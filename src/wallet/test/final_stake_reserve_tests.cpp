// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <addresstype.h>
#include <chain.h>
#include <chainparams.h>
#include <common/args.h>
#include <consensus/params.h>
#include <crypto/sha256.h>
#include <common/settings.h>
#include <interfaces/wallet.h>
#include <key_io.h>
#include <primitives/transaction.h>
#include <script/script.h>
#include <test/util/setup_common.h>
#include <txmempool.h>
#include <validation.h>
#include <wallet/coincontrol.h>
#include <wallet/context.h>
#include <wallet/quantum_stake_ops.h>
#include <wallet/spend.h>
#include <wallet/staking.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

#include <util/time.h>
#include <univalue.h>
#include <util/strencodings.h>

#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace wallet {
namespace {

Consensus::Params HeightSchedule(int goldrush_end, int migration_end, int maturity)
{
    Consensus::Params p;
    p.nQuantumLifecycleStartHeight = 1;
    p.nGoldRushEndHeight = goldrush_end;
    p.nQuantumMigrationEndHeight = migration_end;
    p.nCoinbaseMaturity = maturity;
    return p;
}

COutPoint Out(uint8_t first_byte, uint32_t n = 0)
{
    return COutPoint{uint256{first_byte}, n};
}

std::vector<FinalStakeReserveSource> Sources(size_t count, CAmount value = COIN)
{
    std::vector<FinalStakeReserveSource> sources;
    for (size_t i = 0; i < count; ++i) {
        sources.push_back({COutPoint{uint256{static_cast<uint8_t>(i % 200 + 1)}, static_cast<uint32_t>(i / 200)}, value});
    }
    return sources;
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(final_stake_reserve_tests, TestChain100Setup)

// The count-based part of the rule: R = min(32, ceil(N / 2)) for N >= 2. For N == 1 the helper's value 1 is the target
// when the single source is held; whether it is held is the outpoint's rule (see the singleton tests below).
BOOST_AUTO_TEST_CASE(the_target_is_half_rounded_up_and_capped_at_32)
{
    BOOST_CHECK_EQUAL(FinalStakeReserveTarget(0), 0);
    BOOST_CHECK_EQUAL(FinalStakeReserveTarget(1), 1);
    BOOST_CHECK_EQUAL(FinalStakeReserveTarget(2), 1);
    BOOST_CHECK_EQUAL(FinalStakeReserveTarget(3), 2);
    BOOST_CHECK_EQUAL(FinalStakeReserveTarget(63), 32);
    BOOST_CHECK_EQUAL(FinalStakeReserveTarget(64), 32);
    BOOST_CHECK_EQUAL(FinalStakeReserveTarget(65), 32);
    BOOST_CHECK_EQUAL(FinalStakeReserveTarget(100000), 32);
    BOOST_CHECK_EQUAL(FinalStakeReserveTarget(-4), 0);
    // No signed overflow at the top of the range.
    BOOST_CHECK_EQUAL(FinalStakeReserveTarget(std::numeric_limits<int64_t>::max()), 32);
    BOOST_CHECK_EQUAL(FinalStakeReserveTarget(std::numeric_limits<int64_t>::max() - 1), 32);
}

// The singleton rule: one SHA-256 over the tag, the 32 hash bytes and the output index as four little-endian bytes;
// held when the last digest byte is odd.
BOOST_AUTO_TEST_CASE(the_singleton_rule_matches_the_published_vectors)
{
    const auto digest_hex = [](const uint256& txid, uint32_t vout) {
        static const std::string tag{"BLK final stake reserve v1"};
        unsigned char out[CSHA256::OUTPUT_SIZE];
        const unsigned char le[4] = {static_cast<unsigned char>(vout), static_cast<unsigned char>(vout >> 8),
                                     static_cast<unsigned char>(vout >> 16), static_cast<unsigned char>(vout >> 24)};
        CSHA256().Write(reinterpret_cast<const unsigned char*>(tag.data()), tag.size()).Write(txid.data(), 32).Write(le, 4).Finalize(out);
        return HexStr(Span<const unsigned char>{out, sizeof(out)});
    };
    const uint256 zero;
    BOOST_CHECK_EQUAL(digest_hex(zero, 0), "9162afdf0fe267f79b7ed75d96a048255f214b7e7d70fdba4fdab4800812ffcc");
    BOOST_CHECK_EQUAL(digest_hex(zero, 3), "a951e84e54231b9430fecccde215c0c9b65602f36e56d643c4ce94ec7ba581e5");
    BOOST_CHECK(!SingleOutputReserveBit(COutPoint{zero, 0})); // last byte 0xcc: released
    BOOST_CHECK(SingleOutputReserveBit(COutPoint{zero, 3}));  // last byte 0xe5: held
    // Pure and repeatable.
    for (int i = 0; i < 3; ++i) {
        BOOST_CHECK(!SingleOutputReserveBit(COutPoint{zero, 0}));
        BOOST_CHECK(SingleOutputReserveBit(COutPoint{zero, 3}));
    }
    // The hash bytes are in serialization order, not displayed order: uint256{1} has its first byte set. The values below
    // were computed independently of the code under test.
    BOOST_CHECK(SingleOutputReserveBit(Out(1, 0)));
    BOOST_CHECK(!SingleOutputReserveBit(Out(2, 0)));
    BOOST_CHECK(SingleOutputReserveBit(Out(2, 7)));
    BOOST_CHECK(!SingleOutputReserveBit(Out(3, 3)));
    BOOST_CHECK(SingleOutputReserveBit(Out(3, 5)));
    // The output index changes the digest.
    bool differs{false};
    for (uint32_t n = 1; n < 16; ++n) differs |= SingleOutputReserveBit(COutPoint{zero, n}) != SingleOutputReserveBit(COutPoint{zero, 0});
    BOOST_CHECK(differs);
}

// The one reader of -finalstakereserve: the default when unset, the parsed boolean, or the text of a programmatic setting.
BOOST_AUTO_TEST_CASE(the_option_reader_takes_the_stored_value_and_the_default_when_unset)
{
    const auto clear = [] { gArgs.LockSettings([](common::Settings& settings) { settings.forced_settings.erase("finalstakereserve"); }); };
    clear();
    BOOST_CHECK(DEFAULT_FINAL_STAKE_RESERVE);
    BOOST_CHECK_EQUAL(FinalStakeReserveOptionEnabled(), DEFAULT_FINAL_STAKE_RESERVE);
    const std::vector<std::pair<std::string, bool>> texts{{"", true}, {"1", true}, {"0", false}, {"true", true}, {"false", false}, {"TRUE", true}, {"False", false}};
    for (const auto& [text, expected] : texts) {
        gArgs.ForceSetArg("-finalstakereserve", text);
        BOOST_CHECK_MESSAGE(FinalStakeReserveOptionEnabled() == expected, "text '" + text + "'");
    }
    for (const bool value : {true, false}) {
        gArgs.LockSettings([&](common::Settings& settings) { settings.forced_settings["finalstakereserve"] = value; });
        BOOST_CHECK_EQUAL(FinalStakeReserveOptionEnabled(), value);
    }
    clear();
}

BOOST_AUTO_TEST_CASE(a_single_source_is_held_or_released_by_its_outpoint)
{
    const COutPoint held{uint256{}, 3};
    const COutPoint released{uint256{}, 0};
    {
        const FinalStakeReservePlan plan = PlanFinalStakeReserve({{held, COIN}}, {});
        BOOST_CHECK_EQUAL(plan.n, 1);
        BOOST_CHECK(plan.single_output);
        BOOST_CHECK(plan.single_output_held);
        BOOST_CHECK_EQUAL(plan.target, 1);
        BOOST_REQUIRE_EQUAL(plan.reserved.size(), 1U);
        BOOST_CHECK(plan.reserved[0].outpoint == held);
        BOOST_CHECK_EQUAL(plan.shortfall, 0);
    }
    {
        const FinalStakeReservePlan plan = PlanFinalStakeReserve({{released, COIN}}, {});
        BOOST_CHECK_EQUAL(plan.n, 1);
        BOOST_CHECK(plan.single_output);
        BOOST_CHECK(!plan.single_output_held);
        BOOST_CHECK_EQUAL(plan.target, 0);
        BOOST_CHECK(plan.reserved.empty());
        BOOST_CHECK_EQUAL(plan.shortfall, 0);
    }
    // A source consumed by the wallet's own coinstake with nothing unspent left is still the one source: a held one is a
    // shortfall of one, a released one asks for nothing.
    {
        const FinalStakeReservePlan plan = PlanFinalStakeReserve({}, {held});
        BOOST_CHECK_EQUAL(plan.n, 1);
        BOOST_CHECK(plan.single_output_held);
        BOOST_CHECK_EQUAL(plan.target, 1);
        BOOST_CHECK(plan.reserved.empty());
        BOOST_CHECK_EQUAL(plan.shortfall, 1);
    }
    {
        const FinalStakeReservePlan plan = PlanFinalStakeReserve({}, {released});
        BOOST_CHECK_EQUAL(plan.n, 1);
        BOOST_CHECK(!plan.single_output_held);
        BOOST_CHECK_EQUAL(plan.target, 0);
        BOOST_CHECK_EQUAL(plan.shortfall, 0);
    }
    // The same outpoint in both sets, or repeated, is one source and takes the singleton rule.
    {
        const FinalStakeReservePlan plan = PlanFinalStakeReserve({{held, COIN}, {held, 2 * COIN}}, {held});
        BOOST_CHECK_EQUAL(plan.n, 1);
        BOOST_CHECK(plan.single_output);
        BOOST_CHECK_EQUAL(plan.target, 1);
        BOOST_CHECK_EQUAL(plan.reserved.size(), 1U);
        BOOST_CHECK_EQUAL(plan.shortfall, 0);
    }
    // Two distinct sources are never decided by the singleton rule, whatever their own bits are.
    for (const COutPoint& a : {held, released}) {
        for (const COutPoint& b : {COutPoint{uint256{}, 1}, COutPoint{uint256{}, 2}}) {
            const FinalStakeReservePlan plan = PlanFinalStakeReserve({{a, COIN}, {b, COIN}}, {});
            BOOST_CHECK_EQUAL(plan.n, 2);
            BOOST_CHECK(!plan.single_output);
            BOOST_CHECK_EQUAL(plan.target, 1);
            BOOST_CHECK_EQUAL(plan.reserved.size(), 1U);
        }
    }
    // A released source that staked, with its new return mature at F: the new output is unspent, the old is consumed.
    {
        const FinalStakeReservePlan plan = PlanFinalStakeReserve({{COutPoint{uint256{}, 1}, COIN}}, {released});
        BOOST_CHECK_EQUAL(plan.n, 2);
        BOOST_CHECK(!plan.single_output);
        BOOST_CHECK_EQUAL(plan.target, 1);
        BOOST_CHECK_EQUAL(plan.reserved.size(), 1U);
    }
}

BOOST_AUTO_TEST_CASE(the_plan_for_the_boundary_source_counts)
{
    // Sources(1) is the outpoint (uint256{1}, 0), whose singleton bit is set (held): target 1. The other counts follow the
    // count rule.
    BOOST_REQUIRE(SingleOutputReserveBit(Sources(1).front().outpoint));
    const std::vector<std::pair<size_t, int64_t>> expected{{0, 0}, {1, 1}, {2, 1}, {3, 2}, {63, 32}, {64, 32}, {65, 32}};
    for (const auto& [n, target] : expected) {
        const FinalStakeReservePlan plan = PlanFinalStakeReserve(Sources(n), {});
        BOOST_CHECK_EQUAL(plan.n, static_cast<int64_t>(n));
        BOOST_CHECK_EQUAL(plan.target, target);
        BOOST_CHECK_EQUAL(static_cast<int64_t>(plan.reserved.size()), target);
        BOOST_CHECK_EQUAL(plan.shortfall, 0);
        BOOST_CHECK_EQUAL(plan.single_output, n == 1);
    }
}

// Sources already consumed by the wallet's coinstakes stay in N, so the reserve does not shrink as the wallet stakes.
BOOST_AUTO_TEST_CASE(consumed_sources_keep_the_target_and_a_short_supply_is_a_reported_shortfall)
{
    std::set<COutPoint> consumed;
    for (const FinalStakeReserveSource& source : Sources(61, 2 * COIN)) consumed.insert(source.outpoint);
    // Distinct from the consumed outpoints (they are given other outputs of the same transactions).
    std::vector<FinalStakeReserveSource> unspent;
    for (uint32_t i = 0; i < 3; ++i) unspent.push_back({Out(static_cast<uint8_t>(210 + i), 7), COIN});
    const FinalStakeReservePlan plan = PlanFinalStakeReserve(unspent, consumed);
    BOOST_CHECK_EQUAL(plan.n, 64);
    BOOST_CHECK_EQUAL(plan.target, 32);
    BOOST_CHECK_EQUAL(plan.reserved.size(), 3U);
    BOOST_CHECK_EQUAL(plan.shortfall, 29);

    // Nothing left unspent: all of the target is a shortfall.
    const FinalStakeReservePlan none = PlanFinalStakeReserve({}, consumed);
    BOOST_CHECK_EQUAL(none.n, 61);
    BOOST_CHECK(none.reserved.empty());
    BOOST_CHECK_EQUAL(none.shortfall, 31);
}

BOOST_AUTO_TEST_CASE(an_outpoint_in_both_sets_and_a_repeated_outpoint_count_once)
{
    const std::vector<FinalStakeReserveSource> unspent{{Out(1), COIN}, {Out(1), COIN}, {Out(2), 3 * COIN}};
    const std::set<COutPoint> consumed{Out(2), Out(3)};
    const FinalStakeReservePlan plan = PlanFinalStakeReserve(unspent, consumed);
    BOOST_CHECK_EQUAL(plan.n, 3); // 1, 2 and 3
    BOOST_CHECK_EQUAL(plan.target, 2);
    BOOST_REQUIRE_EQUAL(plan.reserved.size(), 2U);
    BOOST_CHECK(plan.reserved[0].outpoint == Out(2));
    BOOST_CHECK(plan.reserved[1].outpoint == Out(1));
}

// Largest effective value at F first; equal values by transaction hash, then output index, both ascending.
BOOST_AUTO_TEST_CASE(the_reserve_order_is_value_then_hash_then_index)
{
    std::vector<FinalStakeReserveSource> unspent{
        {Out(9, 1), 5 * COIN}, {Out(9, 0), 5 * COIN}, {Out(4, 3), 5 * COIN}, {Out(200, 0), 9 * COIN},
        {Out(1, 0), COIN},     {Out(2, 0), COIN},     {Out(3, 0), COIN},     {Out(5, 0), 7 * COIN},
    };
    const FinalStakeReservePlan plan = PlanFinalStakeReserve(unspent, {});
    BOOST_CHECK_EQUAL(plan.n, 8);
    BOOST_CHECK_EQUAL(plan.target, 4);
    BOOST_REQUIRE_EQUAL(plan.reserved.size(), 4U);
    BOOST_CHECK(plan.reserved[0].outpoint == Out(200, 0));
    BOOST_CHECK(plan.reserved[1].outpoint == Out(5, 0));
    // Tie at 5 COIN: the smaller transaction hash first. uint256{4} and uint256{9} order by their bytes.
    const bool four_before_nine = Out(4, 3) < Out(9, 0);
    BOOST_CHECK(plan.reserved[2].outpoint == (four_before_nine ? Out(4, 3) : Out(9, 0)));
    BOOST_CHECK(plan.reserved[3].outpoint == (four_before_nine ? Out(9, 0) : Out(4, 3)));
    // The same input in any order gives the same reserve.
    std::reverse(unspent.begin(), unspent.end());
    const FinalStakeReservePlan reversed = PlanFinalStakeReserve(unspent, {});
    BOOST_REQUIRE_EQUAL(reversed.reserved.size(), plan.reserved.size());
    for (size_t i = 0; i < plan.reserved.size(); ++i) BOOST_CHECK(reversed.reserved[i].outpoint == plan.reserved[i].outpoint);
    // Equal value and equal hash: the lower index first.
    const FinalStakeReservePlan same_hash = PlanFinalStakeReserve({{Out(9, 1), COIN}, {Out(9, 0), COIN}}, {});
    BOOST_REQUIRE_EQUAL(same_hash.reserved.size(), 1U);
    BOOST_CHECK(same_hash.reserved[0].outpoint == Out(9, 0));
}

// The guard runs for F - maturity <= h <= M and is released for candidate F (= M + 1).
BOOST_AUTO_TEST_CASE(the_guard_boundaries_on_the_mainnet_heights)
{
    const Consensus::Params mainnet = HeightSchedule(6192999, 6921999, 500);
    BOOST_CHECK(!IsFinalStakeReserveGuardActive(mainnet, 6921499)); // F - C - 1
    BOOST_CHECK(IsFinalStakeReserveGuardActive(mainnet, 6921500));  // F - C
    BOOST_CHECK(IsFinalStakeReserveGuardActive(mainnet, 6921501));
    BOOST_CHECK(IsFinalStakeReserveGuardActive(mainnet, 6921999));  // M
    BOOST_CHECK(!IsFinalStakeReserveGuardActive(mainnet, 6922000)); // F
    BOOST_CHECK(!IsFinalStakeReserveGuardActive(mainnet, 6922001));
    BOOST_CHECK(!IsFinalStakeReserveGuardActive(mainnet, 1));

    // Regtest shape of the functional tests: M = 91, maturity 10.
    const Consensus::Params regtest = HeightSchedule(61, 91, 10);
    BOOST_CHECK(!IsFinalStakeReserveGuardActive(regtest, 81));
    BOOST_CHECK(IsFinalStakeReserveGuardActive(regtest, 82));
    BOOST_CHECK(IsFinalStakeReserveGuardActive(regtest, 91));
    BOOST_CHECK(!IsFinalStakeReserveGuardActive(regtest, 92));

    // No complete height schedule: no guard.
    BOOST_CHECK(!IsFinalStakeReserveGuardActive(Consensus::Params{}, 6921700));
    Consensus::Params time_only;
    time_only.nGoldRushEndTime = 1000;
    time_only.nQuantumMigrationDeadlineTime = 2000;
    BOOST_CHECK(!IsFinalStakeReserveGuardActive(time_only, 6921700));
}

// The opportunistic window is max(first Migration height, F - 10 * maturity) through the height before the mandatory
// window, and never reads the mandatory predicate.
BOOST_AUTO_TEST_CASE(the_opportunistic_window_boundaries_on_the_mainnet_heights)
{
    const Consensus::Params mainnet = HeightSchedule(6192999, 6921999, 500);
    BOOST_REQUIRE(FirstOpportunisticLegacyReturnHeight(mainnet).has_value());
    BOOST_CHECK_EQUAL(*FirstOpportunisticLegacyReturnHeight(mainnet), 6917000);
    BOOST_CHECK(!IsLegacyStakeInOpportunisticReturnWindow(mainnet, 6916999)); // start - 1
    BOOST_CHECK(IsLegacyStakeInOpportunisticReturnWindow(mainnet, 6917000));  // start
    BOOST_CHECK(IsLegacyStakeInOpportunisticReturnWindow(mainnet, 6921498));  // mandatory start - 1
    BOOST_CHECK(!IsLegacyStakeInOpportunisticReturnWindow(mainnet, 6921499)); // mandatory start
    BOOST_CHECK(!IsLegacyStakeInOpportunisticReturnWindow(mainnet, 6921999)); // M
    BOOST_CHECK(!IsLegacyStakeInOpportunisticReturnWindow(mainnet, 6922000)); // F
    // The mandatory predicate is the one it always was: the two windows are disjoint and adjacent.
    BOOST_CHECK(!IsLegacyStakeBarredByMigrationEnd(mainnet, 6921498));
    BOOST_CHECK(IsLegacyStakeBarredByMigrationEnd(mainnet, 6921499));
    BOOST_CHECK(!IsLegacyStakeBarredByMigrationEnd(mainnet, 6917000));
    for (int h : {6917000, 6919000, 6921498, 6921499, 6921999, 6922000}) {
        BOOST_CHECK(!(IsLegacyStakeInOpportunisticReturnWindow(mainnet, h) && IsLegacyStakeBarredByMigrationEnd(mainnet, h)));
    }
}

BOOST_AUTO_TEST_CASE(the_opportunistic_window_never_starts_before_the_first_migration_block)
{
    // G = 61, M = 91, maturity 10: F - 100 is far before the first Migration block 62.
    const Consensus::Params regtest = HeightSchedule(61, 91, 10);
    BOOST_CHECK_EQUAL(*FirstOpportunisticLegacyReturnHeight(regtest), 62);
    BOOST_CHECK(!IsLegacyStakeInOpportunisticReturnWindow(regtest, 61));
    BOOST_CHECK(IsLegacyStakeInOpportunisticReturnWindow(regtest, 62));
    BOOST_CHECK(IsLegacyStakeInOpportunisticReturnWindow(regtest, 80)); // last legacy-return height
    BOOST_CHECK(!IsLegacyStakeInOpportunisticReturnWindow(regtest, 81));

    // A schedule where F - 10 * maturity is after the first Migration block.
    const Consensus::Params later = HeightSchedule(61, 300, 10);
    BOOST_CHECK_EQUAL(*FirstOpportunisticLegacyReturnHeight(later), 201);
    BOOST_CHECK(!IsLegacyStakeInOpportunisticReturnWindow(later, 200));
    BOOST_CHECK(IsLegacyStakeInOpportunisticReturnWindow(later, 201));

    // No schedule, no window.
    BOOST_CHECK(!FirstOpportunisticLegacyReturnHeight(Consensus::Params{}).has_value());
    BOOST_CHECK(!IsLegacyStakeInOpportunisticReturnWindow(Consensus::Params{}, 6917000));
}

namespace {
/** A mock wallet that holds quantum keys of its own. */
std::unique_ptr<CWallet> NewMockWallet(interfaces::Chain& chain)
{
    auto wallet = std::make_unique<CWallet>(&chain, "", CreateMockableWalletDatabase());
    wallet->LoadWallet();
    LOCK(wallet->cs_wallet);
    wallet->SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
    wallet->SetupDescriptorScriptPubKeyMans();
    return wallet;
}

std::vector<unsigned char> PublicKeyOf(CWallet& wallet, const CTxDestination& dest)
{
    LOCK(wallet.cs_wallet);
    const auto info = wallet.GetQuantumKeyInfo(dest);
    BOOST_REQUIRE(info);
    return info->public_key;
}
} // namespace

// A v16 output counts when the wallet holds its key; a v14 cold-stake output counts only when the wallet holds the
// STAKER key (the owner key alone cannot stake); a legacy script never counts.
BOOST_AUTO_TEST_CASE(a_cold_stake_output_counts_only_with_the_staker_key)
{
    auto wallet = NewMockWallet(*m_node.chain);
    auto other = NewMockWallet(*m_node.chain);
    const auto own_dest = wallet->GetNewQuantumDestination("own");
    const auto foreign_dest = other->GetNewQuantumDestination("foreign");
    BOOST_REQUIRE(own_dest && foreign_dest);
    const std::vector<unsigned char> own_key = PublicKeyOf(*wallet, *own_dest);
    const std::vector<unsigned char> foreign_key = PublicKeyOf(*other, *foreign_dest);

    // Staker-side only: the wallet's key stakes, the owner key belongs to somebody else.
    const auto staker_only = wallet->AddQuantumColdStakeDelegation(own_key, foreign_key, "staker-only", GetTime());
    // Owner-side only: the wallet owns the funds and delegates staking to somebody else.
    const auto owner_only = wallet->AddQuantumColdStakeDelegation(foreign_key, own_key, "owner-only", GetTime());
    BOOST_REQUIRE(staker_only && owner_only);

    LOCK(wallet->cs_wallet);
    BOOST_CHECK(IsFinalStakeReserveSourceScript(*wallet, GetScriptForDestination(*own_dest)));
    BOOST_CHECK(!IsFinalStakeReserveSourceScript(*wallet, GetScriptForDestination(*foreign_dest)));
    BOOST_CHECK(IsFinalStakeReserveSourceScript(*wallet, GetScriptForDestination(*staker_only)));
    BOOST_CHECK(!IsFinalStakeReserveSourceScript(*wallet, GetScriptForDestination(*owner_only)));
    BOOST_CHECK(!IsFinalStakeReserveSourceScript(*wallet, GetScriptForDestination(PKHash(coinbaseKey.GetPubKey()))));
}

namespace {
CTransactionRef Paying(const std::vector<CTxOut>& outputs, uint32_t salt)
{
    CMutableTransaction tx;
    tx.vin.emplace_back(COutPoint{uint256{static_cast<uint8_t>(salt)}, salt});
    tx.vout = outputs;
    return MakeTransactionRef(std::move(tx));
}

CTransactionRef CoinstakeSpending(const std::vector<COutPoint>& inputs, const CScript& pay_to, uint32_t salt)
{
    CMutableTransaction tx;
    tx.nTime = salt;
    for (const COutPoint& input : inputs) tx.vin.emplace_back(input);
    tx.vout.emplace_back(0, CScript());
    tx.vout.emplace_back(10 * COIN + salt, pay_to);
    BOOST_REQUIRE(tx.vin[0].prevout.IsNull() == false);
    return MakeTransactionRef(std::move(tx));
}
} // namespace

// S counts every qualifying input of the wallet's coinstakes that are confirmed on the active chain in the guard
// range; it ignores orphaned, abandoned and unconfirmed coinstakes and sources created too late to be mature at F.
BOOST_AUTO_TEST_CASE(consumed_sources_are_the_inputs_of_confirmed_coinstakes_in_the_guard_range)
{
    auto wallet = CreateSyncedWallet(*m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    const auto dest = wallet->GetNewQuantumDestination("source");
    BOOST_REQUIRE(dest);
    const CScript quantum = GetScriptForDestination(*dest);
    const CScript legacy = GetScriptForDestination(PKHash(coinbaseKey.GetPubKey()));

    std::vector<uint256> blocks(101);
    {
        LOCK(::cs_main);
        for (int h = 1; h <= 100; ++h) blocks[static_cast<size_t>(h)] = m_node.chainman->ActiveChain()[h]->GetBlockHash();
    }
    const auto confirmed = [&](int height) { return TxStateConfirmed{blocks[static_cast<size_t>(height)], height, 0}; };

    // Sources: created at 40 and 41 (old enough), at 70 (too late for last_source_height 60), plus one legacy output
    // and one output of too little value. Every source has one output and an extra, so inputs are not only kernels.
    const CTransactionRef old_a = Paying({CTxOut{COIN * 10, quantum}, CTxOut{COIN * 10, quantum}}, 1);
    const CTransactionRef old_b = Paying({CTxOut{COIN * 10, quantum}}, 2);
    const CTransactionRef late = Paying({CTxOut{COIN * 10, quantum}}, 3);
    const CTransactionRef legacy_source = Paying({CTxOut{COIN * 10, legacy}}, 4);
    const CTransactionRef dust_source = Paying({CTxOut{1, quantum}}, 5);
    CWalletTx* wtx_old_a{nullptr};
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        wtx_old_a = wallet->AddToWallet(old_a, confirmed(40));
        BOOST_REQUIRE(wtx_old_a);
        BOOST_REQUIRE(wallet->AddToWallet(old_b, confirmed(41)));
        BOOST_REQUIRE(wallet->AddToWallet(late, confirmed(70)));
        BOOST_REQUIRE(wallet->AddToWallet(legacy_source, confirmed(42)));
        BOOST_REQUIRE(wallet->AddToWallet(dust_source, confirmed(43)));
    }

    const COutPoint a0{old_a->GetHash(), 0}, a1{old_a->GetHash(), 1}, b0{old_b->GetHash(), 0}, l0{late->GetHash(), 0};
    const COutPoint leg0{legacy_source->GetHash(), 0}, dust0{dust_source->GetHash(), 0};

    // A confirmed coinstake at height 65 with two qualifying inputs and three that do not qualify.
    const CTransactionRef coinstake_in_range = CoinstakeSpending({a0, a1, l0, leg0, dust0}, quantum, 10);
    // The same shape, but only unconfirmed, inactive (orphaned) and abandoned: all ignored.
    const CTransactionRef unconfirmed = CoinstakeSpending({b0}, quantum, 11);
    const CTransactionRef orphaned = CoinstakeSpending({b0}, quantum, 12);
    const CTransactionRef abandoned = CoinstakeSpending({b0}, quantum, 13);
    // A confirmed coinstake before the guard began: also ignored.
    const CTransactionRef early = CoinstakeSpending({b0}, quantum, 14);
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_REQUIRE(wallet->AddToWallet(coinstake_in_range, confirmed(65)));
        BOOST_REQUIRE(wallet->AddToWallet(unconfirmed, TxStateInMempool{}));
        BOOST_REQUIRE(wallet->AddToWallet(orphaned, TxStateInactive{}));
        BOOST_REQUIRE(wallet->AddToWallet(abandoned, TxStateInactive{/*abandoned=*/true}));
        BOOST_REQUIRE(wallet->AddToWallet(early, confirmed(55)));
    }

    LOCK2(::cs_main, wallet->cs_wallet);
    std::set<COutPoint> consumed = FinalStakeReserveConsumedSources(*wallet, /*first_guard_height=*/60, /*last_height=*/100, /*last_source_height=*/60);
    BOOST_CHECK(consumed == (std::set<COutPoint>{a0, a1}));

    // A coinstake after the last Migration block is not counted either.
    consumed = FinalStakeReserveConsumedSources(*wallet, 60, /*last_height=*/64, 60);
    BOOST_CHECK(consumed.empty());

    // Once the confirmed coinstake is replaced by a reorganisation (it becomes inactive), its inputs leave S.
    {
        BOOST_REQUIRE(wallet->AddToWallet(coinstake_in_range, TxStateInactive{}));
    }
    BOOST_CHECK(FinalStakeReserveConsumedSources(*wallet, 60, 100, 60).empty());
}

namespace {
class ScheduledSetup : public TestChain100Setup
{
public:
    explicit ScheduledSetup(const char* migration_end_arg)
        : TestChain100Setup{ChainType::REGTEST, {
              "-shadowwhitelistheight=20",
              "-shadowgoldrushstartheight=30",
              "-shadowgoldrushendheight=60",
              "-qqgoldrushendheight=60",
              migration_end_arg,
          }}
    {
    }
    ~ScheduledSetup() { gArgs.ForceSetArg("-finalstakereserve", "1"); }
};
// Chain height 100, so the candidate is 101 and maturity is 10: the guard runs for F-10 <= h <= M.
struct CandidateBeforeGuard : ScheduledSetup { CandidateBeforeGuard() : ScheduledSetup{"-qqmigrationendheight=111"} {} }; // F-C = 102
struct CandidateAtGuardStart : ScheduledSetup { CandidateAtGuardStart() : ScheduledSetup{"-qqmigrationendheight=110"} {} }; // F-C = 101
struct CandidateAtLastMigration : ScheduledSetup { CandidateAtLastMigration() : ScheduledSetup{"-qqmigrationendheight=101"} {} }; // M = 101
struct CandidateAtFinal : ScheduledSetup { CandidateAtFinal() : ScheduledSetup{"-qqmigrationendheight=100"} {} }; // F = 101

FinalStakeReserve ReserveOf(CWallet& wallet)
{
    LOCK2(::cs_main, wallet.cs_wallet);
    return ComputeFinalStakeReserve(wallet);
}
} // namespace

BOOST_FIXTURE_TEST_CASE(the_reserve_is_off_before_the_guard, CandidateBeforeGuard)
{
    auto wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    const FinalStakeReserve reserve = ReserveOf(*wallet);
    BOOST_CHECK(reserve.enabled);
    BOOST_CHECK(reserve.schedule_known);
    BOOST_CHECK(!reserve.active); // candidate 101 = F - C - 1
    BOOST_CHECK_EQUAL(reserve.final_height, 112);
    BOOST_CHECK_EQUAL(reserve.guard_first_height, 102);
    BOOST_CHECK(reserve.enforced.empty());
    LOCK2(::cs_main, wallet->cs_wallet);
    BOOST_CHECK(FinalStakeReserveEnforcedOutpoints(*wallet).empty());
}

BOOST_FIXTURE_TEST_CASE(the_reserve_is_on_at_the_first_guard_height, CandidateAtGuardStart)
{
    auto wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    const FinalStakeReserve reserve = ReserveOf(*wallet);
    BOOST_CHECK(reserve.active); // candidate 101 = F - C
    BOOST_CHECK_EQUAL(reserve.guard_first_height, 101);
    BOOST_CHECK_EQUAL(reserve.n, 0); // a legacy-only wallet has no quantum source
    BOOST_CHECK_EQUAL(reserve.target, 0);
}

BOOST_FIXTURE_TEST_CASE(the_reserve_is_on_at_the_last_migration_block, CandidateAtLastMigration)
{
    auto wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    BOOST_CHECK(ReserveOf(*wallet).active); // candidate 101 = M
}

BOOST_FIXTURE_TEST_CASE(the_reserve_is_released_for_the_first_final_block, CandidateAtFinal)
{
    auto wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    const FinalStakeReserve reserve = ReserveOf(*wallet);
    BOOST_CHECK(!reserve.active); // candidate 101 = F
    BOOST_CHECK(reserve.enforced.empty());
}

BOOST_FIXTURE_TEST_CASE(the_option_turns_the_reserve_off, CandidateAtGuardStart)
{
    auto wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    BOOST_CHECK(ReserveOf(*wallet).active);
    gArgs.ForceSetArg("-finalstakereserve", "0");
    const FinalStakeReserve off = ReserveOf(*wallet);
    BOOST_CHECK(!off.enabled);
    BOOST_CHECK(!off.active);
    BOOST_CHECK(off.enforced.empty());
    LOCK2(::cs_main, wallet->cs_wallet);
    BOOST_CHECK(FinalStakeReserveEnforcedOutpoints(*wallet).empty());
}

// The staker's cached selection is only valid under the reserve policy it was built with.
BOOST_FIXTURE_TEST_CASE(a_policy_change_invalidates_the_cached_selection, CandidateAtGuardStart)
{
    auto wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    LOCK2(::cs_main, wallet->cs_wallet);
    CBlockIndex* tip = wallet->chain().getTip();
    BOOST_REQUIRE(tip);
    const auto first = AcquireStakeSlotCache(*wallet, tip);
    BOOST_CHECK(first->final_reserve_enabled);
    BOOST_CHECK(first->final_reserve_active);
    const StakeSlotCacheStats after_first = wallet->GetStakeSlotCacheStateLocked().stats;
    const auto again = AcquireStakeSlotCache(*wallet, tip);
    BOOST_CHECK(again == first);
    BOOST_CHECK_EQUAL(wallet->GetStakeSlotCacheStateLocked().stats.rebuilds, after_first.rebuilds);

    gArgs.ForceSetArg("-finalstakereserve", "0");
    const auto rebuilt = AcquireStakeSlotCache(*wallet, tip);
    BOOST_CHECK(rebuilt != first);
    BOOST_CHECK(!rebuilt->final_reserve_enabled);
    BOOST_CHECK(!rebuilt->final_reserve_active);
    BOOST_CHECK(rebuilt->final_reserve.empty());
    BOOST_CHECK_EQUAL(wallet->GetStakeSlotCacheStateLocked().stats.rebuilds, after_first.rebuilds + 1);
}

namespace {
/** Put a quantum stake source of `value` for `dest` into the wallet as confirmed at `height`, and into the coin view.
 *  With `held` given, the transaction is varied (its salt) until the singleton rule gives that answer for the source's
 *  outpoint: the rule depends on the transaction id, which depends on the wallet's random key. */
COutPoint AddQuantumStakeSource(TestChain100Setup& setup, CWallet& wallet, const CTxDestination& dest, CAmount value, int height, uint32_t salt,
                                std::optional<bool> held = std::nullopt)
{
    CTransactionRef tx = Paying({CTxOut{value, GetScriptForDestination(dest)}}, salt);
    for (uint32_t extra = 1; held && SingleOutputReserveBit(COutPoint{tx->GetHash(), 0}) != *held; ++extra) {
        BOOST_REQUIRE_LT(extra, 4000U);
        tx = Paying({CTxOut{value, GetScriptForDestination(dest)}}, salt + 256 * extra);
    }
    const CBlockIndex* index = WITH_LOCK(::cs_main, return setup.m_node.chainman->ActiveChain()[height]);
    BOOST_REQUIRE(index);
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        BOOST_REQUIRE(wallet.AddToWallet(tx, TxStateConfirmed{index->GetBlockHash(), height, 0}));
        wallet.chain().getCoinsTip().AddCoin(COutPoint{tx->GetHash(), 0}, Coin(tx->vout[0], height, false, false, index->nTime), true);
    }
    return COutPoint{tx->GetHash(), 0};
}
} // namespace

namespace {
/** A wallet with two quantum stake sources, the larger one (N = 2, R = 1) the reserve while the guard is on. */
struct ReserveWallet
{
    std::unique_ptr<CWallet> wallet;
    CTxDestination dest_big, dest_small;
    COutPoint big, small;
    CTxDestination recipient;
};

ReserveWallet MakeReserveWallet(TestChain100Setup& setup, const CKey& key)
{
    ReserveWallet rw;
    rw.wallet = CreateSyncedWallet(*setup.m_node.chain, WITH_LOCK(Assert(setup.m_node.chainman)->GetMutex(), return setup.m_node.chainman->ActiveChain()), key);
    const auto a = rw.wallet->GetNewQuantumDestination("a");
    const auto b = rw.wallet->GetNewQuantumDestination("b");
    BOOST_REQUIRE(a && b);
    rw.dest_big = *a;
    rw.dest_small = *b;
    // The larger source is the one that is held when the other is out of the count (a user lock, say): as a lone source
    // its outpoint must give "held" under the singleton rule.
    rw.big = AddQuantumStakeSource(setup, *rw.wallet, *a, 20 * COIN, 70, 1, /*held=*/true);
    rw.small = AddQuantumStakeSource(setup, *rw.wallet, *b, 10 * COIN, 71, 2);
    // Quantum inputs may only pay quantum outputs: the payee is a third key of the wallet.
    const auto payee = rw.wallet->GetNewQuantumDestination("payee");
    BOOST_REQUIRE(payee);
    rw.recipient = *payee;
    return rw;
}
} // namespace

namespace {
//! A transaction built while the guard is off (the option is off), paying `amount`. The option is left off.
CTransactionRef BuildBeforeTheGuard(ReserveWallet& rw, CAmount amount, CCoinControl coin_control = {})
{
    gArgs.ForceSetArg("-finalstakereserve", "0");
    coin_control.destChange = rw.dest_small; // a fixed change output, so the id varies only with the input order and the lock time
    const auto created = CreateTransaction(*rw.wallet, {CRecipient{rw.recipient, amount, false}}, /*change_pos=*/1, coin_control);
    BOOST_REQUIRE_MESSAGE(created, util::ErrorString(created).original);
    return created->tx;
}

bool Recorded(const ReserveWallet& rw, const CTransactionRef& tx)
{
    return WITH_LOCK(rw.wallet->cs_wallet, return rw.wallet->mapWallet.count(tx->GetHash()) > 0);
}
} // namespace

// The reserve of the first Final block holds the larger of two sources. A transaction built before the guard that
// takes both is refused at the commit, inside the guard: nothing is stored. The coin lock this operation put on its
// input (lock_unspents) does not take it out of the reserve and is released with the refusal; a lock the user put on
// another input is not this operation's and stays.
BOOST_FIXTURE_TEST_CASE(a_commit_inside_the_guard_refuses_the_reserve_and_releases_only_its_own_locks, CandidateAtGuardStart)
{
    ReserveWallet rw = MakeReserveWallet(*this, coinbaseKey);
    const CTransactionRef tx = BuildBeforeTheGuard(rw, 25 * COIN);
    BOOST_REQUIRE_EQUAL(tx->vin.size(), 2U);
    gArgs.ForceSetArg("-finalstakereserve", "1");
    BOOST_REQUIRE(ReserveOf(*rw.wallet).active);
    {
        LOCK(rw.wallet->cs_wallet);
        rw.wallet->LockCoin(rw.big);   // by this operation (lock_unspents)
        rw.wallet->LockCoin(rw.small); // by the user, after the transaction was built
    }
    CommitSpendProvenance provenance;
    provenance.operation_locks = {rw.big};
    std::string error;
    WalletCommitStatus status;
    BOOST_CHECK(!rw.wallet->CommitTransaction(tx, {}, {}, &error, &status, std::nullopt, &provenance));
    BOOST_CHECK_EQUAL(error, FINAL_STAKE_RESERVE_COMMIT_ERROR);
    BOOST_CHECK(status == WalletCommitStatus::REJECTED_NOT_ADDED);
    BOOST_CHECK(!Recorded(rw, tx));
    LOCK(rw.wallet->cs_wallet);
    BOOST_CHECK(!rw.wallet->IsLockedCoin(rw.big));
    BOOST_CHECK(rw.wallet->IsLockedCoin(rw.small));
}

// An explicit input may spend the reserve, and the commit reports what it consumed from one inventory before and
// after, derived inside its critical section: for a transaction built before the guard and committed inside it, and
// with the coin lock the operation put on that explicit input (lock_unspents).
BOOST_FIXTURE_TEST_CASE(an_explicit_spend_of_the_reserve_is_reported_from_the_commit_itself, CandidateAtGuardStart)
{
    ReserveWallet rw = MakeReserveWallet(*this, coinbaseKey);
    CCoinControl coin_control;
    coin_control.Select(rw.big);
    coin_control.m_allow_other_inputs = false;
    const CTransactionRef tx = BuildBeforeTheGuard(rw, 15 * COIN, coin_control);
    BOOST_REQUIRE_EQUAL(tx->vin.size(), 1U);
    BOOST_REQUIRE(tx->vin[0].prevout == rw.big);
    gArgs.ForceSetArg("-finalstakereserve", "1");
    {
        LOCK(rw.wallet->cs_wallet);
        rw.wallet->LockCoin(rw.big); // lock_unspents on the explicit input
    }
    CommitSpendProvenance provenance;
    provenance.explicit_inputs = {rw.big};
    provenance.operation_locks = {rw.big};
    std::string error;
    FinalStakeReserveSpendReport report;
    BOOST_REQUIRE_MESSAGE(rw.wallet->CommitTransaction(tx, {}, {}, &error, nullptr, std::nullopt, &provenance, &report), error);
    BOOST_CHECK(Recorded(rw, tx));
    BOOST_REQUIRE_EQUAL(report.spent.size(), 1U);
    BOOST_CHECK(report.spent[0].outpoint == rw.big);
    BOOST_CHECK_EQUAL(report.reserved_before, 1);
    // The other source is the only one left (N = 1): the singleton rule decides whether it is the reserve.
    BOOST_CHECK_EQUAL(report.reserved_after, SingleOutputReserveBit(rw.small) ? 1 : 0);
    BOOST_CHECK_EQUAL(report.eligible_before, 2);
    BOOST_CHECK_EQUAL(report.eligible_after, 1);
    BOOST_CHECK_GT(report.eligible_weight_before, report.eligible_weight_after);
    BOOST_CHECK_EQUAL(report.spent_effective_value, report.spent[0].effective_value);
}

// A wallet with one quantum source: the outpoint decides whether it is the reserve, and the reserve report names the
// rule. Sources of both parities are made by varying the transaction until the rule gives each answer.
BOOST_FIXTURE_TEST_CASE(a_single_source_wallet_reports_and_applies_the_singleton_rule, CandidateAtGuardStart)
{
    std::optional<COutPoint> held, released;
    CKey key;
    key.MakeNewKey(/*fCompressed=*/true);
    const auto source_for = [&](uint32_t salt, std::unique_ptr<CWallet>& wallet) {
        wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), key);
        const auto dest = wallet->GetNewQuantumDestination("only");
        BOOST_REQUIRE(dest);
        return AddQuantumStakeSource(*this, *wallet, *dest, 10 * COIN + salt, 70, salt);
    };
    std::unique_ptr<CWallet> held_wallet, released_wallet, trial;
    for (uint32_t salt = 1; salt <= 200 && !(held && released); ++salt) {
        // Each trial wallet is discarded unless its source has the wanted parity: a wallet keeps what it is given.
        const COutPoint outpoint = source_for(salt, trial);
        if (SingleOutputReserveBit(outpoint) && !held) {
            held = outpoint;
            held_wallet = std::move(trial);
        } else if (!SingleOutputReserveBit(outpoint) && !released) {
            released = outpoint;
            released_wallet = std::move(trial);
        }
    }
    BOOST_REQUIRE_MESSAGE(held && released, "no source of one of the parities found");

    gArgs.ForceSetArg("-finalstakereserve", "1");
    {
        const FinalStakeReserve reserve = ReserveOf(*held_wallet);
        BOOST_CHECK(reserve.active);
        BOOST_CHECK_EQUAL(reserve.n, 1);
        BOOST_CHECK(reserve.single_output);
        BOOST_CHECK(reserve.single_output_held);
        BOOST_CHECK_EQUAL(reserve.target, 1);
        BOOST_REQUIRE_EQUAL(reserve.reserved.size(), 1U);
        BOOST_CHECK(reserve.reserved[0].outpoint == *held);
        BOOST_CHECK(reserve.enforced == (std::set<COutPoint>{*held}));
        CMutableTransaction spend;
        spend.vin.emplace_back(*held);
        BOOST_CHECK(SpendsFinalStakeReserve(*held_wallet, CTransaction{spend}));
    }
    {
        const FinalStakeReserve reserve = ReserveOf(*released_wallet);
        BOOST_CHECK(reserve.active);
        BOOST_CHECK_EQUAL(reserve.n, 1);
        BOOST_CHECK(reserve.single_output);
        BOOST_CHECK(!reserve.single_output_held);
        BOOST_CHECK_EQUAL(reserve.target, 0);
        BOOST_CHECK_EQUAL(reserve.eligible_count, 1);
        BOOST_CHECK(reserve.reserved.empty());
        BOOST_CHECK(reserve.enforced.empty());
        BOOST_CHECK_EQUAL(reserve.shortfall, 0);
        CMutableTransaction spend;
        spend.vin.emplace_back(*released);
        BOOST_CHECK(!SpendsFinalStakeReserve(*released_wallet, CTransaction{spend}));
    }
}


// Explicit and automatic inputs in one transaction: the explicit one keeps its right, the automatic one is checked.
BOOST_FIXTURE_TEST_CASE(a_mixed_transaction_is_refused_when_its_automatic_input_is_in_the_reserve, CandidateAtGuardStart)
{
    ReserveWallet rw = MakeReserveWallet(*this, coinbaseKey);
    CCoinControl coin_control;
    coin_control.Select(rw.small); // the user chose the small one; the wallet adds the large one itself
    const CTransactionRef tx = BuildBeforeTheGuard(rw, 25 * COIN, coin_control);
    BOOST_REQUIRE_EQUAL(tx->vin.size(), 2U);
    gArgs.ForceSetArg("-finalstakereserve", "1");
    CommitSpendProvenance provenance;
    provenance.explicit_inputs = {rw.small};
    std::string error;
    FinalStakeReserveSpendReport report;
    BOOST_CHECK(!rw.wallet->CommitTransaction(tx, {}, {}, &error, nullptr, std::nullopt, &provenance, &report));
    BOOST_CHECK_EQUAL(error, FINAL_STAKE_RESERVE_COMMIT_ERROR);
    BOOST_CHECK(!Recorded(rw, tx));
    BOOST_CHECK(report.spent.empty());
    // The same transaction with both inputs named by the user is the user's decision.
    provenance.explicit_inputs = {rw.small, rw.big};
    BOOST_REQUIRE_MESSAGE(rw.wallet->CommitTransaction(tx, {}, {}, &error, nullptr, std::nullopt, &provenance, &report), error);
    BOOST_CHECK(Recorded(rw, tx));
    BOOST_CHECK_EQUAL(report.spent.size(), 1U);
}


namespace {
//! The wallet of ReserveWallet behind the interface the GUI commits through.
struct ReserveInterface
{
    std::shared_ptr<CWallet> wallet;
    WalletContext context;
    std::unique_ptr<interfaces::Wallet> iface;
    ReserveInterface(TestChain100Setup& setup, ReserveWallet& rw)
        : wallet{rw.wallet.release()}
    {
        context.chain = setup.m_node.chain.get();
        iface = interfaces::MakeWallet(context, wallet);
    }
    //! A transaction of the interface, built while the guard is off, spending `big` by choice.
    CTransactionRef Prepare(const ReserveWallet& rw, CAmount amount, bool explicit_big)
    {
        gArgs.ForceSetArg("-finalstakereserve", "0");
        CCoinControl coin_control;
        if (explicit_big) {
            coin_control.Select(rw.big);
            coin_control.m_allow_other_inputs = false;
        }
        coin_control.destChange = rw.dest_small;
        int change_pos{1};
        CAmount fee{0};
        auto created = iface->createTransaction({CRecipient{rw.recipient, amount, false}}, coin_control, /*sign=*/true, change_pos, fee);
        BOOST_REQUIRE_MESSAGE(created, util::ErrorString(created).original);
        return *created;
    }
};
bool IsRejection(const std::exception& e) { return dynamic_cast<const interfaces::WalletCommitRejected*>(&e) != nullptr; }
} // namespace

// The wallet stored the transaction and could not relay it yet: that is a commit, and the reserve it consumed is
// reported like any other spend of it. (Review: the warning was dropped for this disposition.)
BOOST_FIXTURE_TEST_CASE(a_stored_but_unrelayed_commit_still_reports_the_reserve_it_consumed, CandidateAtGuardStart)
{
    ReserveWallet rw = MakeReserveWallet(*this, coinbaseKey);
    ReserveInterface gui{*this, rw};
    gui.wallet->SetBroadcastTransactions(true);
    // The mempool already holds another transaction that spends the same output, so the relay of ours is refused for
    // a reason that is not terminal: the wallet keeps ours and relays it later.
    const CTransactionRef rival = gui.Prepare(rw, 14 * COIN, /*explicit_big=*/true);
    const CTransactionRef tx = gui.Prepare(rw, 15 * COIN, /*explicit_big=*/true);
    BOOST_REQUIRE_EQUAL(tx->vin.size(), 1U);
    BOOST_REQUIRE(rival->GetHash() != tx->GetHash());
    {
        LOCK(::cs_main);
        const MempoolAcceptResult accepted = m_node.chainman->ProcessTransaction(rival);
        BOOST_REQUIRE_MESSAGE(accepted.m_result_type == MempoolAcceptResult::ResultType::VALID, accepted.m_state.ToString());
    }
    gArgs.ForceSetArg("-finalstakereserve", "1");
    bilingual_str warning_text;
    BOOST_CHECK_NO_THROW(warning_text = gui.iface->commitTransaction(tx, {}, {}));
    const std::string warning = warning_text.original;
    BOOST_CHECK(WITH_LOCK(gui.wallet->cs_wallet, return gui.wallet->mapWallet.count(tx->GetHash()) > 0));
    BOOST_CHECK_MESSAGE(!WITH_LOCK(m_node.mempool->cs, return m_node.mempool->exists(GenTxid::Txid(tx->GetHash()))), "the relay was not refused: the test does not reach the stored-but-unrelayed disposition");
    BOOST_CHECK_MESSAGE(warning.find("final stake reserve") != std::string::npos, "warning: " + warning);
    // Both situations apply here, so both are told, in one text that is translated as a whole.
    BOOST_CHECK_MESSAGE(warning.find("could not be broadcast") != std::string::npos, "warning: " + warning);
    BOOST_CHECK_EQUAL(warning_text.translated, warning_text.original);
}

namespace {
//! Commit one prepared transaction through the interface and return its warning. `pending_relay` makes the relay
//! refuse for a reason that is not terminal (a rival spends the same outputs in the mempool), so that the wallet keeps
//! the transaction; `consume_reserve` makes it spend the reserved output on purpose with the guard on.
bilingual_str CommitWithWarning(TestChain100Setup& setup, bool pending_relay, bool consume_reserve)
{
    ReserveWallet rw = MakeReserveWallet(setup, setup.coinbaseKey);
    ReserveInterface gui{setup, rw};
    gui.wallet->SetBroadcastTransactions(pending_relay);
    const CTransactionRef tx = gui.Prepare(rw, consume_reserve ? 14 * COIN : 25 * COIN, /*explicit_big=*/consume_reserve);
    if (pending_relay) {
        const CTransactionRef rival = gui.Prepare(rw, consume_reserve ? 13 * COIN : 24 * COIN, /*explicit_big=*/consume_reserve);
        BOOST_REQUIRE(rival->GetHash() != tx->GetHash());
        LOCK(::cs_main);
        const MempoolAcceptResult accepted = setup.m_node.chainman->ProcessTransaction(rival);
        BOOST_REQUIRE_MESSAGE(accepted.m_result_type == MempoolAcceptResult::ResultType::VALID, accepted.m_state.ToString());
    }
    gArgs.ForceSetArg("-finalstakereserve", consume_reserve ? "1" : "0");
    bilingual_str warning;
    BOOST_CHECK_NO_THROW(warning = gui.iface->commitTransaction(tx, {}, {}));
    BOOST_CHECK(WITH_LOCK(gui.wallet->cs_wallet, return gui.wallet->mapWallet.count(tx->GetHash()) > 0));
    if (pending_relay) {
        BOOST_CHECK_MESSAGE(!WITH_LOCK(setup.m_node.mempool->cs, return setup.m_node.mempool->exists(GenTxid::Txid(tx->GetHash()))), "the relay was not refused");
    }
    return warning;
}
bool MentionsRelay(const bilingual_str& w) { return w.original.find("could not be broadcast") != std::string::npos; }
bool MentionsReserve(const bilingual_str& w) { return w.original.find("final stake reserve") != std::string::npos; }
} // namespace

// The four combinations of "stored but not relayed" and "spent the reserve": neither, each alone, both.
BOOST_FIXTURE_TEST_CASE(the_commit_warning_is_empty_when_nothing_needs_saying, CandidateAtGuardStart)
{
    const bilingual_str warning = CommitWithWarning(*this, /*pending_relay=*/false, /*consume_reserve=*/false);
    BOOST_CHECK_MESSAGE(warning.empty(), "warning: " + warning.original);
}

BOOST_FIXTURE_TEST_CASE(the_commit_warning_names_a_consumed_reserve_alone, CandidateAtGuardStart)
{
    const bilingual_str warning = CommitWithWarning(*this, /*pending_relay=*/false, /*consume_reserve=*/true);
    BOOST_CHECK_MESSAGE(MentionsReserve(warning) && !MentionsRelay(warning), "warning: " + warning.original);
    BOOST_CHECK_EQUAL(warning.translated, warning.original);
}

BOOST_FIXTURE_TEST_CASE(the_commit_warning_names_a_pending_relay_alone_and_promises_nothing, CandidateAtGuardStart)
{
    const bilingual_str warning = CommitWithWarning(*this, /*pending_relay=*/true, /*consume_reserve=*/false);
    BOOST_CHECK_MESSAGE(MentionsRelay(warning) && !MentionsReserve(warning), "warning: " + warning.original);
    BOOST_CHECK_MESSAGE(warning.original.find("not certain") != std::string::npos, warning.original);
    BOOST_CHECK_EQUAL(warning.translated, warning.original);
}

BOOST_FIXTURE_TEST_CASE(the_commit_warning_names_both_when_both_apply, CandidateAtGuardStart)
{
    // With a translator that marks every string, the whole text is translated, template by template, and the original
    // stays the English one.
    bilingual_str warning;
    {
        // Established before the helper, which can stop the test with a fatal assertion.
        const ScopedTestTranslation translation;
        warning = CommitWithWarning(*this, /*pending_relay=*/true, /*consume_reserve=*/true);
    }
    BOOST_CHECK_MESSAGE(MentionsReserve(warning) && MentionsRelay(warning), "warning: " + warning.original);
    BOOST_CHECK_EQUAL(warning.original.find("[T]"), std::string::npos);
    BOOST_CHECK(warning.translated.rfind("[T] The transaction was stored", 0) == 0);
    BOOST_CHECK_NE(warning.translated.find(" [T] This transaction spends"), std::string::npos);
}

namespace {
// The guard is on for the candidate 101 (as CandidateAtGuardStart) and bonded tiers exist.
class TieredReserveSetup : public TestChain100Setup
{
public:
    TieredReserveSetup()
        : TestChain100Setup{ChainType::REGTEST, {
              "-shadowwhitelistheight=20",
              "-shadowgoldrushstartheight=30",
              "-shadowgoldrushendheight=60",
              "-qqgoldrushendheight=60",
              "-qqmigrationendheight=110",
              "-qqstaketierheight=61",
          }}
    {
    }
    ~TieredReserveSetup() { gArgs.ForceSetArg("-finalstakereserve", "1"); }
};

constexpr uint32_t TEST_UNBONDING_BLOCKS{9450};

//! Withdraw a bonded staking output. Only the named output is the caller's own choice; the fee input is the wallet's.
util::Result<interfaces::WalletQuantumOperatorBondTx> WithdrawBond(CWallet& wallet, const CTxDestination& bond, const COutPoint& selected)
{
    return WithdrawTieredStakeAddress(wallet, EncodeDestination(bond), /*require_operator_lock=*/false, "unbond", "withdraw",
                                      "test unbond", "test withdraw", selected, /*allow_all_outputs=*/false,
                                      /*allow_new_quantum_key=*/true);
}
} // namespace

// A staking withdrawal names the output it takes. That output may be one the reserve holds back, and the result
// reports it; the fee input the withdrawal adds itself is not named, so it may not be one.
BOOST_FIXTURE_TEST_CASE(a_named_withdrawal_output_may_be_reserved_and_the_result_says_so, TieredReserveSetup)
{
    gArgs.ForceSetArg("-finalstakereserve", "1");
    // The wallet holds the node's coinbases (legacy coins: the fee input) and two bonded outputs (N = 2, R = 1).
    auto wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), coinbaseKey);
    wallet->SetBroadcastTransactions(false);
    const auto big_bond = wallet->GetNewTieredQuantumDestination("bond-big", TEST_UNBONDING_BLOCKS);
    const auto small_bond = wallet->GetNewTieredQuantumDestination("bond-small", TEST_UNBONDING_BLOCKS);
    BOOST_REQUIRE(big_bond && small_bond);
    const COutPoint big = AddQuantumStakeSource(*this, *wallet, *big_bond, 20 * COIN, 70, 1);
    const COutPoint small = AddQuantumStakeSource(*this, *wallet, *small_bond, 10 * COIN, 71, 2);
    const FinalStakeReserve reserve = ReserveOf(*wallet);
    BOOST_REQUIRE(reserve.active);
    BOOST_REQUIRE_EQUAL(reserve.n, 2);
    BOOST_REQUIRE_EQUAL(reserve.reserved.size(), 1U);
    BOOST_REQUIRE(reserve.reserved[0].outpoint == big);
    (void)small;

    const auto result = WithdrawBond(*wallet, *big_bond, big);
    BOOST_REQUIRE_MESSAGE(result, util::ErrorString(result).original);
    BOOST_CHECK_MESSAGE(result->warning.original.find("final stake reserve") != std::string::npos, result->warning.original);
    BOOST_CHECK_MESSAGE(result->warning.original.find("Back up this wallet now") != std::string::npos, result->warning.original);
    // The transaction is in the wallet and spends the named output.
    LOCK(wallet->cs_wallet);
    const CWalletTx* wtx = wallet->GetWalletTx(uint256S(result->txid));
    BOOST_REQUIRE(wtx);
    BOOST_CHECK(std::any_of(wtx->tx->vin.begin(), wtx->tx->vin.end(), [&](const CTxIn& in) { return in.prevout == big; }));
}

BOOST_FIXTURE_TEST_CASE(a_reserved_fee_input_the_withdrawal_chose_itself_is_refused, TieredReserveSetup)
{
    gArgs.ForceSetArg("-finalstakereserve", "1");
    CKey key;
    key.MakeNewKey(/*fCompressed=*/true);
    auto wallet = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), key);
    wallet->SetBroadcastTransactions(false);
    // No legacy coin: the only fee input is a direct quantum output, the largest of three sources (N = 3, R = 2), so it
    // is reserved. The named bonded output is reserved too.
    const auto fee_dest = wallet->GetNewQuantumDestination("fee");
    const auto big_bond = wallet->GetNewTieredQuantumDestination("bond-big", TEST_UNBONDING_BLOCKS);
    const auto small_bond = wallet->GetNewTieredQuantumDestination("bond-small", TEST_UNBONDING_BLOCKS);
    BOOST_REQUIRE(fee_dest && big_bond && small_bond);
    const COutPoint fee = AddQuantumStakeSource(*this, *wallet, *fee_dest, 30 * COIN, 70, 1);
    const COutPoint big = AddQuantumStakeSource(*this, *wallet, *big_bond, 20 * COIN, 71, 2);
    AddQuantumStakeSource(*this, *wallet, *small_bond, 10 * COIN, 72, 3);
    const FinalStakeReserve reserve = ReserveOf(*wallet);
    BOOST_REQUIRE_EQUAL(reserve.n, 3);
    BOOST_REQUIRE(reserve.enforced.count(fee) > 0 && reserve.enforced.count(big) > 0);

    const size_t transactions_before = WITH_LOCK(wallet->cs_wallet, return wallet->mapWallet.size());
    const auto result = WithdrawBond(*wallet, *big_bond, big);
    BOOST_REQUIRE_MESSAGE(!result, "the withdrawal took a reserved fee input without being asked to");
    BOOST_CHECK_MESSAGE(util::ErrorString(result).original.find("held back as the final stake reserve") != std::string::npos, util::ErrorString(result).original);
    // Nothing of the refused transaction is left in the wallet apart from the keys it made.
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet, return wallet->mapWallet.size()), transactions_before);
}

// The reserve refusal is the typed, recoverable rejection: nothing was stored.
BOOST_FIXTURE_TEST_CASE(a_reserve_refusal_through_the_interface_is_the_typed_rejection, CandidateAtGuardStart)
{
    ReserveWallet rw = MakeReserveWallet(*this, coinbaseKey);
    ReserveInterface gui{*this, rw};
    const CTransactionRef tx = gui.Prepare(rw, 25 * COIN, /*explicit_big=*/false);
    BOOST_REQUIRE_EQUAL(tx->vin.size(), 2U);
    gArgs.ForceSetArg("-finalstakereserve", "1");
    BOOST_CHECK_EXCEPTION(gui.iface->commitTransaction(tx, {}, {}), interfaces::WalletCommitRejected,
        [](const interfaces::WalletCommitRejected& e) { return std::string{e.what()} == FINAL_STAKE_RESERVE_COMMIT_ERROR; });
    BOOST_CHECK(!WITH_LOCK(gui.wallet->cs_wallet, return gui.wallet->mapWallet.count(tx->GetHash()) > 0));
}

// A storage failure in the commit is not a rejection a caller may recover from: the wallet can hold a record the
// disk does not. It reaches the caller as an ordinary exception (the Send dialog does not catch that type), never as
// the typed rejection.
BOOST_FIXTURE_TEST_CASE(a_storage_failure_in_the_commit_is_not_a_recoverable_rejection, CandidateAtGuardStart)
{
    ReserveWallet rw = MakeReserveWallet(*this, coinbaseKey);
    ReserveInterface gui{*this, rw};
    const CTransactionRef tx = gui.Prepare(rw, 25 * COIN, /*explicit_big=*/false);
    gArgs.ForceSetArg("-finalstakereserve", "0");
    gArgs.ForceSetArg("-qqcommitwritefailure", "1");
    bool thrown{false};
    try {
        gui.iface->commitTransaction(tx, {}, {});
    } catch (const std::exception& e) {
        thrown = true;
        BOOST_CHECK_MESSAGE(!IsRejection(e), "a storage failure was reported as a recoverable rejection");
        BOOST_CHECK_MESSAGE(std::string{e.what()}.find("Wallet db error") != std::string::npos, e.what());
    }
    gArgs.ForceSetArg("-qqcommitwritefailure", "0");
    BOOST_CHECK(thrown);
}


namespace {
//! Chain height 100, Final begins at 101 and demurrage with it; a month is one block, so an output untouched since
//! before 101 has been inactive for more than the grace of 6 blocks from the block 108 on, and is not yet locked (24).
class DemurrageSweepSetup : public TestChain100Setup
{
public:
    DemurrageSweepSetup()
        : TestChain100Setup{ChainType::REGTEST, {
              "-shadowwhitelistheight=20",
              "-shadowgoldrushstartheight=30",
              "-shadowgoldrushendheight=60",
              "-qqgoldrushendheight=60",
              "-qqmigrationendheight=100",
              "-qqdemurrageblockspermonth=1",
          }}
    {
    }
};
} // namespace

// The sweep of the GUI makes its transaction under cs_main and cs_wallet and commits it with neither held (the commit
// takes both itself). A funded, committed sweep; in a lock-order build a lock held at the commit aborts it.
BOOST_FIXTURE_TEST_CASE(a_funded_gui_sweep_commits_without_holding_the_wallet_locks, DemurrageSweepSetup)
{
    // Final blocks pay quantum outputs only: the coinbase of the blocks that age the chain goes to a quantum address.
    CKey miner_key;
    miner_key.MakeNewKey(/*fCompressed=*/true);
    std::shared_ptr<CWallet> wallet;
    {
        std::unique_ptr<CWallet> aging = CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), miner_key);
        const auto miner_dest = aging->GetNewQuantumDestination("miner");
        BOOST_REQUIRE(miner_dest);
        for (int i = 0; i < 8; ++i) CreateAndProcessBlock({}, GetScriptForDestination(*miner_dest));
    }
    wallet.reset(CreateSyncedWallet(*m_node.chain, WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return m_node.chainman->ActiveChain()), miner_key).release());
    wallet->SetBroadcastTransactions(false);
    const auto source_dest = wallet->GetNewQuantumDestination("decaying");
    BOOST_REQUIRE(source_dest);
    const COutPoint source = AddQuantumStakeSource(*this, *wallet, *source_dest, 20 * COIN, 30, 1);
    WalletContext context;
    context.chain = m_node.chain.get();
    const auto iface = interfaces::MakeWallet(context, wallet);

    const auto swept = iface->sweepDemurrageDecay(/*allow_new_quantum_key=*/true);
    BOOST_REQUIRE_MESSAGE(swept, util::ErrorString(swept).original);
    BOOST_CHECK_EQUAL(swept->selected_inputs, 1U);
    BOOST_CHECK_EQUAL(swept->selected_amount, 20 * COIN);
    BOOST_CHECK_GT(swept->amount, 0);
    BOOST_CHECK_LT(swept->amount, 20 * COIN);
    const uint256 txid{uint256S(swept->txid)};
    LOCK(wallet->cs_wallet);
    const CWalletTx* wtx = wallet->GetWalletTx(txid);
    BOOST_REQUIRE(wtx);
    BOOST_REQUIRE_EQUAL(wtx->tx->vin.size(), 1U);
    BOOST_CHECK(wtx->tx->vin[0].prevout == source);
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
