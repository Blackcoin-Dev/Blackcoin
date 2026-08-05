// Copyright (c) 2018-2022 The Bitcoin Core developers
// Copyright (c) 2018-2022 Blackcoin Core Developers
// Copyright (c) 2018-2022 Blackcoin More Developers
// Copyright (c) 2018-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <boost/test/unit_test.hpp>

#include <common/args.h>
#include <noui.h>
#include <test/util/logging.h>
#include <test/util/setup_common.h>
#include <wallet/shadow_pow_claim_recovery_args.h>
#include <wallet/test/init_test_fixture.h>
#include <wallet/context.h>
#include <wallet/load.h>
#include <wallet/wallet.h>
#include <wallet/walletdb.h>
#include <wallet/test/util.h>

namespace wallet {
namespace {

void SetAutomaticClaimRecoveryArgs(ArgsManager& args)
{
    args.ForceSetArg(ARG_AUTORESOLVE_FAILED_CLAIMS, "automatic");
    args.ForceSetArg(ARG_AUTORESOLVE_MAX_FEE, "0.001");
    args.ForceSetArg(ARG_AUTORESOLVE_BATCH_FEE_CAP, "0.01");
    args.ForceSetArg(ARG_AUTORESOLVE_ROLLING_FEE_BUDGET, "0.10");
    args.ForceSetArg(ARG_AUTORESOLVE_ROLLING_WINDOW, "3600");
    args.ForceSetArg(ARG_AUTORESOLVE_MAX_ACTIONS, "10");
    args.ForceSetArg(ARG_AUTORESOLVE_STALE_BLOCKS, "6");
}

ShadowPowClaimRecoveryPolicy ExpectedAutomaticClaimRecoveryPolicy()
{
    ShadowPowClaimRecoveryPolicy policy = DefaultShadowPowClaimRecoveryPolicy();
    policy.choice_recorded = 1;
    policy.automatic_enabled = 1;
    policy.max_fee_per_resolution = COIN / 1000;
    policy.aggregate_batch_fee_cap = COIN / 100;
    policy.rolling_fee_budget = COIN / 10;
    policy.rolling_fee_window_seconds = 3600;
    policy.max_actions_per_window = 10;
    policy.minimum_stale_blocks = 6;
    return policy;
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(init_tests, InitWalletDirTestingSetup)

BOOST_AUTO_TEST_CASE(walletinit_verify_walletdir_default)
{
    SetWalletDir(m_walletdir_path_cases["default"]);
    bool result = m_wallet_loader->verify();
    BOOST_CHECK(result == true);
    fs::path walletdir = m_args.GetPathArg("-walletdir");
    fs::path expected_path = fs::canonical(m_walletdir_path_cases["default"]);
    BOOST_CHECK_EQUAL(walletdir, expected_path);
}

BOOST_AUTO_TEST_CASE(walletinit_verify_walletdir_custom)
{
    SetWalletDir(m_walletdir_path_cases["custom"]);
    bool result = m_wallet_loader->verify();
    BOOST_CHECK(result == true);
    fs::path walletdir = m_args.GetPathArg("-walletdir");
    fs::path expected_path = fs::canonical(m_walletdir_path_cases["custom"]);
    BOOST_CHECK_EQUAL(walletdir, expected_path);
}

BOOST_AUTO_TEST_CASE(walletinit_verify_walletdir_does_not_exist)
{
    SetWalletDir(m_walletdir_path_cases["nonexistent"]);
    {
        ASSERT_DEBUG_LOG("does not exist");
        bool result = m_wallet_loader->verify();
        BOOST_CHECK(result == false);
    }
}

BOOST_AUTO_TEST_CASE(walletinit_verify_walletdir_is_not_directory)
{
    SetWalletDir(m_walletdir_path_cases["file"]);
    {
        ASSERT_DEBUG_LOG("is not a directory");
        bool result = m_wallet_loader->verify();
        BOOST_CHECK(result == false);
    }
}

BOOST_AUTO_TEST_CASE(walletinit_verify_walletdir_is_not_relative)
{
    SetWalletDir(m_walletdir_path_cases["relative"]);
    {
        ASSERT_DEBUG_LOG("is a relative path");
        bool result = m_wallet_loader->verify();
        BOOST_CHECK(result == false);
    }
}

BOOST_AUTO_TEST_CASE(walletinit_verify_walletdir_no_trailing)
{
    SetWalletDir(m_walletdir_path_cases["trailing"]);
    bool result = m_wallet_loader->verify();
    BOOST_CHECK(result == true);
    fs::path walletdir = m_args.GetPathArg("-walletdir");
    fs::path expected_path = fs::canonical(m_walletdir_path_cases["default"]);
    BOOST_CHECK_EQUAL(walletdir, expected_path);
}

BOOST_AUTO_TEST_CASE(walletinit_verify_walletdir_no_trailing2)
{
    SetWalletDir(m_walletdir_path_cases["trailing2"]);
    bool result = m_wallet_loader->verify();
    BOOST_CHECK(result == true);
    fs::path walletdir = m_args.GetPathArg("-walletdir");
    fs::path expected_path = fs::canonical(m_walletdir_path_cases["default"]);
    BOOST_CHECK_EQUAL(walletdir, expected_path);
}

BOOST_AUTO_TEST_CASE(pow_claim_recovery_startup_policy_is_default_off)
{
    ArgsManager args;
    std::optional<ShadowPowClaimRecoveryPolicy> policy;
    std::string error;
    BOOST_CHECK(ParseShadowPowClaimRecoveryStartupPolicy(args, policy, error));
    BOOST_CHECK(!policy.has_value());
    BOOST_CHECK(error.empty());
}

BOOST_AUTO_TEST_CASE(pow_claim_recovery_startup_pause_is_explicit_and_non_spending)
{
    ArgsManager args;
    args.ForceSetArg(ARG_AUTORESOLVE_FAILED_CLAIMS, "pause-and-ask");

    std::optional<ShadowPowClaimRecoveryPolicy> policy;
    std::string error;
    BOOST_REQUIRE(ParseShadowPowClaimRecoveryStartupPolicy(args, policy, error));
    BOOST_REQUIRE(policy.has_value());
    BOOST_CHECK_EQUAL(policy->choice_recorded, 1);
    BOOST_CHECK_EQUAL(policy->automatic_enabled, 0);
    BOOST_CHECK(!policy->HasAutomaticAuthority());
}

BOOST_AUTO_TEST_CASE(pow_claim_recovery_startup_automatic_requires_complete_bounded_limits)
{
    ArgsManager args;
    args.ForceSetArg(ARG_AUTORESOLVE_FAILED_CLAIMS, "automatic");
    args.ForceSetArg(ARG_AUTORESOLVE_MAX_FEE, "0.001");

    std::optional<ShadowPowClaimRecoveryPolicy> policy;
    std::string error;
    BOOST_CHECK(!ParseShadowPowClaimRecoveryStartupPolicy(args, policy, error));
    BOOST_CHECK(!policy.has_value());
    BOOST_CHECK(error.find("all six explicit limits") != std::string::npos);

    args.ForceSetArg(ARG_AUTORESOLVE_BATCH_FEE_CAP, "0.01");
    args.ForceSetArg(ARG_AUTORESOLVE_ROLLING_FEE_BUDGET, "0.10");
    args.ForceSetArg(ARG_AUTORESOLVE_ROLLING_WINDOW, "3600");
    args.ForceSetArg(ARG_AUTORESOLVE_MAX_ACTIONS, "10");
    args.ForceSetArg(ARG_AUTORESOLVE_STALE_BLOCKS, "6");
    BOOST_REQUIRE(ParseShadowPowClaimRecoveryStartupPolicy(args, policy, error));
    BOOST_REQUIRE(policy.has_value());
    BOOST_CHECK(policy->HasAutomaticAuthority());
    BOOST_CHECK_EQUAL(policy->max_fee_per_resolution, COIN / 1000);
    BOOST_CHECK_EQUAL(policy->aggregate_batch_fee_cap, COIN / 100);
    BOOST_CHECK_EQUAL(policy->rolling_fee_budget, COIN / 10);
    BOOST_CHECK_EQUAL(policy->rolling_fee_window_seconds, 3600U);
    BOOST_CHECK_EQUAL(policy->max_actions_per_window, 10U);
    BOOST_CHECK_EQUAL(policy->minimum_stale_blocks, 6U);

    args.ForceSetArg(ARG_AUTORESOLVE_BATCH_FEE_CAP, "0.0001");
    BOOST_CHECK(!ParseShadowPowClaimRecoveryStartupPolicy(args, policy, error));
    BOOST_CHECK(!policy.has_value());
    BOOST_CHECK(error.find("batch fee cap") != std::string::npos);
}

BOOST_AUTO_TEST_CASE(pow_claim_recovery_startup_rejects_orphaned_or_ignored_limits)
{
    ArgsManager args;
    args.ForceSetArg(ARG_AUTORESOLVE_MAX_FEE, "0.001");

    std::optional<ShadowPowClaimRecoveryPolicy> policy;
    std::string error;
    BOOST_CHECK(!ParseShadowPowClaimRecoveryStartupPolicy(args, policy, error));
    BOOST_CHECK(!policy.has_value());
    BOOST_CHECK(error.find("explicit") != std::string::npos);

    args.ForceSetArg(ARG_AUTORESOLVE_FAILED_CLAIMS, "pause-and-ask");
    BOOST_CHECK(!ParseShadowPowClaimRecoveryStartupPolicy(args, policy, error));
    BOOST_CHECK(!policy.has_value());
    BOOST_CHECK(error.find("accepted only") != std::string::npos);
}

BOOST_AUTO_TEST_CASE(pow_claim_recovery_startup_seeds_only_absent_policy)
{
    ArgsManager args;
    SetAutomaticClaimRecoveryArgs(args);

    CWallet wallet(/*chain=*/nullptr, "recovery-seed-absent", CreateMockableWalletDatabase());
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(!WalletBatch(wallet.GetDatabase(), /*flush_on_close=*/false).HasShadowPowClaimRecoveryPolicy());

    bilingual_str error;
    BOOST_REQUIRE(wallet.ApplyShadowPowClaimRecoveryStartupPolicy(args, error));
    BOOST_CHECK(error.empty());
    BOOST_CHECK(wallet.GetShadowPowClaimRecoveryPolicy() == ExpectedAutomaticClaimRecoveryPolicy());

    ShadowPowClaimRecoveryPolicy persisted;
    WalletBatch batch(wallet.GetDatabase(), /*flush_on_close=*/false);
    BOOST_CHECK(batch.HasShadowPowClaimRecoveryPolicy());
    BOOST_REQUIRE_EQUAL(batch.ReadShadowPowClaimRecoveryPolicy(persisted), DBErrors::LOAD_OK);
    BOOST_CHECK(persisted == ExpectedAutomaticClaimRecoveryPolicy());
}

BOOST_AUTO_TEST_CASE(pow_claim_recovery_startup_preserves_every_existing_record)
{
    ArgsManager args;
    SetAutomaticClaimRecoveryArgs(args);

    const auto check_preserved = [&](const ShadowPowClaimRecoveryPolicy& persisted, const std::string& name) {
        std::unique_ptr<WalletDatabase> database = CreateMockableWalletDatabase();
        {
            WalletBatch batch(*database, /*flush_on_close=*/false);
            BOOST_REQUIRE(batch.WriteShadowPowClaimRecoveryPolicy(persisted));
        }

        CWallet wallet(/*chain=*/nullptr, name, std::move(database));
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        bilingual_str error;
        BOOST_REQUIRE(wallet.ApplyShadowPowClaimRecoveryStartupPolicy(args, error));
        BOOST_CHECK(error.empty());
        BOOST_CHECK(wallet.GetShadowPowClaimRecoveryPolicy() == persisted);

        ShadowPowClaimRecoveryPolicy still_persisted;
        WalletBatch batch(wallet.GetDatabase(), /*flush_on_close=*/false);
        BOOST_CHECK(batch.HasShadowPowClaimRecoveryPolicy());
        BOOST_REQUIRE_EQUAL(batch.ReadShadowPowClaimRecoveryPolicy(still_persisted), DBErrors::LOAD_OK);
        BOOST_CHECK(still_persisted == persisted);
    };

    // Even a deliberately persisted UNSET record is an existing wallet record
    // and cannot be silently promoted by a process argument.
    check_preserved(DefaultShadowPowClaimRecoveryPolicy(), "recovery-seed-existing-default");

    ShadowPowClaimRecoveryPolicy pause = DefaultShadowPowClaimRecoveryPolicy();
    pause.choice_recorded = 1;
    check_preserved(pause, "recovery-seed-existing-pause");
}

BOOST_AUTO_TEST_CASE(pow_claim_recovery_startup_preserves_malformed_record_fail_closed)
{
    std::unique_ptr<WalletDatabase> database = CreateMockableWalletDatabase();
    {
        std::unique_ptr<DatabaseBatch> raw_batch = database->MakeBatch(/*flush_on_close=*/false);
        BOOST_REQUIRE(raw_batch->Write(DBKeys::SHADOW_POW_CLAIM_RECOVERY_POLICY, std::string{"malformed"}));
    }

    CWallet wallet(/*chain=*/nullptr, "recovery-seed-malformed", std::move(database));
    BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::NONCRITICAL_ERROR);
    BOOST_CHECK(!wallet.GetShadowPowClaimRecoveryPolicy().HasAutomaticAuthority());

    ArgsManager args;
    SetAutomaticClaimRecoveryArgs(args);
    bilingual_str error;
    BOOST_REQUIRE(wallet.ApplyShadowPowClaimRecoveryStartupPolicy(args, error));
    BOOST_CHECK(error.empty());
    BOOST_CHECK(!wallet.GetShadowPowClaimRecoveryPolicy().HasAutomaticAuthority());

    ShadowPowClaimRecoveryPolicy ignored;
    std::string read_error;
    WalletBatch batch(wallet.GetDatabase(), /*flush_on_close=*/false);
    BOOST_CHECK(batch.HasShadowPowClaimRecoveryPolicy());
    BOOST_CHECK_EQUAL(batch.ReadShadowPowClaimRecoveryPolicy(ignored, &read_error), DBErrors::NONCRITICAL_ERROR);
    BOOST_CHECK(!read_error.empty());
}

BOOST_FIXTURE_TEST_CASE(createwallet_and_loadwallet_apply_seed_without_unlock_or_mining, TestingSetup)
{
    m_args.ForceSetArg("-unsafesqlitesync", "1");
    fs::create_directories(m_args.GetDataDirNet() / "wallets");

    WalletContext context;
    context.args = &m_args;
    context.chain = m_node.chain.get();

    // First create an encrypted wallet without startup policy metadata. It is
    // unloaded before the explicit process policy is supplied, modeling a
    // later loadwallet RPC call.
    const std::string load_wallet_name{"runtime-load-recovery-seed"};
    DatabaseOptions initial_options;
    ReadDatabaseArgs(m_args, initial_options);
    initial_options.require_create = true;
    initial_options.create_flags = WALLET_FLAG_DESCRIPTORS;
    initial_options.create_passphrase = SecureString{"runtime-load-passphrase"};
    DatabaseStatus status;
    bilingual_str error;
    std::vector<bilingual_str> warnings;
    std::shared_ptr<CWallet> load_wallet = CreateWallet(
        context, load_wallet_name, /*load_on_start=*/false, initial_options,
        status, error, warnings);
    BOOST_REQUIRE_MESSAGE(load_wallet, error.original);
    BOOST_CHECK(!WalletBatch(load_wallet->GetDatabase(), /*flush_on_close=*/false).HasShadowPowClaimRecoveryPolicy());
    BOOST_CHECK(load_wallet->IsLocked());
    BOOST_REQUIRE(RemoveWallet(context, load_wallet, /*load_on_start=*/false));
    UnloadWallet(std::move(load_wallet));

    SetAutomaticClaimRecoveryArgs(m_args);

    // A wallet created after startup receives the same bounded policy without
    // being left unlocked or having its miner enabled.
    const std::string create_wallet_name{"runtime-create-recovery-seed"};
    DatabaseOptions create_options;
    ReadDatabaseArgs(m_args, create_options);
    create_options.require_create = true;
    create_options.create_flags = WALLET_FLAG_DESCRIPTORS;
    create_options.create_passphrase = SecureString{"runtime-create-passphrase"};
    warnings.clear();
    error.clear();
    std::shared_ptr<CWallet> create_wallet = CreateWallet(
        context, create_wallet_name, /*load_on_start=*/false, create_options,
        status, error, warnings);
    BOOST_REQUIRE_MESSAGE(create_wallet, error.original);
    BOOST_CHECK(create_wallet->GetShadowPowClaimRecoveryPolicy() == ExpectedAutomaticClaimRecoveryPolicy());
    BOOST_CHECK(create_wallet->IsLocked());
    std::unique_ptr<interfaces::Wallet> create_interface = interfaces::MakeWallet(context, create_wallet);
    BOOST_CHECK(!create_interface->getPowMiningInfo().enabled);
    create_interface.reset();

    // The previously created wallet receives the policy when loaded later via
    // the shared runtime LoadWallet path.
    DatabaseOptions load_options;
    ReadDatabaseArgs(m_args, load_options);
    load_options.require_existing = true;
    warnings.clear();
    error.clear();
    load_wallet = LoadWallet(
        context, load_wallet_name, /*load_on_start=*/false, load_options,
        status, error, warnings);
    BOOST_REQUIRE_MESSAGE(load_wallet, error.original);
    BOOST_CHECK(load_wallet->GetShadowPowClaimRecoveryPolicy() == ExpectedAutomaticClaimRecoveryPolicy());
    BOOST_CHECK(load_wallet->IsLocked());
    std::unique_ptr<interfaces::Wallet> load_interface = interfaces::MakeWallet(context, load_wallet);
    BOOST_CHECK(!load_interface->getPowMiningInfo().enabled);
    load_interface.reset();

    BOOST_REQUIRE(RemoveWallet(context, create_wallet, /*load_on_start=*/false));
    UnloadWallet(std::move(create_wallet));
    BOOST_REQUIRE(RemoveWallet(context, load_wallet, /*load_on_start=*/false));
    UnloadWallet(std::move(load_wallet));
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
