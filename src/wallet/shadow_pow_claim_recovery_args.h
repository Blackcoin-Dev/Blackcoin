// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_ARGS_H
#define BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_ARGS_H

#include <common/args.h>
#include <util/moneystr.h>
#include <util/strencodings.h>
#include <wallet/shadow_pow_claim_recovery_types.h>

#include <array>
#include <limits>
#include <optional>
#include <string>

namespace wallet {

inline constexpr char ARG_AUTORESOLVE_FAILED_CLAIMS[]{"-autoresolvefailedclaims"};
inline constexpr char ARG_AUTORESOLVE_MAX_FEE[]{"-autoresolvemaxfee"};
inline constexpr char ARG_AUTORESOLVE_BATCH_FEE_CAP[]{"-autoresolvebatchfeecap"};
inline constexpr char ARG_AUTORESOLVE_ROLLING_FEE_BUDGET[]{"-autoresolverollingfeebudget"};
inline constexpr char ARG_AUTORESOLVE_ROLLING_WINDOW[]{"-autoresolverollingwindow"};
inline constexpr char ARG_AUTORESOLVE_MAX_ACTIONS[]{"-autoresolvemaxactions"};
inline constexpr char ARG_AUTORESOLVE_STALE_BLOCKS[]{"-autoresolvestaleblocks"};

inline constexpr std::array<const char*, 6> SHADOW_POW_RECOVERY_LIMIT_ARGS{
    ARG_AUTORESOLVE_MAX_FEE,
    ARG_AUTORESOLVE_BATCH_FEE_CAP,
    ARG_AUTORESOLVE_ROLLING_FEE_BUDGET,
    ARG_AUTORESOLVE_ROLLING_WINDOW,
    ARG_AUTORESOLVE_MAX_ACTIONS,
    ARG_AUTORESOLVE_STALE_BLOCKS,
};

/**
 * Parse an optional process startup seed for the wallet-scoped claim recovery
 * policy. A successful null result means the operator supplied no startup
 * choice and no wallet record should be written.
 *
 * Automatic mode deliberately has no spending-limit defaults: all six limits
 * must be present and valid before this parser can produce automatic
 * authority. Pause-and-ask records an explicit non-spending choice and rejects
 * otherwise-ignored limit arguments.
 */
inline bool ParseShadowPowClaimRecoveryStartupPolicy(
    const ArgsManager& args,
    std::optional<ShadowPowClaimRecoveryPolicy>& policy_out,
    std::string& error)
{
    policy_out.reset();
    error.clear();

    const bool mode_set = args.IsArgSet(ARG_AUTORESOLVE_FAILED_CLAIMS);
    bool any_limit_set{false};
    for (const char* arg : SHADOW_POW_RECOVERY_LIMIT_ARGS) {
        any_limit_set |= args.IsArgSet(arg);
    }

    if (!mode_set) {
        if (any_limit_set) {
            error = "automatic PoW claim recovery limits require an explicit "
                    "-autoresolvefailedclaims=automatic or pause-and-ask choice";
            return false;
        }
        return true;
    }

    const std::string mode = ToLower(args.GetArg(ARG_AUTORESOLVE_FAILED_CLAIMS, ""));
    const bool automatic = mode == "1" || mode == "true" || mode == "yes" ||
                           mode == "on" || mode == "auto" || mode == "automatic";
    const bool pause_and_ask = mode == "0" || mode == "false" || mode == "no" ||
                               mode == "off" || mode == "pause" ||
                               mode == "pause-and-ask" || mode == "pause_and_ask";
    if (!automatic && !pause_and_ask) {
        error = "-autoresolvefailedclaims must be automatic (1) or pause-and-ask (0)";
        return false;
    }

    ShadowPowClaimRecoveryPolicy policy = DefaultShadowPowClaimRecoveryPolicy();
    policy.choice_recorded = 1;

    if (pause_and_ask) {
        if (any_limit_set) {
            error = "automatic PoW claim recovery limits are accepted only with "
                    "-autoresolvefailedclaims=automatic";
            return false;
        }
        policy.automatic_enabled = 0;
        policy_out = policy;
        return true;
    }

    std::string missing;
    for (const char* arg : SHADOW_POW_RECOVERY_LIMIT_ARGS) {
        if (args.IsArgSet(arg)) continue;
        if (!missing.empty()) missing += ", ";
        missing += arg;
    }
    if (!missing.empty()) {
        error = "-autoresolvefailedclaims=automatic requires all six explicit limits; missing: " + missing;
        return false;
    }

    const auto parse_amount = [&](const char* arg, CAmount& destination) {
        const std::optional<CAmount> amount = ParseMoney(args.GetArg(arg, ""));
        if (!amount || *amount <= 0) {
            error = std::string(arg) + " must be a positive BLK amount";
            return false;
        }
        destination = *amount;
        return true;
    };
    const auto parse_uint32 = [&](const char* arg, uint32_t& destination) {
        const std::optional<int64_t> value = args.GetIntArg(arg);
        if (!value || *value <= 0 || *value > std::numeric_limits<uint32_t>::max()) {
            error = std::string(arg) + " must be a positive integer";
            return false;
        }
        destination = static_cast<uint32_t>(*value);
        return true;
    };

    policy.automatic_enabled = 1;
    if (!parse_amount(ARG_AUTORESOLVE_MAX_FEE, policy.max_fee_per_resolution) ||
        !parse_amount(ARG_AUTORESOLVE_BATCH_FEE_CAP, policy.aggregate_batch_fee_cap) ||
        !parse_amount(ARG_AUTORESOLVE_ROLLING_FEE_BUDGET, policy.rolling_fee_budget) ||
        !parse_uint32(ARG_AUTORESOLVE_ROLLING_WINDOW, policy.rolling_fee_window_seconds) ||
        !parse_uint32(ARG_AUTORESOLVE_MAX_ACTIONS, policy.max_actions_per_window) ||
        !parse_uint32(ARG_AUTORESOLVE_STALE_BLOCKS, policy.minimum_stale_blocks)) {
        return false;
    }

    std::string validation_error;
    if (!ValidateShadowPowClaimRecoveryPolicy(policy, &validation_error)) {
        error = "invalid automatic PoW claim recovery startup policy: " + validation_error;
        return false;
    }

    policy_out = policy;
    return true;
}

} // namespace wallet

#endif // BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_ARGS_H
