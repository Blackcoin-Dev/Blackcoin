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

#include <chrono>
#include <future>
#include <string>
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
            // Each case stands alone: the reorganisation rescan bound is
            // exercised by its own test.
            m_wallet.m_redelegation_last_reorg_scan = {};
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

BOOST_AUTO_TEST_CASE(auto_scan_decision_follows_growth_and_bounds_reorganisation_rescans)
{
    using namespace std::chrono_literals;
    const uint256 tip_a{uint256::ONE};
    const uint256 tip_b{uint256{2}};
    const auto t0 = std::chrono::steady_clock::now();
    std::chrono::steady_clock::time_point last_reorg{};

    // Forward growth always scans, and never counts toward the bound.
    BOOST_CHECK(DecideAutoScan(10, tip_a, 11, tip_b, last_reorg, t0) == AutoScanVerdict::SCAN);
    BOOST_CHECK(last_reorg == std::chrono::steady_clock::time_point{});
    // The very tip already scanned is skipped, however often it is offered.
    BOOST_CHECK(DecideAutoScan(10, tip_a, 10, tip_a, last_reorg, t0) == AutoScanVerdict::SKIP_SAME_TIP);
    // No remembered hash (an older wallet's record, or a reset): scan again.
    BOOST_CHECK(DecideAutoScan(10, uint256{}, 10, tip_a, last_reorg, t0) == AutoScanVerdict::SCAN);
    BOOST_CHECK(last_reorg == std::chrono::steady_clock::time_point{});

    // A competing tip at the same height is a reorganisation: the first scans.
    BOOST_CHECK(DecideAutoScan(10, tip_a, 10, tip_b, last_reorg, t0) == AutoScanVerdict::SCAN);
    BOOST_CHECK(last_reorg == t0);
    // A run of short reorganisations (A, B, A, B, a shorter tip) inside the
    // interval is not rescanned, whatever the order of the tips.
    BOOST_CHECK(DecideAutoScan(10, tip_b, 10, tip_a, last_reorg, t0 + 1s) == AutoScanVerdict::SKIP_REORG_BOUND);
    BOOST_CHECK(DecideAutoScan(10, tip_a, 10, tip_b, last_reorg, t0 + 2s) == AutoScanVerdict::SKIP_REORG_BOUND);
    BOOST_CHECK(DecideAutoScan(10, tip_b, 9, tip_a, last_reorg, t0 + 3s) == AutoScanVerdict::SKIP_REORG_BOUND);
    BOOST_CHECK(last_reorg == t0);
    // A skipped scan is not remembered by the caller, so growth still scans.
    BOOST_CHECK(DecideAutoScan(10, tip_b, 11, tip_a, last_reorg, t0 + 4s) == AutoScanVerdict::SCAN);
    // Once the interval has passed the next reorganisation scans again.
    BOOST_CHECK(DecideAutoScan(10, tip_a, 10, tip_b, last_reorg, t0 + AUTO_SCAN_REORG_MIN_INTERVAL) == AutoScanVerdict::SCAN);
    BOOST_CHECK(last_reorg == t0 + AUTO_SCAN_REORG_MIN_INTERVAL);
}

BOOST_AUTO_TEST_CASE(redelegation_scan_is_bounded_across_a_run_of_different_tips)
{
    const AutoRedelegateArgs args;
    const CBlockIndex* tip = WITH_LOCK(::cs_main, return m_node.chainman->ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    const int height = tip->nHeight;
    const auto scan_records = [&] {
        return GetMockableDatabase(m_wallet).m_records.size();
    };
    const auto remember = [&](const uint256& hash) {
        LOCK(m_wallet.cs_wallet);
        m_wallet.m_redelegation_last_auto_scan_height = height;
        m_wallet.m_redelegation_last_auto_scan_tip = hash;
    };

    // First reorganisation scan runs.
    remember(uint256::ONE);
    GetMockableDatabase(m_wallet).m_records.clear();
    BOOST_CHECK_EQUAL(MaybeAutoRedelegateQuantumColdStake(m_wallet), 0);
    BOOST_CHECK_EQUAL(scan_records(), 2U);

    // The chain flips to other tips and back: no further scan inside the
    // interval, and nothing is written (the remembered tip stays as it was).
    for (const uint256& other : {uint256{2}, uint256{3}, uint256::ONE}) {
        remember(other);
        GetMockableDatabase(m_wallet).m_records.clear();
        BOOST_CHECK_EQUAL(MaybeAutoRedelegateQuantumColdStake(m_wallet), 0);
        BOOST_CHECK_EQUAL(scan_records(), 0U);
        BOOST_CHECK(WITH_LOCK(m_wallet.cs_wallet, return m_wallet.m_redelegation_last_auto_scan_tip) == other);
    }

    // After the interval the next reorganisation scans.
    {
        LOCK(m_wallet.cs_wallet);
        m_wallet.m_redelegation_last_reorg_scan -= AUTO_SCAN_REORG_MIN_INTERVAL + std::chrono::seconds{1};
    }
    GetMockableDatabase(m_wallet).m_records.clear();
    BOOST_CHECK_EQUAL(MaybeAutoRedelegateQuantumColdStake(m_wallet), 0);
    BOOST_CHECK_EQUAL(scan_records(), 2U);
}

BOOST_AUTO_TEST_CASE(explicit_disable_during_end_stop_wins)
{
    // The maintenance thread saw the miner enabled, then an explicit disable
    // completed before it took the authority mutex. The end-stop must not
    // queue an automatic restart over that request.
    m_wallet.m_pow_mining_enabled = true;
    m_wallet.m_pow_threads = 1;
    m_wallet.m_pow_cpu_percent = 10;

    std::promise<void> reached;
    std::promise<void> release;
    std::shared_future<void> release_future = release.get_future().share();
    m_wallet.m_pow_reconcile_test_hook = [&](const char* stage) {
        if (std::string{stage} != "before_end_stop_lock") return;
        reached.set_value();
        release_future.wait();
    };
    auto worker = std::async(std::launch::async, [&] {
        m_wallet.ReconcilePowMinerWithWindowState(/*closed=*/true, /*tip_height=*/SHADOW_REWARD_END_HEIGHT);
    });
    reached.get_future().wait();
    bilingual_str error;
    BOOST_CHECK(m_wallet.SetPowMining(/*enabled=*/false, 1, 10, error));
    release.set_value();
    worker.get();
    m_wallet.m_pow_reconcile_test_hook = nullptr;

    BOOST_CHECK(!m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK(!m_wallet.m_pow_resume_below_end.load());
}

BOOST_AUTO_TEST_CASE(unload_stop_during_end_stop_leaves_no_restart_queued)
{
    // What unloading a wallet does to the miner (FlushWallets stops it) completes while the maintenance thread
    // is poised before taking the authority mutex for the end-stop. The end-stop must find the miner already
    // stopped: no restart is queued over the unload, nothing hangs, and the wallet's miner state is the
    // stopped state. (The interleaving INSIDE the join of the workers cannot be pinned without a hook in
    // StopPowMiningLocked between the stop flag and the join; none exists and none is added here.)
    m_wallet.m_pow_mining_enabled = true;
    m_wallet.m_pow_threads = 1;
    m_wallet.m_pow_cpu_percent = 10;

    std::promise<void> reached;
    std::promise<void> release;
    std::shared_future<void> release_future = release.get_future().share();
    m_wallet.m_pow_reconcile_test_hook = [&](const char* stage) {
        if (std::string{stage} != "before_end_stop_lock") return;
        reached.set_value();
        release_future.wait();
    };
    auto worker = std::async(std::launch::async, [&] {
        m_wallet.ReconcilePowMinerWithWindowState(/*closed=*/true, /*tip_height=*/SHADOW_REWARD_END_HEIGHT);
    });
    reached.get_future().wait();
    m_wallet.StopPowMining();
    m_wallet.StopStake();
    release.set_value();
    worker.get();
    m_wallet.m_pow_reconcile_test_hook = nullptr;

    BOOST_CHECK(!m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK(!m_wallet.m_pow_resume_below_end.load());
}

BOOST_AUTO_TEST_CASE(end_stop_without_interference_queues_the_restart)
{
    m_wallet.m_pow_mining_enabled = true;
    m_wallet.m_pow_threads = 3;
    m_wallet.m_pow_cpu_percent = 40;
    m_wallet.ReconcilePowMinerWithWindowState(/*closed=*/true, SHADOW_REWARD_END_HEIGHT);
    BOOST_CHECK(!m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK(m_wallet.m_pow_resume_below_end.load());
    BOOST_CHECK_EQUAL(m_wallet.m_pow_resume_threads.load(), 3);
    BOOST_CHECK_EQUAL(m_wallet.m_pow_resume_cpu_percent.load(), 40);
}

BOOST_AUTO_TEST_CASE(explicit_disable_between_restart_decision_and_enable_wins)
{
    // The restart is queued and the maintenance thread has decided to act on
    // it. An explicit disable completes before the automatic enable publishes:
    // the automatic restart must be refused.
    m_wallet.m_pow_resume_below_end = true;
    m_wallet.m_pow_resume_threads = 1;
    m_wallet.m_pow_resume_cpu_percent = 10;
    const uint64_t refused_before = m_wallet.m_pow_auto_restart_refusals.load();

    std::promise<void> reached;
    std::promise<void> release;
    std::shared_future<void> release_future = release.get_future().share();
    m_wallet.m_pow_reconcile_test_hook = [&](const char* stage) {
        if (std::string{stage} != "before_restart") return;
        reached.set_value();
        release_future.wait();
    };
    auto worker = std::async(std::launch::async, [&] {
        m_wallet.ReconcilePowMinerWithWindowState(/*closed=*/false, SHADOW_REWARD_END_HEIGHT - 5);
    });
    reached.get_future().wait();
    bilingual_str error;
    BOOST_CHECK(m_wallet.SetPowMining(/*enabled=*/false, 1, 10, error));
    release.set_value();
    worker.get();
    m_wallet.m_pow_reconcile_test_hook = nullptr;

    BOOST_CHECK_EQUAL(m_wallet.m_pow_auto_restart_refusals.load(), refused_before + 1);
    BOOST_CHECK(!m_wallet.m_pow_mining_enabled.load());
    BOOST_CHECK(!m_wallet.m_pow_resume_below_end.load());
}

BOOST_AUTO_TEST_CASE(restart_proceeds_when_no_explicit_request_intervenes)
{
    m_wallet.m_pow_resume_below_end = true;
    m_wallet.m_pow_resume_threads = 1;
    m_wallet.m_pow_resume_cpu_percent = 10;
    const uint64_t refused_before = m_wallet.m_pow_auto_restart_refusals.load();
    m_wallet.ReconcilePowMinerWithWindowState(/*closed=*/false, SHADOW_REWARD_END_HEIGHT - 5);
    // The consent was intact, so the restart was attempted and consumed the
    // queue (this wallet has no keys, so the miner itself cannot start).
    BOOST_CHECK_EQUAL(m_wallet.m_pow_auto_restart_refusals.load(), refused_before);
    BOOST_CHECK(!m_wallet.m_pow_resume_below_end.load());
}


BOOST_AUTO_TEST_SUITE_END()
} // namespace wallet
