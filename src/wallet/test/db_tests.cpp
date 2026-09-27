// Copyright (c) 2018-2022 Blackcoin Core Developers
// Copyright (c) 2018-2022 Blackcoin More Developers
// Copyright (c) 2018-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <boost/test/unit_test.hpp>

#include <test/util/setup_common.h>
#include <util/check.h>
#include <util/fs.h>
#include <util/translation.h>
#ifdef USE_BDB
#include <wallet/bdb.h>
#endif
#ifdef USE_SQLITE
#include <wallet/sqlite.h>
#include <sqlite3.h>
#endif
#include <wallet/test/util.h>
#include <wallet/walletutil.h> // for WALLET_FLAG_DESCRIPTORS

#include <fstream>
#include <chrono>
#include <future>
#include <memory>
#include <string>
#include <string_view>

inline std::ostream& operator<<(std::ostream& os, const std::pair<const SerializeData, SerializeData>& kv)
{
    Span key{kv.first}, value{kv.second};
    os << "(\"" << std::string_view{reinterpret_cast<const char*>(key.data()), key.size()} << "\", \""
       << std::string_view{reinterpret_cast<const char*>(key.data()), key.size()} << "\")";
    return os;
}

namespace wallet {

static Span<const std::byte> StringBytes(std::string_view str)
{
    return AsBytes<const char>({str.data(), str.size()});
}

static SerializeData StringData(std::string_view str)
{
    auto bytes = StringBytes(str);
    return SerializeData{bytes.begin(), bytes.end()};
}

static void CheckPrefix(DatabaseBatch& batch, Span<const std::byte> prefix, MockableData expected)
{
    std::unique_ptr<DatabaseCursor> cursor = batch.GetNewPrefixCursor(prefix);
    MockableData actual;
    while (true) {
        DataStream key, value;
        DatabaseCursor::Status status = cursor->Next(key, value);
        if (status == DatabaseCursor::Status::DONE) break;
        BOOST_CHECK(status == DatabaseCursor::Status::MORE);
        BOOST_CHECK(
            actual.emplace(SerializeData(key.begin(), key.end()), SerializeData(value.begin(), value.end())).second);
    }
    BOOST_CHECK_EQUAL_COLLECTIONS(actual.begin(), actual.end(), expected.begin(), expected.end());
}

BOOST_FIXTURE_TEST_SUITE(db_tests, BasicTestingSetup)

#ifdef USE_SQLITE
BOOST_AUTO_TEST_CASE(list_databases_top_level_sqlite_wallet)
{
    const fs::path wallet_dir = m_path_root / "wallets";
    DatabaseOptions options;
    DatabaseStatus status;
    bilingual_str error;

    auto database = MakeSQLiteDatabase(wallet_dir, options, status, error);
    BOOST_REQUIRE_MESSAGE(database, error.original);
    database.reset();

    const auto wallets = ListDatabases(wallet_dir);
    BOOST_REQUIRE_EQUAL(wallets.size(), 1U);
    BOOST_CHECK(wallets.front().empty());
}

BOOST_AUTO_TEST_CASE(sqlite_failed_configuration_does_not_leak_instance_count)
{
    // Start without other SQLite users; sqlite3_config must fail after initialize.
    BOOST_REQUIRE_EQUAL(sqlite3_shutdown(), SQLITE_OK);
    BOOST_REQUIRE_EQUAL(sqlite3_config(SQLITE_CONFIG_SERIALIZED), SQLITE_OK);
    struct SQLiteShutdownOnExit {
        ~SQLiteShutdownOnExit() { sqlite3_shutdown(); }
    } shutdown_on_exit;
    BOOST_REQUIRE_EQUAL(sqlite3_initialize(), SQLITE_OK);

    DatabaseOptions options;
    DatabaseStatus status;
    bilingual_str error;
    const fs::path wallet_path = m_path_root / "retry-after-config-failure";
    auto failed = MakeSQLiteDatabase(wallet_path, options, status, error);
    BOOST_REQUIRE(!failed);
    BOOST_CHECK(status == DatabaseStatus::FAILED_LOAD);
    BOOST_CHECK(error.original.find("Failed to setup error log") != std::string::npos);

    BOOST_REQUIRE_EQUAL(sqlite3_shutdown(), SQLITE_OK);
    error = {};
    auto database = MakeSQLiteDatabase(wallet_path, options, status, error);
    BOOST_REQUIRE_MESSAGE(database, error.original);
    auto batch = database->MakeBatch();
    BOOST_REQUIRE(batch->Write(std::string{"after-retry"}, 42));
    int value{0};
    BOOST_REQUIRE(batch->Read(std::string{"after-retry"}, value));
    BOOST_CHECK_EQUAL(value, 42);
    batch.reset();
    database.reset();

    // If the failed constructor retained a reference, the retry's destructor
    // left SQLite initialized and configuration is still refused.
    BOOST_CHECK_EQUAL(sqlite3_config(SQLITE_CONFIG_SERIALIZED), SQLITE_OK);
}
#endif

static std::shared_ptr<BerkeleyEnvironment> GetWalletEnv(const fs::path& path, fs::path& database_filename)
{
    fs::path data_file = BDBDataFile(path);
    database_filename = data_file.filename();
    return GetBerkeleyEnv(data_file.parent_path(), false);
}

BOOST_AUTO_TEST_CASE(getwalletenv_file)
{
    fs::path test_name = "test_name.dat";
    const fs::path datadir = m_args.GetDataDirNet();
    fs::path file_path = datadir / test_name;
    std::ofstream f{file_path};
    f.close();

    fs::path filename;
    std::shared_ptr<BerkeleyEnvironment> env = GetWalletEnv(file_path, filename);
    BOOST_CHECK_EQUAL(filename, test_name);
    BOOST_CHECK_EQUAL(env->Directory(), datadir);
}

BOOST_AUTO_TEST_CASE(getwalletenv_directory)
{
    fs::path expected_name = "wallet.dat";
    const fs::path datadir = m_args.GetDataDirNet();

    fs::path filename;
    std::shared_ptr<BerkeleyEnvironment> env = GetWalletEnv(datadir, filename);
    BOOST_CHECK_EQUAL(filename, expected_name);
    BOOST_CHECK_EQUAL(env->Directory(), datadir);
}

BOOST_AUTO_TEST_CASE(getwalletenv_g_dbenvs_multiple)
{
    fs::path datadir = m_args.GetDataDirNet() / "1";
    fs::path datadir_2 = m_args.GetDataDirNet() / "2";
    fs::path filename;

    std::shared_ptr<BerkeleyEnvironment> env_1 = GetWalletEnv(datadir, filename);
    std::shared_ptr<BerkeleyEnvironment> env_2 = GetWalletEnv(datadir, filename);
    std::shared_ptr<BerkeleyEnvironment> env_3 = GetWalletEnv(datadir_2, filename);

    BOOST_CHECK(env_1 == env_2);
    BOOST_CHECK(env_2 != env_3);
}

BOOST_AUTO_TEST_CASE(getwalletenv_g_dbenvs_free_instance)
{
    fs::path datadir = gArgs.GetDataDirNet() / "1";
    fs::path datadir_2 = gArgs.GetDataDirNet() / "2";
    fs::path filename;

    std::shared_ptr <BerkeleyEnvironment> env_1_a = GetWalletEnv(datadir, filename);
    std::shared_ptr <BerkeleyEnvironment> env_2_a = GetWalletEnv(datadir_2, filename);
    env_1_a.reset();

    std::shared_ptr<BerkeleyEnvironment> env_1_b = GetWalletEnv(datadir, filename);
    std::shared_ptr<BerkeleyEnvironment> env_2_b = GetWalletEnv(datadir_2, filename);

    BOOST_CHECK(env_1_a != env_1_b);
    BOOST_CHECK(env_2_a == env_2_b);
}

static std::vector<std::unique_ptr<WalletDatabase>> TestDatabases(const fs::path& path_root)
{
    std::vector<std::unique_ptr<WalletDatabase>> dbs;
    DatabaseOptions options;
    DatabaseStatus status;
    bilingual_str error;
#ifdef USE_BDB
    dbs.emplace_back(MakeBerkeleyDatabase(path_root / "bdb", options, status, error));
#endif
#ifdef USE_SQLITE
    dbs.emplace_back(MakeSQLiteDatabase(path_root / "sqlite", options, status, error));
#endif
    dbs.emplace_back(CreateMockableWalletDatabase());
    return dbs;
}

#ifdef USE_SQLITE
static int SQLiteSyncMode(SQLiteDatabase& database)
{
    sqlite3_stmt* statement{nullptr};
    BOOST_REQUIRE_EQUAL(sqlite3_prepare_v2(database.m_db, "PRAGMA synchronous", -1, &statement, nullptr), SQLITE_OK);
    BOOST_REQUIRE_EQUAL(sqlite3_step(statement), SQLITE_ROW);
    const int mode = sqlite3_column_int(statement, 0);
    BOOST_REQUIRE_EQUAL(sqlite3_finalize(statement), SQLITE_OK);
    return mode;
}

struct SQLiteDeniedTransactions {
    bool commit{false};
    bool rollback{false};
};

static int DenySQLiteTransaction(void* context, int action, const char* operation, const char*, const char*, const char*)
{
    if (action != SQLITE_TRANSACTION || !operation) return SQLITE_OK;
    const auto& denied = *static_cast<SQLiteDeniedTransactions*>(context);
    return ((denied.commit && std::string_view(operation) == "COMMIT") ||
            (denied.rollback && std::string_view(operation) == "ROLLBACK")) ? SQLITE_DENY : SQLITE_OK;
}

struct SQLiteHooksReset {
    sqlite3* db;
    ~SQLiteHooksReset()
    {
        sqlite3_set_authorizer(db, nullptr, nullptr);
        sqlite3_commit_hook(db, nullptr, nullptr);
    }
};

BOOST_AUTO_TEST_CASE(sqlite_batch_transaction_ownership)
{
    DatabaseOptions options;
    options.use_unsafe_sync = true;
    DatabaseStatus status;
    bilingual_str error;
    auto database = MakeSQLiteDatabase(m_path_root / "ownership", options, status, error);
    BOOST_REQUIRE_MESSAGE(database, error.original);
    auto owner = database->MakeBatch();
    BOOST_REQUIRE(owner->TxnBegin(/*durable=*/true));
    BOOST_REQUIRE(owner->Write(std::string{"owned"}, 1));
    BOOST_CHECK_EQUAL(SQLiteSyncMode(*database), 2);
    {
        auto reader = database->MakeBatch();
        int value{0};
        BOOST_REQUIRE(reader->Read(std::string{"owned"}, value));
        BOOST_CHECK_EQUAL(value, 1);
        BOOST_CHECK(!reader->TxnBegin(/*durable=*/true));
        BOOST_CHECK(!reader->TxnCommit());
        BOOST_CHECK(!reader->TxnAbort());
        // Recursive same-thread reads are useful, but a different batch
        // must not silently add writes to the owner's atomic operation.
        BOOST_CHECK(!reader->Write(std::string{"foreign"}, 2));
        BOOST_CHECK(!reader->Erase(std::string{"owned"}));
        BOOST_CHECK(!reader->ErasePrefix(StringBytes("")));
        auto cursor = reader->GetNewCursor();
        DataStream key, data;
        BOOST_REQUIRE(cursor);
        BOOST_CHECK(cursor->Next(key, data) == DatabaseCursor::Status::MORE);
    }
    BOOST_CHECK_EQUAL(sqlite3_get_autocommit(database->m_db), 0);
    BOOST_CHECK_EQUAL(SQLiteSyncMode(*database), 2);
    BOOST_REQUIRE(owner->TxnCommit());
    BOOST_CHECK_EQUAL(SQLiteSyncMode(*database), 0);
    BOOST_CHECK(!owner->Exists(std::string{"foreign"}));
    {
        auto forgotten = database->MakeBatch();
        BOOST_REQUIRE(forgotten->TxnBegin(/*durable=*/true));
        BOOST_REQUIRE(forgotten->Write(std::string{"forgotten"}, 3));
    }
    BOOST_CHECK_EQUAL(sqlite3_get_autocommit(database->m_db), 1);
    BOOST_CHECK_EQUAL(SQLiteSyncMode(*database), 0);
    BOOST_CHECK(!owner->Exists(std::string{"forgotten"}));
    owner.reset();
    database->Close();
    database->Open();
    BOOST_CHECK(database->MakeBatch()->Exists(std::string{"owned"}));
}

BOOST_AUTO_TEST_CASE(sqlite_batch_foreign_writer_waits_for_transaction)
{
    DatabaseOptions options;
    DatabaseStatus status;
    bilingual_str error;
    auto database = MakeSQLiteDatabase(m_path_root / "serialized", options, status, error);
    BOOST_REQUIRE_MESSAGE(database, error.original);
    for (const bool commit : {false, true}) {
        auto owner = database->MakeBatch();
        auto foreign = database->MakeBatch();
        BOOST_REQUIRE(owner->TxnBegin(/*durable=*/true));
        const std::string owner_key = commit ? "committed-owner" : "aborted-owner";
        const std::string foreign_key = commit ? "after-commit" : "after-abort";
        BOOST_REQUIRE(owner->Write(owner_key, 1));
        std::promise<void> started;
        auto started_future = started.get_future();
        auto writer = std::async(std::launch::async, [&, foreign = std::move(foreign)] {
            const bool control_refused = !foreign->TxnCommit() && !foreign->TxnAbort();
            started.set_value();
            const bool written = foreign->Write(foreign_key, 2);
            return control_refused && written;
        });
        started_future.wait();
        BOOST_CHECK(writer.wait_for(std::chrono::milliseconds{100}) == std::future_status::timeout);
        BOOST_CHECK_EQUAL(sqlite3_get_autocommit(database->m_db), 0);
        const bool ended = commit ? owner->TxnCommit() : owner->TxnAbort();
        // Destruction also releases/poisons on a failed end, so a regression
        // cannot strand the worker solely because the next assertion fails.
        owner.reset();
        BOOST_CHECK(ended);
        BOOST_CHECK(writer.get());
        auto reader = database->MakeBatch();
        BOOST_CHECK_EQUAL(reader->Exists(owner_key), commit);
        BOOST_CHECK(reader->Exists(foreign_key));
    }
    database->Close();
    database->Open();
    auto reader = database->MakeBatch();
    BOOST_CHECK(!reader->Exists(std::string{"aborted-owner"}));
    BOOST_CHECK(reader->Exists(std::string{"committed-owner"}));
    BOOST_CHECK(reader->Exists(std::string{"after-abort"}));
    BOOST_CHECK(reader->Exists(std::string{"after-commit"}));
}

BOOST_AUTO_TEST_CASE(sqlite_batch_commit_failure_restores_transaction_state)
{
    DatabaseOptions options;
    options.use_unsafe_sync = true;
    DatabaseStatus status;
    bilingual_str error;
    auto database = MakeSQLiteDatabase(m_path_root / "commit-failure", options, status, error);
    BOOST_REQUIRE_MESSAGE(database, error.original);
    auto owner = database->MakeBatch();
    BOOST_REQUIRE(owner->TxnBegin(/*durable=*/true));
    BOOST_REQUIRE(owner->Write(std::string{"denied-commit"}, 1));
    {
        SQLiteDeniedTransactions denied{true, false};
        SQLiteHooksReset reset{database->m_db};
        BOOST_REQUIRE_EQUAL(sqlite3_set_authorizer(database->m_db, DenySQLiteTransaction, &denied), SQLITE_OK);
        BOOST_CHECK(!owner->TxnCommit());
    }
    BOOST_CHECK_EQUAL(sqlite3_get_autocommit(database->m_db), 1);
    BOOST_CHECK_EQUAL(SQLiteSyncMode(*database), 0);
    BOOST_CHECK(!owner->Exists(std::string{"denied-commit"}));

    // A rejecting commit hook makes SQLite roll back automatically. The
    // owner must still release its retained mutex and restore durability.
    BOOST_REQUIRE(owner->TxnBegin(/*durable=*/true));
    BOOST_REQUIRE(owner->Write(std::string{"automatic-rollback"}, 2));
    {
        SQLiteHooksReset reset{database->m_db};
        sqlite3_commit_hook(database->m_db, [](void*) { return 1; }, nullptr);
        BOOST_CHECK(!owner->TxnCommit());
    }
    BOOST_CHECK_EQUAL(sqlite3_get_autocommit(database->m_db), 1);
    BOOST_CHECK_EQUAL(SQLiteSyncMode(*database), 0);
    BOOST_CHECK(!owner->Exists(std::string{"automatic-rollback"}));

    // A statement error can also roll back before TxnAbort is called.
    BOOST_REQUIRE_EQUAL(sqlite3_exec(database->m_db,
        "CREATE TEMP TRIGGER force_rollback BEFORE INSERT ON main BEGIN SELECT RAISE(ROLLBACK, 'test rollback'); END",
        nullptr, nullptr, nullptr), SQLITE_OK);
    BOOST_REQUIRE(owner->TxnBegin(/*durable=*/true));
    BOOST_CHECK(!owner->Write(std::string{"statement-rollback"}, 3));
    BOOST_CHECK_EQUAL(sqlite3_get_autocommit(database->m_db), 1);
    BOOST_CHECK(!owner->TxnAbort());
    BOOST_CHECK_EQUAL(SQLiteSyncMode(*database), 0);
    BOOST_REQUIRE_EQUAL(sqlite3_exec(database->m_db, "DROP TRIGGER force_rollback", nullptr, nullptr, nullptr), SQLITE_OK);
    BOOST_REQUIRE(owner->TxnBegin(/*durable=*/true));
    BOOST_REQUIRE(owner->Write(std::string{"retry"}, 3));
    BOOST_REQUIRE(owner->TxnCommit());
}

BOOST_AUTO_TEST_CASE(sqlite_batch_unabortable_close_poisoned_until_reload)
{
    DatabaseOptions options;
    options.use_unsafe_sync = true;
    DatabaseStatus status;
    bilingual_str error;
    auto database = MakeSQLiteDatabase(m_path_root / "poison", options, status, error);
    BOOST_REQUIRE_MESSAGE(database, error.original);
    auto other = database->MakeBatch();
    auto cursor = other->GetNewCursor();
    BOOST_REQUIRE(cursor);
    auto owner = database->MakeBatch();
    BOOST_REQUIRE(owner->TxnBegin(/*durable=*/true));
    BOOST_REQUIRE(owner->Write(std::string{"orphan"}, 1));
    {
        SQLiteDeniedTransactions denied{false, true};
        SQLiteHooksReset reset{database->m_db};
        BOOST_REQUIRE_EQUAL(sqlite3_set_authorizer(database->m_db, DenySQLiteTransaction, &denied), SQLITE_OK);
        BOOST_CHECK(!owner->TxnAbort());
        BOOST_CHECK_EQUAL(SQLiteSyncMode(*database), 2);
        owner.reset();
    }
    BOOST_CHECK(database->m_transaction_poisoned);
    BOOST_CHECK(database->m_transaction_owner == nullptr);
    BOOST_CHECK_EQUAL(sqlite3_get_autocommit(database->m_db), 0);
    BOOST_CHECK_EQUAL(SQLiteSyncMode(*database), 2);
    int value{0};
    BOOST_CHECK(!other->Read(std::string{"orphan"}, value));
    BOOST_CHECK(!other->Exists(std::string{"orphan"}));
    BOOST_CHECK(!other->Write(std::string{"foreign"}, 2));
    BOOST_CHECK(!other->Erase(std::string{"orphan"}));
    BOOST_CHECK(!other->ErasePrefix(StringBytes("")));
    BOOST_CHECK(!other->TxnBegin());
    BOOST_CHECK(!other->GetNewCursor());
    BOOST_CHECK(!other->GetNewPrefixCursor(StringBytes("")));
    DataStream key, data;
    BOOST_CHECK(cursor->Next(key, data) == DatabaseCursor::Status::FAIL);
    BOOST_CHECK(!database->MakeBatch()->Write(std::string{"new-batch"}, 3));
    BOOST_CHECK(!database->Backup(fs::PathToString(m_path_root / "poison-backup")));
    BOOST_CHECK(!database->Rewrite());
    BOOST_CHECK(!database->Verify(error));
    cursor.reset();
    other.reset();
    database->Close();
    database->Open();
    auto reloaded = database->MakeBatch();
    BOOST_CHECK(!database->m_transaction_poisoned);
    BOOST_CHECK(!reloaded->Exists(std::string{"orphan"}));
    BOOST_CHECK(!reloaded->Exists(std::string{"foreign"}));
    BOOST_CHECK(!reloaded->Exists(std::string{"new-batch"}));
    BOOST_CHECK(reloaded->Write(std::string{"after-reload"}, 4));
}
#endif // USE_SQLITE

BOOST_AUTO_TEST_CASE(db_cursor_prefix_range_test)
{
    // Test each supported db
    for (const auto& database : TestDatabases(m_path_root)) {
        std::vector<std::string> prefixes = {"", "FIRST", "SECOND", "P\xfe\xff", "P\xff\x01", "\xff\xff"};

        // Write elements to it
        std::unique_ptr<DatabaseBatch> handler = Assert(database)->MakeBatch();
        for (unsigned int i = 0; i < 10; i++) {
            for (const auto& prefix : prefixes) {
                BOOST_CHECK(handler->Write(std::make_pair(prefix, i), i));
            }
        }

        // Now read all the items by prefix and verify that each element gets parsed correctly
        for (const auto& prefix : prefixes) {
            DataStream s_prefix;
            s_prefix << prefix;
            std::unique_ptr<DatabaseCursor> cursor = handler->GetNewPrefixCursor(s_prefix);
            DataStream key;
            DataStream value;
            for (int i = 0; i < 10; i++) {
                DatabaseCursor::Status status = cursor->Next(key, value);
                BOOST_CHECK_EQUAL(status, DatabaseCursor::Status::MORE);

                std::string key_back;
                unsigned int i_back;
                key >> key_back >> i_back;
                BOOST_CHECK_EQUAL(key_back, prefix);

                unsigned int value_back;
                value >> value_back;
                BOOST_CHECK_EQUAL(value_back, i_back);
            }

            // Let's now read it once more, it should return DONE
            BOOST_CHECK(cursor->Next(key, value) == DatabaseCursor::Status::DONE);
        }
    }
}

// Lower level DatabaseBase::GetNewPrefixCursor test, to cover cases that aren't
// covered in the higher level test above. The higher level test uses
// serialized strings which are prefixed with string length, so it doesn't test
// truly empty prefixes or prefixes that begin with \xff
BOOST_AUTO_TEST_CASE(db_cursor_prefix_byte_test)
{
    const MockableData::value_type
        e{StringData(""), StringData("e")},
        p{StringData("prefix"), StringData("p")},
        ps{StringData("prefixsuffix"), StringData("ps")},
        f{StringData("\xff"), StringData("f")},
        fs{StringData("\xffsuffix"), StringData("fs")},
        ff{StringData("\xff\xff"), StringData("ff")},
        ffs{StringData("\xff\xffsuffix"), StringData("ffs")};
    for (const auto& database : TestDatabases(m_path_root)) {
        std::unique_ptr<DatabaseBatch> batch = database->MakeBatch();
        for (const auto& [k, v] : {e, p, ps, f, fs, ff, ffs}) {
            batch->Write(Span{k}, Span{v});
        }
        CheckPrefix(*batch, StringBytes(""), {e, p, ps, f, fs, ff, ffs});
        CheckPrefix(*batch, StringBytes("prefix"), {p, ps});
        CheckPrefix(*batch, StringBytes("\xff"), {f, fs, ff, ffs});
        CheckPrefix(*batch, StringBytes("\xff\xff"), {ff, ffs});
    }
}

BOOST_AUTO_TEST_CASE(db_erase_prefix_joins_existing_transaction)
{
    const MockableData::value_type
        p{StringData("prefix"), StringData("p")},
        ps{StringData("prefixsuffix"), StringData("ps")},
        other{StringData("other"), StringData("other")};
    for (const auto& database : TestDatabases(m_path_root)) {
        std::unique_ptr<DatabaseBatch> batch = database->MakeBatch();
        BOOST_REQUIRE(batch->Write(Span{p.first}, Span{p.second}));
        BOOST_REQUIRE(batch->Write(Span{ps.first}, Span{ps.second}));
        BOOST_REQUIRE(batch->Write(Span{other.first}, Span{other.second}));

        // A standalone prefix erase owns and commits its transaction.
        BOOST_REQUIRE(batch->ErasePrefix(StringBytes("prefix")));
        CheckPrefix(*batch, StringBytes("prefix"), {});
        CheckPrefix(*batch, StringBytes("other"), {other});

        BOOST_REQUIRE(batch->Write(Span{p.first}, Span{p.second}));
        BOOST_REQUIRE(batch->Write(Span{ps.first}, Span{ps.second}));

        // A caller-owned transaction keeps ownership: abort restores the
        // erased rows and commit removes them.
        BOOST_REQUIRE(batch->TxnBegin(/*durable=*/true));
        BOOST_REQUIRE(batch->ErasePrefix(StringBytes("prefix")));
        CheckPrefix(*batch, StringBytes("prefix"), {});
        BOOST_REQUIRE(batch->TxnAbort());
        CheckPrefix(*batch, StringBytes("prefix"), {p, ps});

        BOOST_REQUIRE(batch->TxnBegin(/*durable=*/true));
        BOOST_REQUIRE(batch->ErasePrefix(StringBytes("prefix")));
        BOOST_REQUIRE(batch->TxnCommit());
        CheckPrefix(*batch, StringBytes("prefix"), {});
        CheckPrefix(*batch, StringBytes("other"), {other});
    }
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
