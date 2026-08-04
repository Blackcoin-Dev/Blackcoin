// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/shadow_pow_claim_recovery.h>

#include <chain.h>
#include <key.h>
#include <script/script.h>
#include <script/solver.h>
#include <shadow.h>
#include <test/util/setup_common.h>
#include <util/check.h>
#include <util/string.h>
#include <util/time.h>
#include <validation.h>
#include <validationinterface.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <memory>
#include <utility>
#include <vector>

namespace wallet {
namespace {

class RecoveryShadowScheduleGuard
{
public:
    RecoveryShadowScheduleGuard(int whitelist_height, int reward_start_height,
                                int gold_rush_blocks)
        : m_whitelist_height{SHADOW_WHITELIST_HEIGHT},
          m_reward_start_height{SHADOW_REWARD_START_HEIGHT},
          m_gold_rush_blocks{SHADOW_GOLD_RUSH_BLOCKS}
    {
        SetShadowTestSchedule(whitelist_height, reward_start_height,
                              gold_rush_blocks);
    }

    ~RecoveryShadowScheduleGuard()
    {
        SetShadowTestSchedule(m_whitelist_height, m_reward_start_height,
                              m_gold_rush_blocks);
    }

private:
    int m_whitelist_height;
    int m_reward_start_height;
    int m_gold_rush_blocks;
};

class RecoveryQQP3TestingSetup : public TestChain100Setup
{
public:
    RecoveryQQP3TestingSetup()
        : TestChain100Setup{ChainType::REGTEST, {
              "-regtest",
              "-shadowwhitelistheight=99",
              "-shadowgoldrushstartheight=100",
              "-shadowgoldrushblocks=1000",
              "-shadowcompetingclaimsheight=100",
          }}
    {
    }
};

CTransactionRef MakeRecoveryTestClaim(const COutPoint& input, CAmount value,
                                      const CScript& wallet_script)
{
    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0});
    // Canonical QQP2 framing with zero nonce. It parses completely but is not
    // valid work on the pinned tip. Because QQP2 does not bind an origin, the
    // same bytes may validate against a descendant context; resolver tests
    // therefore exercise the explicit descendant-revalidation risk path.
    proof.insert(proof.end(), 8, 0);
    proof.push_back(static_cast<unsigned char>(wallet_script.size() & 0xff));
    proof.push_back(static_cast<unsigned char>((wallet_script.size() >> 8) & 0xff));
    proof.insert(proof.end(), wallet_script.begin(), wallet_script.end());
    const CScript quantum_payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x51)});
    proof.push_back(static_cast<unsigned char>(quantum_payout.size() & 0xff));
    proof.push_back(static_cast<unsigned char>((quantum_payout.size() >> 8) & 0xff));
    proof.insert(proof.end(), quantum_payout.begin(), quantum_payout.end());
    CMutableTransaction claim;
    claim.vin.emplace_back(input);
    claim.vout.emplace_back(value, wallet_script);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    CTransactionRef result = MakeTransactionRef(std::move(claim));
    BOOST_REQUIRE(TransactionHasShadowProof(*result));
    return result;
}

void AddRecoveryTestClaim(CWallet& wallet, const CTransactionRef& claim,
                          int branch_height, const uint256& branch_tip,
                          int first_height, const uint256& first_tip,
                          bool explicit_authored = true)
{
    BOOST_REQUIRE(wallet.AddToWallet(
        claim, TxStateInactive{},
        [=](CWalletTx& wtx, bool) {
            if (explicit_authored) {
                wtx.mapValue[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
                wtx.mapValue[SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY] =
                    ToString(branch_height);
                wtx.mapValue[SHADOW_POW_CLAIM_CREATED_TIP_KEY] =
                    branch_tip.GetHex();
                wtx.fFromMe = true;
            }
            wtx.mapValue[SHADOW_POW_QUARANTINE_MARKER_KEY] = "1";
            wtx.mapValue[SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY] =
                ToString(first_height);
            wtx.mapValue[SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY] =
                first_tip.GetHex();
            wtx.mapValue[SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY] =
                ToString(branch_height);
            wtx.mapValue[SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY] =
                branch_tip.GetHex();
            return true;
        }));
}

CTransactionRef AddRecoveryTestManagedResolution(
    CWallet& wallet, const CTransactionRef& anchor_tx,
    const COutPoint& anchor, const uint256& generation_fingerprint,
    CAmount fee, const std::string& origin, int created_height,
    int64_t created_time)
{
    BOOST_REQUIRE(fee > 0);
    BOOST_REQUIRE(anchor.n < anchor_tx->vout.size());
    BOOST_REQUIRE(anchor_tx->vout.at(anchor.n).nValue > fee);
    CMutableTransaction resolution;
    resolution.vin.emplace_back(
        anchor, CScript(), std::numeric_limits<uint32_t>::max());
    resolution.vout.emplace_back(
        anchor_tx->vout.at(anchor.n).nValue - fee,
        anchor_tx->vout.at(anchor.n).scriptPubKey);
    const CTransactionRef result =
        MakeTransactionRef(std::move(resolution));
    BOOST_REQUIRE(wallet.AddToWallet(
        result, TxStateInactive{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_RESOLUTION_SCHEMA_KEY] =
                SHADOW_POW_RESOLUTION_SCHEMA_VERSION;
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY] =
                anchor.hash.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY] =
                ToString(anchor.n);
            wtx.mapValue[SHADOW_POW_RESOLUTION_FINGERPRINT_KEY] =
                generation_fingerprint.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ORIGIN_KEY] = origin;
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY] =
                ToString(created_height);
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_TIME_KEY] =
                ToString(created_time);
            wtx.mapValue[SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY] = "1";
            wtx.fFromMe = true;
            return true;
        }));
    return result;
}

const ShadowPowClaimRecoveryComponent& FindRecoveryComponent(
    const ShadowPowClaimRecoveryInventory& inventory, const COutPoint& anchor)
{
    const auto it = std::find_if(
        inventory.components.begin(), inventory.components.end(),
        [&](const auto& component) { return component.anchor == anchor; });
    BOOST_REQUIRE_MESSAGE(it != inventory.components.end(),
                          "missing expected recovery component");
    return *it;
}

void SyncRecoveryTestWalletTip(CWallet& wallet, ChainstateManager& chainman)
{
    LOCK2(::cs_main, wallet.cs_wallet);
    const CBlockIndex* tip = chainman.ActiveChain().Tip();
    BOOST_REQUIRE(tip);
    wallet.SetLastBlockProcessed(tip->nHeight, tip->GetBlockHash());
}

} // namespace

BOOST_FIXTURE_TEST_SUITE(shadow_pow_claim_recovery_tests, TestChain100Setup)

BOOST_AUTO_TEST_CASE(aggregate_review_tracks_policy_tip_and_wallet_generation_atomically)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);

    ShadowPowClaimRecoveryPolicy first_policy =
        DefaultShadowPowClaimRecoveryPolicy();
    first_policy.choice_recorded = 1;
    first_policy.automatic_enabled = 1;
    first_policy.max_fee_per_resolution = CENT / 4;
    first_policy.aggregate_batch_fee_cap = CENT / 2;
    bilingual_str policy_error;
    BOOST_REQUIRE(wallet->SetShadowPowClaimRecoveryPolicy(
        first_policy, policy_error));

    ShadowPowClaimRecoveryRequest request;
    request.origin = ShadowPowClaimRecoveryOrigin::AUTOMATIC;
    const ShadowPowClaimRecoveryReview before =
        wallet->GetShadowPowClaimRecoveryReview(request);
    BOOST_REQUIRE(before.available);
    BOOST_REQUIRE(before.consistent);
    BOOST_CHECK(before.policy == first_policy);
    BOOST_CHECK_EQUAL(before.plan.max_fee_per_resolution,
                      first_policy.max_fee_per_resolution);
    BOOST_CHECK_EQUAL(before.plan.aggregate_batch_fee_cap,
                      first_policy.aggregate_batch_fee_cap);
    BOOST_CHECK(before.active_tip == before.inventory.active_tip);
    BOOST_CHECK(before.active_tip == before.plan.active_tip);
    BOOST_CHECK_EQUAL(before.wallet_generation,
                      before.inventory.wallet_generation);
    BOOST_CHECK_EQUAL(before.wallet_generation,
                      before.plan.wallet_generation);

    CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    SyncRecoveryTestWalletTip(*wallet, *Assert(m_node.chainman));

    ShadowPowClaimRecoveryPolicy second_policy = first_policy;
    second_policy.max_fee_per_resolution = CENT / 2;
    second_policy.aggregate_batch_fee_cap = CENT;
    second_policy.rolling_fee_window_seconds = 12 * 60 * 60;
    BOOST_REQUIRE(wallet->SetShadowPowClaimRecoveryPolicy(
        second_policy, policy_error));
    // The in-memory mock database intentionally does not advance its update
    // counter on writes. Advance it explicitly to model an intervening wallet
    // mutation exactly as a production SQLite/BDB backend would.
    wallet->GetDatabase().nUpdateCounter.fetch_add(1);

    const ShadowPowClaimRecoveryReview after =
        wallet->GetShadowPowClaimRecoveryReview(request);
    BOOST_REQUIRE(after.available);
    BOOST_REQUIRE(after.consistent);
    BOOST_CHECK(after.policy == second_policy);
    BOOST_CHECK_EQUAL(after.plan.max_fee_per_resolution,
                      second_policy.max_fee_per_resolution);
    BOOST_CHECK_EQUAL(after.plan.aggregate_batch_fee_cap,
                      second_policy.aggregate_batch_fee_cap);
    BOOST_CHECK(after.active_tip == after.inventory.active_tip);
    BOOST_CHECK(after.active_tip == after.plan.active_tip);
    BOOST_CHECK_EQUAL(after.wallet_generation,
                      after.inventory.wallet_generation);
    BOOST_CHECK_EQUAL(after.wallet_generation,
                      after.plan.wallet_generation);

    // Both immutable refresh results remain internally coherent even though
    // policy, chain tip, and wallet database generation changed between them.
    BOOST_CHECK(before.active_tip != after.active_tip);
    BOOST_CHECK(before.active_height < after.active_height);
    BOOST_CHECK(before.wallet_generation < after.wallet_generation);
    BOOST_CHECK(before.policy == first_policy);
    BOOST_CHECK(after.policy == second_policy);
}

BOOST_AUTO_TEST_CASE(full_graph_groups_conflicts_branches_and_independent_anchors)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);

    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    const int branch_height = tip->nHeight;
    const uint256 branch_tip = tip->GetBlockHash();
    const CBlockIndex* genesis = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Genesis());
    BOOST_REQUIRE(genesis);

    const CTransactionRef anchor_tx_a = m_coinbase_txns.at(0);
    const CTransactionRef anchor_tx_b = m_coinbase_txns.at(1);
    const COutPoint anchor_a{anchor_tx_a->GetHash(), 0};
    const COutPoint anchor_b{anchor_tx_b->GetHash(), 0};
    const CScript wallet_script = anchor_tx_a->vout.at(0).scriptPubKey;

    const CTransactionRef root_a = MakeRecoveryTestClaim(
        anchor_a, anchor_tx_a->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    const CTransactionRef root_b = MakeRecoveryTestClaim(
        anchor_a,
        anchor_tx_a->vout.at(0).nValue - 2 * DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    const CTransactionRef child_a = MakeRecoveryTestClaim(
        COutPoint{root_a->GetHash(), 0},
        root_a->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    const CTransactionRef child_b = MakeRecoveryTestClaim(
        COutPoint{root_b->GetHash(), 0},
        root_b->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    const CTransactionRef independent = MakeRecoveryTestClaim(
        anchor_b, anchor_tx_b->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);

    for (const CTransactionRef& claim :
         {root_a, root_b, child_a, child_b, independent}) {
        AddRecoveryTestClaim(*wallet, claim, branch_height, branch_tip,
                             genesis->nHeight, genesis->GetBlockHash());
    }
    {
        LOCK(wallet->cs_wallet);
        wallet->mapWallet.at(independent->GetHash())
            .mapValue[SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY] =
            uint256{99}.GetHex();
    }

    // Every wallet-known proof object must remain visible, even when its
    // ancestry and debit cannot be authenticated.
    const CTransactionRef foreign = MakeRecoveryTestClaim(
        COutPoint{uint256{124}, 7}, COIN, wallet_script);
    AddRecoveryTestClaim(*wallet, foreign, branch_height, branch_tip,
                         genesis->nHeight, genesis->GetBlockHash(),
                         /*explicit_authored=*/false);

    const ShadowPowClaimRecoveryInventory first =
        wallet->GetShadowPowClaimRecoveryInventory();
    const ShadowPowClaimRecoveryInventory repeat =
        wallet->GetShadowPowClaimRecoveryInventory();
    BOOST_REQUIRE(first.wallet_tip_matches);
    ShadowPowClaimRecoveryRequest review_request;
    const ShadowPowClaimRecoveryReview review =
        wallet->GetShadowPowClaimRecoveryReview(review_request);
    BOOST_CHECK(review.available);
    BOOST_CHECK(review.consistent);
    BOOST_CHECK(review.status ==
                ShadowPowClaimRecoveryReviewStatus::AVAILABLE);
    BOOST_CHECK_EQUAL(review.reason_code, "available");
    BOOST_CHECK(review.active_tip == first.active_tip);
    BOOST_CHECK_EQUAL(review.active_height, first.active_height);
    BOOST_CHECK_EQUAL(review.wallet_generation, first.wallet_generation);
    BOOST_CHECK(review.inventory.active_tip == review.plan.active_tip);
    BOOST_CHECK_EQUAL(review.inventory.active_height,
                      review.plan.active_height);
    BOOST_CHECK_EQUAL(review.inventory.wallet_generation,
                      review.plan.wallet_generation);
    BOOST_CHECK_EQUAL(review.usage.pending_manual, 0U);
    BOOST_CHECK_EQUAL(review.usage.pending_automatic, 0U);
    BOOST_CHECK_EQUAL(first.raw_claim_objects, 6U);
    BOOST_CHECK_EQUAL(first.components.size(), 3U);
    BOOST_CHECK_EQUAL(first.unanchored_claim_txids.size(), 1U);
    BOOST_CHECK(first.unanchored_claim_txids.front() == foreign->GetHash());

    const auto& component_a = FindRecoveryComponent(first, anchor_a);
    BOOST_CHECK(component_a.anchor_authenticated);
    BOOST_CHECK(component_a.anchor_unspent);
    BOOST_CHECK_EQUAL(component_a.claim_txids.size(), 4U);
    BOOST_CHECK_EQUAL(component_a.root_claim_txids.size(), 2U);
    BOOST_CHECK_EQUAL(component_a.descendant_claims, 2U);
    BOOST_CHECK(component_a.all_claims_quarantined);
    BOOST_CHECK(component_a.all_claims_explicitly_provenanced);
    BOOST_CHECK(component_a.stale_depth_known);
    BOOST_CHECK_EQUAL(component_a.minimum_stale_depth, 0);

    const auto& component_b = FindRecoveryComponent(first, anchor_b);
    BOOST_CHECK_EQUAL(component_b.claim_txids.size(), 1U);
    BOOST_CHECK_EQUAL(component_b.root_claim_txids.size(), 1U);
    BOOST_CHECK_EQUAL(component_b.descendant_claims, 0U);
    BOOST_CHECK(!component_b.stale_depth_known);

    // The immutable first observation is 100 blocks old, but the valid
    // branch-qualified observation is at this tip. Only the latter drives the
    // separately exposed stale age; typed state is policy-independent.
    if (component_a.has_transient_claim) {
        BOOST_CHECK(component_a.state == ShadowPowClaimRecoveryState::TRANSIENT);
    } else if (component_a.all_claims_terminal_on_pinned_tip) {
        BOOST_CHECK(component_a.state ==
                        ShadowPowClaimRecoveryState::TERMINAL_ON_PINNED_TIP ||
                    component_a.state ==
                        ShadowPowClaimRecoveryState::CURRENT_BRANCH_INELIGIBLE);
    }

    BOOST_REQUIRE_EQUAL(first.components.size(), repeat.components.size());
    for (size_t i = 0; i < first.components.size(); ++i) {
        BOOST_CHECK(first.components[i].fingerprint ==
                    repeat.components[i].fingerprint);
    }

    // A wallet-known ordinary descendant makes the whole anchor component
    // mixed. It must fail closed instead of being silently omitted.
    CMutableTransaction ordinary;
    ordinary.vin.emplace_back(COutPoint{root_a->GetHash(), 0});
    ordinary.vout.emplace_back(
        root_a->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    const CTransactionRef ordinary_ref =
        MakeTransactionRef(std::move(ordinary));
    BOOST_REQUIRE(wallet->AddToWallet(ordinary_ref, TxStateInactive{}));

    const ShadowPowClaimRecoveryInventory mixed =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& mixed_a = FindRecoveryComponent(mixed, anchor_a);
    BOOST_CHECK(mixed_a.state == ShadowPowClaimRecoveryState::INDETERMINATE);
    BOOST_CHECK(mixed_a.has_indeterminate_node);
    BOOST_CHECK_EQUAL(mixed_a.ordinary_or_mixed_txids.size(), 1U);
    BOOST_CHECK(mixed_a.ordinary_or_mixed_txids.front() ==
                ordinary_ref->GetHash());
    BOOST_CHECK(mixed_a.fingerprint != component_a.fingerprint);
    BOOST_CHECK(FindRecoveryComponent(mixed, anchor_b).fingerprint ==
                component_b.fingerprint);

    // Local abandonment never turns an ordinary transaction into a claim.
    // Preserve it in the audit graph, but keep the complete component blocked
    // for both manual and automatic recovery.
    BOOST_REQUIRE(wallet->AbandonTransaction(ordinary_ref->GetHash()));
    const ShadowPowClaimRecoveryInventory abandoned_descendant =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& abandoned_a =
        FindRecoveryComponent(abandoned_descendant, anchor_a);
    BOOST_CHECK(abandoned_a.state ==
                ShadowPowClaimRecoveryState::INDETERMINATE);
    BOOST_CHECK(abandoned_a.has_indeterminate_node);
    BOOST_REQUIRE_EQUAL(abandoned_a.ordinary_or_mixed_txids.size(), 1U);
    BOOST_CHECK(abandoned_a.ordinary_or_mixed_txids.front() ==
                ordinary_ref->GetHash());
    const auto abandoned_node = std::find_if(
        abandoned_a.nodes.begin(), abandoned_a.nodes.end(),
        [&](const ShadowPowClaimRecoveryNode& node) {
            return node.txid == ordinary_ref->GetHash();
        });
    BOOST_REQUIRE(abandoned_node != abandoned_a.nodes.end());
    BOOST_CHECK(abandoned_node->abandoned);
    BOOST_CHECK(abandoned_a.fingerprint != mixed_a.fingerprint);

    ShadowPowClaimRecoveryRequest abandoned_manual;
    abandoned_manual.selectors = {root_a->GetHash()};
    const ShadowPowClaimRecoveryPlan abandoned_plan =
        wallet->PlanShadowPowClaimRecovery(abandoned_manual);
    BOOST_CHECK(abandoned_plan.actions.empty());
    BOOST_REQUIRE_EQUAL(abandoned_plan.refused.size(), 1U);
    BOOST_CHECK_EQUAL(abandoned_plan.refused.front().reason_code,
                      "ordinary-conflict");

    // Local abandonment is not sufficient for an ordinary transaction that
    // itself spends the confirmed anchor: a peer may still confirm those
    // retained bytes independently of every terminal claim descendant.
    CMutableTransaction direct_anchor_spend;
    direct_anchor_spend.vin.emplace_back(anchor_a);
    direct_anchor_spend.vout.emplace_back(
        anchor_tx_a->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    const CTransactionRef direct_anchor_ref =
        MakeTransactionRef(std::move(direct_anchor_spend));
    BOOST_REQUIRE(wallet->AddToWallet(direct_anchor_ref, TxStateInactive{}));
    BOOST_REQUIRE(wallet->AbandonTransaction(direct_anchor_ref->GetHash()));
    const ShadowPowClaimRecoveryInventory direct_anchor_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& direct_anchor_blocked =
        FindRecoveryComponent(direct_anchor_inventory, anchor_a);
    BOOST_CHECK(direct_anchor_blocked.state ==
                ShadowPowClaimRecoveryState::INDETERMINATE);
    BOOST_CHECK(std::find(
                    direct_anchor_blocked.ordinary_or_mixed_txids.begin(),
                    direct_anchor_blocked.ordinary_or_mixed_txids.end(),
                    direct_anchor_ref->GetHash()) !=
                direct_anchor_blocked.ordinary_or_mixed_txids.end());
}

BOOST_AUTO_TEST_CASE(historical_three_anchor_forest_collapses_to_three_current_actions)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    // Sanitized reproduction of the reported alpha-era topology: three
    // independent confirmed anchors, three claim branches per anchor, and six
    // claims per branch. This produces 54 claims and nine leaves without
    // retaining any production wallet identifiers or transaction bytes.
    std::vector<COutPoint> anchors;
    for (size_t anchor_index = 0; anchor_index < 3; ++anchor_index) {
        const CTransactionRef& anchor_tx = m_coinbase_txns.at(anchor_index);
        const COutPoint anchor{anchor_tx->GetHash(), 0};
        const CScript& wallet_script =
            anchor_tx->vout.at(0).scriptPubKey;
        anchors.push_back(anchor);

        for (size_t branch = 0; branch < 3; ++branch) {
            COutPoint input = anchor;
            CAmount value = anchor_tx->vout.at(0).nValue -
                            static_cast<CAmount>(branch + 1) *
                                DEFAULT_TRANSACTION_MAXFEE;
            for (size_t depth = 0; depth < 6; ++depth) {
                const CTransactionRef claim = MakeRecoveryTestClaim(
                    input, value, wallet_script);
                AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                                     tip->GetBlockHash(), tip->nHeight,
                                     tip->GetBlockHash());
                input = COutPoint{claim->GetHash(), 0};
                value -= DEFAULT_TRANSACTION_MAXFEE;
            }
        }
    }

    const ShadowPowClaimRecoveryInventory inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    BOOST_REQUIRE(inventory.wallet_tip_matches);
    BOOST_CHECK_EQUAL(inventory.raw_claim_objects, 54U);
    BOOST_CHECK_EQUAL(wallet->CountQuarantinedShadowPowClaims(), 54U);
    BOOST_CHECK_EQUAL(
        wallet->CountQuarantinedShadowPowClaims(),
        wallet->GetShadowPowClaimInventory().BlockingClaims());
    BOOST_CHECK_EQUAL(inventory.components.size(), 3U);
    BOOST_CHECK(inventory.unanchored_claim_txids.empty());
    for (const COutPoint& anchor : anchors) {
        const auto& component = FindRecoveryComponent(inventory, anchor);
        BOOST_CHECK_EQUAL(component.claim_txids.size(), 18U);
        BOOST_CHECK_EQUAL(component.root_claim_txids.size(), 3U);
        BOOST_CHECK_EQUAL(component.descendant_claims, 15U);
        BOOST_CHECK(component.anchor_authenticated);
        BOOST_CHECK(component.anchor_unspent);
        BOOST_CHECK(component.all_claims_quarantined);
        BOOST_CHECK(component.all_claims_explicitly_provenanced);
        BOOST_CHECK(component.state ==
                    ShadowPowClaimRecoveryState::CURRENT_BRANCH_INELIGIBLE);
        BOOST_CHECK(component.has_revalidating_unbound_proof);
        for (const auto& node : component.nodes) {
            if (node.kind != ShadowPowClaimRecoveryNodeKind::CLAIM) continue;
            BOOST_CHECK(node.proof_may_revalidate_on_descendant);
            BOOST_CHECK(node.disposition ==
                        ShadowPowClaimMempoolDisposition::UNBOUND_PROOF_MAY_REVALIDATE);
        }
    }

    ShadowPowClaimRecoveryRequest request;
    const ShadowPowClaimRecoveryPlan plan =
        wallet->PlanShadowPowClaimRecovery(request);
    BOOST_REQUIRE(plan.complete);
    BOOST_CHECK(plan.refused.empty());
    BOOST_REQUIRE_EQUAL(plan.actions.size(), 3U);
    size_t affected_claims{0};
    size_t collapsed_descendants{0};
    for (const ShadowPowClaimRecoveryAction& action : plan.actions) {
        BOOST_CHECK(std::find(anchors.begin(), anchors.end(),
                              action.anchor) != anchors.end());
        BOOST_CHECK_EQUAL(action.claim_txids.size(), 18U);
        BOOST_CHECK_EQUAL(action.descendant_claims, 15U);
        BOOST_CHECK(action.component_state ==
                    ShadowPowClaimRecoveryState::CURRENT_BRANCH_INELIGIBLE);
        BOOST_CHECK(action.conflicts_with_revalidating_unbound_proof);
        BOOST_CHECK_EQUAL(action.reason_code,
                          "unbound-proof-may-revalidate");
        BOOST_REQUIRE(action.transaction);
        BOOST_REQUIRE_EQUAL(action.transaction->vin.size(), 1U);
        BOOST_CHECK(action.transaction->vin.front().prevout ==
                    action.anchor);
        affected_claims += action.claim_txids.size();
        collapsed_descendants += action.descendant_claims;
    }
    BOOST_CHECK_EQUAL(affected_claims, 54U);
    BOOST_CHECK_EQUAL(collapsed_descendants, 45U);

    // The same shared batch resolver signs exactly one transaction per
    // confirmed anchor, not one per historical claim object. SIGN_ONLY must
    // persist all three exact drafts without granting relay authority.
    ShadowPowClaimRecoveryRequest sign_request = request;
    sign_request.mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
    sign_request.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
    sign_request.acknowledge_fee_and_conflict_risk = true;
    sign_request.expected_plan_id = plan.plan_id;
    const ShadowPowClaimRecoveryResult signed_batch =
        wallet->ResolveShadowPowClaims(sign_request);
    BOOST_REQUIRE_MESSAGE(signed_batch.success, signed_batch.error);
    BOOST_CHECK(signed_batch.durable_state_changed);
    BOOST_CHECK_EQUAL(signed_batch.signed_and_persisted, 3U);
    BOOST_CHECK_EQUAL(signed_batch.relay_authority_granted, 0U);
    BOOST_CHECK_EQUAL(signed_batch.broadcast, 0U);
    BOOST_CHECK_EQUAL(wallet->CountQuarantinedShadowPowClaims(), 54U);
    BOOST_REQUIRE_EQUAL(signed_batch.plan.actions.size(), 3U);
    for (const ShadowPowClaimRecoveryAction& action :
         signed_batch.plan.actions) {
        BOOST_CHECK(action.status ==
                    ShadowPowClaimRecoveryActionStatus::SIGNED_AND_PERSISTED);
        BOOST_CHECK(action.persisted);
        BOOST_CHECK(!action.relay_authorized);
        BOOST_CHECK(action.conflicts_with_revalidating_unbound_proof);
        BOOST_CHECK_EQUAL(action.reason_code,
                          "unbound-proof-may-revalidate");
        BOOST_REQUIRE(action.transaction);
        BOOST_CHECK_EQUAL(action.vsize,
                          GetVirtualTransactionSize(*action.transaction));
    }

    const ShadowPowClaimRecoveryPlan persisted =
        wallet->PlanShadowPowClaimRecovery(request);
    BOOST_REQUIRE_EQUAL(persisted.actions.size(), 3U);
    for (const ShadowPowClaimRecoveryAction& action : persisted.actions) {
        BOOST_CHECK(action.status ==
                    ShadowPowClaimRecoveryActionStatus::REUSE_MANAGED);
        BOOST_CHECK(action.persisted);
        BOOST_CHECK(!action.relay_authorized);
        BOOST_CHECK(action.conflicts_with_revalidating_unbound_proof);
        BOOST_CHECK_EQUAL(action.reason_code,
                          "unbound-proof-may-revalidate");
    }
}

BOOST_AUTO_TEST_CASE(historical_imported_forest_requires_atomic_component_adoption)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    BOOST_REQUIRE(tip->pprev);
    const CBlockIndex* stale_observation = tip->pprev;

    std::vector<COutPoint> anchors;
    for (size_t anchor_index = 0; anchor_index < 3; ++anchor_index) {
        const CTransactionRef& anchor_tx = m_coinbase_txns.at(anchor_index);
        const COutPoint anchor{anchor_tx->GetHash(), 0};
        const CScript& wallet_script = anchor_tx->vout.at(0).scriptPubKey;
        anchors.push_back(anchor);

        for (size_t branch = 0; branch < 3; ++branch) {
            COutPoint input = anchor;
            CAmount value = anchor_tx->vout.at(0).nValue -
                            static_cast<CAmount>(branch + 1) *
                                DEFAULT_TRANSACTION_MAXFEE;
            for (size_t depth = 0; depth < 6; ++depth) {
                const CTransactionRef claim = MakeRecoveryTestClaim(
                    input, value, wallet_script);
                AddRecoveryTestClaim(
                    *wallet, claim, stale_observation->nHeight,
                    stale_observation->GetBlockHash(),
                    stale_observation->nHeight,
                    stale_observation->GetBlockHash(),
                    /*explicit_authored=*/false);
                input = COutPoint{claim->GetHash(), 0};
                value -= DEFAULT_TRANSACTION_MAXFEE;
            }
        }
    }

    const ShadowPowClaimRecoveryInventory imported =
        wallet->GetShadowPowClaimRecoveryInventory();
    BOOST_REQUIRE_EQUAL(imported.raw_claim_objects, 54U);
    BOOST_REQUIRE_EQUAL(imported.components.size(), 3U);
    for (const COutPoint& anchor : anchors) {
        const auto& component = FindRecoveryComponent(imported, anchor);
        BOOST_CHECK_EQUAL(component.claim_txids.size(), 18U);
        BOOST_CHECK(!component.all_claims_explicitly_provenanced);
    }

    wallet->SetBroadcastTransactions(/*broadcast=*/true);
    wallet->m_pow_mining_enabled.store(true);
    ShadowPowClaimRecoveryPolicy policy =
        DefaultShadowPowClaimRecoveryPolicy();
    policy.choice_recorded = 1;
    policy.automatic_enabled = 1;
    policy.minimum_stale_blocks = 1;
    policy.max_actions_per_window = 10;
    bilingual_str policy_error;
    BOOST_REQUIRE(wallet->SetShadowPowClaimRecoveryPolicy(policy,
                                                           policy_error));

    ShadowPowClaimRecoveryRequest automatic_request;
    automatic_request.origin = ShadowPowClaimRecoveryOrigin::AUTOMATIC;
    const ShadowPowClaimRecoveryPlan before_adoption =
        wallet->PlanShadowPowClaimRecovery(automatic_request);
    BOOST_REQUIRE(before_adoption.complete);
    BOOST_CHECK(before_adoption.actions.empty());
    BOOST_REQUIRE_EQUAL(before_adoption.refused.size(), 3U);
    for (const ShadowPowClaimRecoveryAction& refused :
         before_adoption.refused) {
        BOOST_CHECK_EQUAL(refused.reason_code,
                          "automatic-provenance-missing");
    }

    for (const COutPoint& anchor : anchors) {
        const ShadowPowClaimRecoveryInventory current =
            wallet->GetShadowPowClaimRecoveryInventory();
        const auto& component = FindRecoveryComponent(current, anchor);
        BOOST_REQUIRE_EQUAL(component.claim_txids.size(), 18U);
        const ShadowPowClaimRecoveryAdoptionResult adopted =
            wallet->AdoptShadowPowClaimRecoveryComponent(
                component.claim_txids.front(), current.active_tip,
                component.fingerprint);
        BOOST_REQUIRE_MESSAGE(adopted.IsSuccess(), adopted.detail);
        BOOST_CHECK(adopted.status ==
                    ShadowPowClaimRecoveryAdoptionStatus::SUCCESS);
        BOOST_REQUIRE_EQUAL(adopted.claim_txids.size(), 18U);
    }

    const ShadowPowClaimRecoveryInventory adopted =
        wallet->GetShadowPowClaimRecoveryInventory();
    BOOST_REQUIRE_EQUAL(adopted.raw_claim_objects, 54U);
    BOOST_REQUIRE_EQUAL(adopted.components.size(), 3U);
    for (const COutPoint& anchor : anchors) {
        const auto& component = FindRecoveryComponent(adopted, anchor);
        BOOST_CHECK(component.all_claims_explicitly_provenanced);
        BOOST_REQUIRE_EQUAL(component.claim_txids.size(), 18U);
        for (const ShadowPowClaimRecoveryNode& node : component.nodes) {
            if (node.kind != ShadowPowClaimRecoveryNodeKind::CLAIM) continue;
            BOOST_CHECK(node.provenance ==
                        ShadowPowClaimRecoveryProvenance::EXPLICIT_ADOPTED);
            BOOST_CHECK(node.adoption_metadata_valid);
        }
    }

    const ShadowPowClaimRecoveryPlan after_adoption =
        wallet->PlanShadowPowClaimRecovery(automatic_request);
    BOOST_REQUIRE(after_adoption.complete);
    BOOST_CHECK(after_adoption.refused.empty());
    BOOST_REQUIRE_EQUAL(after_adoption.actions.size(), 3U);
    size_t affected_claims{0};
    for (const ShadowPowClaimRecoveryAction& action :
         after_adoption.actions) {
        BOOST_CHECK(std::find(anchors.begin(), anchors.end(),
                              action.anchor) != anchors.end());
        BOOST_CHECK_EQUAL(action.claim_txids.size(), 18U);
        BOOST_CHECK_EQUAL(action.descendant_claims, 15U);
        affected_claims += action.claim_txids.size();
    }
    BOOST_CHECK_EQUAL(affected_claims, 54U);
}

BOOST_AUTO_TEST_CASE(explicit_provenance_requires_complete_authenticated_metadata)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    const CTransactionRef authored_anchor_tx = m_coinbase_txns.at(0);
    const CTransactionRef adopted_anchor_tx = m_coinbase_txns.at(1);
    const COutPoint authored_anchor{authored_anchor_tx->GetHash(), 0};
    const COutPoint adopted_anchor{adopted_anchor_tx->GetHash(), 0};
    const CScript wallet_script =
        authored_anchor_tx->vout.at(0).scriptPubKey;
    const CTransactionRef authored_claim = MakeRecoveryTestClaim(
        authored_anchor,
        authored_anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    const CTransactionRef adopted_claim = MakeRecoveryTestClaim(
        adopted_anchor,
        adopted_anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);

    AddRecoveryTestClaim(*wallet, authored_claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash(), /*explicit_authored=*/false);
    AddRecoveryTestClaim(*wallet, adopted_claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash(), /*explicit_authored=*/false);
    {
        LOCK(wallet->cs_wallet);
        wallet->mapWallet.at(authored_claim->GetHash())
            .mapValue[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
        wallet->mapWallet.at(adopted_claim->GetHash())
            .mapValue[SHADOW_POW_CLAIM_ADOPTED_KEY] = "1";
    }

    const ShadowPowClaimRecoveryInventory bare =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& bare_authored =
        FindRecoveryComponent(bare, authored_anchor);
    const auto& bare_adopted =
        FindRecoveryComponent(bare, adopted_anchor);
    BOOST_REQUIRE_EQUAL(bare_authored.nodes.size(), 1U);
    BOOST_REQUIRE_EQUAL(bare_adopted.nodes.size(), 1U);
    BOOST_CHECK(bare_authored.nodes.front().provenance ==
                ShadowPowClaimRecoveryProvenance::UNKNOWN);
    BOOST_CHECK(!bare_authored.nodes.front().authored_metadata_valid);
    BOOST_CHECK(!bare_authored.all_claims_explicitly_provenanced);
    BOOST_CHECK(bare_adopted.nodes.front().provenance ==
                ShadowPowClaimRecoveryProvenance::UNKNOWN);
    BOOST_CHECK(!bare_adopted.nodes.front().adoption_metadata_valid);
    BOOST_CHECK(!bare_adopted.all_claims_explicitly_provenanced);

    {
        LOCK(wallet->cs_wallet);
        CWalletTx& authored =
            wallet->mapWallet.at(authored_claim->GetHash());
        authored.mapValue[SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY] =
            ToString(tip->nHeight);
        authored.mapValue[SHADOW_POW_CLAIM_CREATED_TIP_KEY] =
            tip->GetBlockHash().GetHex();

        CWalletTx& adopted = wallet->mapWallet.at(adopted_claim->GetHash());
        adopted.mapValue[SHADOW_POW_CLAIM_ADOPTION_TIP_KEY] =
            tip->GetBlockHash().GetHex();
        adopted.mapValue[SHADOW_POW_CLAIM_ADOPTION_FINGERPRINT_KEY] =
            bare_authored.generation_fingerprint.GetHex();
    }

    const ShadowPowClaimRecoveryInventory mismatched_adoption =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& complete_authored =
        FindRecoveryComponent(mismatched_adoption, authored_anchor);
    const auto& wrong_adoption =
        FindRecoveryComponent(mismatched_adoption, adopted_anchor);
    BOOST_CHECK(complete_authored.nodes.front().provenance ==
                ShadowPowClaimRecoveryProvenance::EXPLICIT_AUTHORED);
    BOOST_CHECK(complete_authored.nodes.front().authored_metadata_valid);
    BOOST_CHECK(complete_authored.nodes.front().created_tip ==
                tip->GetBlockHash());
    BOOST_CHECK(complete_authored.all_claims_explicitly_provenanced);
    BOOST_CHECK(wrong_adoption.nodes.front().provenance ==
                ShadowPowClaimRecoveryProvenance::UNKNOWN);
    BOOST_CHECK(!wrong_adoption.nodes.front().adoption_metadata_valid);

    {
        LOCK(wallet->cs_wallet);
        wallet->mapWallet.at(adopted_claim->GetHash())
            .mapValue[SHADOW_POW_CLAIM_ADOPTION_FINGERPRINT_KEY] =
            wrong_adoption.generation_fingerprint.GetHex();
    }
    const ShadowPowClaimRecoveryInventory adopted =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& complete_adopted =
        FindRecoveryComponent(adopted, adopted_anchor);
    BOOST_CHECK(complete_adopted.nodes.front().provenance ==
                ShadowPowClaimRecoveryProvenance::EXPLICIT_ADOPTED);
    BOOST_CHECK(complete_adopted.nodes.front().adoption_metadata_valid);
    BOOST_CHECK(complete_adopted.nodes.front().adoption_tip ==
                tip->GetBlockHash());
    BOOST_CHECK(complete_adopted.nodes.front()
                    .adoption_generation_fingerprint ==
                complete_adopted.generation_fingerprint);
    BOOST_CHECK(complete_adopted.all_claims_explicitly_provenanced);
}

BOOST_AUTO_TEST_CASE(component_adoption_has_typed_atomic_outcomes)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CScript script = anchor_tx->vout.at(0).scriptPubKey;
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        script);
    AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash(), /*explicit_authored=*/false);

    const ShadowPowClaimRecoveryInventory initial =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& initial_component = FindRecoveryComponent(initial, anchor);
    BOOST_CHECK(!initial_component.all_claims_explicitly_provenanced);

    const ShadowPowClaimRecoveryAdoptionResult not_found =
        wallet->AdoptShadowPowClaimRecoveryComponent(
            uint256S("03e7"), initial.active_tip,
            initial_component.fingerprint);
    BOOST_CHECK(not_found.status ==
                ShadowPowClaimRecoveryAdoptionStatus::SELECTOR_NOT_FOUND);
    BOOST_CHECK(!not_found.IsSuccess());
    BOOST_CHECK(!not_found.durable_state_changed);

    const ShadowPowClaimRecoveryAdoptionResult stale_tip =
        wallet->AdoptShadowPowClaimRecoveryComponent(
            claim->GetHash(), uint256S("03e6"),
            initial_component.fingerprint);
    BOOST_CHECK(stale_tip.status ==
                ShadowPowClaimRecoveryAdoptionStatus::STALE_TIP);
    BOOST_CHECK(!stale_tip.durable_state_changed);

    const ShadowPowClaimRecoveryAdoptionResult stale_fingerprint =
        wallet->AdoptShadowPowClaimRecoveryComponent(
            claim->GetHash(), initial.active_tip, uint256S("03e5"));
    BOOST_CHECK(stale_fingerprint.status ==
                ShadowPowClaimRecoveryAdoptionStatus::STALE_COMPONENT_FINGERPRINT);
    BOOST_CHECK(!stale_fingerprint.durable_state_changed);

    {
        LOCK(wallet->cs_wallet);
        wallet->m_wallet_unlock_staking_only = true;
    }
    const ShadowPowClaimRecoveryAdoptionResult unavailable =
        wallet->AdoptShadowPowClaimRecoveryComponent(
            claim->GetHash(), initial.active_tip,
            initial_component.fingerprint);
    {
        LOCK(wallet->cs_wallet);
        wallet->m_wallet_unlock_staking_only = false;
    }
    BOOST_CHECK(unavailable.status ==
                ShadowPowClaimRecoveryAdoptionStatus::SIGNING_UNAVAILABLE);
    BOOST_CHECK(!unavailable.durable_state_changed);

    const ShadowPowClaimRecoveryAdoptionResult adopted =
        wallet->AdoptShadowPowClaimRecoveryComponent(
            claim->GetHash(), initial.active_tip,
            initial_component.fingerprint);
    BOOST_REQUIRE_MESSAGE(adopted.IsSuccess(), adopted.detail);
    BOOST_CHECK(adopted.status ==
                ShadowPowClaimRecoveryAdoptionStatus::SUCCESS);
    BOOST_CHECK(adopted.adopted);
    BOOST_CHECK(adopted.durable_state_changed);
    BOOST_CHECK(!adopted.durable_state_ambiguous);
    BOOST_CHECK(adopted.active_tip == initial.active_tip);
    BOOST_CHECK(adopted.generation_fingerprint ==
                initial_component.generation_fingerprint);
    BOOST_CHECK(adopted.reviewed_component_fingerprint ==
                initial_component.fingerprint);
    BOOST_REQUIRE(!adopted.post_adoption_component_fingerprint.IsNull());
    BOOST_CHECK(adopted.automatic_eligible_after_adoption);
    BOOST_CHECK(adopted.component_has_revalidating_unbound_proof);
    BOOST_REQUIRE_EQUAL(adopted.claim_txids.size(), 1U);
    BOOST_CHECK(adopted.claim_txids.front() == claim->GetHash());

    const ShadowPowClaimRecoveryInventory after =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& after_component = FindRecoveryComponent(after, anchor);
    BOOST_CHECK(after_component.fingerprint ==
                adopted.post_adoption_component_fingerprint);
    BOOST_CHECK(after_component.all_claims_explicitly_provenanced);
    const auto claim_node = std::find_if(
        after_component.nodes.begin(), after_component.nodes.end(),
        [&](const ShadowPowClaimRecoveryNode& node) {
            return node.txid == claim->GetHash();
        });
    BOOST_REQUIRE(claim_node != after_component.nodes.end());
    BOOST_CHECK(claim_node->provenance ==
                ShadowPowClaimRecoveryProvenance::EXPLICIT_ADOPTED);

    const ShadowPowClaimRecoveryAdoptionResult repeated =
        wallet->AdoptShadowPowClaimRecoveryComponent(
            claim->GetHash(), after.active_tip,
            after_component.fingerprint);
    BOOST_CHECK(repeated.IsSuccess());
    BOOST_CHECK(repeated.status ==
                ShadowPowClaimRecoveryAdoptionStatus::ALREADY_EXPLICIT);
    BOOST_CHECK(!repeated.adopted);
    BOOST_CHECK(!repeated.durable_state_changed);
    BOOST_CHECK(repeated.automatic_eligible_after_adoption);
    BOOST_CHECK(repeated.component_has_revalidating_unbound_proof);

    // A selector must name a claim, not merely any node in its graph.
    CMutableTransaction descendant;
    descendant.vin.emplace_back(COutPoint{claim->GetHash(), 0});
    descendant.vout.emplace_back(
        claim->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE, script);
    const CTransactionRef descendant_ref =
        MakeTransactionRef(std::move(descendant));
    BOOST_REQUIRE(wallet->AddToWallet(descendant_ref, TxStateInactive{}));
    const ShadowPowClaimRecoveryInventory mixed =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& mixed_component = FindRecoveryComponent(mixed, anchor);
    const ShadowPowClaimRecoveryAdoptionResult not_claim =
        wallet->AdoptShadowPowClaimRecoveryComponent(
            descendant_ref->GetHash(), mixed.active_tip,
            mixed_component.fingerprint);
    BOOST_CHECK(not_claim.status ==
                ShadowPowClaimRecoveryAdoptionStatus::SELECTOR_NOT_CLAIM);
    BOOST_CHECK(!not_claim.durable_state_changed);

    // Local abandonment does not convert an ordinary descendant into a claim.
    // Even an already-explicit claim component must be refused while that
    // ordinary node remains in its audit graph.
    BOOST_REQUIRE(wallet->AbandonTransaction(descendant_ref->GetHash()));
    const ShadowPowClaimRecoveryInventory reviewed =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& reviewed_component = FindRecoveryComponent(reviewed, anchor);
    BOOST_REQUIRE_EQUAL(reviewed_component.ordinary_or_mixed_txids.size(), 1U);
    BOOST_CHECK(reviewed_component.ordinary_or_mixed_txids.front() ==
                descendant_ref->GetHash());
    const ShadowPowClaimRecoveryAdoptionResult unsafe_abandoned =
        wallet->AdoptShadowPowClaimRecoveryComponent(
            claim->GetHash(), reviewed.active_tip,
            reviewed_component.fingerprint);
    BOOST_CHECK(unsafe_abandoned.status ==
                ShadowPowClaimRecoveryAdoptionStatus::UNSAFE_GRAPH);
    BOOST_CHECK_EQUAL(unsafe_abandoned.component_refusal_code,
                      "ordinary-conflict");
    BOOST_CHECK(!unsafe_abandoned.adopted);
    BOOST_CHECK(!unsafe_abandoned.durable_state_changed);
}

BOOST_AUTO_TEST_CASE(component_adoption_fails_closed_for_unsafe_and_ambiguous_state)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto make_unknown_claim_wallet = [&]() {
        return CreateSyncedWallet(
            *m_node.chain,
            WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                      return m_node.chainman->ActiveChain()),
            coinbaseKey);
    };
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    auto unsafe_wallet = make_unknown_claim_wallet();
    const CTransactionRef unsafe_anchor_tx = m_coinbase_txns.at(1);
    const COutPoint unsafe_anchor{unsafe_anchor_tx->GetHash(), 0};
    const CScript script = unsafe_anchor_tx->vout.at(0).scriptPubKey;
    const CTransactionRef unsafe_claim = MakeRecoveryTestClaim(
        unsafe_anchor,
        unsafe_anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        script);
    AddRecoveryTestClaim(*unsafe_wallet, unsafe_claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash(), /*explicit_authored=*/false);
    CMutableTransaction direct_conflict;
    direct_conflict.vin.emplace_back(unsafe_anchor);
    direct_conflict.vout.emplace_back(
        unsafe_anchor_tx->vout.at(0).nValue - 2 * DEFAULT_TRANSACTION_MAXFEE,
        script);
    BOOST_REQUIRE(unsafe_wallet->AddToWallet(
        MakeTransactionRef(std::move(direct_conflict)),
        TxStateInactive{}));
    const ShadowPowClaimRecoveryInventory unsafe_inventory =
        unsafe_wallet->GetShadowPowClaimRecoveryInventory();
    const auto& unsafe_component =
        FindRecoveryComponent(unsafe_inventory, unsafe_anchor);
    const ShadowPowClaimRecoveryAdoptionResult unsafe =
        unsafe_wallet->AdoptShadowPowClaimRecoveryComponent(
            unsafe_claim->GetHash(), unsafe_inventory.active_tip,
            unsafe_component.fingerprint);
    BOOST_CHECK(unsafe.status ==
                ShadowPowClaimRecoveryAdoptionStatus::UNSAFE_GRAPH);
    BOOST_CHECK_EQUAL(unsafe.component_refusal_code,
                      "ordinary-conflict");
    BOOST_CHECK(!unsafe.durable_state_changed);

    auto ambiguous_wallet = make_unknown_claim_wallet();
    const CTransactionRef ambiguous_anchor_tx = m_coinbase_txns.at(2);
    const COutPoint ambiguous_anchor{ambiguous_anchor_tx->GetHash(), 0};
    const CTransactionRef ambiguous_claim = MakeRecoveryTestClaim(
        ambiguous_anchor,
        ambiguous_anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        ambiguous_anchor_tx->vout.at(0).scriptPubKey);
    AddRecoveryTestClaim(*ambiguous_wallet, ambiguous_claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash(), /*explicit_authored=*/false);
    const ShadowPowClaimRecoveryInventory ambiguous_inventory =
        ambiguous_wallet->GetShadowPowClaimRecoveryInventory();
    const auto& ambiguous_component =
        FindRecoveryComponent(ambiguous_inventory, ambiguous_anchor);
    MockableDatabase& database = GetMockableDatabase(*ambiguous_wallet);
    database.m_fail_commit = true;
    const ShadowPowClaimRecoveryAdoptionResult ambiguous =
        ambiguous_wallet->AdoptShadowPowClaimRecoveryComponent(
            ambiguous_claim->GetHash(), ambiguous_inventory.active_tip,
            ambiguous_component.fingerprint);
    database.m_fail_commit = false;
    BOOST_CHECK(ambiguous.status ==
                ShadowPowClaimRecoveryAdoptionStatus::DATABASE_OUTCOME_AMBIGUOUS);
    BOOST_CHECK(!ambiguous.adopted);
    BOOST_CHECK(!ambiguous.durable_state_changed);
    BOOST_CHECK(ambiguous.durable_state_ambiguous);
    BOOST_CHECK(ambiguous_wallet->IsShadowPowClaimRecoveryDatabaseAmbiguous());

    // The in-memory record was never published after the indeterminate DB
    // commit; callers must reload instead of treating it as authoritative.
    const ShadowPowClaimRecoveryInventory ambiguous_after =
        ambiguous_wallet->GetShadowPowClaimRecoveryInventory();
    const auto& ambiguous_after_component =
        FindRecoveryComponent(ambiguous_after, ambiguous_anchor);
    BOOST_CHECK(!ambiguous_after_component.all_claims_explicitly_provenanced);
}

BOOST_AUTO_TEST_CASE(generic_retryable_claims_remain_refused)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/999,
                                         /*reward_start_height=*/1000,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        anchor_tx->vout.at(0).scriptPubKey);
    AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash());

    const ShadowPowClaimRecoveryInventory inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& component = FindRecoveryComponent(inventory, anchor);
    BOOST_REQUIRE_EQUAL(component.claim_txids.size(), 1U);
    BOOST_REQUIRE_EQUAL(component.nodes.size(), 1U);
    BOOST_CHECK(component.state == ShadowPowClaimRecoveryState::TRANSIENT);
    BOOST_CHECK(component.nodes.front().disposition ==
                ShadowPowClaimMempoolDisposition::HEIGHT_BEFORE_WINDOW);
    BOOST_CHECK(!component.nodes.front().proof_may_revalidate_on_descendant);
    BOOST_CHECK(!component.has_revalidating_unbound_proof);

    ShadowPowClaimRecoveryRequest request;
    const ShadowPowClaimRecoveryPlan plan =
        wallet->PlanShadowPowClaimRecovery(request);
    BOOST_CHECK(plan.actions.empty());
    BOOST_REQUIRE_EQUAL(plan.refused.size(), 1U);
    BOOST_CHECK_EQUAL(plan.refused.front().reason_code,
                      "claim-not-terminal");
    BOOST_CHECK(!plan.refused.front()
                     .conflicts_with_revalidating_unbound_proof);
}

BOOST_AUTO_TEST_CASE(generation_identity_is_stable_across_tip_and_resolution_state)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    ChainstateManager& chainman = *Assert(m_node.chainman);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CScript wallet_script = anchor_tx->vout.at(0).scriptPubKey;
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    AddRecoveryTestClaim(*wallet, claim, tip->nHeight, tip->GetBlockHash(),
                         tip->nHeight, tip->GetBlockHash());

    const ShadowPowClaimRecoveryInventory initial =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& initial_component = FindRecoveryComponent(initial, anchor);
    BOOST_REQUIRE(!initial_component.generation_fingerprint.IsNull());
    const uint256 generation = initial_component.generation_fingerprint;
    const uint256 initial_snapshot = initial_component.fingerprint;

    CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    SyncWithValidationInterfaceQueue();
    SyncRecoveryTestWalletTip(*wallet, chainman);
    const ShadowPowClaimRecoveryInventory advanced =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& advanced_component = FindRecoveryComponent(advanced, anchor);
    BOOST_CHECK(advanced_component.generation_fingerprint == generation);
    BOOST_CHECK(advanced_component.fingerprint != initial_snapshot);

    CMutableTransaction resolution;
    resolution.vin.emplace_back(anchor);
    resolution.vout.emplace_back(
        anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    const CTransactionRef resolution_ref =
        MakeTransactionRef(std::move(resolution));
    BOOST_REQUIRE(wallet->AddToWallet(
        resolution_ref, TxStateInactive{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_RESOLUTION_SCHEMA_KEY] =
                SHADOW_POW_RESOLUTION_SCHEMA_VERSION;
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY] =
                anchor.hash.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY] =
                ToString(anchor.n);
            wtx.mapValue[SHADOW_POW_RESOLUTION_FINGERPRINT_KEY] =
                generation.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ORIGIN_KEY] =
                SHADOW_POW_RESOLUTION_ORIGIN_MANUAL;
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY] =
                ToString(advanced.active_height);
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_TIME_KEY] = "1";
            return true;
        }));

    const ShadowPowClaimRecoveryInventory pending =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& pending_component = FindRecoveryComponent(pending, anchor);
    BOOST_CHECK(pending_component.generation_fingerprint == generation);
    BOOST_CHECK(pending_component.fingerprint != advanced_component.fingerprint);
    BOOST_CHECK(pending_component.has_managed_resolution);
    BOOST_REQUIRE_EQUAL(pending_component.resolution_txids.size(), 1U);
    const auto resolution_node = std::find_if(
        pending_component.nodes.begin(), pending_component.nodes.end(),
        [&](const auto& node) { return node.txid == resolution_ref->GetHash(); });
    BOOST_REQUIRE(resolution_node != pending_component.nodes.end());
    BOOST_CHECK(resolution_node->resolution_generation_fingerprint ==
                generation);
}

BOOST_AUTO_TEST_CASE(unanchored_same_input_forest_is_one_fail_closed_component)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    const CScript wallet_script =
        m_coinbase_txns.at(0)->vout.at(0).scriptPubKey;
    const COutPoint missing_anchor{uint256{124}, 7};
    const CTransactionRef root_a = MakeRecoveryTestClaim(
        missing_anchor, 4 * COIN, wallet_script);
    const CTransactionRef root_b = MakeRecoveryTestClaim(
        missing_anchor, 3 * COIN, wallet_script);
    const CTransactionRef child_a = MakeRecoveryTestClaim(
        COutPoint{root_a->GetHash(), 0}, 2 * COIN, wallet_script);
    const CTransactionRef child_b = MakeRecoveryTestClaim(
        COutPoint{root_b->GetHash(), 0}, COIN, wallet_script);
    for (const CTransactionRef& claim :
         {root_a, root_b, child_a, child_b}) {
        AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                             tip->GetBlockHash(), tip->nHeight,
                             tip->GetBlockHash());
    }

    CMutableTransaction ordinary;
    ordinary.vin.emplace_back(COutPoint{child_a->GetHash(), 0});
    ordinary.vout.emplace_back(COIN, wallet_script);
    const CTransactionRef ordinary_ref =
        MakeTransactionRef(std::move(ordinary));
    BOOST_REQUIRE(wallet->AddToWallet(ordinary_ref, TxStateInactive{}));

    const ShadowPowClaimRecoveryInventory inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    BOOST_REQUIRE_EQUAL(inventory.components.size(), 1U);
    BOOST_CHECK_EQUAL(inventory.raw_claim_objects, 4U);
    BOOST_CHECK_EQUAL(inventory.unanchored_claim_txids.size(), 4U);
    const auto& component = inventory.components.front();
    BOOST_CHECK(component.anchor == missing_anchor);
    BOOST_CHECK(!component.anchor_authenticated);
    BOOST_CHECK(component.generation_fingerprint.IsNull());
    BOOST_CHECK(component.state ==
                ShadowPowClaimRecoveryState::INDETERMINATE);
    BOOST_CHECK(component.has_indeterminate_node);
    BOOST_CHECK_EQUAL(component.claim_txids.size(), 4U);
    BOOST_CHECK_EQUAL(component.root_claim_txids.size(), 2U);
    BOOST_CHECK_EQUAL(component.descendant_claims, 2U);
    BOOST_CHECK_EQUAL(component.ordinary_or_mixed_txids.size(), 1U);
    BOOST_CHECK(component.ordinary_or_mixed_txids.front() ==
                ordinary_ref->GetHash());
    BOOST_CHECK_EQUAL(component.nodes.size(), 5U);
}

BOOST_AUTO_TEST_CASE(resolution_metadata_is_recognized_only_when_complete)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    std::vector<COutPoint> anchors;
    std::vector<CTransactionRef> claims;
    std::vector<CTransactionRef> resolutions;
    for (size_t index = 0; index < 3; ++index) {
        const CTransactionRef anchor_tx = m_coinbase_txns.at(index);
        const COutPoint anchor{anchor_tx->GetHash(), 0};
        const CScript script = anchor_tx->vout.at(0).scriptPubKey;
        const CTransactionRef claim = MakeRecoveryTestClaim(
            anchor,
            anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
            script);
        AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                             tip->GetBlockHash(), tip->nHeight,
                             tip->GetBlockHash());

        CMutableTransaction resolution;
        resolution.vin.emplace_back(anchor);
        resolution.vout.emplace_back(
            anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
            script);
        anchors.push_back(anchor);
        claims.push_back(claim);
        resolutions.push_back(MakeTransactionRef(std::move(resolution)));
    }

    const ShadowPowClaimRecoveryInventory claims_only =
        wallet->GetShadowPowClaimRecoveryInventory();
    std::vector<uint256> generation_fingerprints;
    for (const COutPoint& anchor : anchors) {
        const auto& component = FindRecoveryComponent(claims_only, anchor);
        BOOST_REQUIRE(!component.generation_fingerprint.IsNull());
        generation_fingerprints.push_back(component.generation_fingerprint);
    }

    BOOST_REQUIRE(wallet->AddToWallet(
        resolutions[0], TxStateInactive{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_RESOLUTION_SCHEMA_KEY] =
                SHADOW_POW_RESOLUTION_SCHEMA_VERSION;
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY] =
                anchors[0].hash.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY] =
                ToString(anchors[0].n);
            wtx.mapValue[SHADOW_POW_RESOLUTION_FINGERPRINT_KEY] =
                generation_fingerprints[0].GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ORIGIN_KEY] =
                SHADOW_POW_RESOLUTION_ORIGIN_MANUAL;
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY] =
                ToString(tip->nHeight);
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_TIME_KEY] = "1";
            return true;
        }));

    BOOST_REQUIRE(wallet->AddToWallet(
        resolutions[1], TxStateInactive{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_LEGACY_CLEANUP_FOR_KEY] =
                claims[1]->GetHash().GetHex();
            return true;
        }));

    // An exact-shape transaction with a different anchor generation's
    // fingerprint and a legacy marker naming a claim from another component
    // must not gain trusted status.
    BOOST_REQUIRE(wallet->AddToWallet(
        resolutions[2], TxStateInactive{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_RESOLUTION_SCHEMA_KEY] =
                SHADOW_POW_RESOLUTION_SCHEMA_VERSION;
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY] =
                anchors[2].hash.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY] =
                ToString(anchors[2].n);
            wtx.mapValue[SHADOW_POW_RESOLUTION_FINGERPRINT_KEY] =
                generation_fingerprints[0].GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ORIGIN_KEY] =
                SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC;
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY] =
                ToString(tip->nHeight);
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_TIME_KEY] = "1";
            wtx.mapValue[SHADOW_POW_LEGACY_CLEANUP_FOR_KEY] =
                claims[0]->GetHash().GetHex();
            return true;
        }));

    const ShadowPowClaimRecoveryInventory inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& managed = FindRecoveryComponent(inventory, anchors[0]);
    BOOST_CHECK(managed.has_managed_resolution);
    BOOST_CHECK(!managed.has_legacy_resolution);
    BOOST_CHECK_EQUAL(managed.resolution_txids.size(), 1U);
    BOOST_CHECK(managed.resolution_txids.front() == resolutions[0]->GetHash());
    const auto managed_node = std::find_if(
        managed.nodes.begin(), managed.nodes.end(), [&](const auto& node) {
            return node.txid == resolutions[0]->GetHash();
        });
    BOOST_REQUIRE(managed_node != managed.nodes.end());
    BOOST_CHECK(managed_node->resolution_generation_fingerprint ==
                managed.generation_fingerprint);

    const auto& legacy = FindRecoveryComponent(inventory, anchors[1]);
    BOOST_CHECK(!legacy.has_managed_resolution);
    BOOST_CHECK(legacy.has_legacy_resolution);
    BOOST_CHECK_EQUAL(legacy.resolution_txids.size(), 1U);
    BOOST_CHECK(legacy.resolution_txids.front() == resolutions[1]->GetHash());

    const auto& malformed = FindRecoveryComponent(inventory, anchors[2]);
    BOOST_CHECK(!malformed.has_managed_resolution);
    BOOST_CHECK(!malformed.has_legacy_resolution);
    BOOST_CHECK(malformed.has_indeterminate_node);
    BOOST_CHECK_EQUAL(malformed.ordinary_or_mixed_txids.size(), 1U);
    BOOST_CHECK(malformed.ordinary_or_mixed_txids.front() ==
                resolutions[2]->GetHash());
}

BOOST_AUTO_TEST_CASE(active_chain_spend_resolution_is_reversible_after_reorg)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    ChainstateManager& chainman = *Assert(m_node.chainman);

    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    const CBlockIndex* genesis = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Genesis());
    BOOST_REQUIRE(genesis);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CScript wallet_script = anchor_tx->vout.at(0).scriptPubKey;
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    AddRecoveryTestClaim(*wallet, claim, tip->nHeight, tip->GetBlockHash(),
                         genesis->nHeight, genesis->GetBlockHash());

    const ShadowPowClaimRecoveryInventory before =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& before_component = FindRecoveryComponent(before, anchor);
    BOOST_CHECK(before_component.anchor_unspent);
    BOOST_CHECK(before_component.state !=
                ShadowPowClaimRecoveryState::RESOLVED_ON_ACTIVE_CHAIN);
    const uint256 before_fingerprint = before_component.fingerprint;

    const CMutableTransaction competing_spend = CreateValidMempoolTransaction(
        anchor_tx, /*input_vout=*/0, /*input_height=*/1, coinbaseKey,
        wallet_script,
        anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        /*submit=*/true);
    const CBlock resolution_block = CreateAndProcessBlock(
        {competing_spend}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    SyncWithValidationInterfaceQueue();
    SyncRecoveryTestWalletTip(*wallet, chainman);

    const ShadowPowClaimRecoveryInventory resolved =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& resolved_component = FindRecoveryComponent(resolved, anchor);
    BOOST_CHECK(!resolved_component.anchor_unspent);
    BOOST_CHECK(resolved_component.state ==
                ShadowPowClaimRecoveryState::RESOLVED_ON_ACTIVE_CHAIN);
    BOOST_CHECK_EQUAL(resolved.resolved_components, 1U);
    BOOST_CHECK(resolved_component.fingerprint != before_fingerprint);

    CBlockIndex* resolution_index = WITH_LOCK(
        ::cs_main,
        return chainman.m_blockman.LookupBlockIndex(
            resolution_block.GetHash()));
    BOOST_REQUIRE(resolution_index);
    BlockValidationState state;
    BOOST_REQUIRE(chainman.ActiveChainstate().InvalidateBlock(
        state, resolution_index));
    SyncWithValidationInterfaceQueue();
    SyncRecoveryTestWalletTip(*wallet, chainman);

    const ShadowPowClaimRecoveryInventory restored =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& restored_component = FindRecoveryComponent(restored, anchor);
    BOOST_CHECK(restored_component.anchor_unspent);
    BOOST_CHECK(restored_component.state !=
                ShadowPowClaimRecoveryState::RESOLVED_ON_ACTIVE_CHAIN);
    BOOST_CHECK_EQUAL(restored.resolved_components, 0U);
    BOOST_CHECK_EQUAL(restored.blocking_components, 1U);

    // The disconnected spend may remain as wallet-known ordinary history and
    // therefore legitimately change the graph fingerprint. Reversibility is
    // the restored active-chain anchor plus fail-closed blocking state; a
    // repeated read on that exact tip must still be byte-stable.
    const ShadowPowClaimRecoveryInventory restored_repeat =
        wallet->GetShadowPowClaimRecoveryInventory();
    BOOST_CHECK(FindRecoveryComponent(restored_repeat, anchor).fingerprint ==
                restored_component.fingerprint);
}

BOOST_AUTO_TEST_CASE(confirmed_claim_is_a_hard_frontier_without_duplicate_descendants)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    ChainstateManager& chainman = *Assert(m_node.chainman);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CScript script = anchor_tx->vout.at(0).scriptPubKey;
    const CTransactionRef winner = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        script);
    const CTransactionRef stale_sibling = MakeRecoveryTestClaim(
        anchor,
        anchor_tx->vout.at(0).nValue - 2 * DEFAULT_TRANSACTION_MAXFEE,
        script);
    const COutPoint frontier{winner->GetHash(), 0};
    const CTransactionRef descendant = MakeRecoveryTestClaim(
        frontier, winner->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        script);
    for (const CTransactionRef& claim :
         {winner, stale_sibling, descendant}) {
        AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                             tip->GetBlockHash(), tip->nHeight,
                             tip->GetBlockHash());
    }

    {
        LOCK2(::cs_main, wallet->cs_wallet);
        CCoinsViewCache& coins = chainman.ActiveChainstate().CoinsTip();
        BOOST_REQUIRE(coins.SpendCoin(anchor));
        coins.AddCoin(
            frontier,
            Coin{winner->vout.at(0), tip->nHeight, /*coinbase=*/false,
                 /*coinstake=*/false, winner->nTime},
            /*possible_overwrite=*/false);
        wallet->mapWallet.at(winner->GetHash()).m_state =
            TxStateConfirmed{tip->GetBlockHash(), tip->nHeight, 1};
        wallet->mapWallet.at(winner->GetHash()).MarkDirty();
    }

    const ShadowPowClaimRecoveryInventory inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& old_generation = FindRecoveryComponent(inventory, anchor);
    const auto& new_frontier = FindRecoveryComponent(inventory, frontier);
    BOOST_CHECK(old_generation.state ==
                ShadowPowClaimRecoveryState::RESOLVED_ON_ACTIVE_CHAIN);
    BOOST_CHECK(std::find(old_generation.claim_txids.begin(),
                          old_generation.claim_txids.end(),
                          descendant->GetHash()) ==
                old_generation.claim_txids.end());
    BOOST_REQUIRE_EQUAL(new_frontier.claim_txids.size(), 1U);
    BOOST_CHECK(new_frontier.claim_txids.front() == descendant->GetHash());

    const size_t descendant_occurrences = std::count_if(
        inventory.components.begin(), inventory.components.end(),
        [&](const ShadowPowClaimRecoveryComponent& component) {
            return std::find(component.claim_txids.begin(),
                             component.claim_txids.end(),
                             descendant->GetHash()) !=
                   component.claim_txids.end();
        });
    BOOST_CHECK_EQUAL(descendant_occurrences, 1U);

    ShadowPowClaimRecoveryRequest request;
    request.selectors = {descendant->GetHash()};
    const ShadowPowClaimRecoveryPlan plan =
        wallet->PlanShadowPowClaimRecovery(request);
    BOOST_REQUIRE_EQUAL(plan.actions.size(), 1U);
    BOOST_CHECK(plan.actions.front().anchor == frontier);
}

BOOST_AUTO_TEST_CASE(automatic_usage_survives_original_claim_confirmation_and_reorg)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    ChainstateManager& chainman = *Assert(m_node.chainman);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CScript script = anchor_tx->vout.at(0).scriptPubKey;
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        script);
    AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash());

    const auto initial = wallet->GetShadowPowClaimRecoveryInventory();
    const uint256 generation =
        FindRecoveryComponent(initial, anchor).generation_fingerprint;
    const CAmount fee = 1000;
    CMutableTransaction resolution;
    resolution.vin.emplace_back(
        anchor, CScript(), std::numeric_limits<uint32_t>::max());
    resolution.vout.emplace_back(
        anchor_tx->vout.at(0).nValue - fee, script);
    const CTransactionRef resolution_ref =
        MakeTransactionRef(std::move(resolution));
    const int64_t created_time = GetTime();
    BOOST_REQUIRE(created_time > 0);
    BOOST_REQUIRE(wallet->AddToWallet(
        resolution_ref, TxStateInactive{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_RESOLUTION_SCHEMA_KEY] =
                SHADOW_POW_RESOLUTION_SCHEMA_VERSION;
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY] =
                anchor.hash.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY] =
                ToString(anchor.n);
            wtx.mapValue[SHADOW_POW_RESOLUTION_FINGERPRINT_KEY] =
                generation.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ORIGIN_KEY] =
                SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC;
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY] =
                ToString(tip->nHeight);
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_TIME_KEY] =
                ToString(created_time);
            wtx.mapValue[SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY] = "1";
            wtx.fFromMe = true;
            return true;
        }));

    Coin original_anchor;
    const COutPoint frontier{claim->GetHash(), 0};
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        CCoinsViewCache& coins = chainman.ActiveChainstate().CoinsTip();
        BOOST_REQUIRE(coins.SpendCoin(anchor, &original_anchor));
        coins.AddCoin(
            frontier,
            Coin{claim->vout.at(0), tip->nHeight, /*coinbase=*/false,
                 /*coinstake=*/false, claim->nTime},
            /*possible_overwrite=*/false);
        wallet->mapWallet.at(claim->GetHash()).m_state =
            TxStateConfirmed{tip->GetBlockHash(), tip->nHeight, 1};
        wallet->mapWallet.at(claim->GetHash()).MarkDirty();
    }

    const auto claim_won_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    BOOST_CHECK(claim_won_inventory.components.empty());
    const ShadowPowClaimRecoveryUsage claim_won =
        wallet->GetShadowPowClaimRecoveryUsage(/*rolling_window_seconds=*/86400);
    BOOST_CHECK_EQUAL(claim_won.pending_automatic, 1U);
    BOOST_CHECK_EQUAL(claim_won.automatic_actions_in_window, 1U);
    BOOST_CHECK_EQUAL(claim_won.automatic_fee_exposure_in_window, fee);

    // Simulate disconnecting the original winner. The durable automatic
    // action remains the same fact; only the component/anchor state changes.
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        CCoinsViewCache& coins = chainman.ActiveChainstate().CoinsTip();
        BOOST_REQUIRE(coins.SpendCoin(frontier));
        coins.AddCoin(anchor, std::move(original_anchor),
                      /*possible_overwrite=*/true);
        wallet->mapWallet.at(claim->GetHash()).m_state = TxStateInactive{};
        wallet->mapWallet.at(claim->GetHash()).MarkDirty();
    }
    const auto restored_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    BOOST_REQUIRE(!restored_inventory.components.empty());
    const ShadowPowClaimRecoveryUsage restored =
        wallet->GetShadowPowClaimRecoveryUsage(/*rolling_window_seconds=*/86400);
    BOOST_CHECK_EQUAL(restored.pending_automatic,
                      claim_won.pending_automatic);
    BOOST_CHECK_EQUAL(restored.automatic_actions_in_window,
                      claim_won.automatic_actions_in_window);
    BOOST_CHECK_EQUAL(restored.automatic_fee_exposure_in_window,
                      claim_won.automatic_fee_exposure_in_window);
}

BOOST_AUTO_TEST_CASE(recycled_output_usage_requires_exact_confirmed_managed_outpoint)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    ChainstateManager& chainman = *Assert(m_node.chainman);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CScript script = anchor_tx->vout.at(0).scriptPubKey;
    const CTransactionRef original_claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        script);
    AddRecoveryTestClaim(*wallet, original_claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash());
    const uint256 generation = FindRecoveryComponent(
        wallet->GetShadowPowClaimRecoveryInventory(), anchor)
                                   .generation_fingerprint;
    const CAmount resolution_fee = 1000;
    const CTransactionRef resolution = AddRecoveryTestManagedResolution(
        *wallet, anchor_tx, anchor, generation, resolution_fee,
        SHADOW_POW_RESOLUTION_ORIGIN_MANUAL, tip->nHeight,
        std::max<int64_t>(1, GetTime()));
    const COutPoint exact_resolution_output{resolution->GetHash(), 0};

    {
        LOCK2(::cs_main, wallet->cs_wallet);
        CCoinsViewCache& coins = chainman.ActiveChainstate().CoinsTip();
        BOOST_REQUIRE(coins.SpendCoin(anchor));
        coins.AddCoin(
            exact_resolution_output,
            Coin{resolution->vout.at(0), tip->nHeight,
                 /*coinbase=*/false, /*coinstake=*/false,
                 resolution->nTime},
            /*possible_overwrite=*/false);
        wallet->mapWallet.at(resolution->GetHash()).m_state =
            TxStateConfirmed{tip->GetBlockHash(), tip->nHeight, 1};
        wallet->mapWallet.at(resolution->GetHash()).MarkDirty();
    }

    const ShadowPowClaimRecoveryUsage no_recycle =
        wallet->GetShadowPowClaimRecoveryUsage(/*rolling_window_seconds=*/86400);
    BOOST_CHECK_EQUAL(no_recycle.confirmed_manual, 1U);
    BOOST_CHECK_EQUAL(no_recycle.recycled_outputs, 0U);

    // A later wallet claim against an unrelated valid wallet input is not a
    // recycle of this managed resolution.
    const CTransactionRef unrelated_anchor_tx = m_coinbase_txns.at(1);
    const COutPoint unrelated_anchor{unrelated_anchor_tx->GetHash(), 0};
    const CTransactionRef unrelated_claim = MakeRecoveryTestClaim(
        unrelated_anchor,
        unrelated_anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        unrelated_anchor_tx->vout.at(0).scriptPubKey);
    AddRecoveryTestClaim(*wallet, unrelated_claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash());
    BOOST_CHECK_EQUAL(
        wallet->GetShadowPowClaimRecoveryUsage(86400).recycled_outputs, 0U);

    // Sharing only the resolution txid is insufficient. Vout 1 does not
    // exist and must never be counted as recycled collateral.
    const CTransactionRef out_of_range_claim = MakeRecoveryTestClaim(
        COutPoint{resolution->GetHash(), 1},
        resolution->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        resolution->vout.at(0).scriptPubKey);
    AddRecoveryTestClaim(*wallet, out_of_range_claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash());
    BOOST_CHECK_EQUAL(
        wallet->GetShadowPowClaimRecoveryUsage(86400).recycled_outputs, 0U);

    const CTransactionRef exact_recycled_claim = MakeRecoveryTestClaim(
        exact_resolution_output,
        resolution->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        resolution->vout.at(0).scriptPubKey);
    AddRecoveryTestClaim(*wallet, exact_recycled_claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash());
    BOOST_CHECK_EQUAL(
        wallet->GetShadowPowClaimRecoveryUsage(86400).recycled_outputs, 1U);
}

BOOST_AUTO_TEST_CASE(automatic_actions_use_chain_anchored_logical_time)
{
    struct MockTimeReset {
        ~MockTimeReset() { SetMockTime(0); }
    } mock_time_reset;
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    BOOST_REQUIRE(tip->pprev);
    const CBlockIndex* stale_observation = tip->pprev;

    const CTransactionRef anchor_tx_a = m_coinbase_txns.at(0);
    const CTransactionRef anchor_tx_b = m_coinbase_txns.at(1);
    const CTransactionRef anchor_tx_c = m_coinbase_txns.at(2);
    const COutPoint anchor_a{anchor_tx_a->GetHash(), 0};
    const COutPoint anchor_b{anchor_tx_b->GetHash(), 0};
    const COutPoint anchor_c{anchor_tx_c->GetHash(), 0};
    const CScript script = anchor_tx_a->vout.at(0).scriptPubKey;
    const CTransactionRef claim_a = MakeRecoveryTestClaim(
        anchor_a,
        anchor_tx_a->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        script);
    const CTransactionRef claim_b = MakeRecoveryTestClaim(
        anchor_b,
        anchor_tx_b->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        script);
    const CTransactionRef claim_c = MakeRecoveryTestClaim(
        anchor_c,
        anchor_tx_c->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        script);
    for (const CTransactionRef& claim : {claim_a, claim_b, claim_c}) {
        AddRecoveryTestClaim(*wallet, claim,
                             stale_observation->nHeight,
                             stale_observation->GetBlockHash(),
                             stale_observation->nHeight,
                             stale_observation->GetBlockHash());
    }

    const auto initial = wallet->GetShadowPowClaimRecoveryInventory();
    const uint256 generation_a =
        FindRecoveryComponent(initial, anchor_a).generation_fingerprint;
    const uint256 generation_c =
        FindRecoveryComponent(initial, anchor_c).generation_fingerprint;
    const int64_t chain_time =
        std::max<int64_t>(1, tip->GetMedianTimePast());
    const int64_t future_action_time = GetTime() + 3600;
    CMutableTransaction old_resolution;
    old_resolution.vin.emplace_back(
        anchor_a, CScript(), std::numeric_limits<uint32_t>::max());
    old_resolution.vout.emplace_back(
        anchor_tx_a->vout.at(0).nValue - 1000, script);
    const CTransactionRef old_resolution_ref =
        MakeTransactionRef(std::move(old_resolution));
    BOOST_REQUIRE(wallet->AddToWallet(
        old_resolution_ref, TxStateInactive{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_RESOLUTION_SCHEMA_KEY] =
                SHADOW_POW_RESOLUTION_SCHEMA_VERSION;
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY] =
                anchor_a.hash.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY] =
                ToString(anchor_a.n);
            wtx.mapValue[SHADOW_POW_RESOLUTION_FINGERPRINT_KEY] =
                generation_a.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ORIGIN_KEY] =
                SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC;
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY] =
                ToString(tip->nHeight);
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_TIME_KEY] =
                ToString(future_action_time);
            wtx.mapValue[SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY] = "1";
            wtx.fFromMe = true;
            return true;
        }));

    // A genuinely recent legacy record must not disappear merely because a
    // different old record is dated in the future.
    CMutableTransaction recent_resolution;
    recent_resolution.nTime = static_cast<uint32_t>(chain_time + 1);
    recent_resolution.vin.emplace_back(
        anchor_c, CScript(), std::numeric_limits<uint32_t>::max());
    recent_resolution.vout.emplace_back(
        anchor_tx_c->vout.at(0).nValue - 1000, script);
    const CTransactionRef recent_resolution_ref =
        MakeTransactionRef(std::move(recent_resolution));
    BOOST_REQUIRE(wallet->AddToWallet(
        recent_resolution_ref, TxStateInactive{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_RESOLUTION_SCHEMA_KEY] =
                SHADOW_POW_RESOLUTION_SCHEMA_VERSION;
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY] =
                anchor_c.hash.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY] =
                ToString(anchor_c.n);
            wtx.mapValue[SHADOW_POW_RESOLUTION_FINGERPRINT_KEY] =
                generation_c.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ORIGIN_KEY] =
                SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC;
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY] =
                ToString(tip->nHeight);
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_TIME_KEY] =
                ToString(chain_time);
            wtx.mapValue[SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY] = "1";
            wtx.fFromMe = true;
            return true;
        }));

    ShadowPowClaimRecoveryRequest wrong_origin_retry;
    wrong_origin_retry.mode =
        ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST;
    wrong_origin_retry.origin = ShadowPowClaimRecoveryOrigin::MANUAL;
    wrong_origin_retry.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::PERSISTED_COMMIT;
    wrong_origin_retry.selectors = {old_resolution_ref->GetHash()};
    const ShadowPowClaimRecoveryResult refused_origin_confusion =
        wallet->ResolveShadowPowClaims(wrong_origin_retry);
    BOOST_CHECK(!refused_origin_confusion.success);

    ShadowPowClaimRecoveryPolicy policy =
        DefaultShadowPowClaimRecoveryPolicy();
    policy.choice_recorded = 1;
    policy.automatic_enabled = 1;
    policy.minimum_stale_blocks = 1;
    policy.max_actions_per_window = 10;
    bilingual_str policy_error;
    BOOST_REQUIRE(wallet->SetShadowPowClaimRecoveryPolicy(policy,
                                                           policy_error));
    wallet->SetBroadcastTransactions(/*broadcast=*/true);
    wallet->m_pow_mining_enabled.store(true);
    // A large forward host-clock jump must not expire the prior action or
    // become the timestamp of a newly authorized automatic action.
    SetMockTime(future_action_time + 30 * 24 * 60 * 60);

    ShadowPowClaimRecoveryRequest request;
    request.mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
    request.origin = ShadowPowClaimRecoveryOrigin::AUTOMATIC;
    request.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::AUTOMATIC_POLICY;
    request.selectors = {claim_b->GetHash()};
    const ShadowPowClaimRecoveryResult result =
        wallet->ResolveShadowPowClaims(request);
    BOOST_REQUIRE_MESSAGE(result.success, result.error);
    BOOST_REQUIRE_EQUAL(result.signed_and_persisted, 1U);
    BOOST_REQUIRE_EQUAL(result.plan.actions.size(), 1U);
    BOOST_CHECK(result.plan.actions.front()
                    .conflicts_with_revalidating_unbound_proof);
    BOOST_CHECK_EQUAL(result.plan.actions.front().reason_code,
                      "unbound-proof-may-revalidate");

    int64_t persisted_time{0};
    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& persisted = wallet->mapWallet.at(
            result.plan.actions.front().transaction->GetHash());
        const auto created = persisted.mapValue.find(
            SHADOW_POW_RESOLUTION_CREATED_TIME_KEY);
        BOOST_REQUIRE(created != persisted.mapValue.end());
        BOOST_REQUIRE(ParseInt64(created->second, &persisted_time));
    }
    BOOST_CHECK_EQUAL(persisted_time, chain_time);
    const ShadowPowClaimRecoveryUsage usage =
        wallet->GetShadowPowClaimRecoveryUsage(/*rolling_window_seconds=*/86400);
    BOOST_CHECK_EQUAL(usage.automatic_actions_in_window, 3U);
}

BOOST_AUTO_TEST_CASE(legacy_backward_clock_action_uses_transaction_chain_time_floor)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CScript script = anchor_tx->vout.at(0).scriptPubKey;
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor,
        anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        script);
    AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash());
    const auto inventory = wallet->GetShadowPowClaimRecoveryInventory();
    const uint256 generation =
        FindRecoveryComponent(inventory, anchor).generation_fingerprint;

    const CAmount fee{1000};
    const int64_t chain_time =
        std::max<int64_t>(1, tip->GetMedianTimePast());
    CMutableTransaction resolution;
    resolution.nTime = static_cast<uint32_t>(chain_time + 1);
    resolution.vin.emplace_back(
        anchor, CScript(), std::numeric_limits<uint32_t>::max());
    resolution.vout.emplace_back(
        anchor_tx->vout.at(0).nValue - fee, script);
    const CTransactionRef resolution_ref =
        MakeTransactionRef(std::move(resolution));
    BOOST_REQUIRE(wallet->AddToWallet(
        resolution_ref, TxStateInactive{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_RESOLUTION_SCHEMA_KEY] =
                SHADOW_POW_RESOLUTION_SCHEMA_VERSION;
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY] =
                anchor.hash.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY] =
                ToString(anchor.n);
            wtx.mapValue[SHADOW_POW_RESOLUTION_FINGERPRINT_KEY] =
                generation.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ORIGIN_KEY] =
                SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC;
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY] =
                ToString(tip->nHeight);
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_TIME_KEY] =
                ToString(std::max<int64_t>(1, chain_time - 2 * 86400));
            wtx.mapValue[SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY] = "1";
            wtx.fFromMe = true;
            return true;
        }));

    const ShadowPowClaimRecoveryUsage usage =
        wallet->GetShadowPowClaimRecoveryUsage(/*rolling_window_seconds=*/86400);
    BOOST_CHECK_EQUAL(usage.pending_automatic, 1U);
    BOOST_CHECK_EQUAL(usage.automatic_actions_in_window, 1U);
    BOOST_CHECK_EQUAL(usage.automatic_fee_exposure_in_window, fee);
}

BOOST_AUTO_TEST_CASE(durable_automatic_usage_exhausts_action_and_fee_budgets)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    BOOST_REQUIRE(tip->pprev);
    const CBlockIndex* stale_observation = tip->pprev;

    const CTransactionRef anchor_tx_a = m_coinbase_txns.at(0);
    const CTransactionRef anchor_tx_b = m_coinbase_txns.at(1);
    const CTransactionRef anchor_tx_c = m_coinbase_txns.at(2);
    const COutPoint anchor_a{anchor_tx_a->GetHash(), 0};
    const COutPoint anchor_b{anchor_tx_b->GetHash(), 0};
    const COutPoint anchor_c{anchor_tx_c->GetHash(), 0};
    const CTransactionRef claim_a = MakeRecoveryTestClaim(
        anchor_a,
        anchor_tx_a->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        anchor_tx_a->vout.at(0).scriptPubKey);
    const CTransactionRef claim_b = MakeRecoveryTestClaim(
        anchor_b,
        anchor_tx_b->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        anchor_tx_b->vout.at(0).scriptPubKey);
    const CTransactionRef claim_c = MakeRecoveryTestClaim(
        anchor_c,
        anchor_tx_c->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        anchor_tx_c->vout.at(0).scriptPubKey);
    for (const CTransactionRef& claim : {claim_a, claim_b, claim_c}) {
        AddRecoveryTestClaim(*wallet, claim,
                             stale_observation->nHeight,
                             stale_observation->GetBlockHash(),
                             stale_observation->nHeight,
                             stale_observation->GetBlockHash());
    }

    const ShadowPowClaimRecoveryInventory initial =
        wallet->GetShadowPowClaimRecoveryInventory();
    const uint256 generation_a =
        FindRecoveryComponent(initial, anchor_a).generation_fingerprint;
    const CAmount prior_fee = 10 * CENT;
    AddRecoveryTestManagedResolution(
        *wallet, anchor_tx_a, anchor_a, generation_a, prior_fee,
        SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC, tip->nHeight,
        std::max<int64_t>(1, GetTime()));

    wallet->SetBroadcastTransactions(/*broadcast=*/true);
    wallet->m_pow_mining_enabled.store(true);
    ShadowPowClaimRecoveryPolicy policy =
        DefaultShadowPowClaimRecoveryPolicy();
    policy.choice_recorded = 1;
    policy.automatic_enabled = 1;
    policy.minimum_stale_blocks = 1;
    policy.max_actions_per_window = 1;
    bilingual_str policy_error;
    BOOST_REQUIRE(wallet->SetShadowPowClaimRecoveryPolicy(policy,
                                                           policy_error));

    const ShadowPowClaimRecoveryUsage persisted_usage =
        wallet->GetShadowPowClaimRecoveryUsage(
            policy.rolling_fee_window_seconds);
    BOOST_CHECK_EQUAL(persisted_usage.pending_automatic, 1U);
    BOOST_CHECK_EQUAL(persisted_usage.automatic_actions_in_window, 1U);
    BOOST_CHECK_EQUAL(persisted_usage.automatic_fee_exposure_in_window,
                      prior_fee);

    ShadowPowClaimRecoveryRequest automatic_request;
    automatic_request.origin = ShadowPowClaimRecoveryOrigin::AUTOMATIC;
    automatic_request.selectors = {claim_b->GetHash()};
    const ShadowPowClaimRecoveryResult action_limited =
        wallet->ResolveShadowPowClaims(automatic_request);
    BOOST_REQUIRE_MESSAGE(action_limited.success, action_limited.error);
    BOOST_CHECK(action_limited.plan.actions.empty());
    BOOST_REQUIRE_EQUAL(action_limited.plan.refused.size(), 1U);
    BOOST_CHECK_EQUAL(action_limited.plan.refused.front().reason_code,
                      "action-rate-exhausted");

    policy.max_actions_per_window = 10;
    policy.rolling_fee_budget = prior_fee;
    BOOST_REQUIRE(wallet->SetShadowPowClaimRecoveryPolicy(policy,
                                                           policy_error));
    const ShadowPowClaimRecoveryUsage usage_after_policy_change =
        wallet->GetShadowPowClaimRecoveryUsage(
            policy.rolling_fee_window_seconds);
    BOOST_CHECK_EQUAL(usage_after_policy_change.automatic_actions_in_window,
                      persisted_usage.automatic_actions_in_window);
    BOOST_CHECK_EQUAL(
        usage_after_policy_change.automatic_fee_exposure_in_window,
        persisted_usage.automatic_fee_exposure_in_window);

    automatic_request.selectors = {claim_c->GetHash()};
    const ShadowPowClaimRecoveryResult fee_limited =
        wallet->ResolveShadowPowClaims(automatic_request);
    BOOST_REQUIRE_MESSAGE(fee_limited.success, fee_limited.error);
    BOOST_CHECK(fee_limited.plan.actions.empty());
    BOOST_REQUIRE_EQUAL(fee_limited.plan.refused.size(), 1U);
    BOOST_CHECK_EQUAL(fee_limited.plan.refused.front().reason_code,
                      "rolling-fee-budget-exhausted");
}

BOOST_AUTO_TEST_CASE(shared_preview_is_deterministic_side_effect_free_and_matches_legacy_adapter)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        anchor_tx->vout.at(0).scriptPubKey);
    AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash());

    const size_t wallet_records_before = WITH_LOCK(
        wallet->cs_wallet, return wallet->mapWallet.size());
    ShadowPowClaimRecoveryRequest request;
    request.selectors = {claim->GetHash()};
    const ShadowPowClaimRecoveryPlan first =
        wallet->PlanShadowPowClaimRecovery(request);
    const ShadowPowClaimRecoveryPlan repeat =
        wallet->PlanShadowPowClaimRecovery(request);
    if (!first.refused.empty()) {
        BOOST_TEST_MESSAGE("preview refusal: " <<
                           first.refused.front().reason_code << " " <<
                           first.refused.front().detail);
        const auto debug_inventory =
            wallet->GetShadowPowClaimRecoveryInventory();
        const auto& debug_component =
            FindRecoveryComponent(debug_inventory, anchor);
        for (const auto& node : debug_component.nodes) {
            BOOST_TEST_MESSAGE("node wallet=" << node.wallet_authored <<
                               " shape=" << node.expected_shape <<
                               " disposition=" <<
                               static_cast<int>(node.disposition));
        }
    }
    BOOST_REQUIRE(first.complete);
    BOOST_REQUIRE_EQUAL(first.actions.size(), 1U);
    BOOST_CHECK(first.refused.empty());
    BOOST_CHECK(first.plan_id == repeat.plan_id);
    BOOST_CHECK(first.actions.front().anchor == anchor);
    BOOST_CHECK(first.actions.front().transaction->vin.size() == 1U);
    BOOST_CHECK(first.actions.front().transaction->vin.front().prevout ==
                anchor);
    BOOST_CHECK_EQUAL(first.actions.front().transaction->vin.front().nSequence,
                      std::numeric_limits<uint32_t>::max());
    BOOST_CHECK(first.actions.front().transaction->vout.size() == 1U);
    BOOST_CHECK(first.actions.front().transaction->vout.front().scriptPubKey ==
                anchor_tx->vout.at(0).scriptPubKey);
    BOOST_CHECK_GT(first.actions.front().vsize, 0);
    BOOST_CHECK_GE(first.actions.front().vsize,
                   GetVirtualTransactionSize(
                       *first.actions.front().transaction));
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet,
                                return wallet->mapWallet.size()),
                      wallet_records_before);

    ShadowPowClaimRecoveryRequest explicit_rate = request;
    explicit_rate.fee_rate = CFeeRate{2000};
    const ShadowPowClaimRecoveryPlan rate_plan =
        wallet->PlanShadowPowClaimRecovery(explicit_rate);
    BOOST_CHECK(rate_plan.plan_id != first.plan_id);

    const ShadowPowClaimRecoveryInventory full =
        wallet->GetShadowPowClaimRecoveryInventory();
    const ShadowPowClaimInventory compatibility =
        wallet->GetShadowPowClaimInventory();
    size_t expected_raw{0};
    size_t expected_actionable{0};
    size_t expected_resolved{0};
    size_t expected_indeterminate{0};
    for (const ShadowPowClaimRecoveryComponent& component : full.components) {
        const size_t relevant = std::count_if(
            component.nodes.begin(), component.nodes.end(),
            [](const ShadowPowClaimRecoveryNode& node) {
                return node.kind == ShadowPowClaimRecoveryNodeKind::CLAIM &&
                       !node.active_chain_confirmed && !node.in_mempool &&
                       node.wallet_authored;
            });
        expected_raw += relevant;
        if (component.state ==
            ShadowPowClaimRecoveryState::RESOLVED_ON_ACTIVE_CHAIN) {
            expected_resolved += relevant;
        } else if (component.state ==
                   ShadowPowClaimRecoveryState::INDETERMINATE) {
            expected_indeterminate += relevant;
        } else {
            expected_actionable += relevant;
        }
    }
    BOOST_CHECK_EQUAL(compatibility.raw_quarantined_claims, expected_raw);
    BOOST_CHECK_EQUAL(compatibility.actionable_claims, expected_actionable);
    BOOST_CHECK_EQUAL(compatibility.resolved_on_active_chain_claims,
                      expected_resolved);
    BOOST_CHECK_EQUAL(compatibility.indeterminate_claims,
                      expected_indeterminate);
    BOOST_CHECK_EQUAL(wallet->CountQuarantinedShadowPowClaims(),
                      compatibility.BlockingClaims());
}

BOOST_AUTO_TEST_CASE(sign_only_persists_exact_uncommitted_bytes_and_reuses_them)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        anchor_tx->vout.at(0).scriptPubKey);
    AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash());
    const size_t wallet_records_before = WITH_LOCK(
        wallet->cs_wallet, return wallet->mapWallet.size());

    ShadowPowClaimRecoveryRequest preview_request;
    preview_request.selectors = {claim->GetHash()};
    const ShadowPowClaimRecoveryPlan preview =
        wallet->PlanShadowPowClaimRecovery(preview_request);
    if (!preview.refused.empty()) {
        BOOST_TEST_MESSAGE("sign preview refusal: " <<
                           preview.refused.front().reason_code << " " <<
                           preview.refused.front().detail);
    }
    BOOST_REQUIRE_EQUAL(preview.actions.size(), 1U);

    ShadowPowClaimRecoveryRequest missing_consent = preview_request;
    missing_consent.mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
    missing_consent.expected_plan_id = preview.plan_id;
    const ShadowPowClaimRecoveryResult refused_consent =
        wallet->ResolveShadowPowClaims(missing_consent);
    BOOST_CHECK(!refused_consent.success);
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet,
                                return wallet->mapWallet.size()),
                      wallet_records_before);

    missing_consent.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
    missing_consent.acknowledge_fee_and_conflict_risk = true;
    missing_consent.expected_plan_id.reset();
    const ShadowPowClaimRecoveryResult refused_unpinned =
        wallet->ResolveShadowPowClaims(missing_consent);
    BOOST_CHECK(!refused_unpinned.success);
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet,
                                return wallet->mapWallet.size()),
                      wallet_records_before);

    ShadowPowClaimRecoveryRequest sign_request = preview_request;
    sign_request.mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
    sign_request.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
    sign_request.acknowledge_fee_and_conflict_risk = true;
    sign_request.expected_plan_id = preview.plan_id;
    const ShadowPowClaimRecoveryResult signed_result =
        wallet->ResolveShadowPowClaims(sign_request);
    BOOST_REQUIRE_MESSAGE(signed_result.success, signed_result.error);
    BOOST_CHECK_EQUAL(signed_result.signed_and_persisted, 1U);
    BOOST_REQUIRE_EQUAL(signed_result.plan.actions.size(), 1U);
    const CTransactionRef exact = signed_result.plan.actions.front().transaction;
    BOOST_REQUIRE(exact);
    {
        LOCK(wallet->cs_wallet);
        const auto persisted = wallet->mapWallet.find(exact->GetHash());
        BOOST_REQUIRE(persisted != wallet->mapWallet.end());
        BOOST_CHECK(persisted->second.tx->GetWitnessHash() ==
                    exact->GetWitnessHash());
        BOOST_CHECK_EQUAL(
            persisted->second.mapValue.at(
                SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY),
            "0");
        BOOST_CHECK_EQUAL(
            persisted->second.mapValue.at(
                SHADOW_POW_RESOLUTION_FINGERPRINT_KEY),
            preview.actions.front().generation_fingerprint.GetHex());
    }

    ShadowPowClaimRecoveryRequest repeat_request = preview_request;
    repeat_request.mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
    repeat_request.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
    repeat_request.acknowledge_fee_and_conflict_risk = true;
    repeat_request.expected_plan_id =
        wallet->PlanShadowPowClaimRecovery(preview_request).plan_id;
    const ShadowPowClaimRecoveryResult repeat =
        wallet->ResolveShadowPowClaims(repeat_request);
    BOOST_REQUIRE_MESSAGE(repeat.success, repeat.error);
    BOOST_CHECK_EQUAL(repeat.signed_and_persisted, 0U);
    BOOST_REQUIRE_EQUAL(repeat.plan.actions.size(), 1U);
    BOOST_CHECK(repeat.plan.actions.front().status ==
                ShadowPowClaimRecoveryActionStatus::REUSE_MANAGED);
    BOOST_CHECK(repeat.plan.actions.front().transaction->GetWitnessHash() ==
                exact->GetWitnessHash());
    BOOST_CHECK(!repeat.plan.actions.front().in_mempool);

    // An inbound/source-agnostic mempool callback cannot promote a draft.
    wallet->transactionAddedToMempool(exact);
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK_EQUAL(
            wallet->mapWallet.at(exact->GetHash()).mapValue.at(
                SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY),
            "0");
    }
    wallet->transactionRemovedFromMempool(
        exact, MemPoolRemovalReason::EXPIRY);

    // A successful local sendrawtransaction RPC is an authenticated operator
    // action. Its dedicated callback grants durable retry authority for only
    // these exact bytes.
    wallet->transactionSubmittedByRpc(exact);
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK_EQUAL(
            wallet->mapWallet.at(exact->GetHash()).mapValue.at(
                SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY),
            "1");
    }
    wallet->SetBroadcastTransactions(/*broadcast=*/true);

    ShadowPowClaimRecoveryBroadcastGuard stale_guard;
    stale_guard.expected_wallet_generation =
        wallet->GetDatabase().nUpdateCounter.load() + 1;
    stale_guard.expected_wallet_tip = tip->GetBlockHash();
    std::string guarded_error;
    BOOST_CHECK(!wallet->SubmitTxMemoryPoolAndRelay(
        exact->GetHash(), guarded_error, /*relay=*/true, &stale_guard));
    BOOST_CHECK_EQUAL(guarded_error,
                      "recovery-wallet-generation-changed");

    {
        LOCK(wallet->cs_wallet);
        wallet->m_wallet_unlock_staking_only = true;
    }
    ShadowPowClaimRecoveryRequest durable_retry;
    durable_retry.mode =
        ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST;
    durable_retry.origin = ShadowPowClaimRecoveryOrigin::MANUAL;
    durable_retry.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::PERSISTED_COMMIT;
    durable_retry.selectors = {exact->GetHash()};
    const ShadowPowClaimRecoveryResult retried =
        wallet->ResolveShadowPowClaims(durable_retry);
    {
        LOCK(wallet->cs_wallet);
        wallet->m_wallet_unlock_staking_only = false;
    }
    BOOST_REQUIRE_MESSAGE(retried.success, retried.error);
    BOOST_CHECK_EQUAL(retried.signed_and_persisted, 0U);
    BOOST_CHECK_EQUAL(retried.broadcast + retried.already_in_mempool, 1U);
}

BOOST_AUTO_TEST_CASE(manual_scheduler_retries_exact_authorized_fee_above_preview_default)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CScript script = anchor_tx->vout.at(0).scriptPubKey;
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        script);
    AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash());
    const uint256 generation = FindRecoveryComponent(
        wallet->GetShadowPowClaimRecoveryInventory(), anchor)
                                   .generation_fingerprint;

    const CAmount reviewed_fee = 2 * CENT;
    BOOST_REQUIRE(reviewed_fee > CENT);
    BOOST_REQUIRE(reviewed_fee < wallet->m_default_max_tx_fee);
    CMutableTransaction resolution;
    resolution.nVersion = CTransaction::CURRENT_VERSION;
    resolution.nTime = GetAdjustedTimeSeconds();
    resolution.vin.emplace_back(
        anchor, CScript(), std::numeric_limits<uint32_t>::max());
    resolution.vout.emplace_back(
        anchor_tx->vout.at(0).nValue - reviewed_fee, script);
    const unsigned int script_verify_flags =
        wallet->GetActiveScriptVerifyFlags();
    {
        LOCK(wallet->cs_wallet);
        std::map<int, bilingual_str> input_errors;
        BOOST_REQUIRE(wallet->SignTransactionWithScriptVerifyFlags(
            resolution, input_errors, script_verify_flags));
    }
    const CTransactionRef exact =
        MakeTransactionRef(std::move(resolution));
    BOOST_REQUIRE(wallet->AddToWallet(
        exact, TxStateInactive{},
        [&](CWalletTx& wtx, bool) {
            wtx.mapValue[SHADOW_POW_RESOLUTION_SCHEMA_KEY] =
                SHADOW_POW_RESOLUTION_SCHEMA_VERSION;
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY] =
                anchor.hash.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY] =
                ToString(anchor.n);
            wtx.mapValue[SHADOW_POW_RESOLUTION_FINGERPRINT_KEY] =
                generation.GetHex();
            wtx.mapValue[SHADOW_POW_RESOLUTION_ORIGIN_KEY] =
                SHADOW_POW_RESOLUTION_ORIGIN_MANUAL;
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY] =
                ToString(tip->nHeight);
            wtx.mapValue[SHADOW_POW_RESOLUTION_CREATED_TIME_KEY] =
                ToString(std::max<int64_t>(1, GetTime()));
            wtx.mapValue[SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY] = "1";
            wtx.fFromMe = true;
            return true;
        }));

    ShadowPowClaimRecoveryRequest preview_defaults;
    preview_defaults.selectors = {exact->GetHash()};
    const ShadowPowClaimRecoveryPlan artificially_capped =
        wallet->PlanShadowPowClaimRecovery(preview_defaults);
    BOOST_CHECK(artificially_capped.actions.empty());
    BOOST_REQUIRE_EQUAL(artificially_capped.refused.size(), 1U);
    BOOST_CHECK_EQUAL(artificially_capped.refused.front().reason_code,
                      "fee-limit-exceeded");

    wallet->SetBroadcastTransactions(/*broadcast=*/true);
    wallet->MaybeAutoResolveShadowPowClaims();
    SyncWithValidationInterfaceQueue();
    BOOST_CHECK(m_node.chain->isInMempool(exact->GetHash()));
}

BOOST_AUTO_TEST_CASE(stale_plan_and_unsafe_graph_fail_before_signing)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return Assert(m_node.chainman)->ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        anchor_tx->vout.at(0).scriptPubKey);
    AddRecoveryTestClaim(*wallet, claim, tip->nHeight,
                         tip->GetBlockHash(), tip->nHeight,
                         tip->GetBlockHash());
    // Canonical QQP2 bytes are unbound and may revalidate on a descendant.
    // Zero-payment retirement must never release their input.
    BOOST_CHECK_EQUAL(wallet->RetireExpiredShadowPowClaims(), 0U);
    BOOST_CHECK(!WITH_LOCK(
        wallet->cs_wallet,
        return wallet->mapWallet.at(claim->GetHash()).isAbandoned()));

    ShadowPowClaimRecoveryRequest request;
    request.selectors = {claim->GetHash()};
    const ShadowPowClaimRecoveryPlan preview =
        wallet->PlanShadowPowClaimRecovery(request);
    if (!preview.refused.empty()) {
        BOOST_TEST_MESSAGE("stale preview refusal: " <<
                           preview.refused.front().reason_code << " " <<
                           preview.refused.front().detail);
    }
    BOOST_REQUIRE_EQUAL(preview.actions.size(), 1U);
    BOOST_REQUIRE(wallet->AddToWallet(
        claim, TxStateInactive{}, [](CWalletTx& wtx, bool) {
            wtx.mapValue["test_recovery_generation_change"] = "1";
            return true;
        }));
    // Mock databases do not uniformly advance their backend update counter
    // for an overwrite. Model the externally observable wallet-generation
    // advance that production BDB/SQLite backends perform.
    wallet->GetDatabase().nUpdateCounter.fetch_add(1);
    request.mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
    request.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
    request.acknowledge_fee_and_conflict_risk = true;
    request.expected_plan_id = preview.plan_id;
    const ShadowPowClaimRecoveryResult stale =
        wallet->ResolveShadowPowClaims(request);
    BOOST_CHECK(!stale.success);
    BOOST_CHECK(stale.stale_plan);

    CMutableTransaction ordinary;
    ordinary.vin.emplace_back(COutPoint{claim->GetHash(), 0});
    ordinary.vout.emplace_back(
        claim->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        anchor_tx->vout.at(0).scriptPubKey);
    BOOST_REQUIRE(wallet->AddToWallet(
        MakeTransactionRef(std::move(ordinary)), TxStateInactive{}));
    ShadowPowClaimRecoveryRequest unsafe_request;
    unsafe_request.selectors = {claim->GetHash()};
    const ShadowPowClaimRecoveryPlan unsafe =
        wallet->PlanShadowPowClaimRecovery(unsafe_request);
    BOOST_CHECK(unsafe.actions.empty());
    BOOST_REQUIRE_EQUAL(unsafe.refused.size(), 1U);
    BOOST_CHECK_EQUAL(unsafe.refused.front().reason_code,
                      "ordinary-conflict");
}

BOOST_FIXTURE_TEST_CASE(
    origin_expiry_retires_without_transaction_and_reopens_on_reorg,
    RecoveryQQP3TestingSetup)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    auto notifications_handler = m_node.chain->handleNotifications(
        {wallet.get(), [](CWallet*) {}});
    ChainstateManager& chainman = *Assert(m_node.chainman);
    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CScript wallet_script = anchor_tx->vout.at(0).scriptPubKey;
    const CScript quantum_payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x51)});

    std::vector<unsigned char> proof;
    const CBlockIndex* origin_parent{nullptr};
    {
        LOCK(::cs_main);
        origin_parent = chainman.ActiveChain().Tip();
        BOOST_REQUIRE(origin_parent);
        BOOST_REQUIRE(MineShadowProofData(
            wallet_script, quantum_payout, origin_parent,
            chainman.ActiveChainstate().CoinsTip(), 2000000, proof));
    }
    const std::vector<unsigned char> qqp3_magic{'Q', 'Q', 'P', '3'};
    BOOST_REQUIRE(std::search(proof.begin(), proof.end(),
                              qqp3_magic.begin(), qqp3_magic.end()) !=
                  proof.end());

    CMutableTransaction claim_mutable;
    claim_mutable.vin.emplace_back(anchor);
    claim_mutable.vout.emplace_back(
        anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        wallet_script);
    claim_mutable.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    const CTransactionRef claim =
        MakeTransactionRef(std::move(claim_mutable));
    AddRecoveryTestClaim(*wallet, claim, origin_parent->nHeight,
                         origin_parent->GetBlockHash(),
                         origin_parent->nHeight,
                         origin_parent->GetBlockHash());

    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet,
                          return wallet->IsSpent(anchor)));
    BOOST_CHECK_EQUAL(wallet->RetireExpiredShadowPowClaims(), 0U);

    CBlock expiry_block;
    for (unsigned int age = 1;
         age <= SHADOW_POW_LATE_ORIGIN_WINDOW + 1; ++age) {
        expiry_block = CreateAndProcessBlock(
            {}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
        SyncWithValidationInterfaceQueue();
    }
    SyncRecoveryTestWalletTip(*wallet, chainman);

    ShadowPowClaimRecoveryRequest pending_request;
    pending_request.selectors = {claim->GetHash()};
    const ShadowPowClaimRecoveryPlan pending_preview =
        wallet->PlanShadowPowClaimRecovery(pending_request);
    BOOST_CHECK(pending_preview.actions.empty());
    BOOST_REQUIRE_EQUAL(pending_preview.refused.size(), 1U);
    BOOST_CHECK_EQUAL(pending_preview.refused.front().reason_code,
                      "zero-payment-retirement-pending");
    BOOST_CHECK_EQUAL(pending_preview.total_fee, 0);

    const size_t transaction_count_before = WITH_LOCK(
        wallet->cs_wallet, return wallet->mapWallet.size());
    BOOST_CHECK_EQUAL(wallet->RetireExpiredShadowPowClaims(), 1U);
    BOOST_CHECK_EQUAL(WITH_LOCK(
                          wallet->cs_wallet, return wallet->mapWallet.size()),
                      transaction_count_before);
    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& retired = wallet->mapWallet.at(claim->GetHash());
        BOOST_CHECK(retired.isAbandoned());
        BOOST_CHECK_EQUAL(
            retired.mapValue.at(SHADOW_POW_CLAIM_EXPIRED_RETIRED_KEY), "1");
        BOOST_CHECK_EQUAL(
            retired.mapValue.at(SHADOW_POW_CLAIM_EXPIRED_RETIRED_TIP_KEY),
            expiry_block.GetHash().GetHex());
        BOOST_CHECK(!wallet->IsSpent(anchor));
    }
    BOOST_CHECK_EQUAL(wallet->CountQuarantinedShadowPowClaims(), 0U);

    const ShadowPowClaimRecoveryInventory retired_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& retired_component =
        FindRecoveryComponent(retired_inventory, anchor);
    BOOST_CHECK(retired_component.state ==
                ShadowPowClaimRecoveryState::RETIRED_ON_ACTIVE_BRANCH);
    BOOST_CHECK(retired_component.all_claims_expired_locally_retired);
    BOOST_CHECK_EQUAL(retired_inventory.retired_claim_objects, 1U);
    BOOST_CHECK_EQUAL(retired_inventory.retired_components, 1U);
    BOOST_CHECK_EQUAL(retired_inventory.blocking_components, 0U);

    ShadowPowClaimRecoveryRequest preview_request;
    preview_request.selectors = {claim->GetHash()};
    const ShadowPowClaimRecoveryPlan retired_preview =
        wallet->PlanShadowPowClaimRecovery(preview_request);
    BOOST_CHECK(retired_preview.actions.empty());
    BOOST_REQUIRE_EQUAL(retired_preview.refused.size(), 1U);
    BOOST_CHECK_EQUAL(retired_preview.refused.front().reason_code,
                      "claim-expired-locally-retired");
    BOOST_CHECK_EQUAL(retired_preview.total_fee, 0);

    CBlockIndex* expiry_index = WITH_LOCK(
        ::cs_main,
        return chainman.m_blockman.LookupBlockIndex(expiry_block.GetHash()));
    BOOST_REQUIRE(expiry_index);
    BlockValidationState state;
    BOOST_REQUIRE(chainman.ActiveChainstate().InvalidateBlock(
        state, expiry_index));
    SyncWithValidationInterfaceQueue();
    SyncRecoveryTestWalletTip(*wallet, chainman);

    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& reopened = wallet->mapWallet.at(claim->GetHash());
        BOOST_CHECK(!reopened.isAbandoned());
        BOOST_CHECK(reopened.mapValue.count(
                        SHADOW_POW_CLAIM_EXPIRED_RETIRED_KEY) == 0);
        BOOST_CHECK(wallet->IsSpent(anchor));
    }
    BOOST_CHECK(wallet->CountQuarantinedShadowPowClaims() > 0);
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
