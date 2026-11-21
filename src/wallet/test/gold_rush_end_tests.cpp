// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/staking.h>
#include <wallet/test/util.h>
#include <wallet/test/wallet_test_fixture.h>
#include <wallet/wallet.h>
#include <wallet/walletdb.h>

#include <chain.h>
#include <common/args.h>
#include <common/settings.h>
#include <shadow.h>
#include <sync.h>
#include <uint256.h>
#include <univalue.h>
#include <validation.h>

#include <boost/test/unit_test.hpp>

#include <utility>
#include <vector>

namespace wallet {
namespace {

/** Forces the two options the automatic redelegation scan needs and restores
 * them on scope exit. */
struct AutoRedelegateArgs {
    AutoRedelegateArgs()
    {
        gArgs.LockSettings([&](common::Settings& settings) { m_saved = settings; });
        gArgs.ForceSetArg("-qqautoredelegate", "1");
        gArgs.ForceSetArg("-qqallowautokeycreation", "1");
    }
    ~AutoRedelegateArgs()
    {
        gArgs.LockSettings([&](common::Settings& settings) { settings = m_saved; });
    }
    common::Settings m_saved;
};

} // namespace

BOOST_FIXTURE_TEST_SUITE(gold_rush_end_tests, WalletTestingSetup)

static_assert(MAINNET_SHADOW_REWARD_END_HEIGHT == 6192999);

BOOST_AUTO_TEST_CASE(window_closes_exactly_when_the_next_block_is_past_the_end)
{
    // Tip G - 1: the next block, G, still earns a reward.
    BOOST_CHECK(!IsShadowGoldRushWindowClosedAtTip(SHADOW_REWARD_END_HEIGHT - 1));
    // Tip G: the next block, G + 1, is past the window.
    BOOST_CHECK(IsShadowGoldRushWindowClosedAtTip(SHADOW_REWARD_END_HEIGHT));
    BOOST_CHECK(IsShadowGoldRushWindowClosedAtTip(SHADOW_REWARD_END_HEIGHT + 1));
    // No tip is never "closed".
    BOOST_CHECK(!IsShadowGoldRushWindowClosedAtTip(-1));
    // Reading it again after a reorganisation below G flips it back.
    BOOST_CHECK(!IsShadowGoldRushWindowClosedAtTip(SHADOW_REWARD_END_HEIGHT - 3));
}

BOOST_AUTO_TEST_CASE(nothing_is_reserved_before_the_window_closes)
{
    LOCK(m_wallet.cs_wallet);
    const ShadowPowClosedClaimReservation reservation = m_wallet.GetClosedClaimReservationLocked();
    BOOST_CHECK_EQUAL(reservation.amount, 0);
    BOOST_CHECK_EQUAL(reservation.anchors, 0U);
    BOOST_CHECK_EQUAL(reservation.claims, 0U);
}

BOOST_AUTO_TEST_CASE(redelegation_scan_repeats_for_a_competing_tip_at_the_same_height)
{
    const AutoRedelegateArgs args;
    const CBlockIndex* tip = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    const uint256 tip_hash = tip->GetBlockHash();
    const int height = tip->nHeight;

    const auto scan_records = [&] {
        return GetMockableDatabase(m_wallet).m_records.size();
    };

    // The remembered scan belongs to another block at this very height: scan.
    {
        LOCK(m_wallet.cs_wallet);
        m_wallet.m_redelegation_last_auto_scan_height = height;
        m_wallet.m_redelegation_last_auto_scan_tip = uint256::ONE;
    }
    GetMockableDatabase(m_wallet).m_records.clear();
    BOOST_CHECK_EQUAL(MaybeAutoRedelegateQuantumColdStake(m_wallet), 0);
    BOOST_CHECK(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.m_redelegation_last_auto_scan_tip) == tip_hash);
    BOOST_CHECK_EQUAL(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.m_redelegation_last_auto_scan_height), height);
    BOOST_CHECK_EQUAL(scan_records(), 2U);

    // The same tip is skipped: nothing is written again.
    GetMockableDatabase(m_wallet).m_records.clear();
    BOOST_CHECK_EQUAL(MaybeAutoRedelegateQuantumColdStake(m_wallet), 0);
    BOOST_CHECK_EQUAL(scan_records(), 0U);

    // A shorter or longer remembered height with another hash scans again, and
    // so does a remembered height without any hash (an older wallet's record).
    const std::vector<std::pair<int, uint256>> remembered_scans{
        {height + 5, tip_hash}, {height - 1, tip_hash}, {height, uint256{}}};
    for (const auto& [remembered_height, remembered_tip] : remembered_scans) {
        {
            LOCK(m_wallet.cs_wallet);
            m_wallet.m_redelegation_last_auto_scan_height = remembered_height;
            m_wallet.m_redelegation_last_auto_scan_tip = remembered_tip;
        }
        GetMockableDatabase(m_wallet).m_records.clear();
        BOOST_CHECK_EQUAL(MaybeAutoRedelegateQuantumColdStake(m_wallet), 0);
        BOOST_CHECK_EQUAL(scan_records(), 2U);
    }
}

BOOST_AUTO_TEST_CASE(redelegation_scan_tip_record_is_trusted_only_for_its_own_height)
{
    const uint256 hash_at_ten{uint256::ONE};
    MockableData records;
    {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        WalletBatch batch(wallet.GetDatabase());
        BOOST_REQUIRE(batch.WriteQuantumRedelegationAutoScanHeight(10));
        BOOST_REQUIRE(batch.WriteQuantumRedelegationAutoScanTip(10, hash_at_ten));
        records = GetMockableDatabase(wallet).m_records;
    }
    {
        CWallet reloaded(/*chain=*/nullptr, "", CreateMockableWalletDatabase(records));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        LOCK(reloaded.cs_wallet);
        BOOST_CHECK_EQUAL(reloaded.m_redelegation_last_auto_scan_height, 10);
        BOOST_CHECK(reloaded.m_redelegation_last_auto_scan_tip == hash_at_ten);
    }
    // Wallet software of an earlier release advances the height record alone.
    {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase(records));
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        WalletBatch batch(wallet.GetDatabase());
        BOOST_REQUIRE(batch.WriteQuantumRedelegationAutoScanHeight(11));
        records = GetMockableDatabase(wallet).m_records;
    }
    {
        CWallet reloaded(/*chain=*/nullptr, "", CreateMockableWalletDatabase(records));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        LOCK(reloaded.cs_wallet);
        BOOST_CHECK_EQUAL(reloaded.m_redelegation_last_auto_scan_height, 11);
        BOOST_CHECK(reloaded.m_redelegation_last_auto_scan_tip.IsNull());
    }
    // A height record on its own, as every earlier release wrote it.
    {
        CWallet wallet(/*chain=*/nullptr, "", CreateMockableWalletDatabase());
        BOOST_REQUIRE_EQUAL(wallet.LoadWallet(), DBErrors::LOAD_OK);
        WalletBatch batch(wallet.GetDatabase());
        BOOST_REQUIRE(batch.WriteQuantumRedelegationAutoScanHeight(12));
        records = GetMockableDatabase(wallet).m_records;
    }
    {
        CWallet reloaded(/*chain=*/nullptr, "", CreateMockableWalletDatabase(records));
        BOOST_REQUIRE_EQUAL(reloaded.LoadWallet(), DBErrors::LOAD_OK);
        LOCK(reloaded.cs_wallet);
        BOOST_CHECK_EQUAL(reloaded.m_redelegation_last_auto_scan_height, 12);
        BOOST_CHECK(reloaded.m_redelegation_last_auto_scan_tip.IsNull());
    }
}

BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
