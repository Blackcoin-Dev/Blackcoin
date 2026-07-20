// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_H
#define BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_H

#include <consensus/amount.h>
#include <primitives/transaction.h>
#include <serialize.h>
#include <shadow.h>
#include <uint256.h>

#include <cstdint>
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
inline constexpr char SHADOW_POW_CLAIM_ADOPTED_KEY[]{"qq_shadow_pow_adopted"};
// Explicit adoption is authenticated to both the tip at which the operator
// reviewed the component and the stable anchor-generation identity that was
// reviewed.  The marker alone never grants trusted provenance.
inline constexpr char SHADOW_POW_CLAIM_ADOPTION_TIP_KEY[]{"qq_shadow_pow_adoption_tip"};
inline constexpr char SHADOW_POW_CLAIM_ADOPTION_FINGERPRINT_KEY[]{"qq_shadow_pow_adoption_fingerprint"};
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
    bool active_chain_confirmed{false};
    bool in_mempool{false};
    bool quarantined{false};
    bool expected_shape{false};
    bool wallet_authored{false};
    int created_height{-1};
    uint256 created_tip;
    bool authored_metadata_valid{false};
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
    bool all_claims_quarantined{false};
    bool all_claims_explicitly_provenanced{false};
    bool has_live_claim{false};
    bool has_transient_claim{false};
    bool has_indeterminate_node{false};
    bool has_managed_resolution{false};
    bool has_legacy_resolution{false};
    bool has_live_resolution{false};
    bool all_claims_terminal_on_pinned_tip{false};
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
    bool wallet_tip_matches{false};
    size_t raw_claim_objects{0};
    size_t live_claim_objects{0};
    size_t quarantined_claim_objects{0};
    size_t blocking_components{0};
    size_t resolved_components{0};
    std::vector<ShadowPowClaimRecoveryComponent> components;
    std::vector<uint256> unanchored_claim_txids;
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

#endif // BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_H
