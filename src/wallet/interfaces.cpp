// Copyright (c) 2018-2022 Blackcoin Core Developers
// Copyright (c) 2018-2022 Blackcoin More Developers
// Copyright (c) 2018-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <interfaces/wallet.h>

#include <addresstype.h>
#include <chain.h>
#include <chainparams.h>
#include <common/args.h>
#include <core_io.h>
#include <consensus/amount.h>
#include <consensus/demurrage.h>
#include <consensus/quantum_witness.h>
#include <crypto/mldsa.h>
#include <interfaces/chain.h>
#include <interfaces/handler.h>
#include <kernel/cs_main.h>
#include <key_io.h>
#include <node/quantum_pool.h>
#include <policy/fees.h>
#include <policy/policy.h>
#include <primitives/transaction.h>
#include <rpc/server.h>
#include <script/solver.h>
#include <shadow.h>
#include <support/allocators/secure.h>
#include <sync.h>
#include <uint256.h>
#include <util/check.h>
#include <util/moneystr.h>
#include <util/strencodings.h>
#include <util/translation.h>
#include <util/ui_change_type.h>
#include <wallet/coincontrol.h>
#include <wallet/context.h>
#include <wallet/fees.h>
#include <wallet/types.h>
#include <wallet/load.h>
#include <wallet/quantum_stake_ops.h>
#include <wallet/receive.h>
#include <wallet/rpc/wallet.h>
#include <wallet/spend.h>
#include <wallet/staking.h>
#include <wallet/shadow_pow_claim_recovery.h>
#include <wallet/wallet.h>

#include <algorithm>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

using interfaces::Chain;
using interfaces::FoundBlock;
using interfaces::Handler;
using interfaces::MakeSignalHandler;
using interfaces::Wallet;
using interfaces::WalletAddress;
using interfaces::WalletBalances;
using interfaces::WalletLoader;
using interfaces::WalletMigrationResult;
using interfaces::WalletMigrationStatus;
using interfaces::WalletPowClaimRecoveryMode;
using interfaces::WalletPowClaimRecoveryPolicy;
using interfaces::WalletPowClaimRecoveryRequestMode;
using interfaces::WalletPowMiningInfo;
using interfaces::WalletDemurrageInfo;
using interfaces::WalletDemurrageOutputInfo;
using interfaces::WalletEUTXOStateInfo;
using interfaces::WalletRGBAssetInfo;
using interfaces::WalletRGBAssignmentInfo;
using interfaces::WalletQuantumAddressInfo;
using interfaces::WalletQuantumColdStakeBalanceInfo;
using interfaces::WalletQuantumActionTx;
using interfaces::WalletQuantumColdStakeInfo;
using interfaces::WalletQuantumFundingStatus;
using interfaces::WalletQuantumOperatorBondInfo;
using interfaces::WalletQuantumOperatorBondTx;
using interfaces::WalletQuantumPoolInfo;
using interfaces::WalletQuantumPoolOperatorInfo;
using interfaces::WalletQuantumRedelegationInfo;
using interfaces::WalletQuantumStakeOutputInfo;
using interfaces::WalletUTXOOptimizationTx;
using interfaces::WalletOrderForm;
using interfaces::WalletTx;
using interfaces::WalletTxOut;
using interfaces::WalletTxStatus;
using interfaces::WalletValueMap;

namespace wallet {
static_assert(WalletPowClaimRecoveryPolicy::VERSION == ShadowPowClaimRecoveryPolicy::VERSION);
static_assert(WalletPowClaimRecoveryPolicy::MIN_FEE_PER_RESOLUTION == SHADOW_POW_RECOVERY_MIN_FEE_PER_RESOLUTION);
static_assert(WalletPowClaimRecoveryPolicy::MAX_FEE_PER_RESOLUTION == SHADOW_POW_RECOVERY_MAX_FEE_PER_RESOLUTION);
static_assert(WalletPowClaimRecoveryPolicy::MAX_BATCH_FEE_CAP == SHADOW_POW_RECOVERY_MAX_BATCH_FEE_CAP);
static_assert(WalletPowClaimRecoveryPolicy::MAX_ROLLING_FEE_BUDGET == SHADOW_POW_RECOVERY_MAX_ROLLING_FEE_BUDGET);
static_assert(WalletPowClaimRecoveryPolicy::MIN_WINDOW_SECONDS == SHADOW_POW_RECOVERY_MIN_WINDOW_SECONDS);
static_assert(WalletPowClaimRecoveryPolicy::MAX_WINDOW_SECONDS == SHADOW_POW_RECOVERY_MAX_WINDOW_SECONDS);
static_assert(WalletPowClaimRecoveryPolicy::MIN_ACTIONS_PER_WINDOW == SHADOW_POW_RECOVERY_MIN_ACTIONS_PER_WINDOW);
static_assert(WalletPowClaimRecoveryPolicy::MAX_ACTIONS_PER_WINDOW == SHADOW_POW_RECOVERY_MAX_ACTIONS_PER_WINDOW);
static_assert(WalletPowClaimRecoveryPolicy::MIN_STALE_BLOCKS == SHADOW_POW_RECOVERY_MIN_STALE_BLOCKS);
static_assert(WalletPowClaimRecoveryPolicy::MAX_STALE_BLOCKS == SHADOW_POW_RECOVERY_MAX_STALE_BLOCKS);

// All members of the classes in this namespace are intentionally public, as the
// classes themselves are private.
namespace {

interfaces::WalletPowClaimRecoveryState MakeRecoveryState(
    ShadowPowClaimRecoveryState state)
{
    using Out = interfaces::WalletPowClaimRecoveryState;
    switch (state) {
    case ShadowPowClaimRecoveryState::LIVE: return Out::LIVE;
    case ShadowPowClaimRecoveryState::TRANSIENT: return Out::TRANSIENT;
    case ShadowPowClaimRecoveryState::INDETERMINATE: return Out::INDETERMINATE;
    case ShadowPowClaimRecoveryState::CURRENT_BRANCH_INELIGIBLE: return Out::CURRENT_BRANCH_INELIGIBLE;
    case ShadowPowClaimRecoveryState::TERMINAL_ON_PINNED_TIP: return Out::TERMINAL_ON_PINNED_TIP;
    case ShadowPowClaimRecoveryState::RETIRED_ON_ACTIVE_BRANCH: return Out::RETIRED_ON_ACTIVE_BRANCH;
    case ShadowPowClaimRecoveryState::RESOLUTION_PENDING: return Out::RESOLUTION_PENDING;
    case ShadowPowClaimRecoveryState::RESOLVED_ON_ACTIVE_CHAIN: return Out::RESOLVED_ON_ACTIVE_CHAIN;
    }
    return Out::INDETERMINATE;
}

interfaces::WalletPowClaimRecoveryProvenance MakeRecoveryProvenance(
    ShadowPowClaimRecoveryProvenance provenance)
{
    using Out = interfaces::WalletPowClaimRecoveryProvenance;
    switch (provenance) {
    case ShadowPowClaimRecoveryProvenance::EXPLICIT_AUTHORED: return Out::EXPLICIT_AUTHORED;
    case ShadowPowClaimRecoveryProvenance::EXPLICIT_ADOPTED: return Out::EXPLICIT_ADOPTED;
    case ShadowPowClaimRecoveryProvenance::LEGACY_WALLET_AUTHORED: return Out::LEGACY_WALLET_AUTHORED;
    case ShadowPowClaimRecoveryProvenance::UNKNOWN: return Out::UNKNOWN;
    }
    return Out::UNKNOWN;
}

interfaces::WalletPowClaimRecoveryNodeKind MakeRecoveryNodeKind(
    ShadowPowClaimRecoveryNodeKind kind)
{
    using Out = interfaces::WalletPowClaimRecoveryNodeKind;
    switch (kind) {
    case ShadowPowClaimRecoveryNodeKind::CLAIM: return Out::CLAIM;
    case ShadowPowClaimRecoveryNodeKind::MANAGED_RESOLUTION: return Out::MANAGED_RESOLUTION;
    case ShadowPowClaimRecoveryNodeKind::LEGACY_RESOLUTION: return Out::LEGACY_RESOLUTION;
    case ShadowPowClaimRecoveryNodeKind::ORDINARY: return Out::ORDINARY;
    }
    return Out::ORDINARY;
}

interfaces::WalletPowClaimRecoveryActionStatus MakeRecoveryActionStatus(
    ShadowPowClaimRecoveryActionStatus status)
{
    using Out = interfaces::WalletPowClaimRecoveryActionStatus;
    switch (status) {
    case ShadowPowClaimRecoveryActionStatus::READY: return Out::READY;
    case ShadowPowClaimRecoveryActionStatus::REUSE_MANAGED: return Out::REUSE_MANAGED;
    case ShadowPowClaimRecoveryActionStatus::REUSE_LEGACY: return Out::REUSE_LEGACY;
    case ShadowPowClaimRecoveryActionStatus::SIGNED_AND_PERSISTED: return Out::SIGNED_AND_PERSISTED;
    case ShadowPowClaimRecoveryActionStatus::BROADCAST: return Out::BROADCAST;
    case ShadowPowClaimRecoveryActionStatus::ALREADY_IN_MEMPOOL: return Out::ALREADY_IN_MEMPOOL;
    case ShadowPowClaimRecoveryActionStatus::RELAY_DEFERRED: return Out::RELAY_DEFERRED;
    case ShadowPowClaimRecoveryActionStatus::REFUSED: return Out::REFUSED;
    case ShadowPowClaimRecoveryActionStatus::FAILED: return Out::FAILED;
    }
    return Out::FAILED;
}

std::string RecoveryDispositionName(ShadowPowClaimMempoolDisposition disposition)
{
    switch (disposition) {
    case ShadowPowClaimMempoolDisposition::ELIGIBLE: return "eligible";
    case ShadowPowClaimMempoolDisposition::INACTIVE: return "inactive";
    case ShadowPowClaimMempoolDisposition::HEIGHT_BEFORE_WINDOW: return "height_before_window";
    case ShadowPowClaimMempoolDisposition::HEIGHT_AFTER_WINDOW: return "height_after_window";
    case ShadowPowClaimMempoolDisposition::INVALID_LOCATION: return "invalid_location";
    case ShadowPowClaimMempoolDisposition::MALFORMED: return "malformed";
    case ShadowPowClaimMempoolDisposition::DUPLICATE: return "duplicate";
    case ShadowPowClaimMempoolDisposition::WRONG_MODE: return "wrong_mode";
    case ShadowPowClaimMempoolDisposition::UNKNOWN_MODE: return "unknown_mode";
    case ShadowPowClaimMempoolDisposition::UNSUPPORTED_VERSION: return "unsupported_version";
    case ShadowPowClaimMempoolDisposition::VERSION_NOT_YET_ACTIVE: return "version_not_yet_active";
    case ShadowPowClaimMempoolDisposition::INVALID_PROOF: return "invalid_proof";
    case ShadowPowClaimMempoolDisposition::UNBOUND_PROOF_MAY_REVALIDATE: return "unbound_proof_may_revalidate";
    case ShadowPowClaimMempoolDisposition::ORIGIN_MISMATCH: return "origin_mismatch";
    case ShadowPowClaimMempoolDisposition::ORIGIN_NOT_YET_REACHED: return "origin_not_yet_reached";
    case ShadowPowClaimMempoolDisposition::ORIGIN_EXPIRED: return "origin_expired";
    case ShadowPowClaimMempoolDisposition::INPUT_MISMATCH: return "input_mismatch";
    case ShadowPowClaimMempoolDisposition::ALREADY_ACCOUNTED: return "already_accounted";
    case ShadowPowClaimMempoolDisposition::CAPACITY_LIMIT: return "capacity_limit";
    case ShadowPowClaimMempoolDisposition::EVALUATION_LIMIT: return "evaluation_limit";
    case ShadowPowClaimMempoolDisposition::LOCAL_STATE_ERROR: return "local_state_error";
    }
    return "local_state_error";
}

interfaces::WalletPowClaimRecoveryNode MakeRecoveryNode(
    const ShadowPowClaimRecoveryNode& node)
{
    interfaces::WalletPowClaimRecoveryNode out;
    out.txid = node.txid.GetHex();
    out.kind = MakeRecoveryNodeKind(node.kind);
    out.provenance = MakeRecoveryProvenance(node.provenance);
    out.disposition = RecoveryDispositionName(node.disposition);
    out.proof_may_revalidate_on_descendant =
        node.proof_may_revalidate_on_descendant;
    out.active_chain_confirmed = node.active_chain_confirmed;
    out.in_mempool = node.in_mempool;
    out.quarantined = node.quarantined;
    out.abandoned = node.abandoned;
    out.expired_locally_retired = node.expired_locally_retired;
    out.expected_shape = node.expected_shape;
    out.wallet_authored = node.wallet_authored;
    out.created_height = node.created_height;
    out.first_quarantine_height = node.first_quarantine_height;
    out.branch_quarantine_height = node.branch_quarantine_height;
    out.stale_depth = node.stale_depth;
    out.stale_depth_known = node.stale_depth_known;
    out.resolution_relay_authorized = node.resolution_relay_authorized;
    out.resolution_relay_revoked = node.resolution_relay_revoked;
    return out;
}

std::vector<std::string> HashStrings(const std::vector<uint256>& hashes)
{
    std::vector<std::string> out;
    out.reserve(hashes.size());
    for (const uint256& hash : hashes) out.push_back(hash.GetHex());
    return out;
}

interfaces::WalletPowClaimRecoveryComponent MakeRecoveryComponent(
    const ShadowPowClaimRecoveryComponent& component)
{
    interfaces::WalletPowClaimRecoveryComponent out;
    out.anchor_txid = component.anchor.hash.GetHex();
    out.anchor_vout = component.anchor.n;
    out.anchor_amount = component.anchor_amount;
    out.generation_fingerprint = component.generation_fingerprint.GetHex();
    out.component_fingerprint = component.fingerprint.GetHex();
    out.state = MakeRecoveryState(component.state);
    out.nodes.reserve(component.nodes.size());
    for (const auto& node : component.nodes) out.nodes.push_back(MakeRecoveryNode(node));
    out.claim_txids = HashStrings(component.claim_txids);
    out.root_claim_txids = HashStrings(component.root_claim_txids);
    out.resolution_txids = HashStrings(component.resolution_txids);
    out.anchor_authenticated = component.anchor_authenticated;
    out.anchor_unspent = component.anchor_unspent;
    out.all_claims_explicitly_provenanced = component.all_claims_explicitly_provenanced;
    out.all_claims_zero_payment_retirable =
        component.all_claims_zero_payment_retirable;
    out.all_claims_expired_locally_retired =
        component.all_claims_expired_locally_retired;
    out.has_revalidating_unbound_proof =
        component.has_revalidating_unbound_proof;
    out.adoption_graph_safe = component.adoption_graph_safe;
    out.descendant_claims = component.descendant_claims;
    out.minimum_stale_depth = component.minimum_stale_depth;
    out.stale_depth_known = component.stale_depth_known;
    return out;
}

interfaces::WalletPowClaimRecoveryAction MakeRecoveryAction(
    const ShadowPowClaimRecoveryAction& action)
{
    interfaces::WalletPowClaimRecoveryAction out;
    out.anchor_txid = action.anchor.hash.GetHex();
    out.anchor_vout = action.anchor.n;
    out.generation_fingerprint = action.generation_fingerprint.GetHex();
    out.component_fingerprint = action.component_fingerprint.GetHex();
    out.claim_txids = HashStrings(action.claim_txids);
    out.descendant_claims = action.descendant_claims;
    out.component_state = MakeRecoveryState(action.component_state);
    out.status = MakeRecoveryActionStatus(action.status);
    out.fee = action.fee;
    out.vsize = action.vsize;
    if (action.transaction) out.transaction_txid = action.transaction->GetHash().GetHex();
    out.persisted = action.persisted;
    out.in_mempool = action.in_mempool;
    out.relay_authorized = action.relay_authorized;
    out.relay_revoked = action.relay_revoked;
    out.frontier_may_advance = action.frontier_may_advance;
    out.conflicts_with_revalidating_unbound_proof =
        action.conflicts_with_revalidating_unbound_proof;
    out.reason_code = action.reason_code;
    out.detail = action.detail;
    return out;
}

interfaces::WalletPowClaimRecoveryPlan MakeRecoveryPlan(
    const ShadowPowClaimRecoveryPlan& plan)
{
    interfaces::WalletPowClaimRecoveryPlan out;
    out.active_tip = plan.active_tip.GetHex();
    out.active_height = plan.active_height;
    out.wallet_generation = plan.wallet_generation;
    out.plan_id = plan.plan_id.GetHex();
    out.max_fee_per_resolution = plan.max_fee_per_resolution;
    out.aggregate_batch_fee_cap = plan.aggregate_batch_fee_cap;
    out.fee_rate_atoms_per_k = plan.fee_rate_atoms_per_k;
    out.total_fee = plan.total_fee;
    out.actions.reserve(plan.actions.size());
    for (const auto& action : plan.actions) out.actions.push_back(MakeRecoveryAction(action));
    out.refused.reserve(plan.refused.size());
    for (const auto& action : plan.refused) out.refused.push_back(MakeRecoveryAction(action));
    out.wallet_tip_matches = plan.wallet_tip_matches;
    out.complete = plan.complete;
    return out;
}

interfaces::WalletPowClaimRecoveryUsage MakeRecoveryUsage(
    const ShadowPowClaimRecoveryUsage& usage)
{
    interfaces::WalletPowClaimRecoveryUsage out;
    out.pending_manual = usage.pending_manual;
    out.pending_automatic = usage.pending_automatic;
    out.confirmed_manual = usage.confirmed_manual;
    out.confirmed_automatic = usage.confirmed_automatic;
    out.confirmed_resolution_fees = usage.confirmed_resolution_fees;
    out.automatic_actions_in_window = usage.automatic_actions_in_window;
    out.automatic_fee_exposure_in_window = usage.automatic_fee_exposure_in_window;
    out.reconciled_descendant_claims = usage.reconciled_descendant_claims;
    out.recycled_outputs = usage.recycled_outputs;
    return out;
}

interfaces::WalletPowClaimRecoveryPolicy MakeRecoveryPolicy(
    const ShadowPowClaimRecoveryPolicy& policy)
{
    interfaces::WalletPowClaimRecoveryPolicy out;
    out.version = policy.version;
    out.mode = policy.choice_recorded == 0
        ? interfaces::WalletPowClaimRecoveryMode::UNSET
        : policy.automatic_enabled == 1
            ? interfaces::WalletPowClaimRecoveryMode::AUTOMATIC
            : interfaces::WalletPowClaimRecoveryMode::PAUSE_AND_ASK;
    out.max_fee_per_resolution = policy.max_fee_per_resolution;
    out.aggregate_batch_fee_cap = policy.aggregate_batch_fee_cap;
    out.rolling_fee_budget = policy.rolling_fee_budget;
    out.rolling_fee_window_seconds = policy.rolling_fee_window_seconds;
    out.max_actions_per_window = policy.max_actions_per_window;
    out.minimum_stale_blocks = policy.minimum_stale_blocks;
    return out;
}

bool MakeCoreRecoveryPolicy(
    const interfaces::WalletPowClaimRecoveryPolicy& policy,
    ShadowPowClaimRecoveryPolicy& out, std::string& error)
{
    out.version = policy.version;
    switch (policy.mode) {
    case interfaces::WalletPowClaimRecoveryMode::UNSET:
        out.choice_recorded = 0;
        out.automatic_enabled = 0;
        break;
    case interfaces::WalletPowClaimRecoveryMode::PAUSE_AND_ASK:
        out.choice_recorded = 1;
        out.automatic_enabled = 0;
        break;
    case interfaces::WalletPowClaimRecoveryMode::AUTOMATIC:
        out.choice_recorded = 1;
        out.automatic_enabled = 1;
        break;
    default:
        error = "Unknown PoW claim recovery policy mode";
        return false;
    }
    out.max_fee_per_resolution = policy.max_fee_per_resolution;
    out.aggregate_batch_fee_cap = policy.aggregate_batch_fee_cap;
    out.rolling_fee_budget = policy.rolling_fee_budget;
    out.rolling_fee_window_seconds = policy.rolling_fee_window_seconds;
    out.max_actions_per_window = policy.max_actions_per_window;
    out.minimum_stale_blocks = policy.minimum_stale_blocks;
    error.clear();
    return true;
}

interfaces::WalletPowClaimRecoveryPolicyMutationStatus
MakeRecoveryPolicyMutationStatus(
    ShadowPowClaimRecoveryPolicyMutationStatus status)
{
    using Out = interfaces::WalletPowClaimRecoveryPolicyMutationStatus;
    switch (status) {
    case ShadowPowClaimRecoveryPolicyMutationStatus::SUCCESS:
        return Out::SUCCESS;
    case ShadowPowClaimRecoveryPolicyMutationStatus::INVALID_POLICY:
        return Out::INVALID_POLICY;
    case ShadowPowClaimRecoveryPolicyMutationStatus::DATABASE_FAILURE:
        return Out::DATABASE_FAILURE;
    case ShadowPowClaimRecoveryPolicyMutationStatus::DATABASE_OUTCOME_AMBIGUOUS:
        return Out::DATABASE_OUTCOME_AMBIGUOUS;
    }
    return Out::DATABASE_FAILURE;
}

interfaces::WalletPowClaimRecoveryPolicyMutationResult
MakeRecoveryPolicyMutationResult(
    const ShadowPowClaimRecoveryPolicyMutationResult& result)
{
    interfaces::WalletPowClaimRecoveryPolicyMutationResult out;
    out.status = MakeRecoveryPolicyMutationStatus(result.status);
    out.reason_code =
        ShadowPowClaimRecoveryPolicyMutationStatusName(result.status);
    out.success = result.success;
    out.durable_state_changed = result.durable_state_changed;
    out.durable_state_ambiguous = result.durable_state_ambiguous;
    out.authoritative_state_available = result.authoritative_state_available;
    if (result.authoritative_state_available) {
        out.authoritative_policy =
            MakeRecoveryPolicy(result.authoritative_policy);
    }
    out.detail = result.detail;
    return out;
}

interfaces::WalletPowClaimRecoveryAdoptionStatus MakeRecoveryAdoptionStatus(
    ShadowPowClaimRecoveryAdoptionStatus status)
{
    using Out = interfaces::WalletPowClaimRecoveryAdoptionStatus;
    switch (status) {
    case ShadowPowClaimRecoveryAdoptionStatus::SUCCESS: return Out::SUCCESS;
    case ShadowPowClaimRecoveryAdoptionStatus::ALREADY_EXPLICIT: return Out::ALREADY_EXPLICIT;
    case ShadowPowClaimRecoveryAdoptionStatus::NO_CHAIN: return Out::NO_CHAIN;
    case ShadowPowClaimRecoveryAdoptionStatus::DATABASE_OUTCOME_AMBIGUOUS: return Out::DATABASE_OUTCOME_AMBIGUOUS;
    case ShadowPowClaimRecoveryAdoptionStatus::SIGNING_UNAVAILABLE: return Out::SIGNING_UNAVAILABLE;
    case ShadowPowClaimRecoveryAdoptionStatus::STALE_TIP: return Out::STALE_TIP;
    case ShadowPowClaimRecoveryAdoptionStatus::SELECTOR_NOT_FOUND: return Out::SELECTOR_NOT_FOUND;
    case ShadowPowClaimRecoveryAdoptionStatus::SELECTOR_NOT_CLAIM: return Out::SELECTOR_NOT_CLAIM;
    case ShadowPowClaimRecoveryAdoptionStatus::SELECTOR_AMBIGUOUS: return Out::SELECTOR_AMBIGUOUS;
    case ShadowPowClaimRecoveryAdoptionStatus::STALE_COMPONENT_FINGERPRINT: return Out::STALE_COMPONENT_FINGERPRINT;
    case ShadowPowClaimRecoveryAdoptionStatus::UNSAFE_GRAPH: return Out::UNSAFE_GRAPH;
    case ShadowPowClaimRecoveryAdoptionStatus::DATABASE_FAILURE: return Out::DATABASE_FAILURE;
    }
    return Out::DATABASE_FAILURE;
}

interfaces::WalletPowClaimRecoveryAdoptionResult MakeRecoveryAdoptionResult(
    const ShadowPowClaimRecoveryAdoptionResult& result)
{
    interfaces::WalletPowClaimRecoveryAdoptionResult out;
    out.status = MakeRecoveryAdoptionStatus(result.status);
    out.reason_code = ShadowPowClaimRecoveryAdoptionStatusName(result.status);
    out.success = result.IsSuccess();
    out.adopted = result.adopted;
    out.durable_state_changed = result.durable_state_changed;
    out.durable_state_ambiguous = result.durable_state_ambiguous;
    if (!result.active_tip.IsNull()) out.active_tip = result.active_tip.GetHex();
    if (!result.generation_fingerprint.IsNull()) {
        out.generation_fingerprint = result.generation_fingerprint.GetHex();
    }
    if (!result.reviewed_component_fingerprint.IsNull()) {
        out.reviewed_component_fingerprint =
            result.reviewed_component_fingerprint.GetHex();
    }
    if (!result.post_adoption_component_fingerprint.IsNull()) {
        out.post_adoption_component_fingerprint =
            result.post_adoption_component_fingerprint.GetHex();
    }
    out.claim_txids = HashStrings(result.claim_txids);
    out.automatic_eligible_after_adoption =
        result.automatic_eligible_after_adoption;
    out.component_has_revalidating_unbound_proof =
        result.component_has_revalidating_unbound_proof;
    out.component_refusal_code = result.component_refusal_code;
    out.detail = result.detail;
    return out;
}

bool MakeCoreRecoveryRequest(
    const interfaces::WalletPowClaimRecoveryRequest& request,
    ShadowPowClaimRecoveryRequest& out, std::string& error)
{
    out.origin = ShadowPowClaimRecoveryOrigin::MANUAL;
    switch (request.mode) {
    case WalletPowClaimRecoveryRequestMode::PREVIEW:
        out.mode = ShadowPowClaimRecoveryMode::PREVIEW;
        out.execution_authority = ShadowPowClaimRecoveryExecutionAuthority::NONE;
        break;
    case WalletPowClaimRecoveryRequestMode::SIGN_ONLY:
        out.mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
        out.execution_authority = ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
        break;
    case WalletPowClaimRecoveryRequestMode::COMMIT_AND_BROADCAST:
        out.mode = ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST;
        out.execution_authority = ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
        break;
    default:
        error = "Unknown claim recovery request mode";
        return false;
    }
    out.acknowledge_fee_and_conflict_risk = request.acknowledge_fee_and_conflict_risk;
    out.max_fee_per_resolution = request.max_fee_per_resolution;
    out.aggregate_batch_fee_cap = request.aggregate_batch_fee_cap;
    if (request.fee_rate_atoms_per_k) {
        out.fee_rate = CFeeRate{*request.fee_rate_atoms_per_k};
    }
    for (const std::string& selector : request.selectors) {
        uint256 hash;
        if (!ParseHashStr(selector, hash)) {
            error = "Invalid claim or resolution transaction id: " + selector;
            return false;
        }
        out.selectors.push_back(hash);
    }
    if (request.expected_plan_id) {
        uint256 plan_id;
        if (!ParseHashStr(*request.expected_plan_id, plan_id)) {
            error = "Invalid recovery plan id";
            return false;
        }
        out.expected_plan_id = plan_id;
    }
    error.clear();
    return true;
}

std::string QuantumQuasarPhaseName(Consensus::QuantumQuasarPhase phase)
{
    switch (phase) {
    case Consensus::QuantumQuasarPhase::LEGACY: return "legacy";
    case Consensus::QuantumQuasarPhase::GOLD_RUSH: return "gold_rush";
    case Consensus::QuantumQuasarPhase::MIGRATION: return "migration";
    case Consensus::QuantumQuasarPhase::FINAL_LOCKOUT: return "final_lockout";
    }
    return "unknown";
}

std::optional<bilingual_str> QuantumMigrationSweepPhaseError(
    const CWallet& wallet,
    bool goldrush_rewards_only)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main)
{
    if (!wallet.HaveChain()) {
        return _("Chain state is unavailable; migration cannot be evaluated.");
    }

    const CBlockIndex* tip = wallet.chain().getTip();
    if (!tip) {
        return _("Chain tip is unavailable; migration cannot be evaluated.");
    }

    const Consensus::Params& consensus = Params().GetConsensus();
    const int64_t mtp = tip->GetMedianTimePast();
    const int next_height = tip->nHeight + 1;
    const bool quantum_outputs_active = IsQuantumWitnessSpendActive(consensus, mtp, next_height);
    if (goldrush_rewards_only) {
        if (!quantum_outputs_active) {
            return _("Gold Rush reward outputs remain locked until quantum witness spends activate after the Gold Rush.");
        }
        return std::nullopt;
    }

    if (consensus.IsQuantumFinalLockout(mtp, next_height)) {
        return _("The migration deadline has passed; legacy coins are no longer spendable and cannot be migrated.");
    }
    if (!quantum_outputs_active || !consensus.IsQuantumMigrationWindow(mtp, next_height)) {
        return _("Legacy migration is available only during the active Migration phase.");
    }
    return std::nullopt;
}

util::Result<void> CommitWalletTransactionOrError(CWallet& wallet, const CTransactionRef& tx, mapValue_t map_value, const std::string& action)
{
    try {
        std::string broadcast_error;
        WalletCommitStatus status;
        if (!wallet.CommitTransaction(tx, std::move(map_value), {}, &broadcast_error, &status)) {
            const std::string reason = broadcast_error.empty() ? "transaction was not accepted into the mempool" : broadcast_error;
            if (status == WalletCommitStatus::PERSISTED_PENDING) return {};
            return util::Error{Untranslated(strprintf("Error: %s transaction could not be committed: %s", action, reason))};
        }
    } catch (const std::exception& e) {
        return util::Error{Untranslated(strprintf("Error: %s transaction could not be committed: %s", action, e.what()))};
    }
    return {};
}

bilingual_str DurableQuantumKeyFailure(
    const CTxDestination& created_destination,
    const std::string& action,
    const bilingual_str& failure)
{
    return Untranslated(strprintf(
        "%s failed after creating durable non-HD ML-DSA key %s. The key remains in this wallet even though no successful action was reported. Back up the wallet now; an older backup cannot recover it. Original error: %s",
        action,
        EncodeDestination(created_destination),
        failure.original));
}

WalletQuantumAddressInfo MakeWalletQuantumAddressInfo(const CWallet& wallet, const QuantumKeyInfo& info)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    WalletQuantumAddressInfo result;
    result.address = EncodeDestination(info.destination);
    if (const auto* entry = wallet.FindAddressBookEntry(info.destination)) {
        result.label = entry->GetLabel();
    }
    result.public_key = HexStr(info.public_key);
    result.creation_time = info.creation_time;
    result.encrypted = info.encrypted;
    result.durably_stored = info.durably_stored;
    result.backup_verified = info.backup_verified;
    QuantumStakeTierProgram tier;
    if (DecodeQuantumStakeTierProgram(QUANTUM_MIGRATION_WITNESS_VERSION, info.witness_program, tier) && tier.tiered) {
        result.tiered = true;
        result.unbonding_blocks = tier.unbonding_blocks;
        result.unlock_height = tier.unlock_height;
    }
    return result;
}

WalletQuantumColdStakeInfo MakeWalletQuantumColdStakeInfo(const CWallet& wallet, const QuantumColdStakeDelegationInfo& info)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    WalletQuantumColdStakeInfo result;
    result.address = EncodeDestination(info.destination);
    if (const auto* entry = wallet.FindAddressBookEntry(info.destination)) {
        result.label = entry->GetLabel();
    }
    result.staking_pubkey_hash = info.staker_pubkey_hash.GetHex();
    result.owner_pubkey_hash = info.owner_pubkey_hash.GetHex();
    result.creation_time = info.creation_time;
    result.has_staker_key = info.has_staker_key;
    result.has_owner_key = info.has_owner_key;
    result.tiered = info.tiered;
    result.unbonding_blocks = info.unbonding_blocks;
    result.unlock_height = info.unlock_height;
    return result;
}

} // namespace

struct ColdStakeDelegationOutputs
{
    struct Record
    {
        COutPoint outpoint;
        CAmount amount{0};
        int depth{0};
        bool spendable{false};
    };

    CAmount amount{0};
    int outputs{0};
    CAmount confirmed_amount{0};
    int confirmed_outputs{0};
    CAmount unconfirmed_amount{0};
    int unconfirmed_outputs{0};
    CAmount spendable_amount{0};
    int spendable_outputs{0};
    std::vector<COutPoint> spendable_outpoints;
    std::vector<Record> records;
    std::vector<Record> spendable_records;
};

struct ColdStakeFundingInputs
{
    CAmount eligible_amount{0};
    unsigned int eligible_inputs{0};
    CAmount goldrush_reward_amount{0};
    unsigned int goldrush_reward_inputs{0};
};

static constexpr uint16_t OPERATOR_COMMITMENT_BLOCKS = 40500;
static constexpr int RANDOM_CHANGE_POSITION = -1;

util::Result<QuantumColdStakeDelegationInfo> DecodeWalletColdStakeDelegationAddress(
    const CWallet& wallet,
    const std::string& address,
    CTxDestination& dest) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    std::string error_msg;
    dest = DecodeDestination(address, error_msg);
    if (!IsValidDestination(dest)) {
        return util::Error{Untranslated(error_msg.empty() ? "Error: Invalid quantum cold-stake address" : error_msg)};
    }

    const auto* witness = std::get_if<WitnessUnknown>(&dest);
    if (!witness || !IsQuantumColdStakeWitnessProgram(witness->GetWitnessVersion(), witness->GetWitnessProgram())) {
        return util::Error{_("Error: Address must be a Quantum Cold-Stake delegation address")};
    }

    const auto info = wallet.GetQuantumColdStakeDelegationInfo(dest);
    if (!info) {
        return util::Error{_("Error: Cold-stake delegation address is not backed by this wallet")};
    }
    return *info;
}

ColdStakeDelegationOutputs ScanColdStakeDelegationOutputs(
    const CWallet& wallet,
    const CScript& delegation_script,
    bool spendable_only) EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet)
{
    ColdStakeDelegationOutputs outputs;

    CoinFilterParams filter;
    filter.only_spendable = spendable_only;
    filter.skip_locked = spendable_only;
    filter.include_immature_coinbase = false;
    filter.include_locked_quantum_stake_outputs = true;

    const std::vector<COutput> coins = spendable_only
        ? AvailableCoins(wallet, nullptr, std::nullopt, filter).All()
        : AvailableCoinsListUnspent(wallet, nullptr, filter).All();

    for (const COutput& out : coins) {
        if (out.txout.nValue <= 0 || out.txout.scriptPubKey != delegation_script) continue;
        outputs.records.push_back({out.outpoint, out.txout.nValue, out.depth, out.spendable});
        outputs.amount += out.txout.nValue;
        ++outputs.outputs;
        if (out.depth > 0) {
            outputs.confirmed_amount += out.txout.nValue;
            ++outputs.confirmed_outputs;
        } else {
            outputs.unconfirmed_amount += out.txout.nValue;
            ++outputs.unconfirmed_outputs;
        }
        if (out.spendable) {
            outputs.spendable_amount += out.txout.nValue;
            ++outputs.spendable_outputs;
            if (spendable_only) {
                outputs.spendable_outpoints.push_back(out.outpoint);
                outputs.spendable_records.push_back({out.outpoint, out.txout.nValue, out.depth, out.spendable});
            }
        }
    }
    return outputs;
}

WalletQuantumColdStakeBalanceInfo MakeWalletColdStakeBalanceInfo(const CWallet& wallet, const std::string& address)
{
    WalletQuantumColdStakeBalanceInfo result;
    CTxDestination dest;
    TRY_LOCK(::cs_main, main_lock);
    if (!main_lock) {
        result.available = false;
        return result;
    }
    TRY_LOCK(wallet.cs_wallet, wallet_lock);
    if (!wallet_lock) {
        result.available = false;
        return result;
    }
    const auto delegation = DecodeWalletColdStakeDelegationAddress(wallet, address, dest);
    if (!delegation) return result;

    result.valid_delegation_address = true;
    result.current_height = wallet.GetLastBlockHeight();
    const ColdStakeDelegationOutputs outputs = ScanColdStakeDelegationOutputs(
        wallet,
        GetScriptForDestination(dest),
        /*spendable_only=*/false);
    result.amount = outputs.amount;
    result.outputs = outputs.outputs;
    result.confirmed_amount = outputs.confirmed_amount;
    result.confirmed_outputs = outputs.confirmed_outputs;
    result.unconfirmed_amount = outputs.unconfirmed_amount;
    result.unconfirmed_outputs = outputs.unconfirmed_outputs;
    result.spendable_amount = outputs.spendable_amount;
    result.spendable_outputs = outputs.spendable_outputs;
    return result;
}

util::Result<QuantumStakeTierProgram> DecodeTieredStakeAddress(const std::string& address, CTxDestination& dest, bool require_operator_lock)
{
    std::string error_msg;
    dest = DecodeDestination(address, error_msg);
    if (!IsValidDestination(dest)) {
        return util::Error{Untranslated(error_msg.empty() ? "Error: Invalid quantum staking address" : error_msg)};
    }

    const auto* witness = std::get_if<WitnessUnknown>(&dest);
    if (!witness) {
        return util::Error{_("Error: Address must be a bonded quantum staking address")};
    }

    QuantumStakeTierProgram tier;
    if (!DecodeQuantumStakeTierProgram(witness->GetWitnessVersion(), witness->GetWitnessProgram(), tier) ||
        tier.cold_stake || !tier.IsBonded()) {
        return util::Error{_("Error: Address must be a wallet-backed bonded quantum staking address")};
    }
    if (require_operator_lock && tier.unbonding_blocks != OPERATOR_COMMITMENT_BLOCKS) {
        return util::Error{_("Error: Operator address must be a wallet-backed fixed 30-day bonded quantum staking address")};
    }
    return tier;
}

bool CanCreateSignedSpend(const CWallet& wallet, bilingual_str& error)
{
    if (wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)) {
        error = _("Error: Private keys are disabled for this wallet");
        return false;
    }
    if (wallet.IsLocked()) {
        error = _("Error: Wallet is locked");
        return false;
    }
    if (wallet.m_wallet_unlock_staking_only) {
        error = _("Error: Wallet is unlocked for staking only");
        return false;
    }
    return true;
}

ColdStakeFundingInputs ScanColdStakeFundingInputs(
    const CWallet& wallet,
    const CCoinsViewCache& view) EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet)
{
    ColdStakeFundingInputs summary;
    const CBlockIndex* tip = wallet.chain().getTip();
    const int spend_height = tip ? tip->nHeight + 1 : 0;
    const int64_t spend_time = tip ? tip->GetMedianTimePast() : 0;

    CCoinControl scan_control;
    scan_control.m_input_family = CCoinControl::InputFamily::QUANTUM_MIGRATION;

    CoinFilterParams filter;
    filter.only_spendable = true;
    filter.skip_locked = true;
    filter.include_immature_coinbase = false;
    filter.include_generated_quantum_inputs = true;

    for (const COutput& out : AvailableCoins(wallet, &scan_control, std::nullopt, filter).All()) {
        if (out.txout.nValue <= 0 || !IsDirectQuantumMigrationScript(out.txout.scriptPubKey)) continue;

        CScript marker_script;
        if (IsLockedGoldRushPayoutOutput(view, out.outpoint, Params().GetConsensus(),
                spend_time, spend_height, &marker_script) && marker_script == out.txout.scriptPubKey) {
            summary.goldrush_reward_amount += out.txout.nValue;
            ++summary.goldrush_reward_inputs;
            continue;
        }

        summary.eligible_amount += out.txout.nValue;
        ++summary.eligible_inputs;
    }

    return summary;
}

struct SafeFeeInputSummary {
    CAmount amount{0};
    unsigned int inputs{0};
};

SafeFeeInputSummary SelectSafeUnbondingFeeInputs(
    CWallet& wallet,
    const CCoinsViewCache& view,
    CCoinControl& coin_control,
    CAmount target_amount,
    bool allow_legacy) EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet)
{
    SafeFeeInputSummary summary;
    const CBlockIndex* tip = wallet.chain().getTip();
    const int spend_height = tip ? tip->nHeight + 1 : 0;
    const int64_t spend_time = tip ? tip->GetMedianTimePast() : 0;

    CoinFilterParams filter;
    filter.only_spendable = true;
    filter.skip_locked = true;
    filter.include_immature_coinbase = false;

    CCoinControl scan_control;
    scan_control.m_exclude_generated_quantum_inputs = true;

    std::vector<COutput> outputs = AvailableCoins(wallet, &scan_control, std::nullopt, filter).All();
    std::sort(outputs.begin(), outputs.end(), [](const COutput& a, const COutput& b) {
        if (a.txout.nValue != b.txout.nValue) return a.txout.nValue < b.txout.nValue;
        return a.outpoint < b.outpoint;
    });

    for (const COutput& out : outputs) {
        if (coin_control.IsSelected(out.outpoint) || out.txout.nValue <= 0) continue;

        const CScript& spk = out.txout.scriptPubKey;
        CScript marker_script;
        if (IsLockedGoldRushPayoutOutput(view, out.outpoint, Params().GetConsensus(),
                spend_time, spend_height, &marker_script) && marker_script == spk) continue;

        const bool direct_quantum = IsDirectQuantumMigrationScript(spk);
        const bool legacy = allow_legacy && !IsQuantumMigrationScript(spk) && !IsQuantumColdStakeScript(spk) && !IsEUTXOScript(spk);
        if (!direct_quantum && !legacy) continue;

        if (!MoneyRange(out.txout.nValue) || summary.amount > MAX_MONEY - out.txout.nValue) break;
        coin_control.Select(out.outpoint);
        summary.amount += out.txout.nValue;
        ++summary.inputs;
        if (summary.amount >= target_amount) break;
    }

    return summary;
}

struct OperatorBondOutputs
{
    struct Record
    {
        COutPoint outpoint;
        CAmount amount{0};
        int depth{0};
        bool spendable{false};
        std::string state;
        uint32_t unlock_height{0};
    };

    CAmount bonded_amount{0};
    int bonded_outputs{0};
    std::vector<COutPoint> bonded_outpoints;
    CAmount unbonding_amount{0};
    int unbonding_outputs{0};
    CAmount withdrawable_amount{0};
    int withdrawable_outputs{0};
    std::vector<COutPoint> withdrawable_outpoints;
    uint32_t next_unlock_height{0};
    std::vector<Record> records;
};

struct LocalOperatorBondCandidate
{
    std::vector<unsigned char> staking_pubkey;
    COutPoint outpoint;
};

OperatorBondOutputs ScanOperatorBondOutputs(
    const CWallet& wallet,
    const CScript& bonded_script,
    const uint256& operator_commitment,
    int spend_height,
    bool spendable_only) EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet)
{
    OperatorBondOutputs outputs;

    CoinFilterParams filter;
    filter.only_spendable = spendable_only;
    filter.skip_locked = spendable_only;
    filter.include_immature_coinbase = false;
    filter.include_locked_quantum_stake_outputs = true;

    const std::vector<COutput> coins = spendable_only
        ? AvailableCoins(wallet, nullptr, std::nullopt, filter).All()
        : AvailableCoinsListUnspent(wallet, nullptr, filter).All();

    for (const COutput& out : coins) {
        if (out.txout.nValue <= 0) continue;
        if (out.txout.scriptPubKey == bonded_script) {
            outputs.bonded_amount += out.txout.nValue;
            ++outputs.bonded_outputs;
            if (spendable_only) outputs.bonded_outpoints.push_back(out.outpoint);
            outputs.records.push_back({out.outpoint, out.txout.nValue, out.depth, out.spendable, "bonded", 0});
            continue;
        }

        const auto tier = GetQuantumStakeTierProgram(out.txout.scriptPubKey);
        if (!tier || !tier->IsUnbonding() || tier->cold_stake || tier->commitment != operator_commitment) continue;

        outputs.unbonding_amount += out.txout.nValue;
        ++outputs.unbonding_outputs;
        if (tier->unlock_height <= static_cast<uint32_t>(std::max(0, spend_height))) {
            outputs.withdrawable_amount += out.txout.nValue;
            ++outputs.withdrawable_outputs;
            if (spendable_only) outputs.withdrawable_outpoints.push_back(out.outpoint);
            outputs.records.push_back({out.outpoint, out.txout.nValue, out.depth, out.spendable, "withdrawable", tier->unlock_height});
        } else if (outputs.next_unlock_height == 0 || tier->unlock_height < outputs.next_unlock_height) {
            outputs.next_unlock_height = tier->unlock_height;
            outputs.records.push_back({out.outpoint, out.txout.nValue, out.depth, out.spendable, "unbonding", tier->unlock_height});
        } else {
            outputs.records.push_back({out.outpoint, out.txout.nValue, out.depth, out.spendable, "unbonding", tier->unlock_height});
        }
    }
    return outputs;
}

std::vector<WalletQuantumStakeOutputInfo> ListTieredStakeOutputs(
    const CWallet& wallet,
    const std::string& address,
    bool require_operator_lock)
{
    std::vector<WalletQuantumStakeOutputInfo> result;
    CTxDestination dest;
    const auto tier = DecodeTieredStakeAddress(address, dest, require_operator_lock);
    if (!tier) return result;

    TRY_LOCK(::cs_main, main_lock);
    if (!main_lock) return result;
    TRY_LOCK(wallet.cs_wallet, wallet_lock);
    if (!wallet_lock) return result;
    const auto key_info = wallet.GetQuantumKeyInfo(dest);
    if (!key_info) return result;

    const int current_height = wallet.GetLastBlockHeight();
    const int spend_height = current_height + 1;
    const OperatorBondOutputs outputs = ScanOperatorBondOutputs(
        wallet,
        GetScriptForDestination(dest),
        tier->commitment,
        spend_height,
        /*spendable_only=*/false);

    result.reserve(outputs.records.size());
    for (const OperatorBondOutputs::Record& record : outputs.records) {
        WalletQuantumStakeOutputInfo info;
        info.txid = record.outpoint.hash.GetHex();
        info.vout = record.outpoint.n;
        info.address = address;
        info.amount = record.amount;
        info.depth = record.depth;
        info.state = record.state;
        info.unlock_height = record.unlock_height;
        info.spendable = record.spendable;
        result.push_back(std::move(info));
    }
    return result;
}

std::vector<LocalOperatorBondCandidate> FindWalletOperatorBondCandidates(const CWallet& wallet)
{
    struct OperatorAddress
    {
        std::string address;
        std::vector<unsigned char> staking_pubkey;
    };

    std::vector<OperatorAddress> operator_addresses;
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        const auto infos = wallet.ListQuantumKeyInfos();
        operator_addresses.reserve(infos.size());
        for (const QuantumKeyInfo& info : infos) {
            const WalletQuantumAddressInfo address_info = MakeWalletQuantumAddressInfo(wallet, info);
            if (!address_info.tiered ||
                address_info.unbonding_blocks != OPERATOR_COMMITMENT_BLOCKS ||
                info.public_key.size() != ML_DSA::PUBLICKEY_BYTES) {
                continue;
            }
            operator_addresses.push_back({address_info.address, info.public_key});
        }
    }

    std::vector<LocalOperatorBondCandidate> candidates;
    for (const OperatorAddress& operator_address : operator_addresses) {
        const std::vector<WalletQuantumStakeOutputInfo> outputs =
            ListTieredStakeOutputs(wallet, operator_address.address, /*require_operator_lock=*/true);
        for (const WalletQuantumStakeOutputInfo& output : outputs) {
            if (output.state != "bonded" || output.amount <= 0) continue;
            candidates.push_back({
                operator_address.staking_pubkey,
                COutPoint{uint256S(output.txid), output.vout}});
        }
    }
    return candidates;
}

std::map<uint256, std::vector<node::QuantumPoolClaim>> FindWalletQuantumPoolClaims(const CWallet& wallet)
{
    std::map<uint256, std::vector<node::QuantumPoolClaim>> claims_by_operator;

    LOCK2(::cs_main, wallet.cs_wallet);
    CoinFilterParams filter;
    filter.only_spendable = false;
    filter.skip_locked = false;
    filter.include_immature_coinbase = false;
    const std::vector<COutput> coins = AvailableCoinsListUnspent(wallet, nullptr, filter).All();

    for (const COutput& out : coins) {
        if (out.txout.nValue <= 0) continue;

        int witness_version{0};
        std::vector<unsigned char> witness_program;
        if (!out.txout.scriptPubKey.IsWitnessProgram(witness_version, witness_program) ||
            !IsQuantumColdStakeWitnessProgram(witness_version, witness_program)) {
            continue;
        }

        const auto info = wallet.GetQuantumColdStakeDelegationInfo(witness_program);
        if (!info) continue;

        node::QuantumPoolClaim claim;
        claim.outpoint = out.outpoint;
        claim.staker_pubkey_hash = info->staker_pubkey_hash;
        claim.owner_pubkey_hash = info->owner_pubkey_hash;

        if (const auto tier = GetQuantumStakeTierProgram(out.txout.scriptPubKey); tier && tier->tiered && tier->cold_stake) {
            claim.tiered = true;
            claim.state = tier->state;
            claim.unbonding_blocks = tier->unbonding_blocks;
            claim.unlock_height = tier->unlock_height;
        }

        claims_by_operator[claim.staker_pubkey_hash].push_back(std::move(claim));
    }

    return claims_by_operator;
}

bool FindTieredStakeRecord(const OperatorBondOutputs& outputs, const COutPoint& outpoint, OperatorBondOutputs::Record& record)
{
    const auto it = std::find_if(outputs.records.begin(), outputs.records.end(), [&](const OperatorBondOutputs::Record& candidate) {
        return candidate.outpoint == outpoint;
    });
    if (it == outputs.records.end()) return false;
    record = *it;
    return true;
}

void KeepOnlySelectedTieredStakeOutput(OperatorBondOutputs& outputs, const OperatorBondOutputs::Record& selected)
{
    outputs.bonded_amount = 0;
    outputs.bonded_outputs = 0;
    outputs.bonded_outpoints.clear();
    outputs.unbonding_amount = 0;
    outputs.unbonding_outputs = 0;
    outputs.withdrawable_amount = 0;
    outputs.withdrawable_outputs = 0;
    outputs.withdrawable_outpoints.clear();
    outputs.next_unlock_height = 0;

    if (selected.state == "bonded") {
        outputs.bonded_amount = selected.amount;
        outputs.bonded_outputs = 1;
        outputs.bonded_outpoints.push_back(selected.outpoint);
    } else if (selected.state == "withdrawable") {
        outputs.unbonding_amount = selected.amount;
        outputs.unbonding_outputs = 1;
        outputs.withdrawable_amount = selected.amount;
        outputs.withdrawable_outputs = 1;
        outputs.withdrawable_outpoints.push_back(selected.outpoint);
    } else if (selected.state == "unbonding") {
        outputs.unbonding_amount = selected.amount;
        outputs.unbonding_outputs = 1;
        outputs.next_unlock_height = selected.unlock_height;
    }
}

bool FindColdStakeDelegationRecord(const ColdStakeDelegationOutputs& outputs, const COutPoint& outpoint, ColdStakeDelegationOutputs::Record& record)
{
    const auto it = std::find_if(outputs.records.begin(), outputs.records.end(), [&](const ColdStakeDelegationOutputs::Record& candidate) {
        return candidate.outpoint == outpoint;
    });
    if (it == outputs.records.end()) return false;
    record = *it;
    return true;
}

bool HasColdStakeDelegationOutpoint(const ColdStakeDelegationOutputs& outputs, const COutPoint& outpoint)
{
    return std::any_of(outputs.records.begin(), outputs.records.end(), [&](const ColdStakeDelegationOutputs::Record& candidate) {
        return candidate.outpoint == outpoint;
    });
}

void KeepOnlySelectedColdStakeDelegationOutput(ColdStakeDelegationOutputs& outputs, const ColdStakeDelegationOutputs::Record& selected)
{
    outputs.amount = selected.amount;
    outputs.outputs = 1;
    if (selected.depth > 0) {
        outputs.confirmed_amount = selected.amount;
        outputs.confirmed_outputs = 1;
        outputs.unconfirmed_amount = 0;
        outputs.unconfirmed_outputs = 0;
    } else {
        outputs.confirmed_amount = 0;
        outputs.confirmed_outputs = 0;
        outputs.unconfirmed_amount = selected.amount;
        outputs.unconfirmed_outputs = 1;
    }
    outputs.spendable_amount = selected.amount;
    outputs.spendable_outputs = 1;
    outputs.spendable_outpoints = {selected.outpoint};
    outputs.records = {selected};
    outputs.spendable_records = {selected};
}

WalletQuantumOperatorBondInfo MakeWalletTieredStakeBondInfo(const CWallet& wallet, const std::string& address, bool require_operator_lock)
{
    WalletQuantumOperatorBondInfo result;
    CTxDestination dest;
    const auto tier = DecodeTieredStakeAddress(address, dest, require_operator_lock);
    if (!tier) return result;

    TRY_LOCK(::cs_main, main_lock);
    if (!main_lock) {
        result.available = false;
        return result;
    }
    TRY_LOCK(wallet.cs_wallet, wallet_lock);
    if (!wallet_lock) {
        result.available = false;
        return result;
    }
    const auto key_info = wallet.GetQuantumKeyInfo(dest);
    if (!key_info) return result;

    const int current_height = wallet.GetLastBlockHeight();
    const int spend_height = current_height + 1;
    const OperatorBondOutputs outputs = ScanOperatorBondOutputs(
        wallet,
        GetScriptForDestination(dest),
        tier->commitment,
        spend_height,
        /*spendable_only=*/false);

    result.valid_operator_address = true;
    result.current_height = current_height;
    result.bonded_amount = outputs.bonded_amount;
    result.bonded_outputs = outputs.bonded_outputs;
    result.unbonding_amount = outputs.unbonding_amount;
    result.unbonding_outputs = outputs.unbonding_outputs;
    result.withdrawable_amount = outputs.withdrawable_amount;
    result.withdrawable_outputs = outputs.withdrawable_outputs;
    result.next_unlock_height = outputs.next_unlock_height;
    return result;
}

WalletQuantumOperatorBondInfo MakeWalletOperatorBondInfo(const CWallet& wallet, const std::string& operator_address)
{
    return MakeWalletTieredStakeBondInfo(wallet, operator_address, /*require_operator_lock=*/true);
}

util::Result<WalletQuantumOperatorBondTx> FundTieredStakeAddress(
    CWallet& wallet,
    const std::string& address,
    CAmount amount,
    bool require_operator_lock,
    std::string comment,
    bool allow_new_quantum_key)
{
    if (!allow_new_quantum_key) {
        return util::Error{_("Explicit allow_new_quantum_key=true consent is required because funding creates a new non-HD ML-DSA change key. No key or transaction was created. Back up the wallet after retrying.")};
    }
    if (!MoneyRange(amount) || amount <= 0) {
        return util::Error{_("Error: Funding amount must be positive")};
    }

    CTxDestination dest;
    const auto tier = DecodeTieredStakeAddress(address, dest, require_operator_lock);
    if (!tier) return util::Error{util::ErrorString(tier)};

    CTransactionRef tx;
    CAmount fee{0};
    std::optional<CTxDestination> created_key;
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        bilingual_str spend_error;
        if (!CanCreateSignedSpend(wallet, spend_error)) return util::Error{spend_error};
        const CBlockIndex* tip = wallet.chain().chainman().ActiveChain().Tip();
        if (!tip || !IsQuantumWitnessSpendActive(
                Params().GetConsensus(), tip->GetMedianTimePast(), tip->nHeight + 1)) {
            return util::Error{_("Error: Quantum staking outputs cannot be funded until the post-Gold-Rush migration phase")};
        }
        if (!IsQuantumStakeTiersActive(Params().GetConsensus(), tip->GetMedianTimePast(), tip->nHeight + 1)) {
            return util::Error{_("Error: Tiered quantum staking outputs cannot be funded before tiered staking activation")};
        }
        if (!wallet.GetQuantumKeyInfo(dest)) {
            return util::Error{_("Error: Staking address is not backed by this wallet")};
        }

        std::vector<CRecipient> recipients{{dest, amount, /*fSubtractFeeFromAmount=*/false}};
        CCoinControl coin_control;
        coin_control.m_input_family = CCoinControl::InputFamily::QUANTUM_MIGRATION;
        coin_control.m_allow_other_inputs = true;
        auto change_dest = wallet.GetNewQuantumChangeDestination();
        if (!change_dest) return util::Error{util::ErrorString(change_dest)};
        created_key = *change_dest;
        coin_control.destChange = *change_dest;
        int change_pos = RANDOM_CHANGE_POSITION;
        auto res = CreateTransaction(wallet, recipients, change_pos, coin_control, /*sign=*/true);
        if (!res) return util::Error{DurableQuantumKeyFailure(*created_key, "Staking address funding", util::ErrorString(res))};
        tx = res->tx;
        fee = res->fee;
    }

    mapValue_t map_value;
    map_value["comment"] = std::move(comment);
    if (auto committed = CommitWalletTransactionOrError(wallet, tx, std::move(map_value), "staking address funding"); !committed) {
        return util::Error{DurableQuantumKeyFailure(*created_key, "Staking address funding", util::ErrorString(committed))};
    }

    WalletQuantumOperatorBondTx result;
    result.txid = tx->GetHash().GetHex();
    result.address = address;
    result.amount = amount;
    result.fee = fee;
    result.warning = "A new non-HD ML-DSA quantum change key was created during transaction construction. Back up this wallet now; an older backup cannot recover it.";
    return result;
}

util::Result<WalletQuantumOperatorBondTx> WithdrawTieredStakeAddress(
    CWallet& wallet,
    const std::string& address,
    bool require_operator_lock,
    const std::string& unbonding_label,
    const std::string& withdrawal_label,
    std::string unbonding_comment,
    std::string withdrawal_comment,
    std::optional<COutPoint> selected_outpoint,
    bool allow_all_outputs,
    bool allow_new_quantum_key)
{
    if (!allow_new_quantum_key) {
        return util::Error{_("Explicit allow_new_quantum_key=true consent is required because unbonding or withdrawal creates a new non-HD ML-DSA change or destination key. No key or transaction was created. Back up the wallet after retrying.")};
    }
    CTxDestination dest;
    const auto tier = DecodeTieredStakeAddress(address, dest, require_operator_lock);
    if (!tier) return util::Error{util::ErrorString(tier)};

    CTransactionRef tx;
    CAmount amount{0};
    CAmount fee{0};
    uint32_t unlock_height{0};
    std::string destination_address;
    std::string comment;
    bool started_unbonding{false};
    bool completed_withdrawal{false};
    std::optional<CTxDestination> created_key;
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        bilingual_str spend_error;
        if (!CanCreateSignedSpend(wallet, spend_error)) return util::Error{spend_error};

        const auto stake_key = wallet.GetQuantumKeyInfo(dest);
        if (!stake_key) {
            return util::Error{_("Error: Staking address is not backed by this wallet")};
        }

        const int current_height = wallet.GetLastBlockHeight();
        const int spend_height = current_height + 1;
        OperatorBondOutputs outputs = ScanOperatorBondOutputs(
            wallet,
            GetScriptForDestination(dest),
            tier->commitment,
            spend_height,
            /*spendable_only=*/true);

        if (selected_outpoint) {
            OperatorBondOutputs::Record selected_record;
            if (!FindTieredStakeRecord(outputs, *selected_outpoint, selected_record)) {
                const OperatorBondOutputs all_outputs = ScanOperatorBondOutputs(
                    wallet,
                    GetScriptForDestination(dest),
                    tier->commitment,
                    spend_height,
                    /*spendable_only=*/false);
                if (FindTieredStakeRecord(all_outputs, *selected_outpoint, selected_record)) {
                    return util::Error{_("Error: Selected staking output is not currently spendable")};
                }
                return util::Error{_("Error: Selected staking output was not found for this address")};
            }
            KeepOnlySelectedTieredStakeOutput(outputs, selected_record);
        } else if (outputs.bonded_outpoints.size() + outputs.withdrawable_outpoints.size() > 1 && !allow_all_outputs) {
            return util::Error{_("Error: Multiple spendable staking outputs were found. Specify an outpoint, or pass all=true to act on every spendable output for this address.")};
        }

        CCoinControl coin_control;
        int change_pos = RANDOM_CHANGE_POSITION;
        std::vector<CRecipient> recipients;

        if (!outputs.bonded_outpoints.empty()) {
            for (const COutPoint& outpoint : outputs.bonded_outpoints) {
                coin_control.Select(outpoint);
            }
            coin_control.m_allow_other_inputs = false;
            coin_control.m_exclude_generated_quantum_inputs = true;
            coin_control.m_include_locked_quantum_stake_outputs = true;
            const CCoinsViewCache& view = wallet.chain().chainman().ActiveChainstate().CoinsTip();
            const SafeFeeInputSummary fee_inputs = SelectSafeUnbondingFeeInputs(
                wallet,
                view,
                coin_control,
                wallet.m_default_max_tx_fee,
                /*allow_legacy=*/true);
            if (fee_inputs.inputs == 0) {
                return util::Error{_("Error: No safe fee input is available to start unbonding. Add a small ordinary legacy or direct quantum UTXO, then try again.")};
            }

            auto change_dest = wallet.GetNewQuantumChangeDestination();
            if (!change_dest) return util::Error{util::ErrorString(change_dest)};
            created_key = *change_dest;
            coin_control.destChange = *change_dest;

            unlock_height = static_cast<uint32_t>(std::max(0, spend_height + int{tier->unbonding_blocks}));
            const std::vector<unsigned char> unbonding_program = QuantumTieredMigrationProgramForPubkey(
                stake_key->public_key,
                QUANTUM_TIERED_STATE_UNBONDING,
                tier->unbonding_blocks,
                unlock_height);
            const CTxDestination unbonding_dest = WitnessUnknown{QUANTUM_MIGRATION_WITNESS_VERSION, unbonding_program};
            wallet.SetAddressBook(unbonding_dest, unbonding_label, AddressPurpose::RECEIVE);

            amount = outputs.bonded_amount;
            destination_address = EncodeDestination(unbonding_dest);
            recipients.push_back({unbonding_dest, amount, /*fSubtractFeeFromAmount=*/false});
            comment = std::move(unbonding_comment);
            started_unbonding = true;
        } else if (!outputs.withdrawable_outpoints.empty()) {
            for (const COutPoint& outpoint : outputs.withdrawable_outpoints) {
                coin_control.Select(outpoint);
            }
            coin_control.m_allow_other_inputs = false;
            coin_control.m_input_family = CCoinControl::InputFamily::QUANTUM;
            coin_control.m_include_locked_quantum_stake_outputs = true;

            auto withdraw_dest = wallet.GetNewQuantumDestination(withdrawal_label);
            if (!withdraw_dest) return util::Error{util::ErrorString(withdraw_dest)};
            created_key = *withdraw_dest;
            coin_control.destChange = *withdraw_dest;

            amount = outputs.withdrawable_amount;
            destination_address = EncodeDestination(*withdraw_dest);
            recipients.push_back({*withdraw_dest, amount, /*fSubtractFeeFromAmount=*/true});
            comment = std::move(withdrawal_comment);
            completed_withdrawal = true;
        } else if (outputs.unbonding_outputs > 0 && outputs.next_unlock_height > 0) {
            return util::Error{strprintf(_("Error: Staking funds are unbonding and cannot be withdrawn until block %u"), outputs.next_unlock_height)};
        } else {
            return util::Error{_("Error: No spendable bonded or matured unbonding staking funds found for this address")};
        }

        auto res = CreateTransaction(wallet, recipients, change_pos, coin_control, /*sign=*/true);
        if (!res) return util::Error{DurableQuantumKeyFailure(*created_key, "Staking address withdrawal", util::ErrorString(res))};
        tx = res->tx;
        fee = res->fee;
    }

    mapValue_t map_value;
    map_value["comment"] = std::move(comment);
    if (auto committed = CommitWalletTransactionOrError(wallet, tx, std::move(map_value), "staking address withdrawal"); !committed) {
        return util::Error{DurableQuantumKeyFailure(*created_key, "Staking address withdrawal", util::ErrorString(committed))};
    }

    WalletQuantumOperatorBondTx result;
    result.txid = tx->GetHash().GetHex();
    result.address = destination_address;
    result.amount = amount;
    result.fee = fee;
    result.unlock_height = unlock_height;
    result.started_unbonding = started_unbonding;
    result.completed_withdrawal = completed_withdrawal;
    result.warning = started_unbonding
        ? "A new non-HD ML-DSA quantum change key was created while starting unbonding. Back up this wallet now; an older backup cannot recover it."
        : "A new non-HD ML-DSA quantum withdrawal key was created. Back up this wallet now; an older backup cannot recover it.";
    return result;
}

util::Result<WalletQuantumOperatorBondTx> FundColdStakeDelegationAddress(
    CWallet& wallet,
    const std::string& address,
    CAmount amount,
    bool allow_goldrush_migration,
    bool allow_new_quantum_key)
{
    if (!allow_new_quantum_key) {
        return util::Error{_("Explicit allow_new_quantum_key=true consent is required because delegation funding creates a new non-HD ML-DSA change key. No key or transaction was created. Back up the wallet after retrying.")};
    }
    (void)allow_goldrush_migration; // Retained for RPC/API compatibility; no forced first-move workflow exists.
    if (!MoneyRange(amount) || amount <= 0) {
        return util::Error{_("Error: Delegation funding amount must be positive")};
    }

    CTransactionRef tx;
    CAmount fee{0};
    std::optional<CTxDestination> created_key;
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        bilingual_str spend_error;
        if (!CanCreateSignedSpend(wallet, spend_error)) return util::Error{spend_error};
        const CBlockIndex* tip = wallet.chain().chainman().ActiveChain().Tip();
        if (!tip || !IsQuantumWitnessSpendActive(
                Params().GetConsensus(), tip->GetMedianTimePast(), tip->nHeight + 1)) {
            return util::Error{_("Error: Quantum cold-stake outputs cannot be funded until the post-Gold-Rush migration phase")};
        }

        CTxDestination dest;
        const auto delegation = DecodeWalletColdStakeDelegationAddress(wallet, address, dest);
        if (!delegation) return util::Error{util::ErrorString(delegation)};
        const std::optional<QuantumStakeTierProgram> tier = GetQuantumStakeTierProgram(GetScriptForDestination(dest));
        if (tier && tier->tiered && !IsQuantumStakeTiersActive(
                Params().GetConsensus(), tip->GetMedianTimePast(), tip->nHeight + 1)) {
            return util::Error{_("Error: Tiered quantum cold-stake outputs cannot be funded before tiered staking activation")};
        }
        if (!delegation->has_owner_key) {
            return util::Error{_("Error: Wallet must hold the owner key before funding a cold-stake delegation")};
        }

        const CCoinsViewCache& view = wallet.chain().chainman().ActiveChainstate().CoinsTip();
        const node::QuantumPoolShare share = node::ComputeQuantumPoolShare(
            view,
            delegation->staker_pubkey_hash,
            node::GetQuantumPoolClaims(delegation->staker_pubkey_hash));
        const bool would_exceed_cap = node::WouldQuantumPoolExceedCap(
            share.total_coldstake,
            share.operator_share.verified_value,
            amount);
        const bool cap_filter_unlocked = would_exceed_cap &&
            !node::HasQuantumPoolUnderCapCandidate(view, amount, {delegation->staker_pubkey_hash});
        if (would_exceed_cap && !cap_filter_unlocked) {
            return util::Error{strprintf(
                _("Error: This delegation would push the selected cold-staking node above the 20%% wallet-policy cap. Select an under-cap verified node or retry only if every verified node is over cap. Current selected node share: %d bps."),
                node::QuantumPoolShareBps(share.operator_share.verified_value, share.total_coldstake))};
        }

        CCoinControl coin_control;
        coin_control.m_input_family = CCoinControl::InputFamily::QUANTUM_MIGRATION;
        coin_control.m_exclude_generated_quantum_inputs = true;
        coin_control.m_allow_other_inputs = true;

        const ColdStakeFundingInputs funding = ScanColdStakeFundingInputs(wallet, view);
        if (funding.eligible_inputs == 0) {
            return util::Error{_("Error: No spendable direct quantum outputs are available to fund this cold-stake delegation. Gold Rush payouts become ordinary direct quantum funds after Gold Rush and normal maturity.")};
        }
        if (funding.eligible_amount <= amount) {
            bilingual_str error = strprintf(
                _("Error: Insufficient direct quantum balance to fund this delegation and its fee. Available direct quantum balance: %s."),
                FormatMoney(funding.eligible_amount));
            return util::Error{error};
        }

        auto change_dest = wallet.GetNewQuantumChangeDestination();
        if (!change_dest) return util::Error{util::ErrorString(change_dest)};
        created_key = *change_dest;

        std::vector<CRecipient> recipients{{dest, amount, /*fSubtractFeeFromAmount=*/false}};
        coin_control.destChange = *change_dest;
        int change_pos = RANDOM_CHANGE_POSITION;
        auto res = CreateTransaction(wallet, recipients, change_pos, coin_control, /*sign=*/true);
        if (!res) {
            bilingual_str error = strprintf(
                _("Error: Unable to fund cold-stake delegation from direct quantum outputs. %s"),
                util::ErrorString(res).original);
            return util::Error{DurableQuantumKeyFailure(*created_key, "Cold-stake delegation funding", error)};
        }
        tx = res->tx;
        fee = res->fee;
    }

    mapValue_t map_value;
    map_value["comment"] = "Blackcoin quantum cold-stake delegation funding";
    if (auto committed = CommitWalletTransactionOrError(wallet, tx, std::move(map_value), "cold-stake delegation funding"); !committed) {
        return util::Error{DurableQuantumKeyFailure(*created_key, "Cold-stake delegation funding", util::ErrorString(committed))};
    }

    WalletQuantumOperatorBondTx result;
    result.txid = tx->GetHash().GetHex();
    result.address = address;
    result.amount = amount;
    result.fee = fee;
    result.warning = "A new non-HD ML-DSA quantum change key was created during delegation funding. Back up this wallet now; an older backup cannot recover it.";
    return result;
}

util::Result<WalletQuantumOperatorBondTx> WithdrawColdStakeDelegationAddress(
    CWallet& wallet,
    const std::string& address,
    std::optional<COutPoint> selected_outpoint,
    bool allow_all_outputs,
    bool allow_new_quantum_key)
{
    if (!allow_new_quantum_key) {
        return util::Error{_("Explicit allow_new_quantum_key=true consent is required because delegation unbonding or withdrawal creates a new non-HD ML-DSA change or destination key. No key or transaction was created. Back up the wallet after retrying.")};
    }
    CTransactionRef tx;
    CAmount amount{0};
    CAmount fee{0};
    uint32_t unlock_height{0};
    std::string destination_address;
    bool started_unbonding{false};
    bool completed_withdrawal{false};
    std::optional<CTxDestination> created_key;
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        bilingual_str spend_error;
        if (!CanCreateSignedSpend(wallet, spend_error)) return util::Error{spend_error};

        CTxDestination dest;
        const auto delegation = DecodeWalletColdStakeDelegationAddress(wallet, address, dest);
        if (!delegation) return util::Error{util::ErrorString(delegation)};
        if (!delegation->has_owner_key) {
            return util::Error{_("Error: Wallet does not hold the owner key for this cold-stake delegation")};
        }

        ColdStakeDelegationOutputs outputs = ScanColdStakeDelegationOutputs(
            wallet,
            GetScriptForDestination(dest),
            /*spendable_only=*/true);
        if (outputs.spendable_outpoints.empty()) {
            return util::Error{_("Error: No spendable cold-stake delegation funds found for this address")};
        }
        if (selected_outpoint) {
            ColdStakeDelegationOutputs::Record selected_record;
            if (!FindColdStakeDelegationRecord(outputs, *selected_outpoint, selected_record)) {
                const ColdStakeDelegationOutputs all_outputs = ScanColdStakeDelegationOutputs(
                    wallet,
                    GetScriptForDestination(dest),
                    /*spendable_only=*/false);
                if (HasColdStakeDelegationOutpoint(all_outputs, *selected_outpoint)) {
                    return util::Error{_("Error: Selected cold-stake delegation output is not currently spendable")};
                }
                return util::Error{_("Error: Selected cold-stake delegation output was not found for this address")};
            }
            KeepOnlySelectedColdStakeDelegationOutput(outputs, selected_record);
        } else if (outputs.spendable_outpoints.size() > 1 && !allow_all_outputs) {
            return util::Error{_("Error: Multiple spendable cold-stake delegation outputs were found. Specify an outpoint, or pass all=true to act on every spendable output for this address.")};
        }

        CCoinControl coin_control;
        for (const COutPoint& outpoint : outputs.spendable_outpoints) {
            coin_control.Select(outpoint);
        }
        int change_pos = RANDOM_CHANGE_POSITION;

        amount = outputs.spendable_amount;
        std::vector<CRecipient> recipients;
        const int current_height = wallet.GetLastBlockHeight();
        const int spend_height = current_height + 1;

        if (delegation->tiered && delegation->unlock_height == 0) {
            coin_control.m_allow_other_inputs = false;
            coin_control.m_exclude_generated_quantum_inputs = true;
            const CCoinsViewCache& view = wallet.chain().chainman().ActiveChainstate().CoinsTip();
            const SafeFeeInputSummary fee_inputs = SelectSafeUnbondingFeeInputs(
                wallet,
                view,
                coin_control,
                wallet.m_default_max_tx_fee,
                /*allow_legacy=*/true);
            if (fee_inputs.inputs == 0) {
                return util::Error{_("Error: No safe fee input is available to start cold-stake unbonding. Add a small ordinary legacy or direct quantum UTXO, then try again.")};
            }
            auto change_dest = wallet.GetNewQuantumChangeDestination();
            if (!change_dest) return util::Error{util::ErrorString(change_dest)};
            created_key = *change_dest;
            coin_control.destChange = *change_dest;

            unlock_height = static_cast<uint32_t>(std::max(0, spend_height + int{delegation->unbonding_blocks}));
            auto unbonding_dest = wallet.AddQuantumColdStakeDelegationForKeyHashes(
                delegation->staker_pubkey_hash,
                delegation->owner_pubkey_hash,
                "coldstake-delegation-unbonding",
                GetTime(),
                delegation->unbonding_blocks,
                unlock_height,
                QUANTUM_TIERED_STATE_UNBONDING);
            if (!unbonding_dest) {
                return util::Error{DurableQuantumKeyFailure(
                    *created_key,
                    "Cold-stake delegation withdrawal",
                    util::ErrorString(unbonding_dest))};
            }

            destination_address = EncodeDestination(*unbonding_dest);
            recipients.push_back({*unbonding_dest, amount, /*fSubtractFeeFromAmount=*/false});
            started_unbonding = true;
        } else {
            if (delegation->tiered && delegation->unlock_height > static_cast<uint32_t>(std::max(0, spend_height))) {
                return util::Error{strprintf(_("Error: Cold-stake delegation funds are unbonding and cannot be withdrawn until block %u"), delegation->unlock_height)};
            }
            coin_control.m_allow_other_inputs = false;
            coin_control.m_input_family = CCoinControl::InputFamily::QUANTUM;

            auto withdraw_dest = wallet.GetNewQuantumDestination("coldstake-delegation-withdrawal");
            if (!withdraw_dest) return util::Error{util::ErrorString(withdraw_dest)};
            created_key = *withdraw_dest;
            coin_control.destChange = *withdraw_dest;

            destination_address = EncodeDestination(*withdraw_dest);
            recipients.push_back({*withdraw_dest, amount, /*fSubtractFeeFromAmount=*/true});
            completed_withdrawal = true;
        }
        auto res = CreateTransaction(wallet, recipients, change_pos, coin_control, /*sign=*/true);
        if (!res) return util::Error{DurableQuantumKeyFailure(*created_key, "Cold-stake delegation withdrawal", util::ErrorString(res))};
        tx = res->tx;
        fee = res->fee;
    }

    mapValue_t map_value;
    map_value["comment"] = "Blackcoin quantum cold-stake delegation withdrawal";
    if (auto committed = CommitWalletTransactionOrError(wallet, tx, std::move(map_value), "cold-stake delegation withdrawal"); !committed) {
        return util::Error{DurableQuantumKeyFailure(*created_key, "Cold-stake delegation withdrawal", util::ErrorString(committed))};
    }

    WalletQuantumOperatorBondTx result;
    result.txid = tx->GetHash().GetHex();
    result.address = destination_address;
    result.amount = amount;
    result.fee = fee;
    result.unlock_height = unlock_height;
    result.started_unbonding = started_unbonding;
    result.completed_withdrawal = completed_withdrawal;
    result.warning = started_unbonding
        ? "A new non-HD ML-DSA quantum change key was created while starting delegation unbonding. Back up this wallet now; an older backup cannot recover it."
        : "A new non-HD ML-DSA quantum withdrawal key was created. Back up this wallet now; an older backup cannot recover it.";
    return result;
}

namespace {

std::vector<WalletRGBAssetInfo> ListWalletRGBAssets(CWallet& wallet, bool include_spent)
{
    std::vector<WalletRGBAssetInfo> result;
    TRY_LOCK(wallet.cs_wallet, wallet_lock);
    if (!wallet_lock) return result;

    const auto contracts = wallet.ListRGBContracts();
    const auto assignments = wallet.ListRGBAssignments();
    const auto transitions = wallet.ListRGBTransitions();
    const auto transition_proofs = wallet.ListRGBTransitionProofs();

    result.reserve(contracts.size());
    for (const auto& [contract_id, contract] : contracts) {
        WalletRGBAssetInfo asset;
        asset.contract_id = contract_id.GetHex();
        asset.ticker = contract.ticker;
        asset.name = contract.name;
        asset.total_supply = contract.total_supply;
        asset.creation_time = contract.creation_time;
        asset.proof_available = wallet.GetRGBGenesisProof(contract_id).has_value();

        for (const auto& [key, assignment] : assignments) {
            if (key.first != contract_id) continue;
            if (!assignment.spent) {
                if (assignment.amount > std::numeric_limits<uint64_t>::max() - asset.balance) {
                    asset.balance = std::numeric_limits<uint64_t>::max();
                } else {
                    asset.balance += assignment.amount;
                }
            }
            if (include_spent || !assignment.spent) {
                WalletRGBAssignmentInfo entry;
                entry.txid = key.second.hash.GetHex();
                entry.vout = key.second.n;
                entry.amount = assignment.amount;
                entry.spent = assignment.spent;
                entry.creation_time = assignment.creation_time;
                asset.assignments.push_back(std::move(entry));
            }
        }
        for (const auto& [key, transition] : transitions) {
            if (key.first == contract_id) ++asset.transition_count;
        }
        for (const auto& [key, proof] : transition_proofs) {
            if (key.first == contract_id) ++asset.proof_transition_count;
        }
        result.push_back(std::move(asset));
    }
    return result;
}

std::vector<WalletEUTXOStateInfo> ListWalletEUTXOStates(CWallet& wallet, bool include_spent)
{
    std::vector<std::pair<COutPoint, EUTXOStateRecord>> states;
    {
        TRY_LOCK(wallet.cs_wallet, wallet_lock);
        if (!wallet_lock) return {};
        states = wallet.ListEUTXOStates();
    }

    std::map<COutPoint, Coin> coins;
    for (const auto& [outpoint, record] : states) {
        coins.emplace(outpoint, Coin{});
    }
    TRY_LOCK(::cs_main, main_lock);
    if (!main_lock) return {};
    wallet.chain().findCoins(coins);

    std::vector<WalletEUTXOStateInfo> result;
    for (const auto& [outpoint, record] : states) {
        const auto coin_it = coins.find(outpoint);
        const bool spent = coin_it == coins.end() || coin_it->second.IsSpent();
        if (spent && !include_spent) continue;

        WalletEUTXOStateInfo state;
        state.txid = outpoint.hash.GetHex();
        state.vout = outpoint.n;
        state.amount = record.amount;
        state.datum_hex = HexStr(record.datum);
        state.validator_hex = HexStr(record.validator_script);
        state.address = EncodeDestination(WitnessUnknown{EUTXO_WITNESS_VERSION, EUTXOProgramForDatumAndValidator(record.datum, record.validator_script)});
        state.creation_time = record.creation_time;
        state.spent = spent;
        result.push_back(std::move(state));
    }
    return result;
}

WalletDemurrageInfo GetWalletDemurrageInfo(CWallet& wallet)
{
    WalletDemurrageInfo info;
    if (!wallet.HaveChain()) {
        info.available = false;
        return info;
    }

    TRY_LOCK(::cs_main, main_lock);
    if (!main_lock) {
        info.available = false;
        return info;
    }
    TRY_LOCK(wallet.cs_wallet, wallet_lock);
    if (!wallet_lock) {
        info.available = false;
        return info;
    }

    const Consensus::Params& consensus = Params().GetConsensus();
    const CBlockIndex* tip = wallet.chain().getTip();
    info.tip_height = tip ? tip->nHeight : -1;
    info.evaluation_height = info.tip_height >= 0 ? info.tip_height + 1 : 0;
    info.evaluation_time = tip ? tip->GetMedianTimePast() : 0;
    info.demurrage_active = consensus.IsDemurrageActive(info.evaluation_height, info.evaluation_time);
    info.demurrage_activation_height = consensus.nDemurrageActivationHeight;
    info.demurrage_effective_activation_height = consensus.EffectiveDemurrageActivationHeight();
    info.demurrage_height_guard_satisfied = info.evaluation_height >= consensus.EffectiveDemurrageActivationHeight();
    info.demurrage_post_migration_guard_satisfied =
        consensus.IsMigrationEndScheduled() && consensus.MigrationDeadlinePassed(info.evaluation_time, info.evaluation_height);
    info.wallet_staking_enabled = wallet.m_enabled_staking.load();

    CoinsResult available = AvailableCoinsListUnspent(wallet);
    std::map<COutPoint, Coin> chain_coins;
    std::vector<COutput> quantum_outputs;
    for (const COutput& out : available.All()) {
        if (!IsQuantumMigrationScript(out.txout.scriptPubKey)) continue;
        CTxDestination dest;
        if (!ExtractDestination(out.txout.scriptPubKey, dest) || !wallet.GetQuantumKeyInfo(dest).has_value()) continue;
        chain_coins.emplace(out.outpoint, Coin{});
        quantum_outputs.push_back(out);
    }
    wallet.chain().findCoins(chain_coins);

    // Wallet records can outlive a chainstate entry. Do not narrow an
    // untrusted local timestamp when reconstructing the temporary Coin used
    // for lifecycle reporting: UTXO provenance is a uint32_t block field.
    for (const COutput& out : quantum_outputs) {
        const auto coin_it = chain_coins.find(out.outpoint);
        const bool chainstate_backed = coin_it != chain_coins.end() && !coin_it->second.IsSpent();
        if (!chainstate_backed &&
            (out.time < 0 || out.time > static_cast<int64_t>(std::numeric_limits<uint32_t>::max()))) {
            info.available = false;
            return info;
        }
    }

    const CCoinsViewCache& view = wallet.chain().getCoinsTip();
    info.quantum_outputs = static_cast<int>(quantum_outputs.size());
    info.outputs.reserve(quantum_outputs.size());

    for (const COutput& out : quantum_outputs) {
        CTxDestination dest;
        if (!ExtractDestination(out.txout.scriptPubKey, dest)) continue;

        const auto coin_it = chain_coins.find(out.outpoint);
        const bool chainstate_backed = coin_it != chain_coins.end() && !coin_it->second.IsSpent();
        Coin coin = chainstate_backed
            ? coin_it->second
            : Coin{out.txout, out.depth > 0 ? info.tip_height - out.depth + 1 : info.evaluation_height, false, false, static_cast<uint32_t>(out.time)};
        const std::optional<Consensus::DemurrageAttestationState> latest_attestation =
            Consensus::LatestDemurrageAttestationStateForScript(view, out.txout.scriptPubKey);
        const Consensus::DemurrageEvaluation eval = Consensus::EvaluateDemurrage(
            coin, consensus, info.evaluation_height, info.evaluation_time,
            latest_attestation ? std::optional<int>{latest_attestation->height} : std::nullopt,
            latest_attestation ? std::optional<int>{static_cast<int>(latest_attestation->coverage_start_height)} : std::nullopt);
        const bool attestation_due = info.demurrage_active &&
                                     !eval.locked &&
                                     eval.inactive_blocks >= consensus.DemurrageAutoAttestBlocks();

        WalletDemurrageOutputInfo output;
        output.txid = out.outpoint.hash.GetHex();
        output.vout = out.outpoint.n;
        output.address = EncodeDestination(dest);
        output.depth = out.depth;
        output.coin_height = coin.nHeight;
        output.latest_attestation_height = latest_attestation
            ? std::optional<int>{latest_attestation->height}
            : std::nullopt;
        output.inactive_blocks = eval.inactive_blocks;
        output.remaining_ppm = eval.remaining_ppm;
        output.nominal_amount = eval.nominal_value;
        output.effective_amount = eval.effective_value;
        output.burned_if_spent_amount = eval.burned_value;
        output.locked = eval.locked;
        output.attestation_due = attestation_due;
        output.blocks_until_decay = std::max(0, consensus.DemurrageGraceBlocks() - eval.inactive_blocks);
        output.blocks_until_lock = std::max(0, consensus.DemurrageZeroBlocks() - eval.inactive_blocks);
        if (!info.demurrage_active) {
            output.action = "none: demurrage is inactive";
        } else if (eval.locked) {
            output.action = "locked: this output can no longer be spent";
        } else if (attestation_due && info.wallet_staking_enabled) {
            output.action = "attestation due: automatic attempt also requires normal unlock and a safe fee input";
        } else if (attestation_due) {
            output.action = "manual attestation recommended";
        } else if (eval.burned_value > 0) {
            output.action = "full-sweep spend recommended";
        } else {
            output.action = "none";
        }

        info.nominal_amount += eval.nominal_value;
        info.effective_amount += eval.effective_value;
        info.burned_if_spent_amount += eval.burned_value;
        if (eval.burned_value > 0) ++info.decaying_outputs;
        if (eval.locked) ++info.locked_outputs;
        if (attestation_due) ++info.attestation_due_outputs;
        info.outputs.push_back(std::move(output));
    }

    return info;
}

} // namespace

util::Result<WalletQuantumActionTx> CreateQuantumMigrationSweep(
    CWallet& wallet,
    bool goldrush_rewards_only,
    bool allow_goldrush_epoch,
    const std::string& destination_label,
    const std::string& comment_override,
    bool allow_new_quantum_key)
{
    if (!allow_new_quantum_key) {
        return util::Error{_("This action creates a new non-HD ML-DSA destination key. Retry with allow_new_quantum_key=true only after authorizing key creation, then back up the wallet. No key or transaction was created.")};
    }
    // Check the current lifecycle before reserving a new destination. Repeat
    // the check under the transaction-creation locks below to close the race
    // if the active tip changes while the key is being generated.
    {
        LOCK(::cs_main);
        if (const auto error = QuantumMigrationSweepPhaseError(wallet, goldrush_rewards_only)) {
            return util::Error{*error};
        }
    }

    const std::string label = !destination_label.empty()
        ? destination_label
        : (goldrush_rewards_only ? "goldrush-consolidation-gui" : "migration-gui");
    auto destination_result = wallet.GetNewQuantumDestination(label);
    if (!destination_result) return util::Error{util::ErrorString(destination_result)};
    const CTxDestination destination = *destination_result;
    const CScript destination_script = GetScriptForDestination(destination);
    const std::string destination_address = EncodeDestination(destination);
    const std::string action_name = goldrush_rewards_only
        ? "Gold Rush reward consolidation"
        : "Quantum migration";

    CTransactionRef tx;
    CAmount eligible_amount{0};
    CAmount effective_eligible_amount{0};
    CAmount burned_amount{0};
    CAmount fee{0};
    unsigned int eligible_inputs{0};
    std::string comment;
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        bilingual_str spend_error;
        if (!CanCreateSignedSpend(wallet, spend_error)) {
            return util::Error{DurableQuantumKeyFailure(destination, action_name, spend_error)};
        }
        if (wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)) {
            return util::Error{DurableQuantumKeyFailure(
                destination,
                action_name,
                _("Error: Private keys are disabled for this wallet"))};
        }

        if (const auto error = QuantumMigrationSweepPhaseError(wallet, goldrush_rewards_only)) {
            return util::Error{DurableQuantumKeyFailure(destination, action_name, *error)};
        }
        const Consensus::Params& consensus = Params().GetConsensus();
        const CBlockIndex* tip = wallet.chain().getTip();
        Assume(tip != nullptr);
        const int64_t mtp = tip->GetMedianTimePast();
        const int next_height = tip->nHeight + 1;

        if (!wallet.GetQuantumKeyInfo(destination).has_value()) {
            return util::Error{DurableQuantumKeyFailure(
                destination,
                action_name,
                _("Refusing to continue: destination ML-DSA key is not confirmed stored in the wallet."))};
        }

        CCoinControl coin_control;
        coin_control.m_allow_other_inputs = false;
        coin_control.m_include_unsafe_inputs = false;
        // Reuse the expressly authorized sweep destination for any unexpected
        // change instead of silently creating a second non-HD key.
        coin_control.destChange = destination;
        coin_control.m_include_generated_quantum_inputs = goldrush_rewards_only;

        CoinFilterParams filter;
        filter.only_spendable = true;
        filter.skip_locked = true;
        filter.include_immature_coinbase = false;
        filter.include_generated_quantum_inputs = goldrush_rewards_only;

        const CCoinsViewCache& view = wallet.chain().chainman().ActiveChainstate().CoinsTip();
        unsigned int migration_anchor_inputs{0};
        for (const COutput& out : AvailableCoins(wallet, &coin_control, std::nullopt, filter).All()) {
            const CScript& spk = out.txout.scriptPubKey;
            if (goldrush_rewards_only) {
                if (!IsQuantumMigrationScript(spk) || spk == destination_script) continue;
                CScript marker_script;
                if (!IsGoldRushDirectPayoutOutput(view, out.outpoint, &marker_script) || marker_script != spk) continue;
                const Coin& coin = view.AccessCoin(out.outpoint);
                if (coin.IsSpent()) continue;
                const std::optional<Consensus::DemurrageAttestationState> latest_attestation =
                    Consensus::LatestDemurrageAttestationStateForScript(view, spk);
                const Consensus::DemurrageEvaluation eval = Consensus::EvaluateDemurrage(
                    coin, consensus, next_height, mtp,
                    latest_attestation ? std::optional<int>{latest_attestation->height} : std::nullopt,
                    latest_attestation ? std::optional<int>{static_cast<int>(latest_attestation->coverage_start_height)} : std::nullopt);
                if (eval.locked || eval.effective_value <= 0) continue;
                effective_eligible_amount += eval.effective_value;
                burned_amount += eval.burned_value;
            } else {
                if (IsQuantumMigrationScript(spk) || IsQuantumColdStakeScript(spk) || IsEUTXOScript(spk)) continue;
                if (!out.spendable) continue;
                const Coin& coin = view.AccessCoin(out.outpoint);
                if (!coin.IsSpent() && IsWalletProtectedLineageInput(
                        wallet, out.outpoint, coin, consensus, mtp, next_height)) {
                    ++migration_anchor_inputs;
                }
            }
            coin_control.Select(out.outpoint);
            eligible_amount += out.txout.nValue;
            if (!goldrush_rewards_only) effective_eligible_amount += out.txout.nValue;
            ++eligible_inputs;
        }
        if (eligible_inputs == 0) {
            const bilingual_str failure = goldrush_rewards_only
                ? _("No spendable wallet-owned Gold Rush reward outputs are available to consolidate.")
                : _("No spendable legacy coins to migrate.");
            return util::Error{DurableQuantumKeyFailure(destination, action_name, failure)};
        }
        if (!goldrush_rewards_only && IsQuantumWitnessSpendActive(consensus, mtp, next_height) &&
            migration_anchor_inputs == 0) {
            return util::Error{DurableQuantumKeyFailure(
                destination,
                action_name,
                _("This wallet's spendable legacy coins are witness-only and cannot create a fork-unique migration transaction. Add a small P2PKH or non-witness P2SH wallet UTXO as a migration anchor; during Gold Rush, prepare that anchor before quantum spending activates."))};
        }

        std::vector<CRecipient> recipients{{destination, effective_eligible_amount, /*fSubtractFeeFromAmount=*/true}};
        int change_pos = RANDOM_CHANGE_POSITION;
        auto res = CreateTransaction(wallet, recipients, change_pos, coin_control, /*sign=*/true);
        if (!res) {
            return util::Error{DurableQuantumKeyFailure(destination, action_name, util::ErrorString(res))};
        }
        tx = res->tx;
        fee = res->fee;
        if (tx->vout.size() != 1 || IsDust(tx->vout[0], wallet.chain().relayDustFee())) {
            const bilingual_str failure = goldrush_rewards_only
                ? _("Gold Rush reward consolidation would strand funds: selected value is below the dust threshold after fees.")
                : _("Migration would strand funds: swept value is below the dust threshold after fees.");
            return util::Error{DurableQuantumKeyFailure(destination, action_name, failure)};
        }
        comment = !comment_override.empty()
            ? comment_override
            : goldrush_rewards_only
            ? "Blackcoin Gold Rush reward consolidation"
            : "Blackcoin quantum migration";
    }

    mapValue_t map_value;
    map_value["comment"] = std::move(comment);
    if (auto committed = CommitWalletTransactionOrError(wallet, tx, std::move(map_value), action_name); !committed) {
        return util::Error{DurableQuantumKeyFailure(destination, action_name, util::ErrorString(committed))};
    }

    WalletQuantumActionTx result;
    result.txid = tx->GetHash().GetHex();
    result.address = destination_address;
    result.amount = tx->vout.empty() ? 0 : tx->vout[0].nValue;
    result.fee = fee;
    result.vsize = static_cast<int>(GetVirtualTransactionSize(*tx, 0, 0));
    result.selected_inputs = eligible_inputs;
    result.selected_amount = eligible_amount;
    result.warning = burned_amount > 0
        ? strprintf("A new ML-DSA quantum address was created. This consolidation realizes %s of scheduled demurrage. Back up this wallet.", FormatMoney(burned_amount))
        : "A new ML-DSA quantum address was created. Back up this wallet before relying on the moved funds.";
    return result;
}

namespace {

util::Result<WalletQuantumActionTx> CreateWalletDemurrageAttestation(CWallet& wallet, const std::string& address)
{
    std::string error_msg;
    const CTxDestination dest = DecodeDestination(address, error_msg);
    if (!IsValidDestination(dest)) {
        return util::Error{Untranslated(error_msg.empty() ? "Invalid address" : error_msg)};
    }
    const auto* witness = std::get_if<WitnessUnknown>(&dest);
    if (!witness || !IsQuantumMigrationWitnessProgram(witness->GetWitnessVersion(), witness->GetWitnessProgram())) {
        return util::Error{_("Address is not a Blackcoin migration address")};
    }

    {
        LOCK(wallet.cs_wallet);
        bilingual_str spend_error;
        if (!CanCreateSignedSpend(wallet, spend_error)) return util::Error{spend_error};
    }

    CCoinControl coin_control;
    DemurrageAttestationTxResult tx_result;
    bilingual_str error;
    if (!CreateDemurrageAttestationTransaction(wallet, witness->GetWitnessProgram(), coin_control, /*sign=*/true, tx_result, error)) {
        return util::Error{error};
    }

    mapValue_t map_value;
    map_value["comment"] = "Blackcoin demurrage attestation";
    if (auto committed = CommitWalletTransactionOrError(wallet, tx_result.tx, std::move(map_value), "demurrage attestation"); !committed) {
        return util::Error{util::ErrorString(committed)};
    }

    WalletQuantumActionTx result;
    result.txid = tx_result.tx->GetHash().GetHex();
    result.address = EncodeDestination(dest);
    result.fee = tx_result.fee;
    result.vsize = static_cast<int>(GetVirtualTransactionSize(*tx_result.tx, 0, 0));
    return result;
}

util::Result<WalletQuantumActionTx> CreateWalletDemurrageSweep(CWallet& wallet, bool allow_new_quantum_key)
{
    if (!allow_new_quantum_key) {
        return util::Error{_("Demurrage sweep creates a new non-HD ML-DSA destination key. Retry with allow_new_quantum_key=true only after authorizing key creation, then back up the wallet. No key or transaction was created.")};
    }
    LOCK2(::cs_main, wallet.cs_wallet);
    bilingual_str spend_error;
    if (!CanCreateSignedSpend(wallet, spend_error)) return util::Error{spend_error};

    const Consensus::Params& consensus = Params().GetConsensus();
    const CBlockIndex* tip = wallet.chain().getTip();
    const int tip_height = tip ? tip->nHeight : -1;
    const int evaluation_height = tip_height >= 0 ? tip_height + 1 : 0;
    const int64_t evaluation_time = tip ? tip->GetMedianTimePast() : 0;
    if (!consensus.IsDemurrageActive(evaluation_height, evaluation_time)) {
        return util::Error{_("Error: Demurrage is not active for the next block")};
    }

    auto op_dest = wallet.GetNewQuantumDestination("demurrage-sweep");
    if (!op_dest) return util::Error{util::ErrorString(op_dest)};
    const CTxDestination created_destination = *op_dest;
    if (!wallet.GetQuantumKeyInfo(*op_dest).has_value()) {
        return util::Error{DurableQuantumKeyFailure(
            created_destination,
            "Demurrage sweep",
            _("Error: Refusing to sweep: destination ML-DSA key is not confirmed stored in the wallet"))};
    }

    CCoinControl coin_control;
    coin_control.m_allow_other_inputs = false;
    coin_control.m_include_unsafe_inputs = false;
    // The newly authorized sweep destination is also the change destination;
    // never create a second hidden non-HD key.
    coin_control.destChange = *op_dest;

    CoinFilterParams filter;
    filter.only_spendable = true;
    filter.skip_locked = true;
    filter.include_immature_coinbase = false;

    CoinsResult available = AvailableCoins(wallet, &coin_control, std::nullopt, filter);
    std::map<COutPoint, Coin> chain_coins;
    std::vector<COutput> candidates;
    for (const COutput& out : available.All()) {
        if (!IsQuantumMigrationScript(out.txout.scriptPubKey)) continue;
        CTxDestination out_dest;
        if (!ExtractDestination(out.txout.scriptPubKey, out_dest) || !wallet.GetQuantumKeyInfo(out_dest).has_value()) continue;
        chain_coins.emplace(out.outpoint, Coin{});
        candidates.push_back(out);
    }
    wallet.chain().findCoins(chain_coins);

    CAmount nominal_amount{0};
    CAmount effective_amount{0};
    CAmount burned_amount{0};
    CAmount skipped_locked_amount{0};
    unsigned int selected_inputs{0};
    unsigned int skipped_locked_outputs{0};
    std::vector<COutPoint> selected_outpoints;
    const CCoinsViewCache& view = wallet.chain().getCoinsTip();
    for (const COutput& out : candidates) {
        const auto coin_it = chain_coins.find(out.outpoint);
        if (coin_it == chain_coins.end() || coin_it->second.IsSpent()) continue;
        const std::optional<Consensus::DemurrageAttestationState> latest_attestation =
            Consensus::LatestDemurrageAttestationStateForScript(view, out.txout.scriptPubKey);
        const Consensus::DemurrageEvaluation eval = Consensus::EvaluateDemurrage(
            coin_it->second, consensus, evaluation_height, evaluation_time,
            latest_attestation ? std::optional<int>{latest_attestation->height} : std::nullopt,
            latest_attestation ? std::optional<int>{static_cast<int>(latest_attestation->coverage_start_height)} : std::nullopt);
        if (eval.locked) {
            ++skipped_locked_outputs;
            skipped_locked_amount += eval.nominal_value;
            continue;
        }
        if (eval.burned_value <= 0) continue;
        selected_outpoints.push_back(out.outpoint);
        nominal_amount += eval.nominal_value;
        effective_amount += eval.effective_value;
        burned_amount += eval.burned_value;
        ++selected_inputs;
    }
    if (selected_inputs == 0) {
        return util::Error{DurableQuantumKeyFailure(
            created_destination,
            "Demurrage sweep",
            _("Error: No spendable wallet-owned quantum outputs are currently decaying"))};
    }
    if (effective_amount <= 0) {
        return util::Error{DurableQuantumKeyFailure(
            created_destination,
            "Demurrage sweep",
            _("Error: Selected decaying outputs have no spendable effective value"))};
    }

    const int64_t current_time = GetAdjustedTimeSeconds();
    const CFeeRate fee_rate = GetMinimumFeeRate(wallet, coin_control, current_time);

    CMutableTransaction sweep_tx;
    sweep_tx.nVersion = CTransaction::CURRENT_VERSION;
    sweep_tx.nTime = current_time;
    static constexpr uint32_t MAX_SEQUENCE_NONFINAL = 0xfffffffe;
    for (const COutPoint& outpoint : selected_outpoints) {
        sweep_tx.vin.emplace_back(outpoint, CScript(), MAX_SEQUENCE_NONFINAL);
    }
    sweep_tx.vout.emplace_back(effective_amount, GetScriptForDestination(*op_dest));

    const TxSize tx_size = CalculateMaximumSignedTxSize(CTransaction(sweep_tx), &wallet, &coin_control);
    if (tx_size.vsize <= 0) {
        return util::Error{DurableQuantumKeyFailure(
            created_destination,
            "Demurrage sweep",
            _("Error: Unable to estimate demurrage sweep transaction size"))};
    }
    const CAmount fee = std::max(GetMinFee(static_cast<size_t>(tx_size.vsize), static_cast<uint32_t>(current_time)), fee_rate.GetFee(static_cast<uint32_t>(tx_size.vsize)));
    if (fee > wallet.m_default_max_tx_fee) {
        return util::Error{DurableQuantumKeyFailure(
            created_destination,
            "Demurrage sweep",
            strprintf(_("Error: Demurrage sweep fee exceeds wallet max transaction fee (%s)"), FormatMoney(wallet.m_default_max_tx_fee)))};
    }
    const CAmount output_amount = effective_amount - fee;
    if (!MoneyRange(output_amount) || output_amount <= 0) {
        return util::Error{DurableQuantumKeyFailure(
            created_destination,
            "Demurrage sweep",
            _("Error: Selected decaying outputs cannot pay the sweep fee"))};
    }
    sweep_tx.vout[0].nValue = output_amount;
    if (IsDust(sweep_tx.vout[0], wallet.chain().relayDustFee())) {
        return util::Error{DurableQuantumKeyFailure(
            created_destination,
            "Demurrage sweep",
            _("Error: Demurrage sweep would strand the effective value below dust after fees"))};
    }

    std::map<int, bilingual_str> input_errors;
    if (!wallet.SignTransaction(sweep_tx, input_errors)) {
        if (!input_errors.empty()) {
            return util::Error{DurableQuantumKeyFailure(
                created_destination,
                "Demurrage sweep",
                strprintf(_("Error: Signing demurrage sweep failed: %s"), input_errors.begin()->second.original))};
        }
        return util::Error{DurableQuantumKeyFailure(
            created_destination,
            "Demurrage sweep",
            _("Error: Signing demurrage sweep failed"))};
    }

    CTransactionRef tx = MakeTransactionRef(std::move(sweep_tx));
    mapValue_t map_value;
    map_value["comment"] = "Blackcoin demurrage sweep";
    if (auto committed = CommitWalletTransactionOrError(wallet, tx, std::move(map_value), "demurrage sweep"); !committed) {
        return util::Error{DurableQuantumKeyFailure(
            created_destination,
            "Demurrage sweep",
            util::ErrorString(committed))};
    }

    WalletQuantumActionTx result;
    result.txid = tx->GetHash().GetHex();
    result.address = EncodeDestination(*op_dest);
    result.amount = output_amount;
    result.fee = fee;
    result.vsize = static_cast<int>(GetVirtualTransactionSize(*tx, 0, 0));
    result.selected_inputs = selected_inputs;
    result.selected_amount = nominal_amount;
    result.warning = strprintf(
        _("Burned %s of demurrage decay and skipped %u fully locked output(s) worth %s. Back up the wallet after this fresh quantum address is created.").original,
        FormatMoney(burned_amount),
        skipped_locked_outputs,
        FormatMoney(skipped_locked_amount));
    return result;
}

//! Construct wallet tx struct.
WalletTx MakeWalletTx(CWallet& wallet, const CWalletTx& wtx)
{
    LOCK(wallet.cs_wallet);
    WalletTx result;
    result.tx = wtx.tx;
    result.txin_is_mine.reserve(wtx.tx->vin.size());
    for (const auto& txin : wtx.tx->vin) {
        result.txin_is_mine.emplace_back(InputIsMine(wallet, txin));
    }
    result.txout_is_mine.reserve(wtx.tx->vout.size());
    result.txout_address.reserve(wtx.tx->vout.size());
    result.txout_address_is_mine.reserve(wtx.tx->vout.size());
    for (const auto& txout : wtx.tx->vout) {
        CTxDestination address;
        ExtractDestination(txout.scriptPubKey, address);
        result.txout_is_mine.emplace_back(wallet.IsMine(txout));
        result.txout_is_change.push_back(OutputIsChange(wallet, txout));
        result.txout_address.emplace_back();
        result.txout_address_is_mine.emplace_back(ExtractDestination(txout.scriptPubKey, result.txout_address.back()) ?
                                                      wallet.IsMine(result.txout_address.back()) :
                                                      ISMINE_NO);
    }
    result.credit = CachedTxGetCredit(wallet, wtx, ISMINE_ALL);
    result.debit = CachedTxGetDebit(wallet, wtx, ISMINE_ALL);
    result.change = CachedTxGetChange(wallet, wtx);
    result.time = wtx.GetTxTime();
    result.value_map = wtx.mapValue;
    result.is_coinbase = wtx.IsCoinBase();
    result.is_coinstake = wtx.IsCoinStake();
    return result;
}

//! Construct wallet tx status struct.
WalletTxStatus MakeWalletTxStatus(const CWallet& wallet, const CWalletTx& wtx)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    AssertLockHeld(wallet.cs_wallet);

    WalletTxStatus result;
    result.block_height =
        wtx.state<TxStateConfirmed>() ? wtx.state<TxStateConfirmed>()->confirmed_block_height :
        wtx.state<TxStateConflicted>() ? wtx.state<TxStateConflicted>()->conflicting_block_height :
        std::numeric_limits<int>::max();
    result.blocks_to_maturity = wallet.GetTxBlocksToMaturity(wtx);
    result.depth_in_main_chain = wallet.GetTxDepthInMainChain(wtx);
    result.time_received = wtx.nTimeReceived;
    result.lock_time = wtx.tx->nLockTime;
    result.is_trusted = CachedTxIsTrusted(wallet, wtx);
    result.is_abandoned = wtx.isAbandoned();
    result.is_coinbase = wtx.IsCoinBase();
    result.is_coinstake = wtx.IsCoinStake();
    result.is_in_main_chain = wallet.IsTxInMainChain(wtx);
    return result;
}

//! Construct wallet TxOut struct.
WalletTxOut MakeWalletTxOut(const CWallet& wallet,
    const CWalletTx& wtx,
    int n,
    int depth) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    WalletTxOut result;
    result.txout = wtx.tx->vout[n];
    result.time = wtx.GetTxTime();
    result.depth_in_main_chain = depth;
    result.is_spent = wallet.IsSpent(COutPoint(wtx.GetHash(), n));
    return result;
}

WalletTxOut MakeWalletTxOut(const CWallet& wallet,
    const COutput& output) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    WalletTxOut result;
    result.txout = output.txout;
    result.time = output.time;
    result.depth_in_main_chain = output.depth;
    result.is_spent = wallet.IsSpent(output.outpoint);
    return result;
}

class WalletImpl : public Wallet
{
public:
    explicit WalletImpl(WalletContext& context, const std::shared_ptr<CWallet>& wallet) : m_context(context), m_wallet(wallet) {}

    bool encryptWallet(const SecureString& wallet_passphrase) override
    {
        return m_wallet->EncryptWallet(wallet_passphrase);
    }
    bool hasPrivateKeys() override { return m_wallet->HasPrivateKeys(); }
    bool isCrypted() override { return m_wallet->IsCrypted(); }
    bool lock() override { return m_wallet->Lock(); }
    bool unlock(const SecureString& wallet_passphrase,
                std::optional<bool> staking_only) override
    {
        return m_wallet->Unlock(wallet_passphrase, /*accept_no_keys=*/false,
                                staking_only);
    }
    bool isLocked() override { return m_wallet->IsLocked(); }
    bool tryGetEncryptionStatus(interfaces::WalletEncryptionStatus& status) override
    {
        TRY_LOCK(m_wallet->cs_wallet, wallet_lock);
        if (!wallet_lock) return false;
        status.encrypted = m_wallet->IsCrypted();
        status.locked = status.encrypted && m_wallet->IsLocked();
        status.private_keys_disabled = m_wallet->IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS);
        return true;
    }
    bool changeWalletPassphrase(const SecureString& old_wallet_passphrase,
        const SecureString& new_wallet_passphrase) override
    {
        return m_wallet->ChangeWalletPassphrase(old_wallet_passphrase, new_wallet_passphrase);
    }
    void abortRescan() override { m_wallet->AbortRescan(); }
    bool backupWallet(const std::string& filename) override { return m_wallet->BackupWallet(filename); }
    std::string getWalletName() override { return m_wallet->GetName(); }
    util::Result<CTxDestination> getNewDestination(const OutputType type, const std::string& label) override
    {
        LOCK(m_wallet->cs_wallet);
        return m_wallet->GetNewDestination(type, label);
    }
    bool getPubKey(const CScript& script, const CKeyID& address, CPubKey& pub_key) override
    {
        std::unique_ptr<SigningProvider> provider = m_wallet->GetSolvingProvider(script);
        if (provider) {
            return provider->GetPubKey(address, pub_key);
        }
        return false;
    }
    SigningResult signMessage(const std::string& message, const PKHash& pkhash, std::string& str_sig) override
    {
        return m_wallet->SignMessage(message, pkhash, str_sig);
    }
    bool isSpendable(const CTxDestination& dest) override
    {
        LOCK(m_wallet->cs_wallet);
        return m_wallet->IsMine(dest) & ISMINE_SPENDABLE;
    }
    bool haveWatchOnly() override
    {
        auto spk_man = m_wallet->GetLegacyScriptPubKeyMan();
        if (spk_man) {
            return spk_man->HaveWatchOnly();
        }
        return false;
    };
    bool setAddressBook(const CTxDestination& dest, const std::string& name, const std::optional<AddressPurpose>& purpose) override
    {
        return m_wallet->SetAddressBook(dest, name, purpose);
    }
    bool delAddressBook(const CTxDestination& dest) override
    {
        return m_wallet->DelAddressBook(dest);
    }
    bool getAddress(const CTxDestination& dest,
        std::string* name,
        isminetype* is_mine,
        AddressPurpose* purpose) override
    {
        LOCK(m_wallet->cs_wallet);
        const auto& entry = m_wallet->FindAddressBookEntry(dest, /*allow_change=*/false);
        if (!entry) return false; // addr not found
        if (name) {
            *name = entry->GetLabel();
        }
        std::optional<isminetype> dest_is_mine;
        if (is_mine || purpose) {
            dest_is_mine = m_wallet->IsMine(dest);
        }
        if (is_mine) {
            *is_mine = *dest_is_mine;
        }
        if (purpose) {
            // In very old wallets, address purpose may not be recorded so we derive it from IsMine
            *purpose = entry->purpose.value_or(*dest_is_mine ? AddressPurpose::RECEIVE : AddressPurpose::SEND);
        }
        return true;
    }
    std::vector<WalletAddress> getAddresses() const override
    {
        LOCK(m_wallet->cs_wallet);
        std::vector<WalletAddress> result;
        m_wallet->ForEachAddrBookEntry([&](const CTxDestination& dest, const std::string& label, bool is_change, const std::optional<AddressPurpose>& purpose) EXCLUSIVE_LOCKS_REQUIRED(m_wallet->cs_wallet) {
            if (is_change) return;
            isminetype is_mine = m_wallet->IsMine(dest);
            // In very old wallets, address purpose may not be recorded so we derive it from IsMine
            result.emplace_back(dest, is_mine, purpose.value_or(is_mine ? AddressPurpose::RECEIVE : AddressPurpose::SEND), label);
        });
        return result;
    }
    std::vector<std::string> getAddressReceiveRequests() override {
        LOCK(m_wallet->cs_wallet);
        return m_wallet->GetAddressReceiveRequests();
    }
    bool setAddressReceiveRequest(const CTxDestination& dest, const std::string& id, const std::string& value) override {
        // Note: The setAddressReceiveRequest interface used by the GUI to store
        // receive requests is a little awkward and could be improved in the
        // future:
        //
        // - The same method is used to save requests and erase them, but
        //   having separate methods could be clearer and prevent bugs.
        //
        // - Request ids are passed as strings even though they are generated as
        //   integers.
        //
        // - Multiple requests can be stored for the same address, but it might
        //   be better to only allow one request or only keep the current one.
        LOCK(m_wallet->cs_wallet);
        WalletBatch batch{m_wallet->GetDatabase()};
        return value.empty() ? m_wallet->EraseAddressReceiveRequest(batch, dest, id)
                             : m_wallet->SetAddressReceiveRequest(batch, dest, id, value);
    }
    bool displayAddress(const CTxDestination& dest) override
    {
        LOCK(m_wallet->cs_wallet);
        return m_wallet->DisplayAddress(dest);
    }
    bool lockCoin(const COutPoint& output, const bool write_to_db) override
    {
        LOCK(m_wallet->cs_wallet);
        std::unique_ptr<WalletBatch> batch = write_to_db ? std::make_unique<WalletBatch>(m_wallet->GetDatabase()) : nullptr;
        return m_wallet->LockCoin(output, batch.get());
    }
    bool unlockCoin(const COutPoint& output) override
    {
        LOCK(m_wallet->cs_wallet);
        std::unique_ptr<WalletBatch> batch = std::make_unique<WalletBatch>(m_wallet->GetDatabase());
        return m_wallet->UnlockCoin(output, batch.get());
    }
    bool isLockedCoin(const COutPoint& output) override
    {
        LOCK(m_wallet->cs_wallet);
        return m_wallet->IsLockedCoin(output);
    }
    void listLockedCoins(std::vector<COutPoint>& outputs) override
    {
        LOCK(m_wallet->cs_wallet);
        return m_wallet->ListLockedCoins(outputs);
    }
    util::Result<CTransactionRef> createTransaction(const std::vector<CRecipient>& recipients,
        const CCoinControl& coin_control,
        bool sign,
        int& change_pos,
        CAmount& fee) override
    {
        auto res = CreateTransaction(*m_wallet, recipients, change_pos,
                                     coin_control, sign);
        if (!res) return util::Error{util::ErrorString(res)};
        const auto& txr = *res;
        fee = txr.fee;
        change_pos = txr.change_pos;

        return txr.tx;
    }
    void commitTransaction(CTransactionRef tx,
        WalletValueMap value_map,
        WalletOrderForm order_form) override
    {
        std::string broadcast_error;
        WalletCommitStatus status;
        if (!m_wallet->CommitTransaction(tx, std::move(value_map), std::move(order_form), &broadcast_error, &status)) {
            if (status == WalletCommitStatus::PERSISTED_PENDING) return;
            throw std::runtime_error(broadcast_error.empty()
                ? "Transaction could not be committed"
                : broadcast_error);
        }
    }
    bool transactionCanBeAbandoned(const uint256& txid) override { return m_wallet->TransactionCanBeAbandoned(txid); }
    bool abandonTransaction(const uint256& txid) override
    {
        const bool abandoned = m_wallet->AbandonTransaction(txid);
        if (abandoned) m_wallet->ReconcileRGBAssignments();
        return abandoned;
    }
    CTransactionRef getTx(const uint256& txid) override
    {
        LOCK(m_wallet->cs_wallet);
        auto mi = m_wallet->mapWallet.find(txid);
        if (mi != m_wallet->mapWallet.end()) {
            return mi->second.tx;
        }
        return {};
    }
    WalletTx getWalletTx(const uint256& txid) override
    {
        LOCK(m_wallet->cs_wallet);
        auto mi = m_wallet->mapWallet.find(txid);
        if (mi != m_wallet->mapWallet.end()) {
            return MakeWalletTx(*m_wallet, mi->second);
        }
        return {};
    }
    std::set<WalletTx> getWalletTxs() override
    {
        LOCK(m_wallet->cs_wallet);
        std::set<WalletTx> result;
        for (const auto& entry : m_wallet->mapWallet) {
            result.emplace(MakeWalletTx(*m_wallet, entry.second));
        }
        return result;
    }
    bool tryGetTxStatus(const uint256& txid,
        interfaces::WalletTxStatus& tx_status,
        int& num_blocks,
        int64_t& block_time) override
    {
        TRY_LOCK(::cs_main, locked_main);
        if (!locked_main) {
            return false;
        }
        TRY_LOCK(m_wallet->cs_wallet, locked_wallet);
        if (!locked_wallet) {
            return false;
        }
        auto mi = m_wallet->mapWallet.find(txid);
        if (mi == m_wallet->mapWallet.end()) {
            return false;
        }
        num_blocks = m_wallet->GetLastBlockHeight();
        block_time = -1;
        CHECK_NONFATAL(m_wallet->chain().findBlock(m_wallet->GetLastBlockHash(), FoundBlock().time(block_time)));
        tx_status = MakeWalletTxStatus(*m_wallet, mi->second);
        return true;
    }
    WalletTx getWalletTxDetails(const uint256& txid,
        WalletTxStatus& tx_status,
        WalletOrderForm& order_form,
        bool& in_mempool,
        int& num_blocks) override
    {
        LOCK(m_wallet->cs_wallet);
        auto mi = m_wallet->mapWallet.find(txid);
        if (mi != m_wallet->mapWallet.end()) {
            num_blocks = m_wallet->GetLastBlockHeight();
            in_mempool = mi->second.InMempool();
            order_form = mi->second.vOrderForm;
            tx_status = MakeWalletTxStatus(*m_wallet, mi->second);
            return MakeWalletTx(*m_wallet, mi->second);
        }
        return {};
    }
    TransactionError fillPSBT(int sighash_type,
        bool sign,
        bool bip32derivs,
        size_t* n_signed,
        PartiallySignedTransaction& psbtx,
        bool& complete) override
    {
        return m_wallet->FillPSBT(psbtx, complete, sighash_type, sign, bip32derivs, n_signed);
    }
    bool finalizePSBT(PartiallySignedTransaction& psbtx, CMutableTransaction& mtx) override
    {
        return m_wallet->FinalizeAndExtractPSBT(psbtx, mtx);
    }
    std::pair<unsigned int, uint32_t> getPSBTAnalysisContext() const override
    {
        return {m_wallet->GetActiveScriptVerifyFlags(), Params().GetConsensus().nQuantumSighashChainId};
    }
    WalletBalances getBalancesLocked()
    {
        AssertLockHeld(::cs_main);
        AssertLockHeld(m_wallet->cs_wallet);
        WalletBalances result;
        Balance bal;
        WalletLifecycleSummary lifecycle;
        std::string lifecycle_error;
        if (!GetLifecycleAdjustedBalance(*m_wallet, 0, /*avoid_reuse=*/true,
                                         bal, lifecycle, lifecycle_error)) {
            m_wallet->WalletLogPrintf("Unable to calculate lifecycle-adjusted GUI balance: %s\n",
                                      lifecycle_error);
            result.have_watch_only = haveWatchOnly();
            return result;
        }
        result.balance = bal.m_mine_trusted;
        result.legacy_balance = lifecycle.mine.spendable_legacy;
        result.quantum_balance = lifecycle.mine.spendable_quantum;
        auto category_nominal = [&](ValueLifecycleCategory category) {
            return lifecycle.mine.nominal.at(static_cast<size_t>(category));
        };
        result.synthetic_immature_balance = category_nominal(
            ValueLifecycleCategory::GOLD_RUSH_SYNTHETIC_IMMATURE);
        result.synthetic_mature_locked_balance = category_nominal(
            ValueLifecycleCategory::GOLD_RUSH_SYNTHETIC_MATURE_LOCKED);
        result.direct_quantum_phase_locked_balance = category_nominal(
            ValueLifecycleCategory::DIRECT_QUANTUM_PHASE_LOCKED);
        result.quantum_contract_restricted_balance = category_nominal(
            ValueLifecycleCategory::QUANTUM_CONTRACT_RESTRICTED);
        result.final_locked_legacy_balance = category_nominal(
            ValueLifecycleCategory::FINAL_LOCKED_LEGACY);
        result.demurrage_locked_balance = category_nominal(
            ValueLifecycleCategory::DEMURRAGE_LOCKED);
        for (const CAmount burned : lifecycle.mine.burned) {
            result.demurrage_burned_balance += burned;
        }
        result.unconfirmed_balance = bal.m_mine_untrusted_pending;
        result.immature_balance = bal.m_mine_immature;
        result.stake = bal.m_mine_stake;
        result.have_watch_only = haveWatchOnly();
        if (result.have_watch_only) {
            result.watch_only_balance = bal.m_watchonly_trusted;
            result.unconfirmed_watch_only_balance = bal.m_watchonly_untrusted_pending;
            result.immature_watch_only_balance = bal.m_watchonly_immature;
            result.watch_only_stake = bal.m_watchonly_stake;
        }
        return result;
    }
    WalletBalances getBalances() override
    {
        for (;;) {
            m_wallet->BlockUntilSyncedToCurrentChain();
            LOCK2(::cs_main, m_wallet->cs_wallet);
            if (!WalletLifecycleViewIsSynchronized(*m_wallet)) continue;
            return getBalancesLocked();
        }
    }
    bool tryGetBalances(WalletBalances& balances, uint256& block_hash) override
    {
        TRY_LOCK(::cs_main, locked_main);
        if (!locked_main) {
            return false;
        }
        TRY_LOCK(m_wallet->cs_wallet, locked_wallet);
        if (!locked_wallet) {
            return false;
        }
        // Notification delivery can lag a newly connected block. Returning
        // false keeps the GUI's last valid balance until both views catch up.
        if (!WalletLifecycleViewIsSynchronized(*m_wallet)) return false;
        block_hash = m_wallet->GetLastBlockHash();
        balances = getBalancesLocked();
        return true;
    }
    CAmount getBalance() override
    {
        for (;;) {
            m_wallet->BlockUntilSyncedToCurrentChain();
            LOCK2(::cs_main, m_wallet->cs_wallet);
            if (!WalletLifecycleViewIsSynchronized(*m_wallet)) continue;
            Balance balance;
            WalletLifecycleSummary lifecycle;
            std::string error;
            if (!GetLifecycleAdjustedBalance(*m_wallet, 0, /*avoid_reuse=*/true,
                                             balance, lifecycle, error)) {
                m_wallet->WalletLogPrintf("Unable to calculate lifecycle-adjusted balance: %s\n", error);
                return 0;
            }
            return balance.m_mine_trusted;
        }
    }
    CAmount getAvailableBalance(const CCoinControl& coin_control) override
    {
        LOCK2(::cs_main, m_wallet->cs_wallet);
        CAmount total_amount = 0;
        // Fetch selected coins total amount
        if (coin_control.HasSelected()) {
            FastRandomContext rng{};
            CoinSelectionParams params(rng);
            // Note: for now, swallow any error.
            if (auto res = FetchSelectedInputs(*m_wallet, coin_control, params)) {
                total_amount += res->total_amount;
            }
        }

        // And fetch the wallet available coins
        if (coin_control.m_allow_other_inputs) {
            total_amount += AvailableCoins(*m_wallet, &coin_control).GetTotalAmount();
        }

        return total_amount;
    }
    isminetype txinIsMine(const CTxIn& txin) override
    {
        LOCK(m_wallet->cs_wallet);
        return InputIsMine(*m_wallet, txin);
    }
    isminetype txoutIsMine(const CTxOut& txout) override
    {
        LOCK(m_wallet->cs_wallet);
        return m_wallet->IsMine(txout);
    }
    CAmount getDebit(const CTxIn& txin, isminefilter filter) override
    {
        LOCK(m_wallet->cs_wallet);
        return m_wallet->GetDebit(txin, filter);
    }
    CAmount getCredit(const CTxOut& txout, isminefilter filter) override
    {
        LOCK(m_wallet->cs_wallet);
        return OutputGetCredit(*m_wallet, txout, filter);
    }
    CoinsList listCoins() override
    {
        LOCK2(::cs_main, m_wallet->cs_wallet);
        CoinsList result;
        for (const auto& entry : ListCoins(*m_wallet)) {
            auto& group = result[entry.first];
            for (const auto& coin : entry.second) {
                group.emplace_back(coin.outpoint,
                    MakeWalletTxOut(*m_wallet, coin));
            }
        }
        return result;
    }
    std::vector<WalletTxOut> getCoins(const std::vector<COutPoint>& outputs) override
    {
        LOCK(m_wallet->cs_wallet);
        std::vector<WalletTxOut> result;
        result.reserve(outputs.size());
        for (const auto& output : outputs) {
            result.emplace_back();
            auto it = m_wallet->mapWallet.find(output.hash);
            if (it != m_wallet->mapWallet.end()) {
                int depth = m_wallet->GetTxDepthInMainChain(it->second);
                if (depth >= 0) {
                    result.back() = MakeWalletTxOut(*m_wallet, it->second, output.n, depth);
                }
            }
        }
        return result;
    }
    CAmount getMinimumFee(unsigned int tx_bytes,
        const CCoinControl& coin_control,
        int64_t current_time) override
    {
        CAmount result;
        result = GetMinimumFee(*m_wallet, tx_bytes, coin_control, current_time);
        return result;
    }
    bool hdEnabled() override { return m_wallet->IsHDEnabled(); }
    bool canGetAddresses() override { return m_wallet->CanGetAddresses(); }
    bool hasExternalSigner() override { return m_wallet->IsWalletFlagSet(WALLET_FLAG_EXTERNAL_SIGNER); }
    bool privateKeysDisabled() override { return m_wallet->IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS); }
    bool taprootEnabled() override {
        if (m_wallet->IsLegacy()) return false;
        auto spk_man = m_wallet->GetScriptPubKeyMan(OutputType::BECH32M, /*internal=*/false);
        return spk_man != nullptr;
    }
    OutputType getDefaultAddressType() override { return m_wallet->m_default_address_type; }
    CAmount getDefaultMaxTxFee() override { return m_wallet->m_default_max_tx_fee; }
    void remove() override
    {
        RemoveWallet(m_context, m_wallet, /*load_on_start=*/false);
    }
    unsigned int getQQDevelopmentDonationPercentage() override
    {
        return m_wallet->GetQQDevelopmentDonationPercentage();
    }
    std::string getQQDevelopmentDonationAddress() override
    {
        return Params().GetQQDevelopmentDonationAddress();
    }
    bool setQQDevelopmentDonation(unsigned int percentage,
                                  const std::string& recipient,
                                  std::string& error) override
    {
        bilingual_str wallet_error;
        const bool success = m_wallet->SetQQDevelopmentDonationConsent(
            percentage, recipient, wallet_error);
        error = wallet_error.original;
        return success;
    }
    bool tryGetStakeWeight(uint64_t& nWeight) override
    {
        // The staking worker publishes a complete scan. GUI polling must not
        // acquire chain/wallet locks and repeat the O(wallet-history) walk.
        if (m_wallet->m_cached_stake_weight_height.load(std::memory_order_acquire) < 0) {
            return false;
        }
        nWeight = m_wallet->m_cached_stake_weight.load(std::memory_order_relaxed);
        return true;
    }
    uint64_t getStakeWeight() override
    {
        LOCK2(::cs_main, m_wallet->cs_wallet);
        return m_wallet->GetStakeWeight();
    }
    int64_t getLastCoinStakeSearchInterval() override
    {
        return m_wallet->m_last_coin_stake_search_interval.load(std::memory_order_relaxed);
    }
    bool getWalletUnlockStakingOnly() override
    {
        return m_wallet->m_wallet_unlock_staking_only;
    }
    void setWalletUnlockStakingOnly(bool unlock) override
    {
        m_wallet->SetWalletUnlockStakingOnly(unlock);
    }
    void setEnabledStaking(bool enabled) override
    {
        if (enabled) {
            // The GUI runtime switch must have the same effect as the
            // `staking true` RPC: create the worker when this wallet was not
            // autostarted, and resume the existing worker idempotently.
            m_wallet->StartStake();
        } else {
            // Disabling is intentionally non-blocking for the GUI. The live
            // worker observes this atomic state and idles; wallet unload owns
            // the final stop/join. A later enable reuses the worker.
            m_wallet->m_enabled_staking = false;
        }
    }
    bool getEnabledStaking() override
    {
        return m_wallet->m_enabled_staking;
    }
    interfaces::WalletStakingInfo getStakingInfo() override
    {
        const StakingTelemetrySnapshot snapshot =
            m_wallet->GetStakingTelemetrySnapshot();
        interfaces::WalletStakingInfo info;
        info.sequence = snapshot.sequence;
        info.enabled = snapshot.enabled;
        info.worker_running = snapshot.worker_running;
        info.eligible = snapshot.eligible;
        info.tip_height = snapshot.tip_height;
        info.weight = snapshot.weight;
        info.weight_cache_height = snapshot.weight_cache_height;
        info.search_interval = snapshot.search_interval;
        info.reason = snapshot.reason;
        switch (snapshot.state) {
        case StakingTelemetryState::DISABLED:
            info.state = interfaces::WalletStakingState::DISABLED;
            break;
        case StakingTelemetryState::STARTING:
            info.state = interfaces::WalletStakingState::STARTING;
            break;
        case StakingTelemetryState::LOCKED:
            info.state = interfaces::WalletStakingState::LOCKED;
            break;
        case StakingTelemetryState::SYNCING:
            info.state = interfaces::WalletStakingState::SYNCING;
            break;
        case StakingTelemetryState::SEARCHING:
            info.state = interfaces::WalletStakingState::SEARCHING;
            break;
        case StakingTelemetryState::NO_ELIGIBLE_COINS:
            info.state = interfaces::WalletStakingState::NO_ELIGIBLE_COINS;
            break;
        case StakingTelemetryState::FAULT:
            info.state = interfaces::WalletStakingState::FAULT;
            break;
        case StakingTelemetryState::STOPPED:
            info.state = interfaces::WalletStakingState::STOPPED;
            break;
        }
        return info;
    }
    bool setPowMining(bool enabled, int threads, int cpu_percent, std::string& error,
                      bool allow_new_payout_key, bool* created_payout_key) override
    {
        bilingual_str werror;
        const bool ok = m_wallet->SetPowMining(
            enabled, threads, cpu_percent, werror, created_payout_key,
            allow_new_payout_key);
        if (!ok) {
            error = werror.original;
            m_wallet->WalletLogPrintf("Gold Rush PoW miner configuration failed: %s\n", werror.original);
        }
        return ok;
    }
    WalletPowMiningInfo getPowMiningInfo() override
    {
        ScopedDisallowShadowSolverActivityFullScan no_full_solver_scan;
        WalletPowMiningInfo info;
        info.enabled = m_wallet->m_pow_mining_enabled;
        info.state = m_wallet->m_pow_state;
        info.threads = m_wallet->m_pow_threads;
        info.cpu_percent = m_wallet->m_pow_cpu_percent;
        info.hashrate = m_wallet->m_pow_hashrate;
        info.claims_submitted = m_wallet->m_pow_claims_submitted;
        info.shadow_whitelist_height = SHADOW_WHITELIST_HEIGHT;
        info.shadow_reward_start_height = SHADOW_REWARD_START_HEIGHT;
        info.shadow_reward_end_height = SHADOW_REWARD_END_HEIGHT;
        std::set<CScript> wallet_scripts;
        std::vector<WalletShadowSolveReference> wallet_solves;
        TRY_LOCK(::cs_main, main_lock);
        if (!main_lock) {
            info.payout_address_available = false;
            info.wallet_goldrush_status_available = false;
            return info;
        }
        {
            TRY_LOCK(m_wallet->cs_wallet, wallet_lock);
            if (wallet_lock) {
                info.payout_address = m_wallet->m_pow_payout_quantum;
                const ShadowPowClaimStakeReserveInfo reserve =
                    m_wallet->GetShadowPowClaimStakeReserveInfoLocked();
                info.stake_reserve_available = reserve.wallet_tip_matches;
                info.configured_stake_reserve_coins =
                    reserve.configured_reserve_coins;
                info.mature_stakeable_legacy_coins = static_cast<int>(
                    reserve.mature_stakeable_legacy_coins);
                info.mature_stakeable_legacy_weight =
                    reserve.mature_stakeable_legacy_weight;
                info.reserved_stake_coins = static_cast<int>(
                    reserve.reserved_stake_coins);
                info.reserved_stake_weight = reserve.reserved_stake_weight;
                info.claim_coins_after_stake_reserve = static_cast<int>(
                    reserve.claim_coins_after_reserve);
                info.last_stake_coin_guard = reserve.last_stake_coin_guard;
                const std::vector<CScript> known_scripts =
                    m_wallet->GetOwnedLegacyShadowScripts(MAX_WALLET_SHADOW_SOLVE_REFERENCES);
                wallet_scripts.insert(known_scripts.begin(), known_scripts.end());
                const CBlockIndex* tip = m_wallet->chain().chainman().ActiveChain().Tip();
                if (tip) wallet_solves = GetWalletShadowSolveReferences(*m_wallet, tip->nHeight);
                for (const WalletShadowSolveReference& solve : wallet_solves) wallet_scripts.insert(solve.target);
            } else {
                info.payout_address_available = false;
                info.wallet_goldrush_status_available = false;
            }
        }
        if (m_wallet->HaveChain()) {
            ChainstateManager& chainman = m_wallet->chain().chainman();
            Chainstate& active = chainman.ActiveChainstate();
            const CBlockIndex* tip = active.m_chain.Tip();
            if (tip) {
                const Consensus::Params& consensus = Params().GetConsensus();
                info.current_height = tip->nHeight;
                const int next_height = tip->nHeight + 1;
                info.epoch_active = IsShadowGoldRushRewardActive(consensus, tip->GetMedianTimePast(), next_height);
                info.blocks_remaining = info.epoch_active ? std::max(0, SHADOW_REWARD_END_HEIGHT - next_height + 1) : 0;
                const ShadowGoldRushInfo shadow_info = GetShadowGoldRushInfo(active.CoinsTip(), tip);
                info.accrued_jackpot = shadow_info.pow_amount;
                info.next_claim_payout = info.epoch_active ? shadow_info.pow_amount + ShadowBaseReward(next_height) / 2 : shadow_info.pow_amount;
                info.pos_accrued_jackpot = shadow_info.pos_amount;
                const CAmount next_reward = info.epoch_active ? ShadowBaseReward(next_height) : 0;
                const CAmount next_pos_reward = next_reward - next_reward / 2;
                info.pos_next_payout_pool = shadow_info.pos_amount + next_pos_reward;
                const std::map<CScript, CScript> active_signals = GetActiveShadowSignalPayouts(active.CoinsTip(), tip);
                info.pos_active_signalers = static_cast<int>(active_signals.size());
                info.pos_estimated_payout_per_signaler = info.pos_active_signalers > 0
                    ? info.pos_next_payout_pool / info.pos_active_signalers
                    : 0;
                info.pos_claim_count = static_cast<int>(shadow_info.pos_count);
                info.pos_last_payout_height = static_cast<int>(shadow_info.last_pos_height);
                for (const CScript& script : wallet_scripts) {
                    const bool whitelisted = IsWhitelisted(active.CoinsTip(), script);
                    if (!whitelisted) continue;
                    ++info.wallet_whitelisted_scripts;
                    if (active_signals.count(script)) {
                        info.wallet_active_signal = true;
                    }
                }
                for (const WalletShadowSolveReference& solve : wallet_solves) {
                    if (!wallet_scripts.count(solve.target) || !IsWhitelisted(active.CoinsTip(), solve.target)) continue;
                    const CBlockIndex* solved = active.m_chain[solve.solve_height];
                    if (!solved || solved->GetBlockHash() != solve.solve_hash ||
                        !HasRecentShadowSolverActivity(active.CoinsTip(), tip, solve.target, solve.solve_height, solve.solve_hash)) {
                        continue;
                    }
                    info.wallet_recent_solve_qualified = true;
                    info.wallet_blocks_until_solver_expiry = std::max(
                        info.wallet_blocks_until_solver_expiry,
                        std::max(0, SHADOW_SOLVER_ACTIVITY_WINDOW - (tip->nHeight - static_cast<int>(solve.solve_height))));
                }
            }
        }
        return info;
    }
    WalletPowClaimRecoveryPolicy getPowClaimRecoveryPolicy() override
    {
        return MakeRecoveryPolicy(
            m_wallet->GetShadowPowClaimRecoveryPolicy());
    }
    interfaces::WalletPowClaimRecoveryPolicyMutationResult
    getPowClaimRecoveryPolicyState() override
    {
        return MakeRecoveryPolicyMutationResult(
            m_wallet->GetShadowPowClaimRecoveryPolicyState());
    }
    bool setPowClaimRecoveryPolicy(const WalletPowClaimRecoveryPolicy& policy,
                                   std::string& error) override
    {
        const interfaces::WalletPowClaimRecoveryPolicyMutationResult result =
            setPowClaimRecoveryPolicyDetailed(policy);
        error = result.success ? std::string{} : result.detail;
        return result.success;
    }
    interfaces::WalletPowClaimRecoveryPolicyMutationResult
    setPowClaimRecoveryPolicyDetailed(
        const WalletPowClaimRecoveryPolicy& policy) override
    {
        ShadowPowClaimRecoveryPolicy core;
        std::string error;
        if (!MakeCoreRecoveryPolicy(policy, core, error)) {
            const ShadowPowClaimRecoveryPolicyMutationResult state =
                m_wallet->GetShadowPowClaimRecoveryPolicyState();
            if (!state.authoritative_state_available) {
                return MakeRecoveryPolicyMutationResult(state);
            }
            interfaces::WalletPowClaimRecoveryPolicyMutationResult result;
            result.status = interfaces::WalletPowClaimRecoveryPolicyMutationStatus::INVALID_POLICY;
            result.reason_code = "invalid_policy";
            result.detail = std::move(error);
            result.authoritative_state_available = true;
            result.authoritative_policy =
                MakeRecoveryPolicy(state.authoritative_policy);
            return result;
        }
        return MakeRecoveryPolicyMutationResult(
            m_wallet->SetShadowPowClaimRecoveryPolicyDetailed(core));
    }
    interfaces::WalletPowClaimRecoveryReview getPowClaimRecoveryReview(
        const interfaces::WalletPowClaimRecoveryRequest& request) override
    {
        interfaces::WalletPowClaimRecoveryReview review;
        ShadowPowClaimRecoveryRequest core_request;
        if (!MakeCoreRecoveryRequest(request, core_request, review.error)) {
            return review;
        }
        // A review is always read-only even if a caller accidentally supplies
        // a mutating interface mode. Execution has a separate method.
        core_request.mode = ShadowPowClaimRecoveryMode::PREVIEW;
        core_request.execution_authority =
            ShadowPowClaimRecoveryExecutionAuthority::NONE;
        core_request.acknowledge_fee_and_conflict_risk = false;
        core_request.expected_plan_id.reset();

        const ShadowPowClaimRecoveryReview core_review =
            m_wallet->GetShadowPowClaimRecoveryReview(core_request);
        const ShadowPowClaimRecoveryInventory& inventory =
            core_review.inventory;
        const ShadowPowClaimRecoveryPlan& plan = core_review.plan;

        review.active_tip = inventory.active_tip.GetHex();
        review.active_height = inventory.active_height;
        review.wallet_generation = inventory.wallet_generation;
        review.wallet_tip_matches = inventory.wallet_tip_matches;
        review.raw_claim_objects = inventory.raw_claim_objects;
        review.live_claim_objects = inventory.live_claim_objects;
        review.quarantined_claim_objects = inventory.quarantined_claim_objects;
        review.blocking_components = inventory.blocking_components;
        review.retired_claim_objects = inventory.retired_claim_objects;
        review.retired_components = inventory.retired_components;
        review.resolved_components = inventory.resolved_components;
        review.components.reserve(inventory.components.size());
        for (const auto& component : inventory.components) {
            review.components.push_back(MakeRecoveryComponent(component));
        }
        review.unanchored_claim_txids =
            HashStrings(inventory.unanchored_claim_txids);
        review.plan = MakeRecoveryPlan(plan);
        review.usage = MakeRecoveryUsage(core_review.usage);
        review.policy_available = core_review.available ||
            core_review.status !=
                ShadowPowClaimRecoveryReviewStatus::POLICY_UNAVAILABLE;
        review.policy = MakeRecoveryPolicy(core_review.policy);
        review.reason_code = core_review.reason_code;
        review.consistent = core_review.consistent;
        if (!core_review.available) review.error = core_review.detail;
        return review;
    }
    interfaces::WalletPowClaimRecoveryExecution resolvePowClaims(
        const interfaces::WalletPowClaimRecoveryRequest& request) override
    {
        interfaces::WalletPowClaimRecoveryExecution execution;
        ShadowPowClaimRecoveryRequest core_request;
        if (!MakeCoreRecoveryRequest(request, core_request, execution.error)) {
            return execution;
        }
        const ShadowPowClaimRecoveryResult result =
            m_wallet->ResolveShadowPowClaims(core_request);
        execution.plan = MakeRecoveryPlan(result.plan);
        execution.success = result.success;
        execution.stale_plan = result.stale_plan;
        execution.signed_and_persisted = result.signed_and_persisted;
        execution.durable_state_changed = result.durable_state_changed;
        execution.durable_state_ambiguous = result.durable_state_ambiguous;
        execution.relay_authority_granted = result.relay_authority_granted;
        execution.broadcast = result.broadcast;
        execution.already_in_mempool = result.already_in_mempool;
        execution.relay_deferred = result.relay_deferred;
        execution.error = result.error;
        return execution;
    }
    bool adoptPowClaimRecoveryComponent(
        const std::string& selector_txid,
        const std::string& expected_tip,
        const std::string& expected_component_fingerprint,
        std::string& error) override
    {
        const interfaces::WalletPowClaimRecoveryAdoptionResult result =
            adoptPowClaimRecoveryComponentDetailed(
                selector_txid, expected_tip,
                expected_component_fingerprint);
        error = result.success ? std::string{} : result.detail;
        return result.success;
    }
    interfaces::WalletPowClaimRecoveryAdoptionResult
    adoptPowClaimRecoveryComponentDetailed(
        const std::string& selector_txid,
        const std::string& expected_tip,
        const std::string& expected_component_fingerprint) override
    {
        interfaces::WalletPowClaimRecoveryAdoptionResult invalid;
        uint256 selector;
        uint256 tip;
        uint256 fingerprint;
        if (!ParseHashStr(selector_txid, selector)) {
            invalid.status = interfaces::WalletPowClaimRecoveryAdoptionStatus::SELECTOR_NOT_FOUND;
            invalid.reason_code = "selector_not_found";
            invalid.detail = "Invalid claim transaction id";
            return invalid;
        }
        if (!ParseHashStr(expected_tip, tip)) {
            invalid.status = interfaces::WalletPowClaimRecoveryAdoptionStatus::STALE_TIP;
            invalid.reason_code = "stale_tip";
            invalid.detail = "Invalid expected active tip";
            return invalid;
        }
        if (!ParseHashStr(expected_component_fingerprint, fingerprint)) {
            invalid.status = interfaces::WalletPowClaimRecoveryAdoptionStatus::STALE_COMPONENT_FINGERPRINT;
            invalid.reason_code = "stale_component_fingerprint";
            invalid.detail = "Invalid component fingerprint";
            return invalid;
        }
        return MakeRecoveryAdoptionResult(
            m_wallet->AdoptShadowPowClaimRecoveryComponent(
                selector, tip, fingerprint));
    }
    util::Result<WalletQuantumAddressInfo> createQuantumAddress(const std::string& label) override
    {
        auto dest = m_wallet->GetNewQuantumDestination(label);
        if (!dest) return util::Error{util::ErrorString(dest)};
        LOCK(m_wallet->cs_wallet);
        const auto info = m_wallet->GetQuantumKeyInfo(*dest);
        if (!info) return util::Error{_("Error: Created quantum address is not wallet-backed")};
        return MakeWalletQuantumAddressInfo(*m_wallet, *info);
    }
    util::Result<WalletQuantumAddressInfo> createQuantumStakeAddress(const std::string& label, uint16_t unbonding_blocks) override
    {
        auto dest = m_wallet->GetNewTieredQuantumDestination(label, unbonding_blocks);
        if (!dest) return util::Error{util::ErrorString(dest)};
        LOCK(m_wallet->cs_wallet);
        const auto info = m_wallet->GetQuantumKeyInfo(*dest);
        if (!info) return util::Error{_("Error: Created quantum staking address is not wallet-backed")};
        return MakeWalletQuantumAddressInfo(*m_wallet, *info);
    }
    std::vector<WalletQuantumAddressInfo> listQuantumAddresses() override
    {
        std::vector<WalletQuantumAddressInfo> result;
        TRY_LOCK(m_wallet->cs_wallet, wallet_lock);
        if (!wallet_lock) return result;
        const auto infos = m_wallet->ListQuantumKeyInfos();
        result.reserve(infos.size());
        for (const QuantumKeyInfo& info : infos) {
            result.push_back(MakeWalletQuantumAddressInfo(*m_wallet, info));
        }
        return result;
    }
    std::vector<WalletQuantumColdStakeInfo> listQuantumColdStakeDelegations() override
    {
        std::vector<WalletQuantumColdStakeInfo> result;
        TRY_LOCK(m_wallet->cs_wallet, wallet_lock);
        if (!wallet_lock) return result;
        const auto infos = m_wallet->ListQuantumColdStakeDelegationInfos();
        result.reserve(infos.size());
        for (const QuantumColdStakeDelegationInfo& info : infos) {
            result.push_back(MakeWalletQuantumColdStakeInfo(*m_wallet, info));
        }
        return result;
    }
    WalletQuantumPoolInfo getQuantumPoolInfo() override
    {
        WalletQuantumPoolInfo result;
        if (!m_wallet->HaveChain()) {
            result.available = false;
            return result;
        }

        const std::vector<LocalOperatorBondCandidate> local_operator_bonds =
            FindWalletOperatorBondCandidates(*m_wallet);
        const std::map<uint256, std::vector<node::QuantumPoolClaim>> local_claims =
            FindWalletQuantumPoolClaims(*m_wallet);

        TRY_LOCK(::cs_main, main_lock);
        if (!main_lock) {
            result.available = false;
            return result;
        }

        ChainstateManager& chainman = m_wallet->chain().chainman();
        const CCoinsViewCache& view = chainman.ActiveChainstate().CoinsTip();
        result.total_coldstake = node::ComputeQuantumColdStakeTotal(view);
        result.cap_bps = node::QUANTUM_POOL_CAP_BPS;

        for (const auto& [staker_hash, claims] : local_claims) {
            node::UpsertQuantumPoolClaims(staker_hash, claims);
        }

        for (const LocalOperatorBondCandidate& candidate : local_operator_bonds) {
            if (!node::VerifyQuantumPoolOperatorCommitment(view, candidate.staking_pubkey, candidate.outpoint)) {
                continue;
            }
            const uint256 staker_hash = node::QuantumPoolHashPubKey(candidate.staking_pubkey);
            node::UpsertQuantumPoolOperator(
                staker_hash,
                candidate.staking_pubkey,
                node::GetQuantumPoolClaims(staker_hash),
                /*operator_commitment_verified=*/true,
                candidate.outpoint);
        }

        const std::vector<uint256> operators = node::ListQuantumPoolOperators();
        result.operators.reserve(operators.size());
        for (const uint256& staker_hash : operators) {
            const node::QuantumPoolShare share = node::ComputeQuantumPoolShare(view, staker_hash, node::GetQuantumPoolClaims(staker_hash));

            WalletQuantumPoolOperatorInfo entry;
            entry.staking_pubkey_hash = share.operator_share.staker_pubkey_hash.GetHex();
            if (!share.operator_share.staker_pubkey.empty()) {
                entry.staking_pubkey = HexStr(share.operator_share.staker_pubkey);
            }
            entry.verified_value = share.operator_share.verified_value;
            entry.share_bps = node::QuantumPoolShareBps(share.operator_share.verified_value, share.total_coldstake);
            entry.verified_claims = share.operator_share.verified_claims;
            entry.invalid_claims = share.operator_share.invalid_claims;
            entry.operator_commitment_verified = share.operator_share.operator_commitment_verified;
            entry.over_cap = node::WouldQuantumPoolExceedCap(share.total_coldstake, share.operator_share.verified_value, 0);
            result.operators.push_back(std::move(entry));
        }
        return result;
    }
    WalletQuantumOperatorBondInfo getQuantumOperatorBondInfo(const std::string& operator_address) override
    {
        return MakeWalletOperatorBondInfo(*m_wallet, operator_address);
    }
    util::Result<WalletQuantumOperatorBondTx> fundQuantumOperatorBond(const std::string& operator_address, CAmount amount, bool allow_new_quantum_key) override
    {
        return FundTieredStakeAddress(
            *m_wallet,
            operator_address,
            amount,
            /*require_operator_lock=*/true,
            "Blackcoin cold-stake operator bond",
            allow_new_quantum_key);
    }
    util::Result<WalletQuantumOperatorBondTx> withdrawQuantumOperatorBond(const std::string& operator_address, bool allow_new_quantum_key) override
    {
        return WithdrawTieredStakeAddress(
            *m_wallet,
            operator_address,
            /*require_operator_lock=*/true,
            "coldstake-operator-unbonding",
            "coldstake-operator-withdrawal",
            "Blackcoin cold-stake operator unbond",
            "Blackcoin cold-stake operator withdrawal",
            std::nullopt,
            /*allow_all_outputs=*/true,
            allow_new_quantum_key);
    }
    WalletQuantumOperatorBondInfo getQuantumStakeAddressBondInfo(const std::string& stake_address) override
    {
        return MakeWalletTieredStakeBondInfo(*m_wallet, stake_address, /*require_operator_lock=*/false);
    }
    std::vector<WalletQuantumStakeOutputInfo> listQuantumStakeOutputs(const std::string& stake_address) override
    {
        return ListTieredStakeOutputs(*m_wallet, stake_address, /*require_operator_lock=*/false);
    }
    util::Result<WalletQuantumOperatorBondTx> fundQuantumStakeAddress(const std::string& stake_address, CAmount amount, bool allow_new_quantum_key) override
    {
        return FundTieredStakeAddress(
            *m_wallet,
            stake_address,
            amount,
            /*require_operator_lock=*/false,
            "Blackcoin quantum staking address funding",
            allow_new_quantum_key);
    }
    util::Result<WalletQuantumOperatorBondTx> withdrawQuantumStakeAddress(const std::string& stake_address, bool allow_new_quantum_key) override
    {
        return WithdrawTieredStakeAddress(
            *m_wallet,
            stake_address,
            /*require_operator_lock=*/false,
            "quantum-stake-unbonding",
            "quantum-stake-withdrawal",
            "Blackcoin quantum staking address unbond",
            "Blackcoin quantum staking address withdrawal",
            std::nullopt,
            /*allow_all_outputs=*/true,
            allow_new_quantum_key);
    }
    util::Result<WalletQuantumOperatorBondTx> withdrawQuantumStakeOutput(const std::string& stake_address, const COutPoint& outpoint, bool allow_new_quantum_key) override
    {
        return WithdrawTieredStakeAddress(
            *m_wallet,
            stake_address,
            /*require_operator_lock=*/false,
            "quantum-stake-unbonding",
            "quantum-stake-withdrawal",
            "Blackcoin quantum staking output unbond",
            "Blackcoin quantum staking output withdrawal",
            outpoint,
            /*allow_all_outputs=*/false,
            allow_new_quantum_key);
    }
    util::Result<WalletQuantumColdStakeInfo> createQuantumColdStakeAddress(const std::string& staking_pubkey_hex, const std::string& label, uint16_t unbonding_blocks) override
    {
        if (!IsHex(staking_pubkey_hex)) {
            return util::Error{_("Error: staking public key must be hex")};
        }
        const std::vector<unsigned char> staking_pubkey = ParseHex(staking_pubkey_hex);
        if (staking_pubkey.size() != ML_DSA::PUBLICKEY_BYTES) {
            return util::Error{_("Error: staking public key must be exactly 1312 bytes")};
        }

        const std::string owner_label = label.empty() ? "coldstake-owner" : label + " owner";
        auto owner_dest = m_wallet->GetNewQuantumDestination(owner_label);
        if (!owner_dest) return util::Error{util::ErrorString(owner_dest)};

        LOCK(m_wallet->cs_wallet);
        const auto owner_info = m_wallet->GetQuantumKeyInfo(*owner_dest);
        if (!owner_info) return util::Error{_("Error: Created quantum owner address is not wallet-backed")};

        auto qcs_dest = m_wallet->AddQuantumColdStakeDelegation(staking_pubkey, owner_info->public_key, label, GetTime(), /*record_as_receive=*/true, unbonding_blocks, /*tiered=*/unbonding_blocks > 0);
        if (!qcs_dest) return util::Error{util::ErrorString(qcs_dest)};

        const auto qcs_info = m_wallet->GetQuantumColdStakeDelegationInfo(*qcs_dest);
        if (!qcs_info) return util::Error{_("Error: Created quantum cold-stake address is not wallet-backed")};
        return MakeWalletQuantumColdStakeInfo(*m_wallet, *qcs_info);
    }
    WalletQuantumColdStakeBalanceInfo getQuantumColdStakeBalanceInfo(const std::string& coldstake_address) override
    {
        return MakeWalletColdStakeBalanceInfo(*m_wallet, coldstake_address);
    }
    util::Result<WalletQuantumOperatorBondTx> fundQuantumColdStakeAddress(const std::string& coldstake_address, CAmount amount, bool allow_new_quantum_key) override
    {
        return FundColdStakeDelegationAddress(*m_wallet, coldstake_address, amount, /*allow_goldrush_migration=*/true, allow_new_quantum_key);
    }
    util::Result<WalletQuantumOperatorBondTx> withdrawQuantumColdStakeAddress(const std::string& coldstake_address, bool allow_new_quantum_key) override
    {
        return WithdrawColdStakeDelegationAddress(*m_wallet, coldstake_address, std::nullopt, /*allow_all_outputs=*/true, allow_new_quantum_key);
    }
    util::Result<WalletQuantumRedelegationInfo> redelegateQuantumColdStake(const std::string& source_coldstake_address, const std::string& target_staking_pubkey_hex, bool dry_run, const std::string& label, bool allow_new_quantum_key) override
    {
        const CTxDestination source_dest = DecodeDestination(source_coldstake_address);
        if (!IsValidDestination(source_dest) || !IsQuantumColdStakeDestination(source_dest)) {
            return util::Error{Untranslated("Source is not a Quantum Cold-Stake address")};
        }
        if (!IsHex(target_staking_pubkey_hex)) {
            return util::Error{Untranslated("Target staking public key must be a hex string")};
        }
        const std::vector<unsigned char> target_pubkey = ParseHex(target_staking_pubkey_hex);
        if (target_pubkey.size() != ML_DSA::PUBLICKEY_BYTES) {
            return util::Error{Untranslated(strprintf("Target staking public key must be exactly %u bytes", ML_DSA::PUBLICKEY_BYTES))};
        }

        QuantumColdStakeRedelegationOptions options;
        options.dry_run = dry_run;
        options.allow_new_quantum_key = allow_new_quantum_key;
        if (!label.empty()) options.label = label;

        QuantumColdStakeRedelegationResult result;
        bilingual_str error;
        if (!CreateQuantumColdStakeRedelegationTransaction(*m_wallet, source_dest, target_pubkey, options, result, error)) {
            return util::Error{error};
        }

        WalletQuantumRedelegationInfo info;
        info.dry_run = result.dry_run;
        info.source_address = EncodeDestination(result.source_dest);
        info.target_address = EncodeDestination(result.target_dest);
        info.target_wallet_backed = result.target_wallet_backed;
        info.input_amount = result.input_amount;
        info.output_amount = result.output_amount;
        info.fee = result.fee;
        info.vsize = result.vsize;
        info.operator_commitment_verified = result.operator_commitment_verified;
        info.post_total_coldstake = result.post_total_coldstake;
        info.post_operator_value = result.post_operator_value;
        info.post_share_bps = result.post_share_bps;
        info.would_exceed_cap = result.would_exceed_cap;
        info.cap_enforced = result.cap_enforced;
        info.cap_filter_unlocked = result.cap_filter_unlocked;
        if (!result.dry_run && result.tx) info.txid = result.tx->GetHash().GetHex();
        return info;
    }
    util::Result<WalletUTXOOptimizationTx> optimizeUTXOSet(const std::string& dest_address, CAmount utxo_amount) override
    {
        const CTxDestination dest = DecodeDestination(dest_address);
        if (!IsValidDestination(dest)) {
            return util::Error{Untranslated("Invalid destination address")};
        }

        CTransactionRef tx;
        CAmount fee{0};
        auto res = CreateUTXOOptimizationTransaction(*m_wallet, dest, utxo_amount, std::nullopt);
        if (!res) {
            return util::Error{util::ErrorString(res)};
        }
        tx = res->tx;
        fee = res->fee;
        if (auto commit = CommitWalletTransactionOrError(*m_wallet, tx, {}, "Blackcoin UTXO optimization"); !commit) {
            return util::Error{util::ErrorString(commit)};
        }

        WalletUTXOOptimizationTx out;
        out.txid = tx->GetHash().GetHex();
        out.fee = fee;
        const CScript dest_script = GetScriptForDestination(dest);
        for (const CTxOut& txout : tx->vout) {
            if (txout.scriptPubKey == dest_script && txout.nValue == utxo_amount) {
                out.outputs++;
                out.output_amount += txout.nValue;
            }
        }
        return out;
    }
    WalletMigrationStatus getMigrationStatus() override
    {
        WalletMigrationStatus status;
        if (!m_wallet->HaveChain()) return status;

        TRY_LOCK(::cs_main, main_lock);
        if (!main_lock) {
            status.available = false;
            return status;
        }
        TRY_LOCK(m_wallet->cs_wallet, wallet_lock);
        if (!wallet_lock) {
            status.available = false;
            return status;
        }

        const Consensus::Params& consensus = Params().GetConsensus();
        ChainstateManager& chainman = m_wallet->chain().chainman();
        const CBlockIndex* tip = chainman.ActiveChain().Tip();
        const int64_t mtp = tip ? tip->GetMedianTimePast() : 0;
        const int next_height = tip ? tip->nHeight + 1 : 0;
        const bool scheduled = consensus.IsMigrationEndScheduled();
        const bool passed = consensus.IsQuantumFinalLockout(mtp, next_height);
        const int64_t secs = (scheduled && consensus.nQuantumMigrationDeadlineTime > mtp)
                                 ? consensus.nQuantumMigrationDeadlineTime - mtp : 0;
        const bool height_authoritative = consensus.UsesHeightLifecycle() && consensus.IsQuantumLifecycleScheduleOrdered();
        const int64_t exact_blocks = height_authoritative && next_height <= consensus.nQuantumMigrationEndHeight
            ? consensus.nQuantumMigrationEndHeight - next_height + 1 : 0;
        const bool quantum_active = IsQuantumWitnessSpendActive(consensus, mtp, next_height);

        status.phase = QuantumQuasarPhaseName(consensus.GetQuantumQuasarPhase(mtp, next_height));
        status.median_time = mtp;
        status.deadline_mtp = consensus.nQuantumMigrationDeadlineTime;
        status.deadline_height = consensus.nQuantumMigrationEndHeight;
        status.deadline_scheduled = scheduled;
        status.height_boundaries_authoritative = height_authoritative;
        status.seconds_until_deadline = secs;
        status.blocks_until_deadline = exact_blocks;
        status.blocks_until_deadline_est = secs / std::max<int64_t>(1, consensus.nTargetSpacing);
        status.deadline_passed = passed;
        status.goldrush_remigration_active = quantum_active;
        status.quantum_spends_active = quantum_active;

        const CCoinsViewCache& view = chainman.ActiveChainstate().CoinsTip();
        for (const COutput& out : AvailableCoinsListUnspent(*m_wallet).All()) {
            const CScript& spk = out.txout.scriptPubKey;
            if (IsQuantumMigrationScript(spk)) {
                CTxDestination dest;
                const bool wallet_owned = ExtractDestination(spk, dest) && m_wallet->GetQuantumKeyInfo(dest).has_value();
                CScript marker_script;
                if (IsLockedGoldRushPayoutOutput(view, out.outpoint, consensus,
                        mtp, next_height, &marker_script) && marker_script == spk) {
                    status.goldrush_reward_amount_needing_move += out.txout.nValue;
                    ++status.goldrush_reward_outputs_needing_move;
                } else if (wallet_owned) {
                    status.migrated_quantum_amount += out.txout.nValue;
                    ++status.migrated_quantum_outputs;
                    if (IsDirectQuantumMigrationScript(spk)) {
                        status.direct_quantum_amount += out.txout.nValue;
                        ++status.direct_quantum_outputs;
                    } else {
                        status.staked_quantum_amount += out.txout.nValue;
                        ++status.staked_quantum_outputs;
                    }
                }
            } else if (IsQuantumColdStakeScript(spk)) {
                continue;
            } else if (!IsEUTXOScript(spk) && out.spendable) {
                status.eligible_legacy_amount += out.txout.nValue;
                ++status.eligible_legacy_inputs;
            }
        }

        if (passed) {
            status.advice = "Deadline passed. Remaining legacy coins are permanently unspendable.";
        } else if (status.goldrush_reward_outputs_needing_move > 0) {
            status.advice = "Gold Rush reward outputs remain locked until the Gold Rush ends; they then become ordinary quantum funds after normal maturity.";
        } else if (status.eligible_legacy_inputs == 0) {
            status.advice = "No legacy coins remain to migrate.";
        } else if (!scheduled) {
            status.advice = "No deadline is scheduled yet, but this wallet can create quantum addresses now.";
        } else {
            status.advice = "Move legacy coins into a quantum address before the deadline.";
        }
        return status;
    }
    WalletQuantumFundingStatus getQuantumFundingStatus() override
    {
        WalletQuantumFundingStatus status;
        TRY_LOCK(::cs_main, main_lock);
        if (!main_lock || !m_wallet->HaveChain()) return status;

        const CBlockIndex* tip = m_wallet->chain().chainman().ActiveChain().Tip();
        if (!tip) return status;

        const Consensus::Params& consensus = Params().GetConsensus();
        const int64_t mtp = tip->GetMedianTimePast();
        const int next_height = tip->nHeight + 1;
        status.available = true;
        status.quantum_outputs_active = IsQuantumWitnessSpendActive(consensus, mtp, next_height);
        status.legacy_migration_active = status.quantum_outputs_active &&
                                         consensus.IsQuantumMigrationWindow(mtp, next_height);
        status.stake_tiers_active = IsQuantumStakeTiersActive(consensus, mtp, next_height);
        return status;
    }
    util::Result<WalletQuantumActionTx> migrateLegacyToQuantum(bool allow_new_quantum_key) override
    {
        return CreateQuantumMigrationSweep(*m_wallet, /*goldrush_rewards_only=*/false, /*allow_goldrush_epoch=*/false, /*destination_label=*/"", /*comment_override=*/"", allow_new_quantum_key);
    }
    util::Result<WalletQuantumActionTx> migrateGoldRushRewards(bool allow_new_quantum_key) override
    {
        return CreateQuantumMigrationSweep(*m_wallet, /*goldrush_rewards_only=*/true, /*allow_goldrush_epoch=*/true, /*destination_label=*/"", /*comment_override=*/"", allow_new_quantum_key);
    }
    std::vector<WalletRGBAssetInfo> listRGBAssets(bool include_spent = false) override
    {
        return ListWalletRGBAssets(*m_wallet, include_spent);
    }
    std::vector<WalletEUTXOStateInfo> listEUTXOStates(bool include_spent = false) override
    {
        return ListWalletEUTXOStates(*m_wallet, include_spent);
    }
    WalletDemurrageInfo getDemurrageInfo() override
    {
        return GetWalletDemurrageInfo(*m_wallet);
    }
    util::Result<WalletQuantumActionTx> sendDemurrageAttestation(const std::string& address) override
    {
        return CreateWalletDemurrageAttestation(*m_wallet, address);
    }
    util::Result<WalletQuantumActionTx> sweepDemurrageDecay(bool allow_new_quantum_key) override
    {
        return CreateWalletDemurrageSweep(*m_wallet, allow_new_quantum_key);
    }
    bool isLegacy() override { return m_wallet->IsLegacy(); }
    std::unique_ptr<Handler> handleUnload(UnloadFn fn) override
    {
        return MakeSignalHandler(m_wallet->NotifyUnload.connect(fn));
    }
    std::unique_ptr<Handler> handleShowProgress(ShowProgressFn fn) override
    {
        return MakeSignalHandler(m_wallet->ShowProgress.connect(fn));
    }
    std::unique_ptr<Handler> handleStatusChanged(StatusChangedFn fn) override
    {
        return MakeSignalHandler(m_wallet->NotifyStatusChanged.connect([fn](CWallet*) { fn(); }));
    }
    std::unique_ptr<Handler> handleAddressBookChanged(AddressBookChangedFn fn) override
    {
        return MakeSignalHandler(m_wallet->NotifyAddressBookChanged.connect(
            [fn](const CTxDestination& address, const std::string& label, bool is_mine,
                 AddressPurpose purpose, ChangeType status) { fn(address, label, is_mine, purpose, status); }));
    }
    std::unique_ptr<Handler> handleTransactionChanged(TransactionChangedFn fn) override
    {
        return MakeSignalHandler(m_wallet->NotifyTransactionChanged.connect(
            [fn](const uint256& txid, ChangeType status) { fn(txid, status); }));
    }
    std::unique_ptr<Handler> handleWatchOnlyChanged(WatchOnlyChangedFn fn) override
    {
        return MakeSignalHandler(m_wallet->NotifyWatchonlyChanged.connect(fn));
    }
    std::unique_ptr<Handler> handleCanGetAddressesChanged(CanGetAddressesChangedFn fn) override
    {
        return MakeSignalHandler(m_wallet->NotifyCanGetAddressesChanged.connect(fn));
    }
    CWallet* wallet() override { return m_wallet.get(); }

    WalletContext& m_context;
    std::shared_ptr<CWallet> m_wallet;
};

class WalletLoaderImpl : public WalletLoader
{
public:
    WalletLoaderImpl(Chain& chain, ArgsManager& args)
    {
        m_context.chain = &chain;
        m_context.args = &args;
    }
    ~WalletLoaderImpl() override { UnloadWallets(m_context); }

    //! ChainClient methods
    void registerRpcs() override
    {
        std::vector<Span<const CRPCCommand>> commands;
        commands.push_back(GetWalletRPCCommands());
        commands.push_back(m_context.chain->getStakingRPCCommands());
        for(size_t i = 0; i < commands.size(); i++) {
            for (const CRPCCommand& command : commands[i]) {
                m_rpc_commands.emplace_back(command.category, command.name, [this, &command](const JSONRPCRequest& request, UniValue& result, bool last_handler) {
                    JSONRPCRequest& wallet_request = (JSONRPCRequest&)request;
                    wallet_request.context = &m_context;
                    return command.actor(wallet_request, result, last_handler);
                }, command.argNames, command.unique_id);
                m_rpc_handlers.emplace_back(m_context.chain->handleRpc(m_rpc_commands.back()));
            }
        }
    }
    bool verify() override { return VerifyWallets(m_context); }
    bool load() override { return LoadWallets(m_context); }
    void start(CScheduler& scheduler) override { return StartWallets(m_context, scheduler); }
    void flush() override { return FlushWallets(m_context); }
    void stop() override { return StopWallets(m_context); }
    void setMockTime(int64_t time) override { return SetMockTime(time); }
    void transactionSubmittedByRpc(const CTransactionRef& tx) override
    {
        for (const auto& wallet : GetWallets(m_context)) {
            wallet->transactionSubmittedByRpc(tx);
        }
    }

    //! WalletLoader methods
    util::Result<std::unique_ptr<Wallet>> createWallet(const std::string& name, const SecureString& passphrase, uint64_t wallet_creation_flags, std::vector<bilingual_str>& warnings) override
    {
        DatabaseOptions options;
        DatabaseStatus status;
        ReadDatabaseArgs(*m_context.args, options);
        options.require_create = true;
        options.create_flags = wallet_creation_flags;
        options.create_passphrase = passphrase;
        bilingual_str error;
        std::unique_ptr<Wallet> wallet{MakeWallet(m_context, CreateWallet(m_context, name, /*load_on_start=*/true, options, status, error, warnings))};
        if (wallet) {
            return {std::move(wallet)};
        } else {
            return util::Error{error};
        }
    }
    util::Result<std::unique_ptr<Wallet>> loadWallet(const std::string& name, std::vector<bilingual_str>& warnings) override
    {
        DatabaseOptions options;
        DatabaseStatus status;
        ReadDatabaseArgs(*m_context.args, options);
        options.require_existing = true;
        bilingual_str error;
        std::unique_ptr<Wallet> wallet{MakeWallet(m_context, LoadWallet(m_context, name, /*load_on_start=*/true, options, status, error, warnings))};
        if (wallet) {
            return {std::move(wallet)};
        } else {
            return util::Error{error};
        }
    }
    util::Result<std::unique_ptr<Wallet>> restoreWallet(const fs::path& backup_file, const std::string& wallet_name, std::vector<bilingual_str>& warnings) override
    {
        DatabaseStatus status;
        bilingual_str error;
        std::unique_ptr<Wallet> wallet{MakeWallet(m_context, RestoreWallet(m_context, backup_file, wallet_name, /*load_on_start=*/true, status, error, warnings))};
        if (wallet) {
            return {std::move(wallet)};
        } else {
            return util::Error{error};
        }
    }
    util::Result<WalletMigrationResult> migrateWallet(const std::string& name, const SecureString& passphrase) override
    {
        auto res = wallet::MigrateLegacyToDescriptor(name, passphrase, m_context);
        if (!res) return util::Error{util::ErrorString(res)};
        WalletMigrationResult out{
            .wallet = MakeWallet(m_context, res->wallet),
            .watchonly_wallet_name = res->watchonly_wallet ? std::make_optional(res->watchonly_wallet->GetName()) : std::nullopt,
            .solvables_wallet_name = res->solvables_wallet ? std::make_optional(res->solvables_wallet->GetName()) : std::nullopt,
            .backup_path = res->backup_path,
        };
        return {std::move(out)}; // std::move to work around clang bug
    }
    std::string getWalletDir() override
    {
        return fs::PathToString(GetWalletDir());
    }
    std::vector<std::string> listWalletDir() override
    {
        std::vector<std::string> paths;
        for (auto& path : ListDatabases(GetWalletDir())) {
            paths.push_back(fs::PathToString(path));
        }
        return paths;
    }
    std::vector<std::unique_ptr<Wallet>> getWallets() override
    {
        std::vector<std::unique_ptr<Wallet>> wallets;
        for (const auto& wallet : GetWallets(m_context)) {
            wallets.emplace_back(MakeWallet(m_context, wallet));
        }
        return wallets;
    }
    std::unique_ptr<Handler> handleLoadWallet(LoadWalletFn fn) override
    {
        return HandleLoadWallet(m_context, std::move(fn));
    }
    WalletContext* context() override  { return &m_context; }

    WalletContext m_context;
    const std::vector<std::string> m_wallet_filenames;
    std::vector<std::unique_ptr<Handler>> m_rpc_handlers;
    std::list<CRPCCommand> m_rpc_commands;
};
} // namespace
} // namespace wallet

namespace interfaces {
std::unique_ptr<Wallet> MakeWallet(wallet::WalletContext& context, const std::shared_ptr<wallet::CWallet>& wallet) { return wallet ? std::make_unique<wallet::WalletImpl>(context, wallet) : nullptr; }

std::unique_ptr<WalletLoader> MakeWalletLoader(Chain& chain, ArgsManager& args)
{
    return std::make_unique<wallet::WalletLoaderImpl>(chain, args);
}
} // namespace interfaces
