// Copyright (c) 2022 The Bitcoin Core developers
// Copyright (c) 2022 Blackcoin Core Developers
// Copyright (c) 2022 Blackcoin More Developers
// Copyright (c) 2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or https://www.opensource.org/licenses/mit-license.php.

#include <consensus/validation.h>
#include <interfaces/chain.h>
#include <interfaces/handler.h>
#include <kernel/mempool_removal_reason.h>
#include <script/solver.h>
#include <shadow.h>
#include <test/util/logging.h>
#include <test/util/setup_common.h>
#include <validation.h>
#include <validationinterface.h>
#include <wallet/context.h>
#include <wallet/load.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

#include <atomic>
#include <future>
#include <thread>

namespace wallet {

struct WalletLoadTestAccess {
    static bool Attach(const std::shared_ptr<CWallet>& wallet, interfaces::Chain& chain, bilingual_str& error)
    {
        std::vector<bilingual_str> warnings;
        return CWallet::AttachChainUnpublished(wallet, chain, /*rescan_required=*/false, error, warnings);
    }
    static std::unique_ptr<WalletClaimMaintenance> Maintenance(
        std::function<void(CWallet&, bool, bool)> pass)
    {
        return std::unique_ptr<WalletClaimMaintenance>(new WalletClaimMaintenance(std::move(pass)));
    }
    static std::shared_ptr<WalletClaimMaintenanceSlot> Slot(CWallet& wallet)
    {
        LOCK(wallet.cs_wallet);
        return wallet.m_claim_maintenance;
    }
    static bool WaitForCancellation(WalletClaimMaintenance& maintenance,
                                   const std::shared_ptr<WalletClaimMaintenanceSlot>& slot)
    {
        return maintenance.WaitForCancellationForTesting(slot, std::chrono::seconds{5});
    }
};

BOOST_AUTO_TEST_SUITE(walletload_tests)

BOOST_FIXTURE_TEST_CASE(wallet_attach_reconciles_presubscription_disconnect, TestChain100Setup)
{
    CBlockIndex* old_tip = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Tip());
    BOOST_REQUIRE(old_tip && old_tip->pprev);
    const uint256 old_hash = old_tip->GetBlockHash();
    const int old_height = old_tip->nHeight;
    const uint256 funding_block = m_node.chain->getBlockHash(1);
    const CBlockLocator locator = m_node.chain->getTipLocator();
    const CTransactionRef funding = m_coinbase_txns.front();
    const CTransactionRef confirmed = m_coinbase_txns.back();

    CMutableTransaction conflict_tx;
    conflict_tx.vin.emplace_back(COutPoint{funding->GetHash(), 0});
    conflict_tx.vout.emplace_back(COIN, CScript{} << OP_TRUE);
    const CTransactionRef conflicted = MakeTransactionRef(conflict_tx);
    CMutableTransaction child_tx;
    child_tx.vin.emplace_back(COutPoint{conflicted->GetHash(), 0});
    child_tx.vout.emplace_back(COIN / 2, CScript{} << OP_TRUE);
    const CTransactionRef child = MakeTransactionRef(child_tx);

    CWallet seed(m_node.chain.get(), "", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(seed.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(seed.cs_wallet);
        seed.SetLastBlockProcessed(old_height, old_hash);
        BOOST_REQUIRE(seed.AddToWallet(funding, TxStateConfirmed{funding_block, 1, 0}));
        auto* record = seed.AddToWallet(confirmed, TxStateConfirmed{old_hash, old_height, 0});
        BOOST_REQUIRE(record);
        record->mapValue["comment"] = "preserve wallet history";
        BOOST_REQUIRE(WalletBatch(seed.GetDatabase()).WriteTx(*record));
        BOOST_REQUIRE(seed.AddToWallet(conflicted, TxStateConflicted{old_hash, old_height}));
        BOOST_REQUIRE(seed.AddToWallet(child, TxStateConflicted{old_hash, old_height}));
        BOOST_REQUIRE(WalletBatch(seed.GetDatabase()).WriteBestBlock(locator));
    }
    // Both loads see the old tip. Neither is subscribed when the actual
    // disconnect is processed and its notification queue is drained.
    auto loaded = std::make_shared<CWallet>(m_node.chain.get(), "", DuplicateMockDatabase(seed.GetDatabase()));
    auto failing = std::make_shared<CWallet>(m_node.chain.get(), "", DuplicateMockDatabase(seed.GetDatabase()));
    BOOST_REQUIRE_EQUAL(loaded->LoadWallet(), DBErrors::LOAD_OK);
    BOOST_REQUIRE_EQUAL(failing->LoadWallet(), DBErrors::LOAD_OK);
    BlockValidationState state;
    BOOST_REQUIRE(m_node.chainman->ActiveChainstate().InvalidateBlock(state, old_tip));
    SyncWithValidationInterfaceQueue();
    {
        LOCK(loaded->cs_wallet);
        BOOST_CHECK(loaded->mapWallet.at(confirmed->GetHash()).isConfirmed());
        BOOST_CHECK(loaded->mapWallet.at(conflicted->GetHash()).isConflicted());
        BOOST_CHECK_EQUAL(loaded->GetLiveUnspentStakeOutpoints().count(COutPoint{funding->GetHash(), 0}), 1U);
    }

    bilingual_str error;
    auto& failing_db = GetMockableDatabase(*failing);
    const MockableData original_records = failing_db.m_records;
    failing_db.m_fail_commit = true;
    BOOST_CHECK(!WalletLoadTestAccess::Attach(failing, *m_node.chain, error));
    BOOST_CHECK(!error.empty());
    BOOST_CHECK(failing_db.m_records == original_records);
    BOOST_CHECK(failing_db.m_last_txn_durable);
    {
        LOCK(failing->cs_wallet);
        BOOST_CHECK(failing->mapWallet.at(confirmed->GetHash()).isConfirmed());
        BOOST_CHECK(failing->mapWallet.at(conflicted->GetHash()).isConflicted());
    }
    failing->m_chain_notifications_handler.reset();

    error.clear();
    BOOST_REQUIRE_MESSAGE(WalletLoadTestAccess::Attach(loaded, *m_node.chain, error), error.original);
    SyncWithValidationInterfaceQueue();
    {
        LOCK(loaded->cs_wallet);
        BOOST_CHECK_EQUAL(loaded->mapWallet.size(), 4U);
        BOOST_CHECK(loaded->mapWallet.at(funding->GetHash()).isConfirmed());
        for (const auto& tx : {confirmed, conflicted, child}) {
            BOOST_CHECK(loaded->mapWallet.at(tx->GetHash()).state<TxStateInactive>());
        }
        BOOST_CHECK_EQUAL(loaded->mapWallet.at(confirmed->GetHash()).mapValue.at("comment"), "preserve wallet history");
        BOOST_CHECK_EQUAL(loaded->GetLiveUnspentStakeOutpoints().count(COutPoint{funding->GetHash(), 0}), 0U);
        BOOST_CHECK_EQUAL(loaded->GetLastBlockHash(), old_tip->pprev->GetBlockHash());
    }
    // No chain pointer: this reload cannot hide a missing durable update by
    // independently reconciling the old transaction states.
    CWallet persisted(nullptr, "", DuplicateMockDatabase(loaded->GetDatabase()));
    BOOST_REQUIRE_EQUAL(persisted.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(persisted.cs_wallet);
        for (const auto& tx : {confirmed, conflicted, child}) {
            BOOST_CHECK(persisted.mapWallet.at(tx->GetHash()).state<TxStateInactive>());
        }
        BOOST_CHECK_EQUAL(persisted.mapWallet.at(confirmed->GetHash()).mapValue.at("comment"), "preserve wallet history");
    }
    loaded->m_chain_notifications_handler.reset();
    SyncWithValidationInterfaceQueue();
}

/** The pass owns no wallet/chain locks while blocked. Release on all exits. */
struct MaintenancePassBarrier {
    std::promise<void> entered;
    std::promise<void> release;
    std::shared_future<void> released{release.get_future().share()};
    bool done{false};
    void Release()
    {
        if (!done) { done = true; release.set_value(); }
    }
    ~MaintenancePassBarrier() { Release(); }
};

BOOST_FIXTURE_TEST_CASE(claim_maintenance_coalesces_and_is_fair, TestingSetup)
{
    struct Pass { std::string wallet; bool resolve; bool relay; };
    std::vector<Pass> passes;
    std::thread::id worker_thread;
    std::atomic<bool> changed_thread{false};
    WalletContext context;
    // Declared after context: release before context joins on a failed check.
    MaintenancePassBarrier barrier;
    auto entered = barrier.entered.get_future();
    context.claim_maintenance = WalletLoadTestAccess::Maintenance(
        [&](CWallet& wallet, bool resolve, bool relay) {
            passes.push_back({wallet.GetName(), resolve, relay});
            if (passes.size() == 1) {
                worker_thread = std::this_thread::get_id();
                barrier.entered.set_value();
                barrier.released.wait();
            } else if (worker_thread != std::this_thread::get_id()) {
                changed_thread = true;
            }
        });
    auto a = std::make_shared<CWallet>(m_node.chain.get(), "a", CreateMockableWalletDatabase());
    auto b = std::make_shared<CWallet>(m_node.chain.get(), "b", CreateMockableWalletDatabase());
    auto c = std::make_shared<CWallet>(m_node.chain.get(), "c", CreateMockableWalletDatabase());
    a->RequestClaimMaintenance(/*resolve=*/true, /*relay=*/true);
    BOOST_CHECK(!WalletLoadTestAccess::Slot(*a)); // Unpublished has no inline fallback.
    for (const auto& wallet : {a, b, c}) context.claim_maintenance->Register(wallet);
    for (int i = 0; i < 100; ++i) a->RequestClaimMaintenance(false, true);
    BOOST_CHECK(passes.empty()); // Registered startup wallets still do not run early.
    context.claim_maintenance->Start();
    BOOST_CHECK(entered.wait_for(std::chrono::seconds{5}) == std::future_status::ready);
    for (int i = 0; i < 100; ++i) a->RequestClaimMaintenance(true, true);
    {
        LOCK2(::cs_main, a->cs_wallet);
        BOOST_CHECK(WalletLoadTestAccess::Slot(*a));
    }
    barrier.Release();
    context.claim_maintenance->Sync();
    BOOST_REQUIRE_EQUAL(passes.size(), 4U);
    BOOST_CHECK_EQUAL(passes[0].wallet, "a");
    BOOST_CHECK_EQUAL(passes[1].wallet, "b");
    BOOST_CHECK_EQUAL(passes[2].wallet, "c");
    BOOST_CHECK_EQUAL(passes[3].wallet, "a");
    BOOST_CHECK(!passes[0].resolve && passes[0].relay);
    BOOST_CHECK(!passes[1].resolve && !passes[1].relay);
    BOOST_CHECK(!passes[2].resolve && !passes[2].relay);
    BOOST_CHECK(passes[3].resolve && passes[3].relay);
    BOOST_CHECK(worker_thread != std::this_thread::get_id());
    BOOST_CHECK(!changed_thread.load());
    context.claim_maintenance->Unregister(*a);
    context.claim_maintenance->Register(a); // Late publication cannot resurrect it.
    BOOST_CHECK(!WalletLoadTestAccess::Slot(*a));
    a->RequestClaimMaintenance(true, true);
    context.claim_maintenance->Sync();
    BOOST_CHECK_EQUAL(passes.size(), 4U);
    auto unpublished = std::make_shared<CWallet>(m_node.chain.get(), "unpublished", CreateMockableWalletDatabase());
    context.claim_maintenance->Unregister(*unpublished);
    context.claim_maintenance->Register(unpublished);
    BOOST_CHECK(!WalletLoadTestAccess::Slot(*unpublished));
}

BOOST_FIXTURE_TEST_CASE(claim_maintenance_tip_and_removal_wake_without_mining_or_resend, TestChain100Setup)
{
    std::vector<std::pair<bool, bool>> requests;
    WalletContext context;
    context.claim_maintenance = WalletLoadTestAccess::Maintenance(
        [&](CWallet&, bool resolve, bool relay) { requests.emplace_back(resolve, relay); });
    auto wallet = std::make_shared<CWallet>(m_node.chain.get(), "events", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
    const CBlockIndex* tip = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Tip());
    BOOST_REQUIRE(tip && tip->pprev);
    {
        LOCK(wallet->cs_wallet);
        wallet->SetLastBlockProcessed(tip->nHeight, tip->GetBlockHash());
    }
    wallet->SetBroadcastTransactions(true);
    wallet->SetNextResend();
    BOOST_CHECK(!wallet->m_pow_mining_enabled.load());
    BOOST_CHECK(!wallet->ShouldResend());
    context.claim_maintenance->Register(wallet);
    context.claim_maintenance->Start();
    context.claim_maintenance->Sync();
    BOOST_REQUIRE_EQUAL(requests.size(), 1U);
    auto notifications = m_node.chain->handleNotifications(wallet);
    const auto tip_event = [&] {
        GetMainSignals().UpdatedBlockTip(tip, tip->pprev, /*fInitialDownload=*/false);
        SyncWithValidationInterfaceQueue();
        context.claim_maintenance->Sync();
    };
    tip_event();
    BOOST_CHECK_EQUAL(requests.size(), 1U); // No claim history, no tip work.

    const COutPoint anchor{m_coinbase_txns.front()->GetHash(), 0};
    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0});
    CMutableTransaction claim_tx;
    claim_tx.vin.emplace_back(anchor);
    claim_tx.vout.emplace_back(COIN, CScript{} << OP_TRUE);
    claim_tx.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    const CTransactionRef claim = MakeTransactionRef(claim_tx);
    BOOST_REQUIRE(TransactionHasShadowProof(*claim));
    BOOST_REQUIRE(wallet->AddToWallet(
        claim, TxStateConfirmed{tip->GetBlockHash(), tip->nHeight, 0},
        [](CWalletTx& wtx, bool) { wtx.fFromMe = true; return true; }));
    tip_event();
    BOOST_CHECK_EQUAL(requests.size(), 1U); // Inert lifetime proof history is excluded.

    BOOST_REQUIRE(wallet->AddToWallet(claim, TxStateInMempool{}));
    CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    SyncWithValidationInterfaceQueue();
    context.claim_maintenance->Sync();
    BOOST_REQUIRE_EQUAL(requests.size(), 2U);
    BOOST_CHECK(!requests.back().first && requests.back().second);
    BOOST_CHECK(!wallet->m_pow_mining_enabled.load());
    BOOST_CHECK(!wallet->ShouldResend());
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK(wallet->IsSpent(anchor));
    }

    GetMainSignals().TransactionRemovedFromMempool(claim, MemPoolRemovalReason::EXPIRY, 0);
    SyncWithValidationInterfaceQueue();
    context.claim_maintenance->Sync();
    BOOST_REQUIRE_EQUAL(requests.size(), 3U);
    BOOST_CHECK(!requests.back().first && requests.back().second);
    BOOST_CHECK(!wallet->ShouldResend());
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK(wallet->IsSpent(anchor));
        BOOST_CHECK(!wallet->mapWallet.at(claim->GetHash()).isAbandoned());
    }
    GetMainSignals().TransactionRemovedFromMempool(claim, MemPoolRemovalReason::BLOCK, 1);
    SyncWithValidationInterfaceQueue();
    context.claim_maintenance->Sync();
    BOOST_CHECK_EQUAL(requests.size(), 3U);

    CMutableTransaction ordinary_tx;
    ordinary_tx.vin.emplace_back(COutPoint{m_coinbase_txns.back()->GetHash(), 0});
    ordinary_tx.vout.emplace_back(COIN, CScript{} << OP_TRUE);
    const CTransactionRef ordinary = MakeTransactionRef(ordinary_tx);
    BOOST_REQUIRE(wallet->AddToWallet(ordinary, TxStateInactive{}));
    GetMainSignals().TransactionRemovedFromMempool(ordinary, MemPoolRemovalReason::EXPIRY, 2);
    SyncWithValidationInterfaceQueue();
    context.claim_maintenance->Sync();
    BOOST_CHECK_EQUAL(requests.size(), 3U); // Ordinary removal does not request claim work.
    notifications.reset();
    context.claim_maintenance->Unregister(*wallet);
}

BOOST_FIXTURE_TEST_CASE(claim_maintenance_cancel_and_shutdown_join, TestingSetup)
{
    for (const bool shutdown : {false, true}) {
        std::atomic<unsigned> a_calls{0};
        std::atomic<unsigned> b_calls{0};
        WalletContext context;
        MaintenancePassBarrier barrier;
        auto entered = barrier.entered.get_future();
        context.claim_maintenance = WalletLoadTestAccess::Maintenance(
            [&](CWallet& wallet, bool, bool) {
                if (wallet.GetName() == "a") {
                    if (++a_calls == 1) {
                        barrier.entered.set_value();
                        barrier.released.wait();
                    }
                } else {
                    ++b_calls;
                }
            });
        auto a = std::make_shared<CWallet>(m_node.chain.get(), "a", CreateMockableWalletDatabase());
        auto b = std::make_shared<CWallet>(m_node.chain.get(), "b", CreateMockableWalletDatabase());
        context.claim_maintenance->Register(a);
        context.claim_maintenance->Register(b);
        const auto a_slot = WalletLoadTestAccess::Slot(*a);
        const auto b_slot = WalletLoadTestAccess::Slot(*b);
        context.claim_maintenance->Start();
        BOOST_CHECK(entered.wait_for(std::chrono::seconds{5}) == std::future_status::ready);
        for (int i = 0; i < 100; ++i) a->RequestClaimMaintenance(true, true);
        auto stopped = std::async(std::launch::async, [&] {
            if (shutdown) context.claim_maintenance->Stop();
            else context.claim_maintenance->Unregister(*a);
        });
        BOOST_CHECK(WalletLoadTestAccess::WaitForCancellation(*context.claim_maintenance, a_slot));
        if (shutdown) {
            BOOST_CHECK(WalletLoadTestAccess::WaitForCancellation(*context.claim_maintenance, b_slot));
        }
        BOOST_CHECK(stopped.wait_for(std::chrono::milliseconds{0}) == std::future_status::timeout);
        {
            LOCK2(::cs_main, a->cs_wallet); // Drain never retains either lock.
        }
        barrier.Release();
        BOOST_CHECK(stopped.wait_for(std::chrono::seconds{5}) == std::future_status::ready);
        stopped.get();
        context.claim_maintenance->Sync();
        BOOST_CHECK_EQUAL(a_calls.load(), 1U);
        BOOST_CHECK_EQUAL(b_calls.load(), shutdown ? 0U : 1U);
        a->RequestClaimMaintenance(true, true);
        context.claim_maintenance->Sync();
        BOOST_CHECK_EQUAL(a_calls.load(), 1U);
        const std::weak_ptr<CWallet> weak_a = a;
        a.reset();
        BOOST_CHECK(weak_a.expired()); // Neither queued nor completed work owns it.
        context.claim_maintenance->Stop(); // Repeated shutdown joins are harmless.
    }
}

class DummyDescriptor final : public Descriptor {
private:
    std::string desc;
public:
    explicit DummyDescriptor(const std::string& descriptor) : desc(descriptor) {};
    ~DummyDescriptor() = default;

    std::string ToString(bool compat_format) const override { return desc; }
    std::optional<OutputType> GetOutputType() const override { return OutputType::UNKNOWN; }

    bool IsRange() const override { return false; }
    bool IsSolvable() const override { return false; }
    bool IsSingleType() const override { return true; }
    bool ToPrivateString(const SigningProvider& provider, std::string& out) const override { return false; }
    bool ToNormalizedString(const SigningProvider& provider, std::string& out, const DescriptorCache* cache = nullptr) const override { return false; }
    bool Expand(int pos, const SigningProvider& provider, std::vector<CScript>& output_scripts, FlatSigningProvider& out, DescriptorCache* write_cache = nullptr) const override { return false; };
    bool ExpandFromCache(int pos, const DescriptorCache& read_cache, std::vector<CScript>& output_scripts, FlatSigningProvider& out) const override { return false; }
    void ExpandPrivate(int pos, const SigningProvider& provider, FlatSigningProvider& out) const override {}
    std::optional<int64_t> ScriptSize() const override { return {}; }
    std::optional<int64_t> MaxSatisfactionWeight(bool) const override { return {}; }
    std::optional<int64_t> MaxSatisfactionElems() const override { return {}; }
};

BOOST_FIXTURE_TEST_CASE(wallet_load_descriptors, TestingSetup)
{
    std::unique_ptr<WalletDatabase> database = CreateMockableWalletDatabase();
    {
        // Write unknown active descriptor
        WalletBatch batch(*database, false);
        std::string unknown_desc = "trx(tpubD6NzVbkrYhZ4Y4S7m6Y5s9GD8FqEMBy56AGphZXuagajudVZEnYyBahZMgHNCTJc2at82YX6s8JiL1Lohu5A3v1Ur76qguNH4QVQ7qYrBQx/86'/1'/0'/0/*)#8pn8tzdt";
        WalletDescriptor wallet_descriptor(std::make_shared<DummyDescriptor>(unknown_desc), 0, 0, 0, 0);
        BOOST_CHECK(batch.WriteDescriptor(uint256(), wallet_descriptor));
        BOOST_CHECK(batch.WriteActiveScriptPubKeyMan(static_cast<uint8_t>(OutputType::UNKNOWN), uint256(), false));
    }

    {
        // Now try to load the wallet and verify the error.
        const std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", std::move(database)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::UNKNOWN_DESCRIPTOR);
    }

    // Test 2
    // Now write a valid descriptor with an invalid ID.
    // As the software produces another ID for the descriptor, the loading process must be aborted.
    database = CreateMockableWalletDatabase();

    // Verify the error
    bool found = false;
    DebugLogHelper logHelper("The descriptor ID calculated by the wallet differs from the one in DB", [&](const std::string* s) {
        found = true;
        return false;
    });

    {
        // Write valid descriptor with invalid ID
        WalletBatch batch(*database, false);
        std::string desc = "wpkh([d34db33f/84h/0h/0h]xpub6DJ2dNUysrn5Vt36jH2KLBT2i1auw1tTSSomg8PhqNiUtx8QX2SvC9nrHu81fT41fvDUnhMjEzQgXnQjKEu3oaqMSzhSrHMxyyoEAmUHQbY/0/*)#cjjspncu";
        WalletDescriptor wallet_descriptor(std::make_shared<DummyDescriptor>(desc), 0, 0, 0, 0);
        BOOST_CHECK(batch.WriteDescriptor(uint256::ONE, wallet_descriptor));
    }

    {
        // Now try to load the wallet and verify the error.
        const std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", std::move(database)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::CORRUPT);
        BOOST_CHECK(found); // The error must be logged
    }
}

bool HasAnyRecordOfType(WalletDatabase& db, const std::string& key)
{
    std::unique_ptr<DatabaseBatch> batch = db.MakeBatch(false);
    BOOST_CHECK(batch);
    std::unique_ptr<DatabaseCursor> cursor = batch->GetNewCursor();
    BOOST_CHECK(cursor);
    while (true) {
        DataStream ssKey{};
        DataStream ssValue{};
        DatabaseCursor::Status status = cursor->Next(ssKey, ssValue);
        assert(status != DatabaseCursor::Status::FAIL);
        if (status == DatabaseCursor::Status::DONE) break;
        std::string type;
        ssKey >> type;
        if (type == key) return true;
    }
    return false;
}

template<typename... Args>
SerializeData MakeSerializeData(const Args&... args)
{
    CDataStream s(0);
    SerializeMany(s, args...);
    return {s.begin(), s.end()};
}


BOOST_FIXTURE_TEST_CASE(wallet_load_ckey, TestingSetup)
{
    SerializeData ckey_record_key;
    SerializeData ckey_record_value;
    MockableData records;

    {
        // Context setup.
        // Create and encrypt legacy wallet
        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", CreateMockableWalletDatabase()));
        LOCK(wallet->cs_wallet);
        auto legacy_spkm = wallet->GetOrCreateLegacyScriptPubKeyMan();
        BOOST_CHECK(legacy_spkm->SetupGeneration(true));

        // Retrieve a key
        CTxDestination dest = *Assert(legacy_spkm->GetNewDestination(OutputType::LEGACY));
        CKeyID key_id = GetKeyForDestination(*legacy_spkm, dest);
        CKey first_key;
        BOOST_CHECK(legacy_spkm->GetKey(key_id, first_key));

        // Encrypt the wallet
        BOOST_CHECK(wallet->EncryptWallet("encrypt"));
        wallet->Flush();

        // Store a copy of all the records
        records = GetMockableDatabase(*wallet).m_records;

        // Get the record for the retrieved key
        ckey_record_key = MakeSerializeData(DBKeys::CRYPTED_KEY, first_key.GetPubKey());
        ckey_record_value = records.at(ckey_record_key);
    }

    {
        // First test case:
        // Erase all the crypted keys from db and unlock the wallet.
        // The wallet will only re-write the crypted keys to db if any checksum is missing at load time.
        // So, if any 'ckey' record re-appears on db, then the checksums were not properly calculated, and we are re-writing
        // the records every time that 'CWallet::Unlock' gets called, which is not good.

        // Load the wallet and check that is encrypted
        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", CreateMockableWalletDatabase(records)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
        BOOST_CHECK(wallet->IsCrypted());
        BOOST_CHECK(HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_KEY));

        // Now delete all records and check that the 'Unlock' function doesn't re-write them
        BOOST_CHECK(wallet->GetLegacyScriptPubKeyMan()->DeleteRecords());
        BOOST_CHECK(!HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_KEY));
        BOOST_CHECK(wallet->Unlock("encrypt"));
        BOOST_CHECK(!HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_KEY));
    }

    {
        // Second test case:
        // Verify that loading up a 'ckey' with no checksum triggers a complete re-write of the crypted keys.

        // Cut off the 32 byte checksum from a ckey record
        records[ckey_record_key].resize(ckey_record_value.size() - 32);

        // Load the wallet and check that is encrypted
        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", CreateMockableWalletDatabase(records)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
        BOOST_CHECK(wallet->IsCrypted());
        BOOST_CHECK(HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_KEY));

        // Now delete all ckey records and check that the 'Unlock' function re-writes them
        // (this is because the wallet, at load time, found a ckey record with no checksum)
        BOOST_CHECK(wallet->GetLegacyScriptPubKeyMan()->DeleteRecords());
        BOOST_CHECK(!HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_KEY));
        BOOST_CHECK(wallet->Unlock("encrypt"));
        BOOST_CHECK(HasAnyRecordOfType(wallet->GetDatabase(), DBKeys::CRYPTED_KEY));
    }

    {
        // Third test case:
        // Verify that loading up a 'ckey' with an invalid checksum throws an error.

        // Cut off the 32 byte checksum from a ckey record
        records[ckey_record_key].resize(ckey_record_value.size() - 32);
        // Fill in the checksum space with 0s
        records[ckey_record_key].resize(ckey_record_value.size());

        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", CreateMockableWalletDatabase(records)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::CORRUPT);
    }

    {
        // Fourth test case:
        // Verify that loading up a 'ckey' with an invalid pubkey throws an error
        CPubKey invalid_key;
        BOOST_CHECK(!invalid_key.IsValid());
        SerializeData key = MakeSerializeData(DBKeys::CRYPTED_KEY, invalid_key);
        records[key] = ckey_record_value;

        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", CreateMockableWalletDatabase(records)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::CORRUPT);
    }
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
