// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_H
#define BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_H

#include <consensus/amount.h>
#include <serialize.h>

#include <cstdint>
#include <string>

namespace wallet {

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
