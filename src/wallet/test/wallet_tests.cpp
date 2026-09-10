// Copyright (c) 2012-2022 Blackcoin Core Developers
// Copyright (c) 2012-2022 Blackcoin More Developers
// Copyright (c) 2012-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/wallet.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <future>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <stdint.h>
#include <string_view>
#include <thread>
#include <vector>

#include <addresstype.h>
#include <chain.h>
#include <coins.h>
#include <common/args.h>
#include <common/settings.h>
#include <consensus/demurrage.h>
#include <crypto/mldsa.h>
#include <interfaces/chain.h>
#include <interfaces/handler.h>
#include <interfaces/wallet.h>
#include <key_io.h>
#include <logging.h>
#include <node/blockstorage.h>
#include <policy/policy.h>
#include <rpc/protocol.h>
#include <rpc/request.h>
#include <rpc/server.h>
#include <script/solver.h>
#include <shadow.h>
#include <streams.h>
#include <support/cleanse.h>
#include <test/util/logging.h>
#include <test/util/random.h>
#include <test/util/setup_common.h>
#include <undo.h>
#include <util/fs_helpers.h>
#include <util/getuniquepath.h>
#include <util/readwritefile.h>
#include <util/translation.h>
#include <validation.h>
#include <validationinterface.h>
#include <wallet/claim_maintenance.h>
#include <wallet/coincontrol.h>
#include <wallet/context.h>
#include <wallet/load.h>
#ifdef USE_BDB
#include <wallet/bdb.h>
#endif
#include <wallet/quantum_stake_ops.h>
#include <wallet/receive.h>
#include <wallet/rpc/util.h>
#include <wallet/scriptpubkeyman.h>
#include <wallet/spend.h>
#include <wallet/staking.h>
#include <wallet/test/util.h>
#include <wallet/test/wallet_test_fixture.h>

#include <boost/test/unit_test.hpp>
#include <univalue.h>

using node::MAX_BLOCKFILE_SIZE;

namespace wallet {
RPCHelpMan importmulti();
RPCHelpMan dumpwallet();
RPCHelpMan importwallet();
static CMutableTransaction MakeDurabilityTestSpend(
    const CTransaction& from, uint32_t index, const CKey& key,
    const CScript& pubkey)
{
    CMutableTransaction mtx;
    mtx.vout.emplace_back(
        from.vout[index].nValue - DEFAULT_TRANSACTION_MAXFEE, pubkey);
    mtx.vin.emplace_back(CTxIn{from.GetHash(), index});
    FillableSigningProvider keystore;
    keystore.AddKey(key);
    std::map<COutPoint, Coin> coins;
    coins[mtx.vin[0].prevout].out = from.vout[index];
    std::map<int, bilingual_str> input_errors;
    BOOST_REQUIRE(SignTransaction(
        mtx, &keystore, coins, SIGHASH_ALL, input_errors));
    return mtx;
}

class ScopedArgsSettings
{
public:
    ScopedArgsSettings()
    {
        gArgs.LockSettings([&](common::Settings& settings) { m_saved = settings; });
    }

    ~ScopedArgsSettings()
    {
        gArgs.LockSettings([&](common::Settings& settings) { settings = m_saved; });
    }

    void Force(const std::string& option, const std::string& value)
    {
        gArgs.ForceSetArg(option, value);
    }

    void Unset(const std::string& option)
    {
        const std::string name = option.front() == '-' ? option.substr(1) : option;
        gArgs.LockSettings([&](common::Settings& settings) {
            settings.forced_settings.erase(name);
            settings.command_line_options.erase(name);
            for (auto& [_, section] : settings.ro_config) section.erase(name);
            settings.rw_settings.erase(name);
        });
    }

    void SetRepeated(const std::string& option, const std::vector<std::string>& values)
    {
        const std::string name = option.front() == '-' ? option.substr(1) : option;
        gArgs.LockSettings([&](common::Settings& settings) {
            settings.forced_settings.erase(name);
            settings.command_line_options[name].clear();
            for (const std::string& value : values) {
                settings.command_line_options[name].emplace_back(value);
            }
        });
    }

private:
    common::Settings m_saved;
};

class ValidationQueueBarrier
{
public:
    ValidationQueueBarrier()
        : m_release{m_release_promise.get_future().share()}
    {
        CallFunctionInValidationInterfaceQueue(
            [release = m_release] { release.wait(); });
    }

    ValidationQueueBarrier(const ValidationQueueBarrier&) = delete;
    ValidationQueueBarrier& operator=(const ValidationQueueBarrier&) = delete;

    ~ValidationQueueBarrier() { Release(); }

    void Release()
    {
        if (!m_released.exchange(true)) m_release_promise.set_value();
    }

private:
    std::promise<void> m_release_promise;
    std::shared_future<void> m_release;
    std::atomic<bool> m_released{false};
};

// Blackcoin
/*
// Ensure that fee levels defined in the wallet are at least as high
// as the default levels for node policy.
static_assert(DEFAULT_TRANSACTION_MINFEE >= DEFAULT_MIN_RELAY_TX_FEE, "wallet minimum fee is smaller than default relay fee");
*/

BOOST_FIXTURE_TEST_SUITE(wallet_tests, WalletTestingSetup)

BOOST_AUTO_TEST_CASE(coin_lock_batches_publish_only_after_database_commit)
{
    uint256 first_hash;
    first_hash.SetHex("01");
    uint256 second_hash;
    second_hash.SetHex("02");
    const COutPoint first{first_hash, 0};
    const COutPoint second{second_hash, 1};
    const std::vector<COutPoint> duplicated{first, first, second};
    const std::vector<COutPoint> unique{first, second};

    const auto listed = [](CWallet& wallet) {
        std::vector<COutPoint> result;
        LOCK(wallet.cs_wallet);
        wallet.ListLockedCoins(result);
        return result;
    };

    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& database = GetMockableDatabase(wallet);
    const MockableData empty_records = database.m_records;
    std::string error;

    database.m_fail_begin = true;
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(!wallet.UpdateLockedCoins(
            duplicated, /*lock=*/true, /*persistent=*/true, &error));
        BOOST_CHECK(!wallet.IsLockedCoinsDatabaseAmbiguous());
    }
    BOOST_CHECK(listed(wallet).empty());
    BOOST_CHECK(database.m_records == empty_records);
    database.m_fail_begin = false;

    // A failure on the second unique write rolls the complete request back;
    // the duplicate first outpoint never becomes a third database operation.
    database.m_fail_write_at = 1;
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(!wallet.UpdateLockedCoins(
            duplicated, /*lock=*/true, /*persistent=*/true, &error));
        BOOST_CHECK(!wallet.IsLockedCoinsDatabaseAmbiguous());
    }
    BOOST_CHECK_EQUAL(database.m_write_calls, 2U);
    BOOST_CHECK(listed(wallet).empty());
    BOOST_CHECK(database.m_records == empty_records);
    database.m_fail_write_at.reset();

    {
        LOCK(wallet.cs_wallet);
        BOOST_REQUIRE(wallet.UpdateLockedCoins(
            duplicated, /*lock=*/true, /*persistent=*/true, &error));
    }
    BOOST_CHECK_EQUAL(database.m_write_calls, 2U);
    BOOST_CHECK(listed(wallet) == unique);
    const MockableData locked_records = database.m_records;
    CWallet locked_reload(
        /*chain=*/nullptr, "", DuplicateMockDatabase(database));
    BOOST_REQUIRE_EQUAL(locked_reload.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(listed(locked_reload) == unique);

    database.m_fail_write_at = 1;
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(!wallet.UpdateLockedCoins(
            duplicated, /*lock=*/false, /*persistent=*/true, &error));
        BOOST_CHECK(!wallet.IsLockedCoinsDatabaseAmbiguous());
    }
    BOOST_CHECK_EQUAL(database.m_write_calls, 2U);
    BOOST_CHECK(listed(wallet) == unique);
    BOOST_CHECK(database.m_records == locked_records);
    database.m_fail_write_at.reset();

    {
        LOCK(wallet.cs_wallet);
        BOOST_REQUIRE(wallet.UpdateLockedCoins(
            duplicated, /*lock=*/false, /*persistent=*/true, &error));
    }
    BOOST_CHECK(listed(wallet).empty());
    CWallet unlocked_reload(
        /*chain=*/nullptr, "", DuplicateMockDatabase(database));
    BOOST_REQUIRE_EQUAL(unlocked_reload.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(listed(unlocked_reload).empty());

    // A failed commit is an unknown durable outcome. Memory remains at the
    // exact prestate and every later removal remains closed until reload.
    CWallet ambiguous(
        /*chain=*/nullptr, "", CreateMockableWalletDatabase(locked_records));
    BOOST_REQUIRE_EQUAL(ambiguous.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& ambiguous_database = GetMockableDatabase(ambiguous);
    BOOST_CHECK(listed(ambiguous) == unique);
    ambiguous_database.m_fail_commit = true;
    {
        LOCK(ambiguous.cs_wallet);
        BOOST_CHECK(!ambiguous.UpdateLockedCoins(
            unique, /*lock=*/false, /*persistent=*/true, &error));
        BOOST_CHECK(ambiguous.IsLockedCoinsDatabaseAmbiguous());
        BOOST_CHECK(error.find("reload the wallet") != std::string::npos);
        BOOST_CHECK(!ambiguous.UnlockAllCoins(&error));
    }
    BOOST_CHECK(listed(ambiguous) == unique);
    BOOST_CHECK(ambiguous_database.m_records == locked_records);

    // An indeterminate persistent lock-add is fail-closed for ordinary coin
    // selection too: even if the database commit actually succeeded, the
    // requested coins are immediately restricted in memory until reload.
    CWallet ambiguous_lock(
        /*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(ambiguous_lock.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& ambiguous_lock_database =
        GetMockableDatabase(ambiguous_lock);
    ambiguous_lock_database.m_fail_commit = true;
    {
        LOCK(ambiguous_lock.cs_wallet);
        BOOST_CHECK(!ambiguous_lock.UpdateLockedCoins(
            unique, /*lock=*/true, /*persistent=*/true, &error));
        BOOST_CHECK(ambiguous_lock.IsLockedCoinsDatabaseAmbiguous());
        BOOST_CHECK(ambiguous_lock.IsLockedCoin(first));
        BOOST_CHECK(ambiguous_lock.IsLockedCoin(second));
    }
    BOOST_CHECK(listed(ambiguous_lock) == unique);

    // Unlock-all uses the same transaction-before-publication contract even
    // when persistent and memory-only locks are mixed.
    CWallet mixed(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(mixed.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& mixed_database = GetMockableDatabase(mixed);
    {
        LOCK(mixed.cs_wallet);
        BOOST_REQUIRE(mixed.UpdateLockedCoins(
            {first}, /*lock=*/true, /*persistent=*/true, &error));
        BOOST_REQUIRE(mixed.UpdateLockedCoins(
            {second}, /*lock=*/true, /*persistent=*/false, &error));
    }
    const MockableData mixed_records = mixed_database.m_records;
    mixed_database.m_fail_write_at = 1;
    {
        LOCK(mixed.cs_wallet);
        BOOST_CHECK(!mixed.UnlockAllCoins(&error));
    }
    BOOST_CHECK(listed(mixed) == unique);
    BOOST_CHECK(mixed_database.m_records == mixed_records);
    mixed_database.m_fail_write_at.reset();
    {
        LOCK(mixed.cs_wallet);
        BOOST_REQUIRE(mixed.UnlockAllCoins(&error));
    }
    BOOST_CHECK(listed(mixed).empty());
    CWallet mixed_reload(
        /*chain=*/nullptr, "", DuplicateMockDatabase(mixed_database));
    BOOST_REQUIRE_EQUAL(mixed_reload.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(listed(mixed_reload).empty());
}

BOOST_AUTO_TEST_CASE(address_book_updates_publish_only_after_database_commit)
{
    CKey key;
    key.MakeNewKey(/*fCompressed=*/true);
    const CTxDestination destination{PKHash(key.GetPubKey())};
    using State = std::optional<std::pair<std::string, std::optional<AddressPurpose>>>;
    const auto state = [](const CWallet& wallet, const CTxDestination& dest) -> State {
        LOCK(wallet.cs_wallet);
        const CAddressBookData* entry = wallet.FindAddressBookEntry(dest, /*allow_change=*/true);
        if (!entry || entry->IsChange()) return std::nullopt;
        return std::make_pair(entry->GetLabel(), entry->purpose);
    };

    CWallet seed(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(seed.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(seed.SetAddressBook(destination, "old-label", AddressPurpose::SEND));
    const MockableData durable_old = GetMockableDatabase(seed).m_records;

    enum class FailureStage { BEGIN, PURPOSE_WRITE, NAME_WRITE, ABORT, COMMIT };
    for (const FailureStage stage : {FailureStage::BEGIN, FailureStage::PURPOSE_WRITE,
                                     FailureStage::NAME_WRITE, FailureStage::ABORT,
                                     FailureStage::COMMIT}) {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_old));
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& database = GetMockableDatabase(wallet);
        size_t notifications{0};
        auto connection = wallet.NotifyAddressBookChanged.connect(
            [&](const CTxDestination&, const std::string&, bool, AddressPurpose, ChangeType) { ++notifications; });
        if (stage == FailureStage::BEGIN) database.m_fail_begin = true;
        if (stage == FailureStage::PURPOSE_WRITE) database.m_fail_write_at = 0;
        if (stage == FailureStage::NAME_WRITE) database.m_fail_write_at = 1;
        if (stage == FailureStage::ABORT) {
            database.m_fail_write_at = 0;
            database.m_fail_abort = true;
        }
        if (stage == FailureStage::COMMIT) database.m_fail_commit = true;

        BOOST_CHECK(!wallet.SetAddressBook(destination, "new-label", AddressPurpose::RECEIVE));
        BOOST_CHECK_EQUAL(notifications, 0U);
        BOOST_CHECK(database.m_records == durable_old);
        const State current = state(wallet, destination);
        BOOST_REQUIRE(current);
        BOOST_CHECK_EQUAL(current->first, "old-label");
        BOOST_CHECK(current->second == AddressPurpose::SEND);
        BOOST_CHECK_EQUAL(wallet.IsAddressBookDatabaseAmbiguous(),
                          stage == FailureStage::ABORT || stage == FailureStage::COMMIT);

        CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(database));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        const State reloaded_state = state(reloaded, destination);
        BOOST_REQUIRE(reloaded_state);
        BOOST_CHECK_EQUAL(reloaded_state->first, "old-label");
        BOOST_CHECK(reloaded_state->second == AddressPurpose::SEND);
        BOOST_CHECK(!reloaded.IsAddressBookDatabaseAmbiguous());
        connection.disconnect();
    }

    // Model the other legal interpretation of a false commit result: the
    // database contains the full new state even though the caller cannot know
    // that. Memory and observers remain on the old state until reload.
    CWallet committed_ambiguously(/*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_old));
    BOOST_REQUIRE_EQUAL(committed_ambiguously.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& ambiguous_database = GetMockableDatabase(committed_ambiguously);
    ambiguous_database.m_fail_commit = true;
    ambiguous_database.m_commit_records_on_failure = true;
    size_t ambiguous_notifications{0};
    auto ambiguous_connection = committed_ambiguously.NotifyAddressBookChanged.connect(
        [&](const CTxDestination&, const std::string&, bool, AddressPurpose, ChangeType) { ++ambiguous_notifications; });
    BOOST_CHECK(!committed_ambiguously.SetAddressBook(destination, "new-label", AddressPurpose::RECEIVE));
    BOOST_CHECK_EQUAL(ambiguous_notifications, 0U);
    BOOST_REQUIRE(state(committed_ambiguously, destination));
    BOOST_CHECK_EQUAL(state(committed_ambiguously, destination)->first, "old-label");
    BOOST_REQUIRE(committed_ambiguously.IsAddressBookDatabaseAmbiguous());
    CWallet ambiguously_reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(ambiguous_database));
    BOOST_REQUIRE_EQUAL(ambiguously_reloaded.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(state(ambiguously_reloaded, destination));
    BOOST_CHECK_EQUAL(state(ambiguously_reloaded, destination)->first, "new-label");
    BOOST_CHECK(state(ambiguously_reloaded, destination)->second == AddressPurpose::RECEIVE);
    BOOST_CHECK(!ambiguously_reloaded.IsAddressBookDatabaseAmbiguous());
    ambiguous_connection.disconnect();

    CWallet successful(/*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_old));
    BOOST_REQUIRE_EQUAL(successful.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& successful_database = GetMockableDatabase(successful);
    size_t notifications{0};
    auto connection = successful.NotifyAddressBookChanged.connect(
        [&](const CTxDestination& notified_destination, const std::string& label,
            bool is_mine, AddressPurpose purpose, ChangeType status) {
            BOOST_CHECK(notified_destination == destination);
            BOOST_CHECK_EQUAL(label, "new-label");
            BOOST_CHECK(!is_mine);
            BOOST_CHECK(purpose == AddressPurpose::RECEIVE);
            BOOST_CHECK(status == CT_UPDATED);
            BOOST_CHECK_EQUAL(successful_database.m_commit_calls, 1U);
            ++notifications;
        });
    auto throwing_connection = successful.NotifyAddressBookChanged.connect(
        [](const CTxDestination&, const std::string&, bool,
           AddressPurpose, ChangeType) {
            throw std::runtime_error{"observer failure"};
        });
    BOOST_REQUIRE(successful.SetAddressBook(destination, "new-label", AddressPurpose::RECEIVE));
    BOOST_CHECK(!successful_database.m_last_txn_durable);
    BOOST_CHECK_EQUAL(successful_database.m_write_calls, 2U);
    BOOST_CHECK_EQUAL(notifications, 1U);
    CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(successful_database));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    const State reloaded_state = state(reloaded, destination);
    BOOST_REQUIRE(reloaded_state);
    BOOST_CHECK_EQUAL(reloaded_state->first, "new-label");
    BOOST_CHECK(reloaded_state->second == AddressPurpose::RECEIVE);
    throwing_connection.disconnect();
    connection.disconnect();
}

BOOST_AUTO_TEST_CASE(address_book_deletion_is_atomic)
{
    CKey key;
    key.MakeNewKey(/*fCompressed=*/true);
    const CTxDestination destination{PKHash(key.GetPubKey())};
    const auto has_entry = [&](const CWallet& wallet) {
        LOCK(wallet.cs_wallet);
        return wallet.FindAddressBookEntry(destination, /*allow_change=*/true) != nullptr;
    };
    CWallet seed(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(seed.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(seed.SetAddressBook(destination, "delete-me", AddressPurpose::SEND));
    const MockableData durable_entry = GetMockableDatabase(seed).m_records;

    enum class FailureStage { BEGIN, ERASE_DATA, ERASE_PURPOSE, ERASE_NAME, ABORT, COMMIT };
    for (const FailureStage stage : {
             FailureStage::BEGIN, FailureStage::ERASE_DATA,
             FailureStage::ERASE_PURPOSE, FailureStage::ERASE_NAME,
             FailureStage::ABORT, FailureStage::COMMIT}) {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_entry));
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& database = GetMockableDatabase(wallet);
        if (stage == FailureStage::BEGIN) database.m_fail_begin = true;
        if (stage >= FailureStage::ERASE_DATA && stage <= FailureStage::ERASE_NAME) {
            database.m_fail_write_at = static_cast<size_t>(stage) - static_cast<size_t>(FailureStage::ERASE_DATA);
        }
        if (stage == FailureStage::ABORT) {
            database.m_fail_write_at = 0;
            database.m_fail_abort = true;
        }
        if (stage == FailureStage::COMMIT) database.m_fail_commit = true;
        size_t notifications{0};
        auto connection = wallet.NotifyAddressBookChanged.connect(
            [&](const CTxDestination&, const std::string&, bool, AddressPurpose, ChangeType) { ++notifications; });
        BOOST_CHECK(!wallet.DelAddressBook(destination));
        BOOST_CHECK(has_entry(wallet));
        BOOST_CHECK(database.m_records == durable_entry);
        BOOST_CHECK_EQUAL(notifications, 0U);
        BOOST_CHECK_EQUAL(wallet.IsAddressBookDatabaseAmbiguous(),
                          stage == FailureStage::ABORT || stage == FailureStage::COMMIT);
        CWallet reloaded(
            /*chain=*/nullptr, "", DuplicateMockDatabase(database));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        BOOST_CHECK(has_entry(reloaded));
        BOOST_CHECK(!reloaded.IsAddressBookDatabaseAmbiguous());
        connection.disconnect();
    }

    CWallet committed_ambiguously(
        /*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_entry));
    BOOST_REQUIRE_EQUAL(
        committed_ambiguously.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& ambiguous_database =
        GetMockableDatabase(committed_ambiguously);
    ambiguous_database.m_fail_commit = true;
    ambiguous_database.m_commit_records_on_failure = true;
    size_t ambiguous_notifications{0};
    auto ambiguous_connection =
        committed_ambiguously.NotifyAddressBookChanged.connect(
            [&](const CTxDestination&, const std::string&, bool,
                AddressPurpose, ChangeType) {
                ++ambiguous_notifications;
            });
    BOOST_CHECK(!committed_ambiguously.DelAddressBook(destination));
    BOOST_CHECK(has_entry(committed_ambiguously));
    BOOST_CHECK_EQUAL(ambiguous_notifications, 0U);
    BOOST_CHECK(committed_ambiguously.IsAddressBookDatabaseAmbiguous());
    CWallet ambiguously_reloaded(
        /*chain=*/nullptr, "", DuplicateMockDatabase(ambiguous_database));
    BOOST_REQUIRE_EQUAL(
        ambiguously_reloaded.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(!has_entry(ambiguously_reloaded));
    BOOST_CHECK(!ambiguously_reloaded.IsAddressBookDatabaseAmbiguous());
    ambiguous_connection.disconnect();

    CWallet successful(/*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_entry));
    BOOST_REQUIRE_EQUAL(successful.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(successful.DelAddressBook(destination));
    BOOST_CHECK(!GetMockableDatabase(successful).m_last_txn_durable);
    BOOST_CHECK(!has_entry(successful));
    CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(successful.GetDatabase()));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(!has_entry(reloaded));
}

BOOST_AUTO_TEST_CASE(address_book_move_is_atomic)
{
    CKey old_key;
    CKey new_key;
    old_key.MakeNewKey(/*fCompressed=*/true);
    new_key.MakeNewKey(/*fCompressed=*/true);
    const CTxDestination old_destination{PKHash(old_key.GetPubKey())};
    const CTxDestination new_destination{PKHash(new_key.GetPubKey())};
    const auto state = [](const CWallet& wallet, const CTxDestination& dest) {
        LOCK(wallet.cs_wallet);
        const CAddressBookData* entry = wallet.FindAddressBookEntry(dest, /*allow_change=*/true);
        return entry && !entry->IsChange()
            ? std::optional<std::pair<std::string, std::optional<AddressPurpose>>>{{entry->GetLabel(), entry->purpose}}
            : std::nullopt;
    };

    CWallet seed(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(seed.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(seed.SetAddressBook(old_destination, "preserved-label", AddressPurpose::SEND));
    const MockableData durable_old = GetMockableDatabase(seed).m_records;

    enum class FailureStage { BEGIN, WRITE_PURPOSE, WRITE_NAME, ERASE_DATA, ERASE_PURPOSE, ERASE_NAME, ABORT, COMMIT };
    for (const FailureStage stage : {
             FailureStage::BEGIN, FailureStage::WRITE_PURPOSE,
             FailureStage::WRITE_NAME, FailureStage::ERASE_DATA,
             FailureStage::ERASE_PURPOSE, FailureStage::ERASE_NAME,
             FailureStage::ABORT,
             FailureStage::COMMIT}) {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_old));
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& database = GetMockableDatabase(wallet);
        size_t notifications{0};
        auto connection = wallet.NotifyAddressBookChanged.connect(
            [&](const CTxDestination&, const std::string&, bool, AddressPurpose, ChangeType) { ++notifications; });
        if (stage == FailureStage::BEGIN) database.m_fail_begin = true;
        if (stage >= FailureStage::WRITE_PURPOSE && stage <= FailureStage::ERASE_NAME) {
            database.m_fail_write_at = static_cast<size_t>(stage) - static_cast<size_t>(FailureStage::WRITE_PURPOSE);
        }
        if (stage == FailureStage::ABORT) {
            database.m_fail_write_at = 0;
            database.m_fail_abort = true;
        }
        if (stage == FailureStage::COMMIT) database.m_fail_commit = true;

        BOOST_CHECK(!wallet.MoveAddressBook(old_destination, new_destination));
        BOOST_CHECK_EQUAL(notifications, 0U);
        BOOST_CHECK(database.m_records == durable_old);
        BOOST_REQUIRE(state(wallet, old_destination));
        BOOST_CHECK_EQUAL(state(wallet, old_destination)->first, "preserved-label");
        BOOST_CHECK(!state(wallet, new_destination));
        BOOST_CHECK_EQUAL(wallet.IsAddressBookDatabaseAmbiguous(),
                          stage == FailureStage::ABORT || stage == FailureStage::COMMIT);

        CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(database));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        BOOST_REQUIRE(state(reloaded, old_destination));
        BOOST_CHECK(!state(reloaded, new_destination));
        connection.disconnect();
    }

    CWallet committed_ambiguously(/*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_old));
    BOOST_REQUIRE_EQUAL(committed_ambiguously.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& ambiguous_database = GetMockableDatabase(committed_ambiguously);
    ambiguous_database.m_fail_commit = true;
    ambiguous_database.m_commit_records_on_failure = true;
    size_t ambiguous_notifications{0};
    auto ambiguous_connection = committed_ambiguously.NotifyAddressBookChanged.connect(
        [&](const CTxDestination&, const std::string&, bool, AddressPurpose, ChangeType) { ++ambiguous_notifications; });
    BOOST_CHECK(!committed_ambiguously.MoveAddressBook(
        old_destination, new_destination));
    BOOST_CHECK_EQUAL(ambiguous_notifications, 0U);
    BOOST_REQUIRE(state(committed_ambiguously, old_destination));
    BOOST_CHECK(!state(committed_ambiguously, new_destination));
    BOOST_REQUIRE(committed_ambiguously.IsAddressBookDatabaseAmbiguous());
    CWallet ambiguously_reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(ambiguous_database));
    BOOST_REQUIRE_EQUAL(ambiguously_reloaded.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(!state(ambiguously_reloaded, old_destination));
    BOOST_REQUIRE(state(ambiguously_reloaded, new_destination));
    BOOST_CHECK_EQUAL(state(ambiguously_reloaded, new_destination)->first, "preserved-label");
    BOOST_CHECK(!ambiguously_reloaded.IsAddressBookDatabaseAmbiguous());
    ambiguous_connection.disconnect();

    CWallet successful(/*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_old));
    BOOST_REQUIRE_EQUAL(successful.LoadWallet(), DBErrors::LOAD_OK);
    std::vector<std::pair<CTxDestination, ChangeType>> notifications;
    auto connection = successful.NotifyAddressBookChanged.connect(
        [&](const CTxDestination& dest, const std::string&, bool, AddressPurpose, ChangeType status) {
            BOOST_CHECK_EQUAL(GetMockableDatabase(successful).m_commit_calls, 1U);
            notifications.emplace_back(dest, status);
    });
    size_t throwing_notifications{0};
    auto throwing_connection = successful.NotifyAddressBookChanged.connect(
        [&](const CTxDestination&, const std::string&, bool,
            AddressPurpose, ChangeType status) {
            ++throwing_notifications;
            if (status == CT_DELETED) {
                throw std::runtime_error{"observer failure"};
            }
        });
    BOOST_REQUIRE(successful.MoveAddressBook(old_destination, new_destination));
    BOOST_CHECK(!GetMockableDatabase(successful).m_last_txn_durable);
    BOOST_REQUIRE_EQUAL(notifications.size(), 2U);
    BOOST_CHECK_EQUAL(throwing_notifications, 2U);
    BOOST_CHECK(notifications[0] == std::make_pair(old_destination, CT_DELETED));
    BOOST_CHECK(notifications[1] == std::make_pair(new_destination, CT_NEW));
    BOOST_CHECK(!state(successful, old_destination));
    BOOST_REQUIRE(state(successful, new_destination));
    BOOST_CHECK_EQUAL(state(successful, new_destination)->first, "preserved-label");
    CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(successful.GetDatabase()));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(!state(reloaded, old_destination));
    BOOST_REQUIRE(state(reloaded, new_destination));
    BOOST_CHECK_EQUAL(state(reloaded, new_destination)->first, "preserved-label");
    BOOST_CHECK(state(reloaded, new_destination)->second == AddressPurpose::SEND);
    throwing_connection.disconnect();
    connection.disconnect();

    // A UI may have captured the old entry before another writer changes it.
    // Move accepts only the destinations and therefore preserves the current
    // authoritative label and purpose under cs_wallet, not stale UI values.
    CWallet changed_after_snapshot(
        /*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_old));
    BOOST_REQUIRE_EQUAL(
        changed_after_snapshot.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(changed_after_snapshot.SetAddressBook(
        old_destination, "authoritative-after-snapshot",
        AddressPurpose::RECEIVE));
    BOOST_REQUIRE(changed_after_snapshot.MoveAddressBook(
        old_destination, new_destination));
    BOOST_CHECK(!state(changed_after_snapshot, old_destination));
    BOOST_REQUIRE(state(changed_after_snapshot, new_destination));
    BOOST_CHECK_EQUAL(
        state(changed_after_snapshot, new_destination)->first,
        "authoritative-after-snapshot");
    BOOST_CHECK(
        state(changed_after_snapshot, new_destination)->second ==
        AddressPurpose::RECEIVE);

    CWallet purpose_less(
        /*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(purpose_less.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(purpose_less.SetAddressBook(
        old_destination, "purpose-less", std::nullopt));
    BOOST_REQUIRE(purpose_less.MoveAddressBook(
        old_destination, new_destination));
    BOOST_REQUIRE(state(purpose_less, new_destination));
    BOOST_CHECK(!state(purpose_less, new_destination)->second);
    CWallet purpose_less_reload(
        /*chain=*/nullptr, "",
        DuplicateMockDatabase(purpose_less.GetDatabase()));
    BOOST_REQUIRE_EQUAL(
        purpose_less_reload.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(state(purpose_less_reload, new_destination));
    BOOST_CHECK(!state(purpose_less_reload, new_destination)->second);

    CWallet existing_new(/*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_old));
    BOOST_REQUIRE_EQUAL(existing_new.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(existing_new.SetAddressBook(new_destination, "existing", AddressPurpose::SEND));
    BOOST_CHECK(!existing_new.MoveAddressBook(old_destination, new_destination));
    BOOST_REQUIRE(state(existing_new, old_destination));
    BOOST_REQUIRE(state(existing_new, new_destination));
    BOOST_CHECK_EQUAL(state(existing_new, new_destination)->first, "existing");

    CWallet owned_new(/*chain=*/nullptr, "", CreateMockableWalletDatabase(durable_old));
    BOOST_REQUIRE_EQUAL(owned_new.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(owned_new.cs_wallet);
        owned_new.SetupLegacyScriptPubKeyMan();
        BOOST_REQUIRE(owned_new.GetOrCreateLegacyScriptPubKeyMan()->AddKeyPubKey(new_key, new_key.GetPubKey()));
    }
    BOOST_CHECK(!owned_new.MoveAddressBook(old_destination, new_destination));
    BOOST_REQUIRE(state(owned_new, old_destination));
    BOOST_CHECK(!state(owned_new, new_destination));
}

#ifdef USE_BDB
BOOST_AUTO_TEST_CASE(address_book_delete_and_move_join_berkeley_transaction)
{
    const fs::path database_path{m_path_root / "address_book_berkeley"};
    const auto make_database = [&]() {
        DatabaseOptions options;
        DatabaseStatus status;
        bilingual_str error;
        auto database = MakeBerkeleyDatabase(database_path, options, status, error);
        if (!database) throw std::runtime_error(error.original);
        return database;
    };

    CKey old_key;
    CKey moved_key;
    CKey deleted_key;
    old_key.MakeNewKey(/*fCompressed=*/true);
    moved_key.MakeNewKey(/*fCompressed=*/true);
    deleted_key.MakeNewKey(/*fCompressed=*/true);
    const CTxDestination old_destination{PKHash(old_key.GetPubKey())};
    const CTxDestination moved_destination{PKHash(moved_key.GetPubKey())};
    const CTxDestination deleted_destination{PKHash(deleted_key.GetPubKey())};

    {
        CWallet wallet(/*chain=*/nullptr, "bdb-address-book", make_database());
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        BOOST_REQUIRE(wallet.SetAddressBook(
            old_destination, "move-label", AddressPurpose::SEND));
        BOOST_REQUIRE(wallet.SetAddressBook(
            deleted_destination, "delete-label", AddressPurpose::SEND));
        BOOST_REQUIRE(wallet.MoveAddressBook(
            old_destination, moved_destination));
        BOOST_REQUIRE(wallet.DelAddressBook(deleted_destination));
    }

    CWallet reloaded(/*chain=*/nullptr, "bdb-address-book", make_database());
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(reloaded.cs_wallet);
        BOOST_CHECK(reloaded.FindAddressBookEntry(
            old_destination, /*allow_change=*/true) == nullptr);
        BOOST_CHECK(reloaded.FindAddressBookEntry(
            deleted_destination, /*allow_change=*/true) == nullptr);
        const CAddressBookData* moved_entry = reloaded.FindAddressBookEntry(
            moved_destination, /*allow_change=*/true);
        BOOST_REQUIRE(moved_entry);
        BOOST_CHECK_EQUAL(moved_entry->GetLabel(), "move-label");
        BOOST_CHECK(moved_entry->purpose == AddressPurpose::SEND);
    }
}
#endif

BOOST_AUTO_TEST_CASE(imported_script_labels_use_one_caller_owned_transaction)
{
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
    { LOCK(wallet.cs_wallet); wallet.SetupLegacyScriptPubKeyMan(); }
    CKey first_key;
    CKey second_key;
    first_key.MakeNewKey(/*fCompressed=*/true);
    second_key.MakeNewKey(/*fCompressed=*/true);
    const CTxDestination first{PKHash(first_key.GetPubKey())};
    const CTxDestination second{PKHash(second_key.GetPubKey())};
    const std::set<CScript> scripts{GetScriptForDestination(first), GetScriptForDestination(second)};
    size_t notifications{0};
    auto connection = wallet.NotifyAddressBookChanged.connect(
        [&](const CTxDestination&, const std::string&, bool, AddressPurpose, ChangeType) { ++notifications; });
    BOOST_REQUIRE(wallet.ImportScriptPubKeys("imported-label", scripts,
        /*have_solving_data=*/false, /*apply_label=*/true, GetTime()));
    MockableDatabase& database = GetMockableDatabase(wallet);
    BOOST_CHECK(!database.m_last_txn_durable);
    BOOST_CHECK_EQUAL(database.m_write_calls, 4U);
    BOOST_CHECK_EQUAL(notifications, 2U);
    CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(database));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    for (const CTxDestination& dest : {first, second}) {
        LOCK(reloaded.cs_wallet);
        const CAddressBookData* entry = reloaded.FindAddressBookEntry(dest);
        BOOST_REQUIRE(entry);
        BOOST_CHECK_EQUAL(entry->GetLabel(), "imported-label");
    }
    connection.disconnect();

    // Script persistence intentionally precedes the label transaction. A
    // label failure must be reported without publishing labels, while reload
    // still recovers the already-imported watch-only scripts.
    for (const bool fail_begin : {true, false}) {
        CWallet failed(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(failed.LoadWallet(), DBErrors::LOAD_OK);
        {
            LOCK(failed.cs_wallet);
            failed.SetupLegacyScriptPubKeyMan();
        }
        MockableDatabase& failed_database = GetMockableDatabase(failed);
        failed_database.m_fail_begin = fail_begin;
        failed_database.m_fail_commit = !fail_begin;
        size_t failed_notifications{0};
        auto failed_connection = failed.NotifyAddressBookChanged.connect(
            [&](const CTxDestination&, const std::string&, bool,
                AddressPurpose, ChangeType) {
                ++failed_notifications;
            });
        BOOST_CHECK(!failed.ImportScriptPubKeys(
            "failed-label", scripts, /*have_solving_data=*/false,
            /*apply_label=*/true, GetTime()));
        BOOST_CHECK_EQUAL(failed_notifications, 0U);
        BOOST_CHECK_EQUAL(failed.IsAddressBookDatabaseAmbiguous(),
                          !fail_begin);
        for (const CScript& script : scripts) {
            BOOST_CHECK(WITH_LOCK(
                failed.cs_wallet,
                return failed.IsMine(script) != ISMINE_NO));
        }
        BOOST_CHECK(WITH_LOCK(
            failed.cs_wallet, return failed.m_address_book.empty()));

        failed_database.m_fail_begin = false;
        failed_database.m_fail_commit = false;
        CWallet failed_reload(
            /*chain=*/nullptr, "", DuplicateMockDatabase(failed_database));
        BOOST_REQUIRE_EQUAL(failed_reload.LoadWallet(), DBErrors::LOAD_OK);
        for (const CScript& script : scripts) {
            BOOST_CHECK(WITH_LOCK(
                failed_reload.cs_wallet,
                return failed_reload.IsMine(script) != ISMINE_NO));
        }
        BOOST_CHECK(WITH_LOCK(
            failed_reload.cs_wallet,
            return failed_reload.m_address_book.empty()));
        BOOST_CHECK(!failed_reload.IsAddressBookDatabaseAmbiguous());
        failed_connection.disconnect();
    }

    CWallet applied(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(applied.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(applied.cs_wallet);
        applied.SetupLegacyScriptPubKeyMan();
    }
    MockableDatabase& applied_database = GetMockableDatabase(applied);
    applied_database.m_fail_commit = true;
    applied_database.m_commit_records_on_failure = true;
    size_t applied_notifications{0};
    auto applied_connection = applied.NotifyAddressBookChanged.connect(
        [&](const CTxDestination&, const std::string&, bool,
            AddressPurpose, ChangeType) {
            ++applied_notifications;
        });
    BOOST_CHECK(!applied.ImportScriptPubKeys(
        "applied-label", scripts, /*have_solving_data=*/false,
        /*apply_label=*/true, GetTime()));
    BOOST_CHECK_EQUAL(applied_notifications, 0U);
    BOOST_CHECK(applied.IsAddressBookDatabaseAmbiguous());
    BOOST_CHECK(WITH_LOCK(
        applied.cs_wallet, return applied.m_address_book.empty()));
    applied_database.m_fail_commit = false;
    applied_database.m_commit_records_on_failure = false;
    CWallet applied_reload(
        /*chain=*/nullptr, "", DuplicateMockDatabase(applied_database));
    BOOST_REQUIRE_EQUAL(applied_reload.LoadWallet(), DBErrors::LOAD_OK);
    for (const CTxDestination& dest : {first, second}) {
        const CAddressBookData* entry = WITH_LOCK(
            applied_reload.cs_wallet,
            return applied_reload.FindAddressBookEntry(dest));
        BOOST_REQUIRE(entry);
        BOOST_CHECK_EQUAL(entry->GetLabel(), "applied-label");
    }
    BOOST_CHECK(!applied_reload.IsAddressBookDatabaseAmbiguous());
    applied_connection.disconnect();
}

BOOST_AUTO_TEST_CASE(descriptor_import_reports_durable_partial_label_state)
{
    CKey key;
    key.MakeNewKey(/*fCompressed=*/true);
    FlatSigningProvider provider;
    std::string parse_error;
    std::unique_ptr<Descriptor> descriptor = Parse(
        "combo(" + EncodeSecret(key) + ")", provider, parse_error,
        /*require_checksum=*/false);
    BOOST_REQUIRE_MESSAGE(descriptor, parse_error);
    WalletDescriptor wallet_descriptor(
        std::move(descriptor), /*creation_time=*/1,
        /*range_start=*/0, /*range_end=*/1, /*next_index=*/0);

    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(wallet.cs_wallet);
        wallet.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
    }
    MockableDatabase& database = GetMockableDatabase(wallet);
    database.m_fail_write_at = 0;
    bilingual_str error;
    ScriptPubKeyMan* failed_manager;
    {
        LOCK(wallet.cs_wallet);
        failed_manager = wallet.AddWalletDescriptor(
            wallet_descriptor, provider, "descriptor-label",
            /*internal=*/false, &error);
    }
    BOOST_CHECK(failed_manager == nullptr);
    BOOST_CHECK(error.original.find("descriptor, keys, and script cache were stored") != std::string::npos);
    BOOST_REQUIRE(WITH_LOCK(
        wallet.cs_wallet,
        return wallet.GetDescriptorScriptPubKeyMan(wallet_descriptor) !=
               nullptr));
    BOOST_CHECK(WITH_LOCK(
        wallet.cs_wallet, return wallet.m_address_book.empty()));
    BOOST_CHECK(!wallet.IsAddressBookDatabaseAmbiguous());

    // The reported partial result is real: reload recovers the descriptor,
    // but no label from the failed all-or-nothing label transaction.
    database.m_fail_write_at.reset();
    CWallet reloaded(
        /*chain=*/nullptr, "", DuplicateMockDatabase(database));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(reloaded.cs_wallet);
        BOOST_REQUIRE(
            reloaded.GetDescriptorScriptPubKeyMan(wallet_descriptor) != nullptr);
        BOOST_CHECK(reloaded.m_address_book.empty());
    }

    size_t notifications{0};
    auto connection = reloaded.NotifyAddressBookChanged.connect(
        [&](const CTxDestination&, const std::string&, bool,
            AddressPurpose, ChangeType) { ++notifications; });
    ScriptPubKeyMan* retried_manager;
    error.clear();
    {
        LOCK(reloaded.cs_wallet);
        retried_manager = reloaded.AddWalletDescriptor(
            wallet_descriptor, provider, "descriptor-label",
            /*internal=*/false, &error);
        BOOST_REQUIRE(retried_manager);
    }
    const auto scripts =
        static_cast<DescriptorScriptPubKeyMan*>(retried_manager)
            ->GetScriptPubKeys();
    BOOST_REQUIRE(!scripts.empty());
    BOOST_CHECK_EQUAL(notifications, scripts.size());
    for (const CScript& script : scripts) {
        CTxDestination destination;
        if (!ExtractDestination(script, destination)) continue;
        LOCK(reloaded.cs_wallet);
        const CAddressBookData* entry =
            reloaded.FindAddressBookEntry(destination);
        BOOST_REQUIRE(entry);
        BOOST_CHECK_EQUAL(entry->GetLabel(), "descriptor-label");
        BOOST_CHECK(entry->purpose == AddressPurpose::RECEIVE);
    }

    CWallet final_reload(
        /*chain=*/nullptr, "", DuplicateMockDatabase(reloaded.GetDatabase()));
    BOOST_REQUIRE_EQUAL(final_reload.LoadWallet(), DBErrors::LOAD_OK);
    for (const CScript& script : scripts) {
        CTxDestination destination;
        if (!ExtractDestination(script, destination)) continue;
        LOCK(final_reload.cs_wallet);
        const CAddressBookData* entry =
            final_reload.FindAddressBookEntry(destination);
        BOOST_REQUIRE(entry);
        BOOST_CHECK_EQUAL(entry->GetLabel(), "descriptor-label");
    }
    connection.disconnect();

    // A false commit can mean that the complete label transaction actually
    // reached disk. Keep memory and observers unpublished, latch ambiguity,
    // and let reload select the database's authoritative outcome.
    CWallet ambiguous(
        /*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(ambiguous.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(ambiguous.cs_wallet);
        ambiguous.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
    }
    MockableDatabase& ambiguous_database = GetMockableDatabase(ambiguous);
    ambiguous_database.m_fail_commit = true;
    ambiguous_database.m_commit_records_on_failure = true;
    size_t ambiguous_notifications{0};
    auto ambiguous_connection =
        ambiguous.NotifyAddressBookChanged.connect(
            [&](const CTxDestination&, const std::string&, bool,
                AddressPurpose, ChangeType) { ++ambiguous_notifications; });
    error.clear();
    {
        LOCK(ambiguous.cs_wallet);
        BOOST_CHECK(ambiguous.AddWalletDescriptor(
                        wallet_descriptor, provider, "ambiguous-label",
                        /*internal=*/false, &error) == nullptr);
    }
    BOOST_CHECK(error.original.find("commit outcome is uncertain") !=
                std::string::npos);
    BOOST_CHECK(ambiguous.IsAddressBookDatabaseAmbiguous());
    BOOST_CHECK(WITH_LOCK(
        ambiguous.cs_wallet, return ambiguous.m_address_book.empty()));
    BOOST_CHECK_EQUAL(ambiguous_notifications, 0U);
    ambiguous_database.m_fail_commit = false;
    ambiguous_database.m_commit_records_on_failure = false;
    CWallet ambiguous_reload(
        /*chain=*/nullptr, "", DuplicateMockDatabase(ambiguous_database));
    BOOST_REQUIRE_EQUAL(ambiguous_reload.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(!ambiguous_reload.IsAddressBookDatabaseAmbiguous());
    BOOST_CHECK(!WITH_LOCK(
        ambiguous_reload.cs_wallet,
        return ambiguous_reload.m_address_book.empty()));
    ambiguous_connection.disconnect();
}

BOOST_AUTO_TEST_CASE(address_book_ambiguity_blocks_automatic_payout_binding)
{
    ScopedArgsSettings args_guard;
    args_guard.Unset("-qqpowpayoutaddress");
    args_guard.Unset("-qqpospayoutaddress");
    args_guard.Unset("-qqallowautokeycreation");
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
    auto destination = wallet.GetNewQuantumDestination("PoW - Quantum Claim Address");
    BOOST_REQUIRE(destination);
    MockableDatabase& database = GetMockableDatabase(wallet);
    database.m_fail_commit = true;
    BOOST_CHECK(!wallet.SetAddressBook(*destination, "uncertain-label", AddressPurpose::RECEIVE));
    BOOST_REQUIRE(wallet.IsAddressBookDatabaseAmbiguous());
    bilingual_str error;
    bool created{true};
    BOOST_CHECK(!wallet.EnsurePowPayoutAddress(error, &created));
    BOOST_CHECK(!created);
    BOOST_CHECK(error.original.find("uncertain database outcome") != std::string::npos);
    BOOST_CHECK(WITH_LOCK(wallet.cs_wallet, return wallet.m_pow_payout_quantum.empty()));
    CScript script;
    std::string address;
    error.clear();
    BOOST_CHECK(!wallet.EnsureShadowSignalPayoutAddress(script, address, error, &created));
    BOOST_CHECK(script.empty());
    BOOST_CHECK(address.empty());
    BOOST_CHECK(error.original.find("uncertain database outcome") != std::string::npos);
}

BOOST_AUTO_TEST_CASE(restored_label_failure_does_not_block_transaction_sync)
{
    CWallet wallet(m_node.chain.get(), "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);

    CTxDestination destination;
    {
        LOCK(wallet.cs_wallet);
        wallet.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
        wallet.SetupDescriptorScriptPubKeyMans();
        auto* manager = dynamic_cast<DescriptorScriptPubKeyMan*>(
            wallet.GetScriptPubKeyMan(OutputType::BECH32, /*internal=*/false));
        BOOST_REQUIRE(manager);
        const auto scripts = manager->GetScriptPubKeys();
        BOOST_REQUIRE(!scripts.empty());
        BOOST_REQUIRE(ExtractDestination(*scripts.begin(), destination));
        BOOST_CHECK(wallet.FindAddressBookEntry(destination) == nullptr);
    }

    size_t notifications{0};
    auto connection = wallet.NotifyAddressBookChanged.connect(
        [&](const CTxDestination&, const std::string&, bool,
            AddressPurpose, ChangeType) { ++notifications; });

    MockableDatabase& database = GetMockableDatabase(wallet);
    database.m_fail_commit = true;
    CMutableTransaction transaction;
    transaction.vin.emplace_back(COutPoint{uint256::ONE, 0});
    transaction.vout.emplace_back(
        COIN, GetScriptForDestination(destination));
    const CTransactionRef transaction_ref =
        MakeTransactionRef(std::move(transaction));

    BOOST_CHECK_NO_THROW(wallet.transactionAddedToMempool(transaction_ref));
    BOOST_CHECK(wallet.IsAddressBookDatabaseAmbiguous());
    BOOST_CHECK_EQUAL(notifications, 0U);
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(wallet.FindAddressBookEntry(destination) == nullptr);
        const CWalletTx* wallet_tx = wallet.GetWalletTx(transaction_ref->GetHash());
        BOOST_REQUIRE(wallet_tx);
        BOOST_CHECK_EQUAL(
            CachedTxGetAvailableCredit(wallet, *wallet_tx), COIN);
        BOOST_CHECK(wallet.GetLiveUnspentStakeOutpoints().count(
                        COutPoint{transaction_ref->GetHash(), 0}) != 0);
    }

    // Reload discards the process-local ambiguity latch while retaining the
    // authoritative transaction and the database's rolled-back label state.
    database.m_fail_commit = false;
    CWallet reloaded(
        m_node.chain.get(), "", DuplicateMockDatabase(database));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(!reloaded.IsAddressBookDatabaseAmbiguous());
    {
        LOCK(reloaded.cs_wallet);
        BOOST_CHECK(reloaded.FindAddressBookEntry(destination) == nullptr);
        const CWalletTx* wallet_tx =
            reloaded.GetWalletTx(transaction_ref->GetHash());
        BOOST_REQUIRE(wallet_tx);
        BOOST_CHECK_EQUAL(
            CachedTxGetAvailableCredit(reloaded, *wallet_tx), COIN);
    }
    connection.disconnect();
}

BOOST_AUTO_TEST_CASE(staking_autostart_requires_and_preserves_explicit_consent)
{
    ScopedArgsSettings args_guard;
    args_guard.Unset("-staking");
    args_guard.Unset("-autostartstaking");
    BOOST_CHECK(!IsStakingAutostartEnabled());

    args_guard.Force("-staking", "1");
    BOOST_CHECK(IsStakingAutostartEnabled());

    args_guard.Force("-autostartstaking", "0");
    BOOST_CHECK(!IsStakingAutostartEnabled());

    args_guard.Force("-autostartstaking", "1");
    BOOST_CHECK(IsStakingAutostartEnabled());

    args_guard.Unset("-autostartstaking");
    args_guard.Force("-staking", "0");
    BOOST_CHECK(!IsStakingAutostartEnabled());
}

BOOST_AUTO_TEST_CASE(hidden_quantum_key_actions_require_consent_without_wallet_delta)
{
    const auto key_count = [&] {
        return WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size());
    };
    const auto tx_count = [&] {
        return WITH_LOCK(m_wallet.cs_wallet, return m_wallet.mapWallet.size());
    };
    const size_t keys_before = key_count();
    const size_t txs_before = tx_count();
    const auto check_rejected_without_delta = [&](const auto& result) {
        BOOST_CHECK(!result);
        BOOST_CHECK(util::ErrorString(result).original.find("allow_new_quantum_key=true") != std::string::npos);
        BOOST_CHECK_EQUAL(key_count(), keys_before);
        BOOST_CHECK_EQUAL(tx_count(), txs_before);
    };

    check_rejected_without_delta(FundTieredStakeAddress(
        m_wallet, "unused", 1, /*require_operator_lock=*/false,
        "test", /*allow_new_quantum_key=*/false));
    check_rejected_without_delta(WithdrawTieredStakeAddress(
        m_wallet, "unused", /*require_operator_lock=*/false,
        "unbond", "withdraw", "test", "test", std::nullopt,
        /*allow_all_outputs=*/false, /*allow_new_quantum_key=*/false));
    check_rejected_without_delta(FundColdStakeDelegationAddress(
        m_wallet, "unused", 1, /*allow_goldrush_migration=*/true,
        /*allow_new_quantum_key=*/false));
    check_rejected_without_delta(WithdrawColdStakeDelegationAddress(
        m_wallet, "unused", std::nullopt, /*allow_all_outputs=*/false,
        /*allow_new_quantum_key=*/false));
    check_rejected_without_delta(CreateQuantumMigrationSweep(
        m_wallet, /*goldrush_rewards_only=*/false,
        /*allow_goldrush_epoch=*/false, /*destination_label=*/"",
        /*comment_override=*/"", /*allow_new_quantum_key=*/false));

    QuantumColdStakeRedelegationOptions options;
    options.dry_run = false;
    options.allow_new_quantum_key = false;
    QuantumColdStakeRedelegationResult redelegation;
    bilingual_str error;
    BOOST_CHECK(!CreateQuantumColdStakeRedelegationTransaction(
        m_wallet, CNoDestination{}, {}, options, redelegation, error));
    BOOST_CHECK(error.original.find("allow_new_quantum_key=true") != std::string::npos);
    BOOST_CHECK_EQUAL(key_count(), keys_before);
    BOOST_CHECK_EQUAL(tx_count(), txs_before);
}

class TieredUnbondingAddressBookFailureSetup : public TestChain100Setup
{
public:
    TieredUnbondingAddressBookFailureSetup()
        : TestChain100Setup{ChainType::REGTEST, {
              "-shadowwhitelistheight=99",
              "-shadowgoldrushstartheight=100",
              "-shadowgoldrushendheight=100",
              "-qqgoldrushendheight=100",
              "-qqmigrationendheight=200",
              "-qqstaketierheight=101",
          }}
    {
    }
};

BOOST_FIXTURE_TEST_CASE(
    tiered_unbonding_label_failure_reports_durable_change_key,
    TieredUnbondingAddressBookFailureSetup)
{
    const auto distinct_key_count = [](const CWallet& wallet) {
        std::set<std::vector<unsigned char>> public_keys;
        for (const QuantumKeyInfo& info : WITH_LOCK(
                 wallet.cs_wallet, return wallet.ListQuantumKeyInfos())) {
            public_keys.insert(info.public_key);
        }
        return public_keys.size();
    };
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return Assert(m_node.chainman)->ActiveChain()),
        coinbaseKey);

    constexpr uint32_t UNBONDING_BLOCKS{9450};
    auto bonded_destination = wallet->GetNewTieredQuantumDestination(
        "bonded", UNBONDING_BLOCKS);
    BOOST_REQUIRE(bonded_destination);
    const auto bonded_key_info = WITH_LOCK(
        wallet->cs_wallet,
        return wallet->GetQuantumKeyInfo(*bonded_destination));
    BOOST_REQUIRE(bonded_key_info);

    const CBlockIndex* confirmation_block = WITH_LOCK(
        Assert(m_node.chainman)->GetMutex(),
        return Assert(m_node.chainman)->ActiveChain()[1]);
    BOOST_REQUIRE(confirmation_block);
    CMutableTransaction funding;
    funding.vin.emplace_back(COutPoint{uint256{0x71}, 0});
    funding.vout.emplace_back(
        10 * COIN, GetScriptForDestination(*bonded_destination));
    const CTransactionRef funding_ref =
        MakeTransactionRef(std::move(funding));
    BOOST_REQUIRE(wallet->AddToWallet(
        funding_ref,
        TxStateConfirmed{confirmation_block->GetBlockHash(),
                         confirmation_block->nHeight, 1}));

    const size_t keys_before = distinct_key_count(*wallet);
    const size_t transactions_before = WITH_LOCK(
        wallet->cs_wallet, return wallet->mapWallet.size());
    MockableDatabase& database = GetMockableDatabase(*wallet);
    // GetNewQuantumChangeDestination commits first. Fail the immediately
    // following unbonding-label transaction without failing durable key
    // creation itself.
    database.m_fail_commit_at = database.m_commit_calls + 1;

    auto result = WithdrawTieredStakeAddress(
        *wallet, EncodeDestination(*bonded_destination),
        /*require_operator_lock=*/false, "unbonding-label", "withdrawal-label",
        "test unbond", "test withdrawal", std::nullopt,
        /*allow_all_outputs=*/false, /*allow_new_quantum_key=*/true);
    BOOST_CHECK(!result);
    const std::string failure = util::ErrorString(result).original;
    BOOST_CHECK(failure.find(
        "failed after creating durable non-HD ML-DSA key") !=
        std::string::npos);
    BOOST_CHECK(failure.find("Back up the wallet now") != std::string::npos);
    BOOST_CHECK(failure.find("Reload the wallet before retrying") !=
                std::string::npos);
    BOOST_CHECK(failure.find("no transaction was created") !=
                std::string::npos);
    BOOST_CHECK(wallet->IsAddressBookDatabaseAmbiguous());
    BOOST_CHECK_EQUAL(
        distinct_key_count(*wallet),
        keys_before + 1);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(wallet->cs_wallet, return wallet->mapWallet.size()),
        transactions_before);

    const int spend_height = WITH_LOCK(
        wallet->cs_wallet, return wallet->GetLastBlockHeight() + 1);
    const CTxDestination unbonding_destination = WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        QuantumTieredMigrationProgramForPubkey(
            bonded_key_info->public_key,
            QUANTUM_TIERED_STATE_UNBONDING,
            UNBONDING_BLOCKS,
            static_cast<uint32_t>(spend_height + UNBONDING_BLOCKS))};
    BOOST_CHECK(WITH_LOCK(
        wallet->cs_wallet,
        return wallet->FindAddressBookEntry(
                   unbonding_destination, /*allow_change=*/true) == nullptr));

    CWallet reloaded(
        m_node.chain.get(), "", DuplicateMockDatabase(database));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(!reloaded.IsAddressBookDatabaseAmbiguous());
    BOOST_CHECK_EQUAL(
        distinct_key_count(reloaded),
        keys_before + 1);
    BOOST_CHECK(WITH_LOCK(
        reloaded.cs_wallet,
        return reloaded.FindAddressBookEntry(
                   unbonding_destination, /*allow_change=*/true) == nullptr));
}

BOOST_AUTO_TEST_CASE(abandon_unknown_transaction_is_safe)
{
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_CHECK(!wallet.AbandonTransaction(uint256::ONE));
}

BOOST_AUTO_TEST_CASE(automatic_shadow_signal_retry_preserves_audit_record_and_manual_abandon)
{
    CWallet wallet(m_node.chain.get(), "signal-retry", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
    wallet.SetBroadcastTransactions(/*broadcast=*/false);

    CScript quantum_payout_script;
    {
        LOCK(wallet.cs_wallet);
        auto destination = wallet.GetNewQuantumDestination("signal-retry");
        BOOST_REQUIRE(destination);
        quantum_payout_script = GetScriptForDestination(*destination);
    }

    CKey legacy_key;
    legacy_key.MakeNewKey(/*fCompressed=*/true);
    const CScript legacy_target = GetScriptForRawPubKey(legacy_key.GetPubKey());
    std::vector<unsigned char> signal_payload;
    BOOST_REQUIRE(BuildShadowSignalData(
        legacy_target, quantum_payout_script, /*solve_height=*/1, uint256::ONE, signal_payload));

    auto add_funding = [&](uint64_t seed) {
        CMutableTransaction funding;
        funding.vin.emplace_back(COutPoint{uint256{static_cast<uint8_t>(seed)}, 0});
        funding.vout.emplace_back(2 * COIN, legacy_target);
        CTransactionRef ref = MakeTransactionRef(std::move(funding));
        BOOST_REQUIRE(wallet.AddToWallet(ref, TxStateInactive{}));
        return ref;
    };
    auto make_spend = [&](const CTransactionRef& funding, bool shadow_signal) {
        CMutableTransaction spend;
        spend.vin.emplace_back(COutPoint{funding->GetHash(), 0});
        spend.vout.emplace_back(COIN, legacy_target);
        if (shadow_signal) {
            spend.vout.emplace_back(0, CScript{} << OP_RETURN << signal_payload);
        }
        return MakeTransactionRef(std::move(spend));
    };

    const CTransactionRef automatic_signal = make_spend(add_funding(/*seed=*/101), /*shadow_signal=*/true);
    const mapValue_t audit_metadata{{"comment", "PoS Claim"}, {"retry-audit", "preserve-me"}};
    const std::vector<std::pair<std::string, std::string>> audit_order{{"source", "automatic"}};
    BOOST_REQUIRE(wallet.CommitTransaction(automatic_signal, audit_metadata, audit_order));
    const CTransactionRef signal_descendant = make_spend(automatic_signal, /*shadow_signal=*/false);
    const mapValue_t descendant_metadata{{"comment", "signal change descendant"}};
    BOOST_REQUIRE(wallet.CommitTransaction(signal_descendant, descendant_metadata, {}));
    BOOST_REQUIRE(wallet.AbandonTransaction(automatic_signal->GetHash(), /*automatic_shadow_stale=*/true));

    int64_t original_order_pos{-1};
    size_t original_wallet_size{0};
    {
        LOCK(wallet.cs_wallet);
        const CWalletTx& stored = wallet.mapWallet.at(automatic_signal->GetHash());
        BOOST_REQUIRE(stored.isAbandoned());
        BOOST_CHECK_EQUAL(stored.mapValue.at("qq_auto_shadow_stale"), "1");
        BOOST_CHECK(stored.mapValue.count("qq_manual_shadow_abandon") == 0);
        BOOST_CHECK_EQUAL(stored.mapValue.at("comment"), "PoS Claim");
        BOOST_CHECK_EQUAL(stored.mapValue.at("retry-audit"), "preserve-me");
        BOOST_CHECK(stored.vOrderForm == audit_order);
        const CWalletTx& descendant = wallet.mapWallet.at(signal_descendant->GetHash());
        BOOST_CHECK(descendant.isAbandoned());
        BOOST_CHECK(descendant.mapValue.count("qq_auto_shadow_stale") == 0);
        BOOST_CHECK(descendant.mapValue.count("qq_manual_shadow_abandon") == 0);
        original_order_pos = stored.nOrderPos;
        original_wallet_size = wallet.mapWallet.size();
    }

    // Prove that the automatic provenance and audit metadata survive disk
    // serialization before exercising the same-txid retry path.
    CWallet reloaded(m_node.chain.get(), "signal-retry", DuplicateMockDatabase(wallet.GetDatabase()));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    reloaded.SetBroadcastTransactions(/*broadcast=*/false);
    std::string broadcast_error;
    BOOST_REQUIRE(reloaded.CommitTransaction(
        automatic_signal, audit_metadata, audit_order, &broadcast_error));
    BOOST_CHECK(broadcast_error.empty());
    {
        LOCK(reloaded.cs_wallet);
        const CWalletTx& stored = reloaded.mapWallet.at(automatic_signal->GetHash());
        BOOST_CHECK(!stored.isAbandoned());
        BOOST_CHECK_EQUAL(stored.nOrderPos, original_order_pos);
        BOOST_CHECK_EQUAL(reloaded.mapWallet.size(), original_wallet_size);
        BOOST_CHECK_EQUAL(stored.mapValue.at("comment"), "PoS Claim");
        BOOST_CHECK_EQUAL(stored.mapValue.at("retry-audit"), "preserve-me");
        BOOST_CHECK(stored.mapValue.count("qq_auto_shadow_stale") == 0);
        BOOST_CHECK(stored.mapValue.count("qq_manual_shadow_abandon") == 0);
        BOOST_CHECK(stored.vOrderForm == audit_order);
        const CWalletTx& descendant = reloaded.mapWallet.at(signal_descendant->GetHash());
        BOOST_CHECK(descendant.isAbandoned());
        BOOST_CHECK(descendant.mapValue.count("qq_auto_shadow_stale") == 0);
        BOOST_CHECK(descendant.mapValue.count("qq_manual_shadow_abandon") == 0);
    }

    // Once the user explicitly abandons the record, neither an identical
    // retry nor a later automatic cleanup request may reopen it.
    BOOST_REQUIRE(reloaded.AbandonTransaction(automatic_signal->GetHash()));
    broadcast_error.clear();
    BOOST_CHECK(!reloaded.CommitTransaction(
        automatic_signal, audit_metadata, audit_order, &broadcast_error));
    BOOST_CHECK_EQUAL(broadcast_error, "manually abandoned Gold Rush PoS signal will not be reopened");
    BOOST_CHECK(!reloaded.AbandonTransaction(
        automatic_signal->GetHash(), /*automatic_shadow_stale=*/true));
    {
        LOCK(reloaded.cs_wallet);
        const CWalletTx& stored = reloaded.mapWallet.at(automatic_signal->GetHash());
        BOOST_REQUIRE(stored.isAbandoned());
        BOOST_CHECK_EQUAL(stored.nOrderPos, original_order_pos);
        BOOST_CHECK_EQUAL(stored.mapValue.at("comment"), "PoS Claim");
        BOOST_CHECK_EQUAL(stored.mapValue.at("retry-audit"), "preserve-me");
        BOOST_CHECK_EQUAL(stored.mapValue.at("qq_manual_shadow_abandon"), "1");
        BOOST_CHECK(stored.mapValue.count("qq_auto_shadow_stale") == 0);
        BOOST_CHECK(stored.vOrderForm == audit_order);
    }

    // A signal without the exact automatic comment cannot enter the reopen
    // path, even if an internal caller requests automatic cleanup.
    const CTransactionRef non_automatic_signal = make_spend(add_funding(/*seed=*/102), /*shadow_signal=*/true);
    const mapValue_t non_automatic_metadata{{"comment", "manual signal"}};
    BOOST_REQUIRE(wallet.CommitTransaction(non_automatic_signal, non_automatic_metadata, {}));
    BOOST_REQUIRE(wallet.AbandonTransaction(non_automatic_signal->GetHash(), /*automatic_shadow_stale=*/true));
    {
        LOCK(wallet.cs_wallet);
        const CWalletTx& stored = wallet.mapWallet.at(non_automatic_signal->GetHash());
        BOOST_CHECK(stored.isAbandoned());
        BOOST_CHECK_EQUAL(stored.mapValue.at("comment"), "manual signal");
        BOOST_CHECK(stored.mapValue.count("qq_auto_shadow_stale") == 0);
        BOOST_CHECK(stored.mapValue.count("qq_manual_shadow_abandon") == 0);
    }

    // A non-QQSIGNAL transaction cannot opt into the reopen path merely by
    // carrying the internal automatic comment.
    const CTransactionRef ordinary_spend = make_spend(add_funding(/*seed=*/103), /*shadow_signal=*/false);
    const mapValue_t misleading_metadata{{"comment", "PoS Claim"}};
    BOOST_REQUIRE(wallet.CommitTransaction(ordinary_spend, misleading_metadata, {}));
    BOOST_REQUIRE(wallet.AbandonTransaction(ordinary_spend->GetHash(), /*automatic_shadow_stale=*/true));
    {
        LOCK(wallet.cs_wallet);
        const CWalletTx& stored = wallet.mapWallet.at(ordinary_spend->GetHash());
        BOOST_CHECK(stored.isAbandoned());
        BOOST_CHECK_EQUAL(stored.mapValue.at("comment"), "PoS Claim");
        BOOST_CHECK(stored.mapValue.count("qq_auto_shadow_stale") == 0);
        BOOST_CHECK(stored.mapValue.count("qq_manual_shadow_abandon") == 0);
    }
}

BOOST_AUTO_TEST_CASE(shadow_pow_claim_submission_guard_is_single_flight_and_exception_safe)
{
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());

    constexpr size_t worker_count{16};
    std::promise<void> start;
    std::shared_future<void> start_future = start.get_future().share();
    std::promise<void> release_winner;
    std::shared_future<void> release_future = release_winner.get_future().share();
    std::atomic<size_t> ready{0};
    std::atomic<size_t> attempted{0};
    std::atomic<size_t> acquired{0};
    std::vector<std::future<bool>> workers;
    workers.reserve(worker_count);
    for (size_t i = 0; i < worker_count; ++i) {
        workers.emplace_back(std::async(std::launch::async, [&] {
            ++ready;
            start_future.wait();
            ShadowPowClaimSubmissionGuard guard(wallet);
            ++attempted;
            if (!guard) return false;
            ++acquired;
            release_future.wait();
            return true;
        }));
    }

    while (ready.load() != worker_count) std::this_thread::yield();
    start.set_value();
    while (attempted.load() != worker_count) std::this_thread::yield();
    BOOST_CHECK_EQUAL(acquired.load(), 1U);
    release_winner.set_value();

    size_t successful_workers{0};
    for (auto& worker : workers) {
        if (worker.get()) ++successful_workers;
    }
    BOOST_CHECK_EQUAL(successful_workers, 1U);

    try {
        ShadowPowClaimSubmissionGuard guard(wallet);
        BOOST_REQUIRE(static_cast<bool>(guard));
        throw std::runtime_error("injected claim submission failure");
    } catch (const std::runtime_error&) {
    }

    ShadowPowClaimSubmissionGuard after_exception(wallet);
    BOOST_CHECK(static_cast<bool>(after_exception));
}

BOOST_AUTO_TEST_CASE(shadow_pow_claim_quarantine_refuses_generic_abandonment)
{
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    constexpr int first_quarantine_height{321};
    const uint256 first_quarantine_tip{42};
    {
        LOCK(wallet.cs_wallet);
        wallet.SetLastBlockProcessed(
            first_quarantine_height, first_quarantine_tip);
    }

    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    {
        // Match the production wallet lock order: wallet state is acquired
        // before the legacy keystore. AddKeyPubKey may clear the blank-wallet
        // flag through CWallet while it holds cs_KeyStore.
        LOCK(wallet.cs_wallet);
        wallet.SetupLegacyScriptPubKeyMan();
        BOOST_REQUIRE(wallet.GetOrCreateLegacyScriptPubKeyMan()->AddKeyPubKey(
            wallet_key, wallet_key.GetPubKey()));
    }
    CMutableTransaction funding;
    funding.vout.emplace_back(2 * COIN, GetScriptForRawPubKey(wallet_key.GetPubKey()));
    const CTransactionRef funding_ref = MakeTransactionRef(std::move(funding));
    BOOST_REQUIRE(wallet.AddToWallet(funding_ref, TxStateInactive{}));

    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0, 0, 0, 0, 0, 0, 0, 0,
                               0});
    CMutableTransaction claim;
    claim.vin.emplace_back(COutPoint{funding_ref->GetHash(), 0});
    claim.vout.emplace_back(COIN, CScript{} << OP_TRUE);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    const CTransactionRef claim_ref = MakeTransactionRef(std::move(claim));
    BOOST_REQUIRE(TransactionHasShadowProof(*claim_ref));
    BOOST_REQUIRE(wallet.AddToWallet(
        claim_ref, TxStateInactive{},
        [](CWalletTx& wtx, bool) {
            // A legacy display comment is not durable authorization for
            // automatic claim recovery.
            wtx.mapValue["comment"] = "PoW Claim";
            return true;
        }));

    // A proof need not carry the persistent marker to be unsafe to replace:
    // it can be absent from this mempool while another peer still has it.
    BOOST_CHECK_EQUAL(wallet.CountUnresolvedShadowPowClaims(), 1U);
    BOOST_CHECK_EQUAL(wallet.CountLiveShadowPowClaims(), 0U);
    BOOST_CHECK_EQUAL(wallet.CountQuarantinedShadowPowClaims(), 1U);
    BOOST_REQUIRE(wallet.QuarantineShadowPowClaim(claim_ref->GetHash()));
    BOOST_REQUIRE(wallet.QuarantineShadowPowClaim(claim_ref->GetHash()));
    BOOST_CHECK_EQUAL(wallet.CountQuarantinedShadowPowClaims(), 1U);
    {
        LOCK(wallet.cs_wallet);
        const CWalletTx& stored = wallet.mapWallet.at(claim_ref->GetHash());
        BOOST_CHECK(stored.isUnconfirmed());
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(SHADOW_POW_QUARANTINE_MARKER_KEY), "1");
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(first_quarantine_height));
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY),
            first_quarantine_tip.GetHex());
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_AUTHORED_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_CREATED_TIP_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY) == 0);
    }

    // Clearing the transient quarantine marker and observing the claim again
    // must not rewrite its immutable first-observation provenance.
    {
        LOCK(wallet.cs_wallet);
        CWalletTx& stored = wallet.mapWallet.at(claim_ref->GetHash());
        stored.mapValue.erase(SHADOW_POW_QUARANTINE_MARKER_KEY);
        wallet.SetLastBlockProcessed(
            first_quarantine_height + 1, uint256{43});
    }
    BOOST_REQUIRE(wallet.QuarantineShadowPowClaim(claim_ref->GetHash()));
    {
        LOCK(wallet.cs_wallet);
        const CWalletTx& stored = wallet.mapWallet.at(claim_ref->GetHash());
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(first_quarantine_height));
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY),
            first_quarantine_tip.GetHex());
    }

    // A removed claim can still be held by a peer. Generic abandonment must
    // not release its exact fee input, and another claim must not consume a
    // different fee input while this quarantine remains unresolved.
    BOOST_CHECK(!wallet.TransactionCanBeAbandoned(claim_ref->GetHash()));
    BOOST_CHECK(!wallet.AbandonTransaction(claim_ref->GetHash()));
    BOOST_CHECK_EQUAL(wallet.CountUnresolvedShadowPowClaims(), 1U);
    {
        LOCK(wallet.cs_wallet);
        const CWalletTx& stored = wallet.mapWallet.at(claim_ref->GetHash());
        BOOST_CHECK(!stored.isAbandoned());
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(SHADOW_POW_QUARANTINE_MARKER_KEY), "1");
    }
}

BOOST_FIXTURE_TEST_CASE(
    shadow_pow_claim_quarantine_metadata_is_durable_before_authoritative,
    TestChain100Setup)
{
    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    const CScript wallet_script =
        GetScriptForRawPubKey(wallet_key.GetPubKey());
    const CMutableTransaction funding = MakeDurabilityTestSpend(
        *m_coinbase_txns[0], /*index=*/0, coinbaseKey, wallet_script);
    CreateAndProcessBlock(
        {funding}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    auto baseline_wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return Assert(m_node.chainman)->ActiveChain()),
        wallet_key);
    CWallet& baseline = *baseline_wallet;
    const int observation_height = WITH_LOCK(
        Assert(m_node.chainman)->GetMutex(),
        return Assert(m_node.chainman)->ActiveChain().Height());
    const uint256 observation_tip = WITH_LOCK(
        Assert(m_node.chainman)->GetMutex(),
        return Assert(m_node.chainman)->ActiveChain().Tip()->GetBlockHash());
    {
        LOCK(baseline.cs_wallet);
        baseline.SetLastBlockProcessed(observation_height, observation_tip);
    }
    const CTransactionRef funding_ref = MakeTransactionRef(funding);

    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(),
                 {'Q', 'Q', 'P', '2', 0, 0, 0, 0, 0, 0, 0, 0, 0});
    CMutableTransaction claim;
    claim.vin.emplace_back(COutPoint{funding_ref->GetHash(), 0});
    claim.vout.emplace_back(
        funding.vout[0].nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    const CTransactionRef claim_ref = MakeTransactionRef(std::move(claim));
    BOOST_REQUIRE(baseline.AddToWallet(claim_ref, TxStateInactive{}));

    const MockableData before_quarantine =
        GetMockableDatabase(baseline).m_records;
    enum class FailureStage { BEGIN, WRITE, COMMIT };
    for (const FailureStage stage :
         {FailureStage::BEGIN, FailureStage::WRITE, FailureStage::COMMIT}) {
        CWallet failing(
            m_node.chain.get(), "",
            CreateMockableWalletDatabase(before_quarantine));
        BOOST_REQUIRE_EQUAL(failing.LoadWallet(), DBErrors::LOAD_OK);
        {
            LOCK(failing.cs_wallet);
            failing.SetLastBlockProcessed(
                observation_height, observation_tip);
        }
        MockableDatabase& database = GetMockableDatabase(failing);
        const MockableData before_attempt = database.m_records;
        if (stage == FailureStage::BEGIN) database.m_fail_begin = true;
        if (stage == FailureStage::WRITE) database.m_fail_write_at = 0;
        if (stage == FailureStage::COMMIT) database.m_fail_commit = true;

        BOOST_CHECK(!failing.QuarantineShadowPowClaim(claim_ref->GetHash()));
        BOOST_CHECK(failing.IsShadowPowClaimRecoveryDatabaseAmbiguous());
        BOOST_CHECK(database.m_records == before_attempt);
        if (stage != FailureStage::BEGIN) {
            BOOST_CHECK(database.m_last_txn_durable);
        }
        {
            LOCK(failing.cs_wallet);
            const CWalletTx& stored =
                failing.mapWallet.at(claim_ref->GetHash());
            BOOST_CHECK(stored.mapValue.count(
                SHADOW_POW_QUARANTINE_MARKER_KEY) == 0);
            BOOST_CHECK(stored.mapValue.count(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY) == 0);
            BOOST_CHECK(stored.mapValue.count(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY) == 0);
        }

        ShadowPowClaimRecoveryRequest request;
        request.mode = ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST;
        request.execution_authority =
            ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
        request.acknowledge_fee_and_conflict_risk = true;
        request.expected_plan_id = uint256{1};
        const ShadowPowClaimRecoveryResult refused =
            failing.ResolveShadowPowClaims(request);
        BOOST_CHECK(!refused.success);
        BOOST_CHECK(refused.durable_state_ambiguous);
        BOOST_CHECK_EQUAL(refused.signed_and_persisted, 0U);
        BOOST_CHECK_EQUAL(refused.relay_authority_granted, 0U);
        BOOST_CHECK_EQUAL(refused.broadcast, 0U);
        BOOST_CHECK_EQUAL(failing.mapWallet.size(), 2U);
    }

    CWallet successful(
        m_node.chain.get(), "",
        CreateMockableWalletDatabase(before_quarantine));
    BOOST_REQUIRE_EQUAL(successful.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(successful.cs_wallet);
        successful.SetLastBlockProcessed(
            observation_height, observation_tip);
    }
    BOOST_REQUIRE(successful.QuarantineShadowPowClaim(claim_ref->GetHash()));
    BOOST_CHECK(GetMockableDatabase(successful).m_last_txn_durable);
    BOOST_CHECK(!successful.IsShadowPowClaimRecoveryDatabaseAmbiguous());
    const MockableData quarantined_records =
        GetMockableDatabase(successful).m_records;

    CWallet reloaded(
        m_node.chain.get(), "",
        DuplicateMockDatabase(successful.GetDatabase()));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(reloaded.cs_wallet);
        const CWalletTx& stored =
            reloaded.mapWallet.at(claim_ref->GetHash());
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(SHADOW_POW_QUARANTINE_MARKER_KEY), "1");
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(observation_height));
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY),
            observation_tip.GetHex());
    }

    // Use a standard wallet-authored spend to exercise the callback's
    // authoritative mempool check without depending on a synthetic proof's
    // policy validity. The marker plumbing is transaction-shape agnostic.
    CKey external_key;
    external_key.MakeNewKey(/*fCompressed=*/true);
    const CTransactionRef live_ref = MakeTransactionRef(
        MakeDurabilityTestSpend(
            *funding_ref, /*index=*/0, wallet_key,
            GetScriptForRawPubKey(external_key.GetPubKey())));
    CWallet live_seed(
        m_node.chain.get(), "",
        CreateMockableWalletDatabase(quarantined_records));
    BOOST_REQUIRE_EQUAL(live_seed.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(live_seed.AddToWallet(
        live_ref, TxStateInMempool{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_QUARANTINE_MARKER_KEY] = "1";
            wtx.mapValue[
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY] =
                ToString(observation_height);
            wtx.mapValue[SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY] =
                observation_tip.GetHex();
            return true;
        }));
    const MockableData live_records =
        GetMockableDatabase(live_seed).m_records;
    std::string broadcast_error;
    BOOST_REQUIRE_MESSAGE(
        m_node.chain->broadcastTransaction(
            live_ref, DEFAULT_TRANSACTION_MAXFEE, /*relay=*/false,
            broadcast_error),
        broadcast_error);
    const auto seed_live_marker = [&](CWallet& wallet) {
        return wallet.AddToWallet(
            live_ref, TxStateInMempool{},
            [&](CWalletTx& wtx, bool) {
                wtx.mapValue[SHADOW_POW_QUARANTINE_MARKER_KEY] = "1";
                wtx.mapValue[
                    SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY] =
                    ToString(observation_height);
                wtx.mapValue[
                    SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY] =
                    observation_tip.GetHex();
                return true;
            }) != nullptr;
    };

    // A failed authoritative clear is copy-on-write: the durable marker
    // remains visible and the recovery database latches fail-closed.
    CWallet failed_clear(
        m_node.chain.get(), "",
        CreateMockableWalletDatabase(live_records));
    BOOST_REQUIRE_EQUAL(failed_clear.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(seed_live_marker(failed_clear));
    {
        LOCK(failed_clear.cs_wallet);
        const CWalletTx& prearm =
            failed_clear.mapWallet.at(live_ref->GetHash());
        BOOST_REQUIRE(prearm.InMempool());
        BOOST_REQUIRE_EQUAL(
            prearm.mapValue.at(SHADOW_POW_QUARANTINE_MARKER_KEY), "1");
        BOOST_REQUIRE_EQUAL(
            prearm.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(observation_height));
    }
    CWallet prearm_reloaded(
        /*chain=*/nullptr, "",
        DuplicateMockDatabase(failed_clear.GetDatabase()));
    BOOST_REQUIRE_EQUAL(prearm_reloaded.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(prearm_reloaded.cs_wallet);
        const CWalletTx& durable_prearm =
            prearm_reloaded.mapWallet.at(live_ref->GetHash());
        BOOST_REQUIRE_EQUAL(
            durable_prearm.mapValue.at(
                SHADOW_POW_QUARANTINE_MARKER_KEY),
            "1");
        BOOST_REQUIRE_EQUAL(
            durable_prearm.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(observation_height));
    }
    MockableDatabase& failed_clear_database =
        GetMockableDatabase(failed_clear);
    failed_clear_database.m_fail_write_at = 0;
    failed_clear.transactionAddedToMempool(live_ref);
    BOOST_CHECK_EQUAL(failed_clear_database.m_write_calls, 1U);
    BOOST_CHECK(failed_clear.IsShadowPowClaimRecoveryDatabaseAmbiguous());
    {
        LOCK(failed_clear.cs_wallet);
        BOOST_CHECK_EQUAL(
            failed_clear.mapWallet.at(live_ref->GetHash()).mapValue.at(
                SHADOW_POW_QUARANTINE_MARKER_KEY),
            "1");
        BOOST_CHECK_EQUAL(
            failed_clear.mapWallet.at(live_ref->GetHash()).mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(observation_height));
    }
    CWallet failed_clear_reloaded(
        m_node.chain.get(), "",
        DuplicateMockDatabase(failed_clear.GetDatabase()));
    BOOST_REQUIRE_EQUAL(
        failed_clear_reloaded.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(failed_clear_reloaded.cs_wallet);
        const CWalletTx& stored =
            failed_clear_reloaded.mapWallet.at(live_ref->GetHash());
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(SHADOW_POW_QUARANTINE_MARKER_KEY), "1");
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(observation_height));
    }

    CWallet cleared(
        m_node.chain.get(), "",
        CreateMockableWalletDatabase(live_records));
    BOOST_REQUIRE_EQUAL(cleared.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(seed_live_marker(cleared));
    cleared.transactionAddedToMempool(live_ref);
    BOOST_CHECK(!cleared.IsShadowPowClaimRecoveryDatabaseAmbiguous());
    {
        LOCK(cleared.cs_wallet);
        BOOST_CHECK(cleared.mapWallet.at(live_ref->GetHash()).mapValue.count(
            SHADOW_POW_QUARANTINE_MARKER_KEY) == 0);
        BOOST_CHECK_EQUAL(
            cleared.mapWallet.at(live_ref->GetHash()).mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(observation_height));
        BOOST_CHECK(cleared.mapWallet.at(live_ref->GetHash()).mapValue.count(
            SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY) == 0);
    }
    CWallet clear_reloaded(
        m_node.chain.get(), "",
        DuplicateMockDatabase(cleared.GetDatabase()));
    BOOST_REQUIRE_EQUAL(clear_reloaded.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(clear_reloaded.cs_wallet);
        BOOST_CHECK(clear_reloaded.mapWallet.at(live_ref->GetHash()).mapValue.count(
            SHADOW_POW_QUARANTINE_MARKER_KEY) == 0);
        BOOST_CHECK_EQUAL(
            clear_reloaded.mapWallet.at(live_ref->GetHash()).mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(observation_height));
    }

    // A delayed ADD callback that arrives after the transaction is actually
    // removed must not clear the atomic reservation or attempt a DB write.
    WITH_LOCK(
        m_node.mempool->cs,
        m_node.mempool->removeRecursive(
            *live_ref, MemPoolRemovalReason::EXPIRY));
    CWallet delayed_add(
        m_node.chain.get(), "",
        CreateMockableWalletDatabase(live_records));
    BOOST_REQUIRE_EQUAL(delayed_add.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE(seed_live_marker(delayed_add));
    {
        LOCK(delayed_add.cs_wallet);
        BOOST_REQUIRE(
            delayed_add.mapWallet.at(live_ref->GetHash()).InMempool());
    }
    MockableDatabase& delayed_add_database =
        GetMockableDatabase(delayed_add);
    delayed_add_database.m_write_calls = 0;
    delayed_add_database.m_fail_write_at = 0;
    delayed_add.transactionAddedToMempool(live_ref);
    BOOST_CHECK_EQUAL(delayed_add_database.m_write_calls, 0U);
    delayed_add_database.m_fail_write_at.reset();
    BOOST_CHECK(!delayed_add.IsShadowPowClaimRecoveryDatabaseAmbiguous());
    {
        LOCK(delayed_add.cs_wallet);
        BOOST_CHECK_EQUAL(
            delayed_add.mapWallet.at(live_ref->GetHash()).mapValue.at(
                SHADOW_POW_QUARANTINE_MARKER_KEY),
            "1");
        BOOST_CHECK(!delayed_add.mapWallet.at(live_ref->GetHash()).InMempool());
    }
}

class WalletShadowPowQQP2TestingSetup : public TestChain100Setup
{
public:
    WalletShadowPowQQP2TestingSetup()
        : TestChain100Setup{ChainType::REGTEST, {
            "-regtest",
            "-shadowwhitelistheight=99",
            "-shadowgoldrushstartheight=100",
            "-shadowgoldrushblocks=1000",
            "-shadowcompetingclaimsheight=1099",
        }}
    {
    }
};

BOOST_FIXTURE_TEST_CASE(
    shadow_pow_claim_invalidated_selection_preserves_typed_retry_scope,
    WalletShadowPowQQP2TestingSetup)
{
    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    const CScript wallet_script =
        GetScriptForRawPubKey(wallet_key.GetPubKey());
    const CMutableTransaction funding = MakeDurabilityTestSpend(
        *m_coinbase_txns[0], /*index=*/0, coinbaseKey, wallet_script);
    CreateAndProcessBlock(
        {funding}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return Assert(m_node.chainman)->ActiveChain()),
        wallet_key);
    BOOST_REQUIRE(m_node.chain->isReadyToBroadcast());
    wallet->m_pow_mining_enabled = true;
    const COutPoint anchor{funding.GetHash(), 0};
    const CScript quantum_payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x51)});
    const auto select_input = [&] {
        const auto gate = wallet->GetShadowPowClaimMiningGate();
        CCoinControl control;
        control.m_allow_other_inputs = false;
        control.m_avoid_address_reuse = false;
        ShadowPowClaimInput selected;
        bilingual_str error;
        BOOST_REQUIRE(wallet->SelectShadowPowClaimInput(
            std::nullopt, quantum_payout, nullptr, control, selected,
            error, gate) == ShadowPowClaimInputSelectionResult::SELECTED);
        BOOST_REQUIRE(selected.outpoint == anchor);
        return selected;
    };
    ShadowPowClaimInput selected = select_input();
    ShadowPowWork work;
    work.valid = true;
    work.target = selected.target;
    work.quantum_payout_script = quantum_payout;
    work.prev_hash = selected.selection_tip;
    work.height = selected.selection_height + 1;
    // Only the off-chain proof guard is exercised: every attempt below must
    // stop before mempool admission. One zero-difficulty nonce keeps this
    // classification regression independent of mining luck and runtime cost.
    work.bits = 0;
    std::vector<unsigned char> proof;
    BOOST_REQUIRE(GrindShadowPowWork(work, 0, 1, 1, proof));
    const uint64_t authority =
        wallet->m_pow_wallet_authority_generation.load();
    const MockableData durable_before = GetMockableDatabase(*wallet).m_records;
    const size_t records_before = WITH_LOCK(
        wallet->cs_wallet, return wallet->mapWallet.size());
    const auto submit = [&](const ShadowPowClaimInput& input,
                            uint64_t expected_authority) {
        bilingual_str error;
        std::optional<ShadowPowClaimMiningGate> reselection;
        const auto result = wallet->SubmitShadowPowClaim(
            input, work, proof, expected_authority, error, &reselection);
        BOOST_CHECK(!error.original.empty());
        BOOST_CHECK(!reselection); // New anchors have no family-local fallback.
        BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet,
                                   return wallet->mapWallet.size()), records_before);
        BOOST_CHECK(GetMockableDatabase(*wallet).m_records == durable_before);
        BOOST_CHECK_EQUAL(wallet->m_pow_claims_submitted.load(), 0U);
        return result;
    };

    // A stale carried snapshot is an input-scoped refusal, not a generic
    // failure that releases the worker group's exact-tip reservation.
    ++selected.selection_wallet_generation;
    BOOST_CHECK(submit(selected, authority) ==
                ShadowPowClaimSubmitResult::INPUT_UNAVAILABLE);
    selected = select_input();
    BOOST_REQUIRE(WITH_LOCK(wallet->cs_wallet, return wallet->LockCoin(anchor)));
    BOOST_CHECK(submit(selected, authority) ==
                ShadowPowClaimSubmitResult::INPUT_UNAVAILABLE);
    WITH_LOCK(wallet->cs_wallet, wallet->UnlockCoin(anchor));

    // An unrelated signing-authority rejection retains its distinct result.
    selected = select_input();
    BOOST_CHECK(submit(selected, authority + 1) ==
                ShadowPowClaimSubmitResult::FAILED);

    // Repeat after signing at the existing final-publication test barrier.
    // The callback mutates only the exact input, before the final guard runs.
    ScopedArgsSettings settings;
    settings.Force("-qqshadowpowclaimcommitdelaymillis", "1");
    bool locked_at_commit_barrier{false};
    {
        DebugLogHelper barrier("Gold Rush PoW claim final-commit authority test barrier reached",
            [&](const std::string* line) {
                if (line && !locked_at_commit_barrier) {
                    locked_at_commit_barrier = WITH_LOCK(
                        wallet->cs_wallet, return wallet->LockCoin(anchor));
                }
                return true;
            });
        BOOST_CHECK(submit(selected, authority) ==
                    ShadowPowClaimSubmitResult::INPUT_UNAVAILABLE);
    }
    BOOST_CHECK(locked_at_commit_barrier);
    WITH_LOCK(wallet->cs_wallet, wallet->UnlockCoin(anchor));
    wallet->m_pow_mining_enabled = false;
}

BOOST_FIXTURE_TEST_CASE(
    shadow_pow_claim_initial_reservation_is_atomic_without_broadcast,
    WalletShadowPowQQP2TestingSetup)
{
    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    const CScript wallet_script =
        GetScriptForRawPubKey(wallet_key.GetPubKey());
    const CMutableTransaction funding = MakeDurabilityTestSpend(
        *m_coinbase_txns[0], /*index=*/0, coinbaseKey, wallet_script);
    CreateAndProcessBlock(
        {funding}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return Assert(m_node.chainman)->ActiveChain()),
        wallet_key);
    const MockableData durable_before =
        GetMockableDatabase(*wallet).m_records;
    const COutPoint anchor{funding.GetHash(), 0};
    const CScript claim_target =
        CanonicalizeLegacyStakeScript(wallet_script);

    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0});
    proof.insert(proof.end(), 8, 0);
    proof.push_back(
        static_cast<unsigned char>(claim_target.size() & 0xff));
    proof.push_back(static_cast<unsigned char>(
        (claim_target.size() >> 8) & 0xff));
    proof.insert(proof.end(), claim_target.begin(), claim_target.end());
    const CScript quantum_payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x51)});
    proof.push_back(
        static_cast<unsigned char>(quantum_payout.size() & 0xff));
    proof.push_back(static_cast<unsigned char>(
        (quantum_payout.size() >> 8) & 0xff));
    proof.insert(proof.end(), quantum_payout.begin(), quantum_payout.end());
    static constexpr uint32_t SEQUENCE_REPLACEABLE = 0xfffffffd;
    CMutableTransaction claim;
    claim.nVersion = CTransaction::CURRENT_VERSION;
    claim.vin.emplace_back(anchor, CScript{}, SEQUENCE_REPLACEABLE);
    claim.vout.emplace_back(
        funding.vout[0].nValue - CENT,
        claim_target);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    const CTransactionRef claim_ref = MakeTransactionRef(std::move(claim));
    BOOST_REQUIRE(TransactionHasShadowProof(*claim_ref));

    wallet->SetBroadcastTransactions(/*broadcast=*/false);
    const uint64_t authority_generation =
        wallet->m_pow_wallet_authority_generation.load(
            std::memory_order_acquire);
    uint64_t expected_coin_lock_generation{0};
    const auto current_commit_authority = [&] {
        const ShadowPowClaimMiningGate gate =
            wallet->GetShadowPowClaimMiningGate();
        BOOST_REQUIRE(!gate.candidate_state_fingerprint.IsNull());
        CCoinControl selection_control;
        selection_control.m_allow_other_inputs = false;
        selection_control.m_avoid_address_reuse = false;
        ShadowPowClaimInput selected_input;
        bilingual_str selection_error;
        BOOST_REQUIRE(wallet->SelectShadowPowClaimInput(
                          claim_target, quantum_payout, nullptr,
                          selection_control, selected_input,
                          selection_error, gate) ==
                      ShadowPowClaimInputSelectionResult::SELECTED);
        return ShadowPowClaimCommitAuthority{
            wallet->m_pow_wallet_authority_generation.load(
                std::memory_order_acquire),
            /*require_pow_mining_enabled=*/false,
            expected_coin_lock_generation,
            anchor,
            gate.wallet_generation,
            gate.candidate_state_fingerprint,
            gate.active_tip,
            gate.active_height,
            /*require_relay_clock_authority=*/true,
            gate.relay_clock_high_water,
            gate.relay_clock_median_time_past,
            gate.classification_time,
            gate.next_relay_expiry_time,
            gate.next_legacy_relay_expiry_wall_time,
            gate.legacy_relay_clock_high_water,
            selected_input};
    };
    mapValue_t refused_metadata;
    refused_metadata["comment"] = "PoW Claim";
    refused_metadata[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
    std::string refused_error;
    WalletCommitStatus refused_status{WalletCommitStatus::ACCEPTED};
    ShadowPowClaimCommitAuthority refused_authority =
        current_commit_authority();
    refused_authority.expected_wallet_authority_generation =
        authority_generation + 1;
    BOOST_CHECK(!wallet->CommitTransaction(
        claim_ref, std::move(refused_metadata), {}, &refused_error,
        &refused_status, refused_authority));
    BOOST_CHECK(refused_status ==
                WalletCommitStatus::REJECTED_NOT_ADDED);
    BOOST_CHECK_EQUAL(
        refused_error,
        "wallet-signing-authority-changed-before-commit");
    BOOST_CHECK(!WITH_LOCK(
        wallet->cs_wallet,
        return wallet->GetWalletTx(claim_ref->GetHash()) != nullptr));
    BOOST_CHECK(GetMockableDatabase(*wallet).m_records == durable_before);
    BOOST_CHECK(!WITH_LOCK(wallet->cs_wallet,
                           return wallet->IsSpent(anchor)));

    const ShadowPowClaimMiningGate commit_gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_REQUIRE(!commit_gate.candidate_state_fingerprint.IsNull());
    const uint256 wrong_candidate_state = uint256S("01");
    BOOST_REQUIRE(wrong_candidate_state !=
                  commit_gate.candidate_state_fingerprint);
    mapValue_t stale_state_metadata;
    stale_state_metadata["comment"] = "PoW Claim";
    stale_state_metadata[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
    refused_error.clear();
    refused_status = WalletCommitStatus::ACCEPTED;
    ShadowPowClaimCommitAuthority stale_state_authority =
        current_commit_authority();
    stale_state_authority.expected_candidate_state_fingerprint =
        wrong_candidate_state;
    BOOST_CHECK(!wallet->CommitTransaction(
        claim_ref, std::move(stale_state_metadata), {}, &refused_error,
        &refused_status, stale_state_authority));
    BOOST_CHECK(refused_status == WalletCommitStatus::REJECTED_NOT_ADDED);
    BOOST_CHECK_EQUAL(
        refused_error, "wallet-claim-state-changed-before-commit");
    BOOST_CHECK(!WITH_LOCK(
        wallet->cs_wallet,
        return wallet->GetWalletTx(claim_ref->GetHash()) != nullptr));
    BOOST_CHECK(GetMockableDatabase(*wallet).m_records == durable_before);

    mapValue_t stopped_metadata;
    stopped_metadata["comment"] = "PoW Claim";
    stopped_metadata[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
    refused_error.clear();
    refused_status = WalletCommitStatus::ACCEPTED;
    ShadowPowClaimCommitAuthority stopped_authority =
        current_commit_authority();
    stopped_authority.require_pow_mining_enabled = true;
    BOOST_CHECK(!wallet->CommitTransaction(
        claim_ref, std::move(stopped_metadata), {}, &refused_error,
        &refused_status, stopped_authority));
    BOOST_CHECK(refused_status ==
                WalletCommitStatus::REJECTED_NOT_ADDED);
    BOOST_CHECK_EQUAL(
        refused_error,
        "wallet-signing-authority-changed-before-commit");
    BOOST_CHECK(!WITH_LOCK(
        wallet->cs_wallet,
        return wallet->GetWalletTx(claim_ref->GetHash()) != nullptr));
    BOOST_CHECK(GetMockableDatabase(*wallet).m_records == durable_before);

    mapValue_t coin_lock_metadata;
    coin_lock_metadata["comment"] = "PoW Claim";
    coin_lock_metadata[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
    ShadowPowClaimCommitAuthority coin_lock_authority =
        current_commit_authority();
    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE(wallet->LockCoin(anchor));
        ++expected_coin_lock_generation;
    }
    refused_error.clear();
    refused_status = WalletCommitStatus::ACCEPTED;
    BOOST_REQUIRE(expected_coin_lock_generation > 0);
    BOOST_CHECK(!wallet->CommitTransaction(
        claim_ref, std::move(coin_lock_metadata), {}, &refused_error,
        &refused_status, coin_lock_authority));
    BOOST_CHECK(refused_status == WalletCommitStatus::REJECTED_NOT_ADDED);
    BOOST_CHECK_EQUAL(
        refused_error,
        "wallet-coin-lock-authority-changed-before-commit");
    BOOST_CHECK(!WITH_LOCK(
        wallet->cs_wallet,
        return wallet->GetWalletTx(claim_ref->GetHash()) != nullptr));
    BOOST_CHECK(GetMockableDatabase(*wallet).m_records == durable_before);
    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE(wallet->UnlockCoin(anchor));
        ++expected_coin_lock_generation;
    }

    // A selection must retain its exact source and policy authority until
    // publication, not merely its transaction-family fingerprint.
    const auto refuse_stale_selection = [&](
        ShadowPowClaimCommitAuthority authority) {
        mapValue_t stale_metadata;
        stale_metadata["comment"] = "PoW Claim";
        stale_metadata[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
        std::string error;
        WalletCommitStatus stale_status{WalletCommitStatus::ACCEPTED};
        BOOST_CHECK(!wallet->CommitTransaction(
            claim_ref, std::move(stale_metadata), {}, &error,
            &stale_status, std::move(authority)));
        BOOST_CHECK(stale_status == WalletCommitStatus::REJECTED_NOT_ADDED);
        BOOST_CHECK_EQUAL(
            error, "wallet-claim-selection-authority-changed-before-commit");
        BOOST_CHECK(GetMockableDatabase(*wallet).m_records == durable_before);
        BOOST_CHECK(!WITH_LOCK(wallet->cs_wallet,
                              return wallet->IsSpent(anchor)));
    };
    const auto check_changed_selection = [&](auto mutate) {
        auto authority = current_commit_authority();
        BOOST_REQUIRE(authority.selected_input);
        mutate(*authority.selected_input);
        refuse_stale_selection(std::move(authority));
    };
    check_changed_selection([](auto& input) { --input.source_output.nValue; });
    check_changed_selection([](auto& input) { input.source_output.scriptPubKey << OP_NOP; });
    check_changed_selection([](auto& input) { ++input.coin_time; });
    check_changed_selection([](auto& input) { ++input.live_output_index_generation; });
    check_changed_selection([](auto& input) { ++input.stake_reserve_generation; });
    check_changed_selection([](auto& input) { ++input.suppression_generation; });
    check_changed_selection([](auto& input) {
        input.staking_enabled_at_selection = !input.staking_enabled_at_selection;
    });
    auto missing_selection = current_commit_authority();
    missing_selection.selected_input.reset();
    refuse_stale_selection(std::move(missing_selection));

    // An off -> on -> off pulse preserves the final boolean and wallet DB
    // state, but still revokes work selected under the earlier reserve policy.
    BOOST_REQUIRE(!wallet->m_enabled_staking.load());
    auto pulsed_staking = current_commit_authority();
    wallet->SetStakingEnabled(true);
    wallet->SetStakingEnabled(false);
    refuse_stale_selection(std::move(pulsed_staking));

    mapValue_t metadata;
    metadata["comment"] = "PoW Claim";
    metadata[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
    const CBlockIndex* authored_parent = WITH_LOCK(
        ::cs_main,
        return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(authored_parent);
    metadata[SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY] =
        ToString(authored_parent->nHeight + 1);
    metadata[SHADOW_POW_CLAIM_CREATED_TIP_KEY] =
        authored_parent->GetBlockHash().GetHex();
    std::string broadcast_error;
    WalletCommitStatus status{WalletCommitStatus::REJECTED_NOT_ADDED};
    BOOST_REQUIRE(wallet->CommitTransaction(
        claim_ref, std::move(metadata), {}, &broadcast_error, &status,
        current_commit_authority()));
    BOOST_CHECK(status == WalletCommitStatus::ACCEPTED);
    BOOST_CHECK(broadcast_error.empty());
    BOOST_CHECK(!m_node.chain->isInMempool(claim_ref->GetHash()));
    BOOST_CHECK(
        GetMockableDatabase(*wallet).m_records != durable_before);
    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& stored =
            wallet->mapWallet.at(claim_ref->GetHash());
        BOOST_CHECK(stored.isUnconfirmed());
        BOOST_CHECK(!stored.isAbandoned());
        BOOST_CHECK(!stored.InMempool());
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(SHADOW_POW_QUARANTINE_MARKER_KEY), "1");
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY) == 0);
        BOOST_CHECK(wallet->IsSpent(anchor));
        BOOST_CHECK(wallet->IsQuarantinedShadowPowClaim(
            claim_ref->GetHash()));
    }

    // A chain-unspent anchor reserved only by an exact durable QQSPROOF may
    // receive an additional user coin lock. This never makes the anchor
    // spendable; it pauses only that retained family while preserving the
    // option to use a proven-independent anchor. Exercise the persistent
    // database path used by lockunspent too.
    const ShadowPowClaimRecoveryInventory unlocked_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto unlocked_component = std::find_if(
        unlocked_inventory.components.begin(),
        unlocked_inventory.components.end(),
        [&](const auto& component) { return component.anchor == anchor; });
    BOOST_REQUIRE(unlocked_component != unlocked_inventory.components.end());
    BOOST_CHECK(!unlocked_component->anchor_user_locked);
    const uint256 unlocked_component_fingerprint =
        unlocked_component->fingerprint;
    const uint256 unlocked_generation_fingerprint =
        unlocked_component->generation_fingerprint;
    BOOST_REQUIRE_EQUAL(unlocked_component->nodes.size(), 1U);
    const ShadowPowClaimRecoveryNode& unlocked_node =
        unlocked_component->nodes.front();
    const ShadowPowClaimMiningGate unlocked_gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_TEST_CONTEXT(
        "unlocked gate action=" << static_cast<int>(unlocked_gate.action)
        << " coherent=" << unlocked_gate.coherent
        << " db_ambiguous=" << unlocked_gate.recovery_database_ambiguous
        << " unresolved=" << unlocked_gate.unresolved_components
        << " families=" << unlocked_gate.family_claims
        << " unsafe=" << unlocked_gate.unsafe_claims
        << " live=" << unlocked_gate.live_claims
        << " eligible=" << unlocked_gate.eligible_claims
        << " anchor_authenticated=" <<
            unlocked_component->anchor_authenticated
        << " anchor_unspent=" << unlocked_component->anchor_unspent
        << " all_quarantined=" <<
            unlocked_component->all_claims_quarantined
        << " state=" << static_cast<int>(unlocked_component->state)
        << " provenance=" << static_cast<int>(unlocked_node.provenance)
        << " disposition=" << static_cast<int>(unlocked_node.disposition)
        << " expected_shape=" << unlocked_node.expected_shape
        << " exact_carrier=" << unlocked_node.exact_authored_carrier_shape
        << " wallet_authored=" << unlocked_node.wallet_authored
        << " proof_version=" << static_cast<int>(unlocked_node.proof_version)
        << " proof_mode=" << static_cast<int>(unlocked_node.proof_mode)
        << " input_bound=" << unlocked_node.proof_input_bound
        << " origin_bound=" << unlocked_node.proof_origin_bound
        << " lineage_present=" << unlocked_node.lineage_metadata_present
        << " lineage_valid=" << unlocked_node.lineage_metadata_valid
        << " claim_fee=" << unlocked_node.claim_fee) {
        BOOST_CHECK(unlocked_gate.ShouldRelayExisting() ||
                    unlocked_gate.MayRefreshSameAnchor());
    }

    {
        LOCK2(::cs_main, wallet->cs_wallet);
        Coin active_anchor;
        BOOST_REQUIRE(
            Assert(m_node.chainman)
                ->ActiveChainstate()
                .CoinsTip()
                .GetCoin(anchor, active_anchor));
        BOOST_REQUIRE(!active_anchor.IsSpent());
        BOOST_REQUIRE(GetShadowPowProofLogicalId(*claim_ref));
        BOOST_REQUIRE(
            wallet->CanLockQuarantinedShadowPowClaimAnchor(anchor));
        BOOST_REQUIRE(wallet->LockCoin(anchor));
        BOOST_CHECK(wallet->IsLockedCoin(anchor));
    }
    const ShadowPowClaimRecoveryInventory locked_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto locked_component = std::find_if(
        locked_inventory.components.begin(), locked_inventory.components.end(),
        [&](const auto& component) { return component.anchor == anchor; });
    BOOST_REQUIRE(locked_component != locked_inventory.components.end());
    BOOST_CHECK(locked_component->anchor_user_locked);
    BOOST_CHECK(locked_component->fingerprint !=
                unlocked_component_fingerprint);
    BOOST_CHECK(locked_component->generation_fingerprint ==
                unlocked_generation_fingerprint);
    const ShadowPowClaimMiningGate locked_gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_TEST_CONTEXT(
        "locked gate action=" << static_cast<int>(locked_gate.action)
        << " coherent=" << locked_gate.coherent
        << " db_ambiguous=" << locked_gate.recovery_database_ambiguous
        << " unresolved=" << locked_gate.unresolved_components
        << " families=" << locked_gate.family_claims
        << " unsafe=" << locked_gate.unsafe_claims
        << " live=" << locked_gate.live_claims
        << " eligible=" << locked_gate.eligible_claims) {
        BOOST_CHECK(locked_gate.action ==
                    ShadowPowClaimMiningGateAction::CREATE_NEW_ANCHOR);
    }
    BOOST_CHECK(!locked_gate.ShouldRelayExisting());
    BOOST_CHECK(locked_gate.MayCreateNewAnchorClaim());
    BOOST_REQUIRE_EQUAL(
        locked_gate.reserved_family_anchors.size(), 1U);
    BOOST_CHECK(locked_gate.reserved_family_anchors.front() == anchor);

    // A default in-memory unlock changes the candidate snapshot immediately,
    // restores the same safe family action on the same tip, and restores the
    // component fingerprint without changing stable generation identity.
    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE(wallet->UnlockCoin(anchor));
    }
    const ShadowPowClaimRecoveryInventory reunlocked_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto reunlocked_component = std::find_if(
        reunlocked_inventory.components.begin(),
        reunlocked_inventory.components.end(),
        [&](const auto& component) { return component.anchor == anchor; });
    BOOST_REQUIRE(reunlocked_component != reunlocked_inventory.components.end());
    BOOST_CHECK(!reunlocked_component->anchor_user_locked);
    BOOST_CHECK(reunlocked_component->fingerprint ==
                unlocked_component_fingerprint);
    BOOST_CHECK(reunlocked_component->generation_fingerprint ==
                unlocked_generation_fingerprint);
    const ShadowPowClaimMiningGate reunlocked_gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_TEST_CONTEXT(
        "reunlocked gate action=" <<
            static_cast<int>(reunlocked_gate.action)
        << " coherent=" << reunlocked_gate.coherent
        << " db_ambiguous=" << reunlocked_gate.recovery_database_ambiguous
        << " unresolved=" << reunlocked_gate.unresolved_components
        << " families=" << reunlocked_gate.family_claims
        << " unsafe=" << reunlocked_gate.unsafe_claims
        << " live=" << reunlocked_gate.live_claims
        << " eligible=" << reunlocked_gate.eligible_claims) {
        BOOST_CHECK(reunlocked_gate.ShouldRelayExisting() ||
                    reunlocked_gate.MayRefreshSameAnchor());
    }

    // If a persistent user-lock commit has an indeterminate outcome, neither
    // memory nor a guessed durable state is authority to keep mining. The
    // typed gate remains closed until a fresh wallet reload resolves it.
    CWallet ambiguous_lock_wallet(
        m_node.chain.get(), "", DuplicateMockDatabase(wallet->GetDatabase()));
    BOOST_REQUIRE_EQUAL(ambiguous_lock_wallet.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& ambiguous_lock_database =
        GetMockableDatabase(ambiguous_lock_wallet);
    ambiguous_lock_database.m_fail_commit = true;
    {
        LOCK(ambiguous_lock_wallet.cs_wallet);
        ambiguous_lock_wallet.SetLastBlockProcessed(
            unlocked_inventory.wallet_processed_height,
            unlocked_inventory.wallet_processed_tip);
        std::string lock_error;
        BOOST_CHECK(!ambiguous_lock_wallet.UpdateLockedCoins(
            {anchor}, /*lock=*/true, /*persistent=*/true, &lock_error));
        BOOST_CHECK(
            ambiguous_lock_wallet.IsLockedCoinsDatabaseAmbiguous());
    }
    const ShadowPowClaimMiningGate ambiguous_lock_gate =
        ambiguous_lock_wallet.GetShadowPowClaimMiningGate();
    BOOST_CHECK(ambiguous_lock_gate.recovery_database_ambiguous);
    BOOST_CHECK(!ambiguous_lock_gate.MayCreateClaim());
    BOOST_CHECK(!ambiguous_lock_gate.ShouldRelayExisting());

    // Reinstall the hold so the later mixed-spender check proves an existing
    // persistent user restriction always remains removable.
    {
        LOCK(wallet->cs_wallet);
        std::string lock_error;
        BOOST_REQUIRE(wallet->UpdateLockedCoins(
            {anchor}, /*lock=*/true, /*persistent=*/true, &lock_error));
    }

    // The hold was validly installed while the claim was quarantined. If the
    // exact retained bytes later enter the mempool, the quarantine predicate
    // becomes false but the user's restriction must survive that transition
    // and any subsequently learned same-anchor spender.
    BOOST_REQUIRE(wallet->AddToWallet(claim_ref, TxStateInMempool{}));
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK(wallet->IsLockedCoin(anchor));
        BOOST_CHECK(!wallet->IsQuarantinedShadowPowClaim(
            claim_ref->GetHash()));
        BOOST_CHECK(wallet->IsSpent(anchor));
    }

    // A mixed ordinary wallet spender closes the narrow exception. Unlocking
    // an already installed user lock must nevertheless remain possible after
    // that later reservation appears.
    CMutableTransaction ordinary_spend;
    ordinary_spend.vin.emplace_back(anchor);
    ordinary_spend.vout.emplace_back(
        funding.vout[0].nValue - 2 * DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    const CTransactionRef ordinary_ref =
        MakeTransactionRef(std::move(ordinary_spend));
    BOOST_REQUIRE(!TransactionHasShadowProof(*ordinary_ref));
    BOOST_REQUIRE(wallet->AddToWallet(ordinary_ref, TxStateInactive{}));
    const ShadowPowClaimRecoveryInventory held_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();

    CWallet held_reload_wallet(
        m_node.chain.get(), "", DuplicateMockDatabase(wallet->GetDatabase()));
    BOOST_REQUIRE_EQUAL(held_reload_wallet.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(held_reload_wallet.cs_wallet);
        held_reload_wallet.SetLastBlockProcessed(
            unlocked_inventory.wallet_processed_height,
            unlocked_inventory.wallet_processed_tip);
        BOOST_CHECK(held_reload_wallet.IsLockedCoin(anchor));
    }
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        // Discovering a later conflict must not silently revoke the explicit
        // persistent hold. The new ordinary spender closes the narrow lock-add
        // exception, but only an explicit unlock may remove an existing hold.
        BOOST_CHECK(wallet->IsLockedCoin(anchor));
        BOOST_CHECK(
            !wallet->CanLockQuarantinedShadowPowClaimAnchor(anchor));
        BOOST_REQUIRE(
            wallet->ShadowPowClaimRecoveryInventoryMatchesCurrentLocked(
                held_inventory));
        const auto held_component = std::find_if(
            held_inventory.components.begin(), held_inventory.components.end(),
            [&](const auto& component) { return component.anchor == anchor; });
        BOOST_REQUIRE(held_component != held_inventory.components.end());
        BOOST_CHECK(held_component->anchor_user_locked);
        std::string lock_error;
        BOOST_REQUIRE(wallet->UpdateLockedCoins(
            {anchor}, /*lock=*/false, /*persistent=*/true, &lock_error));
        BOOST_CHECK(!wallet->IsLockedCoin(anchor));
    }

    // Historical abandoned or conflicted spends do not reserve the
    // active-chain coin and therefore do not defeat this restriction-only
    // lock exception.  The exact quarantined claim still must be present.
    BOOST_REQUIRE(wallet->AddToWallet(claim_ref, TxStateInactive{}));
    BOOST_REQUIRE(wallet->AbandonTransaction(ordinary_ref->GetHash()));
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_CHECK(wallet->CanLockQuarantinedShadowPowClaimAnchor(anchor));
    }

    CMutableTransaction conflicted_spend;
    conflicted_spend.vin.emplace_back(anchor);
    conflicted_spend.vout.emplace_back(
        funding.vout[0].nValue - 3 * DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    const CTransactionRef conflicted_ref =
        MakeTransactionRef(std::move(conflicted_spend));
    uint256 conflicting_block_hash;
    int conflicting_block_height{-1};
    {
        LOCK(::cs_main);
        const CBlockIndex* tip =
            Assert(m_node.chainman)->ActiveChain().Tip();
        BOOST_REQUIRE(tip);
        conflicting_block_hash = tip->GetBlockHash();
        conflicting_block_height = tip->nHeight;
    }
    BOOST_REQUIRE(wallet->AddToWallet(
        conflicted_ref,
        TxStateConflicted{
            conflicting_block_hash, conflicting_block_height}));
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_CHECK_LT(
            wallet->GetTxDepthInMainChain(
                wallet->mapWallet.at(conflicted_ref->GetHash())),
            0);
        BOOST_CHECK(wallet->CanLockQuarantinedShadowPowClaimAnchor(anchor));
    }

    // A recovery-policy database outcome can become ambiguous after a
    // caller's typed-gate preflight. The final guarded publication boundary
    // must prefer that exact reason and reject before AddToWallet.
    const MockableData before_recovery_ambiguity_commit =
        GetMockableDatabase(*wallet).m_records;
    const size_t before_recovery_ambiguity_records = WITH_LOCK(
        wallet->cs_wallet, return wallet->mapWallet.size());
    {
        LOCK(wallet->cs_wallet);
        wallet->MarkShadowPowClaimRecoveryDatabaseAmbiguous();
    }
    mapValue_t recovery_ambiguous_metadata;
    recovery_ambiguous_metadata["comment"] = "PoW Claim";
    recovery_ambiguous_metadata[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
    refused_error.clear();
    refused_status = WalletCommitStatus::ACCEPTED;
    BOOST_CHECK(!wallet->CommitTransaction(
        claim_ref, std::move(recovery_ambiguous_metadata), {},
        &refused_error, &refused_status,
        ShadowPowClaimCommitAuthority{
            authority_generation,
            /*require_pow_mining_enabled=*/false,
            /*expected_coin_lock_generation=*/0,
            anchor}));
    BOOST_CHECK(refused_status == WalletCommitStatus::REJECTED_NOT_ADDED);
    BOOST_CHECK_EQUAL(
        refused_error,
        "wallet-claim-recovery-authority-changed-before-commit");
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet,
                                return wallet->mapWallet.size()),
                      before_recovery_ambiguity_records);
    BOOST_CHECK(GetMockableDatabase(*wallet).m_records ==
                before_recovery_ambiguity_commit);

    CWallet reloaded(
        m_node.chain.get(), "",
        DuplicateMockDatabase(wallet->GetDatabase()));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(!reloaded.IsShadowPowClaimRecoveryDatabaseAmbiguous());
    {
        LOCK(reloaded.cs_wallet);
        reloaded.SetLastBlockProcessed(
            conflicting_block_height, conflicting_block_hash);
        const CWalletTx& stored =
            reloaded.mapWallet.at(claim_ref->GetHash());
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(SHADOW_POW_QUARANTINE_MARKER_KEY), "1");
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY) == 0);
        BOOST_CHECK(!stored.isAbandoned());
        BOOST_CHECK(!stored.InMempool());
        BOOST_CHECK(reloaded.IsSpent(anchor));
        BOOST_CHECK(reloaded.IsQuarantinedShadowPowClaim(
            claim_ref->GetHash()));
    }
}

BOOST_FIXTURE_TEST_CASE(
    shadow_pow_claim_initial_write_failure_latches_ambiguity,
    WalletShadowPowQQP2TestingSetup)
{
    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    const CScript wallet_script =
        GetScriptForRawPubKey(wallet_key.GetPubKey());
    const CMutableTransaction funding = MakeDurabilityTestSpend(
        *m_coinbase_txns[0], /*index=*/0, coinbaseKey, wallet_script);
    CreateAndProcessBlock(
        {funding}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    auto baseline_wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return Assert(m_node.chainman)->ActiveChain()),
        wallet_key);
    const MockableData durable_before =
        GetMockableDatabase(*baseline_wallet).m_records;
    const COutPoint anchor{funding.GetHash(), 0};

    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(),
                 {'Q', 'Q', 'P', '2', 0, 0, 0, 0, 0, 0, 0, 0, 0});
    CMutableTransaction claim;
    claim.vin.emplace_back(anchor);
    claim.vout.emplace_back(
        funding.vout[0].nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    const CTransactionRef claim_ref = MakeTransactionRef(std::move(claim));
    BOOST_REQUIRE(TransactionHasShadowProof(*claim_ref));

    baseline_wallet->SetBroadcastTransactions(/*broadcast=*/false);
    MockableDatabase& database = GetMockableDatabase(*baseline_wallet);
    mapValue_t metadata;
    metadata["comment"] = "PoW Claim";
    metadata[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
    const ShadowPowClaimMiningGate commit_gate =
        baseline_wallet->GetShadowPowClaimMiningGate();
    BOOST_REQUIRE(!commit_gate.candidate_state_fingerprint.IsNull());
    const CScript quantum_payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x51)});
    CCoinControl selection_control;
    selection_control.m_allow_other_inputs = false;
    selection_control.m_avoid_address_reuse = false;
    ShadowPowClaimInput selected_input;
    bilingual_str selection_error;
    BOOST_REQUIRE(baseline_wallet->SelectShadowPowClaimInput(
                      std::nullopt, quantum_payout, nullptr, selection_control,
                      selected_input, selection_error, commit_gate) ==
                  ShadowPowClaimInputSelectionResult::SELECTED);
    const ShadowPowClaimCommitAuthority commit_authority{
        baseline_wallet->m_pow_wallet_authority_generation.load(
            std::memory_order_acquire),
        /*require_pow_mining_enabled=*/false,
        /*expected_coin_lock_generation=*/0,
        anchor,
        commit_gate.wallet_generation,
        commit_gate.candidate_state_fingerprint,
        commit_gate.active_tip,
        commit_gate.active_height,
        /*require_relay_clock_authority=*/true,
        commit_gate.relay_clock_high_water,
        commit_gate.relay_clock_median_time_past,
        commit_gate.classification_time,
        commit_gate.next_relay_expiry_time,
        commit_gate.next_legacy_relay_expiry_wall_time,
        commit_gate.legacy_relay_clock_high_water,
        selected_input};
    database.m_pass = false;
    std::string broadcast_error;
    WalletCommitStatus status{WalletCommitStatus::REJECTED_NOT_ADDED};
    BOOST_CHECK_EXCEPTION(
        baseline_wallet->CommitTransaction(
            claim_ref, std::move(metadata), {}, &broadcast_error, &status,
            commit_authority),
        std::runtime_error,
        HasReason("Wallet db error, transaction commit failed"));
    BOOST_CHECK(status == WalletCommitStatus::REJECTED_NOT_ADDED);
    BOOST_CHECK(status != WalletCommitStatus::PERSISTED_PENDING);
    BOOST_CHECK(
        baseline_wallet->IsShadowPowClaimRecoveryDatabaseAmbiguous());
    BOOST_CHECK(database.m_records == durable_before);
    BOOST_CHECK(!m_node.chain->isInMempool(claim_ref->GetHash()));
    {
        LOCK2(::cs_main, baseline_wallet->cs_wallet);
        BOOST_CHECK(!baseline_wallet->CanLockQuarantinedShadowPowClaimAnchor(
            anchor));
    }
    {
        LOCK(baseline_wallet->cs_wallet);
        const CWalletTx* transient =
            baseline_wallet->GetWalletTx(claim_ref->GetHash());
        BOOST_REQUIRE(transient);
        BOOST_CHECK_EQUAL(
            transient->mapValue.at(SHADOW_POW_QUARANTINE_MARKER_KEY),
            "1");
        BOOST_REQUIRE_EQUAL(transient->tx->vin.size(), 1U);
        BOOST_CHECK(transient->tx->vin.front().prevout == anchor);
        BOOST_CHECK(transient->mapValue.count(
            SHADOW_POW_LEGACY_CLEANUP_FOR_KEY) == 0);
        BOOST_CHECK(transient->mapValue.count(
            SHADOW_POW_RESOLUTION_SCHEMA_KEY) == 0);
    }
    const ShadowPowClaimMiningGate failed_gate =
        baseline_wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(failed_gate.recovery_database_ambiguous);
    BOOST_CHECK(failed_gate.action ==
                ShadowPowClaimMiningGateAction::UNSAFE);
    BOOST_CHECK(!failed_gate.MayCreateClaim());

    // Reload sees only the pre-attempt database. The transient wallet record,
    // spend reservation, and in-memory ambiguity latch do not survive.
    CWallet reloaded(
        m_node.chain.get(), "",
        DuplicateMockDatabase(baseline_wallet->GetDatabase()));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(!reloaded.IsShadowPowClaimRecoveryDatabaseAmbiguous());
    {
        LOCK(reloaded.cs_wallet);
        BOOST_CHECK(reloaded.GetWalletTx(claim_ref->GetHash()) == nullptr);
        BOOST_CHECK(!reloaded.IsSpent(anchor));
        BOOST_CHECK_EQUAL(reloaded.mapWallet.size(), 1U);
    }
}

BOOST_FIXTURE_TEST_CASE(
    incoming_shadow_proof_cannot_quarantine_or_pause_recipient_wallet,
    TestChain100Setup)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);

    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0, 0, 0, 0, 0, 0, 0, 0,
                               0});
    CMutableTransaction incoming;
    incoming.vin.emplace_back(COutPoint{uint256::ONE, 0});
    incoming.vout.emplace_back(COIN,
                               GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    incoming.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    const CTransactionRef incoming_ref = MakeTransactionRef(std::move(incoming));
    BOOST_REQUIRE(TransactionHasShadowProof(*incoming_ref));
    BOOST_REQUIRE(wallet->AddToWallet(incoming_ref, TxStateInactive{}));

    // A claimant can pay a victim wallet without possessing any victim key.
    // The incoming history entry remains visible for audit, but it has no
    // authority to occupy the victim's local single-flight slot or pause its
    // miner after the transaction disappears.
    BOOST_CHECK_EQUAL(wallet->CountUnresolvedShadowPowClaims(), 0U);
    BOOST_CHECK_EQUAL(wallet->CountLiveShadowPowClaims(), 0U);
    BOOST_CHECK_EQUAL(wallet->CountQuarantinedShadowPowClaims(), 0U);
    BOOST_CHECK(!wallet->QuarantineShadowPowClaim(incoming_ref->GetHash()));
    const ShadowPowClaimRecoveryInventory inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    // Foreign carriers remain in mapWallet for ordinary audit/history, but
    // are intentionally absent from the bounded local-authority inventory.
    // Otherwise an external sender could exhaust the local claim cap and
    // pause an unrelated wallet's miner.
    BOOST_CHECK(inventory.components.empty());
    BOOST_CHECK_EQUAL(inventory.raw_claim_objects, 0U);

    const ShadowPowClaimMiningGate gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(gate.coherent);
    BOOST_CHECK(gate.action ==
                ShadowPowClaimMiningGateAction::CREATE_NEW_ANCHOR);
    BOOST_CHECK(gate.MayCreateNewAnchorClaim());
    BOOST_CHECK_EQUAL(gate.unresolved_components, 0U);
    BOOST_CHECK_EQUAL(gate.family_claims, 0U);
    BOOST_CHECK_EQUAL(gate.live_claims, 0U);
    BOOST_CHECK_EQUAL(gate.eligible_claims, 0U);
    BOOST_CHECK_EQUAL(gate.unsafe_claims, 0U);
    BOOST_CHECK_EQUAL(gate.unsafe_components, 0U);

    // Local provenance corruption is never hidden by the audit-only exception.
    // A record marked from-me without an authenticated wallet debit must fail
    // closed instead of being treated as a harmless incoming payment.
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK(!wallet->IsQuarantinedShadowPowClaim(
            incoming_ref->GetHash()));
        CWalletTx& corrupted =
            wallet->mapWallet.at(incoming_ref->GetHash());
        corrupted.fFromMe = true;
        wallet->RefreshShadowPowClaimIndexEntryLocked(corrupted);
        wallet->MarkShadowPowClaimCandidateStateChangedLocked();
    }
    const ShadowPowClaimMiningGate corrupted_gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(corrupted_gate.action ==
                ShadowPowClaimMiningGateAction::UNSAFE);
    BOOST_CHECK(corrupted_gate.HasUnsafeClaims());
    BOOST_CHECK(!corrupted_gate.MayCreateClaim());
    BOOST_CHECK_EQUAL(corrupted_gate.unresolved_components, 1U);
    BOOST_CHECK_EQUAL(corrupted_gate.unsafe_components, 1U);
    BOOST_CHECK_EQUAL(corrupted_gate.unsafe_claims, 1U);

    // A wallet-tip mismatch zeros the aggregate gate counters before this
    // corrupted record can be classified. That cannot turn the record into an
    // apparently empty wallet or authorize unrelated payout-key allocation.
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip && tip->pprev);
    {
        LOCK(wallet->cs_wallet);
        wallet->SetLastBlockProcessed(
            tip->pprev->nHeight, tip->pprev->GetBlockHash());
    }
    const ShadowPowClaimMiningGate incoherent_gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(!incoherent_gate.coherent);
    BOOST_CHECK_EQUAL(incoherent_gate.unresolved_components, 0U);
    const size_t quantum_keys_before = WITH_LOCK(
        wallet->cs_wallet, return wallet->ListQuantumKeyInfos().size());
    bilingual_str start_error;
    bool created_payout{true};
    BOOST_REQUIRE_MESSAGE(
        wallet->SetPowMining(
            /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/1,
            start_error, &created_payout,
            /*allow_new_payout_key=*/true),
        start_error.original);
    BOOST_CHECK(!created_payout);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(wallet->cs_wallet,
                  return wallet->ListQuantumKeyInfos().size()),
        quantum_keys_before);
    BOOST_CHECK(WITH_LOCK(
        wallet->cs_wallet,
        return wallet->m_pow_payout_quantum.empty()));
    wallet->StopPowMining();
}

BOOST_FIXTURE_TEST_CASE(
    incoming_shadow_proof_with_wallet_authored_ordinary_descendant_remains_audit_only,
    TestChain100Setup)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);

    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0, 0, 0, 0, 0, 0, 0, 0,
                               0});
    CMutableTransaction incoming;
    incoming.vin.emplace_back(COutPoint{uint256::ONE, 0});
    incoming.vout.emplace_back(COIN,
                               GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    incoming.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    const CTransactionRef incoming_ref = MakeTransactionRef(std::move(incoming));
    BOOST_REQUIRE(wallet->AddToWallet(incoming_ref, TxStateInactive{}));

    CMutableTransaction ordinary;
    ordinary.vin.emplace_back(COutPoint{incoming_ref->GetHash(), 0});
    ordinary.vout.emplace_back(
        COIN - 1000, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    const CTransactionRef ordinary_ref =
        MakeTransactionRef(std::move(ordinary));
    BOOST_REQUIRE(!TransactionHasShadowProof(*ordinary_ref));
    BOOST_REQUIRE(wallet->AddToWallet(ordinary_ref, TxStateInactive{}));

    const ShadowPowClaimRecoveryInventory inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    BOOST_CHECK(inventory.components.empty());
    BOOST_CHECK_EQUAL(inventory.raw_claim_objects, 0U);

    const ShadowPowClaimMiningGate gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(gate.action ==
                ShadowPowClaimMiningGateAction::CREATE_NEW_ANCHOR);
    BOOST_CHECK(gate.MayCreateNewAnchorClaim());
    BOOST_CHECK_EQUAL(gate.unresolved_components, 0U);
    BOOST_CHECK_EQUAL(gate.unsafe_components, 0U);

    // The audit-only classification is stable across a wallet-tip mismatch.
    // Neither the incoming proof nor an ordinary spend of its received output
    // authenticates the proof's external input as a local claim anchor.
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    const CBlockIndex* parent = WITH_LOCK(
        ::cs_main,
        return Assert(m_node.chainman)->ActiveChain()[tip->nHeight - 1]);
    BOOST_REQUIRE(parent);
    {
        LOCK(wallet->cs_wallet);
        wallet->SetLastBlockProcessed(
            parent->nHeight, parent->GetBlockHash());
        BOOST_REQUIRE(wallet->m_pow_payout_quantum.empty());
    }
    const ShadowPowClaimRecoveryInventory incoherent =
        wallet->GetShadowPowClaimRecoveryInventory();
    BOOST_CHECK(!incoherent.wallet_tip_matches);
    BOOST_CHECK_EQUAL(incoherent.raw_claim_objects, 0U);
    const size_t quantum_keys_before = WITH_LOCK(
        wallet->cs_wallet, return wallet->ListQuantumKeyInfos().size());
    bilingual_str start_error;
    bool created_payout{true};
    BOOST_REQUIRE_MESSAGE(
        wallet->SetPowMining(
            /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/1,
            start_error, &created_payout,
            /*allow_new_payout_key=*/true),
        start_error.original);
    BOOST_CHECK(created_payout);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(wallet->cs_wallet,
                  return wallet->ListQuantumKeyInfos().size()),
        quantum_keys_before + 1);
    BOOST_CHECK(!WITH_LOCK(
        wallet->cs_wallet, return wallet->m_pow_payout_quantum.empty()));
    wallet->StopPowMining();
}

static CMutableTransaction TestSimpleSpend(const CTransaction& from, uint32_t index, const CKey& key, const CScript& pubkey)
{
    CMutableTransaction mtx;
    mtx.vout.emplace_back(from.vout[index].nValue - DEFAULT_TRANSACTION_MAXFEE, pubkey);
    mtx.vin.push_back({CTxIn{from.GetHash(), index}});
    FillableSigningProvider keystore;
    keystore.AddKey(key);
    std::map<COutPoint, Coin> coins;
    coins[mtx.vin[0].prevout].out = from.vout[index];
    std::map<int, bilingual_str> input_errors;
    BOOST_CHECK(SignTransaction(mtx, &keystore, coins, SIGHASH_ALL, input_errors));
    return mtx;
}

static void AddKey(CWallet& wallet, const CKey& key)
{
    LOCK(wallet.cs_wallet);
    FlatSigningProvider provider;
    std::string error;
    std::unique_ptr<Descriptor> desc = Parse("combo(" + EncodeSecret(key) + ")", provider, error, /* require_checksum=*/ false);
    assert(desc);
    WalletDescriptor w_desc(std::move(desc), 0, 0, 1, 1);
    if (!wallet.AddWalletDescriptor(w_desc, provider, "", false)) assert(false);
}

BOOST_FIXTURE_TEST_CASE(shadow_pow_claim_preserves_mature_legacy_stake_reserve,
                        WalletShadowPowQQP2TestingSetup)
{
    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    const CScript wallet_script =
        GetScriptForRawPubKey(wallet_key.GetPubKey());
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        wallet_key);

    const CBlockIndex* confirmation_block = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain()[1]);
    BOOST_REQUIRE(confirmation_block);
    auto add_confirmed_coin = [&](uint8_t tag, CAmount value) {
        CMutableTransaction funding;
        funding.vin.emplace_back(COutPoint{uint256{tag}, 0});
        funding.vout.emplace_back(value, wallet_script);
        const CTransactionRef tx = MakeTransactionRef(std::move(funding));
        BOOST_REQUIRE(wallet->AddToWallet(
            tx, TxStateConfirmed{confirmation_block->GetBlockHash(),
                                 confirmation_block->nHeight, 1}));
        const COutPoint outpoint{tx->GetHash(), 0};
        {
            LOCK(::cs_main);
            Assert(m_node.chainman)
                ->ActiveChainstate()
                .CoinsTip()
                .AddCoin(
                    outpoint,
                    Coin{tx->vout.at(0), confirmation_block->nHeight,
                         /*coinbase=*/false, /*coinstake=*/false,
                         tx->nTime},
                    /*possible_overwrite=*/false);
        }
        return outpoint;
    };

    const COutPoint first = add_confirmed_coin(0x41, 10 * COIN);
    const CScript quantum_payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x51)});
    CCoinControl control;
    control.m_allow_other_inputs = false;
    control.m_avoid_address_reuse = false;
    control.m_min_depth = 1;
    ShadowPowClaimInput selected;
    bilingual_str error;

    wallet->SetStakingEnabled(true);
    ShadowPowClaimMiningGate selection_gate =
        wallet->GetShadowPowClaimMiningGate();
    {
        const ShadowPowClaimStakeReserveInfo info =
            wallet->GetShadowPowClaimStakeReserveInfo();
        BOOST_CHECK(info.wallet_tip_matches);
        BOOST_CHECK_EQUAL(info.configured_reserve_coins, 1);
        BOOST_CHECK_EQUAL(info.mature_stakeable_legacy_coins, 1U);
        BOOST_CHECK_EQUAL(info.mature_stakeable_legacy_weight, 10 * COIN);
        BOOST_CHECK_EQUAL(info.reserved_stake_coins, 1U);
        BOOST_CHECK_EQUAL(info.reserved_stake_weight, 10 * COIN);
        BOOST_CHECK_EQUAL(info.claim_coins_after_reserve, 0U);
        BOOST_CHECK(info.last_stake_coin_guard);
        BOOST_CHECK(
            wallet->SelectShadowPowClaimInput(
                std::nullopt, quantum_payout, nullptr, control, selected,
                error, selection_gate) ==
            ShadowPowClaimInputSelectionResult::STAKE_RESERVE_PROTECTED);
    }
    BOOST_CHECK(error.original.find("protect 1 mature legacy staking coin") !=
                std::string::npos);

    // The reserve consumes the authoritative staking predicate. A coin below
    // the wallet's configured staking minimum is not protected and remains a
    // valid independent Gold Rush fee input.
    const CAmount original_min_staking_amount =
        wallet->m_min_staking_amount;
    wallet->m_min_staking_amount = 11 * COIN;
    selection_gate = wallet->GetShadowPowClaimMiningGate();
    {
        const ShadowPowClaimStakeReserveInfo info =
            wallet->GetShadowPowClaimStakeReserveInfo();
        BOOST_CHECK_EQUAL(info.mature_stakeable_legacy_coins, 0U);
        BOOST_CHECK_EQUAL(info.reserved_stake_coins, 0U);
        BOOST_CHECK(wallet->SelectShadowPowClaimInput(
                        std::nullopt, quantum_payout, nullptr, control,
                        selected, error, selection_gate) ==
                    ShadowPowClaimInputSelectionResult::SELECTED);
        BOOST_CHECK(selected.outpoint == first);
    }
    wallet->m_min_staking_amount = original_min_staking_amount;

    // A protected coin that cannot satisfy fee policy must report the fee
    // failure, not claim that the stake reserve was the deciding blocker.
    const CAmount original_max_fee = wallet->m_default_max_tx_fee;
    wallet->m_default_max_tx_fee = 0;
    selection_gate = wallet->GetShadowPowClaimMiningGate();
    {
        BOOST_CHECK(
            wallet->SelectShadowPowClaimInput(
                std::nullopt, quantum_payout, nullptr, control, selected,
                error, selection_gate) ==
            ShadowPowClaimInputSelectionResult::FEE_EXCEEDS_MAX);
    }
    wallet->m_default_max_tx_fee = original_max_fee;

    wallet->SetStakingEnabled(false);
    selection_gate = wallet->GetShadowPowClaimMiningGate();
    {
        BOOST_CHECK(wallet->SelectShadowPowClaimInput(
                        std::nullopt, quantum_payout, nullptr, control,
                        selected, error, selection_gate) ==
                    ShadowPowClaimInputSelectionResult::SELECTED);
        BOOST_CHECK(selected.outpoint == first);
    }

    const COutPoint second = add_confirmed_coin(0x42, 20 * COIN);
    wallet->SetStakingEnabled(true);
    selection_gate = wallet->GetShadowPowClaimMiningGate();
    {
        const ShadowPowClaimStakeReserveInfo info =
            wallet->GetShadowPowClaimStakeReserveInfo();
        BOOST_CHECK_EQUAL(info.mature_stakeable_legacy_coins, 2U);
        BOOST_CHECK_EQUAL(info.mature_stakeable_legacy_weight, 30 * COIN);
        BOOST_CHECK_EQUAL(info.reserved_stake_coins, 1U);
        BOOST_CHECK_EQUAL(info.reserved_stake_weight, 20 * COIN);
        BOOST_CHECK_EQUAL(info.claim_coins_after_reserve, 1U);
        BOOST_CHECK(!info.last_stake_coin_guard);
        BOOST_CHECK(wallet->SelectShadowPowClaimInput(
                        std::nullopt, quantum_payout, nullptr, control,
                        selected, error, selection_gate) ==
                    ShadowPowClaimInputSelectionResult::SELECTED);
        BOOST_CHECK(selected.outpoint == first);
        BOOST_CHECK(selected.outpoint != second);
    }

    // Wallet ordering prefers the smaller A, but a stale active-chain A must
    // not hide the later valid B. One invocation checks only its deterministic
    // winner, retires a stale index entry, and requires a fresh snapshot before
    // selecting B. It must not extend the global-lock checkpoint into a scan.
    wallet->SetStakingEnabled(false);
    selection_gate = wallet->GetShadowPowClaimMiningGate();
    Coin stale_first;
    {
        LOCK(::cs_main);
        BOOST_REQUIRE(Assert(m_node.chainman)
                          ->ActiveChainstate()
                          .CoinsTip()
                          .SpendCoin(first, &stale_first));
    }
    BOOST_CHECK(wallet->SelectShadowPowClaimInput(
                    std::nullopt, quantum_payout, nullptr, control,
                    selected, error, selection_gate) ==
                ShadowPowClaimInputSelectionResult::SNAPSHOT_DRIFT);
    BOOST_CHECK(selected.outpoint.IsNull());
    selection_gate = wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(wallet->SelectShadowPowClaimInput(
                    std::nullopt, quantum_payout, nullptr, control,
                    selected, error, selection_gate) ==
                ShadowPowClaimInputSelectionResult::SELECTED);
    BOOST_CHECK(selected.outpoint == second);
    {
        LOCK(::cs_main);
        Assert(m_node.chainman)
            ->ActiveChainstate()
            .CoinsTip()
            .AddCoin(first, std::move(stale_first),
                     /*possible_overwrite=*/false);
    }
    wallet->SetStakingEnabled(true);

    // Reserve policy and telemetry are wallet-scoped. A second wallet on the
    // same chain cannot inherit the first wallet's enabled state, coins, or
    // protected outpoints.
    CKey peer_key;
    peer_key.MakeNewKey(/*fCompressed=*/true);
    const CScript peer_script =
        GetScriptForRawPubKey(peer_key.GetPubKey());
    auto peer_wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        peer_key);
    CMutableTransaction peer_funding;
    peer_funding.vin.emplace_back(COutPoint{uint256{0x43}, 0});
    peer_funding.vout.emplace_back(15 * COIN, peer_script);
    const CTransactionRef peer_tx =
        MakeTransactionRef(std::move(peer_funding));
    BOOST_REQUIRE(peer_wallet->AddToWallet(
        peer_tx, TxStateConfirmed{confirmation_block->GetBlockHash(),
                                  confirmation_block->nHeight, 1}));
    {
        LOCK(::cs_main);
        Assert(m_node.chainman)
            ->ActiveChainstate()
            .CoinsTip()
            .AddCoin(
                COutPoint{peer_tx->GetHash(), 0},
                Coin{peer_tx->vout.at(0), confirmation_block->nHeight,
                     /*coinbase=*/false, /*coinstake=*/false,
                     peer_tx->nTime},
                /*possible_overwrite=*/false);
    }
    peer_wallet->SetStakingEnabled(false);
    const ShadowPowClaimMiningGate peer_selection_gate =
        peer_wallet->GetShadowPowClaimMiningGate();
    {
        const ShadowPowClaimStakeReserveInfo peer_info =
            peer_wallet->GetShadowPowClaimStakeReserveInfo();
        BOOST_CHECK(!peer_info.staking_enabled);
        BOOST_CHECK_EQUAL(peer_info.mature_stakeable_legacy_coins, 1U);
        BOOST_CHECK_EQUAL(peer_info.reserved_stake_coins, 0U);
        BOOST_CHECK(peer_wallet->SelectShadowPowClaimInput(
                        std::nullopt, quantum_payout, nullptr, control,
                        selected, error, peer_selection_gate) ==
                    ShadowPowClaimInputSelectionResult::SELECTED);
        BOOST_CHECK(selected.outpoint == COutPoint(peer_tx->GetHash(), 0));
    }
    {
        const ShadowPowClaimStakeReserveInfo original_info =
            wallet->GetShadowPowClaimStakeReserveInfo();
        BOOST_CHECK(original_info.staking_enabled);
        BOOST_CHECK_EQUAL(original_info.reserved_stake_coins, 1U);
        BOOST_CHECK_EQUAL(original_info.reserved_stake_weight, 20 * COIN);
    }
    wallet->SetStakingEnabled(false);
}

BOOST_FIXTURE_TEST_CASE(staking_telemetry_does_not_treat_zero_search_interval_as_stopped,
                        TestChain100Setup)
{
    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        wallet_key);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    wallet->SetStakingEnabled(true);
    wallet->m_cached_stake_weight = 10 * COIN;
    wallet->m_cached_stake_weight_height = tip->nHeight;
    wallet->m_last_coin_stake_search_interval = 0;
    wallet->PublishStakingTelemetry(
        StakingTelemetryState::SEARCHING, tip->GetBlockHash(), tip->nHeight,
        /*worker_running=*/true, "searching eligible stake coins");

    const StakingTelemetrySnapshot searching =
        wallet->GetStakingTelemetrySnapshot();
    BOOST_CHECK(searching.enabled);
    BOOST_CHECK(searching.worker_running);
    BOOST_CHECK(searching.eligible);
    BOOST_CHECK(searching.state == StakingTelemetryState::SEARCHING);
    BOOST_CHECK_EQUAL(searching.search_interval, 0);
    BOOST_CHECK_EQUAL(searching.weight, 10 * COIN);
    BOOST_CHECK_EQUAL(searching.tip_height, tip->nHeight);
    BOOST_CHECK(searching.tip == tip->GetBlockHash());

    wallet->SetStakingEnabled(false);
    const StakingTelemetrySnapshot disabled =
        wallet->GetStakingTelemetrySnapshot();
    BOOST_CHECK(!disabled.enabled);
    BOOST_CHECK(!disabled.worker_running);
    BOOST_CHECK(!disabled.eligible);
    BOOST_CHECK(disabled.state == StakingTelemetryState::DISABLED);
}

BOOST_FIXTURE_TEST_CASE(commit_refreshes_mempool_state_before_async_callbacks, TestChain100Setup)
{
    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    const CMutableTransaction funding = TestSimpleSpend(
        *m_coinbase_txns[0],
        /*index=*/0,
        coinbaseKey,
        GetScriptForRawPubKey(wallet_key.GetPubKey()));
    CreateAndProcessBlock({funding}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));

    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()),
        wallet_key);
    wallet->SetBroadcastTransactions(/*broadcast=*/true);
    SyncWithValidationInterfaceQueue();

    // Keep transactionAddedToMempool queued so the synchronous post-broadcast
    // refresh is the only way an immediate second send can trust and spend the
    // first transaction's change.
    std::promise<void> unblock_callbacks;
    CallFunctionInValidationInterfaceQueue([&unblock_callbacks] {
        unblock_callbacks.get_future().wait();
    });

    try {
        CKey recipient_key;
        recipient_key.MakeNewKey(/*fCompressed=*/true);
        const CRecipient recipient{PKHash{recipient_key.GetPubKey()}, COIN, /*subtract_fee=*/false};
        CCoinControl coin_control;
        constexpr int RANDOM_CHANGE_POSITION{-1};

        const auto first = CreateTransaction(*wallet, {recipient}, RANDOM_CHANGE_POSITION, coin_control);
        BOOST_REQUIRE_MESSAGE(first, util::ErrorString(first).original);
        BOOST_REQUIRE(wallet->CommitTransaction(first->tx, {}, {}));
        {
            LOCK(wallet->cs_wallet);
            BOOST_REQUIRE(wallet->mapWallet.at(first->tx->GetHash()).InMempool());
        }

        const auto second = CreateTransaction(*wallet, {recipient}, RANDOM_CHANGE_POSITION, coin_control);
        BOOST_REQUIRE_MESSAGE(second, util::ErrorString(second).original);
        BOOST_REQUIRE(wallet->CommitTransaction(second->tx, {}, {}));
        {
            LOCK(wallet->cs_wallet);
            BOOST_REQUIRE(wallet->mapWallet.at(second->tx->GetHash()).InMempool());
        }
    } catch (...) {
        unblock_callbacks.set_value();
        SyncWithValidationInterfaceQueue();
        throw;
    }

    unblock_callbacks.set_value();
    SyncWithValidationInterfaceQueue();
}

BOOST_FIXTURE_TEST_CASE(legacy_shadow_pow_cleanup_is_quarantined_without_rebroadcast_or_input_release, TestChain100Setup)
{
    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    const CMutableTransaction funding = TestSimpleSpend(
        *m_coinbase_txns[0],
        /*index=*/0,
        coinbaseKey,
        GetScriptForRawPubKey(wallet_key.GetPubKey()));
    CreateAndProcessBlock({funding}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));

    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()),
        wallet_key);
    wallet->SetBroadcastTransactions(/*broadcast=*/false);
    SyncWithValidationInterfaceQueue();

    const CMutableTransaction cleanup_mut = TestSimpleSpend(
        CTransaction{funding},
        /*index=*/0,
        wallet_key,
        funding.vout.at(0).scriptPubKey);
    const CTransactionRef cleanup = MakeTransactionRef(cleanup_mut);
    BOOST_REQUIRE_EQUAL(cleanup->vin.size(), 1U);
    BOOST_REQUIRE_EQUAL(cleanup->vout.size(), 1U);
    BOOST_CHECK(cleanup->vout.front().scriptPubKey == funding.vout.at(0).scriptPubKey);
    const COutPoint cleanup_input = cleanup->vin.front().prevout;
    const uint256 cleanup_txid = cleanup->GetHash();
    const mapValue_t legacy_metadata{
        {"comment", "PoW Claim Cleanup"},
        {"qq_shadow_pow_cleanup_for", uint256::ONE.GetHex()},
    };
    BOOST_REQUIRE(wallet->CommitTransaction(cleanup, legacy_metadata, {}));

    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& stored = wallet->mapWallet.at(cleanup_txid);
        BOOST_CHECK(stored.isUnconfirmed());
        BOOST_CHECK(!stored.InMempool());
        BOOST_CHECK(!stored.isAbandoned());
        BOOST_CHECK_EQUAL(stored.mapValue.at("qq_shadow_pow_cleanup_for"), uint256::ONE.GetHex());
        BOOST_CHECK(wallet->IsLegacyShadowPowCleanupFor(stored, uint256::ONE));
        BOOST_CHECK(!wallet->IsLegacyShadowPowCleanupFor(stored, uint256{2}));
        BOOST_CHECK(stored.mapValue.count("qq_shadow_pow_legacy_cleanup_quarantine") == 0);
        BOOST_CHECK(wallet->IsSpent(cleanup_input));
    }
    BOOST_CHECK(!wallet->TransactionCanBeAbandoned(cleanup_txid));
    BOOST_CHECK(!wallet->AbandonTransaction(cleanup_txid));

    wallet->SetBroadcastTransactions(/*broadcast=*/true);
    wallet->ResubmitWalletTransactions(/*relay=*/true, /*force=*/true);
    SyncWithValidationInterfaceQueue();

    BOOST_CHECK(!m_node.chain->isInMempool(cleanup_txid));
    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& stored = wallet->mapWallet.at(cleanup_txid);
        BOOST_CHECK(stored.isUnconfirmed());
        BOOST_CHECK(!stored.InMempool());
        BOOST_CHECK(!stored.isAbandoned());
        BOOST_CHECK_EQUAL(stored.mapValue.at("qq_shadow_pow_legacy_cleanup_quarantine"), "1");
        BOOST_CHECK(wallet->IsSpent(cleanup_input));
    }
}

BOOST_AUTO_TEST_CASE(legacy_cleanup_repair_is_bounded_durable_and_indexed)
{
    CWallet wallet(m_node.chain.get(), "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
    const auto add_record = [&](uint8_t domain, uint32_t index, bool legacy, bool managed) {
        CMutableTransaction tx;
        tx.vin.emplace_back(COutPoint{uint256{domain}, index});
        tx.vout.emplace_back(COIN, CScript{} << OP_TRUE);
        const auto ref = MakeTransactionRef(std::move(tx));
        BOOST_REQUIRE(wallet.AddToWallet(ref, TxStateInactive{}, [&](CWalletTx& record, bool) {
            if (legacy) record.mapValue[SHADOW_POW_LEGACY_CLEANUP_FOR_KEY] = uint256::ONE.GetHex();
            if (managed) record.mapValue[SHADOW_POW_RESOLUTION_SCHEMA_KEY] = "malformed";
            return true;
        }));
        return ref->GetHash();
    };
    for (uint32_t index = 0; index < 1024; ++index) add_record(1, index, false, false);
    std::vector<uint256> legacy;
    for (uint32_t index = 0; index < SHADOW_POW_CLAIM_OWNERSHIP_SLICE + 6; ++index) {
        legacy.push_back(add_record(2, index, true, false));
    }
    const uint256 managed = add_record(3, 0, true, true);

    CWallet failing(m_node.chain.get(), "", DuplicateMockDatabase(wallet.GetDatabase()));
    BOOST_REQUIRE_EQUAL(failing.LoadWallet(), DBErrors::LOAD_OK);
    auto& failed_db = GetMockableDatabase(failing);
    const MockableData before_failure = failed_db.m_records;
    failed_db.m_write_calls = 0;
    failed_db.m_fail_write_at = 2;
    failing.RepairStaleShadowTransactions(/*force=*/true);
    BOOST_CHECK(failing.IsShadowPowClaimRecoveryDatabaseAmbiguous());
    BOOST_CHECK(failed_db.m_records == before_failure);
    {
        LOCK(failing.cs_wallet);
        for (const uint256& txid : legacy) {
            BOOST_CHECK(failing.mapWallet.at(txid).mapValue.count("qq_shadow_pow_legacy_cleanup_quarantine") == 0);
        }
    }

    auto& database = GetMockableDatabase(wallet);
    database.m_write_calls = 0;
    wallet.RepairStaleShadowTransactions(/*force=*/true);
    BOOST_CHECK_EQUAL(database.m_write_calls, SHADOW_POW_CLAIM_OWNERSHIP_SLICE);
    BOOST_CHECK(database.m_last_txn_durable);
    database.m_write_calls = 0;
    wallet.RepairStaleShadowTransactions(/*force=*/true);
    BOOST_CHECK_EQUAL(database.m_write_calls, 6U);
    database.m_write_calls = 0;
    wallet.RepairStaleShadowTransactions(/*force=*/true);
    BOOST_CHECK_EQUAL(database.m_write_calls, 0U);
    {
        LOCK(wallet.cs_wallet);
        for (const uint256& txid : legacy) {
            BOOST_CHECK_EQUAL(wallet.mapWallet.at(txid).mapValue.at("qq_shadow_pow_legacy_cleanup_quarantine"), "1");
        }
        BOOST_CHECK(wallet.mapWallet.at(managed).mapValue.count("qq_shadow_pow_legacy_cleanup_quarantine") == 0);
    }
    CWallet reloaded(m_node.chain.get(), "", DuplicateMockDatabase(wallet.GetDatabase()));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    auto& reloaded_db = GetMockableDatabase(reloaded);
    reloaded_db.m_write_calls = 0;
    reloaded.RepairStaleShadowTransactions(/*force=*/true);
    BOOST_CHECK_EQUAL(reloaded_db.m_write_calls, 0U);
}

BOOST_FIXTURE_TEST_CASE(shadow_pow_claim_inventory_is_tip_pinned_and_reorg_safe, TestChain100Setup)
{
    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    const CScript wallet_script = GetScriptForRawPubKey(wallet_key.GetPubKey());
    const CMutableTransaction funding = TestSimpleSpend(
        *m_coinbase_txns[0],
        /*index=*/0,
        coinbaseKey,
        wallet_script);
    CreateAndProcessBlock({funding}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));

    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()),
        wallet_key);
    BOOST_REQUIRE(m_node.chain->isReadyToBroadcast());

    auto make_shadow_claim = [](const COutPoint& input, CAmount value, const CScript& output_script) {
        std::vector<unsigned char> proof = GetShadowPrefix();
        proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0, 0, 0, 0, 0, 0, 0, 0, 0});
        CMutableTransaction claim;
        claim.vin.emplace_back(input);
        claim.vout.emplace_back(value, output_script);
        claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
        return MakeTransactionRef(std::move(claim));
    };
    auto sync_wallet_tip = [&] {
        LOCK2(::cs_main, wallet->cs_wallet);
        const CBlockIndex* tip = Assert(m_node.chainman)->ActiveChain().Tip();
        BOOST_REQUIRE(tip);
        wallet->SetLastBlockProcessed(tip->nHeight, tip->GetBlockHash());
    };
    auto check_inventory = [&](size_t raw, size_t actionable, size_t resolved, size_t indeterminate) {
        const ShadowPowClaimInventory inventory = wallet->GetShadowPowClaimInventory();
        BOOST_CHECK(inventory.wallet_tip_matches);
        BOOST_CHECK_EQUAL(inventory.raw_quarantined_claims, raw);
        BOOST_CHECK_EQUAL(inventory.actionable_claims, actionable);
        BOOST_CHECK_EQUAL(inventory.resolved_on_active_chain_claims, resolved);
        BOOST_CHECK_EQUAL(inventory.indeterminate_claims, indeterminate);
        BOOST_CHECK_EQUAL(inventory.BlockingClaims(), actionable + indeterminate);
        BOOST_CHECK_EQUAL(wallet->CountQuarantinedShadowPowClaims(), actionable + indeterminate);
    };

    const CTransactionRef funding_ref = MakeTransactionRef(funding);
    const COutPoint funding_outpoint{funding_ref->GetHash(), 0};
    const CTransactionRef stale_claim = make_shadow_claim(
        funding_outpoint,
        funding.vout[0].nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    BOOST_REQUIRE(TransactionHasShadowProof(*stale_claim));
    BOOST_REQUIRE(wallet->AddToWallet(stale_claim, TxStateInactive{}));

    // This deliberately synthetic legacy record has no durable authored or
    // quarantine provenance. The shared classifier must fail closed as
    // indeterminate while still keeping claim creation blocked.
    check_inventory(/*raw=*/1, /*actionable=*/0, /*resolved=*/0, /*indeterminate=*/1);

    const int funding_height = WITH_LOCK(
        ::cs_main,
        return Assert(m_node.chainman)->ActiveChain().Height());
    const CMutableTransaction competing_spend = CreateValidMempoolTransaction(
        funding_ref,
        /*input_vout=*/0,
        funding_height,
        wallet_key,
        wallet_script,
        funding.vout[0].nValue - DEFAULT_TRANSACTION_MAXFEE,
        /*submit=*/true);

    // A mempool-only conflict is not an active-chain resolution. Direct
    // CoinsTip classification must continue to fail closed and block mining.
    check_inventory(/*raw=*/1, /*actionable=*/0, /*resolved=*/0, /*indeterminate=*/1);

    const CBlock resolution_block = CreateAndProcessBlock(
        {competing_spend}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    sync_wallet_tip();

    // Model a legacy wallet record that did not learn the conflict edge. The
    // raw QQSPROOF history remains intact, while the active-chain spend of its
    // authenticated anchor proves that this component is nonblocking.
    check_inventory(/*raw=*/1, /*actionable=*/0, /*resolved=*/1, /*indeterminate=*/0);

    // Import/reindex makes the active CoinsTip unsuitable for a new mining
    // decision. Even though the same anchor is spent on the last processed
    // tip, the lightweight one-second gate must fail closed until the chain is
    // ready again. Keep the global flag scoped so a test failure cannot leak
    // importing state into later fixtures.
    {
        struct ScopedImporting {
            std::atomic<bool>& flag;
            explicit ScopedImporting(std::atomic<bool>& importing)
                : flag(importing)
            {
                flag = true;
            }
            ~ScopedImporting() { flag = false; }
        } importing{Assert(m_node.chainman)->m_blockman.m_importing};
        BOOST_CHECK(!m_node.chain->isReadyToBroadcast());
        BOOST_CHECK_EQUAL(wallet->CountQuarantinedShadowPowClaims(), 1U);
    }
    BOOST_REQUIRE(m_node.chain->isReadyToBroadcast());
    BOOST_CHECK_EQUAL(wallet->CountQuarantinedShadowPowClaims(), 0U);
    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& stored = wallet->mapWallet.at(stale_claim->GetHash());
        BOOST_CHECK(stored.isUnconfirmed());
        BOOST_CHECK(!stored.InMempool());
        BOOST_CHECK(!stored.isAbandoned());
    }

    CBlockIndex* resolution_index = WITH_LOCK(
        ::cs_main,
        return Assert(m_node.chainman)->m_blockman.LookupBlockIndex(resolution_block.GetHash()));
    BOOST_REQUIRE(resolution_index);
    BlockValidationState state;
    BOOST_REQUIRE(Assert(m_node.chainman)->ActiveChainstate().InvalidateBlock(state, resolution_index));
    SyncWithValidationInterfaceQueue();
    sync_wallet_tip();

    // Disconnecting the active-chain spend restores the anchor. Classification
    // is reversible, so the same retained record immediately blocks again in
    // its provenance-incomplete, indeterminate state.
    check_inventory(/*raw=*/1, /*actionable=*/0, /*resolved=*/0, /*indeterminate=*/1);

    const CTransactionRef competing_ref = MakeTransactionRef(competing_spend);
    BOOST_REQUIRE(wallet->AddToWallet(competing_ref, TxStateInMempool{}));
    const CTransactionRef malformed_ancestry_claim = make_shadow_claim(
        COutPoint{competing_ref->GetHash(), 0},
        competing_spend.vout[0].nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    BOOST_REQUIRE(TransactionHasShadowProof(*malformed_ancestry_claim));
    BOOST_REQUIRE(wallet->AddToWallet(malformed_ancestry_claim, TxStateInactive{}));

    // A claim rooted in an unconfirmed ordinary transaction has no
    // authenticated confirmed anchor. It must be indeterminate, never inferred
    // resolved merely because an outpoint is absent from CoinsTip.
    check_inventory(/*raw=*/2, /*actionable=*/0, /*resolved=*/0, /*indeterminate=*/2);

    {
        LOCK2(::cs_main, wallet->cs_wallet);
        const CBlockIndex* tip = Assert(m_node.chainman)->ActiveChain().Tip();
        BOOST_REQUIRE(tip && tip->pprev);
        wallet->SetLastBlockProcessed(tip->pprev->nHeight, tip->pprev->GetBlockHash());
    }
    const ShadowPowClaimInventory stale_snapshot = wallet->GetShadowPowClaimInventory();
    BOOST_CHECK(!stale_snapshot.wallet_tip_matches);
    BOOST_CHECK_EQUAL(stale_snapshot.raw_quarantined_claims, 2U);
    BOOST_CHECK_EQUAL(stale_snapshot.actionable_claims, 0U);
    BOOST_CHECK_EQUAL(stale_snapshot.resolved_on_active_chain_claims, 0U);
    BOOST_CHECK_EQUAL(stale_snapshot.indeterminate_claims, 2U);
    BOOST_CHECK_EQUAL(stale_snapshot.BlockingClaims(), 2U);
    BOOST_CHECK_EQUAL(wallet->CountQuarantinedShadowPowClaims(), 2U);
    sync_wallet_tip();
}

static void CheckLiveUnspentStakeIndex(CWallet& wallet)
{
    std::set<COutPoint> expected;
    std::set<COutPoint> indexed;
    {
        LOCK(wallet.cs_wallet);
        for (const auto& [txid, wtx] : wallet.mapWallet) {
            if (!wtx.tx) continue;
            for (uint32_t output = 0; output < wtx.tx->vout.size(); ++output) {
                const COutPoint outpoint{txid, output};
                if (!wallet.IsSpent(outpoint)) expected.insert(outpoint);
            }
        }
        indexed = wallet.GetLiveUnspentStakeOutpoints();
    }
    BOOST_CHECK(expected == indexed);
    BOOST_CHECK_EQUAL(wallet.GetLiveUnspentStakeOutputCount(), expected.size());
}

BOOST_AUTO_TEST_CASE(live_unspent_stake_index_tracks_state_conflicts_zap_and_reload)
{
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);

    CMutableTransaction funding_mut;
    funding_mut.vin.emplace_back(COutPoint{uint256{1}, 0});
    funding_mut.vout.emplace_back(10 * COIN, CScript{} << OP_TRUE);
    const CTransactionRef funding = MakeTransactionRef(std::move(funding_mut));
    BOOST_REQUIRE(wallet.AddToWallet(funding, TxStateInMempool{}));
    CheckLiveUnspentStakeIndex(wallet);
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(wallet.GetLiveUnspentStakeOutpoints().count(COutPoint{funding->GetHash(), 0}));
    }

    CMutableTransaction spend_a_mut;
    spend_a_mut.vin.emplace_back(COutPoint{funding->GetHash(), 0});
    spend_a_mut.vout.emplace_back(9 * COIN, CScript{} << OP_TRUE);
    const CTransactionRef spend_a = MakeTransactionRef(std::move(spend_a_mut));
    BOOST_REQUIRE(wallet.AddToWallet(spend_a, TxStateInMempool{}));
    CheckLiveUnspentStakeIndex(wallet);
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(!wallet.GetLiveUnspentStakeOutpoints().count(COutPoint{funding->GetHash(), 0}));
    }

    // Abandoning and then reopening a spend models the input-availability
    // transitions used by stale-claim cleanup and reorg recovery.
    BOOST_REQUIRE(wallet.AddToWallet(
        spend_a, TxStateInactive{/*abandoned=*/true},
        [](CWalletTx& wtx, bool new_tx) {
            BOOST_CHECK(!new_tx);
            wtx.m_state = TxStateInactive{/*abandoned=*/true};
            return true;
        }));
    CheckLiveUnspentStakeIndex(wallet);
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(wallet.GetLiveUnspentStakeOutpoints().count(COutPoint{funding->GetHash(), 0}));
    }
    BOOST_REQUIRE(wallet.AddToWallet(spend_a, TxStateInMempool{}));

    CMutableTransaction spend_b_mut;
    spend_b_mut.vin.emplace_back(COutPoint{funding->GetHash(), 0});
    spend_b_mut.vout.emplace_back(8 * COIN, CScript{} << OP_TRUE);
    const CTransactionRef spend_b = MakeTransactionRef(std::move(spend_b_mut));
    BOOST_REQUIRE(wallet.AddToWallet(spend_b, TxStateInMempool{}));
    CheckLiveUnspentStakeIndex(wallet);

    // Removing one of two conflicting spends must not lose the other spend's
    // mapTxSpends entry or prematurely reopen the shared input.
    {
        LOCK(wallet.cs_wallet);
        std::vector<uint256> selected{spend_a->GetHash()};
        std::vector<uint256> removed;
        BOOST_REQUIRE_EQUAL(wallet.ZapSelectTx(selected, removed), DBErrors::LOAD_OK);
        BOOST_REQUIRE_EQUAL(removed.size(), 1U);
        BOOST_CHECK_EQUAL(removed.front(), spend_a->GetHash());
        BOOST_CHECK(!wallet.GetLiveUnspentStakeOutpoints().count(COutPoint{funding->GetHash(), 0}));
    }
    CheckLiveUnspentStakeIndex(wallet);

    {
        LOCK(wallet.cs_wallet);
        std::vector<uint256> selected{spend_b->GetHash()};
        std::vector<uint256> removed;
        BOOST_REQUIRE_EQUAL(wallet.ZapSelectTx(selected, removed), DBErrors::LOAD_OK);
        BOOST_REQUIRE_EQUAL(removed.size(), 1U);
        BOOST_CHECK(wallet.GetLiveUnspentStakeOutpoints().count(COutPoint{funding->GetHash(), 0}));
    }
    CheckLiveUnspentStakeIndex(wallet);

    // The index is memory-only and must reconstruct exactly from persisted
    // wallet transactions rather than becoming a second source of truth.
    CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(wallet.GetDatabase()));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    CheckLiveUnspentStakeIndex(reloaded);
    {
        LOCK(reloaded.cs_wallet);
        BOOST_CHECK(reloaded.GetLiveUnspentStakeOutpoints().count(COutPoint{funding->GetHash(), 0}));
    }
}

BOOST_AUTO_TEST_CASE(live_unspent_stake_index_is_bounded_by_live_outputs_not_history)
{
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);

    COutPoint previous{uint256{2}, 0};
    constexpr size_t HISTORY_LENGTH{512};
    for (size_t i = 0; i < HISTORY_LENGTH; ++i) {
        CMutableTransaction tx;
        tx.vin.emplace_back(previous);
        tx.vout.emplace_back((HISTORY_LENGTH - i + 1) * COIN, CScript{} << OP_TRUE);
        const CTransactionRef ref = MakeTransactionRef(std::move(tx));
        BOOST_REQUIRE(wallet.AddToWallet(ref, TxStateInMempool{}));
        previous = COutPoint{ref->GetHash(), 0};
    }

    CheckLiveUnspentStakeIndex(wallet);
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK_EQUAL(wallet.mapWallet.size(), HISTORY_LENGTH);
        BOOST_REQUIRE_EQUAL(wallet.GetLiveUnspentStakeOutpoints().size(), 1U);
        BOOST_CHECK(*wallet.GetLiveUnspentStakeOutpoints().begin() == previous);
    }
}

static void AddShadowWalletTestCoin(CCoinsViewCache& view, const COutPoint& outpoint, CAmount amount, const CScript& script)
{
    Coin coin;
    coin.out.nValue = amount;
    coin.out.scriptPubKey = script;
    coin.nHeight = 1;
    view.AddCoin(outpoint, std::move(coin), false);
}

static CTransactionRef MakeShadowWalletCoinbaseTx(const CScript& script)
{
    CMutableTransaction mtx;
    mtx.vin.resize(1);
    mtx.vin[0].prevout.SetNull();
    mtx.vout.push_back(CTxOut(1 * COIN, script));
    return MakeTransactionRef(std::move(mtx));
}

static CTransactionRef MakeShadowWalletCoinstakeTx(const CScript& target)
{
    CMutableTransaction mtx;
    mtx.vin.push_back(CTxIn{COutPoint{uint256::ONE, 1}});
    mtx.vout.push_back(CTxOut(0, CScript{}));
    mtx.vout.push_back(CTxOut(1 * COIN, target));
    return MakeTransactionRef(std::move(mtx));
}

static CTransactionRef MakeShadowWalletSignalTx(const CScript& target, const std::vector<unsigned char>& signal)
{
    CMutableTransaction mtx;
    mtx.vin.push_back(CTxIn{COutPoint{uint256{3}, 0}});
    mtx.vout.push_back(CTxOut(1 * COIN, target));
    mtx.vout.push_back(CTxOut(0, CScript{} << OP_RETURN << signal));
    return MakeTransactionRef(std::move(mtx));
}

static CBlockUndo MakeShadowWalletUndo(const CBlock& block, const std::map<size_t, CScript>& input_scripts)
{
    CBlockUndo undo;
    if (block.vtx.empty()) return undo;
    undo.vtxundo.resize(block.vtx.size() - 1);
    for (const auto& [tx_index, script] : input_scripts) {
        if (tx_index == 0 || tx_index > undo.vtxundo.size()) continue;
        Coin coin;
        coin.out = CTxOut(10'000 * COIN, script);
        coin.nHeight = 1;
        coin.nTime = SHADOW_EQUAL_FOOTING_TIME;
        undo.vtxundo[tx_index - 1].vprevout.push_back(std::move(coin));
    }
    return undo;
}

BOOST_FIXTURE_TEST_CASE(loadwallet_reconciles_with_production_chain_snapshot, TestChain100Setup)
{
    uint256 active_block_hash;
    int active_block_height{-1};
    {
        LOCK(Assert(m_node.chainman)->GetMutex());
        const CBlockIndex* tip = Assert(m_node.chainman->ActiveChain().Tip());
        active_block_hash = tip->GetBlockHash();
        active_block_height = tip->nHeight;
    }

    CWallet wallet(m_node.chain.get(), "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);

    CMutableTransaction active_tx;
    active_tx.vin.emplace_back(COutPoint{uint256{11}, 0});
    active_tx.vout.emplace_back(COIN, CScript{} << OP_TRUE);
    const CTransactionRef active_ref = MakeTransactionRef(std::move(active_tx));
    BOOST_REQUIRE(wallet.AddToWallet(active_ref, TxStateConfirmed{active_block_hash, active_block_height, 0}));

    const uint256 inactive_block_hash{12};
    CMutableTransaction inactive_tx;
    inactive_tx.vin.emplace_back(COutPoint{uint256{13}, 0});
    inactive_tx.vout.emplace_back(COIN, CScript{} << OP_TRUE);
    const CTransactionRef inactive_ref = MakeTransactionRef(std::move(inactive_tx));
    BOOST_REQUIRE(wallet.AddToWallet(inactive_ref, TxStateConfirmed{inactive_block_hash, active_block_height, 0}));

    CWallet reloaded(m_node.chain.get(), "", DuplicateMockDatabase(wallet.GetDatabase()));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(reloaded.cs_wallet);
        const CWalletTx* reloaded_active = reloaded.GetWalletTx(active_ref->GetHash());
        BOOST_REQUIRE(reloaded_active);
        const auto* confirmed = reloaded_active->state<TxStateConfirmed>();
        BOOST_REQUIRE(confirmed);
        BOOST_CHECK_EQUAL(confirmed->confirmed_block_hash, active_block_hash);
        BOOST_CHECK_EQUAL(confirmed->confirmed_block_height, active_block_height);

        const CWalletTx* reloaded_inactive = reloaded.GetWalletTx(inactive_ref->GetHash());
        BOOST_REQUIRE(reloaded_inactive);
        BOOST_CHECK(reloaded_inactive->state<TxStateInactive>());
    }
}

BOOST_AUTO_TEST_CASE(rgb_wallet_record_deserialization_bounds)
{
    DataStream oversized_ticker{};
    WriteCompactSize(oversized_ticker, MAX_RGB_WALLET_TICKER_CHARS + 1);
    RGBContractRecord contract;
    BOOST_CHECK_EXCEPTION(oversized_ticker >> contract, std::ios_base::failure, HasReason("String length limit exceeded"));

    DataStream oversized_allocations{};
    WriteCompactSize(oversized_allocations, MAX_RGB_WALLET_RECORD_VECTOR_ENTRIES + 1);
    RGBGenesisProofRecord genesis_proof;
    BOOST_CHECK_EXCEPTION(oversized_allocations >> genesis_proof, std::ios_base::failure, HasReason("RGB wallet vector length limit exceeded"));

    DataStream oversized_inputs{};
    oversized_inputs << uint256::ONE << uint256::ONE << uint32_t{0} << int64_t{1} << true;
    WriteCompactSize(oversized_inputs, MAX_RGB_WALLET_RECORD_VECTOR_ENTRIES + 1);
    RGBTransitionRecord transition;
    BOOST_CHECK_EXCEPTION(oversized_inputs >> transition, std::ios_base::failure, HasReason("RGB wallet vector length limit exceeded"));
}

class ShadowScheduleScope
{
    const int m_whitelist_height{SHADOW_WHITELIST_HEIGHT};
    const int m_reward_start_height{SHADOW_REWARD_START_HEIGHT};
    const int m_gold_rush_blocks{SHADOW_GOLD_RUSH_BLOCKS};
    const int m_phase1_end_height{SHADOW_PHASE1_END_HEIGHT};
    const int m_reward_end_height{SHADOW_REWARD_END_HEIGHT};

public:
    ~ShadowScheduleScope()
    {
        SHADOW_WHITELIST_HEIGHT = m_whitelist_height;
        SHADOW_REWARD_START_HEIGHT = m_reward_start_height;
        SHADOW_GOLD_RUSH_BLOCKS = m_gold_rush_blocks;
        SHADOW_PHASE1_END_HEIGHT = m_phase1_end_height;
        SHADOW_REWARD_END_HEIGHT = m_reward_end_height;
    }
};

class MockTimeScope
{
public:
    ~MockTimeScope() { SetMockTime(0); }
};

BOOST_AUTO_TEST_CASE(shadow_pow_claim_relay_ttl_guard_has_exact_boundaries)
{
    MockTimeScope time_scope;
    constexpr int64_t now{2'000'000'000};
    SetMockTime(now);
    m_wallet.SetBroadcastTransactions(/*broadcast=*/true);
    {
        LOCK2(::cs_main, m_wallet.cs_wallet);
        const CBlockIndex* tip =
            m_wallet.chain().chainman().ActiveChain().Tip();
        BOOST_REQUIRE(tip);
        // WalletTestingSetup constructs the wallet before validation
        // notifications are subscribed, so its processed-tip cursor is
        // intentionally unset. Make this relay-authority fixture coherent
        // before building the guarded snapshots below.
        m_wallet.SetLastBlockProcessed(
            tip->nHeight, tip->GetBlockHash());
    }

    const auto make_wallet_tx = [&](uint8_t seed, bool shadow_proof,
                                    int64_t received_time) {
        CMutableTransaction transaction;
        transaction.vin.emplace_back(
            COutPoint{uint256{seed}, /*n=*/0});
        transaction.vout.emplace_back(COIN, CScript{} << OP_TRUE);
        if (shadow_proof) {
            std::vector<unsigned char> proof = GetShadowPrefix();
            proof.insert(proof.end(),
                         {'Q', 'Q', 'P', '2', 0, 0, 0, 0, 0, 0, 0, 0, 0});
            transaction.vout.emplace_back(
                /*nValue=*/0, CScript{} << OP_RETURN << proof);
        }
        const CTransactionRef transaction_ref =
            MakeTransactionRef(std::move(transaction));
        BOOST_REQUIRE_EQUAL(
            TransactionHasShadowProof(*transaction_ref), shadow_proof);
        BOOST_REQUIRE(m_wallet.AddToWallet(
            transaction_ref, TxStateInactive{}));
        WITH_LOCK(
            m_wallet.cs_wallet,
            m_wallet.mapWallet.at(transaction_ref->GetHash()).nTimeReceived =
                received_time);
        return transaction_ref;
    };

    const auto submit_without_peer_relay = [&](const CTransactionRef& tx) {
        const ShadowPowClaimRecoveryInventory inventory =
            m_wallet.GetShadowPowClaimRecoveryInventory();
        ShadowPowClaimRecoveryBroadcastGuard guard;
        {
            LOCK2(::cs_main, m_wallet.cs_wallet);
            const CBlockIndex* tip =
                m_wallet.chain().chainman().ActiveChain().Tip();
            BOOST_REQUIRE(tip);
            guard.expected_wallet_tip = tip->GetBlockHash();
            guard.expected_wallet_height = tip->nHeight;
            guard.expected_wallet_generation =
                m_wallet.GetDatabase().nUpdateCounter.load();
            guard.expected_candidate_state_fingerprint =
                m_wallet.GetShadowPowClaimCandidateStateFingerprintLocked();
            const auto [schema_high_water, legacy_high_water] =
                m_wallet.GetShadowPowClaimRelayClockHighWatersForTesting();
            guard.require_relay_clock_authority = true;
            guard.expected_relay_clock_high_water =
                schema_high_water;
            guard.expected_relay_clock_median_time_past =
                tip->GetMedianTimePast();
            guard.expected_relay_clock_classification_time = std::max(
                schema_high_water,
                tip->GetMedianTimePast());
            guard.expected_relay_clock_next_transition =
                inventory.next_relay_expiry_time;
            guard.expected_relay_clock_next_legacy_wall_transition =
                inventory.next_legacy_relay_expiry_wall_time;
            guard.expected_legacy_relay_clock_high_water =
                legacy_high_water;
        }
        std::string error;
        const bool accepted = m_wallet.SubmitTxMemoryPoolAndRelay(
            tx->GetHash(), error, /*relay=*/false, &guard);
        BOOST_CHECK(WITH_LOCK(
            m_wallet.cs_wallet,
            return m_wallet.m_inflight_wallet_broadcasts.empty()));
        return std::pair{accepted, error};
    };

    // The final second inside the TTL must pass the wallet guard. The
    // synthetic transaction may still fail ordinary mempool policy, but it
    // must not be classified as expired by this wallet-only relay check.
    const CTransactionRef ttl_minus_one = make_wallet_tx(
        /*seed=*/201, /*shadow_proof=*/true,
        now - (SHADOW_POW_CLAIM_MEMPOOL_TTL_SECONDS - 1));
    const auto ttl_minus_one_result =
        submit_without_peer_relay(ttl_minus_one);
    BOOST_CHECK_NE(ttl_minus_one_result.second,
                   "shadow-proof-relay-ttl-expired");
    BOOST_CHECK_NE(ttl_minus_one_result.second,
                   "shadow-proof-relay-clock-guard-required");
    BOOST_CHECK_NE(ttl_minus_one_result.second,
                   "shadow-proof-relay-clock-changed");
    BOOST_CHECK_NE(ttl_minus_one_result.second,
                   "recovery-wallet-generation-changed");

    // Equality is expired: this stable error must be returned before the
    // transaction is reserved for broadcast.
    const CTransactionRef exact_ttl = make_wallet_tx(
        /*seed=*/202, /*shadow_proof=*/true,
        now - SHADOW_POW_CLAIM_MEMPOOL_TTL_SECONDS);
    const auto [exact_ttl_accepted, exact_ttl_error] =
        submit_without_peer_relay(exact_ttl);
    BOOST_CHECK(!exact_ttl_accepted);
    BOOST_CHECK_EQUAL(exact_ttl_error,
                      "shadow-proof-relay-ttl-expired");

    // A released record with no receipt time has no canonical legacy relay
    // birth. It fails closed as invalid clock metadata, rather than being
    // conflated with a valid record that reached its exact expiry boundary,
    // and likewise never leaves a broadcast reservation behind.
    const CTransactionRef missing_time = make_wallet_tx(
        /*seed=*/203, /*shadow_proof=*/true, /*received_time=*/0);
    const auto [missing_time_accepted, missing_time_error] =
        submit_without_peer_relay(missing_time);
    BOOST_CHECK(!missing_time_accepted);
    BOOST_CHECK_EQUAL(missing_time_error,
                      "shadow-proof-relay-clock-metadata-invalid");

    // The short relay lifetime is specific to QQSPROOF carriers. An ordinary
    // wallet transaction older than that lifetime still reaches normal node
    // policy and cannot receive the proof-expiry result from this guard.
    const CTransactionRef old_ordinary = make_wallet_tx(
        /*seed=*/204, /*shadow_proof=*/false,
        now - SHADOW_POW_CLAIM_MEMPOOL_TTL_SECONDS - 1);
    const auto old_ordinary_result =
        submit_without_peer_relay(old_ordinary);
    BOOST_CHECK_NE(old_ordinary_result.second,
                   "shadow-proof-relay-ttl-expired");
}

BOOST_FIXTURE_TEST_CASE(shadow_pow_claim_branch_quarantine_resets_after_reorg, TestChain100Setup)
{
    ShadowScheduleScope schedule_scope;
    const int initial_height = WITH_LOCK(
        ::cs_main,
        return Assert(m_node.chainman)->ActiveChain().Height());
    const int original_whitelist_height = SHADOW_WHITELIST_HEIGHT;
    const int original_reward_start_height = SHADOW_REWARD_START_HEIGHT;
    const int original_gold_rush_blocks = SHADOW_GOLD_RUSH_BLOCKS;
    const auto enable_gold_rush_classification = [&] {
        SetShadowTestSchedule(
            /*whitelist_height=*/initial_height,
            /*reward_start_height=*/initial_height + 1,
            /*gold_rush_blocks=*/32);
    };
    const auto restore_production_schedule = [&] {
        SetShadowTestSchedule(
            original_whitelist_height,
            original_reward_start_height,
            original_gold_rush_blocks);
    };

    CKey wallet_key;
    wallet_key.MakeNewKey(/*fCompressed=*/true);
    const CScript wallet_script =
        GetScriptForRawPubKey(wallet_key.GetPubKey());
    const CMutableTransaction funding = TestSimpleSpend(
        *m_coinbase_txns[0], /*index=*/0, coinbaseKey, wallet_script);
    CreateAndProcessBlock(
        {funding}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));

    std::shared_ptr<CWallet> wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return Assert(m_node.chainman)->ActiveChain()),
        wallet_key);
    wallet->SetBroadcastTransactions(/*broadcast=*/false);
    SyncWithValidationInterfaceQueue();

    auto sync_wallet_tip = [&] {
        LOCK2(::cs_main, wallet->cs_wallet);
        const CBlockIndex* tip =
            Assert(m_node.chainman)->ActiveChain().Tip();
        BOOST_REQUIRE(tip);
        wallet->SetLastBlockProcessed(tip->nHeight, tip->GetBlockHash());
    };

    const CBlock first_observation_block = CreateAndProcessBlock(
        {}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    SyncWithValidationInterfaceQueue();
    sync_wallet_tip();
    const int first_observation_height = WITH_LOCK(
        ::cs_main,
        return Assert(m_node.chainman)->ActiveChain().Height());
    const uint256 first_observation_tip =
        first_observation_block.GetHash();

    // A canonical QQP2 carrier with zero nonce is invalid work on this pinned
    // tip but can become valid on a descendant because QQP2 has no origin
    // binding. Recovery deliberately supports that one disclosed retryable
    // state, so wallet repair must establish and reorg-reset its stale clock.
    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0});
    proof.insert(proof.end(), 8, 0);
    proof.push_back(static_cast<unsigned char>(wallet_script.size() & 0xff));
    proof.push_back(
        static_cast<unsigned char>((wallet_script.size() >> 8) & 0xff));
    proof.insert(proof.end(), wallet_script.begin(), wallet_script.end());
    const CScript quantum_payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x51)});
    proof.push_back(static_cast<unsigned char>(quantum_payout.size() & 0xff));
    proof.push_back(
        static_cast<unsigned char>((quantum_payout.size() >> 8) & 0xff));
    proof.insert(proof.end(), quantum_payout.begin(), quantum_payout.end());
    const CTransactionRef funding_ref = MakeTransactionRef(funding);
    CMutableTransaction claim;
    claim.vin.emplace_back(COutPoint{funding_ref->GetHash(), 0});
    claim.vout.emplace_back(
        funding.vout[0].nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    const CTransactionRef claim_ref = MakeTransactionRef(std::move(claim));
    BOOST_REQUIRE(TransactionHasShadowProof(*claim_ref));
    BOOST_REQUIRE(wallet->AddToWallet(
        claim_ref, TxStateInactive{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
            wtx.mapValue[SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY] =
                ToString(first_observation_height + 1);
            wtx.mapValue[SHADOW_POW_CLAIM_CREATED_TIP_KEY] =
                first_observation_tip.GetHex();
            return true;
        }));

    // Change the schedule only around the side-effect-free claim
    // classification. Blocks themselves must be built under the fixture's
    // production schedule because this synthetic chain has no retroactive
    // shadow-state history for an activation at height 101.
    enable_gold_rush_classification();
    wallet->RepairStaleShadowTransactions(/*force=*/true);
    restore_production_schedule();
    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& stored =
            wallet->mapWallet.at(claim_ref->GetHash());
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(first_observation_height));
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY),
            first_observation_tip.GetHex());
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY),
            ToString(first_observation_height));
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY),
            first_observation_tip.GetHex());
    }

    // The branch-relative pair is durable across a wallet reload.
    CWallet reloaded(
        m_node.chain.get(), "", DuplicateMockDatabase(wallet->GetDatabase()));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(reloaded.cs_wallet);
        const CWalletTx& stored =
            reloaded.mapWallet.at(claim_ref->GetHash());
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY),
            ToString(first_observation_height));
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY),
            first_observation_tip.GetHex());
    }

    // A descendant tip must mature, rather than overwrite, the observation.
    CreateAndProcessBlock(
        {}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    SyncWithValidationInterfaceQueue();
    sync_wallet_tip();
    enable_gold_rush_classification();
    wallet->RepairStaleShadowTransactions(/*force=*/true);
    restore_production_schedule();
    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& stored =
            wallet->mapWallet.at(claim_ref->GetHash());
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY),
            ToString(first_observation_height));
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY),
            first_observation_tip.GetHex());
    }

    // Real disconnect notifications request maintenance, but cannot run its
    // proof classification inline. Start only after the replacement tip and
    // test classification schedule are ready.
    WalletClaimMaintenance maintenance;
    maintenance.Register(wallet);
    auto notifications = m_node.chain->handleNotifications(wallet);
    CBlockIndex* first_observation_index = WITH_LOCK(
        ::cs_main,
        return Assert(m_node.chainman)->m_blockman.LookupBlockIndex(
            first_observation_tip));
    BOOST_REQUIRE(first_observation_index);
    BlockValidationState state;
    BOOST_REQUIRE(Assert(m_node.chainman)->ActiveChainstate().InvalidateBlock(
        state, first_observation_index));
    SyncWithValidationInterfaceQueue();
    sync_wallet_tip();

    // Replace the invalidated observation block with a byte-distinct block.
    const CBlock replacement_block = CreateAndProcessBlock(
        {}, CScript{} << OP_TRUE);
    BOOST_REQUIRE(replacement_block.GetHash() != first_observation_tip);
    SyncWithValidationInterfaceQueue();
    sync_wallet_tip();
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK(wallet->IsSpent(COutPoint{funding_ref->GetHash(), 0}));
        BOOST_CHECK_EQUAL(wallet->mapWallet.at(claim_ref->GetHash()).mapValue.at(
            SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY), first_observation_tip.GetHex());
    }
    enable_gold_rush_classification();
    maintenance.Start();
    maintenance.Sync();
    notifications.reset();
    maintenance.Unregister(*wallet);
    maintenance.Stop();
    restore_production_schedule();

    const int replacement_height = WITH_LOCK(
        ::cs_main,
        return Assert(m_node.chainman)->ActiveChain().Height());
    const uint256 replacement_tip = replacement_block.GetHash();
    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& stored =
            wallet->mapWallet.at(claim_ref->GetHash());
        // Immutable audit provenance remains the original observation.
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(first_observation_height));
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY),
            first_observation_tip.GetHex());
        // Stale-depth provenance restarts on the current branch.
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY),
            ToString(replacement_height));
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY),
            replacement_tip.GetHex());
    }

    // If a quarantined claim becomes live again, any later failure must start
    // a fresh continuous-terminal-age interval. Keep immutable provenance,
    // but clear the current-branch age before automatic recovery can act.
    BOOST_REQUIRE(!m_node.chain->isInMempool(claim_ref->GetHash()));
    {
        LOCK2(::cs_main, m_node.mempool->cs);
        LockPoints lock_points;
        m_node.mempool->addUnchecked(CTxMemPoolEntry(
            claim_ref, /*fee=*/DEFAULT_TRANSACTION_MAXFEE,
            /*time=*/0, /*entry_height=*/replacement_height,
            /*entry_sequence=*/0, /*spends_coinbase=*/false,
            /*sigops_cost=*/4, lock_points));
    }
    auto remove_live_claim = interfaces::MakeCleanupHandler(
        [this, claim_ref] {
            WITH_LOCK(
                m_node.mempool->cs,
                m_node.mempool->removeRecursive(
                    *claim_ref, MemPoolRemovalReason::EXPIRY));
        });
    BOOST_REQUIRE(m_node.chain->isInMempool(claim_ref->GetHash()));
    wallet->transactionAddedToMempool(claim_ref);
    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& stored =
            wallet->mapWallet.at(claim_ref->GetHash());
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_QUARANTINE_MARKER_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY) == 0);
        BOOST_CHECK(stored.mapValue.count(
            SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY) == 0);
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY),
            ToString(first_observation_height));
        BOOST_CHECK_EQUAL(
            stored.mapValue.at(
                SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY),
            first_observation_tip.GetHex());
    }
    remove_live_claim->disconnect();
    BOOST_CHECK(!m_node.chain->isInMempool(claim_ref->GetHash()));
}

BOOST_AUTO_TEST_CASE(shadow_solve_index_is_bounded_ordered_and_disconnect_safe)
{
    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    {
        LOCK(wallet.cs_wallet);
        wallet.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
        wallet.SetupDescriptorScriptPubKeyMans();
    }

    CKey key_a;
    CKey key_b;
    CKey key_c;
    key_a.MakeNewKey(true);
    key_b.MakeNewKey(true);
    key_c.MakeNewKey(true);
    AddKey(wallet, key_a);
    AddKey(wallet, key_b);
    AddKey(wallet, key_c);

    const CScript target_a = GetScriptForDestination(PKHash(key_a.GetPubKey()));
    const CScript target_b = GetScriptForDestination(PKHash(key_b.GetPubKey()));
    const CScript target_c = GetScriptForDestination(PKHash(key_c.GetPubKey()));

    auto add_funding = [&](const CScript& target, int height, uint64_t block_tag) {
        CMutableTransaction tx;
        tx.vin.resize(1);
        tx.vin[0].prevout.SetNull();
        tx.vout.emplace_back(10 * COIN, target);
        CTransactionRef ref = MakeTransactionRef(std::move(tx));
        BOOST_REQUIRE(wallet.AddToWallet(ref, TxStateConfirmed{uint256{static_cast<uint8_t>(block_tag)}, height, 0}));
        return ref;
    };
    auto add_solve = [&](const CTransactionRef& previous, uint32_t output_index, const CScript& target,
                         int height, uint64_t block_tag) {
        CMutableTransaction tx;
        tx.vin.emplace_back(COutPoint{previous->GetHash(), output_index});
        tx.vout.emplace_back(0, CScript{});
        tx.vout.emplace_back(10 * COIN, target);
        CTransactionRef ref = MakeTransactionRef(std::move(tx));
        BOOST_REQUIRE(wallet.AddToWallet(ref, TxStateConfirmed{uint256{static_cast<uint8_t>(block_tag)}, height, 1}));
        return ref;
    };

    const CTransactionRef funding_a = add_funding(target_a, 1, 1);
    const CTransactionRef funding_b = add_funding(target_b, 1, 2);
    const CTransactionRef funding_c = add_funding(target_c, 1, 3);
    const CTransactionRef solve_a_old = add_solve(funding_a, 0, target_a, 100, 100);
    const CTransactionRef solve_b = add_solve(funding_b, 0, target_b, 101, 101);
    const CTransactionRef solve_c = add_solve(funding_c, 0, target_c, 101, 102);
    const CTransactionRef solve_a_new = add_solve(solve_a_old, 1, target_a, 102, 103);

    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(wallet.GetOwnedLegacyShadowScripts(0).empty());
        BOOST_CHECK(wallet.GetRecentShadowSolveReferences(102, 0).empty());

        const auto newest = wallet.GetRecentShadowSolveReferences(102, 2);
        BOOST_REQUIRE_EQUAL(newest.size(), 2U);
        BOOST_CHECK_EQUAL(newest[0].solve_txid, solve_a_new->GetHash());
        BOOST_CHECK_EQUAL(newest[0].solve_height, 102U);
        BOOST_CHECK_EQUAL(newest[1].solve_height, 101U);

        const auto capped = wallet.GetRecentShadowSolveReferences(102, 1);
        BOOST_REQUIRE_EQUAL(capped.size(), 1U);
        BOOST_CHECK_EQUAL(capped[0].solve_txid, solve_a_new->GetHash());

        const auto at_101 = wallet.GetRecentShadowSolveReferences(101, 3);
        BOOST_REQUIRE_EQUAL(at_101.size(), 2U);
        BOOST_CHECK_EQUAL(at_101[0].solve_height, 101U);
        BOOST_CHECK_EQUAL(at_101[1].solve_height, 101U);
        BOOST_CHECK(at_101[1].target < at_101[0].target);
    }

    BOOST_REQUIRE(wallet.AddToWallet(solve_a_new, TxStateInactive{}));
    {
        LOCK(wallet.cs_wallet);
        const auto after_disconnect = wallet.GetRecentShadowSolveReferences(102, 3);
        BOOST_REQUIRE_EQUAL(after_disconnect.size(), 3U);
        BOOST_CHECK_EQUAL(after_disconnect[0].solve_height, 101U);
        BOOST_CHECK_EQUAL(after_disconnect[1].solve_height, 101U);
        BOOST_CHECK_EQUAL(after_disconnect[2].solve_txid, solve_a_old->GetHash());
    }

    BOOST_REQUIRE(wallet.AddToWallet(solve_a_new, TxStateConfirmed{uint256{103}, 102, 1}));
    {
        LOCK(wallet.cs_wallet);
        const auto after_reconnect = wallet.GetRecentShadowSolveReferences(102, 1);
        BOOST_REQUIRE_EQUAL(after_reconnect.size(), 1U);
        BOOST_CHECK_EQUAL(after_reconnect[0].solve_txid, solve_a_new->GetHash());
    }
}

BOOST_AUTO_TEST_CASE(goldrush_pow_miner_lifecycle_creates_quantum_payout)
{
    ScopedArgsSettings args_guard;
    args_guard.Force("-qqallowautokeycreation", "0");
    auto worker_failure_reset = interfaces::MakeCleanupHandler([] {
        SetPowMinerWorkerCreationFailureAfterForTesting(-1);
    });
    bilingual_str error;
    BOOST_CHECK(!m_wallet.SetPowMining(/*enabled=*/true, /*threads=*/1,
                                      /*cpu_percent=*/10, error));
    BOOST_CHECK(error.original.find("allow_new_payout_key=true") != std::string::npos);
    BOOST_CHECK(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.m_pow_payout_quantum.empty()));

    error.clear();
    bool created_payout_key{false};
    SetPowMinerWorkerCreationFailureAfterForTesting(0);
    BOOST_CHECK(!m_wallet.SetPowMining(
        /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/10, error,
        &created_payout_key, /*allow_new_payout_key=*/true));
    // Payout persistence precedes thread construction. A failed launch must
    // therefore report the durable key and backup requirement truthfully,
    // while leaving the miner disabled because no previous group existed.
    BOOST_CHECK(created_payout_key);
    BOOST_CHECK(!m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK(error.original.find("could not create its worker threads") !=
                std::string::npos);
    BOOST_CHECK(error.original.find("already created and remains") !=
                std::string::npos);
    BOOST_CHECK(error.original.find("Back up the wallet now") !=
                std::string::npos);
    BOOST_CHECK(error.original.find("existing Gold Rush PoW miner") ==
                std::string::npos);
    SetPowMinerWorkerCreationFailureAfterForTesting(-1);

    std::string original_payout;
    {
        LOCK(m_wallet.cs_wallet);
        BOOST_CHECK(!m_wallet.m_pow_payout_quantum.empty());
        original_payout = m_wallet.m_pow_payout_quantum;
        const CTxDestination payout = DecodeDestination(m_wallet.m_pow_payout_quantum);
        BOOST_CHECK(IsValidDestination(payout));
        BOOST_CHECK(IsQuantumMigrationDestination(payout));
    }

    error.clear();
    created_payout_key = true;
    BOOST_REQUIRE(m_wallet.SetPowMining(
        /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/10, error,
        &created_payout_key, /*allow_new_payout_key=*/true));
    BOOST_CHECK(!created_payout_key);
    BOOST_CHECK(m_wallet.m_pow_mining_enabled.load());

    // A partial replacement-group construction failure has the strong
    // guarantee: its dormant replacement is cancelled, and the exact old
    // worker-group object plus thread/CPU configuration remain live.
    auto* const original_group = WITH_LOCK(
        m_wallet.m_pow_miner_mutex,
        return m_wallet.threadPowMinerGroup.get());
    BOOST_REQUIRE(original_group);
    SetPowMinerWorkerCreationFailureAfterForTesting(1);
    error.clear();
    bool reconfigure_created_payout{true};
    BOOST_CHECK(!m_wallet.SetPowMining(
        /*enabled=*/true, /*threads=*/2, /*cpu_percent=*/50, error,
        &reconfigure_created_payout));
    BOOST_CHECK(!reconfigure_created_payout);
    BOOST_CHECK(error.original.find("existing Gold Rush PoW miner remains enabled") !=
                std::string::npos);
    BOOST_CHECK(m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(m_wallet.m_pow_threads.load(), 1);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_cpu_percent.load(), 10);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup.get()),
        original_group);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup->size()),
        1U);
    SetPowMinerWorkerCreationFailureAfterForTesting(-1);
    m_wallet.StopPowMining();
    BOOST_CHECK(!m_wallet.m_pow_mining_enabled.load());

    {
        LOCK(m_wallet.cs_wallet);
        m_wallet.m_pow_payout_quantum.clear();
    }
    BOOST_REQUIRE(m_wallet.EnsurePowPayoutAddress(error));
    {
        LOCK(m_wallet.cs_wallet);
        BOOST_CHECK_EQUAL(m_wallet.m_pow_payout_quantum, original_payout);
    }

    // Concurrent lifecycle requests must serialize the complete
    // stop/validate/start transition. In particular, a second start must not
    // destroy a vector that still owns joinable threads from the first.
    std::array<bool, 2> concurrent_start_results{false, false};
    std::array<bilingual_str, 2> concurrent_start_errors;
    std::promise<void> release_starts;
    const std::shared_future<void> starts_ready =
        release_starts.get_future().share();
    std::thread start_a([&] {
        starts_ready.wait();
        concurrent_start_results[0] = m_wallet.SetPowMining(
            /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/1,
            concurrent_start_errors[0]);
    });
    std::thread start_b([&] {
        starts_ready.wait();
        concurrent_start_results[1] = m_wallet.SetPowMining(
            /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/1,
            concurrent_start_errors[1]);
    });
    release_starts.set_value();
    start_a.join();
    start_b.join();
    BOOST_CHECK(concurrent_start_results[0]);
    BOOST_CHECK(concurrent_start_results[1]);
    BOOST_CHECK(m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup
                             ? m_wallet.threadPowMinerGroup->size()
                             : 0U),
        1U);

    // A racing stop and restart may linearize in either order, but the public
    // enabled flag and owned worker group must describe the same final state.
    bool restart_result{false};
    bilingual_str restart_error;
    std::promise<void> release_race;
    const std::shared_future<void> race_ready =
        release_race.get_future().share();
    std::thread stopper([&] {
        race_ready.wait();
        m_wallet.StopPowMining();
    });
    std::thread starter([&] {
        race_ready.wait();
        restart_result = m_wallet.SetPowMining(
            /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/1,
            restart_error);
    });
    release_race.set_value();
    stopper.join();
    starter.join();
    BOOST_CHECK(restart_result);
    const bool final_enabled = m_wallet.m_pow_mining_enabled.load();
    const size_t final_workers = WITH_LOCK(
        m_wallet.m_pow_miner_mutex,
        return m_wallet.threadPowMinerGroup
                   ? m_wallet.threadPowMinerGroup->size()
                   : 0U);
    BOOST_CHECK_EQUAL(final_workers, final_enabled ? 1U : 0U);
    m_wallet.StopPowMining();
}

BOOST_AUTO_TEST_CASE(goldrush_pow_payout_creation_is_singleflight)
{
    ScopedArgsSettings args_guard;
    args_guard.Force("-qqallowautokeycreation", "0");

    const size_t keys_before = WITH_LOCK(
        m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size());
    std::array<bool, 2> results{false, false};
    std::array<bool, 2> created{false, false};
    std::array<bilingual_str, 2> errors;
    std::array<std::string, 2> payouts;
    std::promise<void> release;
    const std::shared_future<void> ready = release.get_future().share();
    std::array<std::thread, 2> callers{
        std::thread{[&] {
            ready.wait();
            results[0] = m_wallet.EnsurePowPayoutAddress(
                errors[0], &created[0], /*allow_new_key=*/true);
            payouts[0] = WITH_LOCK(
                m_wallet.cs_wallet, return m_wallet.m_pow_payout_quantum);
        }},
        std::thread{[&] {
            ready.wait();
            results[1] = m_wallet.EnsurePowPayoutAddress(
                errors[1], &created[1], /*allow_new_key=*/true);
            payouts[1] = WITH_LOCK(
                m_wallet.cs_wallet, return m_wallet.m_pow_payout_quantum);
        }},
    };
    release.set_value();
    for (std::thread& caller : callers) caller.join();

    BOOST_REQUIRE(results[0]);
    BOOST_REQUIRE(results[1]);
    BOOST_CHECK_NE(created[0], created[1]);
    BOOST_REQUIRE(!payouts[0].empty());
    BOOST_CHECK_EQUAL(payouts[0], payouts[1]);

    const CTxDestination payout = DecodeDestination(payouts[0]);
    BOOST_REQUIRE(IsValidDestination(payout));
    BOOST_REQUIRE(IsQuantumMigrationDestination(payout));
    {
        LOCK(m_wallet.cs_wallet);
        BOOST_REQUIRE_EQUAL(m_wallet.ListQuantumKeyInfos().size(), keys_before + 1);
        const auto key_info = m_wallet.GetQuantumKeyInfo(payout);
        BOOST_REQUIRE(key_info.has_value());
        BOOST_CHECK(key_info->durably_stored);
        const CAddressBookData* entry = m_wallet.FindAddressBookEntry(payout);
        BOOST_REQUIRE(entry);
        BOOST_CHECK_EQUAL(entry->GetLabel(), "PoW - Quantum Claim Address");
        BOOST_CHECK_EQUAL(
            std::count_if(
                m_wallet.m_address_book.begin(), m_wallet.m_address_book.end(),
                [](const auto& item) {
                    return item.second.GetLabel() ==
                           "PoW - Quantum Claim Address";
                }),
            1);
    }

    // Reopen the exact database and resolve the binding again. The one key and
    // one label must be sufficient to reconstruct the same payout without a
    // second creation or an ambiguous wallet-database outcome.
    CWallet reloaded(
        m_node.chain.get(), "pow-payout-singleflight",
        DuplicateMockDatabase(m_wallet.GetDatabase()));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    bilingual_str reload_error;
    bool reload_created{true};
    BOOST_REQUIRE_MESSAGE(
        reloaded.EnsurePowPayoutAddress(reload_error, &reload_created),
        reload_error.original);
    BOOST_CHECK(!reload_created);
    {
        LOCK(reloaded.cs_wallet);
        BOOST_CHECK_EQUAL(reloaded.m_pow_payout_quantum, payouts[0]);
        BOOST_CHECK_EQUAL(reloaded.ListQuantumKeyInfos().size(), keys_before + 1);
        BOOST_REQUIRE(reloaded.FindAddressBookEntry(payout));
        BOOST_CHECK_EQUAL(
            reloaded.FindAddressBookEntry(payout)->GetLabel(),
            "PoW - Quantum Claim Address");
    }
}

BOOST_AUTO_TEST_CASE(goldrush_pow_autostart_waits_for_normal_unlock)
{
    ScopedArgsSettings args_guard;
    args_guard.Force("-qqallowautokeycreation", "0");

    bilingual_str error;
    bool created_payout_key{false};
    BOOST_REQUIRE(m_wallet.EnsurePowPayoutAddress(
        error, &created_payout_key, /*allow_new_key=*/true));
    BOOST_REQUIRE(created_payout_key);
    const std::string payout = WITH_LOCK(
        m_wallet.cs_wallet, return m_wallet.m_pow_payout_quantum);

    const SecureString passphrase{"pow-autostart-test"};
    BOOST_REQUIRE(m_wallet.EncryptWallet(passphrase));
    BOOST_REQUIRE(m_wallet.IsLocked());

    // Interactive RPC/GUI starts remain strict while the wallet is locked.
    error.clear();
    BOOST_CHECK(!m_wallet.SetPowMining(
        /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/1, error));
    BOOST_CHECK(!m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK(error.original.find("requires an unlocked wallet") !=
                std::string::npos);

    // Only explicit startup consent may create a waiting worker. Exercise the
    // real post-init route so this covers the encrypted clean-install order,
    // not merely the internal SetPowMining mode.
    args_guard.Force("-powmining", "1");
    args_guard.Force("-powminingthreads", "2");
    args_guard.Force("-powminingcpu", "1");
    args_guard.Force("-autostartstaking", "0");
    m_wallet.postInitProcess();
    BOOST_CHECK(m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(m_wallet.m_pow_threads.load(), 2);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_cpu_percent.load(), 1);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup
                             ? m_wallet.threadPowMinerGroup->size()
                             : 0U),
        2U);
    auto* const startup_worker_group = WITH_LOCK(
        m_wallet.m_pow_miner_mutex,
        return m_wallet.threadPowMinerGroup.get());
    BOOST_REQUIRE(startup_worker_group);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_hashrate.load(), 0.0);
    BOOST_CHECK(m_wallet.m_pow_state.load() ==
                interfaces::WalletPowMiningState::WALLET_LOCKED_OR_STAKING_ONLY);

    const size_t startup_key_count = WITH_LOCK(
        m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size());
    const uint64_t startup_claims = m_wallet.m_pow_claims_submitted.load();
    const uint64_t startup_tries = m_wallet.m_pow_total_tries.load();
    bool rejected_created_payout{true};
    error.clear();
    BOOST_CHECK(!m_wallet.SetPowMining(
        /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/50, error,
        &rejected_created_payout));
    BOOST_CHECK(!rejected_created_payout);
    BOOST_CHECK(error.original.find("requires an unlocked wallet") !=
                std::string::npos);
    BOOST_CHECK(m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(m_wallet.m_pow_threads.load(), 2);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_cpu_percent.load(), 1);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup.get()),
        startup_worker_group);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup->size()),
        2U);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_claims_submitted.load(), startup_claims);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_total_tries.load(), startup_tries);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.cs_wallet,
                  return m_wallet.ListQuantumKeyInfos().size()),
        startup_key_count);
    BOOST_CHECK_EQUAL(WITH_LOCK(
                          m_wallet.cs_wallet,
                          return m_wallet.m_pow_payout_quantum),
                      payout);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_hashrate.load(), 0.0);
    BOOST_CHECK(m_wallet.m_pow_state.load() ==
                interfaces::WalletPowMiningState::WALLET_LOCKED_OR_STAKING_ONLY);

    BOOST_REQUIRE(m_wallet.Unlock(passphrase, /*accept_no_keys=*/false,
                                  /*staking_only=*/true));
    BOOST_CHECK(m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(m_wallet.m_pow_hashrate.load(), 0.0);
    BOOST_CHECK(m_wallet.m_pow_state.load() ==
                interfaces::WalletPowMiningState::WALLET_LOCKED_OR_STAKING_ONLY);
    std::this_thread::sleep_for(std::chrono::milliseconds{250});
    BOOST_CHECK_EQUAL(m_wallet.m_pow_hashrate.load(), 0.0);
    BOOST_CHECK(m_wallet.m_pow_state.load() ==
                interfaces::WalletPowMiningState::WALLET_LOCKED_OR_STAKING_ONLY);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup.get()),
        startup_worker_group);
    BOOST_CHECK_EQUAL(WITH_LOCK(
                          m_wallet.cs_wallet,
                          return m_wallet.m_pow_payout_quantum),
                      payout);

    rejected_created_payout = true;
    error.clear();
    BOOST_CHECK(!m_wallet.SetPowMining(
        /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/50, error,
        &rejected_created_payout));
    BOOST_CHECK(!rejected_created_payout);
    BOOST_CHECK(error.original.find("normal wallet unlock") !=
                std::string::npos);
    BOOST_CHECK(m_wallet.m_wallet_unlock_staking_only.load());
    BOOST_CHECK(m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(m_wallet.m_pow_threads.load(), 2);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_cpu_percent.load(), 1);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup.get()),
        startup_worker_group);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_claims_submitted.load(), startup_claims);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_total_tries.load(), startup_tries);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.cs_wallet,
                  return m_wallet.ListQuantumKeyInfos().size()),
        startup_key_count);
    BOOST_CHECK_EQUAL(WITH_LOCK(
                          m_wallet.cs_wallet,
                          return m_wallet.m_pow_payout_quantum),
                      payout);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_hashrate.load(), 0.0);
    BOOST_CHECK(m_wallet.m_pow_state.load() ==
                interfaces::WalletPowMiningState::WALLET_LOCKED_OR_STAKING_ONLY);

    // A marker-only GUI transition may narrow an installed key, but it cannot
    // expand staking-only authority. Normal signing authority must come from a
    // successful credential-verified Unlock(..., false), which also closes a
    // concurrent walletpassphrase race against GUI lock-then-stage paths.
    m_wallet.SetWalletUnlockStakingOnly(false);
    BOOST_CHECK(m_wallet.m_wallet_unlock_staking_only.load());
    BOOST_CHECK_EQUAL(m_wallet.m_pow_hashrate.load(), 0.0);
    BOOST_CHECK(m_wallet.m_pow_state.load() ==
                interfaces::WalletPowMiningState::WALLET_LOCKED_OR_STAKING_ONLY);

    // A failed request to expand staking-only authority is atomic: it cannot
    // wake either worker or change the retained unlock scope.
    const SecureString wrong_passphrase{"pow-autostart-wrong"};
    BOOST_CHECK(!m_wallet.Unlock(wrong_passphrase,
                                 /*accept_no_keys=*/false,
                                 /*staking_only=*/false));
    BOOST_CHECK(m_wallet.m_wallet_unlock_staking_only.load());
    BOOST_CHECK_EQUAL(m_wallet.m_pow_hashrate.load(), 0.0);
    BOOST_CHECK(m_wallet.m_pow_state.load() ==
                interfaces::WalletPowMiningState::WALLET_LOCKED_OR_STAKING_ONLY);

    // The same worker remains alive when the operator expands the unlock to
    // normal signing authority; it can resume without another start command.
    BOOST_REQUIRE(m_wallet.Unlock(passphrase, /*accept_no_keys=*/false,
                                  /*staking_only=*/false));
    BOOST_CHECK(m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup.get()),
        startup_worker_group);

    m_wallet.m_pow_hashrate.store(42.0);
    BOOST_REQUIRE(m_wallet.Lock());
    BOOST_CHECK(m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(m_wallet.m_pow_hashrate.load(), 0.0);
    BOOST_CHECK(m_wallet.m_pow_state.load() ==
                interfaces::WalletPowMiningState::WALLET_LOCKED_OR_STAKING_ONLY);
    std::this_thread::sleep_for(std::chrono::milliseconds{250});
    BOOST_CHECK_EQUAL(m_wallet.m_pow_hashrate.load(), 0.0);
    BOOST_CHECK(m_wallet.m_pow_state.load() ==
                interfaces::WalletPowMiningState::WALLET_LOCKED_OR_STAKING_ONLY);
    BOOST_REQUIRE(m_wallet.Unlock(passphrase, /*accept_no_keys=*/false,
                                  /*staking_only=*/false));
    BOOST_CHECK(m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup.get()),
        startup_worker_group);

    // A terminal failure from either worker is authoritative. Late state or
    // hashrate publication from the other configured worker cannot overwrite
    // enabled=false/error before the lifecycle owner joins the group.
    m_wallet.m_pow_hashrate.store(42.0);
    m_wallet.m_pow_mining_enabled.store(false);
    BOOST_REQUIRE(m_wallet.PublishPowMiningWorkerState(
        interfaces::WalletPowMiningState::RUNTIME_ERROR));
    bool late_state_rejected{false};
    bool late_hash_rejected{false};
    std::thread late_state([&] {
        late_state_rejected = !m_wallet.PublishPowMiningWorkerState(
            interfaces::WalletPowMiningState::READY);
    });
    std::thread late_hash([&] {
        late_hash_rejected = !m_wallet.PublishPowMiningHashrate(42.0);
    });
    late_state.join();
    late_hash.join();
    BOOST_CHECK(late_state_rejected);
    BOOST_CHECK(late_hash_rejected);
    std::this_thread::sleep_for(std::chrono::milliseconds{250});
    BOOST_CHECK(!m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(m_wallet.m_pow_hashrate.load(), 0.0);
    BOOST_CHECK(m_wallet.m_pow_state.load() ==
                interfaces::WalletPowMiningState::RUNTIME_ERROR);

    m_wallet.StopPowMining();
    BOOST_CHECK(!m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup
                             ? m_wallet.threadPowMinerGroup->size()
                             : 0U),
        0U);

    // An explicit runtime stop is authoritative. A later lock/unlock cycle
    // cannot recreate the startup worker group in this process.
    BOOST_REQUIRE(m_wallet.Lock());
    BOOST_REQUIRE(m_wallet.Unlock(passphrase, /*accept_no_keys=*/false,
                                  /*staking_only=*/false));
    BOOST_CHECK(!m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.m_pow_miner_mutex,
                  return m_wallet.threadPowMinerGroup
                             ? m_wallet.threadPowMinerGroup->size()
                             : 0U),
        0U);
}

BOOST_FIXTURE_TEST_CASE(pow_mining_reserve_cache_and_controls_are_nonblocking,
                        WalletShadowPowQQP2TestingSetup)
{
    std::shared_ptr<CWallet> wallet{CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey).release()};
    WalletContext wallet_context;
    wallet_context.chain = m_node.chain.get();
    auto wallet_interface = interfaces::MakeWallet(wallet_context, wallet);

    BOOST_CHECK(!wallet_interface->getPowMiningInfo().stake_reserve_available);
    wallet_interface->refreshPowMiningStakeReserve();
    BOOST_REQUIRE(wallet_interface->getPowMiningInfo().stake_reserve_available);
    wallet->SetStakingEnabled(true);
    BOOST_CHECK(!wallet_interface->getPowMiningInfo().stake_reserve_available);
    wallet_interface->refreshPowMiningStakeReserve();
    BOOST_REQUIRE(wallet_interface->getPowMiningInfo().stake_reserve_available);
    const COutPoint coin{m_coinbase_txns.front()->GetHash(), 0};
    BOOST_REQUIRE(WITH_LOCK(wallet->cs_wallet, return wallet->LockCoin(coin)));
    BOOST_CHECK(!wallet_interface->getPowMiningInfo().stake_reserve_available);
    BOOST_REQUIRE(WITH_LOCK(wallet->cs_wallet, return wallet->UnlockCoin(coin)));
    wallet_interface->refreshPowMiningStakeReserve();
    BOOST_REQUIRE(wallet_interface->getPowMiningInfo().stake_reserve_available);

    const auto check_contended_getter = [&](RecursiveMutex& mutex) {
        std::promise<void> held;
        std::promise<void> release;
        auto released = release.get_future();
        std::thread holder([&] {
            LOCK(mutex);
            held.set_value();
            released.wait();
        });
        held.get_future().wait();
        auto read = std::async(std::launch::async, [&] {
            return wallet_interface->getPowMiningInfo();
        });
        const bool returned_without_lock =
            read.wait_for(std::chrono::seconds{1}) == std::future_status::ready;
        release.set_value();
        holder.join();
        const auto info = read.get();
        BOOST_CHECK(returned_without_lock);
        BOOST_CHECK(!info.payout_address_available);
        BOOST_CHECK(!info.wallet_goldrush_status_available);
        BOOST_CHECK(!info.stake_reserve_available);
    };
    check_contended_getter(::cs_main);
    check_contended_getter(wallet->cs_wallet);

    // Disable only relaxes reserve policy; it must remain immediate even
    // while another thread holds the wallet lock. Later enable is serialized.
    std::promise<void> held;
    std::promise<void> release;
    auto released = release.get_future();
    std::thread holder([&] {
        LOCK(wallet->cs_wallet);
        held.set_value();
        released.wait();
    });
    held.get_future().wait();
    auto disable = std::async(std::launch::async, [&] {
        wallet_interface->setEnabledStaking(false);
    });
    const bool disabled_without_lock =
        disable.wait_for(std::chrono::seconds{1}) == std::future_status::ready;
    const bool enabled_before_release = wallet->m_enabled_staking.load();
    release.set_value();
    holder.join();
    disable.get();
    BOOST_CHECK(disabled_without_lock);
    BOOST_CHECK(!enabled_before_release);
    BOOST_CHECK(!wallet_interface->getPowMiningInfo().stake_reserve_available);
}

BOOST_FIXTURE_TEST_CASE(lifecycle_balance_requires_matching_wallet_and_chain_tips, TestChain100Setup)
{
    std::shared_ptr<CWallet> wallet{CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey).release()};
    WalletContext wallet_context;
    wallet_context.chain = m_node.chain.get();
    auto wallet_interface = interfaces::MakeWallet(wallet_context, wallet);

    const CBlockIndex* tip = WITH_LOCK(
        Assert(m_node.chainman)->GetMutex(),
        return m_node.chainman->ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    BOOST_REQUIRE(tip->pprev);
    {
        LOCK2(Assert(m_node.chainman)->GetMutex(), wallet->cs_wallet);
        BOOST_CHECK(WalletLifecycleViewIsSynchronized(*wallet));
        wallet->SetLastBlockProcessed(tip->pprev->nHeight, tip->pprev->GetBlockHash());
        BOOST_CHECK(!WalletLifecycleViewIsSynchronized(*wallet));
    }

    interfaces::WalletBalances gui_balance;
    uint256 gui_block_hash;
    BOOST_CHECK(!wallet_interface->tryGetBalances(gui_balance, gui_block_hash));

    Balance balance;
    WalletLifecycleSummary lifecycle;
    std::string error;
    {
        LOCK2(Assert(m_node.chainman)->GetMutex(), wallet->cs_wallet);
        BOOST_CHECK(!GetLifecycleAdjustedBalance(
            *wallet, /*min_depth=*/0, /*avoid_reuse=*/true,
            balance, lifecycle, error));
    }
    BOOST_CHECK_EQUAL(
        error,
        "Wallet lifecycle view is not synchronized with the active chain tip");

    auto blocking_balance = std::async(std::launch::async, [&] {
        return wallet_interface->getBalances();
    });
    BOOST_CHECK(blocking_balance.wait_for(50ms) == std::future_status::timeout);

    {
        LOCK2(Assert(m_node.chainman)->GetMutex(), wallet->cs_wallet);
        wallet->SetLastBlockProcessed(tip->nHeight, tip->GetBlockHash());
        BOOST_CHECK(WalletLifecycleViewIsSynchronized(*wallet));
        BOOST_CHECK(GetLifecycleAdjustedBalance(
            *wallet, /*min_depth=*/0, /*avoid_reuse=*/true,
            balance, lifecycle, error));
    }
    BOOST_REQUIRE(blocking_balance.wait_for(5s) == std::future_status::ready);
    gui_balance = blocking_balance.get();
    BOOST_CHECK_EQUAL(gui_balance.balance, balance.m_mine_trusted);
    BOOST_CHECK(wallet_interface->tryGetBalances(gui_balance, gui_block_hash));
    BOOST_CHECK_EQUAL(gui_block_hash, tip->GetBlockHash());
}

BOOST_FIXTURE_TEST_CASE(scan_for_wallet_transactions, TestChain100Setup)
{
    // Cap last block file size, and mine new block in a new block file.
    CBlockIndex* oldTip = WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain().Tip());
    WITH_LOCK(::cs_main, m_node.chainman->m_blockman.GetBlockFileInfo(oldTip->GetBlockPos().nFile)->nSize = MAX_BLOCKFILE_SIZE);
    CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    CBlockIndex* newTip = WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain().Tip());
    const CAmount block_subsidy{GetBlockSubsidy(newTip->nHeight, Params().GetConsensus(), /*fProofOfStake=*/false)};

    // Verify ScanForWalletTransactions fails to read an unknown start block.
    {
        CWallet wallet(m_node.chain.get(), "", CreateMockableWalletDatabase());
        {
            LOCK(wallet.cs_wallet);
            LOCK(Assert(m_node.chainman)->GetMutex());
            wallet.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
            wallet.SetLastBlockProcessed(m_node.chainman->ActiveChain().Height(), m_node.chainman->ActiveChain().Tip()->GetBlockHash());
        }
        AddKey(wallet, coinbaseKey);
        WalletRescanReserver reserver(wallet);
        reserver.reserve();
        CWallet::ScanResult result = wallet.ScanForWalletTransactions(/*start_block=*/{}, /*start_height=*/0, /*max_height=*/{}, reserver, /*fUpdate=*/false, /*save_progress=*/false);
        BOOST_CHECK_EQUAL(result.status, CWallet::ScanResult::FAILURE);
        BOOST_CHECK(result.last_failed_block.IsNull());
        BOOST_CHECK(result.last_scanned_block.IsNull());
        BOOST_CHECK(!result.last_scanned_height);
        BOOST_CHECK_EQUAL(GetBalance(wallet).m_mine_immature, 0);
    }

    // Verify ScanForWalletTransactions picks up transactions in both the old
    // and new block files.
    {
        CWallet wallet(m_node.chain.get(), "", CreateMockableWalletDatabase());
        {
            LOCK(wallet.cs_wallet);
            LOCK(Assert(m_node.chainman)->GetMutex());
            wallet.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
            wallet.SetLastBlockProcessed(m_node.chainman->ActiveChain().Height(), m_node.chainman->ActiveChain().Tip()->GetBlockHash());
        }
        AddKey(wallet, coinbaseKey);
        WalletRescanReserver reserver(wallet);
        std::chrono::steady_clock::time_point fake_time;
        reserver.setNow([&] { fake_time += 60s; return fake_time; });
        reserver.reserve();

        {
            CBlockLocator locator;
            BOOST_CHECK(!WalletBatch{wallet.GetDatabase()}.ReadBestBlock(locator));
            BOOST_CHECK(locator.IsNull());
        }

        CWallet::ScanResult result = wallet.ScanForWalletTransactions(/*start_block=*/oldTip->GetBlockHash(), /*start_height=*/oldTip->nHeight, /*max_height=*/{}, reserver, /*fUpdate=*/false, /*save_progress=*/true);
        BOOST_CHECK_EQUAL(result.status, CWallet::ScanResult::SUCCESS);
        BOOST_CHECK(result.last_failed_block.IsNull());
        BOOST_CHECK_EQUAL(result.last_scanned_block, newTip->GetBlockHash());
        BOOST_CHECK_EQUAL(*result.last_scanned_height, newTip->nHeight);
        BOOST_CHECK_EQUAL(GetBalance(wallet).m_mine_immature, 2 * block_subsidy);

        {
            CBlockLocator locator;
            BOOST_CHECK(WalletBatch{wallet.GetDatabase()}.ReadBestBlock(locator));
            BOOST_CHECK(!locator.IsNull());
        }
    }

    // Verify ScanForWalletTransactions succeeds without pruning and picks up
    // the coinbases in the old and new block files.
    {
        CWallet wallet(m_node.chain.get(), "", CreateMockableWalletDatabase());
        {
            LOCK(wallet.cs_wallet);
            LOCK(Assert(m_node.chainman)->GetMutex());
            wallet.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
            wallet.SetLastBlockProcessed(m_node.chainman->ActiveChain().Height(), m_node.chainman->ActiveChain().Tip()->GetBlockHash());
        }
        AddKey(wallet, coinbaseKey);
        WalletRescanReserver reserver(wallet);
        reserver.reserve();
        CWallet::ScanResult result = wallet.ScanForWalletTransactions(/*start_block=*/oldTip->GetBlockHash(), /*start_height=*/oldTip->nHeight, /*max_height=*/{}, reserver, /*fUpdate=*/false, /*save_progress=*/false);
        BOOST_CHECK_EQUAL(result.status, CWallet::ScanResult::SUCCESS);
        BOOST_CHECK(result.last_failed_block.IsNull());
        BOOST_CHECK_EQUAL(result.last_scanned_block, newTip->GetBlockHash());
        BOOST_CHECK_EQUAL(*result.last_scanned_height, newTip->nHeight);
        BOOST_CHECK_EQUAL(GetBalance(wallet).m_mine_immature, 2 * block_subsidy);
    }

    // Verify ScanForWalletTransactions can run without progress persistence.
    {
        CWallet wallet(m_node.chain.get(), "", CreateMockableWalletDatabase());
        {
            LOCK(wallet.cs_wallet);
            LOCK(Assert(m_node.chainman)->GetMutex());
            wallet.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
            wallet.SetLastBlockProcessed(m_node.chainman->ActiveChain().Height(), m_node.chainman->ActiveChain().Tip()->GetBlockHash());
        }
        AddKey(wallet, coinbaseKey);
        WalletRescanReserver reserver(wallet);
        reserver.reserve();
        CWallet::ScanResult result = wallet.ScanForWalletTransactions(/*start_block=*/oldTip->GetBlockHash(), /*start_height=*/oldTip->nHeight, /*max_height=*/{}, reserver, /*fUpdate=*/false, /*save_progress=*/false);
        BOOST_CHECK_EQUAL(result.status, CWallet::ScanResult::SUCCESS);
        BOOST_CHECK(result.last_failed_block.IsNull());
        BOOST_CHECK_EQUAL(result.last_scanned_block, newTip->GetBlockHash());
        BOOST_CHECK_EQUAL(*result.last_scanned_height, newTip->nHeight);
        BOOST_CHECK_EQUAL(GetBalance(wallet).m_mine_immature, 2 * block_subsidy);
    }
}

BOOST_FIXTURE_TEST_CASE(goldrush_shadow_payouts_sync_on_connect_disconnect_and_rescan, TestChain100Setup)
{
    ShadowScheduleScope restore_shadow_schedule;
    MockTimeScope restore_mock_time;

    const CScript block_script = GetScriptForRawPubKey(coinbaseKey.GetPubKey());
    CBlock first_real_block = CreateAndProcessBlock({}, block_script);
    CBlock reward_real_block = CreateAndProcessBlock({}, block_script);

    CBlockIndex* whitelist_index{nullptr};
    CBlockIndex* first_index{nullptr};
    CBlockIndex* reward_index{nullptr};
    {
        LOCK(Assert(m_node.chainman)->GetMutex());
        CChain& active_chain = m_node.chainman->ActiveChain();
        reward_index = active_chain.Tip();
        first_index = reward_index->pprev;
        whitelist_index = first_index->pprev;
        BOOST_REQUIRE(reward_index);
        BOOST_REQUIRE(first_index);
        BOOST_REQUIRE(whitelist_index);
        BOOST_CHECK_EQUAL(first_real_block.GetHash(), first_index->GetBlockHash());
        BOOST_CHECK_EQUAL(reward_real_block.GetHash(), reward_index->GetBlockHash());
    }
    SetShadowRegtestSchedule(whitelist_index->nHeight, 300);
    SetMockTime(reward_index->GetBlockTime());

    CWallet wallet(m_node.chain.get(), "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);

    CTxDestination quantum_dest;
    CScript quantum_script;
    std::vector<unsigned char> quantum_public_key;
    CKeyingMaterial quantum_private_key;
    {
        LOCK(wallet.cs_wallet);
        auto op_dest = wallet.GetNewQuantumDestination("goldrush-shadow");
        BOOST_REQUIRE(op_dest);
        quantum_dest = *op_dest;
        quantum_script = GetScriptForDestination(quantum_dest);
        BOOST_CHECK(wallet.IsMine(quantum_dest) & ISMINE_SPENDABLE);
        const auto info = wallet.GetQuantumKeyInfo(quantum_dest);
        BOOST_REQUIRE(info.has_value());
        bilingual_str error;
        BOOST_REQUIRE(wallet.GetQuantumKey(info->witness_program, quantum_public_key, quantum_private_key, error));
        wallet.SetLastBlockProcessed(whitelist_index->nHeight, whitelist_index->GetBlockHash());
    }

    const CScript legacy_target = CScript{} << OP_TRUE;
    const COutPoint snapshot_coin_outpoint{uint256{42}, 0};
    CBlock first_shadow_block;
    CBlockUndo first_shadow_undo;
    CBlock reward_shadow_block;
    CBlockUndo reward_shadow_undo;
    CTransactionRef synthetic_payout_tx;
    {
        LOCK(Assert(m_node.chainman)->GetMutex());
        CCoinsViewCache& coins_tip = m_node.chainman->ActiveChainstate().CoinsTip();
        AddShadowWalletTestCoin(coins_tip, snapshot_coin_outpoint, 10'000 * COIN, legacy_target);
        ApplyLegacyWhitelistSnapshot(coins_tip, whitelist_index);

        first_shadow_block.vtx.push_back(MakeShadowWalletCoinbaseTx(CScript{} << OP_2));
        first_shadow_block.vtx.push_back(MakeShadowWalletCoinstakeTx(legacy_target));
        first_shadow_undo = MakeShadowWalletUndo(first_shadow_block, {{1, legacy_target}});
        BOOST_REQUIRE(ApplyShadowBlock(coins_tip, first_shadow_block, first_index, &first_shadow_undo));
        BOOST_REQUIRE(AdvanceGoldRushInventoryTip(coins_tip, first_index));

        std::vector<unsigned char> signal;
        BOOST_REQUIRE(BuildShadowSignalData(legacy_target, quantum_script, first_index->nHeight, first_index->GetBlockHash(), signal));

        reward_shadow_block.vtx.push_back(MakeShadowWalletCoinbaseTx(CScript{} << OP_3));
        reward_shadow_block.vtx.push_back(MakeShadowWalletCoinstakeTx(legacy_target));
        reward_shadow_block.vtx.push_back(MakeShadowWalletSignalTx(legacy_target, signal));
        reward_shadow_undo = MakeShadowWalletUndo(reward_shadow_block, {{1, legacy_target}, {2, legacy_target}});
        BOOST_REQUIRE(ApplyShadowBlock(coins_tip, reward_shadow_block, reward_index, &reward_shadow_undo));
        BOOST_REQUIRE(AdvanceGoldRushInventoryTip(coins_tip, reward_index));

        const std::vector<CTransactionRef> payouts = GetAppliedShadowClaimPayoutTransactions(
            coins_tip, reward_index->nHeight, reward_index->GetBlockHash(), reward_index->GetBlockTime());
        BOOST_REQUIRE_EQUAL(payouts.size(), 1U);
        synthetic_payout_tx = payouts[0];
        BOOST_REQUIRE_EQUAL(synthetic_payout_tx->vout.size(), 1U);
        BOOST_CHECK_EQUAL(synthetic_payout_tx->vout[0].nValue, 580 * COIN);
        BOOST_CHECK(synthetic_payout_tx->vout[0].scriptPubKey == quantum_script);
    }

    uint256 reward_hash = reward_index->GetBlockHash();
    uint256 reward_prev_hash = first_index->GetBlockHash();
    interfaces::BlockInfo reward_block_info{reward_hash};
    reward_block_info.prev_hash = &reward_prev_hash;
    reward_block_info.height = reward_index->nHeight;
    reward_block_info.data = &reward_real_block;
    reward_block_info.chain_time_max = reward_index->GetBlockTimeMax();

    wallet.blockConnected(ChainstateRole::NORMAL, reward_block_info);
    {
        LOCK(wallet.cs_wallet);
        const CWalletTx* wtx = wallet.GetWalletTx(synthetic_payout_tx->GetHash());
        BOOST_REQUIRE(wtx);
        const auto* confirmed = wtx->state<TxStateConfirmed>();
        BOOST_REQUIRE(confirmed);
        BOOST_CHECK_EQUAL(confirmed->confirmed_block_hash, reward_index->GetBlockHash());
        BOOST_CHECK_EQUAL(confirmed->confirmed_block_height, reward_index->nHeight);
        BOOST_CHECK_EQUAL(CachedTxGetImmatureCredit(wallet, *wtx, ISMINE_SPENDABLE), 580 * COIN);
        BOOST_CHECK_EQUAL(CachedTxGetAvailableCredit(wallet, *wtx, ISMINE_SPENDABLE), 0);
        BOOST_CHECK_EQUAL(GetBalance(wallet).m_mine_immature, 580 * COIN);
        BOOST_CHECK_EQUAL(wtx->mapValue.at("comment"), "PoS - Quantum Stake");
        BOOST_CHECK_EQUAL(wtx->mapValue.at("to"), EncodeDestination(quantum_dest));
    }

    {
        LOCK(Assert(m_node.chainman)->GetMutex());
        CCoinsViewCache& coins_tip = m_node.chainman->ActiveChainstate().CoinsTip();
        BOOST_REQUIRE(UndoShadowBlock(coins_tip, reward_shadow_block, reward_index, &reward_shadow_undo));
        BOOST_REQUIRE(RewindGoldRushInventoryTip(coins_tip, reward_index));
    }
    wallet.blockDisconnected(reward_block_info);
    {
        LOCK(wallet.cs_wallet);
        const CWalletTx* wtx = wallet.GetWalletTx(synthetic_payout_tx->GetHash());
        BOOST_REQUIRE(wtx);
        BOOST_CHECK(wtx->isInactive());
        BOOST_CHECK_EQUAL(GetBalance(wallet).m_mine_immature, 0);
    }

    {
        LOCK(Assert(m_node.chainman)->GetMutex());
        CCoinsViewCache& coins_tip = m_node.chainman->ActiveChainstate().CoinsTip();
        BOOST_REQUIRE(ApplyShadowBlock(coins_tip, reward_shadow_block, reward_index, &reward_shadow_undo));
        BOOST_REQUIRE(AdvanceGoldRushInventoryTip(coins_tip, reward_index));
    }

    CWallet rescan_wallet(m_node.chain.get(), "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(rescan_wallet.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(rescan_wallet.cs_wallet);
        auto op_dest = rescan_wallet.AddQuantumKey(quantum_public_key, quantum_private_key, "goldrush-shadow", reward_index->GetBlockTime());
        BOOST_REQUIRE(op_dest);
        BOOST_CHECK(*op_dest == quantum_dest);
        rescan_wallet.SetLastBlockProcessed(reward_index->nHeight, reward_index->GetBlockHash());
    }
    WalletRescanReserver reserver(rescan_wallet);
    BOOST_REQUIRE(reserver.reserve());
    CWallet::ScanResult result = rescan_wallet.ScanForWalletTransactions(
        reward_index->GetBlockHash(), reward_index->nHeight, /*max_height=*/{}, reserver, /*fUpdate=*/false, /*save_progress=*/false);
    BOOST_CHECK_EQUAL(result.status, CWallet::ScanResult::SUCCESS);
    BOOST_CHECK_EQUAL(result.last_scanned_block, reward_index->GetBlockHash());
    BOOST_REQUIRE(result.last_scanned_height);
    BOOST_CHECK_EQUAL(*result.last_scanned_height, reward_index->nHeight);
    {
        LOCK(rescan_wallet.cs_wallet);
        const CWalletTx* wtx = rescan_wallet.GetWalletTx(synthetic_payout_tx->GetHash());
        BOOST_REQUIRE(wtx);
        BOOST_CHECK(wtx->state<TxStateConfirmed>() != nullptr);
        BOOST_CHECK_EQUAL(CachedTxGetImmatureCredit(rescan_wallet, *wtx, ISMINE_SPENDABLE), 580 * COIN);
        BOOST_CHECK_EQUAL(GetBalance(rescan_wallet).m_mine_immature, 580 * COIN);
        BOOST_CHECK_EQUAL(wtx->mapValue.at("comment"), "PoS - Quantum Stake");
        BOOST_CHECK_EQUAL(wtx->mapValue.at("to"), EncodeDestination(quantum_dest));
    }

    // Model an unpublished intermediate wallet that persisted a payout with
    // the right QQCPAY block anchor but a txid no longer authenticated by the
    // block's current claim markers. Also cover the explicit metadata path
    // and prove an ordinary coinbase-shaped record is outside reconciliation.
    CMutableTransaction stale_mutable{*synthetic_payout_tx};
    stale_mutable.vout[0].nValue -= COIN;
    const CTransactionRef stale_payout_tx = MakeTransactionRef(std::move(stale_mutable));

    CMutableTransaction marked_mutable{*synthetic_payout_tx};
    marked_mutable.vin[0].scriptSig = CScript{} << OP_1;
    marked_mutable.vout[0].nValue -= 2 * COIN;
    const CTransactionRef marked_stale_tx = MakeTransactionRef(std::move(marked_mutable));

    CMutableTransaction ordinary_mutable{*synthetic_payout_tx};
    ordinary_mutable.vin[0].scriptSig = CScript{} << OP_2;
    ordinary_mutable.vout[0].nValue -= 3 * COIN;
    const CTransactionRef ordinary_coinbase_tx = MakeTransactionRef(std::move(ordinary_mutable));

    const int synthetic_position = static_cast<int>(reward_real_block.vtx.size());
    BOOST_REQUIRE(rescan_wallet.AddToWallet(
        stale_payout_tx,
        TxStateConfirmed{reward_index->GetBlockHash(), reward_index->nHeight, synthetic_position + 10},
        [](CWalletTx& wtx, bool) {
            wtx.mapValue["intermediate-audit"] = "preserve-stale-envelope";
            return true;
        }));
    BOOST_REQUIRE(rescan_wallet.AddToWallet(
        marked_stale_tx,
        TxStateConfirmed{reward_index->GetBlockHash(), reward_index->nHeight, synthetic_position + 11},
        [](CWalletTx& wtx, bool) {
            wtx.mapValue["qq_synthetic_goldrush_payout"] = "1";
            wtx.mapValue["intermediate-audit"] = "preserve-stale-marker";
            return true;
        }));
    BOOST_REQUIRE(rescan_wallet.AddToWallet(
        ordinary_coinbase_tx,
        TxStateConfirmed{reward_index->GetBlockHash(), reward_index->nHeight, synthetic_position + 12}));

    // A valid payout may already have been spent by a wallet transaction. Its
    // authenticated source record must remain confirmed for debit and history
    // accounting even though its outpoint contributes no balance.
    CMutableTransaction payout_spend_mutable;
    payout_spend_mutable.nTime = reward_index->GetBlockTime();
    payout_spend_mutable.vin.emplace_back(COutPoint{synthetic_payout_tx->GetHash(), 0});
    payout_spend_mutable.vout.emplace_back(synthetic_payout_tx->vout[0].nValue - COIN, CScript{} << OP_TRUE);
    const CTransactionRef payout_spend_tx = MakeTransactionRef(std::move(payout_spend_mutable));
    BOOST_REQUIRE(rescan_wallet.AddToWallet(
        payout_spend_tx,
        TxStateConfirmed{reward_index->GetBlockHash(), reward_index->nHeight, synthetic_position + 13}));

    CWallet reconciled_wallet(m_node.chain.get(), "", DuplicateMockDatabase(rescan_wallet.GetDatabase()));
    BOOST_REQUIRE_EQUAL(reconciled_wallet.LoadWallet(), DBErrors::LOAD_OK);
    WITH_LOCK(reconciled_wallet.cs_wallet,
              reconciled_wallet.SetLastBlockProcessed(reward_index->nHeight, reward_index->GetBlockHash()));
    {
        LOCK(reconciled_wallet.cs_wallet);
        const CWalletTx& stale = reconciled_wallet.mapWallet.at(stale_payout_tx->GetHash());
        BOOST_CHECK(stale.isInactive());
        BOOST_CHECK_EQUAL(stale.mapValue.at("qq_synthetic_goldrush_payout"), "1");
        BOOST_CHECK_EQUAL(stale.mapValue.at("qq_synthetic_goldrush_payout_stale"), "1");
        BOOST_CHECK_EQUAL(stale.mapValue.at("qq_synthetic_goldrush_payout_stale_block"), reward_index->GetBlockHash().GetHex());
        BOOST_CHECK_EQUAL(stale.mapValue.at("qq_synthetic_goldrush_payout_stale_height"), ToString(reward_index->nHeight));
        BOOST_CHECK_EQUAL(stale.mapValue.at("intermediate-audit"), "preserve-stale-envelope");
        BOOST_CHECK_EQUAL(CachedTxGetImmatureCredit(reconciled_wallet, stale, ISMINE_SPENDABLE), 0);
        BOOST_CHECK(reconciled_wallet.GetTxBlocksToMaturity(stale) > 0);

        const CWalletTx& marked = reconciled_wallet.mapWallet.at(marked_stale_tx->GetHash());
        BOOST_CHECK(marked.isInactive());
        BOOST_CHECK_EQUAL(marked.mapValue.at("qq_synthetic_goldrush_payout_stale"), "1");
        BOOST_CHECK_EQUAL(marked.mapValue.at("intermediate-audit"), "preserve-stale-marker");

        const CWalletTx& ordinary = reconciled_wallet.mapWallet.at(ordinary_coinbase_tx->GetHash());
        BOOST_CHECK(ordinary.isConfirmed());
        BOOST_CHECK(ordinary.mapValue.count("qq_synthetic_goldrush_payout_stale") == 0);

        const CWalletTx& canonical = reconciled_wallet.mapWallet.at(synthetic_payout_tx->GetHash());
        BOOST_CHECK(canonical.isConfirmed());
        BOOST_CHECK(reconciled_wallet.IsSpent(COutPoint{synthetic_payout_tx->GetHash(), 0}));
        BOOST_CHECK_EQUAL(CachedTxGetAvailableCredit(reconciled_wallet, canonical, ISMINE_SPENDABLE), 0);
        BOOST_CHECK_EQUAL(
            GetBalance(reconciled_wallet).m_mine_immature,
            synthetic_payout_tx->vout[0].nValue + ordinary_coinbase_tx->vout[0].nValue);
    }

    // A second database load proves stale state, audit metadata, and the
    // canonical spent record were persisted rather than repaired in memory.
    CWallet persisted_wallet(m_node.chain.get(), "", DuplicateMockDatabase(reconciled_wallet.GetDatabase()));
    BOOST_REQUIRE_EQUAL(persisted_wallet.LoadWallet(), DBErrors::LOAD_OK);
    WITH_LOCK(persisted_wallet.cs_wallet,
              persisted_wallet.SetLastBlockProcessed(reward_index->nHeight, reward_index->GetBlockHash()));
    {
        LOCK(persisted_wallet.cs_wallet);
        BOOST_CHECK(persisted_wallet.mapWallet.at(stale_payout_tx->GetHash()).isInactive());
        BOOST_CHECK(persisted_wallet.mapWallet.at(marked_stale_tx->GetHash()).isInactive());
        BOOST_CHECK(persisted_wallet.mapWallet.at(ordinary_coinbase_tx->GetHash()).isConfirmed());
        BOOST_CHECK(persisted_wallet.mapWallet.at(synthetic_payout_tx->GetHash()).isConfirmed());
        BOOST_CHECK(persisted_wallet.IsSpent(COutPoint{synthetic_payout_tx->GetHash(), 0}));
    }

    WalletRescanReserver persisted_reserver(persisted_wallet);
    BOOST_REQUIRE(persisted_reserver.reserve());
    const CWallet::ScanResult persisted_scan = persisted_wallet.ScanForWalletTransactions(
        reward_index->GetBlockHash(), reward_index->nHeight, reward_index->nHeight,
        persisted_reserver, /*fUpdate=*/true, /*save_progress=*/false);
    BOOST_CHECK_EQUAL(persisted_scan.status, CWallet::ScanResult::SUCCESS);
    {
        LOCK(persisted_wallet.cs_wallet);
        BOOST_CHECK(persisted_wallet.mapWallet.at(stale_payout_tx->GetHash()).isInactive());
        BOOST_CHECK(persisted_wallet.mapWallet.at(marked_stale_tx->GetHash()).isInactive());
        BOOST_CHECK(persisted_wallet.mapWallet.at(synthetic_payout_tx->GetHash()).isConfirmed());
    }

    // Watch-only ownership follows the same path: an authenticated payout is
    // counted, while a persisted stale intermediate record is retained but
    // cannot inflate watch-only immature credit after restart or rescan.
    CWallet watch_wallet(m_node.chain.get(), "watch-shadow", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(watch_wallet.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(watch_wallet.cs_wallet);
        watch_wallet.SetupLegacyScriptPubKeyMan();
        LegacyScriptPubKeyMan* spkm = watch_wallet.GetLegacyScriptPubKeyMan();
        BOOST_REQUIRE(spkm);
        LOCK(spkm->cs_KeyStore);
        BOOST_REQUIRE(spkm->AddWatchOnly(quantum_script, reward_index->GetBlockTime()));
        watch_wallet.SetLastBlockProcessed(reward_index->nHeight, reward_index->GetBlockHash());
    }
    WalletRescanReserver watch_reserver(watch_wallet);
    BOOST_REQUIRE(watch_reserver.reserve());
    const CWallet::ScanResult watch_scan = watch_wallet.ScanForWalletTransactions(
        reward_index->GetBlockHash(), reward_index->nHeight, reward_index->nHeight,
        watch_reserver, /*fUpdate=*/true, /*save_progress=*/false);
    BOOST_CHECK_EQUAL(watch_scan.status, CWallet::ScanResult::SUCCESS);
    BOOST_REQUIRE(watch_wallet.AddToWallet(
        stale_payout_tx,
        TxStateConfirmed{reward_index->GetBlockHash(), reward_index->nHeight, synthetic_position + 10}));

    CWallet watch_reloaded(m_node.chain.get(), "watch-shadow", DuplicateMockDatabase(watch_wallet.GetDatabase()));
    BOOST_REQUIRE_EQUAL(watch_reloaded.LoadWallet(), DBErrors::LOAD_OK);
    WITH_LOCK(watch_reloaded.cs_wallet,
              watch_reloaded.SetLastBlockProcessed(reward_index->nHeight, reward_index->GetBlockHash()));
    {
        LOCK(watch_reloaded.cs_wallet);
        const CWalletTx& canonical = watch_reloaded.mapWallet.at(synthetic_payout_tx->GetHash());
        const CWalletTx& stale = watch_reloaded.mapWallet.at(stale_payout_tx->GetHash());
        BOOST_CHECK(canonical.isConfirmed());
        BOOST_CHECK(stale.isInactive());
        BOOST_CHECK_EQUAL(CachedTxGetImmatureCredit(watch_reloaded, canonical, ISMINE_WATCH_ONLY), 580 * COIN);
        BOOST_CHECK_EQUAL(CachedTxGetImmatureCredit(watch_reloaded, stale, ISMINE_WATCH_ONLY), 0);
        const Balance watch_balance = GetBalance(watch_reloaded);
        BOOST_CHECK_EQUAL(watch_balance.m_watchonly_immature, 580 * COIN);
        BOOST_CHECK_EQUAL(watch_balance.m_mine_immature, 0);
    }

    {
        LOCK(Assert(m_node.chainman)->GetMutex());
        CCoinsViewCache& coins_tip = m_node.chainman->ActiveChainstate().CoinsTip();
        BOOST_REQUIRE(UndoShadowBlock(coins_tip, reward_shadow_block, reward_index, &reward_shadow_undo));
        BOOST_REQUIRE(RewindGoldRushInventoryTip(coins_tip, reward_index));
        BOOST_REQUIRE(UndoShadowBlock(coins_tip, first_shadow_block, first_index, &first_shadow_undo));
        BOOST_REQUIRE(RewindGoldRushInventoryTip(coins_tip, first_index));
        UndoLegacyWhitelistSnapshot(coins_tip, whitelist_index);
        coins_tip.SpendCoin(snapshot_coin_outpoint);
    }
}

BOOST_FIXTURE_TEST_CASE(importmulti_rescan, TestChain100Setup)
{
    // Cap last block file size, and mine new block in a new block file.
    CBlockIndex* oldTip = WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain().Tip());
    WITH_LOCK(::cs_main, m_node.chainman->m_blockman.GetBlockFileInfo(oldTip->GetBlockPos().nFile)->nSize = MAX_BLOCKFILE_SIZE);
    CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    CBlockIndex* newTip = m_node.chainman->ActiveChain().Tip();

    // Blackcoin
    /*
    // Prune the older block file.
    int file_number;
    {
        LOCK(cs_main);
        file_number = oldTip->GetBlockPos().nFile;
        Assert(m_node.chainman)->m_blockman.PruneOneBlockFile(file_number);
    }
    m_node.chainman->m_blockman.UnlinkPrunedFiles({file_number});
    */

    // Verify importmulti RPC returns failure for a key whose creation time is
    // before the missing block, and success for a key whose creation time is
    // after.
    {
        const std::shared_ptr<CWallet> wallet = std::make_shared<CWallet>(m_node.chain.get(), "", CreateMockableWalletDatabase());
        wallet->SetupLegacyScriptPubKeyMan();
        WITH_LOCK(wallet->cs_wallet, wallet->SetLastBlockProcessed(newTip->nHeight, newTip->GetBlockHash()));
        WalletContext context;
        context.args = &m_args;
        AddWallet(context, wallet);
        UniValue keys;
        keys.setArray();
        UniValue key;
        key.setObject();
        key.pushKV("scriptPubKey", HexStr(GetScriptForRawPubKey(coinbaseKey.GetPubKey())));
        key.pushKV("timestamp", 0);
        key.pushKV("internal", UniValue(true));
        keys.push_back(key);
        key.clear();
        key.setObject();
        CKey futureKey;
        futureKey.MakeNewKey(true);
        key.pushKV("scriptPubKey", HexStr(GetScriptForRawPubKey(futureKey.GetPubKey())));
        key.pushKV("timestamp", newTip->GetBlockTimeMax() + TIMESTAMP_WINDOW + 1);
        key.pushKV("internal", UniValue(true));
        keys.push_back(key);
        JSONRPCRequest request;
        request.context = &context;
        request.params.setArray();
        request.params.push_back(keys);

        UniValue response = importmulti().HandleRequest(request);
        BOOST_CHECK_EQUAL(response.write(), "[{\"success\":true},{\"success\":true}]");
        RemoveWallet(context, wallet, /* load_on_start= */ std::nullopt);
    }
}

// Verify importwallet RPC starts rescan at earliest block with timestamp
// greater or equal than key birthday. Previously there was a bug where
// importwallet RPC would start the scan at the latest block with timestamp less
// than or equal to key birthday.
BOOST_FIXTURE_TEST_CASE(importwallet_rescan, TestChain100Setup)
{
    // Create two blocks with same timestamp to verify that importwallet rescan
    // will pick up both blocks, not just the first.
    const int64_t BLOCK_TIME = WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain().Tip()->GetBlockTimeMax() + 5);
    SetMockTime(BLOCK_TIME);
    m_coinbase_txns.emplace_back(CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey())).vtx[0]);
    m_coinbase_txns.emplace_back(CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey())).vtx[0]);

    // Set key birthday to block time increased by the timestamp window, so
    // rescan will start at the block time.
    const int64_t KEY_TIME = BLOCK_TIME + TIMESTAMP_WINDOW;
    SetMockTime(KEY_TIME);
    m_coinbase_txns.emplace_back(CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey())).vtx[0]);

    std::string backup_file = fs::PathToString(m_args.GetDataDirNet() / "wallet.backup");

    // Import key into wallet and call dumpwallet to create backup file.
    {
        WalletContext context;
        context.args = &m_args;
        const std::shared_ptr<CWallet> wallet = std::make_shared<CWallet>(m_node.chain.get(), "", CreateMockableWalletDatabase());
        {
            auto spk_man = wallet->GetOrCreateLegacyScriptPubKeyMan();
            LOCK2(wallet->cs_wallet, spk_man->cs_KeyStore);
            spk_man->mapKeyMetadata[coinbaseKey.GetPubKey().GetID()].nCreateTime = KEY_TIME;
            spk_man->AddKeyPubKey(coinbaseKey, coinbaseKey.GetPubKey());
        }
        AddWallet(context, wallet);
        {
            LOCK2(Assert(m_node.chainman)->GetMutex(), wallet->cs_wallet);
            wallet->SetLastBlockProcessed(m_node.chainman->ActiveChain().Height(), m_node.chainman->ActiveChain().Tip()->GetBlockHash());
        }
        JSONRPCRequest request;
        request.context = &context;
        request.params.setArray();
        request.params.push_back(backup_file);

        wallet::dumpwallet().HandleRequest(request);
        RemoveWallet(context, wallet, /* load_on_start= */ std::nullopt);
    }

    // Call importwallet RPC and verify all blocks with timestamps >= BLOCK_TIME
    // were scanned, and no prior blocks were scanned.
    {
        const std::shared_ptr<CWallet> wallet = std::make_shared<CWallet>(m_node.chain.get(), "", CreateMockableWalletDatabase());
        {
            LOCK(wallet->cs_wallet);
            wallet->SetupLegacyScriptPubKeyMan();
        }

        WalletContext context;
        context.args = &m_args;
        JSONRPCRequest request;
        request.context = &context;
        request.params.setArray();
        request.params.push_back(backup_file);
        AddWallet(context, wallet);
        {
            LOCK2(Assert(m_node.chainman)->GetMutex(), wallet->cs_wallet);
            wallet->SetLastBlockProcessed(m_node.chainman->ActiveChain().Height(), m_node.chainman->ActiveChain().Tip()->GetBlockHash());
        }
        wallet::importwallet().HandleRequest(request);
        RemoveWallet(context, wallet, /* load_on_start= */ std::nullopt);

        BOOST_CHECK_EQUAL(m_coinbase_txns.size(), 103U);
        {
            LOCK(wallet->cs_wallet);
            BOOST_CHECK_EQUAL(wallet->mapWallet.size(), 3U);
            for (size_t i = 0; i < m_coinbase_txns.size(); ++i) {
                bool found = wallet->GetWalletTx(m_coinbase_txns[i]->GetHash());
                bool expected = i >= 100;
                BOOST_CHECK_EQUAL(found, expected);
            }
        }
    }
}

// Check that GetImmatureCredit() returns a newly calculated value instead of
// the cached value after a MarkDirty() call.
//
// This is a regression test written to verify a bugfix for the immature credit
// function. Similar tests probably should be written for the other credit and
// debit functions.
BOOST_FIXTURE_TEST_CASE(coin_mark_dirty_immature_credit, TestChain100Setup)
{
    CWallet wallet(m_node.chain.get(), "", CreateMockableWalletDatabase());

    LOCK(wallet.cs_wallet);
    LOCK(Assert(m_node.chainman)->GetMutex());
    CWalletTx wtx{m_coinbase_txns.back(), TxStateConfirmed{m_node.chainman->ActiveChain().Tip()->GetBlockHash(), m_node.chainman->ActiveChain().Height(), /*index=*/0}};
    wallet.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
    wallet.SetupDescriptorScriptPubKeyMans();

    wallet.SetLastBlockProcessed(m_node.chainman->ActiveChain().Height(), m_node.chainman->ActiveChain().Tip()->GetBlockHash());

    // Call GetImmatureCredit() once before adding the key to the wallet to
    // cache the current immature credit amount, which is 0.
    BOOST_CHECK_EQUAL(CachedTxGetImmatureCredit(wallet, wtx, ISMINE_SPENDABLE), 0);

    // Invalidate the cached value, add the key, and make sure a new immature
    // credit amount is calculated.
    wtx.MarkDirty();
    AddKey(wallet, coinbaseKey);
    BOOST_CHECK_EQUAL(CachedTxGetImmatureCredit(wallet, wtx, ISMINE_SPENDABLE), wtx.tx->vout[0].nValue);
}

static int64_t AddTx(ChainstateManager& chainman, CWallet& wallet, uint32_t lockTime, int64_t mockTime, int64_t blockTime)
{
    CMutableTransaction tx;
    TxState state = TxStateInactive{};
    tx.nLockTime = lockTime;
    SetMockTime(mockTime);
    CBlockIndex* block = nullptr;
    if (blockTime > 0) {
        LOCK(cs_main);
        auto inserted = chainman.BlockIndex().emplace(std::piecewise_construct, std::make_tuple(GetRandHash()), std::make_tuple());
        assert(inserted.second);
        const uint256& hash = inserted.first->first;
        block = &inserted.first->second;
        block->nTime = blockTime;
        block->phashBlock = &hash;
        state = TxStateConfirmed{hash, block->nHeight, /*index=*/0};
    }
    const std::optional<WalletBlockTime> block_time = blockTime > 0
        ? std::make_optional(WalletBlockTime{blockTime, blockTime})
        : std::nullopt;
    return wallet.AddToWallet(MakeTransactionRef(tx), state, [&](CWalletTx& wtx, bool /* new_tx */) {
        // Assign wtx.m_state to simplify test and avoid the need to simulate
        // reorg events. Without this, AddToWallet asserts false when the same
        // transaction is confirmed in different blocks.
        wtx.m_state = state;
        return true;
    }, /*fFlushOnClose=*/true, /*rescanning_old_block=*/false, block_time)->nTimeSmart;
}

// Simple test to verify assignment of CWalletTx::nSmartTime value. Could be
// expanded to cover more corner cases of smart time logic.
BOOST_AUTO_TEST_CASE(ComputeTimeSmart)
{
    // New transaction should use clock time if lower than block time.
    BOOST_CHECK_EQUAL(AddTx(*m_node.chainman, m_wallet, 1, 100, 120), 100);

    // Test that updating existing transaction does not change smart time.
    BOOST_CHECK_EQUAL(AddTx(*m_node.chainman, m_wallet, 1, 200, 220), 100);

    // New transaction should use clock time if there's no block time.
    BOOST_CHECK_EQUAL(AddTx(*m_node.chainman, m_wallet, 2, 300, 0), 300);

    // New transaction should use block time if lower than clock time.
    BOOST_CHECK_EQUAL(AddTx(*m_node.chainman, m_wallet, 3, 420, 400), 400);

    // New transaction should use latest entry time if higher than
    // min(block time, clock time).
    BOOST_CHECK_EQUAL(AddTx(*m_node.chainman, m_wallet, 4, 500, 390), 400);

    // If there are future entries, new transaction should use time of the
    // newest entry that is no more than 300 seconds ahead of the clock time.
    BOOST_CHECK_EQUAL(AddTx(*m_node.chainman, m_wallet, 5, 50, 600), 300);
}

void TestLoadWallet(const std::string& name, DatabaseFormat format, std::function<void(std::shared_ptr<CWallet>)> f)
{
    node::NodeContext node;
    auto chain{interfaces::MakeChain(node)};
    DatabaseOptions options;
    options.require_format = format;
    DatabaseStatus status;
    bilingual_str error;
    std::vector<bilingual_str> warnings;
    auto database{MakeWalletDatabase(name, options, status, error)};
    auto wallet{std::make_shared<CWallet>(chain.get(), "", std::move(database))};
    BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
    WITH_LOCK(wallet->cs_wallet, f(wallet));
}

BOOST_FIXTURE_TEST_CASE(LoadReceiveRequests, TestingSetup)
{
    for (DatabaseFormat format : DATABASE_FORMATS) {
        const std::string name{strprintf("receive-requests-%i", format)};
        TestLoadWallet(name, format, [](std::shared_ptr<CWallet> wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet->cs_wallet) {
            BOOST_CHECK(!wallet->IsAddressPreviouslySpent(PKHash()));
            WalletBatch batch{wallet->GetDatabase()};
            BOOST_CHECK(batch.WriteAddressPreviouslySpent(PKHash(), true));
            BOOST_CHECK(batch.WriteAddressPreviouslySpent(ScriptHash(), true));
            BOOST_CHECK(wallet->SetAddressReceiveRequest(batch, PKHash(), "0", "val_rr00"));
            BOOST_CHECK(wallet->EraseAddressReceiveRequest(batch, PKHash(), "0"));
            BOOST_CHECK(wallet->SetAddressReceiveRequest(batch, PKHash(), "1", "val_rr10"));
            BOOST_CHECK(wallet->SetAddressReceiveRequest(batch, PKHash(), "1", "val_rr11"));
            BOOST_CHECK(wallet->SetAddressReceiveRequest(batch, ScriptHash(), "2", "val_rr20"));
        });
        TestLoadWallet(name, format, [](std::shared_ptr<CWallet> wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet->cs_wallet) {
            BOOST_CHECK(wallet->IsAddressPreviouslySpent(PKHash()));
            BOOST_CHECK(wallet->IsAddressPreviouslySpent(ScriptHash()));
            auto requests = wallet->GetAddressReceiveRequests();
            auto erequests = {"val_rr11", "val_rr20"};
            BOOST_CHECK_EQUAL_COLLECTIONS(requests.begin(), requests.end(), std::begin(erequests), std::end(erequests));
            WalletBatch batch{wallet->GetDatabase()};
            BOOST_CHECK(batch.WriteAddressPreviouslySpent(PKHash(), false));
            BOOST_CHECK(batch.EraseAddressData(ScriptHash()));
        });
        TestLoadWallet(name, format, [](std::shared_ptr<CWallet> wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet->cs_wallet) {
            BOOST_CHECK(!wallet->IsAddressPreviouslySpent(PKHash()));
            BOOST_CHECK(!wallet->IsAddressPreviouslySpent(ScriptHash()));
            auto requests = wallet->GetAddressReceiveRequests();
            auto erequests = {"val_rr11"};
            BOOST_CHECK_EQUAL_COLLECTIONS(requests.begin(), requests.end(), std::begin(erequests), std::end(erequests));
        });
    }
}

static CMutableTransaction QuantumWalletSpendFixture(const CTxDestination& dest, std::map<COutPoint, Coin>& coins)
{
    BOOST_REQUIRE(IsQuantumMigrationDestination(dest));
    const CScript quantum_script = GetScriptForDestination(dest);

    CMutableTransaction funding_mut;
    funding_mut.nVersion = 2;
    funding_mut.vout.emplace_back(COIN, quantum_script);
    const CTransaction funding_tx{funding_mut};

    CMutableTransaction spend;
    spend.nVersion = 2;
    spend.vin.emplace_back(COutPoint{funding_tx.GetHash(), 0});
    spend.vout.emplace_back(COIN - 1000, quantum_script);
    coins.emplace(spend.vin[0].prevout, Coin{funding_tx.vout[0], 1, false, false, 0});
    return spend;
}

static void CheckQuantumWalletSigning(CWallet& wallet, const CTxDestination& dest)
{
    const CScript quantum_script = GetScriptForDestination(dest);
    {
        LOCK(wallet.cs_wallet);
        BOOST_CHECK(wallet.IsMine(quantum_script) & ISMINE_SPENDABLE);
    }

    std::map<COutPoint, Coin> coins;
    CMutableTransaction spend = QuantumWalletSpendFixture(dest, coins);
    std::map<int, bilingual_str> input_errors;
    BOOST_CHECK(wallet.SignTransaction(spend, coins, SIGHASH_ALL, input_errors));
    BOOST_CHECK(input_errors.empty());
    BOOST_REQUIRE_EQUAL(spend.vin[0].scriptWitness.stack.size(), 2U);
    BOOST_CHECK_EQUAL(spend.vin[0].scriptWitness.stack[0].size(), ML_DSA::SIGNATURE_BYTES);
    BOOST_CHECK_EQUAL(spend.vin[0].scriptWitness.stack[1].size(), ML_DSA::PUBLICKEY_BYTES);
    BOOST_CHECK(spend.vin[0].scriptSig.empty());
}

static void CheckQuantumKeyChallenge(CWallet& wallet, const CTxDestination& dest) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    const auto info = wallet.GetQuantumKeyInfo(dest);
    BOOST_REQUIRE(info.has_value());
    std::vector<unsigned char> public_key;
    CKeyingMaterial private_key;
    bilingual_str error;
    BOOST_REQUIRE_MESSAGE(wallet.GetQuantumKey(info->witness_program, public_key, private_key, error), error.original);

    const uint256 challenge = GetRandHash();
    std::vector<unsigned char> private_key_bytes(private_key.begin(), private_key.end());
    std::vector<unsigned char> signature;
    BOOST_REQUIRE(ML_DSA::Sign(private_key_bytes, challenge.begin(), uint256::size(), signature));
    memory_cleanse(private_key_bytes.data(), private_key_bytes.size());
    BOOST_CHECK(ML_DSA::Verify(public_key, challenge.begin(), uint256::size(), signature));
}

class QuantumWalletSigningTestingSetup : public TestChain100Setup
{
public:
    QuantumWalletSigningTestingSetup()
        : TestChain100Setup{ChainType::REGTEST, {
              "-shadowwhitelistheight=99",
              "-shadowgoldrushstartheight=100",
              "-shadowgoldrushendheight=100",
              "-qqgoldrushendheight=100",
              "-qqmigrationendheight=200",
          }}
    {
    }
};

static std::shared_ptr<CWallet> TestLoadQuantumWallet(const std::string& name, DatabaseFormat format, interfaces::Chain* chain = nullptr)
{
    DatabaseOptions options;
    options.require_format = format;
    DatabaseStatus status;
    bilingual_str error;
    auto database{MakeWalletDatabase(name, options, status, error)};
    auto wallet{std::make_shared<CWallet>(chain, "", std::move(database))};
    BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
    return wallet;
}

static std::shared_ptr<CWallet> TestLoadQuantumWalletBackup(const fs::path& path)
{
    // A wallet backup is a standalone data file. Load it from an isolated
    // wallet directory so SQLiteDataFile() does not append wallet.dat to the
    // backup filename and probe <backup>/wallet.dat.
    const fs::path scratch_dir{GetUniquePath(path.parent_path())};
    BOOST_REQUIRE(TryCreateDirectories(scratch_dir));
    fs::copy_file(path, scratch_dir / "wallet.dat", fs::copy_options::none);

    DatabaseOptions options;
    options.require_existing = true;
    options.verify = true;
    DatabaseStatus status;
    bilingual_str error;
    auto database{MakeDatabase(scratch_dir, options, status, error)};
    BOOST_REQUIRE_MESSAGE(database, error.original);
    auto wallet = std::shared_ptr<CWallet>{
        new CWallet(/*chain=*/nullptr, "restored-quantum-backup", std::move(database)),
        [scratch_dir](CWallet* wallet) {
            delete wallet;
            try {
                fs::remove_all(scratch_dir);
            } catch (const std::exception&) {
                // The fixture root is removed after the test. A cleanup
                // failure must not mask the backup verification result.
            }
        }};
    BOOST_REQUIRE_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
    return wallet;
}

BOOST_FIXTURE_TEST_CASE(QuantumWalletKeysPersistAndSign, QuantumWalletSigningTestingSetup)
{
    for (DatabaseFormat format : DATABASE_FORMATS) {
        const std::string name{strprintf("quantum-wallet-keys-%i", format)};
        CTxDestination dest;
        {
            auto wallet{TestLoadQuantumWallet(name, format, m_node.chain.get())};
            {
                LOCK(wallet->cs_wallet);
                auto op_dest = wallet->GetNewQuantumDestination("quantum");
                BOOST_REQUIRE(op_dest);
                dest = *op_dest;
                BOOST_CHECK(wallet->IsWalletFlagSet(WALLET_FLAG_QUANTUM_KEYS));
                BOOST_CHECK(!wallet->IsWalletFlagSet(WALLET_FLAG_BLANK_WALLET));
                const auto info = wallet->GetQuantumKeyInfo(dest);
                BOOST_REQUIRE(info.has_value());
                BOOST_CHECK(!info->encrypted);
                BOOST_CHECK(info->durably_stored);
                BOOST_CHECK(!info->backup_verified);
            }
            CheckQuantumWalletSigning(*wallet, dest);
        }
        {
            auto wallet{TestLoadQuantumWallet(name, format, m_node.chain.get())};
            {
                LOCK(wallet->cs_wallet);
                BOOST_CHECK(wallet->IsWalletFlagSet(WALLET_FLAG_QUANTUM_KEYS));
                BOOST_CHECK(wallet->IsMine(dest) & ISMINE_SPENDABLE);
                const auto info = wallet->GetQuantumKeyInfo(dest);
                BOOST_REQUIRE(info.has_value());
                BOOST_CHECK(!info->encrypted);
                BOOST_CHECK(info->durably_stored);
                BOOST_CHECK(!info->backup_verified);
            }
            CheckQuantumWalletSigning(*wallet, dest);
        }
    }
}

BOOST_FIXTURE_TEST_CASE(ExplicitQuantumAutomationBindingsPersistWithoutKeyCreation, QuantumWalletSigningTestingSetup)
{
    ScopedArgsSettings args_guard;
    args_guard.Force("-qqallowautokeycreation", "0");
    args_guard.Force("-qqautoredelegate", "0");

    auto quantum_inventory = [](CWallet& wallet) {
        LOCK(wallet.cs_wallet);
        std::set<std::string> addresses;
        for (const QuantumKeyInfo& info : wallet.ListQuantumKeyInfos()) {
            addresses.insert(EncodeDestination(info.destination));
        }
        return addresses;
    };

    for (DatabaseFormat format : DATABASE_FORMATS) {
        const std::string name{strprintf("explicit-quantum-bindings-%i", format)};
        CTxDestination bound_dest;
        std::set<std::string> expected_inventory;
        {
            auto wallet{TestLoadQuantumWallet(name, format, m_node.chain.get())};
            {
                LOCK(wallet->cs_wallet);
                auto created = wallet->GetNewQuantumDestination("unrelated operator key");
                BOOST_REQUIRE(created);
                bound_dest = *created;
                const auto* entry = wallet->FindAddressBookEntry(bound_dest);
                BOOST_REQUIRE(entry);
                BOOST_CHECK_EQUAL(entry->GetLabel(), "unrelated operator key");
            }
            expected_inventory = quantum_inventory(*wallet);
            BOOST_REQUIRE_EQUAL(expected_inventory.size(), 1U);

            const std::string address = EncodeDestination(bound_dest);
            args_guard.Force("-qqpowpayoutaddress", address);
            args_guard.Force("-qqpospayoutaddress", address);
            args_guard.Force("-qqdemurragechangeaddress", address);

            bilingual_str error;
            bool created{true};
            BOOST_REQUIRE_MESSAGE(wallet->EnsurePowPayoutAddress(error, &created), error.original);
            BOOST_CHECK(!created);
            {
                LOCK(wallet->cs_wallet);
                BOOST_CHECK_EQUAL(wallet->m_pow_payout_quantum, address);
            }

            CScript payout_script;
            std::string payout_address;
            created = true;
            BOOST_REQUIRE_MESSAGE(
                wallet->EnsureShadowSignalPayoutAddress(payout_script, payout_address, error, &created),
                error.original);
            BOOST_CHECK(!created);
            BOOST_CHECK_EQUAL(payout_address, address);
            BOOST_CHECK(payout_script == GetScriptForDestination(bound_dest));

            CCoinControl coin_control;
            BOOST_REQUIRE_MESSAGE(wallet->PrepareAutomaticDemurrageChangeAddress(coin_control, error), error.original);
            BOOST_CHECK(coin_control.destChange == bound_dest);

            // The mining loop and signal retry path may resolve their binding
            // repeatedly. Re-resolution keeps the same cached value, which
            // also keeps configured-binding logging edge-triggered.
            created = true;
            BOOST_REQUIRE_MESSAGE(wallet->EnsurePowPayoutAddress(error, &created), error.original);
            BOOST_CHECK(!created);
            created = true;
            BOOST_REQUIRE_MESSAGE(
                wallet->EnsureShadowSignalPayoutAddress(payout_script, payout_address, error, &created),
                error.original);
            BOOST_CHECK(!created);
            {
                LOCK(wallet->cs_wallet);
                BOOST_CHECK_EQUAL(wallet->m_pow_payout_quantum, address);
                BOOST_CHECK_EQUAL(wallet->m_shadow_signal_payout_quantum, address);
            }
            BOOST_CHECK(quantum_inventory(*wallet) == expected_inventory);
        }

        // The binding is configuration-backed and the key is wallet-backed.
        // Reopen the database, invoke all three paths again, and prove that no
        // extra non-HD key appears and no payout label is required.
        {
            auto wallet{TestLoadQuantumWallet(name, format, m_node.chain.get())};
            BOOST_CHECK(quantum_inventory(*wallet) == expected_inventory);

            bilingual_str error;
            bool created{true};
            BOOST_REQUIRE_MESSAGE(wallet->EnsurePowPayoutAddress(error, &created), error.original);
            BOOST_CHECK(!created);

            CScript payout_script;
            std::string payout_address;
            created = true;
            BOOST_REQUIRE_MESSAGE(
                wallet->EnsureShadowSignalPayoutAddress(payout_script, payout_address, error, &created),
                error.original);
            BOOST_CHECK(!created);
            BOOST_CHECK_EQUAL(payout_address, EncodeDestination(bound_dest));

            CCoinControl coin_control;
            BOOST_REQUIRE_MESSAGE(wallet->PrepareAutomaticDemurrageChangeAddress(coin_control, error), error.original);
            BOOST_CHECK(coin_control.destChange == bound_dest);
            BOOST_CHECK(quantum_inventory(*wallet) == expected_inventory);
        }
    }
}

BOOST_FIXTURE_TEST_CASE(ExplicitQuantumAutomationBindingsFailClosed, WalletTestingSetup)
{
    ScopedArgsSettings args_guard;
    args_guard.Force("-qqallowautokeycreation", "0");
    args_guard.Force("-qqautoredelegate", "0");

    CTxDestination owned_dest;
    {
        LOCK(m_wallet.cs_wallet);
        auto created = m_wallet.GetNewQuantumDestination("ordinary quantum key");
        BOOST_REQUIRE(created);
        owned_dest = *created;
    }
    const size_t original_key_count = WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size());
    BOOST_REQUIRE_EQUAL(original_key_count, 1U);

    bilingual_str error;
    args_guard.Unset("-qqpowpayoutaddress");
    BOOST_CHECK(!m_wallet.EnsurePowPayoutAddress(error));
    BOOST_CHECK(error.original.find("-qqpowpayoutaddress") != std::string::npos);
    BOOST_CHECK_EQUAL(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()), original_key_count);

    const std::string owned_address = EncodeDestination(owned_dest);
    args_guard.SetRepeated("-qqpowpayoutaddress", {owned_address, owned_address});
    error.clear();
    BOOST_CHECK(!m_wallet.EnsurePowPayoutAddress(error));
    BOOST_CHECK(error.original.find("ambiguous") != std::string::npos);
    BOOST_CHECK_EQUAL(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()), original_key_count);

    args_guard.Force("-qqpowpayoutaddress", "not-a-quantum-address");
    error.clear();
    BOOST_CHECK(!m_wallet.EnsurePowPayoutAddress(error));
    BOOST_CHECK(error.original.find("valid Quantum Quasar") != std::string::npos);
    BOOST_CHECK_EQUAL(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()), original_key_count);

    CWallet foreign_wallet(/*chain=*/nullptr, "foreign", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(foreign_wallet.LoadWallet(), DBErrors::LOAD_OK);
    CTxDestination foreign_dest;
    {
        LOCK(foreign_wallet.cs_wallet);
        auto created = foreign_wallet.GetNewQuantumDestination("foreign quantum key");
        BOOST_REQUIRE(created);
        foreign_dest = *created;
    }
    args_guard.Force("-qqpowpayoutaddress", EncodeDestination(foreign_dest));
    error.clear();
    BOOST_CHECK(!m_wallet.EnsurePowPayoutAddress(error));
    BOOST_CHECK(error.original.find("not backed") != std::string::npos);
    BOOST_CHECK_EQUAL(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()), original_key_count);

    CTxDestination tiered_dest;
    {
        LOCK(m_wallet.cs_wallet);
        auto created = m_wallet.GetNewTieredQuantumDestination(
            "tiered binding rejection", /*unbonding_blocks=*/9450);
        BOOST_REQUIRE(created);
        tiered_dest = *created;
    }
    const size_t tiered_key_count =
        WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size());
    BOOST_REQUIRE(tiered_key_count > original_key_count);
    const std::string tiered_address = EncodeDestination(tiered_dest);

    // A wallet-owned bonded v16 address has a valid ML-DSA key, but it is a
    // staking contract rather than a direct shadow-ledger payout/change
    // destination. Every automatic binding must reject it without creating a
    // replacement key or mutating the configured output state.
    args_guard.Force("-qqpowpayoutaddress", tiered_address);
    error.clear();
    bool created{true};
    BOOST_CHECK(!m_wallet.EnsurePowPayoutAddress(error, &created));
    BOOST_CHECK(!created);
    BOOST_CHECK(error.original.find("ordinary direct") != std::string::npos);
    BOOST_CHECK_EQUAL(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()), tiered_key_count);

    args_guard.Force("-qqpospayoutaddress", tiered_address);
    CScript payout_script;
    std::string payout_address;
    error.clear();
    created = true;
    BOOST_CHECK(!m_wallet.EnsureShadowSignalPayoutAddress(payout_script, payout_address, error, &created));
    BOOST_CHECK(!created);
    BOOST_CHECK(payout_script.empty());
    BOOST_CHECK(payout_address.empty());
    BOOST_CHECK(error.original.find("ordinary direct") != std::string::npos);
    BOOST_CHECK_EQUAL(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()), tiered_key_count);

    args_guard.Force("-qqdemurragechangeaddress", tiered_address);
    CCoinControl tiered_coin_control;
    error.clear();
    BOOST_CHECK(!m_wallet.PrepareAutomaticDemurrageChangeAddress(tiered_coin_control, error));
    BOOST_CHECK(std::holds_alternative<CNoDestination>(tiered_coin_control.destChange));
    BOOST_CHECK(error.original.find("ordinary direct") != std::string::npos);
    BOOST_CHECK_EQUAL(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()), tiered_key_count);

    // Address-book fallback must apply the same direct-address predicate as
    // explicit configuration. A wallet-owned tiered alias resolves to a real
    // key, but it is not a valid payout script and must never shadow a later
    // ordinary direct labeled address.
    args_guard.Unset("-qqpowpayoutaddress");
    args_guard.Unset("-qqpospayoutaddress");
    {
        LOCK(m_wallet.cs_wallet);
        m_wallet.m_pow_payout_quantum = tiered_address;
    }
    error.clear();
    created = true;
    BOOST_CHECK(!m_wallet.EnsurePowPayoutAddress(error, &created));
    BOOST_CHECK(!created);
    BOOST_CHECK(error.original.find("ordinary direct") != std::string::npos);
    BOOST_CHECK_EQUAL(WITH_LOCK(
        m_wallet.cs_wallet, return m_wallet.m_pow_payout_quantum),
        tiered_address);
    {
        LOCK(m_wallet.cs_wallet);
        m_wallet.m_pow_payout_quantum.clear();
    }
    BOOST_REQUIRE(m_wallet.SetAddressBook(
        tiered_dest, "PoW - Quantum Claim Address",
        AddressPurpose::RECEIVE));
    {
        LOCK(m_wallet.cs_wallet);
        m_wallet.m_pow_payout_quantum.clear();
    }
    error.clear();
    created = true;
    BOOST_CHECK(!m_wallet.EnsurePowPayoutAddress(error, &created));
    BOOST_CHECK(!created);
    BOOST_CHECK(error.original.find("no existing payout key") !=
                std::string::npos);
    BOOST_CHECK(WITH_LOCK(
        m_wallet.cs_wallet,
        return m_wallet.m_pow_payout_quantum.empty()));

    BOOST_REQUIRE(m_wallet.SetAddressBook(
        owned_dest, "PoW - Quantum Claim Address",
        AddressPurpose::RECEIVE));
    error.clear();
    created = true;
    BOOST_REQUIRE_MESSAGE(
        m_wallet.EnsurePowPayoutAddress(error, &created), error.original);
    BOOST_CHECK(!created);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.cs_wallet,
                  return m_wallet.m_pow_payout_quantum),
        owned_address);

    // Multiple valid direct labels are operator-ambiguous. Fail before
    // publishing a cached address or creating any hidden key.
    CTxDestination second_direct_dest;
    {
        LOCK(m_wallet.cs_wallet);
        auto second =
            m_wallet.GetNewQuantumDestination("second direct quantum key");
        BOOST_REQUIRE(second);
        second_direct_dest = *second;
        m_wallet.m_pow_payout_quantum.clear();
    }
    BOOST_REQUIRE(m_wallet.SetAddressBook(
        second_direct_dest, "Quantum PoW Reward Address",
        AddressPurpose::RECEIVE));
    const size_t fallback_key_count = WITH_LOCK(
        m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size());
    error.clear();
    created = true;
    BOOST_REQUIRE_MESSAGE(
        m_wallet.EnsurePowPayoutAddress(error, &created), error.original);
    BOOST_CHECK(!created);
    BOOST_CHECK_EQUAL(WITH_LOCK(
        m_wallet.cs_wallet, return m_wallet.m_pow_payout_quantum),
        owned_address);

    // Two different direct addresses carrying the same highest-priority
    // current label are ambiguous, independent of destination map ordering.
    BOOST_REQUIRE(m_wallet.SetAddressBook(
        second_direct_dest, "PoW - Quantum Claim Address",
        AddressPurpose::RECEIVE));
    {
        LOCK(m_wallet.cs_wallet);
        m_wallet.m_pow_payout_quantum.clear();
    }
    error.clear();
    created = true;
    BOOST_CHECK(!m_wallet.EnsurePowPayoutAddress(error, &created));
    BOOST_CHECK(!created);
    BOOST_CHECK(error.original.find("ambiguous") != std::string::npos);
    BOOST_CHECK(WITH_LOCK(
        m_wallet.cs_wallet,
        return m_wallet.m_pow_payout_quantum.empty()));
    BOOST_CHECK_EQUAL(WITH_LOCK(
        m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()),
        fallback_key_count);

    // Repeat the fallback proof for PoS. Invalid tiered labels are skipped,
    // one direct label is accepted, and two direct labels fail without
    // leaking a partially selected output to the caller.
    BOOST_REQUIRE(m_wallet.SetAddressBook(
        tiered_dest, "PoS - Quantum Stake Address",
        AddressPurpose::RECEIVE));
    BOOST_REQUIRE(m_wallet.SetAddressBook(
        owned_dest, "PoS - Quantum Stake Address",
        AddressPurpose::RECEIVE));
    BOOST_REQUIRE(m_wallet.SetAddressBook(
        second_direct_dest, "Quantum PoS Reward Address",
        AddressPurpose::RECEIVE));
    payout_script.clear();
    payout_address.clear();
    error.clear();
    created = true;
    BOOST_REQUIRE_MESSAGE(
        m_wallet.EnsureShadowSignalPayoutAddress(
            payout_script, payout_address, error, &created),
        error.original);
    BOOST_CHECK(!created);
    BOOST_CHECK_EQUAL(payout_address, owned_address);
    BOOST_CHECK(payout_script == GetScriptForDestination(owned_dest));

    BOOST_REQUIRE(m_wallet.SetAddressBook(
        second_direct_dest, "PoS - Quantum Stake Address",
        AddressPurpose::RECEIVE));
    payout_script.clear();
    payout_address.clear();
    error.clear();
    created = true;
    BOOST_CHECK(!m_wallet.EnsureShadowSignalPayoutAddress(
        payout_script, payout_address, error, &created));
    BOOST_CHECK(!created);
    BOOST_CHECK(error.original.find("ambiguous") != std::string::npos);
    BOOST_CHECK(payout_script.empty());
    BOOST_CHECK(payout_address.empty());
    BOOST_CHECK_EQUAL(WITH_LOCK(
        m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()),
        fallback_key_count);

    BOOST_REQUIRE(m_wallet.SetAddressBook(
        tiered_dest, "tiered binding rejection", AddressPurpose::RECEIVE));
    BOOST_REQUIRE(m_wallet.SetAddressBook(
        owned_dest, "ordinary quantum key", AddressPurpose::RECEIVE));
    BOOST_REQUIRE(m_wallet.SetAddressBook(
        second_direct_dest, "second direct quantum key",
        AddressPurpose::RECEIVE));
    args_guard.Unset("-qqpospayoutaddress");
    payout_script.clear();
    payout_address.clear();
    error.clear();
    BOOST_CHECK(!m_wallet.EnsureShadowSignalPayoutAddress(payout_script, payout_address, error));
    BOOST_CHECK(error.original.find("-qqpospayoutaddress") != std::string::npos);

    args_guard.Unset("-qqdemurragechangeaddress");
    CCoinControl coin_control;
    error.clear();
    BOOST_CHECK(m_wallet.PrepareAutomaticDemurrageChangeAddress(coin_control, error));
    BOOST_CHECK(std::holds_alternative<CNoDestination>(coin_control.destChange));
    BOOST_CHECK(!coin_control.m_allow_new_quantum_key);
    BOOST_CHECK_EQUAL(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()), fallback_key_count);

    args_guard.Force("-qqautodemurrageattest", "0");
    {
        LOCK(m_wallet.cs_wallet);
        m_wallet.m_demurrage_last_auto_attest_scan_height = 77;
    }
    m_wallet.SetStakingEnabled(true);
    BOOST_CHECK_EQUAL(MaybeAutoDemurrageAttest(m_wallet), 0);
    m_wallet.SetStakingEnabled(false);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(m_wallet.cs_wallet, return m_wallet.m_demurrage_last_auto_attest_scan_height),
        77);
    BOOST_CHECK_EQUAL(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()), fallback_key_count);

    // The source-level guard remains fail-closed even if a caller bypasses
    // startup parameter interaction and leaves auto-redelegation enabled.
    args_guard.Force("-qqautoredelegate", "1");
    BOOST_CHECK_EQUAL(MaybeAutoRedelegateQuantumColdStake(m_wallet), 0);
    BOOST_CHECK_EQUAL(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.ListQuantumKeyInfos().size()), fallback_key_count);
}

BOOST_AUTO_TEST_CASE(QuantumWalletKeyCreationIsAtomicAndDurable)
{
    std::vector<uint8_t> public_key;
    std::vector<uint8_t> generated_private_key;
    BOOST_REQUIRE(ML_DSA::KeyGen(public_key, generated_private_key));
    const CKeyingMaterial private_key(generated_private_key.begin(), generated_private_key.end());

    // A transaction that cannot begin must not change either the live wallet
    // or the database image a restarted process would load.
    {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& database = GetMockableDatabase(wallet);
        const MockableData initial_records = database.m_records;
        database.m_fail_begin = true;

        auto result = wallet.AddQuantumKey(public_key, private_key, "atomic-quantum", GetTime(), /*record_as_receive=*/true);
        BOOST_CHECK(!result);
        BOOST_CHECK(database.m_records == initial_records);
        {
            LOCK(wallet.cs_wallet);
            BOOST_CHECK(wallet.ListQuantumKeyInfos().empty());
            BOOST_CHECK(!wallet.IsWalletFlagSet(WALLET_FLAG_QUANTUM_KEYS));
        }

        CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(database));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        LOCK(reloaded.cs_wallet);
        BOOST_CHECK(reloaded.ListQuantumKeyInfos().empty());
    }

    // A receive key is one transaction containing the private key, initial
    // unverified-backup marker, wallet flags, address purpose, and label.
    // Fail each write in turn and prove neither memory nor a crash-style
    // reload can observe a partial key.
    for (size_t fail_write = 0; fail_write < 5; ++fail_write) {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& database = GetMockableDatabase(wallet);
        const MockableData initial_records = database.m_records;
        database.m_fail_write_at = fail_write;

        auto result = wallet.AddQuantumKey(public_key, private_key, "atomic-quantum", GetTime(), /*record_as_receive=*/true);
        BOOST_CHECK(!result);
        BOOST_CHECK(database.m_last_txn_durable);
        BOOST_CHECK(database.m_records == initial_records);
        {
            LOCK(wallet.cs_wallet);
            BOOST_CHECK(wallet.ListQuantumKeyInfos().empty());
            BOOST_CHECK(!wallet.IsWalletFlagSet(WALLET_FLAG_QUANTUM_KEYS));
        }

        CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(database));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        LOCK(reloaded.cs_wallet);
        BOOST_CHECK(reloaded.ListQuantumKeyInfos().empty());
    }

    // An encrypted receive key has one additional database operation: write
    // the encrypted record, erase a possible plaintext record, then write the
    // backup marker, wallet flags, purpose, and label. Exercise every one of
    // those six boundaries while the wallet is normally unlocked.
    for (size_t fail_write = 0; fail_write < 6; ++fail_write) {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        BOOST_REQUIRE(wallet.EncryptWallet("pass"));
        BOOST_REQUIRE(wallet.Unlock("pass"));

        MockableDatabase& database = GetMockableDatabase(wallet);
        const MockableData initial_records = database.m_records;
        database.m_fail_write_at = fail_write;

        auto result = wallet.AddQuantumKey(public_key, private_key, "atomic-encrypted-quantum", GetTime(), /*record_as_receive=*/true);
        BOOST_CHECK(!result);
        BOOST_CHECK(database.m_last_txn_durable);
        BOOST_CHECK(database.m_records == initial_records);
        {
            LOCK(wallet.cs_wallet);
            BOOST_CHECK(wallet.ListQuantumKeyInfos().empty());
            BOOST_CHECK(!wallet.IsWalletFlagSet(WALLET_FLAG_QUANTUM_KEYS));
        }

        CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(database));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        BOOST_REQUIRE(reloaded.Unlock("pass"));
        LOCK(reloaded.cs_wallet);
        BOOST_CHECK(reloaded.ListQuantumKeyInfos().empty());
    }

    // If a durable commit reports failure, the caller cannot know whether the
    // backend rolled it back or committed it. Keep memory unpublished and
    // block every retry until reload establishes the database's actual state.
    {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& database = GetMockableDatabase(wallet);
        const MockableData initial_records = database.m_records;
        database.m_fail_commit = true;
        auto result = wallet.AddQuantumKey(public_key, private_key, "atomic-quantum", GetTime(), /*record_as_receive=*/true);
        BOOST_CHECK(!result);
        BOOST_CHECK(database.m_last_txn_durable);
        BOOST_CHECK(database.m_records == initial_records);
        BOOST_CHECK(wallet.IsQuantumKeyDatabaseAmbiguous());
        BOOST_CHECK(wallet.IsAddressBookDatabaseAmbiguous());
        database.m_fail_commit = false;
        BOOST_CHECK(!wallet.AddQuantumKey(public_key, private_key, "must-not-retry", GetTime(), /*record_as_receive=*/true));
        BOOST_CHECK(!wallet.GetNewQuantumDestination("must-not-generate"));

        CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(database));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        BOOST_CHECK(WITH_LOCK(reloaded.cs_wallet, return reloaded.ListQuantumKeyInfos().empty()));
        BOOST_CHECK(!reloaded.IsQuantumKeyDatabaseAmbiguous());
        BOOST_CHECK(!reloaded.IsAddressBookDatabaseAmbiguous());
    }

    // A write failure whose transaction cannot be aborted is equally
    // uncertain, even when this mock happens to discard its staged records.
    {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& database = GetMockableDatabase(wallet);
        database.m_fail_write_at = 0;
        database.m_fail_abort = true;
        auto result = wallet.AddQuantumKey(public_key, private_key, "abort-ambiguous", GetTime(), /*record_as_receive=*/true);
        BOOST_CHECK(!result);
        BOOST_CHECK(wallet.IsQuantumKeyDatabaseAmbiguous());
        BOOST_CHECK(wallet.IsAddressBookDatabaseAmbiguous());
        database.m_fail_write_at.reset();
        database.m_fail_abort = false;
        BOOST_CHECK(!wallet.GetNewQuantumDestination("must-not-generate"));
        BOOST_CHECK_EQUAL(database.m_commit_calls, 0U);

        CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(database));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        BOOST_CHECK(WITH_LOCK(reloaded.cs_wallet, return reloaded.ListQuantumKeyInfos().empty()));
        BOOST_CHECK(!reloaded.IsQuantumKeyDatabaseAmbiguous());
        BOOST_CHECK(!reloaded.IsAddressBookDatabaseAmbiguous());
    }

    // Model the other valid backend outcome: all key and label records are
    // durable even though commit returned false. Live memory and observers
    // stay at the old state; reload recovers exactly that one complete key.
    {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& database = GetMockableDatabase(wallet);
        database.m_fail_commit = true;
        database.m_commit_records_on_failure = true;
        size_t notifications{0};
        auto connection = wallet.NotifyAddressBookChanged.connect(
            [&](const CTxDestination&, const std::string&, bool, AddressPurpose, ChangeType) { ++notifications; });

        auto result = wallet.AddQuantumKey(public_key, private_key, "committed-ambiguously", GetTime(), /*record_as_receive=*/true);
        BOOST_CHECK(!result);
        BOOST_CHECK_EQUAL(notifications, 0U);
        BOOST_CHECK(WITH_LOCK(wallet.cs_wallet, return wallet.ListQuantumKeyInfos().empty()));
        BOOST_CHECK(WITH_LOCK(wallet.cs_wallet, return wallet.m_address_book.empty()));
        BOOST_CHECK(wallet.IsQuantumKeyDatabaseAmbiguous());
        BOOST_CHECK(wallet.IsAddressBookDatabaseAmbiguous());
        BOOST_CHECK(!wallet.GetNewQuantumDestination("must-not-generate"));
        BOOST_CHECK_EQUAL(database.m_commit_calls, 1U);

        bilingual_str error;
        bool created{true};
        BOOST_CHECK(!wallet.EnsurePowPayoutAddress(error, &created));
        BOOST_CHECK(!created);
        BOOST_CHECK(error.original.find("uncertain database outcome") != std::string::npos);
        CScript payout_script;
        std::string payout_address;
        error.clear();
        created = true;
        BOOST_CHECK(!wallet.EnsureShadowSignalPayoutAddress(payout_script, payout_address, error, &created));
        BOOST_CHECK(!created);
        BOOST_CHECK(payout_script.empty());
        BOOST_CHECK(payout_address.empty());
        BOOST_CHECK(error.original.find("uncertain database outcome") != std::string::npos);

        const CTxDestination destination = WitnessUnknown{
            QUANTUM_MIGRATION_WITNESS_VERSION,
            QuantumMigrationProgramForPubkey(public_key)};
        CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(database));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        BOOST_CHECK_EQUAL(WITH_LOCK(reloaded.cs_wallet, return reloaded.ListQuantumKeyInfos().size()), 1U);
        BOOST_REQUIRE(WITH_LOCK(reloaded.cs_wallet, return reloaded.GetQuantumKeyInfo(destination).has_value()));
        const CAddressBookData* entry = WITH_LOCK(
            reloaded.cs_wallet, return reloaded.FindAddressBookEntry(destination));
        BOOST_REQUIRE(entry);
        BOOST_CHECK_EQUAL(entry->GetLabel(), "committed-ambiguously");
        BOOST_CHECK(entry->purpose == AddressPurpose::RECEIVE);
        BOOST_CHECK(!reloaded.IsQuantumKeyDatabaseAmbiguous());
        BOOST_CHECK(!reloaded.IsAddressBookDatabaseAmbiguous());
        connection.disconnect();
    }

    // Once the durable commit reports success, a fresh process view recovers
    // the complete key and can sign. It remains conservatively unverified
    // until backupwallet reopens and challenges a produced backup.
    {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& database = GetMockableDatabase(wallet);
        auto result = wallet.AddQuantumKey(public_key, private_key, "atomic-quantum", GetTime(), /*record_as_receive=*/true);
        BOOST_REQUIRE(result);
        const CTxDestination destination = *result;
        BOOST_CHECK(database.m_last_txn_durable);

        CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(database));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        LOCK(reloaded.cs_wallet);
        const auto info = reloaded.GetQuantumKeyInfo(destination);
        BOOST_REQUIRE(info.has_value());
        BOOST_CHECK(info->durably_stored);
        BOOST_CHECK(!info->backup_verified);
        CheckQuantumKeyChallenge(reloaded, destination);
    }
}

BOOST_AUTO_TEST_CASE(tiered_quantum_key_and_label_are_one_atomic_commit)
{
    const auto distinct_key_count = [](const CWallet& wallet) {
        std::set<std::vector<unsigned char>> public_keys;
        for (const QuantumKeyInfo& info : WITH_LOCK(
                 wallet.cs_wallet, return wallet.ListQuantumKeyInfos())) {
            public_keys.insert(info.public_key);
        }
        return public_keys.size();
    };
    for (size_t fail_write = 0; fail_write < 5; ++fail_write) {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& database = GetMockableDatabase(wallet);
        const MockableData initial_records = database.m_records;
        database.m_fail_write_at = fail_write;

        auto failed = wallet.GetNewTieredQuantumDestination("tiered-label", /*unbonding_blocks=*/9450);
        BOOST_CHECK(!failed);
        BOOST_CHECK(database.m_records == initial_records);
        BOOST_CHECK(WITH_LOCK(wallet.cs_wallet, return wallet.ListQuantumKeyInfos().empty()));
        BOOST_CHECK(WITH_LOCK(wallet.cs_wallet, return wallet.m_address_book.empty()));
        BOOST_CHECK(!wallet.IsQuantumKeyDatabaseAmbiguous());
        BOOST_CHECK(!wallet.IsAddressBookDatabaseAmbiguous());

        // Retrying after clearing the injected failure creates exactly one
        // key and one matching tiered label, not an orphan plus a replacement.
        database.m_fail_write_at.reset();
        auto retried = wallet.GetNewTieredQuantumDestination("tiered-label", /*unbonding_blocks=*/9450);
        BOOST_REQUIRE(retried);
        BOOST_CHECK_EQUAL(distinct_key_count(wallet), 1U);
        BOOST_REQUIRE(WITH_LOCK(wallet.cs_wallet, return wallet.FindAddressBookEntry(*retried) != nullptr));

        CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(database));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        BOOST_CHECK_EQUAL(distinct_key_count(reloaded), 1U);
        BOOST_REQUIRE(WITH_LOCK(reloaded.cs_wallet, return reloaded.FindAddressBookEntry(*retried) != nullptr));
        const CAddressBookData* reloaded_entry = WITH_LOCK(
            reloaded.cs_wallet, return reloaded.FindAddressBookEntry(*retried));
        BOOST_REQUIRE(reloaded_entry);
        BOOST_CHECK_EQUAL(reloaded_entry->GetLabel(), "tiered-label");
        BOOST_CHECK(reloaded_entry->purpose == AddressPurpose::RECEIVE);
    }

    CWallet commit_failure(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(commit_failure.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& commit_database = GetMockableDatabase(commit_failure);
    const MockableData initial_records = commit_database.m_records;
    commit_database.m_fail_commit = true;
    auto failed_commit = commit_failure.GetNewTieredQuantumDestination("tiered-label", /*unbonding_blocks=*/9450);
    BOOST_CHECK(!failed_commit);
    BOOST_CHECK(commit_database.m_records == initial_records);
    BOOST_CHECK(WITH_LOCK(commit_failure.cs_wallet, return commit_failure.ListQuantumKeyInfos().empty()));
    BOOST_CHECK(WITH_LOCK(commit_failure.cs_wallet, return commit_failure.m_address_book.empty()));
    BOOST_CHECK(commit_failure.IsQuantumKeyDatabaseAmbiguous());
    BOOST_CHECK(commit_failure.IsAddressBookDatabaseAmbiguous());
    commit_database.m_fail_commit = false;
    BOOST_CHECK(!commit_failure.GetNewTieredQuantumDestination("must-not-retry", /*unbonding_blocks=*/9450));
    CWallet reloaded(/*chain=*/nullptr, "", DuplicateMockDatabase(commit_database));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(WITH_LOCK(reloaded.cs_wallet, return reloaded.ListQuantumKeyInfos().empty()));
    BOOST_CHECK(WITH_LOCK(reloaded.cs_wallet, return reloaded.m_address_book.empty()));
    BOOST_CHECK(!reloaded.IsQuantumKeyDatabaseAmbiguous());
    BOOST_CHECK(!reloaded.IsAddressBookDatabaseAmbiguous());

    CWallet abort_failure(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(abort_failure.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& abort_database = GetMockableDatabase(abort_failure);
    abort_database.m_fail_write_at = 0;
    abort_database.m_fail_abort = true;
    BOOST_CHECK(!abort_failure.GetNewTieredQuantumDestination("tiered-abort", /*unbonding_blocks=*/9450));
    BOOST_CHECK(abort_failure.IsQuantumKeyDatabaseAmbiguous());
    BOOST_CHECK(abort_failure.IsAddressBookDatabaseAmbiguous());
    abort_database.m_fail_write_at.reset();
    abort_database.m_fail_abort = false;
    BOOST_CHECK(!abort_failure.GetNewTieredQuantumDestination("must-not-retry", /*unbonding_blocks=*/9450));

    CWallet applied_commit(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(applied_commit.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& applied_database = GetMockableDatabase(applied_commit);
    applied_database.m_fail_commit = true;
    applied_database.m_commit_records_on_failure = true;
    size_t notifications{0};
    auto connection = applied_commit.NotifyAddressBookChanged.connect(
        [&](const CTxDestination&, const std::string&, bool, AddressPurpose, ChangeType) { ++notifications; });
    BOOST_CHECK(!applied_commit.GetNewTieredQuantumDestination("tiered-applied", /*unbonding_blocks=*/9450));
    BOOST_CHECK_EQUAL(notifications, 0U);
    BOOST_CHECK(WITH_LOCK(applied_commit.cs_wallet, return applied_commit.ListQuantumKeyInfos().empty()));
    BOOST_CHECK(WITH_LOCK(applied_commit.cs_wallet, return applied_commit.m_address_book.empty()));
    BOOST_CHECK(applied_commit.IsQuantumKeyDatabaseAmbiguous());
    BOOST_CHECK(applied_commit.IsAddressBookDatabaseAmbiguous());
    applied_database.m_fail_commit = false;
    applied_database.m_commit_records_on_failure = false;
    BOOST_CHECK(!applied_commit.GetNewTieredQuantumDestination("must-not-retry", /*unbonding_blocks=*/9450));
    BOOST_CHECK_EQUAL(applied_database.m_commit_calls, 1U);
    bilingual_str payout_error;
    bool created{true};
    BOOST_CHECK(!applied_commit.EnsurePowPayoutAddress(payout_error, &created));
    BOOST_CHECK(!created);
    CScript payout_script;
    std::string payout_address;
    payout_error.clear();
    created = true;
    BOOST_CHECK(!applied_commit.EnsureShadowSignalPayoutAddress(
        payout_script, payout_address, payout_error, &created));
    BOOST_CHECK(!created);
    BOOST_CHECK(payout_script.empty());
    BOOST_CHECK(payout_address.empty());

    CWallet applied_reload(/*chain=*/nullptr, "", DuplicateMockDatabase(applied_database));
    BOOST_REQUIRE_EQUAL(applied_reload.LoadWallet(), DBErrors::LOAD_OK);
    const std::vector<QuantumKeyInfo> infos = WITH_LOCK(
        applied_reload.cs_wallet, return applied_reload.ListQuantumKeyInfos());
    BOOST_CHECK_EQUAL(distinct_key_count(applied_reload), 1U);
    const auto applied_info = std::find_if(
        infos.begin(), infos.end(), [&](const QuantumKeyInfo& info) {
            return WITH_LOCK(
                applied_reload.cs_wallet,
                const CAddressBookData* entry =
                    applied_reload.FindAddressBookEntry(info.destination);
                return entry && entry->GetLabel() == "tiered-applied";);
        });
    BOOST_REQUIRE(applied_info != infos.end());
    const CTxDestination applied_destination = applied_info->destination;
    const CAddressBookData* applied_entry = WITH_LOCK(
        applied_reload.cs_wallet, return applied_reload.FindAddressBookEntry(applied_destination));
    BOOST_REQUIRE(applied_entry);
    BOOST_CHECK_EQUAL(applied_entry->GetLabel(), "tiered-applied");
    BOOST_CHECK(applied_entry->purpose == AddressPurpose::RECEIVE);
    BOOST_CHECK(!applied_reload.IsQuantumKeyDatabaseAmbiguous());
    BOOST_CHECK(!applied_reload.IsAddressBookDatabaseAmbiguous());
    connection.disconnect();
}

BOOST_AUTO_TEST_CASE(quantum_cold_stake_labels_publish_only_after_durable_commit)
{
    // Seed a durable wallet-owned ML-DSA key without an address-book row. Both
    // delegation entry points below can then be exercised from the same exact
    // database prestate without generating another key.
    CWallet seed(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(seed.LoadWallet(), DBErrors::LOAD_OK);
    auto key_destination = seed.GetNewQuantumChangeDestination();
    BOOST_REQUIRE(key_destination);
    const std::optional<QuantumKeyInfo> key_info = WITH_LOCK(
        seed.cs_wallet, return seed.GetQuantumKeyInfo(*key_destination));
    BOOST_REQUIRE(key_info);
    const std::vector<unsigned char> public_key = key_info->public_key;
    const std::vector<unsigned char> key_program =
        QuantumMigrationProgramForPubkey(public_key);
    BOOST_REQUIRE_EQUAL(key_program.size(), uint256::size());
    uint256 key_hash;
    std::copy(key_program.begin(), key_program.end(), key_hash.begin());
    const MockableData seed_records = GetMockableDatabase(seed).m_records;
    BOOST_CHECK(WITH_LOCK(seed.cs_wallet, return seed.m_address_book.empty()));

    const CTxDestination direct_destination = WitnessUnknown{
        QUANTUM_COLDSTAKE_WITNESS_VERSION,
        QuantumColdStakeProgramForPubkeys(public_key, public_key)};
    const CTxDestination tiered_destination = WitnessUnknown{
        QUANTUM_COLDSTAKE_WITNESS_VERSION,
        QuantumTieredColdStakeProgramForKeyHashes(
            key_hash, key_hash, QUANTUM_TIERED_STATE_BONDED,
            /*unbonding_blocks=*/9450, /*unlock_height=*/0)};

    auto exercise = [&](const CTxDestination& expected_destination,
                        const std::string& label, auto&& add_delegation) {
        enum class FailureStage {
            BEGIN,
            DELEGATION_WRITE,
            PURPOSE_WRITE,
            NAME_WRITE,
            ABORT,
            COMMIT,
        };
        for (const FailureStage stage : {
                 FailureStage::BEGIN, FailureStage::DELEGATION_WRITE,
                 FailureStage::PURPOSE_WRITE, FailureStage::NAME_WRITE,
                 FailureStage::ABORT, FailureStage::COMMIT}) {
            CWallet wallet(
                /*chain=*/nullptr, "", CreateMockableWalletDatabase(seed_records));
            BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
            MockableDatabase& database = GetMockableDatabase(wallet);
            if (stage == FailureStage::BEGIN) database.m_fail_begin = true;
            if (stage >= FailureStage::DELEGATION_WRITE &&
                stage <= FailureStage::NAME_WRITE) {
                database.m_fail_write_at =
                    static_cast<size_t>(stage) -
                    static_cast<size_t>(FailureStage::DELEGATION_WRITE);
            }
            if (stage == FailureStage::ABORT) {
                database.m_fail_write_at = 0;
                database.m_fail_abort = true;
            }
            if (stage == FailureStage::COMMIT) database.m_fail_commit = true;
            size_t notifications{0};
            auto connection = wallet.NotifyAddressBookChanged.connect(
                [&](const CTxDestination&, const std::string&, bool,
                    AddressPurpose, ChangeType) { ++notifications; });

            BOOST_CHECK(!add_delegation(wallet));
            BOOST_CHECK_EQUAL(notifications, 0U);
            BOOST_CHECK(database.m_records == seed_records);
            BOOST_CHECK(WITH_LOCK(
                wallet.cs_wallet,
                return wallet.ListQuantumColdStakeDelegationInfos().empty()));
            BOOST_CHECK(WITH_LOCK(
                wallet.cs_wallet,
                return wallet.FindAddressBookEntry(expected_destination) ==
                       nullptr));
            const bool ambiguous = stage == FailureStage::ABORT ||
                                   stage == FailureStage::COMMIT;
            BOOST_CHECK_EQUAL(
                wallet.IsQuantumDelegationDatabaseAmbiguous(), ambiguous);
            BOOST_CHECK_EQUAL(
                wallet.IsAddressBookDatabaseAmbiguous(), ambiguous);
            if (ambiguous) {
                database.m_fail_write_at.reset();
                database.m_fail_abort = false;
                database.m_fail_commit = false;
                const size_t commit_calls = database.m_commit_calls;
                BOOST_CHECK(!add_delegation(wallet));
                BOOST_CHECK_EQUAL(database.m_commit_calls, commit_calls);
            }

            CWallet reloaded(
                /*chain=*/nullptr, "", DuplicateMockDatabase(database));
            BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
            BOOST_CHECK(WITH_LOCK(
                reloaded.cs_wallet,
                return reloaded.ListQuantumColdStakeDelegationInfos().empty()));
            BOOST_CHECK(WITH_LOCK(
                reloaded.cs_wallet,
                return reloaded.FindAddressBookEntry(expected_destination) ==
                       nullptr));
            BOOST_CHECK(
                !reloaded.IsQuantumDelegationDatabaseAmbiguous());
            BOOST_CHECK(!reloaded.IsAddressBookDatabaseAmbiguous());
            connection.disconnect();
        }

        // The database may contain the complete delegation and label even
        // when commit reports false. Do not publish or notify in the live
        // wallet, and do not permit a retry before reload.
        CWallet committed_ambiguously(
            /*chain=*/nullptr, "", CreateMockableWalletDatabase(seed_records));
        BOOST_REQUIRE_EQUAL(
            committed_ambiguously.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& ambiguous_database =
            GetMockableDatabase(committed_ambiguously);
        ambiguous_database.m_fail_commit = true;
        ambiguous_database.m_commit_records_on_failure = true;
        size_t ambiguous_notifications{0};
        auto ambiguous_connection =
            committed_ambiguously.NotifyAddressBookChanged.connect(
                [&](const CTxDestination&, const std::string&, bool,
                    AddressPurpose, ChangeType) {
                    ++ambiguous_notifications;
                });
        BOOST_CHECK(!add_delegation(committed_ambiguously));
        BOOST_CHECK_EQUAL(ambiguous_notifications, 0U);
        BOOST_CHECK(ambiguous_database.m_records != seed_records);
        BOOST_CHECK(WITH_LOCK(
            committed_ambiguously.cs_wallet,
            return committed_ambiguously
                .ListQuantumColdStakeDelegationInfos()
                .empty()));
        BOOST_CHECK(WITH_LOCK(
            committed_ambiguously.cs_wallet,
            return committed_ambiguously.FindAddressBookEntry(
                       expected_destination) == nullptr));
        BOOST_CHECK(
            committed_ambiguously
                .IsQuantumDelegationDatabaseAmbiguous());
        BOOST_CHECK(
            committed_ambiguously.IsAddressBookDatabaseAmbiguous());
        const size_t ambiguous_commit_calls =
            ambiguous_database.m_commit_calls;
        ambiguous_database.m_fail_commit = false;
        ambiguous_database.m_commit_records_on_failure = false;
        BOOST_CHECK(!add_delegation(committed_ambiguously));
        BOOST_CHECK_EQUAL(
            ambiguous_database.m_commit_calls, ambiguous_commit_calls);

        CWallet ambiguous_reload(
            /*chain=*/nullptr, "", DuplicateMockDatabase(ambiguous_database));
        BOOST_REQUIRE_EQUAL(
            ambiguous_reload.LoadWallet(), DBErrors::LOAD_OK);
        BOOST_CHECK_EQUAL(
            WITH_LOCK(
                ambiguous_reload.cs_wallet,
                return ambiguous_reload
                    .ListQuantumColdStakeDelegationInfos()
                    .size()),
            1U);
        BOOST_REQUIRE(WITH_LOCK(
            ambiguous_reload.cs_wallet,
            return ambiguous_reload
                .GetQuantumColdStakeDelegationInfo(expected_destination)
                .has_value()));
        const CAddressBookData* ambiguous_entry = WITH_LOCK(
            ambiguous_reload.cs_wallet,
            return ambiguous_reload.FindAddressBookEntry(
                expected_destination));
        BOOST_REQUIRE(ambiguous_entry);
        BOOST_CHECK_EQUAL(ambiguous_entry->GetLabel(), label);
        BOOST_CHECK(
            ambiguous_entry->purpose == AddressPurpose::RECEIVE);
        BOOST_CHECK(
            !ambiguous_reload.IsQuantumDelegationDatabaseAmbiguous());
        BOOST_CHECK(!ambiguous_reload.IsAddressBookDatabaseAmbiguous());
        ambiguous_connection.disconnect();

        CWallet successful(
            /*chain=*/nullptr, "", CreateMockableWalletDatabase(seed_records));
        BOOST_REQUIRE_EQUAL(successful.LoadWallet(), DBErrors::LOAD_OK);
        MockableDatabase& successful_database =
            GetMockableDatabase(successful);
        size_t notifications{0};
        auto connection = successful.NotifyAddressBookChanged.connect(
            [&](const CTxDestination& destination,
                const std::string& notified_label, bool is_mine,
                AddressPurpose purpose, ChangeType status) {
                BOOST_CHECK(destination == expected_destination);
                BOOST_CHECK_EQUAL(notified_label, label);
                BOOST_CHECK(is_mine);
                BOOST_CHECK(purpose == AddressPurpose::RECEIVE);
                BOOST_CHECK(status == CT_NEW);
                BOOST_CHECK_EQUAL(successful_database.m_commit_calls, 1U);
                ++notifications;
            });
        auto result = add_delegation(successful);
        BOOST_REQUIRE(result);
        BOOST_CHECK(*result == expected_destination);
        BOOST_CHECK(successful_database.m_last_txn_durable);
        BOOST_CHECK_EQUAL(successful_database.m_write_calls, 3U);
        BOOST_CHECK_EQUAL(notifications, 1U);
        BOOST_CHECK_EQUAL(WITH_LOCK(
            successful.cs_wallet,
            return successful.ListQuantumColdStakeDelegationInfos().size()),
            1U);
        const CAddressBookData* successful_entry = WITH_LOCK(
            successful.cs_wallet,
            return successful.FindAddressBookEntry(expected_destination));
        BOOST_REQUIRE(successful_entry);
        BOOST_CHECK_EQUAL(successful_entry->GetLabel(), label);
        BOOST_CHECK(successful_entry->purpose == AddressPurpose::RECEIVE);

        CWallet successful_reload(
            /*chain=*/nullptr, "", DuplicateMockDatabase(successful_database));
        BOOST_REQUIRE_EQUAL(
            successful_reload.LoadWallet(), DBErrors::LOAD_OK);
        BOOST_CHECK_EQUAL(WITH_LOCK(
            successful_reload.cs_wallet,
            return successful_reload
                .ListQuantumColdStakeDelegationInfos()
                .size()),
            1U);
        BOOST_REQUIRE(WITH_LOCK(
            successful_reload.cs_wallet,
            return successful_reload.FindAddressBookEntry(
                       expected_destination) != nullptr));
        connection.disconnect();
    };

    exercise(
        direct_destination, "direct-delegation",
        [&](CWallet& wallet) {
            return wallet.AddQuantumColdStakeDelegation(
                public_key, public_key, "direct-delegation", GetTime(),
                /*record_as_receive=*/true,
                /*unbonding_blocks=*/0, /*tiered=*/false);
        });
    exercise(
        tiered_destination, "tiered-delegation",
        [&](CWallet& wallet) {
            return wallet.AddQuantumColdStakeDelegationForKeyHashes(
                key_hash, key_hash, "tiered-delegation", GetTime(),
                /*unbonding_blocks=*/9450, /*unlock_height=*/0,
                QUANTUM_TIERED_STATE_BONDED,
                /*record_as_receive=*/true);
        });
}

BOOST_AUTO_TEST_CASE(unlabeled_quantum_delegation_ambiguity_blocks_retry_until_reload)
{
    CWallet seed(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(seed.LoadWallet(), DBErrors::LOAD_OK);
    auto key_destination = seed.GetNewQuantumChangeDestination();
    BOOST_REQUIRE(key_destination);
    const std::optional<QuantumKeyInfo> key_info = WITH_LOCK(
        seed.cs_wallet, return seed.GetQuantumKeyInfo(*key_destination));
    BOOST_REQUIRE(key_info);
    const std::vector<unsigned char> public_key = key_info->public_key;
    const MockableData seed_records = GetMockableDatabase(seed).m_records;
    const CTxDestination expected_destination = WitnessUnknown{
        QUANTUM_COLDSTAKE_WITNESS_VERSION,
        QuantumColdStakeProgramForPubkeys(public_key, public_key)};

    auto add_unlabeled = [&](CWallet& wallet) {
        return wallet.AddQuantumColdStakeDelegation(
            public_key, public_key, "ignored-label", GetTime(),
            /*record_as_receive=*/false,
            /*unbonding_blocks=*/0, /*tiered=*/false);
    };

    CWallet abort_failure(
        /*chain=*/nullptr, "", CreateMockableWalletDatabase(seed_records));
    BOOST_REQUIRE_EQUAL(abort_failure.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& abort_database = GetMockableDatabase(abort_failure);
    abort_database.m_fail_write_at = 0;
    abort_database.m_fail_abort = true;
    BOOST_CHECK(!add_unlabeled(abort_failure));
    BOOST_CHECK(
        abort_failure.IsQuantumDelegationDatabaseAmbiguous());
    BOOST_CHECK(!abort_failure.IsAddressBookDatabaseAmbiguous());
    abort_database.m_fail_write_at.reset();
    abort_database.m_fail_abort = false;
    BOOST_CHECK(!add_unlabeled(abort_failure));
    BOOST_CHECK_EQUAL(abort_database.m_commit_calls, 0U);

    CWallet committed_ambiguously(
        /*chain=*/nullptr, "", CreateMockableWalletDatabase(seed_records));
    BOOST_REQUIRE_EQUAL(
        committed_ambiguously.LoadWallet(), DBErrors::LOAD_OK);
    MockableDatabase& ambiguous_database =
        GetMockableDatabase(committed_ambiguously);
    ambiguous_database.m_fail_commit = true;
    ambiguous_database.m_commit_records_on_failure = true;
    BOOST_CHECK(!add_unlabeled(committed_ambiguously));
    BOOST_CHECK(ambiguous_database.m_records != seed_records);
    BOOST_CHECK(WITH_LOCK(
        committed_ambiguously.cs_wallet,
        return committed_ambiguously.ListQuantumColdStakeDelegationInfos()
            .empty()));
    BOOST_CHECK(WITH_LOCK(
        committed_ambiguously.cs_wallet,
        return committed_ambiguously.m_address_book.empty()));
    BOOST_CHECK(
        committed_ambiguously.IsQuantumDelegationDatabaseAmbiguous());
    BOOST_CHECK(!committed_ambiguously.IsAddressBookDatabaseAmbiguous());
    ambiguous_database.m_fail_commit = false;
    ambiguous_database.m_commit_records_on_failure = false;
    BOOST_CHECK(!add_unlabeled(committed_ambiguously));
    BOOST_CHECK_EQUAL(ambiguous_database.m_commit_calls, 1U);

    CWallet reloaded(
        /*chain=*/nullptr, "", DuplicateMockDatabase(ambiguous_database));
    BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK_EQUAL(WITH_LOCK(
        reloaded.cs_wallet,
        return reloaded.ListQuantumColdStakeDelegationInfos().size()),
        1U);
    BOOST_REQUIRE(WITH_LOCK(
        reloaded.cs_wallet,
        return reloaded
            .GetQuantumColdStakeDelegationInfo(expected_destination)
            .has_value()));
    BOOST_CHECK(WITH_LOCK(
        reloaded.cs_wallet, return reloaded.m_address_book.empty()));
    BOOST_CHECK(!reloaded.IsQuantumDelegationDatabaseAmbiguous());
    BOOST_CHECK(!reloaded.IsAddressBookDatabaseAmbiguous());
}

BOOST_AUTO_TEST_CASE(QuantumWalletEncryptionUsesCheckedDurabilityBarrier)
{
    CWallet master_write_failure_wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(master_write_failure_wallet.LoadWallet(), DBErrors::LOAD_OK);
    auto master_write_failure_destination = master_write_failure_wallet.GetNewQuantumDestination("master-write-failure");
    BOOST_REQUIRE(master_write_failure_destination);
    MockableDatabase& master_write_failure_database = GetMockableDatabase(master_write_failure_wallet);
    master_write_failure_database.m_fail_write_at = 0;
    BOOST_CHECK(!master_write_failure_wallet.EncryptWallet("pass"));
    BOOST_CHECK(master_write_failure_database.m_last_txn_durable);
    BOOST_CHECK(!master_write_failure_wallet.IsCrypted());
    {
        LOCK(master_write_failure_wallet.cs_wallet);
        const auto info = master_write_failure_wallet.GetQuantumKeyInfo(*master_write_failure_destination);
        BOOST_REQUIRE(info.has_value());
        BOOST_CHECK(!info->encrypted);
        CheckQuantumKeyChallenge(master_write_failure_wallet, *master_write_failure_destination);
    }

    CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
    auto destination = wallet.GetNewQuantumDestination("durable-encryption");
    BOOST_REQUIRE(destination);

    MockableDatabase& database = GetMockableDatabase(wallet);
    database.m_last_txn_durable = false;
    BOOST_REQUIRE(wallet.EncryptWallet("pass"));
    BOOST_CHECK(database.m_last_txn_durable);

    CWallet rewrite_failure_wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(rewrite_failure_wallet.LoadWallet(), DBErrors::LOAD_OK);
    auto rewrite_failure_destination = rewrite_failure_wallet.GetNewQuantumDestination("rewrite-failure");
    BOOST_REQUIRE(rewrite_failure_destination);
    MockableDatabase& rewrite_failure_database = GetMockableDatabase(rewrite_failure_wallet);
    rewrite_failure_database.m_last_txn_durable = false;
    rewrite_failure_database.m_fail_rewrite = true;
    BOOST_CHECK(!rewrite_failure_wallet.EncryptWallet("pass"));
    BOOST_CHECK(rewrite_failure_database.m_last_txn_durable);
    BOOST_CHECK(rewrite_failure_wallet.IsCrypted());
    BOOST_CHECK(rewrite_failure_wallet.IsLocked());
    LOCK(rewrite_failure_wallet.cs_wallet);
    const auto info = rewrite_failure_wallet.GetQuantumKeyInfo(*rewrite_failure_destination);
    BOOST_REQUIRE(info.has_value());
    BOOST_CHECK(info->encrypted);
}

BOOST_AUTO_TEST_CASE(QuantumWalletVerifiedBackupsAreCompleteAndRestorable)
{
    for (DatabaseFormat format : DATABASE_FORMATS) {
        const std::string name{strprintf("quantum-wallet-backup-%i", format)};
        const fs::path first_backup_dir = m_path_root / fs::PathFromString(strprintf("quantum-first-backup-%i", format));
        const fs::path current_backup_dir = m_path_root / fs::PathFromString(strprintf("quantum-current-backup-%i", format));
        BOOST_REQUIRE(fs::create_directory(first_backup_dir));
        BOOST_REQUIRE(fs::create_directory(current_backup_dir));

        CTxDestination first_destination;
        CTxDestination second_destination;
        CTxDestination third_destination;
        std::string wallet_filename;
        {
            auto wallet{TestLoadQuantumWallet(name, format)};
            wallet_filename = fs::PathToString(fs::PathFromString(wallet->GetDatabase().Filename()).filename());

            auto first = wallet->GetNewQuantumDestination("first-quantum");
            BOOST_REQUIRE(first);
            first_destination = *first;
            {
                LOCK(wallet->cs_wallet);
                const auto info = wallet->GetQuantumKeyInfo(first_destination);
                BOOST_REQUIRE(info.has_value());
                BOOST_CHECK(info->durably_stored);
                BOOST_CHECK(!info->backup_verified);
            }

            bilingual_str error;
            BOOST_REQUIRE_MESSAGE(wallet->BackupWallet(fs::PathToString(first_backup_dir), &error), error.original);
            {
                LOCK(wallet->cs_wallet);
                const auto info = wallet->GetQuantumKeyInfo(first_destination);
                BOOST_REQUIRE(info.has_value());
                BOOST_CHECK(info->backup_verified);
            }

            // A later non-HD key is not covered by the earlier backup. The
            // older key stays verified; the new one fails closed until the
            // next complete backup is reopened and challenged.
            auto second = wallet->GetNewQuantumDestination("second-quantum");
            BOOST_REQUIRE(second);
            second_destination = *second;
            {
                LOCK(wallet->cs_wallet);
                const auto infos = wallet->ListQuantumKeyInfos();
                BOOST_REQUIRE_EQUAL(infos.size(), 2U);
                BOOST_CHECK_EQUAL(std::count_if(infos.begin(), infos.end(), [](const QuantumKeyInfo& info) { return info.backup_verified; }), 1);
            }

            error.clear();
            BOOST_REQUIRE_MESSAGE(wallet->BackupWallet(fs::PathToString(current_backup_dir), &error), error.original);
            {
                LOCK(wallet->cs_wallet);
                const auto infos = wallet->ListQuantumKeyInfos();
                BOOST_REQUIRE_EQUAL(infos.size(), 2U);
                BOOST_CHECK(std::all_of(infos.begin(), infos.end(), [](const QuantumKeyInfo& info) {
                    return info.durably_stored && info.backup_verified;
                }));
            }

            // Every staged-copy boundary is fail-closed. In particular, no
            // injected failure may modify a pre-existing good destination;
            // only the final verified stage is ever atomically promoted.
            const fs::path current_backup_path = current_backup_dir / fs::PathFromString(wallet_filename);
            const std::array<std::string_view, 16> failpoints{{
                "before_first_copy",
                "fail_initial_file_commit",
                "fail_initial_file_close",
                "fail_initial_stage_directory_commit",
                "after_first_copy",
                "before_marker_prepare",
                "after_marker_prepare",
                "fail_marked_file_commit",
                "fail_marked_file_close",
                "fail_marked_stage_directory_commit",
                "after_marker_commit",
                "before_final_verify",
                "after_final_verify",
                "before_promote",
                "before_final_identity_revalidation",
                "fail_rename",
            }};
            for (const std::string_view injected : failpoints) {
                error.clear();
                BOOST_REQUIRE_MESSAGE(wallet->BackupWallet(fs::PathToString(current_backup_dir), &error), error.original);
                const auto [before_ok, before] = ReadBinaryFile(current_backup_path);
                BOOST_REQUIRE(before_ok);

                wallet->m_quantum_backup_failpoint = [injected](std::string_view point) { return point == injected; };
                error.clear();
                BOOST_CHECK(!wallet->BackupWallet(fs::PathToString(current_backup_dir), &error));
                wallet->m_quantum_backup_failpoint = {};
                BOOST_CHECK(!error.empty());

                const auto [after_ok, after] = ReadBinaryFile(current_backup_path);
                BOOST_REQUIRE(after_ok);
                BOOST_CHECK_EQUAL_COLLECTIONS(before.begin(), before.end(), after.begin(), after.end());
                BOOST_CHECK_EQUAL(static_cast<size_t>(std::distance(fs::directory_iterator(current_backup_dir), fs::directory_iterator{})), 1U);
            }

            // The exact bytes challenged by the final reopen must be the bytes
            // atomically promoted. Even a same-process replacement inside the
            // otherwise private staging directory is detected by the immediate
            // identity revalidation and cannot modify a known-good destination.
            const auto [identity_before_ok, identity_before] = ReadBinaryFile(current_backup_path);
            BOOST_REQUIRE(identity_before_ok);
            bool tampered_stage{false};
            wallet->m_quantum_backup_failpoint = [&](std::string_view point) {
                if (point != "before_final_identity_revalidation") return false;
                for (const auto& entry : fs::directory_iterator(current_backup_dir)) {
                    const fs::path candidate{entry.path()};
                    const std::string name = fs::PathToString(candidate.filename());
                    if (!entry.is_directory() || name.rfind(".blackcoin-wallet-backup-stage-", 0) != 0) continue;
                    tampered_stage = WriteBinaryFile(candidate / "wallet.dat", "tampered after verification");
                    break;
                }
                return false;
            };
            error.clear();
            BOOST_CHECK(!wallet->BackupWallet(fs::PathToString(current_backup_dir), &error));
            wallet->m_quantum_backup_failpoint = {};
            BOOST_REQUIRE(tampered_stage);
            BOOST_CHECK(!error.empty());
            const auto [identity_after_ok, identity_after] = ReadBinaryFile(current_backup_path);
            BOOST_REQUIRE(identity_after_ok);
            BOOST_CHECK_EQUAL_COLLECTIONS(identity_before.begin(), identity_before.end(), identity_after.begin(), identity_after.end());
            BOOST_CHECK_EQUAL(static_cast<size_t>(std::distance(fs::directory_iterator(current_backup_dir), fs::directory_iterator{})), 1U);

            auto third = wallet->GetNewQuantumDestination("source-marker-failure");
            BOOST_REQUIRE(third);
            third_destination = *third;
            {
                LOCK(wallet->cs_wallet);
                const auto info = wallet->GetQuantumKeyInfo(third_destination);
                BOOST_REQUIRE(info.has_value());
                BOOST_CHECK(!info->backup_verified);
            }

            // Once the verified stage has been atomically installed, a
            // directory-sync failure cannot safely be rolled back. Report the
            // failure without deleting the complete destination. A source
            // marker failure is also reported after the independently verified
            // destination is installed, and that destination remains usable.
            for (const std::string_view injected : {
                     std::string_view{"before_final_directory_commit"},
                     std::string_view{"before_final_stage_directory_commit"},
                     std::string_view{"before_source_marker_commit"}}) {
                error.clear();
                wallet->m_quantum_backup_failpoint = [injected](std::string_view point) { return point == injected; };
                BOOST_CHECK(!wallet->BackupWallet(fs::PathToString(current_backup_dir), &error));
                wallet->m_quantum_backup_failpoint = {};
                BOOST_CHECK(!error.empty());
                BOOST_CHECK(fs::is_regular_file(current_backup_path));
                BOOST_CHECK_EQUAL(static_cast<size_t>(std::distance(fs::directory_iterator(current_backup_dir), fs::directory_iterator{})), 1U);
                {
                    auto restored{TestLoadQuantumWalletBackup(current_backup_path)};
                    LOCK(restored->cs_wallet);
                    const auto infos = restored->ListQuantumKeyInfos();
                    BOOST_REQUIRE_EQUAL(infos.size(), 3U);
                    BOOST_CHECK(std::all_of(infos.begin(), infos.end(), [](const QuantumKeyInfo& info) {
                        return info.durably_stored && info.backup_verified;
                    }));
                }
                {
                    LOCK(wallet->cs_wallet);
                    const auto info = wallet->GetQuantumKeyInfo(third_destination);
                    BOOST_REQUIRE(info.has_value());
                    BOOST_CHECK(!info->backup_verified);
                }
            }

            // Revalidate the exact installed bytes before recording source
            // markers. A same-user process can always alter an external file
            // later, but a replacement racing the promotion itself must fail
            // closed and leave a newly added source key unverified.
            bool tampered_destination{false};
            wallet->m_quantum_backup_failpoint = [&](std::string_view point) {
                if (point != "before_installed_identity_revalidation") return false;
                tampered_destination = WriteBinaryFile(current_backup_path, "tampered during promotion");
                return false;
            };
            error.clear();
            BOOST_CHECK(!wallet->BackupWallet(fs::PathToString(current_backup_dir), &error));
            wallet->m_quantum_backup_failpoint = {};
            BOOST_REQUIRE(tampered_destination);
            BOOST_CHECK(!error.empty());
            {
                LOCK(wallet->cs_wallet);
                const auto info = wallet->GetQuantumKeyInfo(third_destination);
                BOOST_REQUIRE(info.has_value());
                BOOST_CHECK(!info->backup_verified);
            }

            error.clear();
            BOOST_REQUIRE_MESSAGE(wallet->BackupWallet(fs::PathToString(current_backup_dir), &error), error.original);
            {
                LOCK(wallet->cs_wallet);
                const auto info = wallet->GetQuantumKeyInfo(third_destination);
                BOOST_REQUIRE(info.has_value());
                BOOST_CHECK(info->backup_verified);
            }
        }

        const fs::path first_backup_path = first_backup_dir / fs::PathFromString(wallet_filename);
        const fs::path current_backup_path = current_backup_dir / fs::PathFromString(wallet_filename);
        BOOST_REQUIRE(fs::is_regular_file(first_backup_path));
        BOOST_REQUIRE(fs::is_regular_file(current_backup_path));

        {
            auto restored{TestLoadQuantumWalletBackup(first_backup_path)};
            LOCK(restored->cs_wallet);
            const auto infos = restored->ListQuantumKeyInfos();
            BOOST_REQUIRE_EQUAL(infos.size(), 1U);
            BOOST_CHECK(infos.front().durably_stored);
            BOOST_CHECK(infos.front().backup_verified);
            BOOST_CHECK(restored->GetQuantumKeyInfo(first_destination).has_value());
            BOOST_CHECK(!restored->GetQuantumKeyInfo(second_destination).has_value());
            CheckQuantumKeyChallenge(*restored, first_destination);
        }
        {
            auto restored{TestLoadQuantumWalletBackup(current_backup_path)};
            LOCK(restored->cs_wallet);
            const auto infos = restored->ListQuantumKeyInfos();
            BOOST_REQUIRE_EQUAL(infos.size(), 3U);
            BOOST_CHECK(std::all_of(infos.begin(), infos.end(), [](const QuantumKeyInfo& info) {
                return info.durably_stored && info.backup_verified;
            }));
            CheckQuantumKeyChallenge(*restored, first_destination);
            CheckQuantumKeyChallenge(*restored, second_destination);
            CheckQuantumKeyChallenge(*restored, third_destination);
        }
    }
}

BOOST_AUTO_TEST_CASE(QuantumWalletEncryptedBackupAndOldWalletCompatibility)
{
    for (DatabaseFormat format : DATABASE_FORMATS) {
        const std::string encrypted_name{strprintf("quantum-wallet-encrypted-backup-%i", format)};
        const fs::path backup_path = m_path_root / fs::PathFromString(strprintf("quantum-encrypted-backup-%i.dat", format));
        CTxDestination destination;

        {
            auto wallet{TestLoadQuantumWallet(encrypted_name, format)};
            auto created = wallet->GetNewQuantumDestination("encrypted-backup");
            BOOST_REQUIRE(created);
            destination = *created;
            BOOST_REQUIRE(wallet->EncryptWallet("pass"));
            BOOST_REQUIRE(wallet->Unlock("pass"));

            bilingual_str error;
            BOOST_REQUIRE_MESSAGE(wallet->BackupWallet(fs::PathToString(backup_path), &error), error.original);
            const auto [read_ok, known_good_backup] = ReadBinaryFile(backup_path);
            BOOST_REQUIRE(read_ok);

            BOOST_REQUIRE(wallet->Lock());
            error.clear();
            BOOST_CHECK(!wallet->BackupWallet(fs::PathToString(backup_path), &error));
            BOOST_CHECK_EQUAL(error.original, "Unlock this wallet before creating a verified quantum-key backup");
            const auto [failed_read_ok, after_failed_backup] = ReadBinaryFile(backup_path);
            BOOST_REQUIRE(failed_read_ok);
            BOOST_CHECK_EQUAL_COLLECTIONS(known_good_backup.begin(), known_good_backup.end(), after_failed_backup.begin(), after_failed_backup.end());

            BOOST_REQUIRE(wallet->Unlock("pass"));
            wallet->m_wallet_unlock_staking_only = true;
            auto blocked_creation = wallet->GetNewQuantumDestination("staking-only-must-not-create");
            BOOST_CHECK(!blocked_creation);
            error.clear();
            BOOST_REQUIRE_MESSAGE(wallet->BackupWallet(fs::PathToString(backup_path), &error), error.original);
            wallet->m_wallet_unlock_staking_only = false;
            BOOST_REQUIRE(wallet->Lock());
        }

        {
            auto restored{TestLoadQuantumWalletBackup(backup_path)};
            LOCK(restored->cs_wallet);
            const auto info = restored->GetQuantumKeyInfo(destination);
            BOOST_REQUIRE(info.has_value());
            BOOST_CHECK(info->encrypted);
            BOOST_CHECK(info->durably_stored);
            BOOST_CHECK(info->backup_verified);
            BOOST_CHECK(restored->IsLocked());
            BOOST_REQUIRE(restored->Unlock("pass"));
            CheckQuantumKeyChallenge(*restored, destination);
        }

        // A pre-v30.1.1 database has the key record but no per-key backup
        // marker. It must remain usable while loading conservatively as
        // unverified on both supported backends.
        const std::string old_name{strprintf("quantum-wallet-old-key-%i", format)};
        std::vector<uint8_t> public_key;
        std::vector<uint8_t> generated_private_key;
        BOOST_REQUIRE(ML_DSA::KeyGen(public_key, generated_private_key));
        const CKeyingMaterial private_key(generated_private_key.begin(), generated_private_key.end());
        const CTxDestination old_destination = WitnessUnknown{
            QUANTUM_MIGRATION_WITNESS_VERSION,
            QuantumMigrationProgramForPubkey(public_key)};
        {
            auto wallet{TestLoadQuantumWallet(old_name, format)};
            WalletBatch batch{wallet->GetDatabase()};
            BOOST_REQUIRE(batch.WriteQuantumKey(public_key, private_key, CKeyMetadata{GetTime()}));
        }
        {
            auto wallet{TestLoadQuantumWallet(old_name, format)};
            LOCK(wallet->cs_wallet);
            const auto info = wallet->GetQuantumKeyInfo(old_destination);
            BOOST_REQUIRE(info.has_value());
            BOOST_CHECK(info->durably_stored);
            BOOST_CHECK(!info->backup_verified);
            CheckQuantumKeyChallenge(*wallet, old_destination);
        }

        // The v30.1.0 compatibility path also applies to encrypted records.
        // Remove only the v30.1.1 per-key backup marker and prove the old key
        // still loads, unlocks, and signs while remaining conservatively
        // unverified.
        const std::string old_encrypted_name{strprintf("quantum-wallet-old-encrypted-key-%i", format)};
        CTxDestination old_encrypted_destination;
        std::vector<unsigned char> old_encrypted_program;
        {
            auto wallet{TestLoadQuantumWallet(old_encrypted_name, format)};
            auto created = wallet->GetNewQuantumDestination("old-encrypted-key");
            BOOST_REQUIRE(created);
            old_encrypted_destination = *created;
            const auto* witness = std::get_if<WitnessUnknown>(&old_encrypted_destination);
            BOOST_REQUIRE(witness);
            old_encrypted_program = witness->GetWitnessProgram();
            BOOST_REQUIRE(wallet->EncryptWallet("old-pass"));

            auto batch = wallet->GetDatabase().MakeBatch();
            BOOST_REQUIRE(batch->Erase(std::make_pair(DBKeys::QUANTUM_KEY_BACKUP_STATE, old_encrypted_program)));
        }
        {
            auto wallet{TestLoadQuantumWallet(old_encrypted_name, format)};
            LOCK(wallet->cs_wallet);
            const auto info = wallet->GetQuantumKeyInfo(old_encrypted_destination);
            BOOST_REQUIRE(info.has_value());
            BOOST_CHECK(info->encrypted);
            BOOST_CHECK(info->durably_stored);
            BOOST_CHECK(!info->backup_verified);
            BOOST_CHECK(wallet->IsLocked());
            BOOST_REQUIRE(wallet->Unlock("old-pass"));
            CheckQuantumKeyChallenge(*wallet, old_encrypted_destination);
        }
    }
}

BOOST_FIXTURE_TEST_CASE(QuantumWalletInactiveSpendFailsBeforeSigning, WalletTestingSetup)
{
    CTxDestination dest;
    {
        LOCK(m_wallet.cs_wallet);
        auto op_dest = m_wallet.GetNewQuantumDestination("quantum-inactive");
        BOOST_REQUIRE(op_dest);
        dest = *op_dest;
    }

    std::map<COutPoint, Coin> coins;
    CMutableTransaction spend = QuantumWalletSpendFixture(dest, coins);
    std::map<int, bilingual_str> input_errors;
    BOOST_CHECK(!m_wallet.SignTransaction(spend, coins, SIGHASH_ALL, input_errors));
    BOOST_REQUIRE(input_errors.count(0));
    BOOST_CHECK_EQUAL(input_errors.at(0).original, "quantum-output-premature");
    BOOST_CHECK(spend.vin[0].scriptWitness.IsNull());
}

BOOST_FIXTURE_TEST_CASE(QuantumWalletChangeKeysPersistAndStayOffReceiveBook, QuantumWalletSigningTestingSetup)
{
    for (DatabaseFormat format : DATABASE_FORMATS) {
        const std::string name{strprintf("quantum-wallet-change-keys-%i", format)};
        CTxDestination dest;
        {
            auto wallet{TestLoadQuantumWallet(name, format, m_node.chain.get())};
            {
                LOCK(wallet->cs_wallet);
                auto op_dest = wallet->GetNewQuantumChangeDestination();
                BOOST_REQUIRE(op_dest);
                dest = *op_dest;
                BOOST_CHECK(wallet->IsWalletFlagSet(WALLET_FLAG_QUANTUM_KEYS));
                BOOST_CHECK(wallet->IsMine(dest) & ISMINE_SPENDABLE);
                BOOST_CHECK(wallet->FindAddressBookEntry(dest) == nullptr);
            }
            CheckQuantumWalletSigning(*wallet, dest);
        }
        {
            auto wallet{TestLoadQuantumWallet(name, format, m_node.chain.get())};
            {
                LOCK(wallet->cs_wallet);
                BOOST_CHECK(wallet->IsWalletFlagSet(WALLET_FLAG_QUANTUM_KEYS));
                BOOST_CHECK(wallet->IsMine(dest) & ISMINE_SPENDABLE);
                BOOST_CHECK(wallet->FindAddressBookEntry(dest) == nullptr);
            }
            CheckQuantumWalletSigning(*wallet, dest);
        }
    }
}

BOOST_AUTO_TEST_CASE(TieredQuantumStakeAliasesPersistAndListAfterReload)
{
    for (DatabaseFormat format : DATABASE_FORMATS) {
        const std::string name{strprintf("quantum-tiered-aliases-%i", format)};
        CTxDestination stake_dest;
        {
            auto wallet{TestLoadQuantumWallet(name, format)};
            LOCK(wallet->cs_wallet);
            auto op_dest = wallet->GetNewTieredQuantumDestination("quantum-stake", /*unbonding_blocks=*/9450);
            BOOST_REQUIRE(op_dest);
            stake_dest = *op_dest;
            const auto info = wallet->GetQuantumKeyInfo(stake_dest);
            BOOST_REQUIRE(info.has_value());
            BOOST_CHECK(wallet->FindAddressBookEntry(stake_dest) != nullptr);
        }
        {
            auto wallet{TestLoadQuantumWallet(name, format)};
            LOCK(wallet->cs_wallet);
            BOOST_CHECK(wallet->IsMine(stake_dest) & ISMINE_SPENDABLE);
            const auto info = wallet->GetQuantumKeyInfo(stake_dest);
            BOOST_REQUIRE(info.has_value());

            const std::vector<QuantumKeyInfo> infos = wallet->ListQuantumKeyInfos();
            const auto listed = std::find_if(infos.begin(), infos.end(), [&](const QuantumKeyInfo& listed_info) {
                return listed_info.destination == stake_dest;
            });
            BOOST_REQUIRE(listed != infos.end());
            const auto* entry = wallet->FindAddressBookEntry(listed->destination);
            BOOST_REQUIRE(entry);
            BOOST_CHECK_EQUAL(entry->GetLabel(), "quantum-stake");
            QuantumStakeTierProgram tier;
            BOOST_CHECK(DecodeQuantumStakeTierProgram(QUANTUM_MIGRATION_WITNESS_VERSION, listed->witness_program, tier));
            BOOST_CHECK(tier.IsBonded());
            BOOST_CHECK_EQUAL(tier.unbonding_blocks, 9450);
        }
    }
}

BOOST_FIXTURE_TEST_CASE(QuantumWalletKeysEncryptReloadAndSign, QuantumWalletSigningTestingSetup)
{
    for (DatabaseFormat format : DATABASE_FORMATS) {
        const std::string name{strprintf("quantum-wallet-encrypted-keys-%i", format)};
        CTxDestination dest;
        {
            auto wallet{TestLoadQuantumWallet(name, format, m_node.chain.get())};
            {
                LOCK(wallet->cs_wallet);
                auto op_dest = wallet->GetNewQuantumDestination("quantum-encrypted");
                BOOST_REQUIRE(op_dest);
                dest = *op_dest;
                BOOST_CHECK(wallet->IsWalletFlagSet(WALLET_FLAG_QUANTUM_KEYS));
                BOOST_CHECK(!wallet->IsWalletFlagSet(WALLET_FLAG_BLANK_WALLET));
            }
            BOOST_CHECK(wallet->EncryptWallet("pass"));
            LOCK(wallet->cs_wallet);
            BOOST_CHECK(wallet->IsWalletFlagSet(WALLET_FLAG_QUANTUM_KEYS));
            BOOST_CHECK(wallet->IsLocked());
            BOOST_CHECK(wallet->IsMine(dest) & ISMINE_SPENDABLE);
            const auto info = wallet->GetQuantumKeyInfo(dest);
            BOOST_REQUIRE(info.has_value());
            BOOST_CHECK(info->encrypted);
        }
        {
            auto wallet{TestLoadQuantumWallet(name, format, m_node.chain.get())};
            {
                LOCK(wallet->cs_wallet);
                BOOST_CHECK(wallet->IsWalletFlagSet(WALLET_FLAG_QUANTUM_KEYS));
                BOOST_CHECK(wallet->IsLocked());
                BOOST_CHECK(wallet->IsMine(dest) & ISMINE_SPENDABLE);
                const auto info = wallet->GetQuantumKeyInfo(dest);
                BOOST_REQUIRE(info.has_value());
                BOOST_CHECK(info->encrypted);

                const auto* witness = std::get_if<WitnessUnknown>(&dest);
                BOOST_REQUIRE(witness != nullptr);
                std::vector<unsigned char> public_key;
                CKeyingMaterial private_key;
                bilingual_str error;
                BOOST_CHECK(!wallet->GetQuantumKey(witness->GetWitnessProgram(), public_key, private_key, error));
                BOOST_CHECK_EQUAL(error.original, "Wallet is locked");

                BOOST_CHECK(wallet->Unlock("pass"));
            }
            CheckQuantumWalletSigning(*wallet, dest);
            BOOST_CHECK(wallet->Lock());
        }
    }
}

// Test some watch-only LegacyScriptPubKeyMan methods by the procedure of loading (LoadWatchOnly),
// checking (HaveWatchOnly), getting (GetWatchPubKey) and removing (RemoveWatchOnly) a
// given PubKey, resp. its corresponding P2PK Script. Results of the impact on
// the address -> PubKey map is dependent on whether the PubKey is a point on the curve
static void TestWatchOnlyPubKey(LegacyScriptPubKeyMan* spk_man, const CPubKey& add_pubkey)
{
    CScript p2pk = GetScriptForRawPubKey(add_pubkey);
    CKeyID add_address = add_pubkey.GetID();
    CPubKey found_pubkey;
    LOCK(spk_man->cs_KeyStore);

    // all Scripts (i.e. also all PubKeys) are added to the general watch-only set
    BOOST_CHECK(!spk_man->HaveWatchOnly(p2pk));
    spk_man->LoadWatchOnly(p2pk);
    BOOST_CHECK(spk_man->HaveWatchOnly(p2pk));

    // only PubKeys on the curve shall be added to the watch-only address -> PubKey map
    bool is_pubkey_fully_valid = add_pubkey.IsFullyValid();
    if (is_pubkey_fully_valid) {
        BOOST_CHECK(spk_man->GetWatchPubKey(add_address, found_pubkey));
        BOOST_CHECK(found_pubkey == add_pubkey);
    } else {
        BOOST_CHECK(!spk_man->GetWatchPubKey(add_address, found_pubkey));
        BOOST_CHECK(found_pubkey == CPubKey()); // passed key is unchanged
    }

    spk_man->RemoveWatchOnly(p2pk);
    BOOST_CHECK(!spk_man->HaveWatchOnly(p2pk));

    if (is_pubkey_fully_valid) {
        BOOST_CHECK(!spk_man->GetWatchPubKey(add_address, found_pubkey));
        BOOST_CHECK(found_pubkey == add_pubkey); // passed key is unchanged
    }
}

// Cryptographically invalidate a PubKey whilst keeping length and first byte
static void PollutePubKey(CPubKey& pubkey)
{
    std::vector<unsigned char> pubkey_raw(pubkey.begin(), pubkey.end());
    std::fill(pubkey_raw.begin()+1, pubkey_raw.end(), 0);
    pubkey = CPubKey(pubkey_raw);
    assert(!pubkey.IsFullyValid());
    assert(pubkey.IsValid());
}

// Test watch-only logic for PubKeys
BOOST_AUTO_TEST_CASE(WatchOnlyPubKeys)
{
    CKey key;
    CPubKey pubkey;
    LegacyScriptPubKeyMan* spk_man = m_wallet.GetOrCreateLegacyScriptPubKeyMan();

    BOOST_CHECK(!spk_man->HaveWatchOnly());

    // uncompressed valid PubKey
    key.MakeNewKey(false);
    pubkey = key.GetPubKey();
    assert(!pubkey.IsCompressed());
    TestWatchOnlyPubKey(spk_man, pubkey);

    // uncompressed cryptographically invalid PubKey
    PollutePubKey(pubkey);
    TestWatchOnlyPubKey(spk_man, pubkey);

    // compressed valid PubKey
    key.MakeNewKey(true);
    pubkey = key.GetPubKey();
    assert(pubkey.IsCompressed());
    TestWatchOnlyPubKey(spk_man, pubkey);

    // compressed cryptographically invalid PubKey
    PollutePubKey(pubkey);
    TestWatchOnlyPubKey(spk_man, pubkey);

    // invalid empty PubKey
    pubkey = CPubKey();
    TestWatchOnlyPubKey(spk_man, pubkey);
}

class ListCoinsTestingSetup : public TestChain100Setup
{
public:
    explicit ListCoinsTestingSetup(const std::vector<const char*>& extra_args = {})
        : TestChain100Setup{ChainType::REGTEST, extra_args}
    {
        CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
        wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    }

    ~ListCoinsTestingSetup()
    {
        wallet.reset();
    }

    CWalletTx& AddTx(CRecipient recipient)
    {
        CTransactionRef tx;
        CCoinControl dummy;
        {
            constexpr int RANDOM_CHANGE_POSITION = -1;
            auto res = CreateTransaction(*wallet, {recipient}, RANDOM_CHANGE_POSITION, dummy);
            BOOST_REQUIRE_MESSAGE(res, util::ErrorString(res).original);
            tx = res->tx;
        }
        wallet->CommitTransaction(tx, {}, {});
        CMutableTransaction blocktx;
        {
            LOCK(wallet->cs_wallet);
            blocktx = CMutableTransaction(*wallet->mapWallet.at(tx->GetHash()).tx);
        }
        CreateAndProcessBlock({CMutableTransaction(blocktx)}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));

        LOCK2(Assert(m_node.chainman)->GetMutex(), wallet->cs_wallet);
        wallet->SetLastBlockProcessed(wallet->GetLastBlockHeight() + 1, m_node.chainman->ActiveChain().Tip()->GetBlockHash());
        auto it = wallet->mapWallet.find(tx->GetHash());
        BOOST_CHECK(it != wallet->mapWallet.end());
        it->second.m_state = TxStateConfirmed{m_node.chainman->ActiveChain().Tip()->GetBlockHash(), m_node.chainman->ActiveChain().Height(), /*index=*/1};
        return it->second;
    }

    std::unique_ptr<CWallet> wallet;
};

class DemurrageAttestationTestingSetup : public ListCoinsTestingSetup
{
public:
    DemurrageAttestationTestingSetup()
        : ListCoinsTestingSetup{{
              "-shadowwhitelistheight=100",
              "-shadowgoldrushstartheight=101",
              "-shadowgoldrushendheight=101",
              "-qqgoldrushendheight=101",
              "-qqmigrationendheight=102",
          }}
    {
    }
};

BOOST_FIXTURE_TEST_CASE(DemurrageAttestationBuilderPreservesReplayAnchor, DemurrageAttestationTestingSetup)
{
    CTxDestination quantum_dest;
    std::vector<unsigned char> witness_program;
    {
        LOCK(wallet->cs_wallet);
        auto op_dest = wallet->GetNewQuantumDestination("b7-attestation");
        BOOST_REQUIRE(op_dest);
        quantum_dest = *op_dest;
        const auto info = wallet->GetQuantumKeyInfo(quantum_dest);
        BOOST_REQUIRE(info.has_value());
        witness_program = info->witness_program;
    }

    DemurrageAttestationTxResult tx_result;
    bilingual_str error;
    CCoinControl coin_control;
    BOOST_CHECK(!CreateDemurrageAttestationTransaction(
        *wallet, witness_program, coin_control, /*sign=*/true, tx_result, error));
    BOOST_CHECK_EQUAL(error.original, "Demurrage is not active for the next block");

    // Height 102 is the compressed test schedule's Migration boundary. Fund
    // two ordinary quantum outputs there: one becomes the attestation target,
    // and the other is a non-decaying quantum fee input after Final Lockout
    // begins at height 103.
    CMutableTransaction funding_tx;
    {
        const CScript quantum_script = GetScriptForDestination(quantum_dest);
        CCoinControl control;
        constexpr int RANDOM_CHANGE_POSITION = -1;
        auto funding = CreateTransaction(
            *wallet,
            {
                CRecipient{quantum_script, 2 * COIN, /*subtract_fee=*/false},
                CRecipient{quantum_script, COIN, /*subtract_fee=*/false},
            },
            RANDOM_CHANGE_POSITION, control, /*sign=*/true);
        BOOST_REQUIRE_MESSAGE(funding, util::ErrorString(funding).original);
        funding_tx = CMutableTransaction(*funding->tx);
    }
    CreateAndProcessBlock({funding_tx}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    const CBlockIndex* funding_index = WITH_LOCK(
        Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain().Tip());
    BOOST_REQUIRE(funding_index);
    WalletRescanReserver reserver(*wallet);
    BOOST_REQUIRE(reserver.reserve());
    const CWallet::ScanResult scan = wallet->ScanForWalletTransactions(
        funding_index->GetBlockHash(), funding_index->nHeight,
        /*max_height=*/funding_index->nHeight, reserver,
        /*fUpdate=*/false, /*save_progress=*/false);
    BOOST_REQUIRE_EQUAL(scan.status, CWallet::ScanResult::SUCCESS);
    {
        LOCK2(Assert(m_node.chainman)->GetMutex(), wallet->cs_wallet);
        wallet->SetLastBlockProcessed(funding_index->nHeight, funding_index->GetBlockHash());
    }

    tx_result = {};
    error.clear();
    BOOST_REQUIRE_MESSAGE(CreateDemurrageAttestationTransaction(*wallet, witness_program, coin_control, /*sign=*/true, tx_result, error), error.original);
    BOOST_REQUIRE(tx_result.tx);
    BOOST_REQUIRE(!tx_result.tx->vin.empty());
    BOOST_CHECK_EQUAL(tx_result.replay_anchor.ToString(), tx_result.tx->vin.front().prevout.ToString());
    BOOST_REQUIRE_GE(tx_result.attestation_vout, 0);
    BOOST_REQUIRE_LT(static_cast<size_t>(tx_result.attestation_vout), tx_result.tx->vout.size());
    BOOST_CHECK_EQUAL(tx_result.tx->vout[tx_result.attestation_vout].nValue, 0);

    const std::vector<Consensus::DemurrageAttestation> attestations = Consensus::ExtractDemurrageAttestations(*tx_result.tx);
    BOOST_REQUIRE_EQUAL(attestations.size(), 1U);
    const Consensus::DemurrageAttestation& attestation = attestations.front();
    BOOST_CHECK_GE(attestation.height, 0);
    BOOST_CHECK_EQUAL(attestation.replay_anchor.ToString(), tx_result.replay_anchor.ToString());
    BOOST_CHECK_EQUAL(attestation.target_outpoint.ToString(), tx_result.target_outpoint.ToString());
    BOOST_CHECK_EQUAL_COLLECTIONS(attestation.pubkey.begin(), attestation.pubkey.end(), tx_result.public_key.begin(), tx_result.public_key.end());
    const uint256 message_hash = Consensus::DemurrageAttestationMessageHash(
        tx_result.replay_anchor, tx_result.target_outpoint,
        attestation.previous_height, attestation.previous_time,
        attestation.previous_coverage_start_height,
        attestation.previous_source,
        tx_result.public_key, Params().GetConsensus().nQuantumSighashChainId);
    BOOST_CHECK(ML_DSA::Verify(tx_result.public_key, message_hash.begin(), uint256::size(), attestation.signature));
}

BOOST_FIXTURE_TEST_CASE(ListCoinsTest, ListCoinsTestingSetup)
{
    std::string coinbaseAddress = coinbaseKey.GetPubKey().GetID().ToString();

    // Confirm ListCoins initially returns 1 coin grouped under coinbaseKey
    // address.
    std::map<CTxDestination, std::vector<COutput>> list;
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        list = ListCoins(*wallet);
    }
    CoinsResult initial_available = WITH_LOCK(::cs_main, return WITH_LOCK(wallet->cs_wallet, return AvailableCoins(*wallet)));
    const size_t initial_available_count = initial_available.Size();
    const CAmount initial_available_amount = initial_available.GetTotalAmount();

    BOOST_REQUIRE_EQUAL(list.size(), 1U);
    BOOST_CHECK_EQUAL(std::get<PKHash>(list.begin()->first).ToString(), coinbaseAddress);
    BOOST_CHECK_EQUAL(list.begin()->second.size(), initial_available_count);

    // Check initial balance from the fixture's mature coinbase transactions.
    BOOST_CHECK_EQUAL(initial_available_amount, WITH_LOCK(::cs_main, return WITH_LOCK(wallet->cs_wallet, return AvailableCoins(*wallet).GetTotalAmount())));

    // Add a transaction creating a change address, and confirm ListCoins still
    // returns the coin associated with the change address underneath the
    // coinbaseKey pubkey, even though the change address has a different
    // pubkey.
    AddTx(CRecipient{PubKeyDestination{{}}, 1 * COIN, /*subtract_fee=*/false});
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        list = ListCoins(*wallet);
    }
    const size_t post_tx_available_count = initial_available_count + 1;

    BOOST_REQUIRE_EQUAL(list.size(), 1U);
    BOOST_CHECK_EQUAL(std::get<PKHash>(list.begin()->first).ToString(), coinbaseAddress);
    BOOST_CHECK_EQUAL(list.begin()->second.size(), post_tx_available_count);

    // Lock both coins. Confirm number of available coins drops to 0.
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_CHECK_EQUAL(AvailableCoinsListUnspent(*wallet).Size(), post_tx_available_count);
    }
    for (const auto& group : list) {
        for (const auto& coin : group.second) {
            LOCK(wallet->cs_wallet);
            wallet->LockCoin(coin.outpoint);
        }
    }
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_CHECK_EQUAL(AvailableCoinsListUnspent(*wallet).Size(), 0U);
    }
    // Confirm ListCoins still returns same result as before, despite coins
    // being locked.
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        list = ListCoins(*wallet);
    }
    BOOST_REQUIRE_EQUAL(list.size(), 1U);
    BOOST_CHECK_EQUAL(std::get<PKHash>(list.begin()->first).ToString(), coinbaseAddress);
    BOOST_CHECK_EQUAL(list.begin()->second.size(), post_tx_available_count);
}

void TestCoinsResult(ListCoinsTest& context, OutputType out_type, CAmount amount)
{
    CTxDestination dest;
    {
        LOCK(context.wallet->cs_wallet);
        dest = *Assert(context.wallet->GetNewDestination(out_type, ""));
    }
    const CScript recipient_script = GetScriptForDestination(dest);
    CWalletTx& wtx = context.AddTx(CRecipient{dest, amount, /*fSubtractFeeFromAmount=*/true});
    LOCK2(::cs_main, context.wallet->cs_wallet);
    CoinFilterParams filter;
    filter.skip_locked = false;
    CoinsResult available_coins = AvailableCoins(*context.wallet, nullptr, std::nullopt, filter);
    bool found_recipient = false;
    for (const COutput& coin : available_coins.coins[out_type]) {
        if (coin.outpoint.hash == wtx.GetHash() && coin.txout.scriptPubKey == recipient_script) {
            found_recipient = true;
        }
    }
    BOOST_CHECK(found_recipient);
    // Lock outputs so they are not spent in follow-up transactions
    for (uint32_t i = 0; i < wtx.tx->vout.size(); i++) context.wallet->LockCoin({wtx.GetHash(), i});
}

BOOST_FIXTURE_TEST_CASE(BasicOutputTypesTest, ListCoinsTest)
{
    // The fixture's P2PK coinbase UTXOs should show up in the Other bucket.
    CoinsResult available_coins = WITH_LOCK(::cs_main, return WITH_LOCK(wallet->cs_wallet, return AvailableCoins(*wallet)));
    BOOST_CHECK_GT(available_coins.coins[OutputType::UNKNOWN].size(), 0U);

    // We will create a self transfer for each of the OutputTypes and
    // verify it is put in the correct bucket after running GetAvailablecoins
    //
    // For each OutputType, We expect 2 UTXOs in our wallet following the self transfer:
    //   1. One UTXO as the recipient
    //   2. One UTXO from the change, due to payment address matching logic

    for (const auto& out_type : OUTPUT_TYPES) {
        if (out_type == OutputType::UNKNOWN) continue;
        TestCoinsResult(*this, out_type, 1 * COIN);
    }
}

BOOST_FIXTURE_TEST_CASE(wallet_disableprivkeys, TestChain100Setup)
{
    {
        const std::shared_ptr<CWallet> wallet = std::make_shared<CWallet>(m_node.chain.get(), "", CreateMockableWalletDatabase());
        wallet->SetupLegacyScriptPubKeyMan();
        wallet->SetMinVersion(FEATURE_LATEST);
        wallet->SetWalletFlag(WALLET_FLAG_DISABLE_PRIVATE_KEYS);
        BOOST_CHECK(!wallet->TopUpKeyPool(1000));
        BOOST_CHECK(!wallet->GetNewDestination(OutputType::BECH32, ""));
    }
    {
        const std::shared_ptr<CWallet> wallet = std::make_shared<CWallet>(m_node.chain.get(), "", CreateMockableWalletDatabase());
        LOCK(wallet->cs_wallet);
        wallet->SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
        wallet->SetMinVersion(FEATURE_LATEST);
        wallet->SetWalletFlag(WALLET_FLAG_DISABLE_PRIVATE_KEYS);
        BOOST_CHECK(!wallet->GetNewDestination(OutputType::BECH32, ""));
    }
}

// Explicit calculation which is used to test the wallet constant
// We get the same virtual size due to rounding(weight/4) for both use_max_sig values
static size_t CalculateNestedKeyhashInputSize(bool use_max_sig)
{
    // Generate ephemeral valid pubkey
    CKey key;
    key.MakeNewKey(true);
    CPubKey pubkey = key.GetPubKey();

    // Generate pubkey hash
    uint160 key_hash(Hash160(pubkey));

    // Create inner-script to enter into keystore. Key hash can't be 0...
    CScript inner_script = CScript() << OP_0 << std::vector<unsigned char>(key_hash.begin(), key_hash.end());

    // Create outer P2SH script for the output
    uint160 script_id(Hash160(inner_script));
    CScript script_pubkey = CScript() << OP_HASH160 << std::vector<unsigned char>(script_id.begin(), script_id.end()) << OP_EQUAL;

    // Add inner-script to key store and key to watchonly
    FillableSigningProvider keystore;
    keystore.AddCScript(inner_script);
    keystore.AddKeyPubKey(key, pubkey);

    // Fill in dummy signatures for fee calculation.
    SignatureData sig_data;

    if (!ProduceSignature(keystore, use_max_sig ? DUMMY_MAXIMUM_SIGNATURE_CREATOR : DUMMY_SIGNATURE_CREATOR, script_pubkey, sig_data)) {
        // We're hand-feeding it correct arguments; shouldn't happen
        assert(false);
    }

    CTxIn tx_in;
    UpdateInput(tx_in, sig_data);
    return (size_t)GetVirtualTransactionInputSize(tx_in);
}

BOOST_FIXTURE_TEST_CASE(dummy_input_size_test, TestChain100Setup)
{
    BOOST_CHECK_EQUAL(CalculateNestedKeyhashInputSize(false), DUMMY_NESTED_P2WPKH_INPUT_SIZE);
    BOOST_CHECK_EQUAL(CalculateNestedKeyhashInputSize(true), DUMMY_NESTED_P2WPKH_INPUT_SIZE);
}

bool malformed_descriptor(std::ios_base::failure e)
{
    std::string s(e.what());
    return s.find("Missing checksum") != std::string::npos;
}

BOOST_FIXTURE_TEST_CASE(wallet_descriptor_test, BasicTestingSetup)
{
    std::vector<unsigned char> malformed_record;
    VectorWriter vw{0, malformed_record, 0};
    vw << std::string("notadescriptor");
    vw << uint64_t{0};
    vw << int32_t{0};
    vw << int32_t{0};
    vw << int32_t{1};

    SpanReader vr{malformed_record};
    WalletDescriptor w_desc;
    BOOST_CHECK_EXCEPTION(vr >> w_desc, std::ios_base::failure, malformed_descriptor);
}

//! Test CWallet::Create() and its behavior handling potential race
//! conditions if it's called the same time an incoming transaction shows up in
//! the mempool or a new block.
//!
//! It isn't possible to verify there aren't race condition in every case, so
//! this test just checks two specific cases and ensures that timing of
//! notifications in these cases doesn't prevent the wallet from detecting
//! transactions.
//!
//! In the first case, block and mempool transactions are created before the
//! wallet is loaded, but notifications about these transactions are delayed
//! until after it is loaded. The notifications are superfluous in this case, so
//! the test verifies the transactions are detected before they arrive.
//!
//! In the second case, block and mempool transactions are created after the
//! wallet rescan and notifications are immediately synced, to verify the wallet
//! must already have a handler in place for them, and there's no gap after
//! rescanning where new transactions in new blocks could be lost.
BOOST_FIXTURE_TEST_CASE(CreateWallet, TestChain100Setup)
{
    m_args.ForceSetArg("-unsafesqlitesync", "1");
    // Create new wallet with known key and unload it.
    WalletContext context;
    context.args = &m_args;
    context.chain = m_node.chain.get();
    auto wallet = TestLoadWallet(context);
    CKey key;
    key.MakeNewKey(true);
    AddKey(*wallet, key);
    TestUnloadWallet(std::move(wallet));


    // Add log hook to detect AddToWallet events from rescans, blockConnected,
    // and transactionAddedToMempool notifications
    int addtx_count = 0;
    DebugLogHelper addtx_counter("[default wallet] AddToWallet", [&](const std::string* s) {
        if (s) ++addtx_count;
        return false;
    });


    bool rescan_completed = false;
    DebugLogHelper rescan_check("[default wallet] Rescan completed", [&](const std::string* s) {
        if (s) rescan_completed = true;
        return false;
    });


    // Block the queue to prevent the wallet receiving blockConnected and
    // transactionAddedToMempool notifications, and create block and mempool
    // transactions paying to the wallet
    std::promise<void> promise;
    CallFunctionInValidationInterfaceQueue([&promise] {
        promise.get_future().wait();
    });
    std::string error;
    m_coinbase_txns.push_back(CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey())).vtx[0]);
    auto block_tx = TestSimpleSpend(*m_coinbase_txns[0], 0, coinbaseKey, GetScriptForRawPubKey(key.GetPubKey()));
    m_coinbase_txns.push_back(CreateAndProcessBlock({block_tx}, GetScriptForRawPubKey(coinbaseKey.GetPubKey())).vtx[0]);
    auto mempool_tx = TestSimpleSpend(*m_coinbase_txns[1], 0, coinbaseKey, GetScriptForRawPubKey(key.GetPubKey()));
    BOOST_CHECK(m_node.chain->broadcastTransaction(MakeTransactionRef(mempool_tx), DEFAULT_TRANSACTION_MAXFEE, false, error));


    // Reload wallet and make sure new transactions are detected despite events
    // being blocked
    // Loading will also ask for current mempool transactions
    wallet = TestLoadWallet(context);
    BOOST_CHECK(rescan_completed);
    // AddToWallet events for block_tx and mempool_tx (x2)
    BOOST_CHECK_EQUAL(addtx_count, 3);
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK_EQUAL(wallet->mapWallet.count(block_tx.GetHash()), 1U);
        BOOST_CHECK_EQUAL(wallet->mapWallet.count(mempool_tx.GetHash()), 1U);
    }


    // Unblock notification queue and make sure stale blockConnected and
    // transactionAddedToMempool events are processed
    promise.set_value();
    SyncWithValidationInterfaceQueue();
    // AddToWallet events for block_tx and mempool_tx events are counted a
    // second time as the notification queue is processed
    BOOST_CHECK_EQUAL(addtx_count, 5);


    TestUnloadWallet(std::move(wallet));


    // Load wallet again, this time creating new block and mempool transactions
    // paying to the wallet as the wallet finishes loading and syncing the
    // queue so the events have to be handled immediately. Releasing the wallet
    // lock during the sync is a little artificial but is needed to avoid a
    // deadlock during the sync and simulates a new block notification happening
    // as soon as possible.
    addtx_count = 0;
    auto handler = HandleLoadWallet(context, [&](std::unique_ptr<interfaces::Wallet> wallet) {
            BOOST_CHECK(rescan_completed);
            m_coinbase_txns.push_back(CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey())).vtx[0]);
            block_tx = TestSimpleSpend(*m_coinbase_txns[2], 0, coinbaseKey, GetScriptForRawPubKey(key.GetPubKey()));
            m_coinbase_txns.push_back(CreateAndProcessBlock({block_tx}, GetScriptForRawPubKey(coinbaseKey.GetPubKey())).vtx[0]);
            mempool_tx = TestSimpleSpend(*m_coinbase_txns[3], 0, coinbaseKey, GetScriptForRawPubKey(key.GetPubKey()));
            BOOST_CHECK(m_node.chain->broadcastTransaction(MakeTransactionRef(mempool_tx), DEFAULT_TRANSACTION_MAXFEE, false, error));
            SyncWithValidationInterfaceQueue();
        });
    wallet = TestLoadWallet(context);
    // Since mempool transactions are requested at the end of loading, there will
    // be 2 additional AddToWallet calls, one from the previous test, and a duplicate for mempool_tx
    BOOST_CHECK_EQUAL(addtx_count, 2 + 2);
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK_EQUAL(wallet->mapWallet.count(block_tx.GetHash()), 1U);
        BOOST_CHECK_EQUAL(wallet->mapWallet.count(mempool_tx.GetHash()), 1U);
    }


    TestUnloadWallet(std::move(wallet));
}

// Exercise the exact AttachChainUnpublished phase which requires the narrow
// ThreadSanitizer deadlock suppression. A real block notification is held in
// the validation queue while a named wallet rescans the same block. The wallet
// must remain absent from WalletContext and wallet RPC routing until both the
// rescan and queued callback finish; only then may postInitProcess start the
// configured real PoW worker.
BOOST_FIXTURE_TEST_CASE(runtime_loadwallet_attachchain_lifecycle, TestChain100Setup)
{
    ScopedArgsSettings args_guard;
    args_guard.Force("-unsafesqlitesync", "1");
    args_guard.Force("-autostartstaking", "0");
    args_guard.Force("-powmining", "0");
    args_guard.Force("-powminingthreads", "1");
    args_guard.Force("-powminingcpu", "1");
    fs::create_directories(gArgs.GetDataDirNet() / "wallets");

    WalletContext context;
    context.args = &gArgs;
    context.chain = m_node.chain.get();

    const std::string wallet_name{"attachchain-lifecycle"};
    DatabaseOptions create_options;
    ReadDatabaseArgs(gArgs, create_options);
    create_options.require_create = true;
    create_options.create_flags = WALLET_FLAG_DESCRIPTORS;
    create_options.create_passphrase = SecureString{"attachchain-passphrase"};
    DatabaseStatus status;
    bilingual_str error;
    std::vector<bilingual_str> warnings;
    std::shared_ptr<CWallet> wallet = wallet::CreateWallet(
        context, wallet_name, /*load_on_start=*/std::nullopt, create_options,
        status, error, warnings);
    BOOST_REQUIRE_MESSAGE(wallet, error.original);
    BOOST_REQUIRE(wallet->IsLocked());
    const CScript receive_script = GetScriptForDestination(
        getNewDestination(*wallet, OutputType::BECH32));

    SyncWithValidationInterfaceQueue();
    BOOST_REQUIRE(RemoveWallet(
        context, wallet, /*load_on_start=*/std::nullopt));
    UnloadWallet(std::move(wallet));
    BOOST_REQUIRE(GetWallets(context).empty());

    // Hold all validation delivery, then produce a real BlockConnected event
    // for a block which pays the unloaded wallet. AttachChainUnpublished will
    // subscribe before rescanning it, so releasing this queue later must
    // deliver a duplicate, harmless AddToWallet update before publication.
    ValidationQueueBarrier attach_queue;

    const CMutableTransaction block_tx = TestSimpleSpend(
        *m_coinbase_txns[0], 0, coinbaseKey, receive_script);
    const CMutableTransaction post_unload_tx = TestSimpleSpend(
        *m_coinbase_txns[1], 0, coinbaseKey, receive_script);
    CreateAndProcessBlock(
        {block_tx}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));

    std::atomic<bool> validation_caught_up{false};
    CallFunctionInValidationInterfaceQueue(
        [&validation_caught_up] { validation_caught_up.store(true); });

    std::promise<void> rescan_release_promise;
    std::shared_future<void> rescan_release{
        rescan_release_promise.get_future().share()};
    std::atomic<bool> rescan_released{false};
    std::promise<void> rescan_entered_promise;
    std::future<void> rescan_entered{rescan_entered_promise.get_future()};
    std::atomic<bool> rescan_entered_signaled{false};
    std::promise<void> rescan_completed_promise;
    std::future<void> rescan_completed{rescan_completed_promise.get_future()};
    std::atomic<bool> rescan_completed_signaled{false};
    std::promise<void> worker_started_promise;
    std::future<void> worker_started{worker_started_promise.get_future()};
    std::atomic<bool> worker_started_signaled{false};
    std::promise<void> worker_stopped_promise;
    std::future<void> worker_stopped{worker_stopped_promise.get_future()};
    std::atomic<bool> worker_stopped_signaled{false};
    std::atomic<int> block_add_count{0};
    std::atomic<int> post_unload_add_count{0};

    std::future<std::shared_ptr<CWallet>> load_future;
    std::atomic<bool> load_notified{false};
    std::atomic<bool> notified_after_validation{false};
    std::atomic<bool> notified_after_duplicate{false};
    std::atomic<bool> notified_before_worker{false};
    auto load_handler = HandleLoadWallet(
        context, [&](std::unique_ptr<interfaces::Wallet>) {
            notified_after_validation.store(validation_caught_up.load());
            notified_after_duplicate.store(block_add_count.load() >= 2);
            notified_before_worker.store(!worker_started_signaled.load());
            load_notified.store(true);
        });

    const auto signal_once = [](
                                 std::atomic<bool>& signaled,
                                 std::promise<void>& promise) {
        if (!signaled.exchange(true)) promise.set_value();
    };
    const std::string wallet_log_prefix{"[" + wallet_name + "] "};
    const std::string block_add_pattern{
        wallet_log_prefix + "AddToWallet " + block_tx.GetHash().ToString()};
    const std::string post_unload_add_pattern{
        wallet_log_prefix + "AddToWallet " +
        post_unload_tx.GetHash().ToString()};
    auto log_connection = LogInstance().PushBackCallback(
        [&](const std::string& line) {
            if (line.find(wallet_log_prefix + "Rescan started from block") !=
                std::string::npos) {
                signal_once(rescan_entered_signaled, rescan_entered_promise);
                rescan_release.wait();
            }
            if (line.find(wallet_log_prefix + "Rescan completed") !=
                std::string::npos) {
                signal_once(
                    rescan_completed_signaled, rescan_completed_promise);
            }
            if (line.find(block_add_pattern) != std::string::npos) {
                ++block_add_count;
            }
            if (line.find(post_unload_add_pattern) != std::string::npos) {
                ++post_unload_add_count;
            }
            if (line.find(
                    wallet_log_prefix +
                    "Gold Rush PoW worker 0 started") != std::string::npos) {
                signal_once(worker_started_signaled, worker_started_promise);
            }
            if (line.find(
                    wallet_log_prefix +
                    "Gold Rush PoW worker 0 stopped") != std::string::npos) {
                signal_once(worker_stopped_signaled, worker_stopped_promise);
            }
        });
    auto log_cleanup = interfaces::MakeCleanupHandler(
        [log_connection] { LogInstance().DeleteCallback(log_connection); });

    const auto release_rescan = [&] {
        if (!rescan_released.exchange(true)) rescan_release_promise.set_value();
    };
    // This guard is declared after the log cleanup and async future so an
    // assertion cannot strand either callback behind a held logging mutex or
    // leave the validation scheduler blocked during stack unwinding.
    auto gate_cleanup = interfaces::MakeCleanupHandler([&] {
        release_rescan();
        attach_queue.Release();
    });

    args_guard.Force("-powmining", "1");
    DatabaseOptions load_options;
    ReadDatabaseArgs(gArgs, load_options);
    load_options.require_existing = true;
    warnings.clear();
    error.clear();
    load_future = std::async(std::launch::async, [&] {
        return LoadWallet(
            context, wallet_name, /*load_on_start=*/std::nullopt,
            load_options, status, error, warnings);
    });

    // The log callback pauses inside ScanForWalletTransactions while
    // AttachChainUnpublished still owns this private wallet's cs_wallet. No
    // WalletContext lookup or default wallet RPC may route to it in this phase.
    const bool entered_rescan =
        rescan_entered.wait_for(std::chrono::seconds{5}) ==
        std::future_status::ready;
    const bool attach_still_pending =
        load_future.wait_for(std::chrono::milliseconds{50}) ==
        std::future_status::timeout;
    const bool named_wallet_unroutable =
        GetWallet(context, wallet_name) == nullptr;
    const bool no_default_wallet = GetWallets(context).empty();
    JSONRPCRequest request;
    request.context = &context;
    int rpc_error_code{0};
    try {
        (void)GetWalletForJSONRPCRequest(request);
    } catch (const UniValue& rpc_error) {
        if (rpc_error["code"].isNum()) {
            rpc_error_code = rpc_error["code"].getInt<int>();
        }
    }
    release_rescan();

    BOOST_CHECK(entered_rescan);
    BOOST_CHECK(attach_still_pending);
    BOOST_CHECK(named_wallet_unroutable);
    BOOST_CHECK(no_default_wallet);
    BOOST_CHECK_EQUAL(rpc_error_code, RPC_WALLET_NOT_FOUND);

    // AttachChainUnpublished may now finish, but the production runtime-load
    // boundary must wait for the queued BlockConnected callback before
    // NotifyWalletLoaded, AddWallet, or postInitProcess can publish or start.
    const bool completed_rescan =
        rescan_completed.wait_for(std::chrono::seconds{5}) ==
        std::future_status::ready;
    const bool catchup_still_pending =
        load_future.wait_for(std::chrono::milliseconds{50}) ==
        std::future_status::timeout;
    const bool still_unpublished =
        GetWallet(context, wallet_name) == nullptr;
    const bool not_notified_early = !load_notified.load();

    BOOST_CHECK(completed_rescan);
    BOOST_CHECK(!validation_caught_up.load());
    BOOST_CHECK(catchup_still_pending);
    BOOST_CHECK(still_unpublished);
    BOOST_CHECK(not_notified_early);

    attach_queue.Release();
    BOOST_REQUIRE(
        load_future.wait_for(std::chrono::seconds{10}) ==
        std::future_status::ready);
    wallet = load_future.get();
    BOOST_REQUIRE_MESSAGE(wallet, error.original);
    BOOST_CHECK(
        worker_started.wait_for(std::chrono::seconds{5}) ==
        std::future_status::ready);

    BOOST_CHECK(validation_caught_up.load());
    BOOST_CHECK(load_notified.load());
    BOOST_CHECK(notified_after_validation.load());
    BOOST_CHECK(notified_after_duplicate.load());
    BOOST_CHECK(notified_before_worker.load());
    BOOST_CHECK_GE(block_add_count.load(), 2);
    BOOST_CHECK(GetWallet(context, wallet_name) == wallet);
    const std::optional<int> height = context.chain->getHeight();
    BOOST_REQUIRE(height);
    const uint256 active_tip = context.chain->getBlockHash(*height);
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK_EQUAL(wallet->mapWallet.count(block_tx.GetHash()), 1U);
        BOOST_CHECK_EQUAL(wallet->GetLastBlockHash(), active_tip);
    }
    BOOST_CHECK(wallet->m_pow_mining_enabled.load());
    BOOST_CHECK(
        wallet->m_pow_state.load() ==
        interfaces::WalletPowMiningState::WALLET_LOCKED_OR_STAKING_ONLY);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(wallet->m_pow_miner_mutex,
                  return wallet->threadPowMinerGroup ? wallet->threadPowMinerGroup->size() : 0U),
        1U);

    wallet->StopPowMining();
    BOOST_CHECK(
        worker_stopped.wait_for(std::chrono::seconds{5}) ==
        std::future_status::ready);
    BOOST_CHECK(!wallet->m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(
        WITH_LOCK(wallet->m_pow_miner_mutex,
                  return wallet->threadPowMinerGroup ? wallet->threadPowMinerGroup->size() : 0U),
        0U);

    // A blocked validation queue cannot keep an unpublished or unloading
    // wallet alive. Unregister the handler while a second real BlockConnected
    // event is queued, and require synchronous unload to finish before that
    // queue is released. The later event must not call the removed wallet.
    std::future<bool> unload_future;
    ValidationQueueBarrier unload_queue;
    CreateAndProcessBlock(
        {post_unload_tx}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    std::atomic<bool> post_unload_event_processed{false};
    CallFunctionInValidationInterfaceQueue([&post_unload_event_processed] {
        post_unload_event_processed.store(true);
    });
    load_handler.reset();
    unload_future = std::async(
        std::launch::async,
        [&, unload_wallet = std::move(wallet)]() mutable {
            const bool removed = RemoveWallet(
                context, unload_wallet, /*load_on_start=*/std::nullopt);
            if (removed) UnloadWallet(std::move(unload_wallet));
            return removed;
        });
    const bool unloaded_while_queue_blocked =
        unload_future.wait_for(std::chrono::seconds{5}) ==
        std::future_status::ready;
    if (!unloaded_while_queue_blocked) unload_queue.Release();
    BOOST_REQUIRE(
        unload_future.wait_for(std::chrono::seconds{5}) ==
        std::future_status::ready);
    BOOST_CHECK(unload_future.get());
    BOOST_CHECK(unloaded_while_queue_blocked);
    BOOST_CHECK(GetWallets(context).empty());
    unload_queue.Release();
    SyncWithValidationInterfaceQueue();
    BOOST_CHECK(post_unload_event_processed.load());
    BOOST_CHECK_EQUAL(post_unload_add_count.load(), 0);

    // Startup uses the separate LoadWallets/StartWallets lifecycle. Holding
    // the validation queue while LoadWallets reopens and rescans this wallet
    // proves that the new runtime-only catch-up barrier does not widen startup
    // blocking or start post-init workers early.
    common::SettingsValue startup_wallets(common::SettingsValue::VARR);
    startup_wallets.push_back(wallet_name);
    BOOST_REQUIRE(context.chain->updateRwSetting(
        "wallet", startup_wallets, /*write=*/false));
    std::future<bool> startup_load_future;
    ValidationQueueBarrier startup_queue;
    startup_load_future = std::async(
        std::launch::async, [&] { return LoadWallets(context); });
    const bool startup_load_unblocked =
        startup_load_future.wait_for(std::chrono::seconds{5}) ==
        std::future_status::ready;
    if (!startup_load_unblocked) startup_queue.Release();
    BOOST_REQUIRE(
        startup_load_future.wait_for(std::chrono::seconds{5}) ==
        std::future_status::ready);
    BOOST_CHECK(startup_load_future.get());
    BOOST_CHECK(startup_load_unblocked);
    wallet = GetWallet(context, wallet_name);
    BOOST_REQUIRE(wallet);
    BOOST_CHECK(!wallet->m_pow_mining_enabled.load());
    BOOST_CHECK_EQUAL(post_unload_add_count.load(), 1);
    startup_queue.Release();
    SyncWithValidationInterfaceQueue();
    BOOST_REQUIRE(RemoveWallet(
        context, wallet, /*load_on_start=*/std::nullopt));
    UnloadWallet(std::move(wallet));
    common::SettingsValue no_startup_wallets(common::SettingsValue::VARR);
    BOOST_REQUIRE(context.chain->updateRwSetting(
        "wallet", no_startup_wallets, /*write=*/false));

    // Runtime creation shares the subscribe-to-publication interval even when
    // a new wallet has no historical range to rescan. Queue a real block-tip
    // notification before CreateWallet subscribes; notification delivery
    // resolves subscribers when it executes, so the new wallet receives it.
    // The explicit sentinel which follows that event must run before the load
    // callback and configured post-init worker.
    const std::string created_wallet_name{
        "attachchain-created-lifecycle"};
    std::atomic<bool> create_validation_caught_up{false};
    std::atomic<bool> create_load_notified{false};
    std::atomic<bool> create_notified_after_validation{false};
    std::atomic<bool> create_notified_before_worker{false};
    std::promise<void> create_worker_started_promise;
    std::future<void> create_worker_started{
        create_worker_started_promise.get_future()};
    std::atomic<bool> create_worker_started_signaled{false};
    std::promise<void> create_worker_stopped_promise;
    std::future<void> create_worker_stopped{
        create_worker_stopped_promise.get_future()};
    std::atomic<bool> create_worker_stopped_signaled{false};
    auto create_load_handler = HandleLoadWallet(
        context, [&](std::unique_ptr<interfaces::Wallet>) {
            create_notified_after_validation.store(
                create_validation_caught_up.load());
            create_notified_before_worker.store(
                !create_worker_started_signaled.load());
            create_load_notified.store(true);
        });
    const std::string created_log_prefix{
        "[" + created_wallet_name + "] "};
    auto create_log_connection = LogInstance().PushBackCallback(
        [&](const std::string& line) {
            if (line.find(
                    created_log_prefix +
                    "Gold Rush PoW worker 0 started") != std::string::npos) {
                signal_once(
                    create_worker_started_signaled,
                    create_worker_started_promise);
            }
            if (line.find(
                    created_log_prefix +
                    "Gold Rush PoW worker 0 stopped") != std::string::npos) {
                signal_once(
                    create_worker_stopped_signaled,
                    create_worker_stopped_promise);
            }
        });
    auto create_log_cleanup = interfaces::MakeCleanupHandler(
        [create_log_connection] {
            LogInstance().DeleteCallback(create_log_connection);
        });

    std::future<std::shared_ptr<CWallet>> create_future;
    ValidationQueueBarrier create_queue;
    CreateAndProcessBlock(
        {}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    CallFunctionInValidationInterfaceQueue(
        [&create_validation_caught_up] {
            create_validation_caught_up.store(true);
        });
    const size_t callbacks_before_create_sync =
        GetMainSignals().CallbacksPending();

    DatabaseOptions runtime_create_options;
    ReadDatabaseArgs(gArgs, runtime_create_options);
    runtime_create_options.require_create = true;
    runtime_create_options.create_flags = WALLET_FLAG_DESCRIPTORS;
    runtime_create_options.create_passphrase =
        SecureString{"attachchain-created-passphrase"};
    DatabaseStatus create_status;
    bilingual_str create_error;
    std::vector<bilingual_str> create_warnings;
    create_future = std::async(std::launch::async, [&] {
        return wallet::CreateWallet(
            context, created_wallet_name, /*load_on_start=*/std::nullopt,
            runtime_create_options, create_status, create_error,
            create_warnings);
    });

    const auto create_sync_deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds{5};
    while (GetMainSignals().CallbacksPending() <=
               callbacks_before_create_sync &&
           create_future.wait_for(std::chrono::milliseconds{0}) !=
               std::future_status::ready &&
           std::chrono::steady_clock::now() < create_sync_deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }
    const bool create_waiting_for_catchup =
        GetMainSignals().CallbacksPending() > callbacks_before_create_sync;
    const bool create_still_pending =
        create_future.wait_for(std::chrono::milliseconds{50}) ==
        std::future_status::timeout;
    BOOST_CHECK(create_waiting_for_catchup);
    BOOST_CHECK(create_still_pending);
    BOOST_CHECK(!create_validation_caught_up.load());
    BOOST_CHECK(!create_load_notified.load());
    BOOST_CHECK(!create_worker_started_signaled.load());
    BOOST_CHECK(GetWallet(context, created_wallet_name) == nullptr);

    create_queue.Release();
    BOOST_REQUIRE(
        create_future.wait_for(std::chrono::seconds{10}) ==
        std::future_status::ready);
    wallet = create_future.get();
    BOOST_REQUIRE_MESSAGE(wallet, create_error.original);
    BOOST_CHECK(
        create_worker_started.wait_for(std::chrono::seconds{5}) ==
        std::future_status::ready);
    BOOST_CHECK(create_validation_caught_up.load());
    BOOST_CHECK(create_load_notified.load());
    BOOST_CHECK(create_notified_after_validation.load());
    BOOST_CHECK(create_notified_before_worker.load());
    BOOST_CHECK(GetWallet(context, created_wallet_name) == wallet);
    BOOST_CHECK(wallet->m_pow_mining_enabled.load());

    wallet->StopPowMining();
    BOOST_CHECK(
        create_worker_stopped.wait_for(std::chrono::seconds{5}) ==
        std::future_status::ready);
    create_load_handler.reset();
    BOOST_REQUIRE(RemoveWallet(
        context, wallet, /*load_on_start=*/std::nullopt));
    UnloadWallet(std::move(wallet));
    create_log_cleanup.reset();

    gate_cleanup.reset();
    log_cleanup.reset();
}

BOOST_FIXTURE_TEST_CASE(CreateWalletWithoutChain, BasicTestingSetup)
{
    WalletContext context;
    context.args = &m_args;
    auto wallet = TestLoadWallet(context);
    BOOST_CHECK(wallet);
    UnloadWallet(std::move(wallet));
}

BOOST_FIXTURE_TEST_CASE(ZapSelectTx, TestChain100Setup)
{
    m_args.ForceSetArg("-unsafesqlitesync", "1");
    WalletContext context;
    context.args = &m_args;
    context.chain = m_node.chain.get();
    auto wallet = TestLoadWallet(context);
    CKey key;
    key.MakeNewKey(true);
    AddKey(*wallet, key);

    std::string error;
    m_coinbase_txns.push_back(CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey())).vtx[0]);
    auto block_tx = TestSimpleSpend(*m_coinbase_txns[0], 0, coinbaseKey, GetScriptForRawPubKey(key.GetPubKey()));
    CreateAndProcessBlock({block_tx}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));

    SyncWithValidationInterfaceQueue();

    {
        auto block_hash = block_tx.GetHash();
        auto prev_tx = m_coinbase_txns[0];

        LOCK(wallet->cs_wallet);
        BOOST_CHECK(wallet->HasWalletSpend(prev_tx));
        BOOST_CHECK_EQUAL(wallet->mapWallet.count(block_hash), 1u);

        std::vector<uint256> vHashIn{ block_hash }, vHashOut;
        BOOST_CHECK_EQUAL(wallet->ZapSelectTx(vHashIn, vHashOut), DBErrors::LOAD_OK);

        BOOST_CHECK(!wallet->HasWalletSpend(prev_tx));
        BOOST_CHECK_EQUAL(wallet->mapWallet.count(block_hash), 0u);
    }

    TestUnloadWallet(std::move(wallet));
}

/**
 * Checks a wallet invalid state where the inputs (prev-txs) of a new arriving transaction are not marked dirty,
 * while the transaction that spends them exist inside the in-memory wallet tx map (not stored on db due a db write failure).
 */
BOOST_FIXTURE_TEST_CASE(wallet_sync_tx_invalid_state_test, TestingSetup)
{
    CWallet wallet(m_node.chain.get(), "", CreateMockableWalletDatabase());
    {
        LOCK(wallet.cs_wallet);
        wallet.SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
        wallet.SetupDescriptorScriptPubKeyMans();
    }

    // Add tx to wallet
    const auto op_dest{*Assert(wallet.GetNewDestination(OutputType::BECH32M, ""))};

    CMutableTransaction mtx;
    mtx.vout.emplace_back(COIN, GetScriptForDestination(op_dest));
    mtx.vin.emplace_back(g_insecure_rand_ctx.rand256(), 0);
    const auto& tx_id_to_spend = wallet.AddToWallet(MakeTransactionRef(mtx), TxStateInMempool{})->GetHash();

    {
        // Cache and verify available balance for the wtx
        LOCK(wallet.cs_wallet);
        const CWalletTx* wtx_to_spend = wallet.GetWalletTx(tx_id_to_spend);
        BOOST_CHECK_EQUAL(CachedTxGetAvailableCredit(wallet, *wtx_to_spend), 1 * COIN);
    }

    // Now the good case:
    // 1) Add a transaction that spends the previously created transaction
    // 2) Verify that the available balance of this new tx and the old one is updated (prev tx is marked dirty)

    mtx.vin.clear();
    mtx.vin.emplace_back(tx_id_to_spend, 0);
    wallet.transactionAddedToMempool(MakeTransactionRef(mtx));
    const uint256& good_tx_id = mtx.GetHash();

    {
        // Verify balance update for the new tx and the old one
        LOCK(wallet.cs_wallet);
        const CWalletTx* new_wtx = wallet.GetWalletTx(good_tx_id);
        BOOST_CHECK_EQUAL(CachedTxGetAvailableCredit(wallet, *new_wtx), 1 * COIN);

        // Now the old wtx
        const CWalletTx* wtx_to_spend = wallet.GetWalletTx(tx_id_to_spend);
        BOOST_CHECK_EQUAL(CachedTxGetAvailableCredit(wallet, *wtx_to_spend), 0 * COIN);
    }

    // Now the bad case:
    // 1) Make db always fail
    // 2) Try to add a transaction that spends the previously created transaction and
    //    verify that we are not moving forward if the wallet cannot store it
    GetMockableDatabase(wallet).m_pass = false;
    mtx.vin.clear();
    mtx.vin.emplace_back(good_tx_id, 0);
    BOOST_CHECK_EXCEPTION(wallet.transactionAddedToMempool(MakeTransactionRef(mtx)),
                          std::runtime_error,
                          HasReason("DB error adding transaction to wallet, write failed"));
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
