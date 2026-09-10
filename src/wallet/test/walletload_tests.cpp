// Copyright (c) 2022 The Bitcoin Core developers
// Copyright (c) 2022 Blackcoin Core Developers
// Copyright (c) 2022 Blackcoin More Developers
// Copyright (c) 2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or https://www.opensource.org/licenses/mit-license.php.

#include <consensus/validation.h>
#include <interfaces/chain.h>
#include <test/util/logging.h>
#include <test/util/setup_common.h>
#include <validation.h>
#include <validationinterface.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

namespace wallet {

struct WalletLoadTestAccess {
    static bool Attach(const std::shared_ptr<CWallet>& wallet, interfaces::Chain& chain, bilingual_str& error)
    {
        std::vector<bilingual_str> warnings;
        return CWallet::AttachChainUnpublished(wallet, chain, /*rescan_required=*/false, error, warnings);
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
