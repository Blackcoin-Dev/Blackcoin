// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_H
#define BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_H

#include <wallet/shadow_pow_claim_recovery_types.h>

namespace wallet {

const char* ShadowPowClaimRecoveryAdoptionStatusName(
    ShadowPowClaimRecoveryAdoptionStatus status);

/** Deterministic snapshot token; transaction signatures are intentionally excluded. */
uint256 ComputeShadowPowClaimRecoveryPlanId(
    const ShadowPowClaimRecoveryPlan& plan,
    const std::vector<uint256>& selectors);

const char* ShadowPowClaimRecoveryPolicyMutationStatusName(
    ShadowPowClaimRecoveryPolicyMutationStatus status);

} // namespace wallet

#endif // BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_H
