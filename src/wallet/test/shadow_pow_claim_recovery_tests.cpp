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

CTransactionRef MakeRecoveryTestClaim(const COutPoint& input, CAmount value,
                                      const CScript& wallet_script)
{
    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0, 0, 0, 0, 0, 0, 0, 0,
                               0});
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

BOOST_AUTO_TEST_SUITE_END()

} // namespace wallet
