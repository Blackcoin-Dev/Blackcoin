// Copyright (c) 2012-2021 The Bitcoin Core developers
// Copyright (c) 2012-2021 Blackcoin Core Developers
// Copyright (c) 2012-2021 Blackcoin More Developers
// Copyright (c) 2012-2021 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <test/util/setup_common.h>
#include <chainparams.h>
#include <clientversion.h>
#include <streams.h>
#include <uint256.h>
#include <wallet/shadow_pow_claim_recovery.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>
#include <wallet/walletdb.h>

#include <array>
#include <boost/test/unit_test.hpp>
#include <limits>
#include <string>
#include <vector>

namespace wallet {
BOOST_FIXTURE_TEST_SUITE(walletdb_tests, BasicTestingSetup)

BOOST_AUTO_TEST_CASE(walletdb_readkeyvalue)
{
    /**
     * When ReadKeyValue() reads from either a "key" or "wkey" it first reads the CDataStream steam into a
     * CPrivKey or CWalletKey respectively and then reads a hash of the pubkey and privkey into a uint256.
     * Wallets from 0.8 or before do not store the pubkey/privkey hash, trying to read the hash from old
     * wallets throws an exception, for backwards compatibility this read is wrapped in a try block to
     * silently fail. The test here makes sure the type of exception thrown from CDataStream::read()
     * matches the type we expect, otherwise we need to update the "key"/"wkey" exception type caught.
     */
    CDataStream ssValue(SER_DISK);
    uint256 dummy;
    BOOST_CHECK_THROW(ssValue >> dummy, std::ios_base::failure);
}

BOOST_AUTO_TEST_CASE(shadow_pow_claim_relay_clock_storage_is_exact_and_fail_closed)
{
    const auto serialized = [](const auto& object) {
        DataStream stream;
        stream << object;
        return SerializeData{stream.begin(), stream.end()};
    };
    const auto canonical_records = [&](bool legacy, int64_t value) {
        MockableData records;
        records.emplace(
            serialized(legacy
                           ? DBKeys::SHADOW_POW_CLAIM_LEGACY_RELAY_CLOCK_HIGH_WATER
                           : DBKeys::SHADOW_POW_CLAIM_RELAY_CLOCK_HIGH_WATER),
            serialized(value));
        return records;
    };
    const auto read = [](WalletBatch& batch, bool legacy,
                         int64_t& value, std::string& error) {
        return legacy
            ? batch.ReadShadowPowClaimLegacyRelayClockHighWater(
                  value, &error)
            : batch.ReadShadowPowClaimRelayClockHighWater(value, &error);
    };
    const auto check_read = [&](bool legacy, MockableData records,
                                DBErrors expected, int64_t expected_value,
                                const auto& configure) {
        std::unique_ptr<WalletDatabase> database =
            CreateMockableWalletDatabase(std::move(records));
        MockableDatabase& mock =
            dynamic_cast<MockableDatabase&>(*database);
        configure(mock);
        WalletBatch batch(*database, /*flush_on_close=*/false);
        int64_t value{-1};
        std::string error{"not cleared"};
        BOOST_CHECK_EQUAL(read(batch, legacy, value, error), expected);
        BOOST_CHECK_EQUAL(value, expected_value);
        if (expected == DBErrors::LOAD_OK) {
            BOOST_CHECK(error.empty());
        } else {
            BOOST_CHECK(!error.empty());
        }
    };
    const auto no_configuration = [](MockableDatabase&) {};

    for (const bool legacy : {false, true}) {
        check_read(legacy, {}, DBErrors::LOAD_OK, 0, no_configuration);
        for (const int64_t value :
             std::array<int64_t, 3>{0, 42,
                                    std::numeric_limits<int64_t>::max()}) {
            check_read(legacy, canonical_records(legacy, value),
                       DBErrors::LOAD_OK, value, no_configuration);
        }

        {
            std::unique_ptr<WalletDatabase> database =
                CreateMockableWalletDatabase();
            WalletBatch batch(*database, /*flush_on_close=*/false);
            BOOST_CHECK(!(legacy
                ? batch.WriteShadowPowClaimLegacyRelayClockHighWater(-1)
                : batch.WriteShadowPowClaimRelayClockHighWater(-1)));
        }

        MockableData truncated = canonical_records(legacy, 7);
        BOOST_REQUIRE(!truncated.begin()->second.empty());
        truncated.begin()->second.pop_back();
        check_read(legacy, std::move(truncated),
                   DBErrors::NONCRITICAL_ERROR, 0, no_configuration);

        MockableData trailing = canonical_records(legacy, 7);
        trailing.begin()->second.push_back(std::byte{0x00});
        check_read(legacy, std::move(trailing),
                   DBErrors::NONCRITICAL_ERROR, 0, no_configuration);

        check_read(legacy, canonical_records(legacy, -1),
                   DBErrors::NONCRITICAL_ERROR, 0, no_configuration);

        MockableData suffix_only;
        SerializeData suffix_key = serialized(
            legacy
                ? DBKeys::SHADOW_POW_CLAIM_LEGACY_RELAY_CLOCK_HIGH_WATER
                : DBKeys::SHADOW_POW_CLAIM_RELAY_CLOCK_HIGH_WATER);
        suffix_key.push_back(std::byte{0x01});
        suffix_only.emplace(suffix_key, serialized(int64_t{9}));
        check_read(legacy, suffix_only, DBErrors::NONCRITICAL_ERROR, 0,
                   no_configuration);

        MockableData duplicate_prefix = canonical_records(legacy, 9);
        duplicate_prefix.emplace(std::move(suffix_key), serialized(int64_t{9}));
        check_read(legacy, std::move(duplicate_prefix),
                   DBErrors::NONCRITICAL_ERROR, 0, no_configuration);

        check_read(
            legacy, canonical_records(legacy, 9),
            DBErrors::NONCRITICAL_ERROR, 0,
            [](MockableDatabase& mock) { mock.m_fail_cursor_create = true; });
        check_read(
            legacy, canonical_records(legacy, 9),
            DBErrors::NONCRITICAL_ERROR, 0,
            [](MockableDatabase& mock) { mock.m_throw_cursor_create = true; });
        check_read(
            legacy, canonical_records(legacy, 9),
            DBErrors::NONCRITICAL_ERROR, 0,
            [](MockableDatabase& mock) {
                mock.m_fail_cursor_next_at = 0;
            });
        check_read(
            legacy, canonical_records(legacy, 9),
            DBErrors::NONCRITICAL_ERROR, 0,
            [](MockableDatabase& mock) {
                mock.m_fail_cursor_next_at = 1;
            });
    }

    // A malformed restriction is noncritical to general wallet loading, but
    // it must latch the shared claim-recovery authority closed rather than
    // silently treating either scalar as absent.
    MockableData malformed = canonical_records(/*legacy=*/false, 11);
    MockableData canonical_legacy = canonical_records(/*legacy=*/true, 12);
    malformed.insert(canonical_legacy.begin(), canonical_legacy.end());
    const auto malformed_schema = malformed.find(serialized(
        DBKeys::SHADOW_POW_CLAIM_RELAY_CLOCK_HIGH_WATER));
    BOOST_REQUIRE(malformed_schema != malformed.end());
    malformed_schema->second.push_back(std::byte{0x00});
    CWallet malformed_wallet(
        m_node.chain.get(), "malformed-relay-clock",
        CreateMockableWalletDatabase(std::move(malformed)));
    BOOST_CHECK_EQUAL(malformed_wallet.LoadWallet(),
                      DBErrors::NONCRITICAL_ERROR);
    BOOST_CHECK(malformed_wallet.IsShadowPowClaimRecoveryDatabaseAmbiguous());
    const auto malformed_high_waters =
        malformed_wallet.GetShadowPowClaimRelayClockHighWatersForTesting();
    BOOST_CHECK_EQUAL(malformed_high_waters.first,
                      std::numeric_limits<int64_t>::max());
    BOOST_CHECK_EQUAL(malformed_high_waters.second,
                      std::numeric_limits<int64_t>::max());
    BOOST_CHECK(!malformed_wallet
                     .AdvanceShadowPowClaimRelayClockHighWatersForTesting(
                         0, 0));
}

BOOST_AUTO_TEST_CASE(shadow_pow_claim_relay_clock_transaction_is_atomic)
{
    const auto high_waters = [](const CWallet& wallet) {
        return wallet.GetShadowPowClaimRelayClockHighWatersForTesting();
    };
    const auto make_wallet = [&] {
        auto wallet = std::make_unique<CWallet>(
            m_node.chain.get(), "relay-clock-transaction",
            CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
        return wallet;
    };
    enum class Failure { BEGIN, FIRST_WRITE, SECOND_WRITE,
                         COMMIT_OLD, COMMIT_APPLIED };
    for (const Failure failure :
         {Failure::BEGIN, Failure::FIRST_WRITE, Failure::SECOND_WRITE,
          Failure::COMMIT_OLD, Failure::COMMIT_APPLIED}) {
        auto wallet = make_wallet();
        MockableDatabase& mock = GetMockableDatabase(*wallet);
        const MockableData before = mock.m_records;
        if (failure == Failure::BEGIN) mock.m_fail_begin = true;
        if (failure == Failure::FIRST_WRITE) mock.m_fail_write_at = 0;
        if (failure == Failure::SECOND_WRITE) mock.m_fail_write_at = 1;
        if (failure == Failure::COMMIT_OLD) mock.m_fail_commit = true;
        if (failure == Failure::COMMIT_APPLIED) {
            mock.m_fail_commit_after_apply = true;
        }
        BOOST_CHECK(!wallet->AdvanceShadowPowClaimRelayClockHighWatersForTesting(
            101, 202));
        BOOST_CHECK(wallet->IsShadowPowClaimRecoveryDatabaseAmbiguous());
        BOOST_CHECK((high_waters(*wallet) ==
                     std::pair<int64_t, int64_t>{0, 0}));
        if (failure == Failure::COMMIT_APPLIED) {
            BOOST_CHECK(mock.m_records != before);
        } else {
            BOOST_CHECK(mock.m_records == before);
        }
        // Ambiguity dominates the compare-and-max no-op path too.
        BOOST_CHECK(!wallet->AdvanceShadowPowClaimRelayClockHighWatersForTesting(
            0, 0));

        if (failure == Failure::COMMIT_APPLIED) {
            CWallet reload(
                m_node.chain.get(), "relay-clock-applied-reload",
                DuplicateMockDatabase(mock));
            BOOST_REQUIRE_EQUAL(reload.LoadWallet(), DBErrors::LOAD_OK);
            BOOST_CHECK((high_waters(reload) ==
                         std::pair<int64_t, int64_t>{101, 202}));
        }
    }

    auto wallet = make_wallet();
    MockableDatabase& mock = GetMockableDatabase(*wallet);
    BOOST_CHECK(!wallet->AdvanceShadowPowClaimRelayClockHighWatersForTesting(
        -1, 0));
    BOOST_CHECK(!wallet->IsShadowPowClaimRecoveryDatabaseAmbiguous());
    BOOST_CHECK((high_waters(*wallet) ==
                 std::pair<int64_t, int64_t>{0, 0}));

    const uint256 fingerprint_before = WITH_LOCK(
        wallet->cs_wallet,
        return wallet->GetShadowPowClaimCandidateStateFingerprintLocked());
    BOOST_REQUIRE(wallet->AdvanceShadowPowClaimRelayClockHighWatersForTesting(
        101, 202));
    BOOST_CHECK(mock.m_last_txn_durable);
    BOOST_CHECK_EQUAL(mock.m_write_calls, 2U);
    BOOST_CHECK((high_waters(*wallet) ==
                 std::pair<int64_t, int64_t>{101, 202}));
    const uint256 fingerprint_after = WITH_LOCK(
        wallet->cs_wallet,
        return wallet->GetShadowPowClaimCandidateStateFingerprintLocked());
    BOOST_CHECK(fingerprint_after != fingerprint_before);

    const MockableData both_records = mock.m_records;
    mock.m_write_calls = 0;
    BOOST_REQUIRE(wallet->AdvanceShadowPowClaimRelayClockHighWatersForTesting(
        100, 201));
    BOOST_CHECK_EQUAL(mock.m_write_calls, 0U);
    BOOST_CHECK(mock.m_records == both_records);

    BOOST_REQUIRE(wallet->AdvanceShadowPowClaimRelayClockHighWatersForTesting(
        303, 201));
    BOOST_CHECK((high_waters(*wallet) ==
                 std::pair<int64_t, int64_t>{303, 202}));
    BOOST_REQUIRE(wallet->AdvanceShadowPowClaimRelayClockHighWatersForTesting(
        303, 404));
    BOOST_CHECK((high_waters(*wallet) ==
                 std::pair<int64_t, int64_t>{303, 404}));

    CWallet reload(
        m_node.chain.get(), "relay-clock-success-reload",
        DuplicateMockDatabase(mock));
    BOOST_REQUIRE_EQUAL(reload.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK((high_waters(reload) ==
                 std::pair<int64_t, int64_t>{303, 404}));
}

BOOST_AUTO_TEST_CASE(walletdb_read_write_deadlock)
{
    // Exercises a db read write operation that shouldn't deadlock.
    for (const DatabaseFormat& db_format : DATABASE_FORMATS) {
        // Context setup
        DatabaseOptions options;
        options.require_format = db_format;
        DatabaseStatus status;
        bilingual_str error_string;
        std::unique_ptr<WalletDatabase> db = MakeDatabase(m_path_root / strprintf("wallet_%d_.dat", db_format).c_str(), options, status, error_string);
        BOOST_CHECK_EQUAL(status, DatabaseStatus::SUCCESS);

        std::shared_ptr<CWallet> wallet(new CWallet(m_node.chain.get(), "", std::move(db)));
        wallet->m_keypool_size = 4;

        // Create legacy spkm
        LOCK(wallet->cs_wallet);
        auto legacy_spkm = wallet->GetOrCreateLegacyScriptPubKeyMan();
        BOOST_CHECK(legacy_spkm->SetupGeneration(true));
        wallet->Flush();

        // Now delete all records, which performs a read write operation.
        BOOST_CHECK(wallet->GetLegacyScriptPubKeyMan()->DeleteRecords());
    }
}

BOOST_AUTO_TEST_CASE(qq_development_donation_consent_validation_and_roundtrip)
{
    const QQDevelopmentDonationConsent defaults =
        DefaultQQDevelopmentDonationConsent();
    BOOST_CHECK(ValidateQQDevelopmentDonationConsent(defaults));
    BOOST_CHECK(!defaults.HasDonationAuthority());

    QQDevelopmentDonationConsent invalid = defaults;
    invalid.percentage = 1;
    BOOST_CHECK(!ValidateQQDevelopmentDonationConsent(invalid));
    invalid = defaults;
    invalid.choice_recorded = 2;
    BOOST_CHECK(!ValidateQQDevelopmentDonationConsent(invalid));
    invalid = defaults;
    invalid.choice_recorded = 1;
    invalid.percentage = MAX_QQ_DEVELOPMENT_DONATION_PERCENTAGE + 1;
    invalid.network = "main";
    invalid.recipient = "recipient";
    BOOST_CHECK(!ValidateQQDevelopmentDonationConsent(invalid));

    std::unique_ptr<WalletDatabase> database = CreateMockableWalletDatabase();
    WalletBatch batch(*database, /*flush_on_close=*/false);
    QQDevelopmentDonationConsent output;
    std::string error{"not cleared"};
    BOOST_CHECK_EQUAL(batch.ReadQQDevelopmentDonationConsent(output, &error), DBErrors::LOAD_OK);
    BOOST_CHECK(output == defaults);
    BOOST_CHECK(error.empty());

    QQDevelopmentDonationConsent input;
    input.choice_recorded = 1;
    input.percentage = 7;
    input.network = "main";
    input.recipient = Params().GetQQDevelopmentDonationAddress();
    BOOST_REQUIRE(ValidateQQDevelopmentDonationConsent(input));
    BOOST_REQUIRE(batch.WriteQQDevelopmentDonationConsent(input));
    BOOST_CHECK_EQUAL(batch.ReadQQDevelopmentDonationConsent(output, &error), DBErrors::LOAD_OK);
    BOOST_CHECK(output == input);

    invalid = input;
    invalid.recipient.clear();
    BOOST_CHECK(!batch.WriteQQDevelopmentDonationConsent(invalid));
    BOOST_CHECK_EQUAL(batch.ReadQQDevelopmentDonationConsent(output, &error), DBErrors::LOAD_OK);
    BOOST_CHECK(output == input);
}

BOOST_AUTO_TEST_CASE(qq_development_donation_runtime_is_recipient_bound)
{
    std::unique_ptr<WalletDatabase> database = CreateMockableWalletDatabase();
    const std::shared_ptr<CWallet> wallet(
        new CWallet(m_node.chain.get(), "qq-development-donation", std::move(database)));
    const std::string recipient = Params().GetQQDevelopmentDonationAddress();
    bilingual_str error;

    BOOST_CHECK_EQUAL(wallet->GetQQDevelopmentDonationPercentage(), 0U);
    BOOST_REQUIRE(wallet->SetQQDevelopmentDonationConsent(7, recipient, error));
    BOOST_CHECK_EQUAL(wallet->GetQQDevelopmentDonationPercentage(), 7U);
    const QQDevelopmentDonationConsent consent =
        wallet->GetQQDevelopmentDonationConsent();
    BOOST_CHECK(consent.HasDonationAuthority());
    BOOST_CHECK_EQUAL(consent.network, Params().GetChainTypeString());
    BOOST_CHECK_EQUAL(consent.recipient, recipient);

    BOOST_CHECK(!wallet->SetQQDevelopmentDonationConsent(8, recipient + "wrong", error));
    BOOST_CHECK(!error.empty());
    BOOST_CHECK_EQUAL(wallet->GetQQDevelopmentDonationPercentage(), 7U);

    MockableDatabase& mock = GetMockableDatabase(*wallet);
    mock.m_fail_write_at = 0;
    BOOST_CHECK(!wallet->SetQQDevelopmentDonationConsent(8, recipient, error));
    BOOST_CHECK(!error.empty());
    BOOST_CHECK_EQUAL(wallet->GetQQDevelopmentDonationPercentage(), 7U);
    BOOST_CHECK_EQUAL(wallet->GetQQDevelopmentDonationConsent().percentage, 7U);
    BOOST_CHECK(!wallet->IsQQDevelopmentDonationDatabaseAmbiguous());
    mock.m_fail_write_at.reset();

    // A failed durable commit leaves the on-disk outcome unknowable. Never
    // publish either possible consent as authority until the wallet reloads.
    mock.m_fail_commit = true;
    BOOST_CHECK(!wallet->SetQQDevelopmentDonationConsent(8, recipient, error));
    BOOST_CHECK(!error.empty());
    BOOST_CHECK_EQUAL(wallet->GetQQDevelopmentDonationPercentage(), 0U);
    BOOST_CHECK(wallet->IsQQDevelopmentDonationDatabaseAmbiguous());
    BOOST_CHECK(!wallet->SetQQDevelopmentDonationConsent(9, recipient, error));
    BOOST_CHECK_EQUAL(wallet->GetQQDevelopmentDonationPercentage(), 0U);
    mock.m_fail_commit = false;
}

BOOST_AUTO_TEST_CASE(qq_development_donation_malformed_and_rotation_fail_closed)
{
    auto check_malformed = [this](const auto& malformed_value) {
        std::unique_ptr<WalletDatabase> database = CreateMockableWalletDatabase();
        {
            std::unique_ptr<DatabaseBatch> raw_batch =
                database->MakeBatch(/*flush_on_close=*/false);
            BOOST_REQUIRE(raw_batch->Write(
                DBKeys::QQ_DEVELOPMENT_DONATION_CONSENT, malformed_value));
        }

        const std::shared_ptr<CWallet> wallet(new CWallet(
            m_node.chain.get(), "malformed-donation-consent", std::move(database)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::NONCRITICAL_ERROR);
        BOOST_CHECK_EQUAL(wallet->GetQQDevelopmentDonationPercentage(), 0U);
        BOOST_CHECK(!wallet->GetQQDevelopmentDonationConsent().HasDonationAuthority());

        QQDevelopmentDonationConsent output;
        std::string error;
        WalletBatch batch(wallet->GetDatabase(), /*flush_on_close=*/false);
        BOOST_CHECK_EQUAL(
            batch.ReadQQDevelopmentDonationConsent(output, &error),
            DBErrors::NONCRITICAL_ERROR);
        BOOST_CHECK(output == DefaultQQDevelopmentDonationConsent());
        BOOST_CHECK(!error.empty());
    };

    check_malformed(std::string{"truncated"});

    QQDevelopmentDonationConsent unknown_version;
    unknown_version.version = QQDevelopmentDonationConsent::VERSION + 1;
    unknown_version.choice_recorded = 1;
    unknown_version.percentage = 7;
    unknown_version.network = Params().GetChainTypeString();
    unknown_version.recipient = Params().GetQQDevelopmentDonationAddress();
    check_malformed(unknown_version);

    // A valid consent record for an older/rotated recipient remains visible
    // for audit, but grants no payment authority under the current identity.
    std::unique_ptr<WalletDatabase> database = CreateMockableWalletDatabase();
    QQDevelopmentDonationConsent rotated;
    rotated.choice_recorded = 1;
    rotated.percentage = 7;
    rotated.network = Params().GetChainTypeString();
    rotated.recipient = "retired-quantum-recipient";
    {
        WalletBatch batch(*database, /*flush_on_close=*/false);
        BOOST_REQUIRE(batch.WriteQQDevelopmentDonationConsent(rotated));
    }
    const std::shared_ptr<CWallet> wallet(new CWallet(
        m_node.chain.get(), "rotated-donation-consent", std::move(database)));
    BOOST_REQUIRE_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(wallet->GetQQDevelopmentDonationConsent() == rotated);
    BOOST_CHECK_EQUAL(wallet->GetQQDevelopmentDonationPercentage(), 0U);

}

BOOST_AUTO_TEST_CASE(shadow_pow_claim_recovery_policy_validation)
{
    const ShadowPowClaimRecoveryPolicy defaults = DefaultShadowPowClaimRecoveryPolicy();
    BOOST_CHECK(ValidateShadowPowClaimRecoveryPolicy(defaults));
    BOOST_CHECK(!defaults.choice_recorded);
    BOOST_CHECK(!defaults.automatic_enabled);
    BOOST_CHECK(!defaults.HasAutomaticAuthority());

    auto expect_invalid = [](ShadowPowClaimRecoveryPolicy policy) {
        std::string error;
        BOOST_CHECK(!ValidateShadowPowClaimRecoveryPolicy(policy, &error));
        BOOST_CHECK(!error.empty());
    };

    ShadowPowClaimRecoveryPolicy policy = defaults;
    policy.automatic_enabled = true;
    expect_invalid(policy);

    policy = defaults;
    policy.version = ShadowPowClaimRecoveryPolicy::VERSION + 1;
    expect_invalid(policy);

    policy = defaults;
    policy.choice_recorded = 2;
    expect_invalid(policy);

    policy = defaults;
    policy.max_fee_per_resolution = 0;
    expect_invalid(policy);

    policy = defaults;
    policy.max_fee_per_resolution = SHADOW_POW_RECOVERY_MAX_FEE_PER_RESOLUTION + 1;
    expect_invalid(policy);

    policy = defaults;
    policy.aggregate_batch_fee_cap = policy.max_fee_per_resolution - 1;
    expect_invalid(policy);

    policy = defaults;
    policy.rolling_fee_budget = policy.aggregate_batch_fee_cap - 1;
    expect_invalid(policy);

    policy = defaults;
    policy.rolling_fee_window_seconds = SHADOW_POW_RECOVERY_MIN_WINDOW_SECONDS - 1;
    expect_invalid(policy);

    policy = defaults;
    policy.max_actions_per_window = 0;
    expect_invalid(policy);

    policy = defaults;
    policy.minimum_stale_blocks = 0;
    expect_invalid(policy);

    policy = defaults;
    policy.choice_recorded = true;
    policy.automatic_enabled = true;
    BOOST_CHECK(ValidateShadowPowClaimRecoveryPolicy(policy));
    BOOST_CHECK(policy.HasAutomaticAuthority());
}

BOOST_AUTO_TEST_CASE(shadow_pow_claim_recovery_policy_walletdb_roundtrip)
{
    std::unique_ptr<WalletDatabase> database = CreateMockableWalletDatabase();
    WalletBatch batch(*database, /*flush_on_close=*/false);

    ShadowPowClaimRecoveryPolicy output;
    output.choice_recorded = true;
    output.automatic_enabled = true;
    std::string error{"not cleared"};
    BOOST_CHECK_EQUAL(batch.ReadShadowPowClaimRecoveryPolicy(output, &error), DBErrors::LOAD_OK);
    BOOST_CHECK(output == DefaultShadowPowClaimRecoveryPolicy());
    BOOST_CHECK(error.empty());

    ShadowPowClaimRecoveryPolicy input = DefaultShadowPowClaimRecoveryPolicy();
    input.choice_recorded = true;
    input.automatic_enabled = true;
    input.max_fee_per_resolution = 25000;
    input.aggregate_batch_fee_cap = 250000;
    input.rolling_fee_budget = 1000000;
    input.rolling_fee_window_seconds = 3600;
    input.max_actions_per_window = 25;
    input.minimum_stale_blocks = 12;
    BOOST_REQUIRE(batch.WriteShadowPowClaimRecoveryPolicy(input));

    BOOST_CHECK_EQUAL(batch.ReadShadowPowClaimRecoveryPolicy(output, &error), DBErrors::LOAD_OK);
    BOOST_CHECK(output == input);
    BOOST_CHECK(error.empty());

    // Invalid writes never replace a previously valid standing-consent record.
    ShadowPowClaimRecoveryPolicy invalid = input;
    invalid.automatic_enabled = true;
    invalid.choice_recorded = false;
    BOOST_CHECK(!batch.WriteShadowPowClaimRecoveryPolicy(invalid));
    BOOST_CHECK_EQUAL(batch.ReadShadowPowClaimRecoveryPolicy(output, &error), DBErrors::LOAD_OK);
    BOOST_CHECK(output == input);

    BOOST_REQUIRE(batch.EraseShadowPowClaimRecoveryPolicy());
    output = input;
    BOOST_CHECK_EQUAL(batch.ReadShadowPowClaimRecoveryPolicy(output, &error), DBErrors::LOAD_OK);
    BOOST_CHECK(output == DefaultShadowPowClaimRecoveryPolicy());
}

BOOST_AUTO_TEST_CASE(shadow_pow_claim_recovery_policy_malformed_is_noncritical)
{
    auto check_malformed = [this](const auto& malformed_value) {
        std::unique_ptr<WalletDatabase> database = CreateMockableWalletDatabase();
        {
            std::unique_ptr<DatabaseBatch> raw_batch = database->MakeBatch(/*flush_on_close=*/false);
            BOOST_REQUIRE(raw_batch->Write(DBKeys::SHADOW_POW_CLAIM_RECOVERY_POLICY, malformed_value));
        }

        const std::shared_ptr<CWallet> wallet(
            new CWallet(m_node.chain.get(), "malformed-recovery-policy", std::move(database)));
        BOOST_CHECK_EQUAL(wallet->LoadWallet(), DBErrors::NONCRITICAL_ERROR);
        BOOST_CHECK(wallet->GetShadowPowClaimRecoveryPolicy() == DefaultShadowPowClaimRecoveryPolicy());

        ShadowPowClaimRecoveryPolicy output;
        output.choice_recorded = true;
        output.automatic_enabled = true;
        std::string error;
        WalletBatch batch(wallet->GetDatabase(), /*flush_on_close=*/false);
        BOOST_CHECK_EQUAL(batch.ReadShadowPowClaimRecoveryPolicy(output, &error), DBErrors::NONCRITICAL_ERROR);
        BOOST_CHECK(output == DefaultShadowPowClaimRecoveryPolicy());
        BOOST_CHECK(!output.HasAutomaticAuthority());
        BOOST_CHECK(!error.empty());
    };

    // A different serialized type cannot be decoded as the policy.
    check_malformed(std::string{"truncated"});

    // A structurally decodable record with an unknown version also fails
    // closed without making the wallet unloadable.
    ShadowPowClaimRecoveryPolicy unknown_version = DefaultShadowPowClaimRecoveryPolicy();
    unknown_version.version = ShadowPowClaimRecoveryPolicy::VERSION + 1;
    unknown_version.choice_recorded = true;
    unknown_version.automatic_enabled = true;
    check_malformed(unknown_version);
}

BOOST_AUTO_TEST_CASE(shadow_pow_claim_recovery_policy_runtime_is_atomic)
{
    ShadowPowClaimRecoveryPolicy initial = DefaultShadowPowClaimRecoveryPolicy();
    initial.choice_recorded = true;
    initial.automatic_enabled = true;
    initial.max_fee_per_resolution = 20000;
    initial.aggregate_batch_fee_cap = 200000;
    initial.rolling_fee_budget = 2000000;
    initial.rolling_fee_window_seconds = 3600;
    initial.max_actions_per_window = 20;
    initial.minimum_stale_blocks = 10;

    std::unique_ptr<WalletDatabase> database = CreateMockableWalletDatabase();
    {
        WalletBatch batch(*database, /*flush_on_close=*/false);
        BOOST_REQUIRE(batch.WriteShadowPowClaimRecoveryPolicy(initial));
    }

    const std::shared_ptr<CWallet> wallet(
        new CWallet(m_node.chain.get(), "recovery-policy-runtime", std::move(database)));
    BOOST_REQUIRE_EQUAL(wallet->LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(wallet->GetShadowPowClaimRecoveryPolicy() == initial);

    ShadowPowClaimRecoveryPolicy updated = initial;
    updated.max_fee_per_resolution = 30000;
    updated.aggregate_batch_fee_cap = 300000;
    updated.rolling_fee_budget = 3000000;
    updated.rolling_fee_window_seconds = 7200;
    updated.max_actions_per_window = 30;
    updated.minimum_stale_blocks = 20;
    const ShadowPowClaimRecoveryPolicyMutationResult update_result =
        wallet->SetShadowPowClaimRecoveryPolicyDetailed(updated);
    BOOST_REQUIRE(update_result.success);
    BOOST_CHECK(update_result.status ==
                ShadowPowClaimRecoveryPolicyMutationStatus::SUCCESS);
    BOOST_CHECK(update_result.durable_state_changed);
    BOOST_CHECK(!update_result.durable_state_ambiguous);
    BOOST_CHECK(update_result.authoritative_state_available);
    BOOST_CHECK(update_result.authoritative_policy == updated);
    BOOST_CHECK(wallet->GetShadowPowClaimRecoveryPolicy() == updated);
    const ShadowPowClaimRecoveryPolicyMutationResult readable_state =
        wallet->GetShadowPowClaimRecoveryPolicyState();
    BOOST_CHECK(readable_state.success);
    BOOST_CHECK(!readable_state.durable_state_changed);
    BOOST_CHECK(!readable_state.durable_state_ambiguous);
    BOOST_CHECK(readable_state.authoritative_state_available);
    BOOST_CHECK(readable_state.authoritative_policy == updated);

    MockableDatabase& mock = GetMockableDatabase(*wallet);
    BOOST_CHECK(mock.m_last_txn_durable);
    ShadowPowClaimRecoveryPolicy persisted;
    {
        WalletBatch batch(wallet->GetDatabase(), /*flush_on_close=*/false);
        BOOST_REQUIRE_EQUAL(batch.ReadShadowPowClaimRecoveryPolicy(persisted), DBErrors::LOAD_OK);
    }
    BOOST_CHECK(persisted == updated);

    // Validation failure changes neither the live policy nor the DB record.
    ShadowPowClaimRecoveryPolicy invalid = updated;
    invalid.choice_recorded = false;
    const ShadowPowClaimRecoveryPolicyMutationResult invalid_result =
        wallet->SetShadowPowClaimRecoveryPolicyDetailed(invalid);
    BOOST_CHECK(!invalid_result.success);
    BOOST_CHECK(invalid_result.status ==
                ShadowPowClaimRecoveryPolicyMutationStatus::INVALID_POLICY);
    BOOST_CHECK(!invalid_result.durable_state_changed);
    BOOST_CHECK(!invalid_result.durable_state_ambiguous);
    BOOST_CHECK(invalid_result.authoritative_state_available);
    BOOST_CHECK(invalid_result.authoritative_policy == updated);
    BOOST_CHECK(!invalid_result.detail.empty());
    BOOST_CHECK(wallet->GetShadowPowClaimRecoveryPolicy() == updated);

    // A failed write aborts the durable transaction before publishing the
    // requested authority in memory.
    ShadowPowClaimRecoveryPolicy write_failure = updated;
    write_failure.max_actions_per_window += 1;
    // MockableBatch resets its per-transaction write index in TxnBegin().
    mock.m_fail_write_at = 0;
    const ShadowPowClaimRecoveryPolicyMutationResult write_result =
        wallet->SetShadowPowClaimRecoveryPolicyDetailed(write_failure);
    BOOST_CHECK(!write_result.success);
    BOOST_CHECK(write_result.status ==
                ShadowPowClaimRecoveryPolicyMutationStatus::DATABASE_FAILURE);
    BOOST_CHECK(!write_result.durable_state_changed);
    BOOST_CHECK(!write_result.durable_state_ambiguous);
    BOOST_CHECK(write_result.authoritative_state_available);
    BOOST_CHECK(write_result.authoritative_policy == updated);
    BOOST_CHECK(wallet->GetShadowPowClaimRecoveryPolicy() == updated);
    mock.m_fail_write_at.reset();

    // A failed durable commit must not claim either the old or requested
    // policy is authoritative. The wallet fails closed until reload even
    // though this deterministic mock's abort leaves its backing store old.
    ShadowPowClaimRecoveryPolicy commit_failure = updated;
    commit_failure.max_actions_per_window += 2;
    mock.m_fail_commit = true;
    const ShadowPowClaimRecoveryPolicyMutationResult commit_result =
        wallet->SetShadowPowClaimRecoveryPolicyDetailed(commit_failure);
    BOOST_CHECK(!commit_result.success);
    BOOST_CHECK(commit_result.status ==
                ShadowPowClaimRecoveryPolicyMutationStatus::DATABASE_OUTCOME_AMBIGUOUS);
    BOOST_CHECK(!commit_result.durable_state_changed);
    BOOST_CHECK(commit_result.durable_state_ambiguous);
    BOOST_CHECK(!commit_result.authoritative_state_available);
    BOOST_CHECK(wallet->IsShadowPowClaimRecoveryDatabaseAmbiguous());
    BOOST_CHECK(wallet->GetShadowPowClaimRecoveryPolicy() == updated);
    mock.m_fail_commit = false;

    const ShadowPowClaimRecoveryPolicyMutationResult ambiguous_state =
        wallet->GetShadowPowClaimRecoveryPolicyState();
    BOOST_CHECK(!ambiguous_state.success);
    BOOST_CHECK(ambiguous_state.status ==
                ShadowPowClaimRecoveryPolicyMutationStatus::DATABASE_OUTCOME_AMBIGUOUS);
    BOOST_CHECK(ambiguous_state.durable_state_ambiguous);
    BOOST_CHECK(!ambiguous_state.authoritative_state_available);

    const ShadowPowClaimRecoveryPolicyMutationResult blocked_result =
        wallet->SetShadowPowClaimRecoveryPolicyDetailed(updated);
    BOOST_CHECK(blocked_result.status ==
                ShadowPowClaimRecoveryPolicyMutationStatus::DATABASE_OUTCOME_AMBIGUOUS);
    BOOST_CHECK(blocked_result.durable_state_ambiguous);
    BOOST_CHECK(!blocked_result.authoritative_state_available);

    {
        WalletBatch batch(wallet->GetDatabase(), /*flush_on_close=*/false);
        BOOST_REQUIRE_EQUAL(batch.ReadShadowPowClaimRecoveryPolicy(persisted), DBErrors::LOAD_OK);
    }
    BOOST_CHECK(persisted == updated);
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
