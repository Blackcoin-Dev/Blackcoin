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
#include <txmempool.h>
#include <util/check.h>
#include <util/string.h>
#include <util/time.h>
#include <validation.h>
#include <validationinterface.h>
#include <wallet/coincontrol.h>
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

class RecoveryQQP2TestingSetup : public TestChain100Setup
{
public:
    RecoveryQQP2TestingSetup()
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

class RecoveryQQP4TestingSetup : public TestChain100Setup
{
public:
    RecoveryQQP4TestingSetup()
        : TestChain100Setup{ChainType::REGTEST, {
                                                    "-regtest",
                                                    "-shadowwhitelistheight=99",
                                                    "-shadowgoldrushstartheight=100",
                                                    "-shadowgoldrushblocks=1000",
                                                    "-shadowcompetingclaimsheight=101",
                                                    "-shadowqqp4height=101",
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

CTransactionRef MakeExactRecoveryTestQQP2Claim(
    const COutPoint& input, CAmount anchor_amount, CAmount fee,
    const CScript& target, const CScript& quantum_payout, uint64_t nonce)
{
    BOOST_REQUIRE(fee > 0);
    BOOST_REQUIRE(fee <= CENT);
    BOOST_REQUIRE(anchor_amount > fee);
    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0});
    for (size_t byte = 0; byte < sizeof(nonce); ++byte) {
        proof.push_back(static_cast<unsigned char>(nonce & 0xff));
        nonce >>= 8;
    }
    proof.push_back(static_cast<unsigned char>(target.size() & 0xff));
    proof.push_back(static_cast<unsigned char>((target.size() >> 8) & 0xff));
    proof.insert(proof.end(), target.begin(), target.end());
    proof.push_back(
        static_cast<unsigned char>(quantum_payout.size() & 0xff));
    proof.push_back(static_cast<unsigned char>(
        (quantum_payout.size() >> 8) & 0xff));
    proof.insert(proof.end(), quantum_payout.begin(), quantum_payout.end());

    static constexpr uint32_t SEQUENCE_REPLACEABLE = 0xfffffffd;
    CMutableTransaction claim;
    claim.nVersion = CTransaction::CURRENT_VERSION;
    claim.vin.emplace_back(input, CScript(), SEQUENCE_REPLACEABLE);
    claim.vout.emplace_back(anchor_amount - fee, target);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    CTransactionRef result = MakeTransactionRef(std::move(claim));
    BOOST_REQUIRE(TransactionHasShadowProof(*result));
    return result;
}

CTransactionRef MakeExactRecoveryTestQQP3Claim(
    const COutPoint& input, CAmount anchor_amount, CAmount fee,
    uint32_t origin_height, const uint256& origin_parent,
    const CScript& target, const CScript& quantum_payout, uint64_t nonce)
{
    BOOST_REQUIRE(fee > 0);
    BOOST_REQUIRE(fee <= CENT);
    BOOST_REQUIRE(anchor_amount > fee);
    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '3', 0});
    for (size_t byte = 0; byte < sizeof(nonce); ++byte) {
        proof.push_back(static_cast<unsigned char>(nonce & 0xff));
        nonce >>= 8;
    }
    for (size_t byte = 0; byte < sizeof(origin_height); ++byte) {
        proof.push_back(static_cast<unsigned char>(origin_height & 0xff));
        origin_height >>= 8;
    }
    proof.insert(proof.end(), origin_parent.begin(), origin_parent.end());
    proof.push_back(static_cast<unsigned char>(target.size() & 0xff));
    proof.push_back(static_cast<unsigned char>((target.size() >> 8) & 0xff));
    proof.insert(proof.end(), target.begin(), target.end());
    proof.push_back(
        static_cast<unsigned char>(quantum_payout.size() & 0xff));
    proof.push_back(static_cast<unsigned char>(
        (quantum_payout.size() >> 8) & 0xff));
    proof.insert(proof.end(), quantum_payout.begin(), quantum_payout.end());

    static constexpr uint32_t SEQUENCE_REPLACEABLE = 0xfffffffd;
    CMutableTransaction claim;
    claim.nVersion = CTransaction::CURRENT_VERSION;
    claim.vin.emplace_back(input, CScript(), SEQUENCE_REPLACEABLE);
    claim.vout.emplace_back(anchor_amount - fee, target);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    CTransactionRef result = MakeTransactionRef(std::move(claim));
    BOOST_REQUIRE(TransactionHasShadowProof(*result));
    return result;
}

CTransactionRef MakeExactRecoveryTestQQP4Claim(
    const COutPoint& input, CAmount anchor_amount, CAmount fee,
    uint32_t origin_height, const uint256& origin_parent,
    const CScript& target, const CScript& quantum_payout, uint64_t nonce)
{
    BOOST_REQUIRE(fee > 0);
    BOOST_REQUIRE(fee <= CENT);
    BOOST_REQUIRE(anchor_amount > fee);
    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '4', 0});
    for (size_t byte = 0; byte < sizeof(nonce); ++byte) {
        proof.push_back(static_cast<unsigned char>(nonce & 0xff));
        nonce >>= 8;
    }
    for (size_t byte = 0; byte < sizeof(origin_height); ++byte) {
        proof.push_back(static_cast<unsigned char>(origin_height & 0xff));
        origin_height >>= 8;
    }
    proof.insert(proof.end(), origin_parent.begin(), origin_parent.end());
    proof.insert(proof.end(), input.hash.begin(), input.hash.end());
    uint32_t input_index = input.n;
    for (size_t byte = 0; byte < sizeof(input_index); ++byte) {
        proof.push_back(static_cast<unsigned char>(input_index & 0xff));
        input_index >>= 8;
    }
    proof.push_back(static_cast<unsigned char>(target.size() & 0xff));
    proof.push_back(static_cast<unsigned char>((target.size() >> 8) & 0xff));
    proof.insert(proof.end(), target.begin(), target.end());
    proof.push_back(
        static_cast<unsigned char>(quantum_payout.size() & 0xff));
    proof.push_back(static_cast<unsigned char>(
        (quantum_payout.size() >> 8) & 0xff));
    proof.insert(proof.end(), quantum_payout.begin(), quantum_payout.end());

    static constexpr uint32_t SEQUENCE_REPLACEABLE = 0xfffffffd;
    CMutableTransaction claim;
    claim.nVersion = CTransaction::CURRENT_VERSION;
    claim.vin.emplace_back(input, CScript(), SEQUENCE_REPLACEABLE);
    claim.vout.emplace_back(anchor_amount - fee, target);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    CTransactionRef result = MakeTransactionRef(std::move(claim));
    BOOST_REQUIRE(TransactionHasShadowProof(*result));
    return result;
}

CTransactionRef MakeExactRecoveryTestClaimFromProof(
    const COutPoint& input, CAmount anchor_amount, CAmount fee,
    const CScript& target, const std::vector<unsigned char>& proof)
{
    BOOST_REQUIRE(fee > 0);
    BOOST_REQUIRE(fee <= CENT);
    BOOST_REQUIRE(anchor_amount > fee);
    static constexpr uint32_t SEQUENCE_REPLACEABLE = 0xfffffffd;
    CMutableTransaction claim;
    claim.nVersion = CTransaction::CURRENT_VERSION;
    claim.vin.emplace_back(input, CScript(), SEQUENCE_REPLACEABLE);
    claim.vout.emplace_back(anchor_amount - fee, target);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    CTransactionRef result = MakeTransactionRef(std::move(claim));
    BOOST_REQUIRE(TransactionHasShadowProof(*result));
    return result;
}

CTransactionRef MakeCurrentTipIneligibleExactRecoveryTestQQP2Claim(
    ChainstateManager& chainman, const COutPoint& input,
    CAmount anchor_amount, CAmount fee, const CScript& target,
    const CScript& quantum_payout, uint64_t& next_nonce)
{
    for (size_t attempt = 0; attempt < 10000; ++attempt) {
        const CTransactionRef candidate = MakeExactRecoveryTestQQP2Claim(
            input, anchor_amount, fee, target, quantum_payout, next_nonce++);
        ShadowPowClaimMempoolDisposition disposition{
            ShadowPowClaimMempoolDisposition::LOCAL_STATE_ERROR};
        std::string reject_reason;
        {
            LOCK(::cs_main);
            const CBlockIndex* tip = chainman.ActiveChain().Tip();
            BOOST_REQUIRE(tip);
            CheckShadowPowClaimForMempoolDetailed(
                *candidate, tip, chainman.ActiveChainstate().CoinsTip(),
                /*gold_rush_active=*/true, reject_reason, &disposition);
        }
        if (disposition ==
            ShadowPowClaimMempoolDisposition::UNBOUND_PROOF_MAY_REVALIDATE) {
            return candidate;
        }
    }
    BOOST_FAIL("could not construct a current-tip-ineligible QQP2 claim");
    return {};
}

CTransactionRef MakeCurrentTipEligibleExactRecoveryTestQQP2Claim(
    ChainstateManager& chainman, const COutPoint& input,
    CAmount anchor_amount, CAmount fee, const CScript& target,
    const CScript& quantum_payout, uint64_t& next_nonce)
{
    for (size_t attempt = 0; attempt < 10000; ++attempt) {
        const CTransactionRef candidate = MakeExactRecoveryTestQQP2Claim(
            input, anchor_amount, fee, target, quantum_payout, next_nonce++);
        ShadowPowClaimMempoolDisposition disposition{
            ShadowPowClaimMempoolDisposition::LOCAL_STATE_ERROR};
        std::string reject_reason;
        ShadowProofValidationResult result;
        {
            LOCK(::cs_main);
            const CBlockIndex* tip = chainman.ActiveChain().Tip();
            BOOST_REQUIRE(tip);
            result = CheckShadowPowClaimForMempoolDetailed(
                *candidate, tip, chainman.ActiveChainstate().CoinsTip(),
                /*gold_rush_active=*/true, reject_reason, &disposition);
        }
        if (result == ShadowProofValidationResult::VALID &&
            disposition == ShadowPowClaimMempoolDisposition::ELIGIBLE) {
            return candidate;
        }
    }
    BOOST_FAIL("could not construct a current-tip-eligible QQP2 claim");
    return {};
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

bool HasRetirementMarker(const CWalletTx& wtx)
{
    return wtx.mapValue.count(SHADOW_POW_CLAIM_EXPIRED_RETIRED_KEY) != 0 ||
           wtx.mapValue.count(
               SHADOW_POW_CLAIM_EXPIRED_RETIRED_HEIGHT_KEY) != 0 ||
           wtx.mapValue.count(
               SHADOW_POW_CLAIM_EXPIRED_RETIRED_TIP_KEY) != 0;
}

void SetRecoveryTestClaimLineage(
    CWallet& wallet, const uint256& claim_txid,
    const uint256& family_fingerprint, const uint256& root_txid,
    const uint256& parent_txid, uint32_t ordinal)
{
    BOOST_REQUIRE(ordinal > 0);
    LOCK(wallet.cs_wallet);
    CWalletTx& wtx = wallet.mapWallet.at(claim_txid);
    wtx.mapValue[SHADOW_POW_CLAIM_LINEAGE_SCHEMA_KEY] =
        SHADOW_POW_CLAIM_LINEAGE_SCHEMA_VERSION;
    wtx.mapValue[SHADOW_POW_CLAIM_LINEAGE_FAMILY_KEY] =
        family_fingerprint.GetHex();
    wtx.mapValue[SHADOW_POW_CLAIM_LINEAGE_ROOT_KEY] = root_txid.GetHex();
    wtx.mapValue[SHADOW_POW_CLAIM_LINEAGE_PARENT_KEY] = parent_txid.GetHex();
    wtx.mapValue[SHADOW_POW_CLAIM_LINEAGE_ORDINAL_KEY] = ToString(ordinal);
}

void SetRecoveryTestClaimLineageRoot(
    CWallet& wallet, const uint256& claim_txid,
    const uint256& family_fingerprint)
{
    LOCK(wallet.cs_wallet);
    CWalletTx& wtx = wallet.mapWallet.at(claim_txid);
    wtx.mapValue[SHADOW_POW_CLAIM_LINEAGE_SCHEMA_KEY] =
        SHADOW_POW_CLAIM_LINEAGE_SCHEMA_VERSION;
    wtx.mapValue[SHADOW_POW_CLAIM_LINEAGE_FAMILY_KEY] =
        family_fingerprint.GetHex();
    wtx.mapValue[SHADOW_POW_CLAIM_LINEAGE_ROOT_KEY] = claim_txid.GetHex();
    wtx.mapValue.erase(SHADOW_POW_CLAIM_LINEAGE_PARENT_KEY);
    wtx.mapValue[SHADOW_POW_CLAIM_LINEAGE_ORDINAL_KEY] = "0";
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

BOOST_AUTO_TEST_CASE(mining_gate_accepts_only_an_authenticated_same_anchor_lineage)
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
    const CBlockIndex* root_parent = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain()[tip->nHeight - 1]);
    BOOST_REQUIRE(root_parent);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CAmount anchor_amount = anchor_tx->vout.at(0).nValue;
    const CScript target = CanonicalizeLegacyStakeScript(
        anchor_tx->vout.at(0).scriptPubKey);
    const CScript payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x51)});
    const uint256 family = ComputeShadowPowClaimLineageFamilyFingerprint(
        anchor, anchor_amount, anchor_tx->vout.at(0).scriptPubKey);
    BOOST_REQUIRE(!family.IsNull());

    uint64_t nonce{0};
    const CTransactionRef root =
        MakeCurrentTipIneligibleExactRecoveryTestQQP2Claim(
            chainman, anchor, anchor_amount, /*fee=*/1000, target, payout,
            nonce);
    AddRecoveryTestClaim(
        *wallet, root, tip->nHeight, root_parent->GetBlockHash(), tip->nHeight,
        tip->GetBlockHash());

    const ShadowPowClaimMiningGate singleton =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(singleton.coherent);
    BOOST_CHECK(!singleton.recovery_database_ambiguous);
    BOOST_CHECK(singleton.action ==
                ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
    BOOST_CHECK(singleton.MayRefreshSameAnchor());
    BOOST_CHECK(!singleton.MayCreateNewAnchorClaim());
    BOOST_CHECK(!singleton.HasUnsafeClaims());
    BOOST_CHECK_EQUAL(singleton.unresolved_components, 1U);
    BOOST_CHECK_EQUAL(singleton.family_claims, 1U);
    BOOST_CHECK_EQUAL(singleton.live_claims, 0U);
    BOOST_CHECK_EQUAL(singleton.eligible_claims, 0U);
    BOOST_CHECK(singleton.anchor == anchor);
    BOOST_CHECK_EQUAL(singleton.anchor_amount, anchor_amount);
    BOOST_CHECK(singleton.target == target);
    BOOST_CHECK(singleton.payout_script == payout);
    BOOST_CHECK(singleton.generation_fingerprint == family);
    BOOST_CHECK(singleton.lineage_root_txid == root->GetHash());
    BOOST_CHECK(singleton.lineage_head_txid == root->GetHash());
    BOOST_CHECK_EQUAL(singleton.next_lineage_ordinal, 1U);

    // A refresh is a conflicting direct sibling, not a descendant and not a
    // spend of another confirmed fee coin. Its durable metadata forms one
    // append-only lineage even though every transaction spends the same root.
    const CTransactionRef sibling =
        MakeCurrentTipIneligibleExactRecoveryTestQQP2Claim(
            chainman, anchor, anchor_amount, /*fee=*/1001, target, payout,
            nonce);
    AddRecoveryTestClaim(
        *wallet, sibling, tip->nHeight, root_parent->GetBlockHash(),
        tip->nHeight, tip->GetBlockHash());
    SetRecoveryTestClaimLineage(
        *wallet, sibling->GetHash(), family, root->GetHash(), root->GetHash(),
        /*ordinal=*/1);

    const ShadowPowClaimMiningGate lineage =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(lineage.action ==
                ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
    BOOST_CHECK(lineage.MayRefreshSameAnchor());
    BOOST_CHECK(!lineage.HasUnsafeClaims());
    BOOST_CHECK_EQUAL(lineage.unresolved_components, 1U);
    BOOST_CHECK_EQUAL(lineage.family_claims, 2U);
    BOOST_CHECK(lineage.anchor == anchor);
    BOOST_CHECK(lineage.lineage_root_txid == root->GetHash());
    BOOST_CHECK(lineage.lineage_head_txid == sibling->GetHash());
    BOOST_CHECK_EQUAL(lineage.next_lineage_ordinal, 2U);

    const auto inventory = wallet->GetShadowPowClaimRecoveryInventory();
    const auto& component = FindRecoveryComponent(inventory, anchor);
    BOOST_CHECK_EQUAL(component.claim_txids.size(), 2U);
    BOOST_CHECK_EQUAL(component.root_claim_txids.size(), 2U);
    BOOST_CHECK_EQUAL(component.descendant_claims, 0U);
    BOOST_CHECK(component.ordinary_or_mixed_txids.empty());
    BOOST_CHECK(component.resolution_txids.empty());
    BOOST_REQUIRE_EQUAL(component.nodes.size(), 2U);
    BOOST_CHECK_EQUAL(component.nodes.front().created_height,
                      component.nodes.back().created_height);
    BOOST_CHECK(component.nodes.front().created_tip ==
                component.nodes.back().created_tip);
}

BOOST_AUTO_TEST_CASE(
    mining_gate_services_multiple_authenticated_families_deterministically)
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
    const CBlockIndex* authored_parent = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain()[tip->nHeight - 1]);
    BOOST_REQUIRE(authored_parent);
    const CScript payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x5a)});

    uint64_t nonce{50000};
    for (size_t anchor_index : {2U, 3U, 4U}) {
        const CTransactionRef anchor_tx = m_coinbase_txns.at(anchor_index);
        const COutPoint anchor{anchor_tx->GetHash(), 0};
        const CAmount anchor_amount = anchor_tx->vout.at(0).nValue;
        const CScript target = CanonicalizeLegacyStakeScript(
            anchor_tx->vout.at(0).scriptPubKey);
        const CTransactionRef root =
            MakeCurrentTipIneligibleExactRecoveryTestQQP2Claim(
                chainman, anchor, anchor_amount, /*fee=*/1000, target,
                payout, nonce);
        AddRecoveryTestClaim(
            *wallet, root, tip->nHeight, authored_parent->GetBlockHash(),
            tip->nHeight, tip->GetBlockHash());
    }

    ShadowPowClaimRecoveryInventory inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    BOOST_REQUIRE_EQUAL(inventory.components.size(), 3U);
    for (const ShadowPowClaimRecoveryComponent& component :
         inventory.components) {
        BOOST_REQUIRE(component.anchor_authenticated);
        BOOST_REQUIRE_EQUAL(component.nodes.size(), 1U);
        BOOST_REQUIRE_EQUAL(component.claim_txids.size(), 1U);
    }

    // Starting the miner for retained families must not require or allocate a
    // new configured payout key. Each same-anchor continuation is already
    // bound to its family's authenticated payout script.
    const ShadowPowClaimMiningGate retained_family_gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_REQUIRE(retained_family_gate.MayRefreshSameAnchor());
    const size_t quantum_keys_before = WITH_LOCK(
        wallet->cs_wallet, return wallet->ListQuantumKeyInfos().size());
    bilingual_str start_error;
    bool created_payout{true};
    BOOST_REQUIRE_MESSAGE(
        wallet->SetPowMining(
            /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/1,
            start_error, &created_payout,
            /*allow_new_payout_key=*/false),
        start_error.original);
    BOOST_CHECK(!created_payout);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(wallet->cs_wallet,
                  return wallet->ListQuantumKeyInfos().size()),
        quantum_keys_before);
    wallet->StopPowMining();

    // Explicit one-call consent while servicing a retained family binds one
    // future-new-anchor payout now, so the call returns the backup warning
    // synchronously and a later CREATE transition cannot allocate silently.
    created_payout = false;
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

    created_payout = true;
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
        quantum_keys_before + 1);
    wallet->StopPowMining();

    // A family-local refresh failure is suppressed only for the exact
    // authoritative snapshot. The aggregate selector must then service every
    // independent refresh family before falling back to a wallet-wide wait.
    const ShadowPowClaimMiningGate first_refresh =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_REQUIRE(first_refresh.MayRefreshSameAnchor());
    ShadowPowClaimMiningGate stale_refresh = first_refresh;
    ++stale_refresh.active_height;
    const ShadowPowClaimMiningGate stale_result =
        wallet->DeferShadowPowClaimFamilyForSnapshot(stale_refresh);
    BOOST_CHECK(stale_result.MayRefreshSameAnchor());
    BOOST_CHECK(stale_result.lineage_root_txid ==
                first_refresh.lineage_root_txid);

    ShadowPowClaimMiningGate second_refresh;
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        second_refresh =
            wallet->DeferShadowPowClaimFamilyForSnapshotLocked(
                first_refresh);
    }
    BOOST_REQUIRE(second_refresh.MayRefreshSameAnchor());
    BOOST_CHECK(second_refresh.lineage_root_txid !=
                first_refresh.lineage_root_txid);
    const ShadowPowClaimMiningGate third_refresh =
        wallet->DeferShadowPowClaimFamilyForSnapshot(second_refresh);
    BOOST_REQUIRE(third_refresh.MayRefreshSameAnchor());
    BOOST_CHECK(third_refresh.lineage_root_txid !=
                first_refresh.lineage_root_txid);
    BOOST_CHECK(third_refresh.lineage_root_txid !=
                second_refresh.lineage_root_txid);
    const ShadowPowClaimMiningGate all_refreshes_deferred =
        wallet->DeferShadowPowClaimFamilyForSnapshot(third_refresh);
    BOOST_CHECK(all_refreshes_deferred.action ==
                ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP);
    BOOST_CHECK(!all_refreshes_deferred.MayCreateClaim());
    BOOST_CHECK(all_refreshes_deferred.relay_txid.IsNull());
    BOOST_CHECK_EQUAL(all_refreshes_deferred.unresolved_components, 3U);
    BOOST_CHECK_EQUAL(all_refreshes_deferred.family_claims, 3U);
    created_payout = true;
    BOOST_REQUIRE_MESSAGE(
        wallet->SetPowMining(
            /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/1,
            start_error, &created_payout,
            /*allow_new_payout_key=*/false),
        start_error.original);
    BOOST_CHECK(!created_payout);
    const ShadowPowClaimMiningGate restarted_worker_gate = WITH_LOCK(
        wallet->m_pow_miner_mutex, return wallet->m_pow_mining_gate);
    BOOST_CHECK(restarted_worker_gate.action ==
                ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP);
    BOOST_CHECK(!restarted_worker_gate.MayCreateClaim());
    wallet->StopPowMining();

    // Model one live family, one relayable family, and one family ready for a
    // same-anchor continuation. These are ordinary upgrade states that older
    // releases could create before the wallet-wide typed single-flight gate.
    inventory.components.at(0).nodes.front().in_mempool = true;
    inventory.components.at(1).nodes.front().disposition =
        ShadowPowClaimMempoolDisposition::ELIGIBLE;
    inventory.components.at(1).nodes.front().relay_ttl_expired = false;
    inventory.components.at(1).nodes.front().relay_expiry_time = 12345;

    const COutPoint live_anchor = inventory.components.at(0).anchor;
    const COutPoint relay_anchor = inventory.components.at(1).anchor;
    const uint256 relay_txid =
        inventory.components.at(1).nodes.front().txid;
    const ShadowPowClaimMiningGate relay_first_gate =
        BuildShadowPowClaimMiningGate(inventory);
    BOOST_CHECK(relay_first_gate.action ==
                ShadowPowClaimMiningGateAction::RELAY_EXISTING);
    BOOST_CHECK(!relay_first_gate.HasUnsafeClaims());
    BOOST_CHECK_EQUAL(relay_first_gate.unresolved_components, 3U);
    BOOST_CHECK_EQUAL(relay_first_gate.family_claims, 3U);
    BOOST_CHECK_EQUAL(relay_first_gate.live_claims, 1U);
    BOOST_CHECK_EQUAL(relay_first_gate.eligible_claims, 1U);
    BOOST_CHECK(relay_first_gate.anchor == relay_anchor);
    BOOST_CHECK(relay_first_gate.relay_txid == relay_txid);

    std::reverse(inventory.components.begin(), inventory.components.end());
    const ShadowPowClaimMiningGate reordered_relay_gate =
        BuildShadowPowClaimMiningGate(inventory);
    BOOST_CHECK(reordered_relay_gate.action == relay_first_gate.action);
    BOOST_CHECK(reordered_relay_gate.anchor == relay_first_gate.anchor);
    BOOST_CHECK(reordered_relay_gate.lineage_root_txid ==
                relay_first_gate.lineage_root_txid);
    BOOST_CHECK(reordered_relay_gate.lineage_head_txid ==
                relay_first_gate.lineage_head_txid);

    const auto find_component =
        [&](const COutPoint& anchor)
            -> ShadowPowClaimRecoveryComponent& {
            const auto it = std::find_if(
                inventory.components.begin(), inventory.components.end(),
                [&](const ShadowPowClaimRecoveryComponent& component) {
                    return component.anchor == anchor;
                });
            BOOST_REQUIRE(it != inventory.components.end());
            return *it;
        };
    find_component(relay_anchor).nodes.front().relay_ttl_expired = true;
    const COutPoint expected_refresh_anchor =
        std::min_element(
            inventory.components.begin(), inventory.components.end(),
            [&](const ShadowPowClaimRecoveryComponent& left,
                const ShadowPowClaimRecoveryComponent& right) {
                if (left.anchor == live_anchor) return false;
                if (right.anchor == live_anchor) return true;
                return left.anchor < right.anchor;
            })->anchor;
    const ShadowPowClaimMiningGate refresh_gate =
        BuildShadowPowClaimMiningGate(inventory);
    BOOST_CHECK(refresh_gate.action ==
                ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
    BOOST_CHECK(refresh_gate.MayRefreshSameAnchor());
    BOOST_CHECK(!refresh_gate.MayCreateNewAnchorClaim());
    BOOST_CHECK(refresh_gate.anchor == expected_refresh_anchor);

    // Independent safe families are serviced before a wallet-wide wait. Once
    // every family has a live member, the aggregate gate waits without
    // creating another anchor or a competing sibling.
    for (ShadowPowClaimRecoveryComponent& component : inventory.components) {
        component.nodes.front().in_mempool = true;
    }
    const ShadowPowClaimMiningGate all_live_gate =
        BuildShadowPowClaimMiningGate(inventory);
    BOOST_CHECK(all_live_gate.action ==
                ShadowPowClaimMiningGateAction::WAIT_FOR_LIVE);
    BOOST_CHECK_EQUAL(all_live_gate.live_claims, 3U);
    BOOST_CHECK(!all_live_gate.MayCreateClaim());
    for (ShadowPowClaimRecoveryComponent& component : inventory.components) {
        component.nodes.front().in_mempool = false;
    }
    const ShadowPowClaimMiningGate baseline_without_foreign =
        BuildShadowPowClaimMiningGate(inventory);
    BOOST_REQUIRE(baseline_without_foreign.action ==
                  ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);

    ShadowPowClaimRecoveryComponent foreign;
    foreign.state = ShadowPowClaimRecoveryState::INDETERMINATE;
    ShadowPowClaimRecoveryNode foreign_node;
    foreign_node.kind = ShadowPowClaimRecoveryNodeKind::CLAIM;
    foreign_node.txid = uint256S("f0");
    foreign_node.provenance =
        ShadowPowClaimRecoveryProvenance::UNKNOWN;
    foreign.nodes.push_back(foreign_node);
    foreign.claim_txids.push_back(foreign_node.txid);
    ShadowPowClaimRecoveryNode foreign_ordinary;
    foreign_ordinary.kind = ShadowPowClaimRecoveryNodeKind::ORDINARY;
    foreign_ordinary.txid = uint256S("f1");
    foreign_ordinary.provenance =
        ShadowPowClaimRecoveryProvenance::UNKNOWN;
    foreign.nodes.push_back(foreign_ordinary);
    foreign.ordinary_or_mixed_txids.push_back(foreign_ordinary.txid);
    inventory.components.push_back(foreign);
    const ShadowPowClaimMiningGate with_foreign =
        BuildShadowPowClaimMiningGate(inventory);
    BOOST_CHECK(with_foreign.action == baseline_without_foreign.action);
    BOOST_CHECK(with_foreign.anchor == baseline_without_foreign.anchor);
    BOOST_CHECK_EQUAL(with_foreign.unresolved_components, 3U);
    BOOST_CHECK_EQUAL(with_foreign.family_claims, 3U);
    BOOST_CHECK_EQUAL(with_foreign.unsafe_components, 0U);
    BOOST_CHECK_EQUAL(with_foreign.unsafe_claims, 0U);

    // The same mixed graph becomes wallet-relevant when its ordinary member
    // spends wallet value or is otherwise marked from-me. It must then fail
    // closed instead of being hidden by the incoming-claim audit exception.
    inventory.components.back().nodes.back().wallet_from_me = true;
    const ShadowPowClaimMiningGate with_local_ordinary =
        BuildShadowPowClaimMiningGate(inventory);
    BOOST_CHECK(with_local_ordinary.action ==
                ShadowPowClaimMiningGateAction::UNSAFE);
    BOOST_CHECK_EQUAL(with_local_ordinary.unsafe_components, 1U);
    inventory.components.back().nodes.back().wallet_from_me = false;

    // Any wallet-relevant family that fails the original strict proof and
    // lineage checks still closes the aggregate gate, without exposing a safe
    // family's action payload as if it were authorized.
    ShadowPowClaimRecoveryComponent& corrupted =
        find_component(relay_anchor);
    corrupted.nodes.front().wallet_from_me = false;
    const ShadowPowClaimMiningGate unsafe_gate =
        BuildShadowPowClaimMiningGate(inventory);
    BOOST_CHECK(unsafe_gate.action ==
                ShadowPowClaimMiningGateAction::UNSAFE);
    BOOST_CHECK(unsafe_gate.HasUnsafeClaims());
    BOOST_CHECK_EQUAL(unsafe_gate.unresolved_components, 3U);
    BOOST_CHECK_EQUAL(unsafe_gate.unsafe_components, 1U);
    BOOST_CHECK_EQUAL(unsafe_gate.unsafe_claims, 1U);
    BOOST_CHECK(unsafe_gate.anchor.IsNull());
    BOOST_CHECK(unsafe_gate.lineage_root_txid.IsNull());
    BOOST_CHECK(unsafe_gate.lineage_head_txid.IsNull());
    BOOST_CHECK(unsafe_gate.relay_txid.IsNull());
}

BOOST_AUTO_TEST_CASE(mining_gate_has_no_wallet_history_cap_for_same_anchor_lineage)
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
    const CBlockIndex* authored_parent = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain()[tip->nHeight - 1]);
    BOOST_REQUIRE(authored_parent);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(1);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CAmount anchor_amount = anchor_tx->vout.at(0).nValue;
    const CScript target = CanonicalizeLegacyStakeScript(
        anchor_tx->vout.at(0).scriptPubKey);
    const CScript payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x51)});
    const uint256 family = ComputeShadowPowClaimLineageFamilyFingerprint(
        anchor, anchor_amount, anchor_tx->vout.at(0).scriptPubKey);

    uint64_t nonce{10000};
    const CTransactionRef root =
        MakeCurrentTipIneligibleExactRecoveryTestQQP2Claim(
            chainman, anchor, anchor_amount, /*fee=*/1000, target, payout,
            nonce);
    AddRecoveryTestClaim(
        *wallet, root, tip->nHeight, authored_parent->GetBlockHash(),
        tip->nHeight, tip->GetBlockHash());
    uint256 parent = root->GetHash();
    for (uint32_t ordinal = 1; ordinal <= 65; ++ordinal) {
        const CTransactionRef sibling =
            MakeCurrentTipIneligibleExactRecoveryTestQQP2Claim(
                chainman, anchor, anchor_amount,
                /*fee=*/1000 + ordinal, target, payout, nonce);
        AddRecoveryTestClaim(
            *wallet, sibling, tip->nHeight,
            authored_parent->GetBlockHash(), tip->nHeight,
            tip->GetBlockHash());
        SetRecoveryTestClaimLineage(
            *wallet, sibling->GetHash(), family, root->GetHash(), parent,
            ordinal);
        parent = sibling->GetHash();
    }

    // The block evaluator's 64-proof cap is not a wallet-history cap. Direct
    // conflicts sharing one anchor cannot coexist in a valid block, so all 66
    // retained siblings still authorize exactly one same-anchor refresh.
    // They may also share one authored height/tip when the one-hour TTL rolls
    // over without a new block; ordinal and parent metadata serialize them.
    const ShadowPowClaimMiningGate gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(gate.action ==
                ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
    BOOST_CHECK(gate.MayRefreshSameAnchor());
    BOOST_CHECK(!gate.HasUnsafeClaims());
    BOOST_CHECK_EQUAL(gate.unresolved_components, 1U);
    BOOST_CHECK_EQUAL(gate.family_claims, 66U);
    BOOST_CHECK_EQUAL(gate.live_claims, 0U);
    BOOST_CHECK_EQUAL(gate.eligible_claims, 0U);
    BOOST_CHECK(gate.lineage_root_txid == root->GetHash());
    BOOST_CHECK(gate.lineage_head_txid == parent);
    BOOST_CHECK_EQUAL(gate.next_lineage_ordinal, 66U);
}

BOOST_FIXTURE_TEST_CASE(
    relay_policy_rejection_suppression_is_snapshot_bound,
    RecoveryQQP2TestingSetup)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    auto wait_wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    auto expiry_wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    ChainstateManager& chainman = *Assert(m_node.chainman);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    const CBlockIndex* authored_parent = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain()[tip->nHeight - 1]);
    BOOST_REQUIRE(authored_parent);

    const CScript payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x56)});
    uint64_t nonce{30000};
    std::set<uint256> relay_claims;
    for (size_t anchor_index : {8U, 9U}) {
        const CTransactionRef anchor_tx = m_coinbase_txns.at(anchor_index);
        const COutPoint anchor{anchor_tx->GetHash(), 0};
        const CAmount anchor_amount = anchor_tx->vout.at(0).nValue;
        const CScript target = CanonicalizeLegacyStakeScript(
            anchor_tx->vout.at(0).scriptPubKey);
        const CTransactionRef root =
            MakeCurrentTipEligibleExactRecoveryTestQQP2Claim(
                chainman, anchor, anchor_amount, /*fee=*/1000, target,
                payout, nonce);
        AddRecoveryTestClaim(
            *wallet, root, tip->nHeight, authored_parent->GetBlockHash(),
            tip->nHeight, tip->GetBlockHash());
        AddRecoveryTestClaim(
            *wait_wallet, root, tip->nHeight,
            authored_parent->GetBlockHash(), tip->nHeight,
            tip->GetBlockHash());
        AddRecoveryTestClaim(
            *expiry_wallet, root, tip->nHeight,
            authored_parent->GetBlockHash(), tip->nHeight,
            tip->GetBlockHash());
        relay_claims.insert(root->GetHash());
        const CTransactionRef sibling =
            MakeCurrentTipEligibleExactRecoveryTestQQP2Claim(
                chainman, anchor, anchor_amount, /*fee=*/1100, target,
                payout, nonce);
        AddRecoveryTestClaim(
            *wallet, sibling, tip->nHeight,
            authored_parent->GetBlockHash(), tip->nHeight,
            tip->GetBlockHash());
        AddRecoveryTestClaim(
            *wait_wallet, sibling, tip->nHeight,
            authored_parent->GetBlockHash(), tip->nHeight,
            tip->GetBlockHash());
        AddRecoveryTestClaim(
            *expiry_wallet, sibling, tip->nHeight,
            authored_parent->GetBlockHash(), tip->nHeight,
            tip->GetBlockHash());
        const uint256 family =
            ComputeShadowPowClaimLineageFamilyFingerprint(
                anchor, anchor_amount,
                anchor_tx->vout.at(0).scriptPubKey);
        SetRecoveryTestClaimLineage(
            *wallet, sibling->GetHash(), family,
            root->GetHash(), root->GetHash(), /*ordinal=*/1);
        SetRecoveryTestClaimLineage(
            *wait_wallet, sibling->GetHash(), family,
            root->GetHash(), root->GetHash(), /*ordinal=*/1);
        SetRecoveryTestClaimLineage(
            *expiry_wallet, sibling->GetHash(), family,
            root->GetHash(), root->GetHash(), /*ordinal=*/1);
        relay_claims.insert(sibling->GetHash());
    }

    const auto inventory = wallet->GetShadowPowClaimRecoveryInventory();
    const ShadowPowClaimMiningGate pure_gate =
        BuildShadowPowClaimMiningGate(inventory);
    BOOST_REQUIRE(pure_gate.action ==
                  ShadowPowClaimMiningGateAction::RELAY_EXISTING);
    BOOST_REQUIRE(pure_gate.ShouldRelayExisting());
    BOOST_CHECK(relay_claims.count(pure_gate.relay_txid) == 1);
    BOOST_CHECK(!pure_gate.candidate_state_fingerprint.IsNull());
    const ShadowPowClaimMiningGate public_before =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(public_before.action == pure_gate.action);
    BOOST_CHECK(public_before.candidate_state_fingerprint ==
                pure_gate.candidate_state_fingerprint);

    const ShadowPowClaimMiningGate wait_first =
        wait_wallet->GetShadowPowClaimMiningGate();
    BOOST_REQUIRE(wait_first.ShouldRelayExisting());
    const ShadowPowClaimMiningGate wait_second =
        wait_wallet->DeferShadowPowClaimFamilyForSnapshot(
            wait_first);
    BOOST_REQUIRE(wait_second.ShouldRelayExisting());
    BOOST_CHECK(wait_second.lineage_root_txid !=
                wait_first.lineage_root_txid);
    const ShadowPowClaimMiningGate all_deferred =
        wait_wallet->DeferShadowPowClaimFamilyForSnapshot(
            wait_second);
    BOOST_CHECK(all_deferred.action ==
                ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP);
    BOOST_CHECK(all_deferred.relay_txid.IsNull());
    BOOST_CHECK(!all_deferred.MayCreateClaim());
    BOOST_CHECK(wait_wallet->GetShadowPowClaimMiningGate().action ==
                ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP);
    const int64_t all_deferred_expiry = std::max(
        wait_first.relay_expiry_time, wait_second.relay_expiry_time);
    BOOST_REQUIRE_GT(all_deferred_expiry, 0);
    const uint256 all_deferred_fingerprint =
        all_deferred.candidate_state_fingerprint;
    const int64_t all_deferred_original_time = GetTime();
    SetMockTime(all_deferred_expiry + 1);
    const ShadowPowClaimMiningGate all_deferred_after_expiry =
        wait_wallet->GetShadowPowClaimMiningGate();
    SetMockTime(all_deferred_original_time);
    BOOST_CHECK(all_deferred_after_expiry.MayRefreshSameAnchor());
    BOOST_CHECK(all_deferred_after_expiry.candidate_state_fingerprint !=
                all_deferred_fingerprint);
    const size_t wait_keys_before = WITH_LOCK(
        wait_wallet->cs_wallet,
        return wait_wallet->ListQuantumKeyInfos().size());
    bilingual_str wait_start_error;
    bool wait_created_payout{true};
    BOOST_REQUIRE_MESSAGE(
        wait_wallet->SetPowMining(
            /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/1,
            wait_start_error, &wait_created_payout,
            /*allow_new_payout_key=*/false),
        wait_start_error.original);
    BOOST_CHECK(!wait_created_payout);
    BOOST_CHECK_EQUAL(
        WITH_LOCK(wait_wallet->cs_wallet,
                  return wait_wallet->ListQuantumKeyInfos().size()),
        wait_keys_before);
    BOOST_CHECK(WITH_LOCK(
        wait_wallet->cs_wallet,
        return wait_wallet->m_pow_payout_quantum.empty()));
    wait_wallet->StopPowMining();

    // Relay eligibility is partly wall-clock based and does not change the
    // wallet generation or candidate-state fingerprint. A cache populated
    // before expiry must be rebuilt once its earliest absent relay candidate
    // expires; otherwise an exact refresh can oscillate against stale relay
    // telemetry or be hidden behind a wallet-wide wait.
    const ShadowPowClaimMiningGate expiry_first =
        expiry_wallet->GetShadowPowClaimMiningGate();
    BOOST_REQUIRE(expiry_first.ShouldRelayExisting());
    const ShadowPowClaimMiningGate expiry_second =
        expiry_wallet->DeferShadowPowClaimFamilyForSnapshot(expiry_first);
    BOOST_REQUIRE(expiry_second.ShouldRelayExisting());
    BOOST_REQUIRE_GT(expiry_second.relay_expiry_time, 0);
    const int64_t original_mock_time = GetTime();
    SetMockTime(expiry_second.relay_expiry_time + 1);
    const ShadowPowClaimMiningGate fresh_after_relay_expiry =
        expiry_wallet->GetShadowPowClaimMiningGate();
    const ShadowPowClaimMiningGate after_cached_relay_expiry =
        expiry_wallet->DeferShadowPowClaimFamilyForSnapshot(expiry_second);
    SetMockTime(original_mock_time);
    BOOST_CHECK(after_cached_relay_expiry.MayRefreshSameAnchor());
    BOOST_CHECK(after_cached_relay_expiry.lineage_root_txid ==
                fresh_after_relay_expiry.lineage_root_txid);

    ShadowPowClaimRecoveryInventory dual_live_inventory = inventory;
    BOOST_REQUIRE_EQUAL(
        dual_live_inventory.components.front().nodes.size(), 2U);
    for (ShadowPowClaimRecoveryNode& node :
         dual_live_inventory.components.front().nodes) {
        node.in_mempool = true;
    }
    const ShadowPowClaimMiningGate dual_live_gate =
        BuildShadowPowClaimMiningGate(dual_live_inventory);
    BOOST_CHECK(dual_live_gate.action ==
                ShadowPowClaimMiningGateAction::UNSAFE);
    BOOST_CHECK_EQUAL(dual_live_gate.unsafe_components, 1U);
    BOOST_CHECK_EQUAL(dual_live_gate.unsafe_claims, 2U);

    std::set<uint256> rejected;
    ShadowPowClaimMiningGate relay_gate = public_before;
    const COutPoint first_selected_anchor = relay_gate.anchor;
    while (relay_gate.ShouldRelayExisting()) {
        BOOST_CHECK(rejected.insert(relay_gate.relay_txid).second);
        BOOST_CHECK(relay_claims.count(relay_gate.relay_txid) == 1);
        ShadowPowClaimMiningGate next_gate;
        BOOST_REQUIRE(wallet->RecordShadowPowClaimRelayPolicyRejection(
            relay_gate, &next_gate));
        if (rejected.size() == 1U) {
            // The older eligible member of the same family is tried before a
            // paid refresh or a different deterministic family.
            BOOST_CHECK(next_gate.ShouldRelayExisting());
            BOOST_CHECK(next_gate.anchor == first_selected_anchor);
        }
        relay_gate = next_gate;
    }
    BOOST_CHECK_EQUAL(rejected.size(), relay_claims.size());
    const ShadowPowClaimMiningGate public_suppressed =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(public_suppressed.action ==
                ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
    BOOST_CHECK(public_suppressed.MayRefreshSameAnchor());
    BOOST_CHECK(public_suppressed.relay_txid.IsNull());
    // The pure inventory builder remains unsuppressed. The wallet-facing gate
    // suppresses every deterministically rejected relay in this exact
    // snapshot, so no rejected family can starve another relayable family.
    BOOST_CHECK(BuildShadowPowClaimMiningGate(inventory).action ==
                ShadowPowClaimMiningGateAction::RELAY_EXISTING);
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_CHECK(wallet->GetShadowPowClaimMiningGateLocked().action ==
                    ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
        BOOST_CHECK(wallet->GetShadowPowClaimMiningGateFromInventoryLocked(
                              inventory)
                        .action ==
                    ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
    }

    ShadowPowClaimMiningGate wrong_txid = public_before;
    wrong_txid.relay_txid = uint256S("dead");
    BOOST_CHECK(
        !wallet->RecordShadowPowClaimRelayPolicyRejection(wrong_txid));

    // A wallet-generation change invalidates suppression even when the exact
    // eligible transaction bytes and chain tip are unchanged.
    wallet->GetDatabase().nUpdateCounter.fetch_add(1);
    const ShadowPowClaimMiningGate generation_changed =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(generation_changed.action ==
                ShadowPowClaimMiningGateAction::RELAY_EXISTING);
    BOOST_REQUIRE(wallet->RecordShadowPowClaimRelayPolicyRejection(
        generation_changed));

    // A tip change likewise invalidates the stored rejection. Compare the
    // wallet-facing gate to the new tip's pure inventory result so a natural
    // proof disposition change cannot be mistaken for lingering suppression.
    CreateAndProcessBlock({},
                          GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    SyncWithValidationInterfaceQueue();
    SyncRecoveryTestWalletTip(*wallet, chainman);
    BOOST_CHECK(!wallet->RecordShadowPowClaimRelayPolicyRejection(
        generation_changed));
    const auto after_tip_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const ShadowPowClaimMiningGate after_tip_pure =
        BuildShadowPowClaimMiningGate(after_tip_inventory);
    const ShadowPowClaimMiningGate after_tip_public =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(after_tip_public.action == after_tip_pure.action);
    BOOST_CHECK(after_tip_public.relay_txid == after_tip_pure.relay_txid);
}

BOOST_AUTO_TEST_CASE(mining_gate_wait_for_next_tip_telemetry_requires_an_exact_worker_snapshot)
{
    ShadowPowClaimMiningGate fresh;
    fresh.action = ShadowPowClaimMiningGateAction::RELAY_EXISTING;
    fresh.active_tip = uint256S("01");
    fresh.active_height = 101;
    fresh.wallet_generation = 7;
    fresh.candidate_state_fingerprint = uint256S("02");
    fresh.coherent = true;
    fresh.unresolved_components = 1;
    fresh.eligible_claims = 1;
    fresh.family_claims = 2;
    fresh.anchor = COutPoint{uint256S("03"), 1};
    fresh.anchor_amount = 100000;
    fresh.target = CScript() << OP_TRUE;
    fresh.payout_script = CScript() << OP_0;
    fresh.generation_fingerprint = uint256S("04");
    fresh.lineage_root_txid = uint256S("05");
    fresh.lineage_head_txid = uint256S("06");
    fresh.next_lineage_ordinal = 2;
    fresh.relay_txid = fresh.lineage_head_txid;

    ShadowPowClaimMiningGate cached = fresh;
    cached.action = ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP;
    cached.relay_txid.SetNull();
    cached.relay_expiry_time = 0;

    const auto reported = [&](const ShadowPowClaimMiningGate& current,
                              const ShadowPowClaimMiningGate& worker,
                              bool enabled = true,
                              bool claim_in_flight = true,
                              bool wallet_wide_tip_wait = false) {
        return GetShadowPowClaimMiningGateTelemetryAction(
            current, worker, enabled, claim_in_flight,
            wallet_wide_tip_wait);
    };

    BOOST_CHECK(reported(fresh, cached) ==
                ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP);
    BOOST_CHECK(!fresh.MayCreateClaim());
    BOOST_CHECK(reported(fresh, cached, /*enabled=*/false) == fresh.action);
    BOOST_CHECK(reported(fresh, cached, /*enabled=*/true,
                         /*claim_in_flight=*/false) == fresh.action);

    // CREATE_NEW_ANCHOR intentionally has no selected family identity. A
    // failed selected input still owns one exact-tip wallet-wide reservation,
    // so equality of the null family fields is authoritative; requiring them
    // to be non-null would hide the bounded wait and invite sibling retries.
    ShadowPowClaimMiningGate create;
    create.action = ShadowPowClaimMiningGateAction::CREATE_NEW_ANCHOR;
    create.active_tip = uint256S("21");
    create.active_height = 201;
    create.wallet_generation = 9;
    create.candidate_state_fingerprint = uint256S("22");
    create.coherent = true;
    ShadowPowClaimMiningGate create_wait = create;
    create_wait.action =
        ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP;
    BOOST_REQUIRE(create.MayCreateNewAnchorClaim());
    BOOST_CHECK(reported(create, create_wait) ==
                ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP);
    ShadowPowClaimMiningGate create_after_user_lock = create;
    ++create_after_user_lock.wallet_generation;
    create_after_user_lock.candidate_state_fingerprint = uint256S("24");
    BOOST_CHECK(reported(create_after_user_lock, create_wait) ==
                create_after_user_lock.action);
    BOOST_CHECK(reported(create_after_user_lock, create_wait,
                         /*enabled=*/true,
                         /*claim_in_flight=*/true,
                         /*wallet_wide_tip_wait=*/true) ==
                ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP);
    BOOST_CHECK(reported(create_after_user_lock, create,
                         /*enabled=*/true,
                         /*claim_in_flight=*/false,
                         /*wallet_wide_tip_wait=*/true) ==
                ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP);
    ShadowPowClaimMiningGate create_unsafe = create_after_user_lock;
    create_unsafe.action = ShadowPowClaimMiningGateAction::UNSAFE;
    create_unsafe.unsafe_components = 1;
    BOOST_CHECK(reported(create_unsafe, create_wait,
                         /*enabled=*/true,
                         /*claim_in_flight=*/true,
                         /*wallet_wide_tip_wait=*/true) ==
                ShadowPowClaimMiningGateAction::UNSAFE);
    ShadowPowClaimMiningGate create_mismatch = create_wait;
    create_mismatch.anchor = COutPoint{uint256S("23"), 0};
    BOOST_CHECK(reported(create, create_mismatch) == create.action);

    ShadowPowClaimMiningGate mismatch = cached;
    mismatch.active_tip = uint256S("07");
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    ++mismatch.active_height;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    ++mismatch.wallet_generation;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.candidate_state_fingerprint = uint256S("08");
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.candidate_state_fingerprint.SetNull();
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.generation_fingerprint = uint256S("09");
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.generation_fingerprint.SetNull();
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.lineage_root_txid = uint256S("0a");
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.lineage_root_txid.SetNull();
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.lineage_head_txid = uint256S("0b");
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.lineage_head_txid.SetNull();
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.anchor = COutPoint{uint256S("0d"), 1};
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    ++mismatch.anchor_amount;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.target = CScript() << OP_FALSE;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.payout_script = CScript() << OP_TRUE;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    ++mismatch.next_lineage_ordinal;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    ++mismatch.unresolved_components;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    ++mismatch.live_claims;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    ++mismatch.eligible_claims;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    ++mismatch.family_claims;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.action = ShadowPowClaimMiningGateAction::RELAY_EXISTING;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.recovery_database_ambiguous = true;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);
    mismatch = cached;
    mismatch.coherent = false;
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);

    // PERSISTED_PENDING deliberately publishes a null-tip sentinel so the
    // worker immediately rebuilds the typed gate instead of reporting a wait.
    mismatch = cached;
    mismatch.active_tip.SetNull();
    BOOST_CHECK(reported(fresh, mismatch) == fresh.action);

    ShadowPowClaimMiningGate unsafe_component = fresh;
    unsafe_component.unsafe_components = 1;
    BOOST_CHECK(reported(unsafe_component, cached) ==
                unsafe_component.action);
    ShadowPowClaimMiningGate unsafe_action = fresh;
    unsafe_action.action = ShadowPowClaimMiningGateAction::UNSAFE;
    BOOST_CHECK(reported(unsafe_action, cached) == unsafe_action.action);
    ShadowPowClaimMiningGate cached_unsafe = cached;
    cached_unsafe.unsafe_components = 1;
    BOOST_CHECK(reported(fresh, cached_unsafe) == fresh.action);
    ShadowPowClaimMiningGate ambiguous = fresh;
    ambiguous.recovery_database_ambiguous = true;
    BOOST_CHECK(reported(ambiguous, cached) == ambiguous.action);
    ShadowPowClaimMiningGate incoherent = fresh;
    incoherent.coherent = false;
    BOOST_CHECK(reported(incoherent, cached) == incoherent.action);

    // A next-tip inventory snapshot exits the override immediately.
    ShadowPowClaimMiningGate next_tip = fresh;
    next_tip.active_tip = uint256S("0c");
    ++next_tip.active_height;
    BOOST_CHECK(reported(next_tip, cached) == next_tip.action);
    BOOST_CHECK(reported(next_tip, cached, /*enabled=*/true,
                         /*claim_in_flight=*/true,
                         /*wallet_wide_tip_wait=*/true) == next_tip.action);

    // Can-submit remains the fresh inventory decision even while the worker's
    // exact matching snapshot truthfully reports a bounded wait.
    ShadowPowClaimMiningGate refresh = fresh;
    refresh.action = ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR;
    BOOST_REQUIRE(refresh.MayCreateClaim());
    BOOST_CHECK(reported(refresh, cached) ==
                ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP);
}

BOOST_AUTO_TEST_CASE(relay_intent_match_requires_the_complete_exact_snapshot)
{
    ShadowPowClaimMiningGate expected;
    expected.action = ShadowPowClaimMiningGateAction::RELAY_EXISTING;
    expected.active_tip = uint256S("01");
    expected.active_height = 101;
    expected.wallet_generation = 7;
    expected.candidate_state_fingerprint = uint256S("02");
    expected.coherent = true;
    expected.recovery_database_ambiguous = false;
    expected.unresolved_components = 2;
    expected.live_claims = 0;
    expected.eligible_claims = 3;
    expected.family_claims = 4;
    expected.unsafe_claims = 0;
    expected.unsafe_components = 0;
    expected.anchor = COutPoint{uint256S("03"), 1};
    expected.anchor_amount = 100000;
    expected.target = CScript() << OP_TRUE;
    expected.payout_script = CScript() << OP_0;
    expected.generation_fingerprint = uint256S("04");
    expected.lineage_root_txid = uint256S("05");
    expected.lineage_head_txid = uint256S("06");
    expected.next_lineage_ordinal = 2;
    expected.relay_txid = uint256S("07");
    expected.relay_expiry_time = 123456;

    BOOST_REQUIRE(expected.ShouldRelayExisting());
    BOOST_CHECK(ShadowPowClaimRelayIntentMatches(expected, expected));
    const auto rejects = [&](auto mutate) {
        ShadowPowClaimMiningGate changed = expected;
        mutate(changed);
        BOOST_CHECK(!ShadowPowClaimRelayIntentMatches(expected, changed));
    };
    rejects([](auto& gate) {
        gate.action = ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP;
    });
    rejects([](auto& gate) { gate.active_tip = uint256S("11"); });
    rejects([](auto& gate) { ++gate.active_height; });
    rejects([](auto& gate) { ++gate.wallet_generation; });
    rejects([](auto& gate) {
        gate.candidate_state_fingerprint = uint256S("12");
    });
    rejects([](auto& gate) { gate.coherent = false; });
    rejects([](auto& gate) { gate.recovery_database_ambiguous = true; });
    rejects([](auto& gate) { ++gate.unresolved_components; });
    rejects([](auto& gate) { ++gate.live_claims; });
    rejects([](auto& gate) { ++gate.eligible_claims; });
    rejects([](auto& gate) { ++gate.family_claims; });
    rejects([](auto& gate) { ++gate.unsafe_claims; });
    rejects([](auto& gate) { ++gate.unsafe_components; });
    rejects([](auto& gate) { gate.anchor.n = 2; });
    rejects([](auto& gate) { ++gate.anchor_amount; });
    rejects([](auto& gate) { gate.target << OP_FALSE; });
    rejects([](auto& gate) { gate.payout_script << OP_TRUE; });
    rejects([](auto& gate) {
        gate.generation_fingerprint = uint256S("14");
    });
    rejects([](auto& gate) { gate.lineage_root_txid = uint256S("15"); });
    rejects([](auto& gate) { gate.lineage_head_txid = uint256S("16"); });
    rejects([](auto& gate) { ++gate.next_lineage_ordinal; });
    rejects([](auto& gate) { gate.relay_txid = uint256S("17"); });
    rejects([](auto& gate) { ++gate.relay_expiry_time; });
}

BOOST_AUTO_TEST_CASE(mining_gate_fails_closed_for_ambiguous_or_nonfamily_graphs)
{
    RecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                         /*reward_start_height=*/100,
                                         /*gold_rush_blocks=*/1000};
    ChainstateManager& chainman = *Assert(m_node.chainman);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    const CBlockIndex* root_parent = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain()[tip->nHeight - 1]);
    BOOST_REQUIRE(root_parent);
    const CScript payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x51)});
    uint64_t nonce{20000};

    const auto make_wallet = [&]() {
        return CreateSyncedWallet(
            *m_node.chain,
            WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                      return m_node.chainman->ActiveChain()),
            coinbaseKey);
    };
    const auto add_root = [&](CWallet& wallet, size_t anchor_index) {
        const CTransactionRef anchor_tx = m_coinbase_txns.at(anchor_index);
        const COutPoint anchor{anchor_tx->GetHash(), 0};
        const CAmount amount = anchor_tx->vout.at(0).nValue;
        const CScript target = CanonicalizeLegacyStakeScript(
            anchor_tx->vout.at(0).scriptPubKey);
        const CTransactionRef root =
            MakeCurrentTipIneligibleExactRecoveryTestQQP2Claim(
                chainman, anchor, amount, /*fee=*/1000, target, payout,
                nonce);
        AddRecoveryTestClaim(
            wallet, root, tip->nHeight, root_parent->GetBlockHash(),
            tip->nHeight, tip->GetBlockHash());
        return root;
    };

    auto ambiguous = make_wallet();
    add_root(*ambiguous, 2);
    {
        LOCK(ambiguous->cs_wallet);
        ambiguous->MarkShadowPowClaimRecoveryDatabaseAmbiguous();
    }
    const ShadowPowClaimMiningGate ambiguous_gate =
        ambiguous->GetShadowPowClaimMiningGate();
    BOOST_CHECK(ambiguous_gate.recovery_database_ambiguous);
    BOOST_CHECK(ambiguous_gate.action ==
                ShadowPowClaimMiningGateAction::UNSAFE);
    BOOST_CHECK(!ambiguous_gate.MayCreateClaim());

    auto mixed = make_wallet();
    const CTransactionRef mixed_root = add_root(*mixed, 3);
    const COutPoint mixed_anchor = mixed_root->vin.front().prevout;
    CMutableTransaction ordinary;
    ordinary.vin.emplace_back(mixed_anchor);
    ordinary.vout.emplace_back(
        mixed_root->vout.front().nValue - 1000,
        mixed_root->vout.front().scriptPubKey);
    BOOST_REQUIRE(mixed->AddToWallet(
        MakeTransactionRef(std::move(ordinary)), TxStateInactive{}));
    const ShadowPowClaimMiningGate mixed_gate =
        mixed->GetShadowPowClaimMiningGate();
    BOOST_CHECK(mixed_gate.action ==
                ShadowPowClaimMiningGateAction::UNSAFE);
    BOOST_CHECK(mixed_gate.HasUnsafeClaims());
    BOOST_CHECK(!mixed_gate.MayCreateClaim());

    auto descendant = make_wallet();
    const CTransactionRef descendant_root = add_root(*descendant, 4);
    const COutPoint descendant_anchor =
        descendant_root->vin.front().prevout;
    const CTransactionRef descendant_anchor_tx = m_coinbase_txns.at(4);
    const uint256 descendant_family =
        ComputeShadowPowClaimLineageFamilyFingerprint(
            descendant_anchor,
            descendant_anchor_tx->vout.at(descendant_anchor.n).nValue,
            descendant_anchor_tx->vout.at(descendant_anchor.n).scriptPubKey);
    const CTransactionRef child = MakeExactRecoveryTestQQP2Claim(
        COutPoint{descendant_root->GetHash(), 0},
        descendant_root->vout.front().nValue, /*fee=*/1000,
        descendant_root->vout.front().scriptPubKey, payout, nonce++);
    AddRecoveryTestClaim(
        *descendant, child, tip->nHeight + 1, tip->GetBlockHash(),
        tip->nHeight, tip->GetBlockHash());
    SetRecoveryTestClaimLineage(
        *descendant, child->GetHash(), descendant_family,
        descendant_root->GetHash(), descendant_root->GetHash(),
        /*ordinal=*/1);
    const ShadowPowClaimMiningGate descendant_gate =
        descendant->GetShadowPowClaimMiningGate();
    BOOST_CHECK(descendant_gate.action ==
                ShadowPowClaimMiningGateAction::UNSAFE);
    BOOST_CHECK(descendant_gate.HasUnsafeClaims());
    BOOST_CHECK(!descendant_gate.MayCreateClaim());

    auto target_mismatch = make_wallet();
    const CTransactionRef target_root = add_root(*target_mismatch, 5);
    const COutPoint target_anchor = target_root->vin.front().prevout;
    const CTransactionRef target_anchor_tx = m_coinbase_txns.at(5);
    const uint256 target_family =
        ComputeShadowPowClaimLineageFamilyFingerprint(
            target_anchor,
            target_anchor_tx->vout.at(target_anchor.n).nValue,
            target_anchor_tx->vout.at(target_anchor.n).scriptPubKey);
    CKey other_key;
    other_key.MakeNewKey(/*fCompressed=*/true);
    const CScript other_target =
        GetScriptForDestination(PKHash(other_key.GetPubKey()));
    const CTransactionRef wrong_target = MakeExactRecoveryTestQQP2Claim(
        target_anchor, target_anchor_tx->vout.at(target_anchor.n).nValue,
        /*fee=*/1001, other_target, payout, nonce++);
    AddRecoveryTestClaim(
        *target_mismatch, wrong_target, tip->nHeight + 1,
        tip->GetBlockHash(), tip->nHeight, tip->GetBlockHash());
    SetRecoveryTestClaimLineage(
        *target_mismatch, wrong_target->GetHash(), target_family,
        target_root->GetHash(), target_root->GetHash(), /*ordinal=*/1);
    const ShadowPowClaimMiningGate target_gate =
        target_mismatch->GetShadowPowClaimMiningGate();
    BOOST_CHECK(target_gate.action ==
                ShadowPowClaimMiningGateAction::UNSAFE);
    BOOST_CHECK(target_gate.HasUnsafeClaims());
    BOOST_CHECK(!target_gate.MayCreateClaim());

    auto payout_mismatch = make_wallet();
    const CTransactionRef payout_root = add_root(*payout_mismatch, 6);
    const COutPoint payout_anchor = payout_root->vin.front().prevout;
    const CTransactionRef payout_anchor_tx = m_coinbase_txns.at(6);
    const uint256 payout_family =
        ComputeShadowPowClaimLineageFamilyFingerprint(
            payout_anchor,
            payout_anchor_tx->vout.at(payout_anchor.n).nValue,
            payout_anchor_tx->vout.at(payout_anchor.n).scriptPubKey);
    const CScript other_payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x52)});
    const CTransactionRef wrong_payout = MakeExactRecoveryTestQQP2Claim(
        payout_anchor, payout_anchor_tx->vout.at(payout_anchor.n).nValue,
        /*fee=*/1001, payout_root->vout.front().scriptPubKey, other_payout,
        nonce++);
    AddRecoveryTestClaim(
        *payout_mismatch, wrong_payout, tip->nHeight + 1,
        tip->GetBlockHash(), tip->nHeight, tip->GetBlockHash());
    SetRecoveryTestClaimLineage(
        *payout_mismatch, wrong_payout->GetHash(), payout_family,
        payout_root->GetHash(), payout_root->GetHash(), /*ordinal=*/1);
    const ShadowPowClaimMiningGate payout_gate =
        payout_mismatch->GetShadowPowClaimMiningGate();
    BOOST_CHECK(payout_gate.action ==
                ShadowPowClaimMiningGateAction::UNSAFE);
    BOOST_CHECK(payout_gate.HasUnsafeClaims());
    BOOST_CHECK(!payout_gate.MayCreateClaim());

    auto incoherent = make_wallet();
    add_root(*incoherent, 7);
    {
        LOCK(incoherent->cs_wallet);
        incoherent->SetLastBlockProcessed(
            root_parent->nHeight, root_parent->GetBlockHash());
    }
    const ShadowPowClaimMiningGate incoherent_gate =
        incoherent->GetShadowPowClaimMiningGate();
    BOOST_CHECK(!incoherent_gate.coherent);
    BOOST_CHECK_EQUAL(incoherent_gate.unresolved_components, 0U);
    BOOST_CHECK_EQUAL(incoherent->CountUnresolvedShadowPowClaims(), 1U);
    BOOST_CHECK(!incoherent_gate.MayCreateClaim());

    // Explicit key-creation consent is not permission to mutate a wallet
    // merely because its current mining gate is unsafe, its database result
    // is ambiguous, or the wallet tip is temporarily incoherent. Such workers
    // may start in a paused state, but they must not allocate a payout key or
    // change the configured binding.
    for (CWallet* blocked :
         {ambiguous.get(), mixed.get(), incoherent.get()}) {
        const size_t keys_before = WITH_LOCK(
            blocked->cs_wallet,
            return blocked->ListQuantumKeyInfos().size());
        bilingual_str start_error;
        bool created_payout{true};
        BOOST_REQUIRE_MESSAGE(
            blocked->SetPowMining(
                /*enabled=*/true, /*threads=*/1, /*cpu_percent=*/1,
                start_error, &created_payout,
                /*allow_new_payout_key=*/true),
            start_error.original);
        BOOST_CHECK(!created_payout);
        BOOST_CHECK_EQUAL(
            WITH_LOCK(blocked->cs_wallet,
                      return blocked->ListQuantumKeyInfos().size()),
            keys_before);
        BOOST_CHECK(WITH_LOCK(
            blocked->cs_wallet,
            return blocked->m_pow_payout_quantum.empty()));
        blocked->StopPowMining();
    }
}

BOOST_AUTO_TEST_CASE(
    same_anchor_refresh_rejects_a_confirmed_coinbase_made_immature_by_reorg)
{
    auto wallet = CreateSyncedWallet(
        *m_node.chain,
        WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                  return m_node.chainman->ActiveChain()),
        coinbaseKey);
    ChainstateManager& chainman = *Assert(m_node.chainman);
    CBlockIndex* old_tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip());
    BOOST_REQUIRE(old_tip);
    BOOST_REQUIRE_EQUAL(old_tip->nHeight, 100);

    // Regtest coinbase maturity is 10 blocks. The height-90 coinbase has
    // wallet depth 11 at tip 100, then depth 10 (one block remaining under
    // the wallet's candidate-spend convention) after invalidating tip 100.
    const CTransactionRef anchor_tx = m_coinbase_txns.at(89);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CAmount anchor_amount = anchor_tx->vout.at(0).nValue;
    const CScript target = CanonicalizeLegacyStakeScript(
        anchor_tx->vout.at(0).scriptPubKey);
    CTxDestination destination;
    BOOST_REQUIRE(ExtractDestination(target, destination));
    BOOST_REQUIRE(IsValidDestination(destination));
    const CScript payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x52)});

    ShadowPowClaimMiningGate gate;
    gate.action = ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR;
    gate.coherent = true;
    gate.active_tip = old_tip->GetBlockHash();
    gate.active_height = old_tip->nHeight;
    gate.wallet_generation = wallet->GetDatabase().nUpdateCounter.load();
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        gate.candidate_state_fingerprint =
            wallet->GetShadowPowClaimCandidateStateFingerprintLocked();
    }
    gate.anchor = anchor;
    gate.anchor_amount = anchor_amount;
    gate.target = target;
    gate.payout_script = payout;
    gate.generation_fingerprint =
        ComputeShadowPowClaimLineageFamilyFingerprint(
            anchor, anchor_amount, anchor_tx->vout.at(0).scriptPubKey);
    gate.lineage_root_txid = uint256S("11");
    gate.lineage_head_txid = uint256S("22");
    gate.next_lineage_ordinal = 3;

    ShadowPowClaimInput selected;
    selected.outpoint = anchor;
    selected.target = target;
    selected.destination = destination;
    selected.value = anchor_amount;
    selected.quantum_payout_script = payout;
    selected.same_anchor_refresh = true;
    selected.lineage_family_fingerprint = gate.generation_fingerprint;
    selected.lineage_root_txid = gate.lineage_root_txid;
    selected.lineage_parent_txid = gate.lineage_head_txid;
    selected.lineage_ordinal = gate.next_lineage_ordinal;

    BOOST_REQUIRE(ShadowPowClaimRefreshInputMatchesMiningGate(
        selected, gate));
    const auto rejects_changed_family_field = [&](const auto& mutate) {
        ShadowPowClaimInput changed = selected;
        mutate(changed);
        BOOST_CHECK(!ShadowPowClaimRefreshInputMatchesMiningGate(
            changed, gate));
    };
    rejects_changed_family_field(
        [](auto& input) { input.same_anchor_refresh = false; });
    rejects_changed_family_field(
        [](auto& input) { input.outpoint = COutPoint{uint256S("31"), 0}; });
    rejects_changed_family_field(
        [](auto& input) { ++input.value; });
    rejects_changed_family_field(
        [](auto& input) { input.target = CScript{} << OP_FALSE; });
    rejects_changed_family_field(
        [](auto& input) {
            input.quantum_payout_script = CScript{} << OP_TRUE;
        });
    rejects_changed_family_field(
        [](auto& input) { input.lineage_family_fingerprint = uint256S("32"); });
    rejects_changed_family_field(
        [](auto& input) { input.lineage_root_txid = uint256S("33"); });
    rejects_changed_family_field(
        [](auto& input) { input.lineage_parent_txid = uint256S("34"); });
    rejects_changed_family_field(
        [](auto& input) { ++input.lineage_ordinal; });

    ShadowPowClaimMiningGate independent_family = gate;
    independent_family.anchor = COutPoint{uint256S("35"), 0};
    independent_family.generation_fingerprint = uint256S("36");
    independent_family.lineage_root_txid = uint256S("37");
    independent_family.lineage_head_txid = uint256S("38");
    BOOST_CHECK(!ShadowPowClaimRefreshInputMatchesMiningGate(
        selected, independent_family));

    Coin mature_coin;
    bilingual_str error;
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_REQUIRE(wallet->GetShadowPowClaimRefreshCoinLocked(
            selected, gate, mature_coin, error));
    }

    BlockValidationState state;
    BOOST_REQUIRE(chainman.ActiveChainstate().InvalidateBlock(
        state, old_tip));
    SyncWithValidationInterfaceQueue();
    SyncRecoveryTestWalletTip(*wallet, chainman);
    const CBlockIndex* reorg_tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip());
    BOOST_REQUIRE(reorg_tip);
    BOOST_REQUIRE_EQUAL(reorg_tip->nHeight, 99);

    gate.active_tip = reorg_tip->GetBlockHash();
    gate.active_height = reorg_tip->nHeight;
    gate.wallet_generation = wallet->GetDatabase().nUpdateCounter.load();
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        gate.candidate_state_fingerprint =
            wallet->GetShadowPowClaimCandidateStateFingerprintLocked();
    }
    Coin immature_coin;
    error = {};
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_CHECK(!wallet->GetShadowPowClaimRefreshCoinLocked(
            selected, gate, immature_coin, error));
    }
    BOOST_CHECK(error.original.find("immature") != std::string::npos);
}

BOOST_FIXTURE_TEST_CASE(
    mining_gate_accepts_v3_schema_roots_only_after_terminal_origin_state,
    RecoveryQQP3TestingSetup)
{
    ChainstateManager& chainman = *Assert(m_node.chainman);
    const CScript payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x53)});
    const auto make_wallet = [&]() {
        return CreateSyncedWallet(
            *m_node.chain,
            WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                      return m_node.chainman->ActiveChain()),
            coinbaseKey);
    };
    const auto assert_terminal_schema_root = [&](CWallet& wallet,
                                                 const COutPoint& anchor,
                                                 const uint256& txid,
                                                 ShadowPowClaimMempoolDisposition disposition) {
        const auto inventory = wallet.GetShadowPowClaimRecoveryInventory();
        const auto& component = FindRecoveryComponent(inventory, anchor);
        const auto node = std::find_if(
            component.nodes.begin(), component.nodes.end(),
            [&](const auto& candidate) { return candidate.txid == txid; });
        BOOST_REQUIRE(node != component.nodes.end());
        BOOST_CHECK_EQUAL(node->proof_version, 3U);
        BOOST_CHECK(node->proof_origin_bound);
        BOOST_CHECK(!node->proof_input_bound);
        BOOST_CHECK_EQUAL(node->proof_origin_height,
                          static_cast<uint32_t>(node->created_height));
        BOOST_CHECK(node->proof_origin_previous_block_hash ==
                    node->created_tip);
        BOOST_CHECK(node->lineage_metadata_present);
        BOOST_CHECK(node->lineage_metadata_valid);
        BOOST_CHECK_EQUAL(node->lineage_ordinal, 0U);
        BOOST_CHECK(node->lineage_root_txid == txid);
        BOOST_CHECK(node->lineage_parent_txid.IsNull());
        BOOST_CHECK(node->disposition == disposition);

        const ShadowPowClaimMiningGate gate =
            wallet.GetShadowPowClaimMiningGate();
        BOOST_CHECK(gate.action ==
                    ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
        BOOST_CHECK(gate.MayRefreshSameAnchor());
        BOOST_CHECK(!gate.HasUnsafeClaims());
        BOOST_CHECK_EQUAL(gate.family_claims, 1U);
        BOOST_CHECK(gate.anchor == anchor);
        BOOST_CHECK(gate.lineage_root_txid == txid);
        BOOST_CHECK(gate.lineage_head_txid == txid);
        BOOST_CHECK_EQUAL(gate.next_lineage_ordinal, 1U);
    };

    auto expired = make_wallet();
    const CTransactionRef expired_anchor_tx = m_coinbase_txns.at(0);
    const COutPoint expired_anchor{expired_anchor_tx->GetHash(), 0};
    const CAmount expired_amount = expired_anchor_tx->vout.at(0).nValue;
    const CScript expired_target = CanonicalizeLegacyStakeScript(
        expired_anchor_tx->vout.at(0).scriptPubKey);
    const CBlockIndex* origin_parent{nullptr};
    std::vector<unsigned char> expired_proof;
    {
        LOCK(::cs_main);
        origin_parent = chainman.ActiveChain().Tip();
        BOOST_REQUIRE(origin_parent);
        BOOST_REQUIRE(MineShadowProofData(
            expired_target, payout, origin_parent,
            chainman.ActiveChainstate().CoinsTip(), 2'000'000,
            expired_proof));
    }
    BOOST_REQUIRE(origin_parent);
    const int origin_height = origin_parent->nHeight + 1;
    const uint256 origin_parent_hash = origin_parent->GetBlockHash();
    const CTransactionRef expired_root =
        MakeExactRecoveryTestClaimFromProof(
            expired_anchor, expired_amount, /*fee=*/1000, expired_target,
            expired_proof);
    AddRecoveryTestClaim(
        *expired, expired_root, origin_height, origin_parent_hash,
        origin_parent->nHeight, origin_parent_hash);
    const uint256 expired_family =
        ComputeShadowPowClaimLineageFamilyFingerprint(
            expired_anchor, expired_amount,
            expired_anchor_tx->vout.at(0).scriptPubKey);
    SetRecoveryTestClaimLineageRoot(
        *expired, expired_root->GetHash(), expired_family);

    for (uint32_t age = 0; age <= SHADOW_POW_LATE_ORIGIN_WINDOW; ++age) {
        CreateAndProcessBlock({},
                              GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    }
    SyncWithValidationInterfaceQueue();
    SyncRecoveryTestWalletTip(*expired, chainman);
    const auto expired_inventory =
        expired->GetShadowPowClaimRecoveryInventory();
    const auto& expired_component =
        FindRecoveryComponent(expired_inventory, expired_anchor);
    BOOST_CHECK(!expired_component.all_claims_zero_payment_retirable);
    assert_terminal_schema_root(
        *expired, expired_anchor, expired_root->GetHash(),
        ShadowPowClaimMempoolDisposition::ORIGIN_EXPIRED);
    BOOST_CHECK(WITH_LOCK(expired->cs_wallet,
                          return expired->IsSpent(expired_anchor)));
    assert_terminal_schema_root(
        *expired, expired_anchor, expired_root->GetHash(),
        ShadowPowClaimMempoolDisposition::ORIGIN_EXPIRED);

    auto implicit_expired = make_wallet();
    const CTransactionRef implicit_anchor_tx = m_coinbase_txns.at(7);
    const COutPoint implicit_anchor{implicit_anchor_tx->GetHash(), 0};
    const CAmount implicit_amount = implicit_anchor_tx->vout.at(0).nValue;
    BOOST_REQUIRE(CanonicalizeLegacyStakeScript(
                      implicit_anchor_tx->vout.at(0).scriptPubKey) ==
                  expired_target);
    const CTransactionRef implicit_expired_root =
        MakeExactRecoveryTestClaimFromProof(
            implicit_anchor, implicit_amount, /*fee=*/1000, expired_target,
            expired_proof);
    AddRecoveryTestClaim(
        *implicit_expired, implicit_expired_root, origin_height,
        origin_parent_hash, origin_parent->nHeight, origin_parent_hash);
    const auto implicit_expired_inventory =
        implicit_expired->GetShadowPowClaimRecoveryInventory();
    const auto& implicit_expired_component = FindRecoveryComponent(
        implicit_expired_inventory, implicit_anchor);
    BOOST_REQUIRE_EQUAL(implicit_expired_component.nodes.size(), 1U);
    BOOST_CHECK(!implicit_expired_component.nodes.front()
                     .lineage_metadata_present);
    BOOST_CHECK(implicit_expired_component.nodes.front().disposition ==
                ShadowPowClaimMempoolDisposition::ORIGIN_EXPIRED);
    BOOST_CHECK(
        !implicit_expired_component.all_claims_zero_payment_retirable);
    const ShadowPowClaimMiningGate implicit_expired_gate =
        implicit_expired->GetShadowPowClaimMiningGate();
    BOOST_CHECK(implicit_expired_gate.action ==
                ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
    BOOST_CHECK(implicit_expired_gate.MayRefreshSameAnchor());
    BOOST_CHECK(WITH_LOCK(implicit_expired->cs_wallet,
                          return implicit_expired->IsSpent(implicit_anchor)));

    // Defense in depth for a wallet carrying pre-hotfix abandoned state: a
    // generic CREATE_NEW selector may not reuse any outpoint that wallet
    // history records as a QQSPROOF input. Only the authenticated refresh
    // branch is permitted to bypass ordinary spentness for that anchor.
    {
        LOCK(expired->cs_wallet);
        expired->mapWallet.at(expired_root->GetHash()).m_state =
            TxStateInactive{/*abandoned=*/true};
    }
    BOOST_CHECK(!WITH_LOCK(expired->cs_wallet,
                           return expired->IsSpent(expired_anchor)));
    ShadowPowClaimMiningGate create_new_gate;
    create_new_gate.action =
        ShadowPowClaimMiningGateAction::CREATE_NEW_ANCHOR;
    create_new_gate.coherent = true;
    create_new_gate.active_tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip()->GetBlockHash());
    create_new_gate.active_height = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Height());
    create_new_gate.wallet_generation =
        expired->GetDatabase().nUpdateCounter.load();
    {
        LOCK2(::cs_main, expired->cs_wallet);
        create_new_gate.candidate_state_fingerprint =
            expired->GetShadowPowClaimCandidateStateFingerprintLocked();
    }
    CCoinControl historical_control;
    historical_control.m_allow_other_inputs = false;
    historical_control.m_avoid_address_reuse = false;
    // AvailableCoins deliberately omits explicitly selected inputs for its
    // caller to fetch separately. Isolate this confirmed anchor by its unique
    // chain depth instead, so NO_ELIGIBLE_INPUT proves the history exclusion
    // rather than coin-control's selected-input convention.
    const int expired_anchor_depth = WITH_LOCK(
        expired->cs_wallet,
        return expired->GetTxDepthInMainChain(
            expired->mapWallet.at(expired_anchor.hash)));
    BOOST_REQUIRE(expired_anchor_depth > 0);
    historical_control.m_min_depth = expired_anchor_depth;
    historical_control.m_max_depth = expired_anchor_depth;
    ShadowPowClaimInput historical_selection;
    bilingual_str historical_error;
    {
        LOCK2(::cs_main, expired->cs_wallet);
        BOOST_CHECK(expired->SelectShadowPowClaimInput(
                        expired_target, payout, nullptr,
                        historical_control, historical_selection,
                        historical_error, &create_new_gate) ==
                    ShadowPowClaimInputSelectionResult::NO_ELIGIBLE_INPUT);
    }
    BOOST_CHECK(historical_selection.outpoint.IsNull());

    auto mismatch = make_wallet();
    const CTransactionRef mismatch_anchor_tx = m_coinbase_txns.at(1);
    const COutPoint mismatch_anchor{mismatch_anchor_tx->GetHash(), 0};
    const CAmount mismatch_amount = mismatch_anchor_tx->vout.at(0).nValue;
    const CScript mismatch_target = CanonicalizeLegacyStakeScript(
        mismatch_anchor_tx->vout.at(0).scriptPubKey);
    const CBlockIndex* mismatch_tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip());
    BOOST_REQUIRE(mismatch_tip);
    const uint256 wrong_parent = uint256S("1234");
    BOOST_REQUIRE(wrong_parent != mismatch_tip->GetBlockHash());
    const CTransactionRef mismatch_root = MakeExactRecoveryTestQQP3Claim(
        mismatch_anchor, mismatch_amount, /*fee=*/1000,
        mismatch_tip->nHeight + 1, wrong_parent, mismatch_target, payout,
        /*nonce=*/0);
    AddRecoveryTestClaim(
        *mismatch, mismatch_root, mismatch_tip->nHeight + 1,
        wrong_parent, mismatch_tip->nHeight,
        mismatch_tip->GetBlockHash());
    const uint256 mismatch_family =
        ComputeShadowPowClaimLineageFamilyFingerprint(
            mismatch_anchor, mismatch_amount,
            mismatch_anchor_tx->vout.at(0).scriptPubKey);
    SetRecoveryTestClaimLineageRoot(
        *mismatch, mismatch_root->GetHash(), mismatch_family);
    assert_terminal_schema_root(
        *mismatch, mismatch_anchor, mismatch_root->GetHash(),
        ShadowPowClaimMempoolDisposition::ORIGIN_MISMATCH);
}

BOOST_FIXTURE_TEST_CASE(
    mining_gate_strictly_migrates_implicit_v3_and_rejects_bad_roots,
    RecoveryQQP3TestingSetup)
{
    ChainstateManager& chainman = *Assert(m_node.chainman);
    const CBlockIndex* tip = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain().Tip());
    BOOST_REQUIRE(tip);
    const CScript payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x54)});
    const uint256 wrong_parent = uint256S("5678");
    BOOST_REQUIRE(wrong_parent != tip->GetBlockHash());
    const auto make_wallet = [&]() {
        return CreateSyncedWallet(
            *m_node.chain,
            WITH_LOCK(Assert(m_node.chainman)->GetMutex(),
                      return m_node.chainman->ActiveChain()),
            coinbaseKey);
    };
    const auto make_root = [&](CWallet& wallet, size_t anchor_index,
                               uint64_t nonce) {
        const CTransactionRef anchor_tx =
            m_coinbase_txns.at(anchor_index);
        const COutPoint anchor{anchor_tx->GetHash(), 0};
        const CAmount amount = anchor_tx->vout.at(0).nValue;
        const CScript target = CanonicalizeLegacyStakeScript(
            anchor_tx->vout.at(0).scriptPubKey);
        const CTransactionRef root = MakeExactRecoveryTestQQP3Claim(
            anchor, amount, /*fee=*/1000, tip->nHeight + 1, wrong_parent,
            target, payout, nonce);
        AddRecoveryTestClaim(
            wallet, root, tip->nHeight + 1, wrong_parent, tip->nHeight,
            tip->GetBlockHash());
        return root;
    };
    const auto assert_unsafe = [](CWallet& wallet) {
        const ShadowPowClaimMiningGate gate =
            wallet.GetShadowPowClaimMiningGate();
        BOOST_CHECK(gate.action == ShadowPowClaimMiningGateAction::UNSAFE);
        BOOST_CHECK(gate.HasUnsafeClaims());
        BOOST_CHECK(!gate.MayCreateClaim());
    };

    // Pre-hotfix QQP3 roots did not persist the new schema. A singleton may
    // migrate only when exact explicit authorship binds the proof's former
    // origin and the classifier proves that origin terminal on this branch.
    auto implicit_v3 = make_wallet();
    const CTransactionRef implicit_root =
        make_root(*implicit_v3, 2, /*nonce=*/1);
    const auto implicit_inventory =
        implicit_v3->GetShadowPowClaimRecoveryInventory();
    const auto& implicit_component = FindRecoveryComponent(
        implicit_inventory, implicit_root->vin.front().prevout);
    BOOST_REQUIRE_EQUAL(implicit_component.nodes.size(), 1U);
    BOOST_CHECK(!implicit_component.nodes.front().lineage_metadata_present);
    BOOST_CHECK(implicit_component.nodes.front().disposition ==
                ShadowPowClaimMempoolDisposition::ORIGIN_MISMATCH);
    const ShadowPowClaimMiningGate implicit_gate =
        implicit_v3->GetShadowPowClaimMiningGate();
    BOOST_CHECK(implicit_gate.action ==
                ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
    BOOST_CHECK(implicit_gate.MayRefreshSameAnchor());

    // Comment-based legacy provenance is not authenticated authorship and
    // cannot opt an implicit v3 transaction into the migration exception.
    auto comment_only = make_wallet();
    const CTransactionRef comment_root =
        make_root(*comment_only, 6, /*nonce=*/6);
    {
        LOCK(comment_only->cs_wallet);
        CWalletTx& record =
            comment_only->mapWallet.at(comment_root->GetHash());
        record.mapValue.erase(SHADOW_POW_CLAIM_AUTHORED_KEY);
        record.mapValue.erase(SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY);
        record.mapValue.erase(SHADOW_POW_CLAIM_CREATED_TIP_KEY);
        record.mapValue["comment"] = "PoW Claim";
        record.fFromMe = true;
    }
    assert_unsafe(*comment_only);

    // A schema does not authenticate a proof whose declared origin differs
    // from the durable authored height/tip. ORIGIN_MISMATCH is refresh-safe
    // only when the proof and authorship record bind the same former branch.
    auto authorship_mismatch = make_wallet();
    const CTransactionRef mismatched_root =
        make_root(*authorship_mismatch, 5, /*nonce=*/5);
    const COutPoint mismatched_anchor =
        mismatched_root->vin.front().prevout;
    const CTransactionRef mismatched_anchor_tx = m_coinbase_txns.at(5);
    const uint256 mismatched_family =
        ComputeShadowPowClaimLineageFamilyFingerprint(
            mismatched_anchor,
            mismatched_anchor_tx->vout.at(mismatched_anchor.n).nValue,
            mismatched_anchor_tx->vout.at(mismatched_anchor.n).scriptPubKey);
    SetRecoveryTestClaimLineageRoot(
        *authorship_mismatch, mismatched_root->GetHash(), mismatched_family);
    {
        LOCK(authorship_mismatch->cs_wallet);
        authorship_mismatch->mapWallet.at(mismatched_root->GetHash())
            .mapValue[SHADOW_POW_CLAIM_CREATED_TIP_KEY] =
            tip->GetBlockHash().GetHex();
    }
    assert_unsafe(*authorship_mismatch);

    // The parent key is forbidden on an ordinal-zero root, including a
    // syntactically valid all-zero hash. Its presence must invalidate the
    // complete lineage record instead of being normalized away.
    auto malformed = make_wallet();
    const CTransactionRef malformed_root = make_root(*malformed, 3, 2);
    const COutPoint malformed_anchor = malformed_root->vin.front().prevout;
    const CTransactionRef malformed_anchor_tx = m_coinbase_txns.at(3);
    const uint256 malformed_family =
        ComputeShadowPowClaimLineageFamilyFingerprint(
            malformed_anchor,
            malformed_anchor_tx->vout.at(malformed_anchor.n).nValue,
            malformed_anchor_tx->vout.at(malformed_anchor.n).scriptPubKey);
    SetRecoveryTestClaimLineageRoot(
        *malformed, malformed_root->GetHash(), malformed_family);
    {
        LOCK(malformed->cs_wallet);
        malformed->mapWallet.at(malformed_root->GetHash())
            .mapValue[SHADOW_POW_CLAIM_LINEAGE_PARENT_KEY] =
            uint256{}.GetHex();
    }
    const auto malformed_inventory =
        malformed->GetShadowPowClaimRecoveryInventory();
    const auto& malformed_component =
        FindRecoveryComponent(malformed_inventory, malformed_anchor);
    BOOST_REQUIRE_EQUAL(malformed_component.nodes.size(), 1U);
    BOOST_CHECK(malformed_component.nodes.front().lineage_metadata_present);
    BOOST_CHECK(!malformed_component.nodes.front().lineage_metadata_valid);
    assert_unsafe(*malformed);

    // Two individually valid ordinal-zero records are still ambiguous. The
    // gate must never choose a root by map order or transaction id.
    auto multiple = make_wallet();
    const CTransactionRef multiple_anchor_tx = m_coinbase_txns.at(4);
    const COutPoint multiple_anchor{multiple_anchor_tx->GetHash(), 0};
    const CAmount multiple_amount = multiple_anchor_tx->vout.at(0).nValue;
    const CScript multiple_target = CanonicalizeLegacyStakeScript(
        multiple_anchor_tx->vout.at(0).scriptPubKey);
    const uint256 multiple_family =
        ComputeShadowPowClaimLineageFamilyFingerprint(
            multiple_anchor, multiple_amount,
            multiple_anchor_tx->vout.at(0).scriptPubKey);
    const CTransactionRef first_root = MakeExactRecoveryTestQQP3Claim(
        multiple_anchor, multiple_amount, /*fee=*/1000,
        tip->nHeight + 1, wrong_parent, multiple_target, payout,
        /*nonce=*/3);
    AddRecoveryTestClaim(
        *multiple, first_root, tip->nHeight + 1, wrong_parent,
        tip->nHeight, tip->GetBlockHash());
    const CTransactionRef second_root = MakeExactRecoveryTestQQP3Claim(
        multiple_anchor, multiple_amount, /*fee=*/1001,
        tip->nHeight + 1, wrong_parent, multiple_target, payout,
        /*nonce=*/4);
    AddRecoveryTestClaim(
        *multiple, second_root, tip->nHeight + 1, wrong_parent,
        tip->nHeight, tip->GetBlockHash());
    assert_unsafe(*multiple);

    SetRecoveryTestClaimLineageRoot(
        *multiple, first_root->GetHash(), multiple_family);
    SetRecoveryTestClaimLineageRoot(
        *multiple, second_root->GetHash(), multiple_family);
    const auto multiple_inventory =
        multiple->GetShadowPowClaimRecoveryInventory();
    const auto& multiple_component =
        FindRecoveryComponent(multiple_inventory, multiple_anchor);
    BOOST_REQUIRE_EQUAL(multiple_component.nodes.size(), 2U);
    for (const auto& node : multiple_component.nodes) {
        BOOST_CHECK(node.lineage_metadata_valid);
        BOOST_CHECK_EQUAL(node.lineage_ordinal, 0U);
        BOOST_CHECK(node.lineage_root_txid == node.txid);
    }
    assert_unsafe(*multiple);
}

BOOST_FIXTURE_TEST_CASE(
    qqp4_bootstraps_one_legacy_implicit_v2_root_then_uses_schema_children,
    RecoveryQQP4TestingSetup)
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
    BOOST_REQUIRE(Params().GetConsensus().IsShadowQQP4Active(
        tip->nHeight + 1));
    const CBlockIndex* previous = WITH_LOCK(
        ::cs_main, return chainman.ActiveChain()[tip->nHeight - 1]);
    BOOST_REQUIRE(previous);

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CAmount anchor_amount = anchor_tx->vout.at(0).nValue;
    const CScript target = CanonicalizeLegacyStakeScript(
        anchor_tx->vout.at(0).scriptPubKey);
    const CScript payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x55)});
    const uint256 family = ComputeShadowPowClaimLineageFamilyFingerprint(
        anchor, anchor_amount, anchor_tx->vout.at(0).scriptPubKey);

    // This is the only metadata-absent migration root: an exact locally
    // authored QQP2 carrier that became unsupported only because QQP4 is now
    // active. It must authorize one same-anchor v4 child, never a new coin.
    const CTransactionRef legacy_root = MakeExactRecoveryTestQQP2Claim(
        anchor, anchor_amount, /*fee=*/1000, target, payout, /*nonce=*/0);
    AddRecoveryTestClaim(
        *wallet, legacy_root, tip->nHeight, previous->GetBlockHash(),
        tip->nHeight, tip->GetBlockHash());
    const auto root_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& root_component =
        FindRecoveryComponent(root_inventory, anchor);
    BOOST_REQUIRE_EQUAL(root_component.nodes.size(), 1U);
    BOOST_CHECK_EQUAL(root_component.nodes.front().proof_version, 2U);
    BOOST_CHECK(!root_component.nodes.front().lineage_metadata_present);
    BOOST_CHECK(root_component.nodes.front().disposition ==
                ShadowPowClaimMempoolDisposition::UNSUPPORTED_VERSION);

    const ShadowPowClaimMiningGate root_gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(root_gate.action ==
                ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
    BOOST_CHECK(root_gate.MayRefreshSameAnchor());
    BOOST_CHECK(root_gate.anchor == anchor);
    BOOST_CHECK(root_gate.lineage_root_txid == legacy_root->GetHash());
    BOOST_CHECK_EQUAL(root_gate.next_lineage_ordinal, 1U);

    CCoinControl control;
    control.m_allow_other_inputs = false;
    control.m_avoid_address_reuse = false;
    control.m_min_depth = 1;
    ShadowPowClaimInput selected;
    bilingual_str selection_error;
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        BOOST_CHECK(wallet->SelectShadowPowClaimInput(
                        target, payout, nullptr, control, selected,
                        selection_error, &root_gate) ==
                    ShadowPowClaimInputSelectionResult::SELECTED);
    }
    BOOST_CHECK(selected.same_anchor_refresh);
    BOOST_CHECK(selected.outpoint == anchor);
    BOOST_CHECK(selected.lineage_root_txid == legacy_root->GetHash());
    BOOST_CHECK(selected.lineage_parent_txid == legacy_root->GetHash());
    BOOST_CHECK_EQUAL(selected.lineage_ordinal, 1U);

    const uint256 wrong_parent = uint256S("9abc");
    BOOST_REQUIRE(wrong_parent != tip->GetBlockHash());
    const CTransactionRef schema_child = MakeExactRecoveryTestQQP4Claim(
        anchor, anchor_amount, /*fee=*/1001, tip->nHeight + 1,
        wrong_parent, target, payout, /*nonce=*/1);
    AddRecoveryTestClaim(
        *wallet, schema_child, tip->nHeight + 1, wrong_parent,
        tip->nHeight, tip->GetBlockHash());
    SetRecoveryTestClaimLineage(
        *wallet, schema_child->GetHash(), family, legacy_root->GetHash(),
        legacy_root->GetHash(), /*ordinal=*/1);

    const auto child_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& child_component =
        FindRecoveryComponent(child_inventory, anchor);
    BOOST_REQUIRE_EQUAL(child_component.nodes.size(), 2U);
    const auto child = std::find_if(
        child_component.nodes.begin(), child_component.nodes.end(),
        [&](const auto& node) { return node.txid == schema_child->GetHash(); });
    BOOST_REQUIRE(child != child_component.nodes.end());
    BOOST_CHECK_EQUAL(child->proof_version, 4U);
    BOOST_CHECK(child->proof_origin_bound);
    BOOST_CHECK(child->proof_input_bound);
    BOOST_CHECK(child->lineage_metadata_valid);
    BOOST_CHECK_EQUAL(child->lineage_ordinal, 1U);
    const ShadowPowClaimMiningGate child_gate =
        wallet->GetShadowPowClaimMiningGate();
    BOOST_CHECK(child_gate.action ==
                ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
    BOOST_CHECK(child_gate.MayRefreshSameAnchor());
    BOOST_CHECK_EQUAL(child_gate.family_claims, 2U);
    BOOST_CHECK(child_gate.lineage_root_txid == legacy_root->GetHash());
    BOOST_CHECK(child_gate.lineage_head_txid == schema_child->GetHash());
    BOOST_CHECK_EQUAL(child_gate.next_lineage_ordinal, 2U);
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

BOOST_AUTO_TEST_CASE(recovery_signing_authority_modes_fail_closed_without_mutation)
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

    const CTransactionRef anchor_tx = m_coinbase_txns.at(0);
    const COutPoint anchor{anchor_tx->GetHash(), 0};
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        anchor_tx->vout.at(0).scriptPubKey);
    AddRecoveryTestClaim(*wallet, claim, tip->pprev->nHeight,
                         tip->pprev->GetBlockHash(), tip->pprev->nHeight,
                         tip->pprev->GetBlockHash());

    wallet->SetBroadcastTransactions(/*broadcast=*/true);
    wallet->m_pow_mining_enabled.store(true);
    ShadowPowClaimRecoveryPolicy policy =
        DefaultShadowPowClaimRecoveryPolicy();
    policy.choice_recorded = 1;
    policy.automatic_enabled = 1;
    policy.minimum_stale_blocks = 1;
    bilingual_str policy_error;
    BOOST_REQUIRE(wallet->SetShadowPowClaimRecoveryPolicy(policy,
                                                          policy_error));

    ShadowPowClaimRecoveryRequest request;
    request.origin = ShadowPowClaimRecoveryOrigin::AUTOMATIC;
    request.selectors = {claim->GetHash()};
    const ShadowPowClaimRecoveryPlan available =
        wallet->PlanShadowPowClaimRecovery(request);
    BOOST_REQUIRE(available.complete);
    BOOST_CHECK(available.refused.empty());
    BOOST_REQUIRE_EQUAL(available.actions.size(), 1U);

    const size_t wallet_records_before = WITH_LOCK(
        wallet->cs_wallet, return wallet->mapWallet.size());
    const unsigned long mempool_size_before = Assert(m_node.mempool)->size();
    const ShadowPowClaimRecoveryUsage usage_before =
        wallet->GetShadowPowClaimRecoveryUsage(
            policy.rolling_fee_window_seconds);

    const auto assert_signing_unavailable = [&]() {
        const ShadowPowClaimRecoveryPlan refused =
            wallet->PlanShadowPowClaimRecovery(request);
        BOOST_REQUIRE(refused.complete);
        BOOST_CHECK(refused.actions.empty());
        BOOST_REQUIRE_EQUAL(refused.refused.size(), 1U);
        BOOST_CHECK_EQUAL(refused.refused.front().reason_code,
                          "wallet-signing-unavailable");

        const ShadowPowClaimRecoveryInventory inventory =
            wallet->GetShadowPowClaimRecoveryInventory();
        const auto& component = FindRecoveryComponent(inventory, anchor);
        const ShadowPowClaimRecoveryAdoptionResult adoption =
            wallet->AdoptShadowPowClaimRecoveryComponent(
                claim->GetHash(), inventory.active_tip,
                component.fingerprint);
        BOOST_CHECK(adoption.status ==
                    ShadowPowClaimRecoveryAdoptionStatus::SIGNING_UNAVAILABLE);
        BOOST_CHECK(!adoption.IsSuccess());
        BOOST_CHECK(!adoption.adopted);
        BOOST_CHECK(!adoption.durable_state_changed);
        BOOST_CHECK(!adoption.durable_state_ambiguous);

        BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet,
                                    return wallet->mapWallet.size()),
                          wallet_records_before);
        BOOST_CHECK_EQUAL(Assert(m_node.mempool)->size(),
                          mempool_size_before);
        const ShadowPowClaimRecoveryUsage usage_after =
            wallet->GetShadowPowClaimRecoveryUsage(
                policy.rolling_fee_window_seconds);
        BOOST_CHECK_EQUAL(usage_after.pending_manual,
                          usage_before.pending_manual);
        BOOST_CHECK_EQUAL(usage_after.pending_automatic,
                          usage_before.pending_automatic);
        BOOST_CHECK_EQUAL(usage_after.confirmed_manual,
                          usage_before.confirmed_manual);
        BOOST_CHECK_EQUAL(usage_after.confirmed_automatic,
                          usage_before.confirmed_automatic);
        BOOST_CHECK_EQUAL(usage_after.confirmed_resolution_fees,
                          usage_before.confirmed_resolution_fees);
        BOOST_CHECK_EQUAL(usage_after.automatic_actions_in_window,
                          usage_before.automatic_actions_in_window);
        BOOST_CHECK_EQUAL(usage_after.automatic_fee_exposure_in_window,
                          usage_before.automatic_fee_exposure_in_window);
    };

    // Canonical watch-only wallets use DISABLE_PRIVATE_KEYS. Exercise that
    // exact recovery-signing gate on a wallet with pre-existing claim history,
    // as can occur after import or migration.
    wallet->SetWalletFlag(WALLET_FLAG_DISABLE_PRIVATE_KEYS);
    BOOST_CHECK(wallet->IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS));
    BOOST_CHECK(!wallet->HasPrivateKeys());
    assert_signing_unavailable();

    // A production external-signer wallet necessarily has private keys
    // disabled. It must produce the same typed refusal and no wallet mutation.
    wallet->SetWalletFlag(WALLET_FLAG_EXTERNAL_SIGNER);
    BOOST_CHECK(wallet->IsWalletFlagSet(WALLET_FLAG_EXTERNAL_SIGNER));
    BOOST_CHECK(!wallet->HasPrivateKeys());
    assert_signing_unavailable();

    // Also exercise the explicit external-signer disjunct independently. The
    // wallet factory rejects this flag combination, but a malformed or migrated
    // record must still fail closed rather than reach signing.
    wallet->UnsetWalletFlag(WALLET_FLAG_DISABLE_PRIVATE_KEYS);
    BOOST_CHECK(wallet->HasPrivateKeys());
    BOOST_CHECK(wallet->IsWalletFlagSet(WALLET_FLAG_EXTERNAL_SIGNER));
    assert_signing_unavailable();

    wallet->UnsetWalletFlag(WALLET_FLAG_EXTERNAL_SIGNER);
    const ShadowPowClaimRecoveryPlan restored =
        wallet->PlanShadowPowClaimRecovery(request);
    BOOST_REQUIRE(restored.complete);
    BOOST_CHECK(restored.refused.empty());
    BOOST_REQUIRE_EQUAL(restored.actions.size(), 1U);
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet,
                                return wallet->mapWallet.size()),
                      wallet_records_before);
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
        BOOST_TEST_MESSAGE("preview refusal: " << first.refused.front().reason_code << " " << first.refused.front().detail);
        const auto debug_inventory =
            wallet->GetShadowPowClaimRecoveryInventory();
        const auto& debug_component =
            FindRecoveryComponent(debug_inventory, anchor);
        for (const auto& node : debug_component.nodes) {
            BOOST_TEST_MESSAGE("node wallet=" << node.wallet_authored << " shape=" << node.expected_shape << " disposition=" << static_cast<int>(node.disposition));
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

BOOST_AUTO_TEST_CASE(recovery_respects_user_coin_lock_through_atomic_broadcast_reservation)
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

    ShadowPowClaimRecoveryRequest request;
    request.selectors = {claim->GetHash()};
    const ShadowPowClaimRecoveryPlan unlocked_preview =
        wallet->PlanShadowPowClaimRecovery(request);
    BOOST_REQUIRE(unlocked_preview.complete);
    BOOST_REQUIRE_EQUAL(unlocked_preview.actions.size(), 1U);
    BOOST_CHECK(unlocked_preview.refused.empty());
    const size_t wallet_records_before = WITH_LOCK(
        wallet->cs_wallet, return wallet->mapWallet.size());

    std::string lock_error;
    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE(wallet->UpdateLockedCoins(
            {anchor}, /*lock=*/true, /*persistent=*/false, &lock_error));
    }
    const ShadowPowClaimRecoveryInventory locked_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const ShadowPowClaimRecoveryComponent& locked_component =
        FindRecoveryComponent(locked_inventory, anchor);
    BOOST_CHECK(locked_component.anchor_user_locked);
    const ShadowPowClaimRecoveryPlan locked_preview =
        wallet->PlanShadowPowClaimRecovery(request);
    BOOST_REQUIRE(locked_preview.complete);
    BOOST_CHECK(locked_preview.actions.empty());
    BOOST_REQUIRE_EQUAL(locked_preview.refused.size(), 1U);
    BOOST_CHECK_EQUAL(locked_preview.refused.front().reason_code,
                      "anchor-user-locked");
    BOOST_CHECK(locked_preview.plan_id != unlocked_preview.plan_id);

    // A lock placed after preview invalidates that exact consent before any
    // signing or persistence can occur.
    ShadowPowClaimRecoveryRequest stale_sign = request;
    stale_sign.mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
    stale_sign.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
    stale_sign.acknowledge_fee_and_conflict_risk = true;
    stale_sign.expected_plan_id = unlocked_preview.plan_id;
    const ShadowPowClaimRecoveryResult stale =
        wallet->ResolveShadowPowClaims(stale_sign);
    BOOST_CHECK(!stale.success);
    BOOST_CHECK(stale.stale_plan);
    BOOST_CHECK_EQUAL(WITH_LOCK(wallet->cs_wallet,
                                return wallet->mapWallet.size()),
                      wallet_records_before);

    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE(wallet->UpdateLockedCoins(
            {anchor}, /*lock=*/false, /*persistent=*/true, &lock_error));
    }
    const ShadowPowClaimRecoveryPlan sign_preview =
        wallet->PlanShadowPowClaimRecovery(request);
    BOOST_REQUIRE_EQUAL(sign_preview.actions.size(), 1U);
    ShadowPowClaimRecoveryRequest sign = request;
    sign.mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
    sign.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
    sign.acknowledge_fee_and_conflict_risk = true;
    sign.expected_plan_id = sign_preview.plan_id;
    const ShadowPowClaimRecoveryResult signed_result =
        wallet->ResolveShadowPowClaims(sign);
    BOOST_REQUIRE_MESSAGE(signed_result.success, signed_result.error);
    BOOST_REQUIRE_EQUAL(signed_result.plan.actions.size(), 1U);
    const CTransactionRef exact =
        signed_result.plan.actions.front().transaction;
    BOOST_REQUIRE(exact);

    // Persistence releases cs_wallet before networking. The guarded in-flight
    // reservation is therefore the linearization point for a concurrent
    // lockunspent: a held exact anchor wins and no bytes enter broadcast.
    ShadowPowClaimRecoveryBroadcastGuard broadcast_guard;
    broadcast_guard.expected_wallet_generation =
        wallet->GetDatabase().nUpdateCounter.load();
    broadcast_guard.expected_wallet_tip = tip->GetBlockHash();
    broadcast_guard.expected_unlocked_input = anchor;
    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE(wallet->UpdateLockedCoins(
            {anchor}, /*lock=*/true, /*persistent=*/false, &lock_error));
    }
    std::string guarded_error;
    BOOST_CHECK(!wallet->SubmitTxMemoryPoolAndRelay(
        exact->GetHash(), guarded_error, /*relay=*/true,
        &broadcast_guard));
    BOOST_CHECK_EQUAL(guarded_error, "recovery-anchor-user-locked");
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet,
                          return wallet->m_inflight_wallet_broadcasts.empty()));
    {
        LOCK(wallet->cs_wallet);
        BOOST_REQUIRE(wallet->UpdateLockedCoins(
            {anchor}, /*lock=*/false, /*persistent=*/true, &lock_error));
    }

    // An indeterminate persistent lock-add is both durable-authority
    // ambiguity and an immediate conservative in-memory restriction. This
    // also prevents ordinary wallet selection from spending through a lock
    // that may already have committed despite the reported failure.
    MockableDatabase& database = GetMockableDatabase(*wallet);
    database.m_fail_commit = true;
    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK(!wallet->UpdateLockedCoins(
            {anchor}, /*lock=*/true, /*persistent=*/true, &lock_error));
        BOOST_CHECK(wallet->IsLockedCoinsDatabaseAmbiguous());
        BOOST_CHECK(wallet->IsLockedCoin(anchor));
    }
    database.m_fail_commit = false;
    const ShadowPowClaimRecoveryPlan ambiguous_preview =
        wallet->PlanShadowPowClaimRecovery(request);
    BOOST_CHECK(ambiguous_preview.actions.empty());
    BOOST_REQUIRE_EQUAL(ambiguous_preview.refused.size(), 1U);
    BOOST_CHECK_EQUAL(ambiguous_preview.refused.front().reason_code,
                      "database-outcome-ambiguous");

    broadcast_guard.expected_wallet_generation =
        wallet->GetDatabase().nUpdateCounter.load();
    guarded_error.clear();
    BOOST_CHECK(!wallet->SubmitTxMemoryPoolAndRelay(
        exact->GetHash(), guarded_error, /*relay=*/true,
        &broadcast_guard));
    BOOST_CHECK_EQUAL(guarded_error,
                      "recovery-database-outcome-ambiguous");
    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet,
                          return wallet->m_inflight_wallet_broadcasts.empty()));
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
        BOOST_TEST_MESSAGE("sign preview refusal: " << preview.refused.front().reason_code << " " << preview.refused.front().detail);
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
            wallet->mapWallet.at(exact->GetHash()).mapValue.at(SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY),
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
            wallet->mapWallet.at(exact->GetHash()).mapValue.at(SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY),
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

    const ShadowPowClaimMiningGate guarded_gate =
        wallet->GetShadowPowClaimMiningGate();
    ShadowPowClaimRecoveryBroadcastGuard candidate_guard;
    candidate_guard.expected_wallet_generation =
        guarded_gate.wallet_generation;
    candidate_guard.expected_wallet_tip = guarded_gate.active_tip;
    candidate_guard.expected_candidate_state_fingerprint =
        guarded_gate.candidate_state_fingerprint == uint256::ONE
        ? uint256S("02")
        : uint256::ONE;
    guarded_error.clear();
    BOOST_CHECK(!wallet->SubmitTxMemoryPoolAndRelay(
        exact->GetHash(), guarded_error, /*relay=*/true,
        &candidate_guard));
    BOOST_CHECK_EQUAL(guarded_error,
                      "recovery-candidate-state-changed");

    ShadowPowClaimRecoveryBroadcastGuard authority_guard;
    authority_guard.expected_wallet_generation =
        guarded_gate.wallet_generation;
    authority_guard.expected_wallet_tip = guarded_gate.active_tip;
    authority_guard.expected_pow_mining_authority_generation =
        wallet->m_pow_wallet_authority_generation.load(
            std::memory_order_acquire) + 1;
    guarded_error.clear();
    BOOST_CHECK(!wallet->SubmitTxMemoryPoolAndRelay(
        exact->GetHash(), guarded_error, /*relay=*/true,
        &authority_guard));
    BOOST_CHECK_EQUAL(guarded_error,
                      "recovery-pow-miner-authority-changed");

    ShadowPowClaimRecoveryBroadcastGuard disabled_guard;
    disabled_guard.expected_wallet_generation =
        guarded_gate.wallet_generation;
    disabled_guard.expected_wallet_tip = guarded_gate.active_tip;
    disabled_guard.require_pow_mining_enabled = true;
    guarded_error.clear();
    BOOST_CHECK(!wallet->SubmitTxMemoryPoolAndRelay(
        exact->GetHash(), guarded_error, /*relay=*/true,
        &disabled_guard));
    BOOST_CHECK_EQUAL(guarded_error, "recovery-pow-miner-disabled");

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

BOOST_AUTO_TEST_CASE(managed_resolution_relay_revocation_is_durable_restriction_only)
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

    ShadowPowClaimRecoveryRequest request;
    request.selectors = {claim->GetHash()};
    const ShadowPowClaimRecoveryPlan initial_preview =
        wallet->PlanShadowPowClaimRecovery(request);
    BOOST_REQUIRE_EQUAL(initial_preview.actions.size(), 1U);
    ShadowPowClaimRecoveryRequest sign = request;
    sign.mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
    sign.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
    sign.acknowledge_fee_and_conflict_risk = true;
    sign.expected_plan_id = initial_preview.plan_id;
    const ShadowPowClaimRecoveryResult signed_result =
        wallet->ResolveShadowPowClaims(sign);
    BOOST_REQUIRE_MESSAGE(signed_result.success, signed_result.error);
    BOOST_REQUIRE_EQUAL(signed_result.plan.actions.size(), 1U);
    const CTransactionRef exact =
        signed_result.plan.actions.front().transaction;
    BOOST_REQUIRE(exact);
    const uint256 resolution_txid = exact->GetHash();

    const MockableData signed_records =
        GetMockableDatabase(*wallet).m_records;
    auto load = [&](const MockableData& records) {
        auto loaded = std::make_unique<CWallet>(
            m_node.chain.get(), "", CreateMockableWalletDatabase(records));
        BOOST_REQUIRE_EQUAL(loaded->LoadWallet(), DBErrors::LOAD_OK);
        {
            LOCK(loaded->cs_wallet);
            loaded->SetLastBlockProcessed(tip->nHeight,
                                          tip->GetBlockHash());
        }
        return loaded;
    };

    // SIGN_ONLY survives restart as a non-authorized draft. Revocation is
    // valid while staking-only/otherwise non-signing and changes neither the
    // exact bytes nor the shared anchor reservation.
    auto restarted_draft = load(signed_records);
    const ShadowPowClaimRecoveryPlan pre_revocation_plan =
        restarted_draft->PlanShadowPowClaimRecovery(request);
    BOOST_REQUIRE_EQUAL(pre_revocation_plan.actions.size(), 1U);
    BOOST_CHECK(!pre_revocation_plan.actions.front().relay_authorized);
    BOOST_CHECK(!pre_revocation_plan.actions.front().relay_revoked);

    const auto missing =
        restarted_draft->RevokeManagedShadowPowResolutionRelayAuthority(
            uint256::ONE);
    BOOST_CHECK(!missing.success);
    BOOST_CHECK(missing.status ==
                ShadowPowClaimResolutionRevocationStatus::NOT_FOUND);
    const auto nonmanaged =
        restarted_draft->RevokeManagedShadowPowResolutionRelayAuthority(
            claim->GetHash());
    BOOST_CHECK(!nonmanaged.success);
    BOOST_CHECK(nonmanaged.status ==
                ShadowPowClaimResolutionRevocationStatus::NOT_MANAGED);

    auto malformed = load(signed_records);
    {
        LOCK(malformed->cs_wallet);
        malformed->mapWallet.at(resolution_txid).mapValue[
            SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY] = "invalid";
    }
    const auto malformed_result =
        malformed->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_CHECK(!malformed_result.success);
    BOOST_CHECK(malformed_result.status ==
                ShadowPowClaimResolutionRevocationStatus::INVALID_METADATA);

    auto unreserved = load(signed_records);
    {
        LOCK(unreserved->cs_wallet);
        unreserved->mapWallet.at(claim->GetHash()).m_state =
            TxStateInactive{/*abandoned=*/true};
        unreserved->mapWallet.at(resolution_txid).m_state =
            TxStateInactive{/*abandoned=*/true};
    }
    const auto unreserved_result =
        unreserved->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_CHECK(!unreserved_result.success);
    BOOST_CHECK(unreserved_result.status ==
                ShadowPowClaimResolutionRevocationStatus::ANCHOR_NOT_RESERVED);
    BOOST_CHECK_EQUAL(unreserved_result.anchor_reserved.value(), false);
    BOOST_CHECK_EQUAL(
        unreserved_result.normal_coin_selection_enabled.value(), true);

    {
        LOCK(restarted_draft->cs_wallet);
        restarted_draft->m_wallet_unlock_staking_only = true;
    }
    const ShadowPowClaimResolutionRevocationResult revoked_draft =
        restarted_draft->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_REQUIRE_MESSAGE(revoked_draft.success, revoked_draft.detail);
    BOOST_CHECK(revoked_draft.status ==
                ShadowPowClaimResolutionRevocationStatus::SUCCESS);
    BOOST_CHECK_EQUAL(revoked_draft.durable_state_changed.value(), true);
    BOOST_CHECK_EQUAL(
        revoked_draft.relay_authority_was_active.value(), false);
    BOOST_CHECK_EQUAL(revoked_draft.relay_authority_revoked.value(), true);
    BOOST_CHECK_EQUAL(revoked_draft.locally_cancelled.value(), true);
    BOOST_CHECK_EQUAL(revoked_draft.in_mempool.value(), false);
    BOOST_CHECK_EQUAL(revoked_draft.broadcast_in_flight.value(), false);
    BOOST_CHECK_EQUAL(revoked_draft.may_still_confirm.value(), true);
    BOOST_CHECK(revoked_draft.anchor == anchor);
    BOOST_CHECK_EQUAL(revoked_draft.anchor_reserved.value(), true);
    BOOST_CHECK_EQUAL(
        revoked_draft.normal_coin_selection_enabled.value(), false);
    {
        LOCK(restarted_draft->cs_wallet);
        restarted_draft->m_wallet_unlock_staking_only = false;
        const CWalletTx& stored =
            restarted_draft->mapWallet.at(resolution_txid);
        BOOST_CHECK(stored.tx->GetWitnessHash() == exact->GetWitnessHash());
        BOOST_CHECK_EQUAL(stored.mapValue.at(
                              SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY),
                          "0");
        BOOST_CHECK_EQUAL(stored.mapValue.at(
                              SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY),
                          "1");
        BOOST_CHECK(restarted_draft->IsSpent(anchor));
    }

    // A chainless/offline wallet can still narrow its own durable relay
    // authority. It must omit observations that require node chain/mempool
    // state instead of dereferencing a missing interface or reporting a
    // fabricated default.
    auto chainless = std::make_unique<CWallet>(
        /*chain=*/nullptr, "", CreateMockableWalletDatabase(signed_records));
    BOOST_REQUIRE_EQUAL(chainless->LoadWallet(), DBErrors::LOAD_OK);
    const ShadowPowClaimResolutionRevocationResult chainless_revoked =
        chainless->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_REQUIRE_MESSAGE(chainless_revoked.success,
                          chainless_revoked.detail);
    BOOST_CHECK(chainless_revoked.status ==
                ShadowPowClaimResolutionRevocationStatus::SUCCESS);
    BOOST_CHECK_EQUAL(chainless_revoked.relay_authority_revoked.value(), true);
    BOOST_CHECK_EQUAL(chainless_revoked.anchor_reserved.value(), true);
    BOOST_CHECK(!chainless_revoked.in_mempool.has_value());
    BOOST_CHECK(!chainless_revoked.mining_gate_available);
    BOOST_CHECK_EQUAL(WITH_LOCK(
        chainless->cs_wallet,
        return chainless->mapWallet.at(resolution_txid).mapValue.at(
            SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY)), "1");

    // The tombstone is restart durable, remains authenticated inventory, and
    // blocks both scheduler retry and generic local-submit promotion.
    auto cancelled = load(GetMockableDatabase(*restarted_draft).m_records);
    const ShadowPowClaimRecoveryInventory cancelled_inventory =
        cancelled->GetShadowPowClaimRecoveryInventory();
    const ShadowPowClaimRecoveryComponent& cancelled_component =
        FindRecoveryComponent(cancelled_inventory, anchor);
    const auto cancelled_node = std::find_if(
        cancelled_component.nodes.begin(), cancelled_component.nodes.end(),
        [&](const ShadowPowClaimRecoveryNode& node) {
            return node.txid == resolution_txid;
        });
    BOOST_REQUIRE(cancelled_node != cancelled_component.nodes.end());
    BOOST_CHECK(cancelled_node->resolution_metadata_valid);
    BOOST_CHECK(!cancelled_node->resolution_relay_authorized);
    BOOST_CHECK(cancelled_node->resolution_relay_revoked);
    cancelled->SetBroadcastTransactions(/*broadcast=*/true);
    cancelled->MaybeAutoResolveShadowPowClaims();
    BOOST_CHECK(!m_node.chain->isInMempool(resolution_txid));
    cancelled->transactionSubmittedByRpc(exact);
    {
        LOCK(cancelled->cs_wallet);
        BOOST_CHECK_EQUAL(cancelled->mapWallet.at(resolution_txid).mapValue.at(
                              SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY),
                          "0");
        BOOST_CHECK_EQUAL(cancelled->mapWallet.at(resolution_txid).mapValue.at(
                              SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY),
                          "1");
    }
    std::string relay_error;
    BOOST_CHECK(!cancelled->SubmitTxMemoryPoolAndRelay(
        resolution_txid, relay_error, /*relay=*/true));
    BOOST_CHECK_EQUAL(relay_error, "recovery-relay-authority-revoked");

    // Revocation consumes the prior wallet snapshot. Reauthorization with
    // that old exact plan fails closed; a fresh plan plus explicit manual
    // consent clears both flags atomically. Wallet broadcasting is disabled
    // so this test can inspect authorized-but-absent bytes deterministically.
    ShadowPowClaimRecoveryRequest stale_commit = request;
    stale_commit.mode =
        ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST;
    stale_commit.execution_authority =
        ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
    stale_commit.acknowledge_fee_and_conflict_risk = true;
    stale_commit.expected_plan_id = pre_revocation_plan.plan_id;
    const ShadowPowClaimRecoveryResult stale =
        cancelled->ResolveShadowPowClaims(stale_commit);
    BOOST_CHECK(!stale.success);
    BOOST_CHECK(stale.stale_plan);
    {
        LOCK(cancelled->cs_wallet);
        BOOST_CHECK_EQUAL(cancelled->mapWallet.at(resolution_txid).mapValue.at(
                              SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY),
                          "1");
    }

    const ShadowPowClaimRecoveryPlan fresh =
        cancelled->PlanShadowPowClaimRecovery(request);
    BOOST_REQUIRE_EQUAL(fresh.actions.size(), 1U);
    BOOST_CHECK(fresh.actions.front().relay_revoked);
    ShadowPowClaimRecoveryRequest reauthorize = stale_commit;
    reauthorize.expected_plan_id = fresh.plan_id;
    cancelled->SetBroadcastTransactions(/*broadcast=*/false);
    const ShadowPowClaimRecoveryResult reauthorized =
        cancelled->ResolveShadowPowClaims(reauthorize);
    BOOST_CHECK(!reauthorized.success);
    BOOST_CHECK(reauthorized.durable_state_changed);
    BOOST_CHECK_EQUAL(reauthorized.relay_authority_granted, 1U);
    {
        LOCK(cancelled->cs_wallet);
        BOOST_CHECK_EQUAL(cancelled->mapWallet.at(resolution_txid).mapValue.at(
                              SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY),
                          "1");
        BOOST_CHECK_EQUAL(cancelled->mapWallet.at(resolution_txid).mapValue.at(
                              SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY),
                          "0");
        BOOST_CHECK(cancelled->IsSpent(anchor));
    }

    // Revocation cannot remove bytes already in the local mempool. Its
    // receipt says so, but still cancels every later wallet-controlled retry.
    {
        LOCK2(::cs_main, m_node.mempool->cs);
        LockPoints lock_points;
        m_node.mempool->addUnchecked(CTxMemPoolEntry(
            exact, signed_result.plan.actions.front().fee,
            /*time=*/0, /*entry_height=*/tip->nHeight,
            /*entry_sequence=*/0, /*spends_coinbase=*/false,
            /*sigops_cost=*/4, lock_points));
    }
    const ShadowPowClaimResolutionRevocationResult revoked_live =
        cancelled->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_REQUIRE_MESSAGE(revoked_live.success, revoked_live.detail);
    BOOST_CHECK_EQUAL(
        revoked_live.relay_authority_was_active.value(), true);
    BOOST_CHECK_EQUAL(revoked_live.in_mempool.value(), true);
    BOOST_CHECK_EQUAL(revoked_live.may_still_confirm.value(), true);
    BOOST_CHECK(!WITH_LOCK(cancelled->cs_wallet,
                           return cancelled->mapWallet.at(
                               resolution_txid).InMempool()));
    cancelled->transactionAddedToMempool(exact);
    BOOST_CHECK(WITH_LOCK(cancelled->cs_wallet,
                          return cancelled->mapWallet.at(
                              resolution_txid).InMempool()));
    cancelled->transactionSubmittedByRpc(exact);
    BOOST_CHECK_EQUAL(WITH_LOCK(
        cancelled->cs_wallet,
        return cancelled->mapWallet.at(resolution_txid).mapValue.at(
            SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY)), "0");
    WITH_LOCK(
        m_node.mempool->cs,
        m_node.mempool->removeRecursive(
            *exact, MemPoolRemovalReason::EXPIRY));
    cancelled->transactionRemovedFromMempool(
        exact, MemPoolRemovalReason::EXPIRY);
    const ShadowPowClaimResolutionRevocationResult idempotent =
        cancelled->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_CHECK(idempotent.success);
    BOOST_CHECK(idempotent.status ==
                ShadowPowClaimResolutionRevocationStatus::ALREADY_REVOKED);
    BOOST_CHECK_EQUAL(idempotent.durable_state_changed.value(), false);

    // Reauthorize once more and snapshot that state for race and database
    // fault paths.
    const ShadowPowClaimRecoveryPlan fresh_again =
        cancelled->PlanShadowPowClaimRecovery(request);
    reauthorize.expected_plan_id = fresh_again.plan_id;
    const ShadowPowClaimRecoveryResult reauthorized_again =
        cancelled->ResolveShadowPowClaims(reauthorize);
    BOOST_CHECK(!reauthorized_again.success);
    BOOST_CHECK(reauthorized_again.durable_state_changed);
    const ShadowPowClaimMiningGateAction pre_in_flight_gate =
        cancelled->GetShadowPowClaimMiningGate().action;
    {
        LOCK(cancelled->cs_wallet);
        cancelled->m_inflight_wallet_broadcasts.insert(resolution_txid);
    }
    const ShadowPowClaimResolutionRevocationResult in_flight =
        cancelled->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_CHECK(!in_flight.success);
    BOOST_CHECK(in_flight.status ==
                ShadowPowClaimResolutionRevocationStatus::BROADCAST_IN_FLIGHT);
    BOOST_CHECK_EQUAL(in_flight.broadcast_in_flight.value(), true);
    BOOST_CHECK_EQUAL(in_flight.durable_state_changed.value(), false);
    BOOST_CHECK(in_flight.mining_gate_action == pre_in_flight_gate);
    {
        LOCK(cancelled->cs_wallet);
        cancelled->m_inflight_wallet_broadcasts.erase(resolution_txid);
        BOOST_CHECK_EQUAL(cancelled->mapWallet.at(resolution_txid).mapValue.at(
                              SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY),
                          "1");
        BOOST_CHECK_EQUAL(cancelled->mapWallet.at(resolution_txid).mapValue.at(
                              SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY),
                          "0");
    }
    const MockableData authorized_records =
        GetMockableDatabase(*cancelled).m_records;

    auto coin_lock_ambiguous = load(authorized_records);
    MockableDatabase& coin_lock_database =
        GetMockableDatabase(*coin_lock_ambiguous);
    coin_lock_database.m_fail_commit = true;
    std::string coin_lock_error;
    {
        LOCK(coin_lock_ambiguous->cs_wallet);
        BOOST_CHECK(!coin_lock_ambiguous->UpdateLockedCoins(
            {anchor}, /*lock=*/true, /*persistent=*/true,
            &coin_lock_error));
        BOOST_CHECK(coin_lock_ambiguous->IsLockedCoinsDatabaseAmbiguous());
    }
    coin_lock_database.m_fail_commit = false;
    const auto coin_lock_ambiguous_result =
        coin_lock_ambiguous->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_CHECK(!coin_lock_ambiguous_result.success);
    BOOST_CHECK(coin_lock_ambiguous_result.status ==
                ShadowPowClaimResolutionRevocationStatus::DATABASE_OUTCOME_AMBIGUOUS);
    BOOST_CHECK(coin_lock_ambiguous_result.durable_state_ambiguous);

    auto coin_lock_ambiguous_draft = load(signed_records);
    MockableDatabase& coin_lock_draft_database =
        GetMockableDatabase(*coin_lock_ambiguous_draft);
    coin_lock_draft_database.m_fail_commit = true;
    {
        LOCK(coin_lock_ambiguous_draft->cs_wallet);
        BOOST_CHECK(!coin_lock_ambiguous_draft->UpdateLockedCoins(
            {anchor}, /*lock=*/true, /*persistent=*/true,
            &coin_lock_error));
        BOOST_CHECK(
            coin_lock_ambiguous_draft->IsLockedCoinsDatabaseAmbiguous());
    }
    coin_lock_draft_database.m_fail_commit = false;
    const uint64_t coin_lock_generation =
        coin_lock_ambiguous_draft->GetDatabase().nUpdateCounter.load();
    coin_lock_ambiguous_draft->transactionSubmittedByRpc(exact);
    BOOST_CHECK_EQUAL(
        coin_lock_ambiguous_draft->GetDatabase().nUpdateCounter.load(),
        coin_lock_generation);
    {
        LOCK(coin_lock_ambiguous_draft->cs_wallet);
        const auto& record =
            coin_lock_ambiguous_draft->mapWallet.at(resolution_txid);
        BOOST_CHECK_EQUAL(record.mapValue.at(
                              SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY),
                          "0");
        BOOST_CHECK_EQUAL(record.mapValue.at(
                              SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY),
                          "0");
    }

    auto begin_failure = load(authorized_records);
    GetMockableDatabase(*begin_failure).m_fail_begin = true;
    const auto begin_result =
        begin_failure->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_CHECK(!begin_result.success);
    BOOST_CHECK(begin_result.status ==
                ShadowPowClaimResolutionRevocationStatus::DATABASE_FAILURE);
    BOOST_CHECK(!begin_result.durable_state_ambiguous);
    BOOST_CHECK_EQUAL(WITH_LOCK(
        begin_failure->cs_wallet,
        return begin_failure->mapWallet.at(resolution_txid).mapValue.at(
            SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY)), "1");

    auto write_failure = load(authorized_records);
    GetMockableDatabase(*write_failure).m_fail_write_at = 0;
    const auto write_result =
        write_failure->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_CHECK(!write_result.success);
    BOOST_CHECK(write_result.status ==
                ShadowPowClaimResolutionRevocationStatus::DATABASE_FAILURE);
    BOOST_CHECK(!write_result.durable_state_ambiguous);
    BOOST_CHECK_EQUAL(WITH_LOCK(
        write_failure->cs_wallet,
        return write_failure->mapWallet.at(resolution_txid).mapValue.at(
            SHADOW_POW_RESOLUTION_RELAY_REVOKED_KEY)), "0");

    auto commit_failure = load(authorized_records);
    GetMockableDatabase(*commit_failure).m_fail_commit = true;
    const auto commit_result =
        commit_failure->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_CHECK(!commit_result.success);
    BOOST_CHECK(commit_result.status ==
                ShadowPowClaimResolutionRevocationStatus::DATABASE_OUTCOME_AMBIGUOUS);
    BOOST_CHECK(commit_result.durable_state_ambiguous);
    BOOST_CHECK(!commit_result.durable_state_changed.has_value());
    BOOST_CHECK(commit_result.relay_authority_was_active.has_value());
    BOOST_CHECK(!commit_result.relay_authority_revoked.has_value());
    BOOST_CHECK(!commit_result.locally_cancelled.has_value());
    BOOST_CHECK(commit_failure->IsShadowPowClaimRecoveryDatabaseAmbiguous());
    BOOST_CHECK_EQUAL(WITH_LOCK(
        commit_failure->cs_wallet,
        return commit_failure->mapWallet.at(resolution_txid).mapValue.at(
            SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY)), "1");
    const auto ambiguity_latched =
        commit_failure->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    BOOST_CHECK(!ambiguity_latched.success);
    BOOST_CHECK(ambiguity_latched.status ==
                ShadowPowClaimResolutionRevocationStatus::DATABASE_OUTCOME_AMBIGUOUS);
    BOOST_CHECK(ambiguity_latched.durable_state_ambiguous);
    BOOST_CHECK(!ambiguity_latched.relay_authority_was_active.has_value());
    BOOST_CHECK(!ambiguity_latched.relay_authority_revoked.has_value());
    BOOST_CHECK(!ambiguity_latched.locally_cancelled.has_value());
    BOOST_CHECK(!ambiguity_latched.in_mempool.has_value());
    BOOST_CHECK(!ambiguity_latched.anchor_reserved.has_value());
    commit_failure->SetBroadcastTransactions(/*broadcast=*/true);
    std::string ambiguous_relay_error;
    BOOST_CHECK(!commit_failure->SubmitTxMemoryPoolAndRelay(
        resolution_txid, ambiguous_relay_error, /*relay=*/true));
    BOOST_CHECK_EQUAL(ambiguous_relay_error,
                      "recovery-database-outcome-ambiguous");
    BOOST_CHECK(WITH_LOCK(
        commit_failure->cs_wallet,
        return commit_failure->m_inflight_wallet_broadcasts.empty()));
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
    // Their peer-retained bytes keep the input reserved.
    BOOST_CHECK(!WITH_LOCK(
        wallet->cs_wallet,
        return wallet->mapWallet.at(claim->GetHash()).isAbandoned()));

    ShadowPowClaimRecoveryRequest request;
    request.selectors = {claim->GetHash()};
    const ShadowPowClaimRecoveryPlan preview =
        wallet->PlanShadowPowClaimRecovery(request);
    if (!preview.refused.empty()) {
        BOOST_TEST_MESSAGE("stale preview refusal: " << preview.refused.front().reason_code << " " << preview.refused.front().detail);
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

BOOST_FIXTURE_TEST_CASE(origin_expiry_preserves_block_valid_claim_input,
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
    const unsigned int script_verify_flags =
        wallet->GetActiveScriptVerifyFlags();
    {
        LOCK(wallet->cs_wallet);
        std::map<int, bilingual_str> input_errors;
        BOOST_REQUIRE(wallet->SignTransactionWithScriptVerifyFlags(
            claim_mutable, input_errors, script_verify_flags));
    }
    const CTransactionRef claim =
        MakeTransactionRef(std::move(claim_mutable));
    AddRecoveryTestClaim(*wallet, claim, origin_parent->nHeight,
                         origin_parent->GetBlockHash(),
                         origin_parent->nHeight,
                         origin_parent->GetBlockHash());

    BOOST_CHECK(WITH_LOCK(wallet->cs_wallet,
                          return wallet->IsSpent(anchor)));

    for (unsigned int age = 1;
         age <= SHADOW_POW_LATE_ORIGIN_WINDOW + 1; ++age) {
        CreateAndProcessBlock(
            {}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
        SyncWithValidationInterfaceQueue();
    }
    SyncRecoveryTestWalletTip(*wallet, chainman);

    ShadowPowClaimMempoolDisposition disposition{
        ShadowPowClaimMempoolDisposition::LOCAL_STATE_ERROR};
    std::string reject_reason;
    ShadowProofValidationResult validation;
    {
        LOCK(::cs_main);
        validation = CheckShadowPowClaimForMempoolDetailed(
            *claim, chainman.ActiveChain().Tip(),
            chainman.ActiveChainstate().CoinsTip(),
            /*gold_rush_active=*/true, reject_reason, &disposition);
    }
    BOOST_CHECK(validation == ShadowProofValidationResult::INVALID);
    BOOST_CHECK(disposition ==
                ShadowPowClaimMempoolDisposition::ORIGIN_EXPIRED);
    {
        LOCK(::cs_main);
        const MempoolAcceptResult mempool_result =
            chainman.ProcessTransaction(claim, /*test_accept=*/true);
        BOOST_CHECK(mempool_result.m_result_type ==
                    MempoolAcceptResult::ResultType::INVALID);
        BOOST_CHECK_EQUAL(mempool_result.m_state.GetRejectReason(),
                          "shadow-proof-origin-expired");
    }
    BOOST_CHECK(!m_node.chain->isInMempool(claim->GetHash()));

    const ShadowPowClaimRecoveryInventory expired_inventory =
        wallet->GetShadowPowClaimRecoveryInventory();
    const auto& expired_component =
        FindRecoveryComponent(expired_inventory, anchor);
    BOOST_CHECK(!expired_component.all_claims_zero_payment_retirable);
    BOOST_CHECK(!expired_component.all_claims_expired_locally_retired);
    BOOST_CHECK(expired_component.state ==
                ShadowPowClaimRecoveryState::TERMINAL_ON_PINNED_TIP);
    BOOST_CHECK_EQUAL(expired_inventory.retired_claim_objects, 0U);
    BOOST_CHECK_EQUAL(expired_inventory.retired_components, 0U);

    ShadowPowClaimRecoveryRequest preview_request;
    preview_request.selectors = {claim->GetHash()};
    const ShadowPowClaimRecoveryPlan recovery_preview =
        wallet->PlanShadowPowClaimRecovery(preview_request);
    BOOST_REQUIRE_EQUAL(recovery_preview.actions.size(), 1U);
    BOOST_CHECK(recovery_preview.refused.empty());
    BOOST_CHECK(recovery_preview.total_fee > 0);

    {
        LOCK(wallet->cs_wallet);
        const CWalletTx& retained = wallet->mapWallet.at(claim->GetHash());
        BOOST_CHECK(!retained.isAbandoned());
        BOOST_CHECK(!HasRetirementMarker(retained));
        BOOST_CHECK(wallet->IsSpent(anchor));
    }
    BOOST_CHECK(wallet->CountQuarantinedShadowPowClaims() > 0);

    // Origin expiry is a mempool/reward-eligibility boundary, not a base
    // transaction consensus rule. A block producer retaining the signed bytes
    // can still include them during Gold Rush, so the wallet must not reuse
    // their confirmed input merely because policy rejects mempool admission.
    CMutableTransaction block_claim{*claim};
    CBlock claim_block = CreateBlock(
        {block_claim}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()),
        chainman.ActiveChainstate());
    bool new_block{false};
    BOOST_REQUIRE(chainman.ProcessNewBlock(
        std::make_shared<const CBlock>(claim_block),
        /*force_processing=*/true, /*min_pow_checked=*/true, &new_block));
    BOOST_CHECK(new_block);
    BOOST_CHECK(WITH_LOCK(
        ::cs_main,
        return chainman.ActiveChain().Tip()->GetBlockHash() ==
            claim_block.GetHash()));
    SyncWithValidationInterfaceQueue();
    SyncRecoveryTestWalletTip(*wallet, chainman);

    {
        LOCK(wallet->cs_wallet);
        BOOST_CHECK(wallet->mapWallet.at(claim->GetHash()).isConfirmed());
        BOOST_CHECK(wallet->IsSpent(anchor));
    }
}

BOOST_FIXTURE_TEST_CASE(legacy_expired_retirement_reopens_fail_closed,
                        RecoveryQQP3TestingSetup)
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
    const CTransactionRef claim = MakeRecoveryTestClaim(
        anchor, anchor_tx->vout.at(0).nValue - DEFAULT_TRANSACTION_MAXFEE,
        anchor_tx->vout.at(0).scriptPubKey);
    AddRecoveryTestClaim(*wallet, claim, tip->nHeight, tip->GetBlockHash(),
                         tip->nHeight, tip->GetBlockHash());

    BOOST_REQUIRE(wallet->AddToWallet(
        claim, TxStateInactive{/*abandoned=*/true},
        [&](CWalletTx& wtx, bool) {
            wtx.m_state = TxStateInactive{/*abandoned=*/true};
            wtx.mapValue[SHADOW_POW_CLAIM_EXPIRED_RETIRED_KEY] = "1";
            wtx.mapValue[SHADOW_POW_CLAIM_EXPIRED_RETIRED_HEIGHT_KEY] =
                ToString(tip->nHeight);
            wtx.mapValue[SHADOW_POW_CLAIM_EXPIRED_RETIRED_TIP_KEY] =
                tip->GetBlockHash().GetHex();
            return true;
        }));
    {
        LOCK(wallet->cs_wallet);
        CWalletTx& legacy = wallet->mapWallet.at(claim->GetHash());
        BOOST_CHECK(legacy.isAbandoned());
        BOOST_CHECK(wallet->IsSpent(anchor));

        // Torn or malformed historical metadata must fail closed too. A
        // repair transaction clears all three keys atomically; until then,
        // the presence of any one key keeps peer-retained bytes reserved.
        const auto complete_metadata = legacy.mapValue;
        legacy.mapValue.erase(SHADOW_POW_CLAIM_EXPIRED_RETIRED_KEY);
        legacy.mapValue.erase(SHADOW_POW_CLAIM_EXPIRED_RETIRED_TIP_KEY);
        BOOST_CHECK(wallet->IsSpent(anchor));
        legacy.mapValue = complete_metadata;
        legacy.mapValue[SHADOW_POW_CLAIM_EXPIRED_RETIRED_KEY] = "malformed";
        legacy.mapValue.erase(
            SHADOW_POW_CLAIM_EXPIRED_RETIRED_HEIGHT_KEY);
        legacy.mapValue.erase(SHADOW_POW_CLAIM_EXPIRED_RETIRED_TIP_KEY);
        BOOST_CHECK(wallet->IsSpent(anchor));
        legacy.mapValue = complete_metadata;
    }
    BOOST_CHECK(wallet->CountQuarantinedShadowPowClaims() > 0);
    const MockableData legacy_records =
        GetMockableDatabase(*wallet).m_records;

    auto load_legacy = [&] {
        auto loaded = std::make_unique<CWallet>(
            m_node.chain.get(), "",
            CreateMockableWalletDatabase(legacy_records));
        BOOST_REQUIRE_EQUAL(loaded->LoadWallet(), DBErrors::LOAD_OK);
        {
            LOCK(loaded->cs_wallet);
            loaded->SetLastBlockProcessed(tip->nHeight,
                                          tip->GetBlockHash());
        }
        return loaded;
    };

    // A user hold installed on a historical marker-backed reservation must
    // survive another same-anchor wallet transaction learned before startup
    // repair. Only an explicit unlock may remove the durable restriction.
    auto held = load_legacy();
    {
        LOCK2(::cs_main, held->cs_wallet);
        BOOST_REQUIRE(held->CanLockQuarantinedShadowPowClaimAnchor(anchor));
        std::string lock_error;
        BOOST_REQUIRE(held->UpdateLockedCoins(
            {anchor}, /*lock=*/true, /*persistent=*/true, &lock_error));
        BOOST_CHECK(held->IsLockedCoin(anchor));
    }
    CMutableTransaction held_conflict;
    held_conflict.vin.emplace_back(anchor);
    held_conflict.vout.emplace_back(
        anchor_tx->vout.at(0).nValue - 2 * DEFAULT_TRANSACTION_MAXFEE,
        anchor_tx->vout.at(0).scriptPubKey);
    BOOST_REQUIRE(held->AddToWallet(
        MakeTransactionRef(std::move(held_conflict)), TxStateInactive{}));
    {
        LOCK(held->cs_wallet);
        BOOST_CHECK(held->IsLockedCoin(anchor));
    }
    CWallet held_reload(
        m_node.chain.get(), "", DuplicateMockDatabase(held->GetDatabase()));
    BOOST_REQUIRE_EQUAL(held_reload.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(held_reload.cs_wallet);
        BOOST_CHECK(held_reload.IsLockedCoin(anchor));
        std::string lock_error;
        BOOST_REQUIRE(held_reload.UpdateLockedCoins(
            {anchor}, /*lock=*/false, /*persistent=*/true, &lock_error));
        BOOST_CHECK(!held_reload.IsLockedCoin(anchor));
    }
    CWallet held_unlocked_reload(
        m_node.chain.get(), "",
        DuplicateMockDatabase(held_reload.GetDatabase()));
    BOOST_REQUIRE_EQUAL(held_unlocked_reload.LoadWallet(), DBErrors::LOAD_OK);
    BOOST_CHECK(WITH_LOCK(held_unlocked_reload.cs_wallet,
                          return !held_unlocked_reload.IsLockedCoin(anchor)));

    auto failed = load_legacy();
    MockableDatabase& failed_database = GetMockableDatabase(*failed);
    failed_database.m_fail_write_at = 0;
    failed->RepairStaleShadowTransactions(/*force=*/true);
    failed_database.m_fail_write_at.reset();
    {
        LOCK(failed->cs_wallet);
        const CWalletTx& retained = failed->mapWallet.at(claim->GetHash());
        BOOST_CHECK(retained.isAbandoned());
        BOOST_CHECK(HasRetirementMarker(retained));
        BOOST_CHECK(failed->IsSpent(anchor));
        BOOST_CHECK(!failed->GetLiveUnspentStakeOutpoints().count(anchor));
    }
    BOOST_CHECK(failed->IsShadowPowClaimRecoveryDatabaseAmbiguous());
    BOOST_CHECK(failed->CountQuarantinedShadowPowClaims() > 0);

    auto repaired = load_legacy();
    repaired->RepairStaleShadowTransactions(/*force=*/true);
    {
        LOCK(repaired->cs_wallet);
        const CWalletTx& reopened = repaired->mapWallet.at(claim->GetHash());
        BOOST_CHECK(!reopened.isAbandoned());
        BOOST_CHECK(!HasRetirementMarker(reopened));
        BOOST_CHECK(repaired->IsQuarantinedShadowPowClaim(
            claim->GetHash()));
        BOOST_CHECK(repaired->IsSpent(anchor));
        BOOST_CHECK(!repaired->GetLiveUnspentStakeOutpoints().count(anchor));
    }

    CWallet repaired_reload(
        m_node.chain.get(), "", DuplicateMockDatabase(repaired->GetDatabase()));
    BOOST_REQUIRE_EQUAL(repaired_reload.LoadWallet(), DBErrors::LOAD_OK);
    {
        LOCK(repaired_reload.cs_wallet);
        repaired_reload.SetLastBlockProcessed(tip->nHeight,
                                              tip->GetBlockHash());
        const CWalletTx& durable =
            repaired_reload.mapWallet.at(claim->GetHash());
        BOOST_CHECK(!durable.isAbandoned());
        BOOST_CHECK(!HasRetirementMarker(durable));
        BOOST_CHECK(repaired_reload.IsSpent(anchor));
        BOOST_CHECK(!repaired_reload.GetLiveUnspentStakeOutpoints().count(
            anchor));
    }
}

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
