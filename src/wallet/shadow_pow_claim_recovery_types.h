// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_TYPES_H
#define BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_TYPES_H

#include <consensus/amount.h>
#include <policy/feerate.h>
#include <primitives/transaction.h>
#include <serialize.h>
#include <shadow.h>
#include <uint256.h>

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace wallet {

// Durable CWalletTx metadata shared by claim creation, repair, recovery, RPC,
// and GUI code.  The string values are wallet-database schema and must not be
// renamed after release.
inline constexpr char SHADOW_POW_CLAIM_AUTHORED_KEY[]{"qq_shadow_pow_authored"};
inline constexpr char SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY[]{"qq_shadow_pow_created_height"};
inline constexpr char SHADOW_POW_CLAIM_CREATED_TIP_KEY[]{"qq_shadow_pow_created_tip"};
inline constexpr char SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY[]{"qq_shadow_pow_first_quarantine_height"};
inline constexpr char SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY[]{"qq_shadow_pow_first_quarantine_tip"};
// Branch-qualified observation used only for the automatic stale-depth gate.
// Repair replaces this pair after a reorg; the immutable FIRST pair remains
// audit provenance and is never used to infer current-branch age.
inline constexpr char SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY[]{"qq_shadow_pow_branch_quarantine_height"};
inline constexpr char SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY[]{"qq_shadow_pow_branch_quarantine_tip"};
// A zero-payment retirement is a reversible, branch-scoped wallet fact. It
// releases only a locally-authored legacy claim that cannot qualify for the
// authenticated same-anchor lineage. Recoverable bound/schema claims are
// never retired. The observation block must remain an ancestor of the active
// tip; otherwise the wallet reopens and reclassifies the claim.
inline constexpr char SHADOW_POW_CLAIM_EXPIRED_RETIRED_KEY[]{"qq_shadow_pow_expired_retired"};
inline constexpr char SHADOW_POW_CLAIM_EXPIRED_RETIRED_HEIGHT_KEY[]{"qq_shadow_pow_expired_retired_height"};
inline constexpr char SHADOW_POW_CLAIM_EXPIRED_RETIRED_TIP_KEY[]{"qq_shadow_pow_expired_retired_tip"};
inline constexpr char SHADOW_POW_CLAIM_ADOPTED_KEY[]{"qq_shadow_pow_adopted"};
// Explicit adoption is authenticated to both the tip at which the operator
// reviewed the component and the stable anchor-generation identity that was
// reviewed.  The marker alone never grants trusted provenance.
inline constexpr char SHADOW_POW_CLAIM_ADOPTION_TIP_KEY[]{"qq_shadow_pow_adoption_tip"};
inline constexpr char SHADOW_POW_CLAIM_ADOPTION_FINGERPRINT_KEY[]{"qq_shadow_pow_adoption_fingerprint"};
// Same-anchor claim refreshes form one durable, append-only lineage. The
// Every newly-authored root carries ordinal zero and names itself as the root;
// later siblings name their direct parent. A narrowly-defined legacy QQP2 root
// may be reconstructed without these fields. All hashes are authenticated
// again against the confirmed anchor generation before another refresh.
inline constexpr char SHADOW_POW_CLAIM_LINEAGE_SCHEMA_KEY[]{"qq_shadow_pow_lineage_schema"};
inline constexpr char SHADOW_POW_CLAIM_LINEAGE_SCHEMA_VERSION[]{"1"};
inline constexpr char SHADOW_POW_CLAIM_LINEAGE_FAMILY_KEY[]{"qq_shadow_pow_lineage_family"};
inline constexpr char SHADOW_POW_CLAIM_LINEAGE_ROOT_KEY[]{"qq_shadow_pow_lineage_root"};
inline constexpr char SHADOW_POW_CLAIM_LINEAGE_PARENT_KEY[]{"qq_shadow_pow_lineage_parent"};
inline constexpr char SHADOW_POW_CLAIM_LINEAGE_ORDINAL_KEY[]{"qq_shadow_pow_lineage_ordinal"};
inline constexpr char SHADOW_POW_RESOLUTION_SCHEMA_KEY[]{"qq_shadow_pow_resolution_schema"};
inline constexpr char SHADOW_POW_RESOLUTION_SCHEMA_VERSION[]{"1"};
inline constexpr char SHADOW_POW_RESOLUTION_ANCHOR_TXID_KEY[]{"qq_shadow_pow_resolution_anchor_txid"};
inline constexpr char SHADOW_POW_RESOLUTION_ANCHOR_VOUT_KEY[]{"qq_shadow_pow_resolution_anchor_vout"};
inline constexpr char SHADOW_POW_RESOLUTION_FINGERPRINT_KEY[]{"qq_shadow_pow_resolution_fingerprint"};
inline constexpr char SHADOW_POW_RESOLUTION_ORIGIN_KEY[]{"qq_shadow_pow_resolution_origin"};
inline constexpr char SHADOW_POW_RESOLUTION_ORIGIN_MANUAL[]{"manual"};
inline constexpr char SHADOW_POW_RESOLUTION_ORIGIN_AUTOMATIC[]{"automatic"};
inline constexpr char SHADOW_POW_RESOLUTION_CREATED_HEIGHT_KEY[]{"qq_shadow_pow_resolution_created_height"};
inline constexpr char SHADOW_POW_RESOLUTION_CREATED_TIME_KEY[]{"qq_shadow_pow_resolution_created_time"};
// A signed draft is deliberately not restart/generic-rebroadcast authority.
// Only COMMIT_AND_BROADCAST durably changes this canonical byte flag to "1"
// before attempting relay. A mempool-observed exact draft may be promoted by
// the resolver after it proves that those same bytes were explicitly relayed.
inline constexpr char SHADOW_POW_RESOLUTION_RELAY_AUTHORIZED_KEY[]{"qq_shadow_pow_resolution_relay_authorized"};
// Older releases use a selected claim txid as this marker's value. New code
// retains it for downgrade-safe non-rebroadcast behavior while the anchor
// metadata above is authoritative for idempotency.
inline constexpr char SHADOW_POW_LEGACY_CLEANUP_FOR_KEY[]{"qq_shadow_pow_cleanup_for"};
inline constexpr char SHADOW_POW_QUARANTINE_MARKER_KEY[]{"qq_shadow_pow_quarantine"};

enum class ShadowPowClaimRecoveryState : uint8_t {
    LIVE,
    TRANSIENT,
    INDETERMINATE,
    CURRENT_BRANCH_INELIGIBLE,
    TERMINAL_ON_PINNED_TIP,
    RETIRED_ON_ACTIVE_BRANCH,
    RESOLUTION_PENDING,
    RESOLVED_ON_ACTIVE_CHAIN,
};

enum class ShadowPowClaimRecoveryProvenance : uint8_t {
    EXPLICIT_AUTHORED,
    EXPLICIT_ADOPTED,
    LEGACY_WALLET_AUTHORED,
    UNKNOWN,
};

enum class ShadowPowClaimRecoveryNodeKind : uint8_t {
    CLAIM,
    MANAGED_RESOLUTION,
    LEGACY_RESOLUTION,
    ORDINARY,
};

struct ShadowPowClaimRecoveryNode
{
    uint256 txid;
    ShadowPowClaimRecoveryNodeKind kind{ShadowPowClaimRecoveryNodeKind::ORDINARY};
    ShadowPowClaimRecoveryProvenance provenance{ShadowPowClaimRecoveryProvenance::UNKNOWN};
    ShadowPowClaimMempoolDisposition disposition{ShadowPowClaimMempoolDisposition::LOCAL_STATE_ERROR};
    /** Invalid on this tip, but the same unbound proof bytes are rehashed
     * against descendant contexts and can become valid later. */
    bool proof_may_revalidate_on_descendant{false};
    bool active_chain_confirmed{false};
    bool in_mempool{false};
    bool abandoned{false};
    bool quarantined{false};
    bool expired_locally_retired{false};
    bool expected_shape{false};
    bool wallet_authored{false};
    bool wallet_from_me{false};
    int created_height{-1};
    uint256 created_tip;
    bool authored_metadata_valid{false};
    /** The authored next-block height and its preceding-tip hash identify an
     * active-branch edge in the inventory snapshot. Parsing the fields alone
     * is not sufficient authority for the mining compatibility gate. */
    bool authored_tip_active_branch_bound{false};
    bool claim_descriptor_valid{false};
    bool proof_evaluation_skipped_resolved_anchor{false};
    uint8_t proof_version{0};
    ShadowProofPayloadMode proof_mode{ShadowProofPayloadMode::MALFORMED};
    bool proof_origin_bound{false};
    uint32_t proof_origin_height{0};
    uint256 proof_origin_previous_block_hash;
    bool proof_input_bound{false};
    uint32_t proof_output_index{0};
    CScript proof_target;
    CScript proof_payout_script;
    CAmount claim_fee{0};
    bool exact_authored_carrier_shape{false};
    bool relay_ttl_expired{false};
    int64_t relay_expiry_time{0};
    bool lineage_metadata_present{false};
    bool lineage_metadata_valid{false};
    uint256 lineage_family_fingerprint;
    uint256 lineage_root_txid;
    uint256 lineage_parent_txid;
    uint32_t lineage_ordinal{0};
    uint256 adoption_tip;
    uint256 adoption_generation_fingerprint;
    bool adoption_metadata_valid{false};
    int first_quarantine_height{-1};
    int branch_quarantine_height{-1};
    int stale_depth{0};
    bool stale_depth_known{false};
    bool resolution_metadata_valid{false};
    uint256 resolution_generation_fingerprint;
    std::string resolution_origin;
    int resolution_created_height{-1};
    int64_t resolution_created_time{0};
    bool resolution_relay_authorized{false};
};

struct ShadowPowClaimRecoveryComponent
{
    COutPoint anchor;
    CAmount anchor_amount{0};
    CScript anchor_script;
    // Stable identity for one confirmed anchor generation.  It intentionally
    // excludes the active tip, sibling set, resolution state, and all other
    // mutable observations.
    uint256 generation_fingerprint;
    // Tip-pinned classifier snapshot.  This changes when the tip or any
    // observed component fact changes and must not be used as idempotency
    // identity for a managed resolution.
    uint256 fingerprint;
    ShadowPowClaimRecoveryState state{ShadowPowClaimRecoveryState::INDETERMINATE};
    std::vector<ShadowPowClaimRecoveryNode> nodes;
    std::vector<uint256> claim_txids;
    std::vector<uint256> root_claim_txids;
    std::vector<uint256> ordinary_or_mixed_txids;
    std::vector<uint256> resolution_txids;
    bool anchor_authenticated{false};
    bool anchor_unspent{false};
    // A user coin lock is a restriction-only hold on this retained family.
    // It suppresses relay and refresh, but must not make the family unsafe or
    // prevent independent families from progressing.
    bool anchor_user_locked{false};
    bool all_claims_quarantined{false};
    bool all_claims_explicitly_provenanced{false};
    bool has_live_claim{false};
    bool has_transient_claim{false};
    bool has_revalidating_unbound_proof{false};
    bool has_indeterminate_node{false};
    bool has_managed_resolution{false};
    bool has_legacy_resolution{false};
    bool has_live_resolution{false};
    bool all_claims_terminal_on_pinned_tip{false};
    bool all_claims_zero_payment_retirable{false};
    bool all_claims_expired_locally_retired{false};
    bool has_branch_relative_ineligibility{false};
    size_t descendant_claims{0};
    int minimum_stale_depth{0};
    bool stale_depth_known{false};
};

struct ShadowPowClaimRecoveryInventory
{
    uint256 active_tip;
    int active_height{-1};
    uint256 wallet_processed_tip;
    int wallet_processed_height{-1};
    uint64_t wallet_generation{0};
    uint256 candidate_state_fingerprint;
    bool wallet_tip_matches{false};
    bool recovery_database_ambiguous{false};
    size_t raw_claim_objects{0};
    size_t live_claim_objects{0};
    size_t quarantined_claim_objects{0};
    size_t blocking_components{0};
    size_t retired_claim_objects{0};
    size_t retired_components{0};
    size_t resolved_components{0};
    std::vector<ShadowPowClaimRecoveryComponent> components;
    std::vector<uint256> unanchored_claim_txids;
};

enum class ShadowPowClaimMiningGateAction : uint8_t {
    CREATE_NEW_ANCHOR,
    WAIT_FOR_LIVE,
    WAIT_FOR_NEXT_TIP,
    RELAY_EXISTING,
    REFRESH_SAME_ANCHOR,
    UNSAFE,
};

/** Read-only, active-tip-pinned wallet action for QQSPROOF production. Counters
 * aggregate every safe authenticated wallet-owned family; the action payload
 * identifies one deterministically selected family. A refresh never selects a
 * second fee UTXO: it spends that family's authenticated confirmed anchor. */
struct ShadowPowClaimMiningGate
{
    ShadowPowClaimMiningGateAction action{
        ShadowPowClaimMiningGateAction::UNSAFE};
    uint256 active_tip;
    int active_height{-1};
    uint64_t wallet_generation{0};
    uint256 candidate_state_fingerprint;
    bool coherent{false};
    bool recovery_database_ambiguous{false};
    size_t unresolved_components{0};
    size_t live_claims{0};
    size_t eligible_claims{0};
    size_t family_claims{0};
    size_t unsafe_claims{0};
    size_t unsafe_components{0};
    COutPoint anchor;
    CAmount anchor_amount{0};
    CScript target;
    CScript payout_script;
    uint256 generation_fingerprint;
    uint256 lineage_root_txid;
    uint256 lineage_head_txid;
    uint32_t next_lineage_ordinal{0};
    uint256 relay_txid;
    int64_t relay_expiry_time{0};

    bool HasUnsafeClaims() const
    {
        return action == ShadowPowClaimMiningGateAction::UNSAFE ||
               unsafe_claims != 0 || unsafe_components != 0;
    }

    bool MayCreateClaim() const
    {
        return coherent && !recovery_database_ambiguous &&
               (action == ShadowPowClaimMiningGateAction::CREATE_NEW_ANCHOR ||
                action == ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR);
    }

    bool MayCreateNewAnchorClaim() const
    {
        return MayCreateClaim() &&
               action == ShadowPowClaimMiningGateAction::CREATE_NEW_ANCHOR;
    }

    bool MayRefreshSameAnchor() const
    {
        return MayCreateClaim() &&
               action == ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR;
    }

    bool ShouldRelayExisting() const
    {
        return coherent && !recovery_database_ambiguous &&
               action == ShadowPowClaimMiningGateAction::RELAY_EXISTING &&
               !relay_txid.IsNull();
    }
};

/** Derive the aggregate mining decision from one already-built recovery
 * inventory so callers can reuse proof-validation work for telemetry and
 * payout decisions. */
ShadowPowClaimMiningGate BuildShadowPowClaimMiningGate(
    const ShadowPowClaimRecoveryInventory& inventory);

/** True when an unresolved component can affect this wallet's mining
 * authority. Pure incoming UNKNOWN/non-authored/non-from-me records are
 * retained for audit but do not count. */
bool HasMiningRelevantUnresolvedShadowPowClaimComponent(
    const ShadowPowClaimRecoveryInventory& inventory);

/**
 * Return true only when two gates authorize the same exact historical relay
 * on the same active-chain and wallet snapshot. Callers use this immediately
 * before handing retained bytes to the mempool so a concurrent tip, wallet,
 * family, safety-counter, or relay-expiry change cannot be mistaken for the
 * previously reviewed intent.
 */
bool ShadowPowClaimRelayIntentMatches(
    const ShadowPowClaimMiningGate& expected,
    const ShadowPowClaimMiningGate& current);

/**
 * Recovery has three deliberately distinct side-effect levels. PREVIEW is
 * read-only. SIGN_ONLY signs and durably records the exact transaction bytes,
 * but never relays them. COMMIT_AND_BROADCAST first performs the SIGN_ONLY
 * durability step for every action in the batch and only then relays those
 * exact wallet records.
 */
enum class ShadowPowClaimRecoveryMode : uint8_t {
    PREVIEW,
    SIGN_ONLY,
    COMMIT_AND_BROADCAST,
};

enum class ShadowPowClaimRecoveryOrigin : uint8_t {
    MANUAL,
    AUTOMATIC,
};

/** Typed execution authority prevents a GUI/RPC wrapper from accidentally
 * turning a preview-capable request into an authorized wallet mutation. */
enum class ShadowPowClaimRecoveryExecutionAuthority : uint8_t {
    NONE,
    EXPLICIT_MANUAL,
    AUTOMATIC_POLICY,
    PERSISTED_COMMIT,
};

enum class ShadowPowClaimRecoveryActionStatus : uint8_t {
    READY,
    REUSE_MANAGED,
    REUSE_LEGACY,
    SIGNED_AND_PERSISTED,
    BROADCAST,
    ALREADY_IN_MEMPOOL,
    RELAY_DEFERRED,
    REFUSED,
    FAILED,
};

/** One current-anchor action or a fail-closed refusal in a pinned plan. */
struct ShadowPowClaimRecoveryAction
{
    COutPoint anchor;
    uint256 generation_fingerprint;
    uint256 component_fingerprint;
    std::vector<uint256> claim_txids;
    size_t descendant_claims{0};
    ShadowPowClaimRecoveryState component_state{
        ShadowPowClaimRecoveryState::INDETERMINATE};
    ShadowPowClaimRecoveryActionStatus status{
        ShadowPowClaimRecoveryActionStatus::REFUSED};
    CAmount fee{0};
    /** Maximum signed vsize used for a new preview's fee calculation, or the
     * exact vsize of already-signed persisted bytes. */
    int64_t vsize{-1};
    CTransactionRef transaction;
    bool persisted{false};
    bool in_mempool{false};
    /** Exact managed bytes already have durable scheduler/relay authority. */
    bool relay_authorized{false};
    bool frontier_may_advance{true};
    /** The action deliberately conflicts with an unbound proof that may
     * become valid on a descendant even though it is invalid now. */
    bool conflicts_with_revalidating_unbound_proof{false};
    std::string reason_code;
    std::string detail;
};

/**
 * Request shared by RPC, GUI, headless automation, and tests. An empty selector
 * list means all current components. A selector may name any claim or known
 * resolution in a component and is canonicalized to its confirmed anchor.
 */
struct ShadowPowClaimRecoveryRequest
{
    ShadowPowClaimRecoveryMode mode{ShadowPowClaimRecoveryMode::PREVIEW};
    ShadowPowClaimRecoveryOrigin origin{ShadowPowClaimRecoveryOrigin::MANUAL};
    ShadowPowClaimRecoveryExecutionAuthority execution_authority{
        ShadowPowClaimRecoveryExecutionAuthority::NONE};
    bool acknowledge_fee_and_conflict_risk{false};
    std::vector<uint256> selectors;
    CAmount max_fee_per_resolution{CENT};
    CAmount aggregate_batch_fee_cap{10 * CENT};
    /** Explicit atoms per 1000 virtual bytes; absent uses wallet policy. */
    std::optional<CFeeRate> fee_rate;
    std::optional<uint256> expected_plan_id;
};

struct ShadowPowClaimRecoveryPlan
{
    uint256 active_tip;
    int active_height{-1};
    uint64_t wallet_generation{0};
    uint256 plan_id;
    ShadowPowClaimRecoveryOrigin origin{
        ShadowPowClaimRecoveryOrigin::MANUAL};
    CAmount max_fee_per_resolution{0};
    CAmount aggregate_batch_fee_cap{0};
    std::optional<CAmount> fee_rate_atoms_per_k;
    CAmount total_fee{0};
    std::vector<ShadowPowClaimRecoveryAction> actions;
    std::vector<ShadowPowClaimRecoveryAction> refused;
    bool wallet_tip_matches{false};
    bool complete{false};
};

struct ShadowPowClaimRecoveryResult
{
    ShadowPowClaimRecoveryPlan plan;
    bool success{false};
    bool stale_plan{false};
    size_t signed_and_persisted{0};
    /** Durable wallet records changed during this invocation. Once true, an
     * RPC must return the structured outcome even if a later preflight or
     * relay step fails, because the side effect cannot be rolled back. */
    bool durable_state_changed{false};
    /** A database commit/rollback outcome was indeterminate. Reload may
     * reveal exact persisted or relay-authorized bytes, so callers must not
     * report this as a proven no-side-effect failure. */
    bool durable_state_ambiguous{false};
    /** Exact transactions newly granted durable relay/scheduler authority. */
    size_t relay_authority_granted{0};
    size_t broadcast{0};
    size_t already_in_mempool{0};
    /** Commit-authorized exact transactions left for a fresh scheduler pass
     * after this invocation relayed one transaction. */
    size_t relay_deferred{0};
    std::string error;
};

/** Stable machine outcomes for explicit historical component adoption. */
enum class ShadowPowClaimRecoveryAdoptionStatus : uint8_t {
    SUCCESS,
    ALREADY_EXPLICIT,
    NO_CHAIN,
    DATABASE_OUTCOME_AMBIGUOUS,
    SIGNING_UNAVAILABLE,
    STALE_TIP,
    SELECTOR_NOT_FOUND,
    SELECTOR_NOT_CLAIM,
    SELECTOR_AMBIGUOUS,
    STALE_COMPONENT_FINGERPRINT,
    UNSAFE_GRAPH,
    DATABASE_FAILURE,
};

/** Atomic adoption result. It contains the reviewed and post-commit facts so
 * adapters never need a racy second inventory lookup after durable mutation. */
struct ShadowPowClaimRecoveryAdoptionResult
{
    ShadowPowClaimRecoveryAdoptionStatus status{
        ShadowPowClaimRecoveryAdoptionStatus::DATABASE_FAILURE};
    bool adopted{false};
    bool durable_state_changed{false};
    bool durable_state_ambiguous{false};
    uint256 active_tip;
    uint256 generation_fingerprint;
    uint256 reviewed_component_fingerprint;
    uint256 post_adoption_component_fingerprint;
    std::vector<uint256> claim_txids;
    bool automatic_eligible_after_adoption{false};
    bool component_has_revalidating_unbound_proof{false};
    /** Shared graph refusal code when status is UNSAFE_GRAPH. */
    std::string component_refusal_code;
    std::string detail;

    bool IsSuccess() const
    {
        return status == ShadowPowClaimRecoveryAdoptionStatus::SUCCESS ||
               status ==
                   ShadowPowClaimRecoveryAdoptionStatus::ALREADY_EXPLICIT;
    }
};

/** Reorg-correct counters reconstructed from durable CWalletTx facts. */
struct ShadowPowClaimRecoveryUsage
{
    size_t pending_manual{0};
    size_t pending_automatic{0};
    size_t confirmed_manual{0};
    size_t confirmed_automatic{0};
    CAmount confirmed_resolution_fees{0};
    size_t automatic_actions_in_window{0};
    CAmount automatic_fee_exposure_in_window{0};
    size_t reconciled_descendant_claims{0};
    size_t recycled_outputs{0};
};

/**
 * Wallet-scoped standing consent for automated Gold Rush PoW claim recovery.
 *
 * Merely storing limits does not grant spending authority. Automation is
 * authorized only when both choice_recorded and automatic_enabled are true.
 * An absent, unreadable, unknown-version, or invalid record must be replaced
 * in memory with DefaultShadowPowClaimRecoveryPolicy(), which has neither bit
 * set.
 */
struct ShadowPowClaimRecoveryPolicy
{
    static constexpr uint32_t VERSION{1};

    uint32_t version{VERSION};
    // Persist flags as bytes so non-canonical values are detectable instead
    // of being silently coerced to true by bool deserialization.
    uint8_t choice_recorded{0};
    uint8_t automatic_enabled{0};
    CAmount max_fee_per_resolution{CENT};
    CAmount aggregate_batch_fee_cap{10 * CENT};
    CAmount rolling_fee_budget{COIN};
    uint32_t rolling_fee_window_seconds{24 * 60 * 60};
    uint32_t max_actions_per_window{100};
    uint32_t minimum_stale_blocks{6};

    SERIALIZE_METHODS(ShadowPowClaimRecoveryPolicy, obj)
    {
        READWRITE(obj.version,
                  obj.choice_recorded,
                  obj.automatic_enabled,
                  obj.max_fee_per_resolution,
                  obj.aggregate_batch_fee_cap,
                  obj.rolling_fee_budget,
                  obj.rolling_fee_window_seconds,
                  obj.max_actions_per_window,
                  obj.minimum_stale_blocks);
    }

    bool HasAutomaticAuthority() const
    {
        return choice_recorded == 1 && automatic_enabled == 1;
    }

    bool operator==(const ShadowPowClaimRecoveryPolicy& other) const
    {
        return version == other.version &&
               choice_recorded == other.choice_recorded &&
               automatic_enabled == other.automatic_enabled &&
               max_fee_per_resolution == other.max_fee_per_resolution &&
               aggregate_batch_fee_cap == other.aggregate_batch_fee_cap &&
               rolling_fee_budget == other.rolling_fee_budget &&
               rolling_fee_window_seconds == other.rolling_fee_window_seconds &&
               max_actions_per_window == other.max_actions_per_window &&
               minimum_stale_blocks == other.minimum_stale_blocks;
    }
};

enum class ShadowPowClaimRecoveryPolicyMutationStatus : uint8_t {
    SUCCESS,
    INVALID_POLICY,
    DATABASE_FAILURE,
    DATABASE_OUTCOME_AMBIGUOUS,
};

/** Durable policy mutation result. `authoritative_state_available=false`
 * means neither the old nor requested policy may be represented as the
 * persisted state until wallet reload. */
struct ShadowPowClaimRecoveryPolicyMutationResult
{
    ShadowPowClaimRecoveryPolicyMutationStatus status{
        ShadowPowClaimRecoveryPolicyMutationStatus::DATABASE_FAILURE};
    bool success{false};
    bool durable_state_changed{false};
    bool durable_state_ambiguous{false};
    bool authoritative_state_available{false};
    ShadowPowClaimRecoveryPolicy authoritative_policy;
    std::string detail;
};

enum class ShadowPowClaimRecoveryReviewStatus : uint8_t {
    AVAILABLE,
    CHAIN_UNAVAILABLE,
    WALLET_TIP_STALE,
    POLICY_UNAVAILABLE,
};

/** Read-only recovery review assembled under one cs_main/cs_wallet snapshot. */
struct ShadowPowClaimRecoveryReview
{
    ShadowPowClaimRecoveryReviewStatus status{
        ShadowPowClaimRecoveryReviewStatus::CHAIN_UNAVAILABLE};
    bool available{false};
    bool consistent{false};
    uint256 active_tip;
    int active_height{-1};
    uint256 wallet_tip;
    int wallet_height{-1};
    uint64_t wallet_generation{0};
    ShadowPowClaimRecoveryInventory inventory;
    ShadowPowClaimRecoveryPlan plan;
    ShadowPowClaimRecoveryPolicy policy;
    ShadowPowClaimRecoveryUsage usage;
    std::string reason_code;
    std::string detail;
};

inline ShadowPowClaimRecoveryPolicy DefaultShadowPowClaimRecoveryPolicy()
{
    return {};
}

// Absolute policy bounds. Relational limits are enforced below as well.
static constexpr CAmount SHADOW_POW_RECOVERY_MIN_FEE_PER_RESOLUTION{1};
static constexpr CAmount SHADOW_POW_RECOVERY_MAX_FEE_PER_RESOLUTION{CENT};
static constexpr CAmount SHADOW_POW_RECOVERY_MAX_BATCH_FEE_CAP{COIN};
static constexpr CAmount SHADOW_POW_RECOVERY_MAX_ROLLING_FEE_BUDGET{10 * COIN};
static constexpr uint32_t SHADOW_POW_RECOVERY_MIN_WINDOW_SECONDS{60};
static constexpr uint32_t SHADOW_POW_RECOVERY_MAX_WINDOW_SECONDS{7 * 24 * 60 * 60};
static constexpr uint32_t SHADOW_POW_RECOVERY_MIN_ACTIONS_PER_WINDOW{1};
static constexpr uint32_t SHADOW_POW_RECOVERY_MAX_ACTIONS_PER_WINDOW{1000};
static constexpr uint32_t SHADOW_POW_RECOVERY_MIN_STALE_BLOCKS{1};
static constexpr uint32_t SHADOW_POW_RECOVERY_MAX_STALE_BLOCKS{10080};

/** Validate the complete persisted policy, including all spending limits. */
inline bool ValidateShadowPowClaimRecoveryPolicy(const ShadowPowClaimRecoveryPolicy& policy,
                                                 std::string* error = nullptr)
{
    auto fail = [&](const char* message) {
        if (error) *error = message;
        return false;
    };

    if (policy.version != ShadowPowClaimRecoveryPolicy::VERSION) {
        return fail("unsupported policy version");
    }
    if (policy.choice_recorded > 1 || policy.automatic_enabled > 1) {
        return fail("policy choice flags are not canonical booleans");
    }
    if (policy.automatic_enabled && !policy.choice_recorded) {
        return fail("automatic recovery requires a recorded operator choice");
    }
    if (policy.max_fee_per_resolution < SHADOW_POW_RECOVERY_MIN_FEE_PER_RESOLUTION ||
        policy.max_fee_per_resolution > SHADOW_POW_RECOVERY_MAX_FEE_PER_RESOLUTION) {
        return fail("per-resolution fee limit is outside the permitted range");
    }
    if (policy.aggregate_batch_fee_cap < policy.max_fee_per_resolution ||
        policy.aggregate_batch_fee_cap > SHADOW_POW_RECOVERY_MAX_BATCH_FEE_CAP) {
        return fail("aggregate batch fee cap must cover one resolution and stay within its permitted range");
    }
    if (policy.rolling_fee_budget < policy.aggregate_batch_fee_cap ||
        policy.rolling_fee_budget > SHADOW_POW_RECOVERY_MAX_ROLLING_FEE_BUDGET) {
        return fail("rolling fee budget must cover one batch and stay within its permitted range");
    }
    if (policy.rolling_fee_window_seconds < SHADOW_POW_RECOVERY_MIN_WINDOW_SECONDS ||
        policy.rolling_fee_window_seconds > SHADOW_POW_RECOVERY_MAX_WINDOW_SECONDS) {
        return fail("rolling fee window is outside the permitted range");
    }
    if (policy.max_actions_per_window < SHADOW_POW_RECOVERY_MIN_ACTIONS_PER_WINDOW ||
        policy.max_actions_per_window > SHADOW_POW_RECOVERY_MAX_ACTIONS_PER_WINDOW) {
        return fail("action limit is outside the permitted range");
    }
    if (policy.minimum_stale_blocks < SHADOW_POW_RECOVERY_MIN_STALE_BLOCKS ||
        policy.minimum_stale_blocks > SHADOW_POW_RECOVERY_MAX_STALE_BLOCKS) {
        return fail("minimum stale-block delay is outside the permitted range");
    }

    if (error) error->clear();
    return true;
}

} // namespace wallet

#endif // BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_TYPES_H
