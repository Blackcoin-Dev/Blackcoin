// Copyright (c) 2020-2022 Blackcoin Core Developers
// Copyright (c) 2020-2022 Blackcoin More Developers
// Copyright (c) 2020-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/sqlite.h>

#include <chainparams.h>
#include <common/system.h>
#include <crypto/common.h>
#include <logging.h>
#include <sync.h>
#include <util/fs_helpers.h>
#include <util/check.h>
#include <util/io_counters.h>
#include <util/strencodings.h>
#include <util/time.h>
#include <util/translation.h>
#include <wallet/db.h>
#include <wallet/scheduler_stats.h>
#include <warnings.h>

#include <sqlite3.h>
#include <stdint.h>

#ifdef __APPLE__
#include <pthread/qos.h>
#elif !defined(WIN32)
#include <sys/resource.h>
#endif

#include <algorithm>
#include <chrono>
#include <optional>
#include <system_error>
#include <utility>
#include <vector>

namespace wallet {
static constexpr int32_t WALLET_SCHEMA_VERSION = 0;

/** SQLite's FULLMUTEX lock is recursive. Holding it across an explicit
 * transaction serializes all connection users without acquiring a new lock
 * for the whole lifetime of a batch (which may precede wallet locking). */
class SQLiteConnectionLock
{
    sqlite3_mutex* m_mutex;

public:
    explicit SQLiteConnectionLock(sqlite3* db) : m_mutex(sqlite3_db_mutex(db))
    {
        assert(m_mutex);
        sqlite3_mutex_enter(m_mutex);
    }
    ~SQLiteConnectionLock() { if (m_mutex) sqlite3_mutex_leave(m_mutex); }
    SQLiteConnectionLock(const SQLiteConnectionLock&) = delete;
    SQLiteConnectionLock& operator=(const SQLiteConnectionLock&) = delete;
    sqlite3_mutex* Release() { return std::exchange(m_mutex, nullptr); }
};

static Span<const std::byte> SpanFromBlob(sqlite3_stmt* stmt, int col)
{
    return {reinterpret_cast<const std::byte*>(sqlite3_column_blob(stmt, col)),
            static_cast<size_t>(sqlite3_column_bytes(stmt, col))};
}

static void ErrorLogCallback(void* arg, int code, const char* msg)
{
    // From sqlite3_config() documentation for the SQLITE_CONFIG_LOG option:
    // "The void pointer that is the second argument to SQLITE_CONFIG_LOG is passed through as
    // the first parameter to the application-defined logger function whenever that function is
    // invoked."
    // Assert that this is the case:
    assert(arg == nullptr);
    LogPrintf("SQLite Error. Code: %d. Message: %s\n", code, msg);
}

static int TraceSqlCallback(unsigned code, void* context, void* param1, void* param2)
{
    auto* db = static_cast<SQLiteDatabase*>(context);
    if (code == SQLITE_TRACE_STMT) {
        auto* stmt = static_cast<sqlite3_stmt*>(param1);
        // To be conservative and avoid leaking potentially secret information
        // in the log file, only expand statements that query the database, not
        // statements that update the database.
        char* expanded{sqlite3_stmt_readonly(stmt) ? sqlite3_expanded_sql(stmt) : nullptr};
        LogPrintf("[%s] SQLite Statement: %s\n", db->Filename(), expanded ? expanded : sqlite3_sql(stmt));
        if (expanded) sqlite3_free(expanded);
    }
    return SQLITE_OK;
}

static bool BindBlobToStatement(sqlite3_stmt* stmt,
                                int index,
                                Span<const std::byte> blob,
                                const std::string& description)
{
    // Pass a pointer to the empty string "" below instead of passing the
    // blob.data() pointer if the blob.data() pointer is null. Passing a null
    // data pointer to bind_blob would cause sqlite to bind the SQL NULL value
    // instead of the empty blob value X'', which would mess up SQL comparisons.
    int res = sqlite3_bind_blob(stmt, index, blob.data() ? static_cast<const void*>(blob.data()) : "", blob.size(), SQLITE_STATIC);
    if (res != SQLITE_OK) {
        LogPrintf("Unable to bind %s to statement: %s\n", description, sqlite3_errstr(res));
        sqlite3_clear_bindings(stmt);
        sqlite3_reset(stmt);
        return false;
    }

    return true;
}

static std::optional<int> ReadPragmaInteger(sqlite3* db, const std::string& key, const std::string& description, bilingual_str& error)
{
    std::string stmt_text = strprintf("PRAGMA %s", key);
    sqlite3_stmt* pragma_read_stmt{nullptr};
    int ret = sqlite3_prepare_v2(db, stmt_text.c_str(), -1, &pragma_read_stmt, nullptr);
    if (ret != SQLITE_OK) {
        sqlite3_finalize(pragma_read_stmt);
        error = Untranslated(strprintf("SQLiteDatabase: Failed to prepare the statement to fetch %s: %s", description, sqlite3_errstr(ret)));
        return std::nullopt;
    }
    ret = sqlite3_step(pragma_read_stmt);
    if (ret != SQLITE_ROW) {
        sqlite3_finalize(pragma_read_stmt);
        error = Untranslated(strprintf("SQLiteDatabase: Failed to fetch %s: %s", description, sqlite3_errstr(ret)));
        return std::nullopt;
    }
    int result = sqlite3_column_int(pragma_read_stmt, 0);
    sqlite3_finalize(pragma_read_stmt);
    return result;
}

static void SetPragma(sqlite3* db, const std::string& key, const std::string& value, const std::string& err_msg)
{
    std::string stmt_text = strprintf("PRAGMA %s = %s", key, value);
    int ret = sqlite3_exec(db, stmt_text.c_str(), nullptr, nullptr, nullptr);
    if (ret != SQLITE_OK) {
        throw std::runtime_error(strprintf("SQLiteDatabase: %s: %s\n", err_msg, sqlite3_errstr(ret)));
    }
}

int SQLitePageCacheKiB(const std::optional<uint64_t>& total_ram)
{
    return total_ram && *total_ram <= (uint64_t{4} << 30) ? 4 * 1024 : 16 * 1024;
}

Mutex SQLiteDatabase::g_sqlite_mutex;
int SQLiteDatabase::g_sqlite_count = 0;

SQLiteDatabase::SQLiteDatabase(const fs::path& dir_path, const fs::path& file_path, const DatabaseOptions& options, bool mock)
    : WalletDatabase(), m_mock(mock), m_full_check(options.full_integrity_check), m_dir_path(fs::PathToString(dir_path)), m_file_path(fs::PathToString(file_path)), m_use_unsafe_sync(options.use_unsafe_sync)
{
    {
        LOCK(g_sqlite_mutex);
        LogPrintf("Using SQLite Version %s\n", SQLiteDatabaseVersion());
        LogPrintf("Using wallet %s\n", m_dir_path);

        if (g_sqlite_count == 0) {
            int ret = sqlite3_config(SQLITE_CONFIG_LOG, ErrorLogCallback, nullptr);
            if (ret != SQLITE_OK) {
                throw std::runtime_error(strprintf("SQLiteDatabase: Failed to setup error log: %s\n", sqlite3_errstr(ret)));
            }
            ret = sqlite3_config(SQLITE_CONFIG_SERIALIZED);
            if (ret != SQLITE_OK) {
                throw std::runtime_error(strprintf("SQLiteDatabase: Failed to configure serialized threading mode: %s\n", sqlite3_errstr(ret)));
            }
        }
        int ret = sqlite3_initialize(); // This is a no-op if sqlite3 is already initialized
        if (ret != SQLITE_OK) {
            throw std::runtime_error(strprintf("SQLiteDatabase: Failed to initialize SQLite: %s\n", sqlite3_errstr(ret)));
        }
        ++g_sqlite_count;
    }

    try {
        Open();
    } catch (const std::runtime_error&) {
        Cleanup();
        throw;
    }
}

void SQLiteBatch::SetupSQLStatements()
{
    const std::vector<std::pair<sqlite3_stmt**, const char*>> statements{
        {&m_read_stmt, "SELECT value FROM main WHERE key = ?"},
        {&m_insert_stmt, "INSERT INTO main VALUES(?, ?)"},
        {&m_overwrite_stmt, "INSERT or REPLACE into main values(?, ?)"},
        {&m_delete_stmt, "DELETE FROM main WHERE key = ?"},
        {&m_delete_prefix_stmt, "DELETE FROM main WHERE instr(key, ?) = 1"},
    };

    for (const auto& [stmt_prepared, stmt_text] : statements) {
        if (*stmt_prepared == nullptr) {
            int res = sqlite3_prepare_v2(m_database.m_db, stmt_text, -1, stmt_prepared, nullptr);
            if (res != SQLITE_OK) {
                throw std::runtime_error(strprintf(
                    "SQLiteDatabase: Failed to setup SQL statements: %s\n", sqlite3_errstr(res)));
            }
        }
    }
}

SQLiteDatabase::~SQLiteDatabase()
{
    Cleanup();
}

void SQLiteDatabase::Cleanup() noexcept
{
    AssertLockNotHeld(g_sqlite_mutex);

    Close();

    LOCK(g_sqlite_mutex);
    if (--g_sqlite_count == 0) {
        int ret = sqlite3_shutdown();
        if (ret != SQLITE_OK) {
            LogPrintf("SQLiteDatabase: Failed to shutdown SQLite: %s\n", sqlite3_errstr(ret));
        }
    }
}

/** Run PRAGMA integrity_check or quick_check; fills error with every finding. */
static bool RunIntegrityPragma(sqlite3* db, const char* pragma, bilingual_str& error)
{
    sqlite3_stmt* stmt{nullptr};
    int ret = sqlite3_prepare_v2(db, strprintf("PRAGMA %s", pragma).c_str(), -1, &stmt, nullptr);
    if (ret != SQLITE_OK) {
        sqlite3_finalize(stmt);
        error = strprintf(_("SQLiteDatabase: Failed to prepare statement to verify database: %s"), sqlite3_errstr(ret));
        return false;
    }
    while (true) {
        ret = sqlite3_step(stmt);
        if (ret == SQLITE_DONE) {
            break;
        }
        if (ret != SQLITE_ROW) {
            error = strprintf(_("SQLiteDatabase: Failed to execute statement to verify database: %s"), sqlite3_errstr(ret));
            break;
        }
        const char* msg = (const char*)sqlite3_column_text(stmt, 0);
        if (!msg) {
            error = strprintf(_("SQLiteDatabase: Failed to read database verification error: %s"), sqlite3_errstr(ret));
            break;
        }
        std::string str_msg(msg);
        if (str_msg == "ok") {
            continue;
        }
        if (error.empty()) {
            error = _("Failed to verify database") + Untranslated("\n");
        }
        error += Untranslated(strprintf("%s\n", str_msg));
    }
    sqlite3_finalize(stmt);
    return error.empty();
}

bool SQLiteDatabase::Verify(bilingual_str& error)
{
    assert(m_db);
    SQLiteConnectionLock lock(m_db);
    if (m_transaction_poisoned) {
        error = _("SQLiteDatabase: Transaction rollback failed; reload the wallet before database access.");
        return false;
    }

    auto read_result = ReadPragmaInteger(m_db, "application_id", "the application id", error);
    if (!read_result.has_value()) return false;
    uint32_t app_id = static_cast<uint32_t>(read_result.value());
    uint32_t net_magic = ReadBE32(Params().MessageStart().data());
    if (app_id != net_magic) {
        error = strprintf(_("SQLiteDatabase: Unexpected application id. Expected %u, got %u"), net_magic, app_id);
        return false;
    }

    read_result = ReadPragmaInteger(m_db, "user_version", "sqlite wallet schema version", error);
    if (!read_result.has_value()) return false;
    int32_t user_ver = read_result.value();
    if (user_ver != WALLET_SCHEMA_VERSION) {
        error = strprintf(_("SQLiteDatabase: Unknown sqlite wallet schema version %d. Only version %d is supported"), user_ver, WALLET_SCHEMA_VERSION);
        return false;
    }

    // The start-up check is the quick one unless the full one was asked for:
    // it reads the same pages but skips matching index rows to table rows.
    // The full check then runs in the background (StartBackgroundIntegrityCheck).
    return RunIntegrityPragma(m_db, m_full_check ? "integrity_check" : "quick_check", error);
}

void SQLiteDatabase::Open()
{
    int flags = SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
    if (m_mock) {
        flags |= SQLITE_OPEN_MEMORY;
    }

    if (m_db == nullptr) {
        m_transaction_poisoned = false;
        m_transaction_owner = nullptr;
        m_bulk_active = false;
        if (!m_mock) {
            TryCreateDirectories(fs::PathFromString(m_dir_path));
        }
        int ret = sqlite3_open_v2(m_file_path.c_str(), &m_db, flags, nullptr);
        if (ret != SQLITE_OK) {
            throw std::runtime_error(strprintf("SQLiteDatabase: Failed to open database: %s\n", sqlite3_errstr(ret)));
        }
        ret = sqlite3_extended_result_codes(m_db, 1);
        if (ret != SQLITE_OK) {
            throw std::runtime_error(strprintf("SQLiteDatabase: Failed to enable extended result codes: %s\n", sqlite3_errstr(ret)));
        }
        // Enable SQL tracing with -debug=walletdb -loglevel=walletdb:trace.
        if (LogAcceptCategory(BCLog::WALLETDB, BCLog::Level::Trace)) {
           ret = sqlite3_trace_v2(m_db, SQLITE_TRACE_STMT, TraceSqlCallback, this);
           if (ret != SQLITE_OK) {
               LogPrintf("Failed to enable SQL tracing for %s\n", Filename());
           }
        }
    }

    if (sqlite3_db_readonly(m_db, "main") != 0) {
        throw std::runtime_error("SQLiteDatabase: Database opened in readonly mode but read-write permissions are needed");
    }

    // Keep exclusive locking mode for this connection. BEGIN EXCLUSIVE verifies access now.
    SetPragma(m_db, "locking_mode", "exclusive", "Unable to change database locking mode to exclusive");
    int ret = sqlite3_exec(m_db, "BEGIN EXCLUSIVE TRANSACTION", nullptr, nullptr, nullptr);
    if (ret != SQLITE_OK) {
        throw std::runtime_error("SQLiteDatabase: Unable to obtain an exclusive lock on the database, is it being used by another instance of " PACKAGE_NAME "?\n");
    }
    ret = sqlite3_exec(m_db, "COMMIT", nullptr, nullptr, nullptr);
    if (ret != SQLITE_OK) {
        throw std::runtime_error(strprintf("SQLiteDatabase: Unable to end exclusive lock transaction: %s\n", sqlite3_errstr(ret)));
    }

    // Enable fullfsync for the platforms that use it
    SetPragma(m_db, "fullfsync", "true", "Failed to enable fullfsync");

    // SQLite keeps about 2 MiB of pages by default, far less than the b-tree
    // of a wallet with a long history, so lookups went to the disk. A negative
    // cache_size is a size in KiB. The journal mode and the synchronous level
    // are left alone.
    SetPragma(m_db, "cache_size", strprintf("-%d", SQLitePageCacheKiB(GetTotalRAM())), "Failed to set the page cache size");

    if (m_use_unsafe_sync) {
        LogPrintf("WARNING SQLite is configured to not wait for data to be flushed to disk. Data loss and corruption may occur.\n");
        SetPragma(m_db, "synchronous", "OFF", "Failed to set synchronous mode to OFF");
    }

    sqlite3_stmt* check_main_stmt{nullptr};
    ret = sqlite3_prepare_v2(m_db, "SELECT name FROM sqlite_master WHERE type='table' AND name='main'", -1, &check_main_stmt, nullptr);
    if (ret != SQLITE_OK) {
        throw std::runtime_error(strprintf("SQLiteDatabase: Failed to prepare statement to check table existence: %s\n", sqlite3_errstr(ret)));
    }
    ret = sqlite3_step(check_main_stmt);
    if (sqlite3_finalize(check_main_stmt) != SQLITE_OK) {
        throw std::runtime_error(strprintf("SQLiteDatabase: Failed to finalize statement checking table existence: %s\n", sqlite3_errstr(ret)));
    }
    bool table_exists;
    if (ret == SQLITE_DONE) {
        table_exists = false;
    } else if (ret == SQLITE_ROW) {
        table_exists = true;
    } else {
        throw std::runtime_error(strprintf("SQLiteDatabase: Failed to execute statement to check table existence: %s\n", sqlite3_errstr(ret)));
    }

    // Initialize network and schema identifiers only when creating the table.
    if (!table_exists) {
        ret = sqlite3_exec(m_db, "CREATE TABLE main(key BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL)", nullptr, nullptr, nullptr);
        if (ret != SQLITE_OK) {
            throw std::runtime_error(strprintf("SQLiteDatabase: Failed to create new database: %s\n", sqlite3_errstr(ret)));
        }

        uint32_t app_id = ReadBE32(Params().MessageStart().data());
        SetPragma(m_db, "application_id", strprintf("%d", static_cast<int32_t>(app_id)),
                  "Failed to set the application id");

        SetPragma(m_db, "user_version", strprintf("%d", WALLET_SCHEMA_VERSION),
                  "Failed to set the wallet schema version");
    }
}

// Result codes that mean the file itself is damaged, as opposed to a problem
// with the copy (full disk, unwritable directory).
static bool IsCorruptionCode(int rc)
{
    const int primary = rc & 0xff;
    return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB;
}

static void LowerCurrentThreadPriority()
{
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
#elif !defined(WIN32)
    // On Linux this affects the calling thread only.
    (void)setpriority(PRIO_PROCESS, 0, 10);
#endif
}

bool SQLiteDatabase::CheckWaitStopped(std::chrono::milliseconds delay)
{
    WAIT_LOCK(m_check_mutex, lock);
    m_check_cv.wait_for(lock, delay, [this]() EXCLUSIVE_LOCKS_REQUIRED(m_check_mutex) { return m_check_stop; });
    return m_check_stop;
}

void SQLiteDatabase::StartBackgroundIntegrityCheck()
{
    if (m_mock || !m_db || m_check_thread.joinable()) return;
    {
        LOCK(m_check_mutex);
        m_check_stop = false;
    }
    m_check_state = static_cast<int>(BackgroundCheckState::RUNNING);
    m_check_thread = std::thread([this] { RunBackgroundIntegrityCheck(); });
}

void SQLiteDatabase::StopBackgroundIntegrityCheck() noexcept
{
    if (!m_check_thread.joinable()) return;
    {
        LOCK(m_check_mutex);
        m_check_stop = true;
        // Interrupts the full check on the copy; the connection stays valid
        // while m_check_mutex is held because the thread clears the pointer
        // under it before closing.
        if (m_check_copy) sqlite3_interrupt(m_check_copy);
    }
    m_check_cv.notify_all();
    m_check_thread.join();
}

void SQLiteDatabase::JoinBackgroundIntegrityCheck()
{
    if (m_check_thread.joinable()) m_check_thread.join();
}

void SQLiteDatabase::RunBackgroundIntegrityCheck()
{
    LowerCurrentThreadPriority();
    const auto start = std::chrono::steady_clock::now();
    const std::string copy_file = m_file_path + ".fullcheck";
    const fs::path copy_path = fs::PathFromString(copy_file);
    const fs::path journal_path = fs::PathFromString(copy_file + "-journal");

    auto finish = [&](BackgroundCheckState state) { m_check_state = static_cast<int>(state); };
    auto stopped = [&]() { return CheckWaitStopped(std::chrono::milliseconds{0}); };
    auto elapsed_ms = [&]() { return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count(); };
    auto fail = [&](const std::string& what) {
        LogPrintf("ERROR: background wallet integrity check of %s found damage: %s\n", m_file_path, what);
        SetWalletIntegrityWarning(strprintf(
            _("Warning: the wallet file %s failed the full integrity check that runs after start-up. Back it up and restore from a recent backup or recover the wallet. First finding: %s"),
            m_file_path, what));
        finish(BackgroundCheckState::FAILED);
    };
    auto skip = [&](const std::string& why) {
        LogPrintf("Background wallet integrity check of %s skipped: %s\n", m_file_path, why);
        finish(BackgroundCheckState::SKIPPED);
    };

    std::error_code ec;
    fs::remove(copy_path, ec);
    fs::remove(journal_path, ec);

    // The copy needs room for the whole file.
    const uintmax_t wallet_size = fs::file_size(fs::PathFromString(m_file_path), ec);
    if (ec) return skip("cannot read the wallet file size");
    const auto space = fs::space(fs::PathFromString(m_dir_path), ec);
    if (ec || space.available < wallet_size + (uintmax_t{64} << 20)) return skip("not enough free disk space for a private copy");

    LogPrintf("Background wallet integrity check of %s started (%u MiB)\n", m_file_path, wallet_size >> 20);

    sqlite3* copy{nullptr};
    int rc = sqlite3_open_v2(copy_file.c_str(), &copy, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nullptr);
    if (rc != SQLITE_OK) {
        sqlite3_close(copy);
        fs::remove(copy_path, ec);
        return skip(strprintf("cannot create the copy: %s", sqlite3_errstr(rc)));
    }
    // The copy holds the same data as the wallet: keep it private.
    fs::permissions(copy_path, fs::perms::owner_read | fs::perms::owner_write, fs::perm_options::replace, ec);
    sqlite3_exec(copy, "PRAGMA journal_mode=OFF", nullptr, nullptr, nullptr);
    sqlite3_exec(copy, "PRAGMA synchronous=OFF", nullptr, nullptr, nullptr);
    {
        LOCK(m_check_mutex);
        m_check_copy = copy;
    }

    // Copy in small steps. The online backup takes the wallet connection's lock
    // for one step only; a write made through the wallet connection while the
    // copy is in progress is mirrored into the copy by SQLite.
    bool cancelled{false};
    std::string damage;     // set when reading the wallet file hit corruption
    std::string copy_error; // set when the copy failed for another reason
    bool copy_ok{false};
    sqlite3_backup* backup = sqlite3_backup_init(copy, "main", m_db, "main");
    if (backup) {
        while (true) {
            if (stopped()) { cancelled = true; break; }
            rc = sqlite3_backup_step(backup, std::max(1, m_check_step_pages.load()));
            if (rc == SQLITE_DONE) { copy_ok = true; break; }
            if (rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED) {
                if (CheckWaitStopped(std::chrono::milliseconds{std::max(1, m_check_step_delay_ms.load())})) { cancelled = true; break; }
                continue;
            }
            if (IsCorruptionCode(rc)) damage = strprintf("reading the wallet file failed: %s", sqlite3_errstr(rc));
            else copy_error = sqlite3_errstr(rc); // not a finding about the wallet file
            break;
        }
        sqlite3_backup_finish(backup);
    }

    BackgroundCheckState end_state{BackgroundCheckState::PASSED};
    if (cancelled) {
        end_state = BackgroundCheckState::CANCELLED;
    } else if (!backup) {
        end_state = BackgroundCheckState::SKIPPED;
        LogPrintf("Background wallet integrity check of %s skipped: cannot start the copy\n", m_file_path);
    } else if (!copy_error.empty()) {
        end_state = BackgroundCheckState::SKIPPED;
        LogPrintf("Background wallet integrity check of %s skipped: copy failed: %s\n", m_file_path, copy_error);
    } else if (!damage.empty()) {
        fail(damage);
        end_state = BackgroundCheckState::FAILED;
    } else if (copy_ok) {
        bilingual_str error;
        if (RunIntegrityPragma(copy, "integrity_check", error)) {
            LogPrintf("Background wallet integrity check of %s passed in %u ms\n", m_file_path, elapsed_ms());
        } else if (stopped()) {
            end_state = BackgroundCheckState::CANCELLED;
        } else {
            std::string first_lines = error.original;
            // Keep the warning short; the full list goes to the log.
            LogPrintf("Background wallet integrity check findings for %s:\n%s", m_file_path, first_lines);
            const size_t nl = first_lines.find('\n');
            const size_t nl2 = nl == std::string::npos ? nl : first_lines.find('\n', nl + 1);
            fail(nl2 == std::string::npos ? first_lines : first_lines.substr(0, nl2));
            end_state = BackgroundCheckState::FAILED;
        }
    }
    if (end_state == BackgroundCheckState::CANCELLED) {
        LogPrintf("Background wallet integrity check of %s cancelled\n", m_file_path);
    }

    {
        LOCK(m_check_mutex);
        m_check_copy = nullptr;
    }
    sqlite3_close(copy);
    fs::remove(copy_path, ec);
    fs::remove(journal_path, ec);
    m_check_state = static_cast<int>(end_state);
}

bool SQLiteDatabase::Rewrite(const char* skip)
{
    // VACUUM replaces the file the background check is reading.
    StopBackgroundIntegrityCheck();
    if (!m_db) return false;
    SQLiteConnectionLock lock(m_db);
    if (m_transaction_poisoned) return false;
    // Rewrite the database using the VACUUM command: https://sqlite.org/lang_vacuum.html
    int ret = sqlite3_exec(m_db, "VACUUM", nullptr, nullptr, nullptr);
    return ret == SQLITE_OK;
}

bool SQLiteDatabase::Backup(const std::string& dest) const
{
    if (!m_db) return false;
    SQLiteConnectionLock lock(m_db);
    if (m_transaction_poisoned) return false;
    sqlite3* db_copy;
    int res = sqlite3_open(dest.c_str(), &db_copy);
    if (res != SQLITE_OK) {
        sqlite3_close(db_copy);
        return false;
    }
    sqlite3_backup* backup = sqlite3_backup_init(db_copy, "main", m_db, "main");
    if (!backup) {
        LogPrintf("%s: Unable to begin backup: %s\n", __func__, sqlite3_errmsg(m_db));
        sqlite3_close(db_copy);
        return false;
    }
    // Specifying -1 will copy all of the pages
    res = sqlite3_backup_step(backup, -1);
    if (res != SQLITE_DONE) {
        LogPrintf("%s: Unable to backup: %s\n", __func__, sqlite3_errstr(res));
        sqlite3_backup_finish(backup);
        sqlite3_close(db_copy);
        return false;
    }
    res = sqlite3_backup_finish(backup);
    sqlite3_close(db_copy);
    return res == SQLITE_OK;
}

void SQLiteDatabase::RecordCommit(SqliteCommitKind kind, std::chrono::microseconds duration)
{
    iocounters::OnWalletCommit(InWalletCallback());
    m_commit_counters.Record(kind, duration);
    ProcessSqliteCommits().Record(kind, duration);
}

void SQLiteDatabase::Close()
{
    // The check thread uses m_db: end it first.
    StopBackgroundIntegrityCheck();
    if (m_db) {
        const SqliteCommitSnapshot commits = m_commit_counters.Snapshot();
        uint64_t n{0}, total_us{0}, max_us{0};
        for (const SqliteCommitCounts& c : commits) {
            n += c.count;
            total_us += c.total_us;
            max_us = std::max(max_us, c.max_us);
        }
        if (n > 0) {
            LogPrintf("SQLite commits for %s over its lifetime: n=%u total=%u ms max=%u ms (grouped write scopes: %u)\n", m_file_path, n, total_us / 1000, max_us / 1000,
                      commits[static_cast<size_t>(SqliteCommitKind::BULK_SCOPE)].count);
        }
    }
    int res = sqlite3_close(m_db);
    if (res != SQLITE_OK) {
        throw std::runtime_error(strprintf("SQLiteDatabase: Failed to close database: %s\n", sqlite3_errstr(res)));
    }
    m_db = nullptr;
}

std::unique_ptr<DatabaseBatch> SQLiteDatabase::MakeBatch(bool flush_on_close)
{
    // We ignore flush_on_close because we don't do manual flushing for SQLite
    return std::make_unique<SQLiteBatch>(*this);
}

SQLiteBatch::SQLiteBatch(SQLiteDatabase& database)
    : m_database(database)
{
    assert(m_database.m_db);
    SQLiteConnectionLock lock(m_database.m_db);
    if (!m_database.m_transaction_poisoned) SetupSQLStatements();
}

void SQLiteBatch::Close()
{
    // A temporary reader or another batch must never abort the owner's
    // transaction merely because they share the same SQLite connection.
    if (m_txn_mutex) {
        if (TxnAbort()) {
            LogPrintf("SQLiteBatch: Batch closed unexpectedly without the transaction being explicitly committed or aborted\n");
        } else {
            LogPrintf("SQLiteBatch: Batch closed and failed to abort transaction\n");
            if (m_txn_mutex) {
                // The failed rollback left a transaction open. Keep FULL
                // synchronization unchanged and refuse subsequent access;
                // releasing the mutex must not expose an orphan transaction.
                m_database.m_transaction_poisoned = true;
                m_database.m_transaction_owner = nullptr;
                m_durable_txn = false;
                sqlite3_mutex_leave(std::exchange(m_txn_mutex, nullptr));
            }
        }
    }

    const std::vector<std::pair<sqlite3_stmt**, const char*>> statements{
        {&m_read_stmt, "read"},
        {&m_insert_stmt, "insert"},
        {&m_overwrite_stmt, "overwrite"},
        {&m_delete_stmt, "delete"},
        {&m_delete_prefix_stmt, "delete prefix"},
    };

    for (const auto& [stmt_prepared, stmt_description] : statements) {
        int res = sqlite3_finalize(*stmt_prepared);
        if (res != SQLITE_OK) {
            LogPrintf("SQLiteBatch: Batch closed but could not finalize %s statement: %s\n",
                      stmt_description, sqlite3_errstr(res));
        }
        *stmt_prepared = nullptr;
    }
}

bool SQLiteBatch::ReadKey(DataStream&& key, DataStream& value)
{
    if (!m_database.m_db) return false;
    SQLiteConnectionLock lock(m_database.m_db);
    if (m_database.m_transaction_poisoned) return false;
    assert(m_read_stmt);

    if (!BindBlobToStatement(m_read_stmt, 1, key, "key")) return false;
    int res = sqlite3_step(m_read_stmt);
    if (res != SQLITE_ROW) {
        if (res != SQLITE_DONE) {
            // SQLITE_DONE means "not found", don't log an error in that case.
            LogPrintf("%s: Unable to execute statement: %s\n", __func__, sqlite3_errstr(res));
        }
        sqlite3_clear_bindings(m_read_stmt);
        sqlite3_reset(m_read_stmt);
        return false;
    }
    value.clear();
    value.write(SpanFromBlob(m_read_stmt, 0));

    sqlite3_clear_bindings(m_read_stmt);
    sqlite3_reset(m_read_stmt);
    return true;
}

bool SQLiteBatch::WriteKey(DataStream&& key, DataStream&& value, bool overwrite)
{
    if (!m_database.m_db) return false;
    SQLiteConnectionLock lock(m_database.m_db);
    if (m_database.m_transaction_poisoned ||
        (m_database.m_transaction_owner && m_database.m_transaction_owner != this)) return false;
    assert(m_insert_stmt && m_overwrite_stmt);

    sqlite3_stmt* stmt;
    if (overwrite) {
        stmt = m_overwrite_stmt;
    } else {
        stmt = m_insert_stmt;
    }

    if (!BindBlobToStatement(stmt, 1, key, "key")) return false;
    if (!BindBlobToStatement(stmt, 2, value, "value")) return false;

    // Outside a transaction SQLite commits this statement by itself.
    const bool implicit_commit = sqlite3_get_autocommit(m_database.m_db) != 0;
    const auto step_start = implicit_commit ? SteadyClock::now() : SteadyClock::time_point{};
    int res = sqlite3_step(stmt);
    if (implicit_commit) {
        m_database.RecordCommit(SqliteCommitKind::AUTOCOMMIT,
                                std::chrono::duration_cast<std::chrono::microseconds>(SteadyClock::now() - step_start));
    }
    sqlite3_clear_bindings(stmt);
    sqlite3_reset(stmt);
    if (res != SQLITE_DONE) {
        LogPrintf("%s: Unable to execute statement: %s\n", __func__, sqlite3_errstr(res));
    }
    return res == SQLITE_DONE;
}

bool SQLiteBatch::ExecStatement(sqlite3_stmt* stmt, Span<const std::byte> blob)
{
    if (!m_database.m_db) return false;
    SQLiteConnectionLock lock(m_database.m_db);
    if (m_database.m_transaction_poisoned ||
        (m_database.m_transaction_owner && m_database.m_transaction_owner != this)) return false;
    assert(stmt);

    if (!BindBlobToStatement(stmt, 1, blob, "key")) return false;

    // Outside a transaction SQLite commits this statement by itself.
    const bool implicit_commit = sqlite3_get_autocommit(m_database.m_db) != 0;
    const auto step_start = implicit_commit ? SteadyClock::now() : SteadyClock::time_point{};
    int res = sqlite3_step(stmt);
    if (implicit_commit) {
        m_database.RecordCommit(SqliteCommitKind::AUTOCOMMIT,
                                std::chrono::duration_cast<std::chrono::microseconds>(SteadyClock::now() - step_start));
    }
    sqlite3_clear_bindings(stmt);
    sqlite3_reset(stmt);
    if (res != SQLITE_DONE) {
        LogPrintf("%s: Unable to execute statement: %s\n", __func__, sqlite3_errstr(res));
    }
    return res == SQLITE_DONE;
}

bool SQLiteBatch::EraseKey(DataStream&& key)
{
    return ExecStatement(m_delete_stmt, key);
}

bool SQLiteBatch::ErasePrefix(Span<const std::byte> prefix)
{
    return ExecStatement(m_delete_prefix_stmt, prefix);
}

bool SQLiteBatch::HasKey(DataStream&& key)
{
    if (!m_database.m_db) return false;
    SQLiteConnectionLock lock(m_database.m_db);
    if (m_database.m_transaction_poisoned) return false;
    assert(m_read_stmt);

    if (!BindBlobToStatement(m_read_stmt, 1, key, "key")) return false;
    int res = sqlite3_step(m_read_stmt);
    sqlite3_clear_bindings(m_read_stmt);
    sqlite3_reset(m_read_stmt);
    return res == SQLITE_ROW;
}

DatabaseCursor::Status SQLiteCursor::Next(DataStream& key, DataStream& value)
{
    if (!m_database.m_db) return Status::FAIL;
    SQLiteConnectionLock lock(m_database.m_db);
    if (m_database.m_transaction_poisoned) return Status::FAIL;
    int res = sqlite3_step(m_cursor_stmt);
    if (res == SQLITE_DONE) {
        return Status::DONE;
    }
    if (res != SQLITE_ROW) {
        LogPrintf("%s: Unable to execute cursor step: %s\n", __func__, sqlite3_errstr(res));
        return Status::FAIL;
    }

    key.clear();
    value.clear();

    key.write(SpanFromBlob(m_cursor_stmt, 0));
    value.write(SpanFromBlob(m_cursor_stmt, 1));
    return Status::MORE;
}

SQLiteCursor::~SQLiteCursor()
{
    sqlite3_clear_bindings(m_cursor_stmt);
    sqlite3_reset(m_cursor_stmt);
    int res = sqlite3_finalize(m_cursor_stmt);
    if (res != SQLITE_OK) {
        LogPrintf("%s: cursor closed but could not finalize cursor statement: %s\n",
                  __func__, sqlite3_errstr(res));
    }
}

std::unique_ptr<DatabaseCursor> SQLiteBatch::GetNewCursor()
{
    if (!m_database.m_db) return nullptr;
    SQLiteConnectionLock lock(m_database.m_db);
    if (m_database.m_transaction_poisoned) return nullptr;
    auto cursor = std::make_unique<SQLiteCursor>(m_database);

    const char* stmt_text = "SELECT key, value FROM main";
    int res = sqlite3_prepare_v2(m_database.m_db, stmt_text, -1, &cursor->m_cursor_stmt, nullptr);
    if (res != SQLITE_OK) {
        throw std::runtime_error(strprintf(
            "%s: Failed to setup cursor SQL statement: %s\n", __func__, sqlite3_errstr(res)));
    }

    return cursor;
}

std::unique_ptr<DatabaseCursor> SQLiteBatch::GetNewPrefixCursor(Span<const std::byte> prefix)
{
    if (!m_database.m_db) return nullptr;
    SQLiteConnectionLock lock(m_database.m_db);
    if (m_database.m_transaction_poisoned) return nullptr;

    // To get just the records we want, the SQL statement does a comparison of the binary data
    // where the data must be greater than or equal to the prefix, and less than
    // the prefix incremented by one (when interpreted as an integer)
    std::vector<std::byte> start_range(prefix.begin(), prefix.end());
    std::vector<std::byte> end_range(prefix.begin(), prefix.end());
    auto it = end_range.rbegin();
    for (; it != end_range.rend(); ++it) {
        if (*it == std::byte(std::numeric_limits<unsigned char>::max())) {
            *it = std::byte(0);
            continue;
        }
        *it = std::byte(std::to_integer<unsigned char>(*it) + 1);
        break;
    }
    if (it == end_range.rend()) {
        // If the prefix is all 0xff bytes, clear end_range as we won't need it
        end_range.clear();
    }

    auto cursor = std::make_unique<SQLiteCursor>(m_database, start_range, end_range);
    if (!cursor) return nullptr;

    const char* stmt_text = end_range.empty() ? "SELECT key, value FROM main WHERE key >= ?" :
                            "SELECT key, value FROM main WHERE key >= ? AND key < ?";
    int res = sqlite3_prepare_v2(m_database.m_db, stmt_text, -1, &cursor->m_cursor_stmt, nullptr);
    if (res != SQLITE_OK) {
        throw std::runtime_error(strprintf(
            "SQLiteDatabase: Failed to setup cursor SQL statement: %s\n", sqlite3_errstr(res)));
    }

    if (!BindBlobToStatement(cursor->m_cursor_stmt, 1, cursor->m_prefix_range_start, "prefix_start")) return nullptr;
    if (!end_range.empty()) {
        if (!BindBlobToStatement(cursor->m_cursor_stmt, 2, cursor->m_prefix_range_end, "prefix_end")) return nullptr;
    }

    return cursor;
}

static constexpr const char* NESTED_SAVEPOINT{"bitcoin_nested_txn"};

bool SQLiteBatch::TxnBegin(bool durable)
{
    if (!m_database.m_db || m_txn_mutex) return false;
    SQLiteConnectionLock lock(m_database.m_db);
    if (m_database.m_bulk_active) {
        // A bulk scope already holds the connection's only transaction. Its
        // atomic units nest as a SAVEPOINT; the durable flag cannot change the
        // synchronous mode inside a transaction, and durability is reached
        // when the scope commits, before any other thread can observe it.
        if (m_database.m_transaction_poisoned || m_database.m_transaction_owner ||
            sqlite3_get_autocommit(m_database.m_db) != 0) return false;
        const std::string begin = strprintf("SAVEPOINT %s", NESTED_SAVEPOINT);
        if (sqlite3_exec(m_database.m_db, begin.c_str(), nullptr, nullptr, nullptr) != SQLITE_OK) {
            LogPrintf("SQLiteBatch: Failed to begin the nested transaction\n");
            return false;
        }
        m_savepoint_txn = true;
        m_durable_txn = false;
        m_database.m_transaction_owner = this;
        m_txn_mutex = lock.Release();
        return true;
    }
    if (m_database.m_transaction_poisoned ||
        m_database.m_transaction_owner || sqlite3_get_autocommit(m_database.m_db) == 0) return false;
    if (durable && m_database.m_use_unsafe_sync) {
        const int sync_res = sqlite3_exec(m_database.m_db, "PRAGMA synchronous=FULL", nullptr, nullptr, nullptr);
        if (sync_res != SQLITE_OK) {
            LogPrintf("SQLiteBatch: Failed to enable durable synchronous mode\n");
            return false;
        }
    }
    int res = sqlite3_exec(m_database.m_db, "BEGIN TRANSACTION", nullptr, nullptr, nullptr);
    if (res != SQLITE_OK) {
        LogPrintf("SQLiteBatch: Failed to begin the transaction\n");
        if (durable && m_database.m_use_unsafe_sync) {
            sqlite3_exec(m_database.m_db, "PRAGMA synchronous=OFF", nullptr, nullptr, nullptr);
        }
        return false;
    }
    m_durable_txn = durable;
    m_database.m_transaction_owner = this;
    m_txn_mutex = lock.Release();
    return true;
}

void SQLiteBatch::ReleaseTransaction()
{
    assert(m_txn_mutex);
    assert(m_database.m_transaction_owner == this);
    // A nested SAVEPOINT leaves the scope's own transaction open.
    assert(m_savepoint_txn || sqlite3_get_autocommit(m_database.m_db) != 0);
    m_savepoint_txn = false;
    if (m_durable_txn && m_database.m_use_unsafe_sync) {
        if (sqlite3_exec(m_database.m_db, "PRAGMA synchronous=OFF", nullptr, nullptr, nullptr) != SQLITE_OK) {
            LogPrintf("SQLiteBatch: Failed to restore unsafe synchronous mode after transaction\n");
        }
    }
    m_durable_txn = false;
    m_database.m_transaction_owner = nullptr;
    sqlite3_mutex_leave(std::exchange(m_txn_mutex, nullptr));
}

bool SQLiteBatch::TxnCommit()
{
    if (!m_txn_mutex) return false;
    if (m_savepoint_txn) {
        // Inside a bulk scope the connection stays in a transaction. If SQLite
        // rolled the scope back by itself (an I/O or full-disk error), this
        // unit is lost and the caller must treat it as failed.
        if (sqlite3_get_autocommit(m_database.m_db) != 0) {
            ReleaseTransaction();
            return false;
        }
        const std::string release = strprintf("RELEASE %s", NESTED_SAVEPOINT);
        const bool released = sqlite3_exec(m_database.m_db, release.c_str(), nullptr, nullptr, nullptr) == SQLITE_OK;
        if (!released) LogPrintf("SQLiteBatch: Failed to commit the nested transaction\n");
        ReleaseTransaction();
        return released;
    }
    if (sqlite3_get_autocommit(m_database.m_db) != 0) {
        // SQLite may itself roll back on an I/O or constraint failure. Only
        // the owner releases its lock and durability state in that case.
        ReleaseTransaction();
        return false;
    }
    const auto commit_start = SteadyClock::now();
    int res = sqlite3_exec(m_database.m_db, "COMMIT TRANSACTION", nullptr, nullptr, nullptr);
    m_database.RecordCommit(m_durable_txn ? SqliteCommitKind::DURABLE : SqliteCommitKind::NON_DURABLE,
                            std::chrono::duration_cast<std::chrono::microseconds>(SteadyClock::now() - commit_start));
    if (res != SQLITE_OK) {
        LogPrintf("SQLiteBatch: Failed to commit the transaction\n");
        // A failed COMMIT can leave the connection inside the transaction.
        // Explicitly roll it back so partial non-HD key state cannot leak into
        // a later batch and synchronous mode can be restored safely.
        if (sqlite3_get_autocommit(m_database.m_db) == 0 &&
            sqlite3_exec(m_database.m_db, "ROLLBACK TRANSACTION", nullptr, nullptr, nullptr) != SQLITE_OK) {
            LogPrintf("SQLiteBatch: Failed to roll back after commit failure\n");
        }
    }
    const bool committed = res == SQLITE_OK;
    if (sqlite3_get_autocommit(m_database.m_db) != 0) {
        ReleaseTransaction();
    }
    // If rollback also failed, retain ownership and the connection lock so
    // the caller can retry abort. Close will poison an unabortable database.
    return committed;
}

bool SQLiteBatch::TxnAbort()
{
    if (!m_txn_mutex) return false;
    if (m_savepoint_txn) {
        if (sqlite3_get_autocommit(m_database.m_db) != 0) {
            ReleaseTransaction();
            return false;
        }
        const std::string rollback = strprintf("ROLLBACK TO %s", NESTED_SAVEPOINT);
        const std::string release = strprintf("RELEASE %s", NESTED_SAVEPOINT);
        const bool aborted =
            sqlite3_exec(m_database.m_db, rollback.c_str(), nullptr, nullptr, nullptr) == SQLITE_OK &&
            sqlite3_exec(m_database.m_db, release.c_str(), nullptr, nullptr, nullptr) == SQLITE_OK;
        if (!aborted) LogPrintf("SQLiteBatch: Failed to abort the nested transaction\n");
        // The savepoint is gone, or the scope's transaction already ended.
        // Either way the scope, not this batch, owns what is left.
        if (aborted || sqlite3_get_autocommit(m_database.m_db) != 0) ReleaseTransaction();
        return aborted;
    }
    if (sqlite3_get_autocommit(m_database.m_db) != 0) {
        ReleaseTransaction();
        return false;
    }
    int res = sqlite3_exec(m_database.m_db, "ROLLBACK TRANSACTION", nullptr, nullptr, nullptr);
    if (res != SQLITE_OK) {
        LogPrintf("SQLiteBatch: Failed to abort the transaction\n");
    }
    const bool aborted = res == SQLITE_OK;
    if (sqlite3_get_autocommit(m_database.m_db) != 0) {
        ReleaseTransaction();
    }
    return aborted;
}

namespace {
/**
 * One SQLite transaction shared by every batch of the connection, held by the
 * creating thread. The recursive connection mutex stays held, so no other
 * thread can read or write the wallet database until Commit (the same
 * exclusion an ordinary TxnBegin gives).
 */
class SQLiteBulkScope : public DatabaseBulkScope
{
    SQLiteDatabase& m_database;
    sqlite3_mutex* m_mutex;
    //! Row changes of the connection when the scope began.
    const int m_changes_at_begin;
    bool m_done{false};

public:
    SQLiteBulkScope(SQLiteDatabase& database, sqlite3_mutex* mutex)
        : m_database(database), m_mutex(mutex), m_changes_at_begin(sqlite3_total_changes(database.m_db)) {}
    ~SQLiteBulkScope() override { Commit(); }

    bool Commit() override
    {
        if (m_done) return true;
        m_done = true;
        // A nested batch that outlived its call would leave a savepoint open.
        // Its unit is already counted failed; the scope still ends here.
        bool committed{false};
        if (sqlite3_get_autocommit(m_database.m_db) == 0) {
            const auto commit_start = SteadyClock::now();
            // A scope in which no row was written ends without touching the
            // disk, so it is not counted as a commit.
            const bool wrote_rows{sqlite3_total_changes(m_database.m_db) != m_changes_at_begin};
            committed = sqlite3_exec(m_database.m_db, "COMMIT TRANSACTION", nullptr, nullptr, nullptr) == SQLITE_OK;
            if (wrote_rows) {
                m_database.RecordCommit(SqliteCommitKind::BULK_SCOPE,
                                        std::chrono::duration_cast<std::chrono::microseconds>(SteadyClock::now() - commit_start));
            }
            if (!committed) {
                LogPrintf("SQLiteDatabase: Failed to commit the grouped wallet writes\n");
                if (sqlite3_get_autocommit(m_database.m_db) == 0 &&
                    sqlite3_exec(m_database.m_db, "ROLLBACK TRANSACTION", nullptr, nullptr, nullptr) != SQLITE_OK) {
                    LogPrintf("SQLiteDatabase: Failed to roll back the grouped wallet writes\n");
                    m_database.m_transaction_poisoned = true;
                }
            }
        } else {
            LogPrintf("SQLiteDatabase: The grouped wallet writes were rolled back by SQLite\n");
        }
        m_database.m_bulk_active = false;
        sqlite3_mutex_leave(m_mutex);
        return committed;
    }
};
} // namespace

std::unique_ptr<DatabaseBulkScope> SQLiteDatabase::MakeBulkScope()
{
    if (!m_db) return nullptr;
    SQLiteConnectionLock lock(m_db);
    if (m_transaction_poisoned || m_transaction_owner || m_bulk_active ||
        sqlite3_get_autocommit(m_db) == 0) return nullptr;
    if (sqlite3_exec(m_db, "BEGIN TRANSACTION", nullptr, nullptr, nullptr) != SQLITE_OK) {
        LogPrintf("SQLiteDatabase: Failed to begin the grouped wallet writes\n");
        return nullptr;
    }
    m_bulk_active = true;
    return std::make_unique<SQLiteBulkScope>(*this, lock.Release());
}

std::unique_ptr<SQLiteDatabase> MakeSQLiteDatabase(const fs::path& path, const DatabaseOptions& options, DatabaseStatus& status, bilingual_str& error)
{
    try {
        fs::path data_file = SQLiteDataFile(path);
        auto db = std::make_unique<SQLiteDatabase>(data_file.parent_path(), data_file, options);
        if (options.verify && !db->Verify(error)) {
            status = DatabaseStatus::FAILED_VERIFY;
            return nullptr;
        }
        status = DatabaseStatus::SUCCESS;
        return db;
    } catch (const std::runtime_error& e) {
        status = DatabaseStatus::FAILED_LOAD;
        error = Untranslated(e.what());
        return nullptr;
    }
}

std::string SQLiteDatabaseVersion()
{
    return std::string(sqlite3_libversion());
}
} // namespace wallet
