// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_MIGRATION_BATCH_H
#define BITCOIN_WALLET_MIGRATION_BATCH_H

#include <consensus/amount.h>
#include <policy/policy.h>
#include <primitives/transaction.h>
#include <util/result.h>
#include <wallet/coincontrol.h>
#include <wallet/spend.h>

#include <cstddef>
#include <cstdint>
#include <vector>

namespace wallet {
class CWallet;

/** Default number of legacy inputs one migratetoquantum call moves. */
static constexpr unsigned int DEFAULT_LEGACY_MIGRATION_BATCH_INPUTS{400};
/** Default number of Gold Rush payout inputs one consolidation call moves. A
 *  payout input weighs about 3,900 weight units, so the weight budget below
 *  binds first on its own; this keeps the count readable. */
static constexpr unsigned int DEFAULT_GOLDRUSH_CONSOLIDATION_BATCH_INPUTS{90};
/** Largest accepted max_inputs option. The weight budget still applies. */
static constexpr unsigned int MAX_MIGRATION_BATCH_INPUTS_OPTION{10000};
/** Weight a batch may use for its inputs and fixed parts: 90% of the standard
 *  transaction weight limit, so estimation error cannot push it over. */
static constexpr int64_t MIGRATION_BATCH_WEIGHT_BUDGET{360000};
/** Fixed transaction weight reserved for the version, counts, the marker and
 *  flag, the single destination output and a possible change output. */
static constexpr int64_t MIGRATION_BATCH_FIXED_WEIGHT{1500};
static_assert(MIGRATION_BATCH_WEIGHT_BUDGET < MAX_STANDARD_TX_WEIGHT);

struct MigrationBatchInput {
    COutPoint outpoint;
    //! Nominal value, reported to the caller.
    CAmount value{0};
    //! Value that reaches the destination before the fee (after any scheduled demurrage).
    CAmount effective_value{0};
    //! Maximum signed input weight in weight units; must be positive.
    int64_t input_weight{0};
    //! Whether the input can serve as the fork-unique migration anchor.
    bool anchor{false};
};

struct MigrationBatchPlan {
    //! Chosen inputs in spend order.
    std::vector<MigrationBatchInput> selected;
    int64_t estimated_weight{0};
    //! True when an anchor is required, candidates exist, and none is an anchor.
    bool blocked_no_anchor{false};
};

/**
 * Choose one bounded batch. Deterministic: candidates are ordered by value,
 * largest first, then by outpoint. At most max_inputs are taken and the fixed
 * weight plus the chosen input weights stay within weight_budget. When an
 * anchor is required, every batch holds one: the first anchor in order. The
 * rest of the batch is filled with non-anchors first so the anchors that are
 * left can serve the later batches; anchors fill remaining room only when
 * no non-anchor candidate is left.
 */
MigrationBatchPlan PlanMigrationBatch(std::vector<MigrationBatchInput> candidates,
                                      size_t max_inputs, int64_t fixed_weight,
                                      int64_t weight_budget, bool require_anchor);

struct MigrationBatch {
    CTransactionRef tx;
    CAmount fee{0};
    std::vector<COutPoint> selected;
    CAmount selected_value{0};
    CAmount selected_effective_value{0};
    size_t total_inputs{0};
    CAmount total_value{0};
    size_t remaining_inputs{0};
    CAmount remaining_value{0};
    //! Maximum signed size the wallet expects; for a signed transaction the actual size is at most this.
    int64_t estimated_vsize{0};
};

/**
 * Plan one bounded batch and build its transaction (signed unless sign is
 * false). The batch is cut down and rebuilt, up to a few times, if the wallet
 * still finds it too large. base_control carries the fee rate, change
 * destination and input-family settings; its selection is replaced by the batch.
 * Requires the wallet lock.
 */
util::Result<MigrationBatch> BuildMigrationBatch(CWallet& wallet, const CCoinControl& base_control,
                                                 const CTxDestination& destination,
                                                 const std::vector<MigrationBatchInput>& candidates,
                                                 size_t max_inputs, bool require_anchor, bool sign)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);

/** Parse the optional max_inputs value: positive, at most the option maximum. */
size_t ClampMigrationBatchInputs(int64_t requested, unsigned int default_inputs);

} // namespace wallet

#endif // BITCOIN_WALLET_MIGRATION_BATCH_H
