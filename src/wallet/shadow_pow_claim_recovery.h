// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_H
#define BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_H

#include <wallet/shadow_pow_claim_recovery_types.h>

namespace wallet {

/** Stable identity of one confirmed wallet anchor generation. */
uint256 ComputeShadowPowClaimLineageFamilyFingerprint(
    const COutPoint& anchor, CAmount anchor_amount,
    const CScript& anchor_script);

/** Select the existing RPC action string without replacing any safety field in
 * the fresh inventory-derived gate. A wallet-wide new-anchor submission wait
 * remains tip-bound even when a user lock changes the otherwise-safe wallet
 * snapshot; family-local waits remain exact-snapshot-bound. */
ShadowPowClaimMiningGateAction GetShadowPowClaimMiningGateTelemetryAction(
    const ShadowPowClaimMiningGate& fresh_gate,
    const ShadowPowClaimMiningGate& cached_gate, bool miner_enabled,
    bool claim_in_flight, bool wallet_wide_tip_wait = false);

const char* ShadowPowClaimRecoveryAdoptionStatusName(
    ShadowPowClaimRecoveryAdoptionStatus status);

/** Deterministic snapshot token; transaction signatures are intentionally excluded. */
uint256 ComputeShadowPowClaimRecoveryPlanId(
    const ShadowPowClaimRecoveryPlan& plan,
    const std::vector<uint256>& selectors);

const char* ShadowPowClaimRecoveryPolicyMutationStatusName(
    ShadowPowClaimRecoveryPolicyMutationStatus status);

const char* ShadowPowClaimResolutionRevocationStatusName(
    ShadowPowClaimResolutionRevocationStatus status);

/** Test-only observability for the wallet recovery evaluator boundary. */
void ResetShadowPowClaimRecoveryProofEvaluationStatsForTesting();
uint64_t GetShadowPowClaimRecoveryProofEvaluationCountForTesting();
uint64_t GetActiveShadowPowClaimRecoveryProofEvaluationsForTesting();
uint64_t GetShadowPowClaimRecoveryInventoryBuildCountForTesting();
uint64_t GetShadowPowClaimRecoveryPathVisitCountForTesting();
uint64_t GetShadowPowClaimRecoveryTopologyVisitCountForTesting();
uint64_t GetShadowPowClaimCandidateFingerprintMapVisitCountForTesting();
void SetShadowPowClaimRecoveryProofEvaluationDelayForTesting(int64_t delay_ms);
void SetShadowPowClaimRecoveryProofEvaluationBudgetForTesting(size_t budget);
void SetShadowPowClaimRecoveryProofEvaluationCacheCapacityForTesting(
    size_t capacity);

} // namespace wallet

#endif // BITCOIN_WALLET_SHADOW_POW_CLAIM_RECOVERY_H
