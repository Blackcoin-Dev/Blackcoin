// Copyright (c) 2020-2021 Blackcoin Core Developers
// Copyright (c) 2020-2021 Blackcoin More Developers
// Copyright (c) 2020-2021 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_SQLITE_H
#define BITCOIN_WALLET_SQLITE_H

#include <sync.h>
#include <wallet/db.h>
#include <wallet/scheduler_stats.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <optional>
#include <thread>

struct bilingual_str;

struct sqlite3_stmt;
struct sqlite3;
struct sqlite3_mutex;

namespace wallet {
class SQLiteDatabase;

/** Page cache of a wallet database connection in KiB: 16 MiB, or 4 MiB on a
 *  system with 4 GiB of memory or less. */
int SQLitePageCacheKiB(const std::optional<uint64_t>& total_ram);

/** RAII class that provides a database cursor */
class SQLiteCursor : public DatabaseCursor
{
private:
    SQLiteDatabase& m_database;

public:
    sqlite3_stmt* m_cursor_stmt{nullptr};
    // Copies of the prefix things for the prefix cursor.
    // Prevents SQLite from accessing temp variables for the prefix things.
    std::vector<std::byte> m_prefix_range_start;
    std::vector<std::byte> m_prefix_range_end;

    explicit SQLiteCursor(SQLiteDatabase& database) : m_database(database) {}
    explicit SQLiteCursor(SQLiteDatabase& database, std::vector<std::byte> start_range, std::vector<std::byte> end_range)
        : m_database(database),
          m_prefix_range_start(std::move(start_range)),
        m_prefix_range_end(std::move(end_range))
    {}
    ~SQLiteCursor() override;

    Status Next(DataStream& key, DataStream& value) override;
};

/** RAII class that provides access to a WalletDatabase */
class SQLiteBatch : public DatabaseBatch
{
private:
    SQLiteDatabase& m_database;

    sqlite3_stmt* m_read_stmt{nullptr};
    sqlite3_stmt* m_insert_stmt{nullptr};
    sqlite3_stmt* m_overwrite_stmt{nullptr};
    sqlite3_stmt* m_delete_stmt{nullptr};
    sqlite3_stmt* m_delete_prefix_stmt{nullptr};
    bool m_durable_txn{false};
    // True when TxnBegin joined an open bulk scope with a SAVEPOINT instead of
    // a transaction of its own.
    bool m_savepoint_txn{false};
    // Successful TxnBegin retains the recursive FULLMUTEX connection lock.
    // Only this batch can end the transaction, on the thread that began it.
    sqlite3_mutex* m_txn_mutex{nullptr};

    void SetupSQLStatements();
    void ReleaseTransaction();
    bool ExecStatement(sqlite3_stmt* stmt, Span<const std::byte> blob);

    bool ReadKey(DataStream&& key, DataStream& value) override;
    bool WriteKey(DataStream&& key, DataStream&& value, bool overwrite = true) override;
    bool EraseKey(DataStream&& key) override;
    bool HasKey(DataStream&& key) override;
    bool ErasePrefix(Span<const std::byte> prefix) override;

public:
    explicit SQLiteBatch(SQLiteDatabase& database);
    ~SQLiteBatch() override { Close(); }

    /* No-op. See comment on SQLiteDatabase::Flush */
    void Flush() override {}

    void Close() override;

    std::unique_ptr<DatabaseCursor> GetNewCursor() override;
    std::unique_ptr<DatabaseCursor> GetNewPrefixCursor(Span<const std::byte> prefix) override;
    bool TxnBegin(bool durable = false) override;
    bool TxnCommit() override;
    bool TxnAbort() override;
};

/** An instance of this class represents one SQLite3 database.
 **/
class SQLiteDatabase : public WalletDatabase
{
private:
    const bool m_mock{false};

    /** Run the full integrity check in Verify() (otherwise the quick check). */
    const bool m_full_check{true};

    const std::string m_dir_path;

    const std::string m_file_path;

    /**
     * This mutex protects SQLite initialization and shutdown.
     * sqlite3_config() and sqlite3_shutdown() are not thread-safe (sqlite3_initialize() is).
     * Concurrent threads that execute SQLiteDatabase::SQLiteDatabase() should have just one
     * of them do the init and the rest wait for it to complete before all can proceed.
     */
    static Mutex g_sqlite_mutex;
    static int g_sqlite_count GUARDED_BY(g_sqlite_mutex);

    void Cleanup() noexcept EXCLUSIVE_LOCKS_REQUIRED(!g_sqlite_mutex);

    // Background full integrity check (see StartBackgroundIntegrityCheck).
    Mutex m_check_mutex;
    std::condition_variable m_check_cv;
    bool m_check_stop GUARDED_BY(m_check_mutex){false};
    sqlite3* m_check_copy GUARDED_BY(m_check_mutex){nullptr};
    std::thread m_check_thread;
    std::atomic<int> m_check_state{0};
    void RunBackgroundIntegrityCheck();
    /** Wait up to the given time; returns true when a stop was requested. */
    bool CheckWaitStopped(std::chrono::milliseconds delay) EXCLUSIVE_LOCKS_REQUIRED(!m_check_mutex);

public:
    SQLiteDatabase() = delete;

    /** Create DB handle to real database */
    SQLiteDatabase(const fs::path& dir_path, const fs::path& file_path, const DatabaseOptions& options, bool mock = false);

    ~SQLiteDatabase();

    bool Verify(bilingual_str& error);

    enum class BackgroundCheckState : int {
        NOT_STARTED = 0,
        RUNNING,
        PASSED,
        FAILED,    //!< damage found, warning raised
        CANCELLED, //!< stopped by Close() or Rewrite()
        SKIPPED,   //!< could not run (for example no space for the copy); not a finding
    };

    /**
     * Run the full integrity check in a low-priority thread. The wallet keeps
     * the file in exclusive locking mode, so a second connection cannot read
     * it. The thread therefore copies the file with SQLite's online backup in
     * small steps through the wallet's own connection (the connection lock is
     * held for one step at a time, then released), and runs the full check on
     * that private copy. The copy is deleted afterwards. On damage it logs an
     * error and sets the wallet integrity warning; it never stops the node.
     */
    void StartBackgroundIntegrityCheck() override EXCLUSIVE_LOCKS_REQUIRED(!m_check_mutex);
    /** Cancel a running background check and wait for its thread to end. */
    void StopBackgroundIntegrityCheck() noexcept EXCLUSIVE_LOCKS_REQUIRED(!m_check_mutex);
    BackgroundCheckState GetBackgroundCheckState() const { return static_cast<BackgroundCheckState>(m_check_state.load()); }
    /** Wait for the thread to end without cancelling it (tests). */
    void JoinBackgroundIntegrityCheck();
    /** Pause between backup steps (tests lengthen it to hold the check open). */
    std::atomic<int> m_check_step_delay_ms{2};
    /** Pages copied per backup step. */
    std::atomic<int> m_check_step_pages{256};

    /** Open the database if it is not already opened */
    void Open() override;

    /** Close the database */
    void Close() override;

    /* These functions are unused */
    void AddRef() override { assert(false); }
    void RemoveRef() override { assert(false); }

    /** Rewrite the entire database on disk */
    bool Rewrite(const char* skip = nullptr) override;

    /** Back up the entire database to a file.
     */
    bool Backup(const std::string& dest) const override;

    /** No-ops
     *
     * SQLite always flushes everything to the database file after each transaction
     * (each Read/Write/Erase that we do is its own transaction unless we called
     * TxnBegin) so there is no need to have Flush or Periodic Flush.
     *
     * There is no DB env to reload, so ReloadDbEnv has nothing to do
     */
    void Flush() override {}
    bool PeriodicFlush() override { return false; }
    void ReloadDbEnv() override {}

    void IncrementUpdateCounter() override { ++nUpdateCounter; }

    std::string Filename() override { return m_file_path; }
    std::vector<fs::path> Files() override { return {fs::PathFromString(m_file_path)}; }
    std::string Format() override { return "sqlite"; }

    /** Make a SQLiteBatch connected to this database */
    std::unique_ptr<DatabaseBatch> MakeBatch(bool flush_on_close = true) override;

    /** Group this thread's writes into one SQLite transaction (see DatabaseBulkScope) */
    std::unique_ptr<DatabaseBulkScope> MakeBulkScope() override;

    sqlite3* m_db{nullptr};
    bool m_use_unsafe_sync;
    // Protected by sqlite3_db_mutex(m_db). An unabortable transaction whose
    // owner is closing must never become an implicit transaction for another
    // batch. Poison survives until the database connection is reopened.
    bool m_transaction_poisoned{false};
    const SQLiteBatch* m_transaction_owner{nullptr};
    // A bulk scope owns an open transaction that every batch of this
    // connection writes into. Protected by sqlite3_db_mutex(m_db), which the
    // scope holds for its whole life.
    bool m_bulk_active{false};

    /** Record a commit in this database's counters and the process-wide ones. */
    void RecordCommit(SqliteCommitKind kind, std::chrono::microseconds duration);
    const SqliteCommitCounters& CommitCounters() const { return m_commit_counters; }

private:
    SqliteCommitCounters m_commit_counters;
};

std::unique_ptr<SQLiteDatabase> MakeSQLiteDatabase(const fs::path& path, const DatabaseOptions& options, DatabaseStatus& status, bilingual_str& error);

std::string SQLiteDatabaseVersion();
} // namespace wallet

#endif // BITCOIN_WALLET_SQLITE_H
