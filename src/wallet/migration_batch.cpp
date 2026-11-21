// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/migration_batch.h>

#include <consensus/validation.h>
#include <policy/policy.h>
#include <util/translation.h>
#include <wallet/spend.h>
#include <wallet/wallet.h>

#include <algorithm>

namespace wallet {

namespace {
bool OrderedBefore(const MigrationBatchInput& a, const MigrationBatchInput& b)
{
    if (a.value != b.value) return a.value > b.value;
    return a.outpoint < b.outpoint;
}
} // namespace

MigrationBatchPlan PlanMigrationBatch(std::vector<MigrationBatchInput> candidates,
                                      size_t max_inputs, int64_t fixed_weight,
                                      int64_t weight_budget, bool require_anchor)
{
    MigrationBatchPlan plan;
    std::sort(candidates.begin(), candidates.end(), OrderedBefore);
    if (candidates.empty() || max_inputs == 0) return plan;

    int64_t weight = fixed_weight;
    std::vector<bool> taken(candidates.size(), false);
    size_t count{0};
    auto try_take = [&](size_t index) {
        if (taken[index] || count >= max_inputs) return false;
        const int64_t w = std::max<int64_t>(1, candidates[index].input_weight);
        if (weight + w > weight_budget) return false;
        taken[index] = true;
        weight += w;
        ++count;
        return true;
    };

    if (require_anchor) {
        const auto anchor_it = std::find_if(candidates.begin(), candidates.end(),
                                            [](const MigrationBatchInput& c) { return c.anchor; });
        if (anchor_it == candidates.end()) {
            plan.blocked_no_anchor = true;
            return plan;
        }
        if (!try_take(static_cast<size_t>(anchor_it - candidates.begin()))) return plan;
        for (size_t i = 0; i < candidates.size(); ++i) {
            if (!candidates[i].anchor) try_take(i);
        }
        for (size_t i = 0; i < candidates.size(); ++i) {
            if (candidates[i].anchor) try_take(i);
        }
    } else {
        for (size_t i = 0; i < candidates.size(); ++i) try_take(i);
    }

    for (size_t i = 0; i < candidates.size(); ++i) {
        if (taken[i]) plan.selected.push_back(candidates[i]);
    }
    plan.estimated_weight = weight;
    return plan;
}

util::Result<MigrationBatch> BuildMigrationBatch(CWallet& wallet, const CCoinControl& base_control,
                                                 const CTxDestination& destination,
                                                 const std::vector<MigrationBatchInput>& candidates,
                                                 size_t max_inputs, bool require_anchor, bool sign)
{
    AssertLockHeld(wallet.cs_wallet);
    CAmount total_value{0};
    for (const MigrationBatchInput& c : candidates) total_value += c.value;

    size_t limit = max_inputs;
    constexpr int MAX_ATTEMPTS = 8;
    for (int attempt = 0; attempt < MAX_ATTEMPTS; ++attempt) {
        const MigrationBatchPlan plan = PlanMigrationBatch(
            candidates, limit, MIGRATION_BATCH_FIXED_WEIGHT, MIGRATION_BATCH_WEIGHT_BUDGET, require_anchor);
        if (plan.blocked_no_anchor) {
            return util::Error{_("The remaining spendable legacy coins are witness-only and cannot create a fork-unique migration transaction. Add a small P2PKH or non-witness P2SH wallet UTXO as a migration anchor, then repeat the call.")};
        }
        if (plan.selected.empty()) {
            return util::Error{_("No input fits in a standard-size transaction.")};
        }

        CCoinControl control = base_control;
        control.UnSelectAll();
        CAmount selected_value{0};
        CAmount selected_effective{0};
        std::vector<COutPoint> selected;
        selected.reserve(plan.selected.size());
        for (const MigrationBatchInput& in : plan.selected) {
            control.Select(in.outpoint);
            selected.push_back(in.outpoint);
            selected_value += in.value;
            selected_effective += in.effective_value;
        }

        std::vector<CRecipient> recipients{{destination, selected_effective, /*fSubtractFeeFromAmount=*/true}};
        // Estimate with the signing-free path first: the wallet's size check
        // uses the maximum signed size either way, and an oversize batch must
        // not be signed (ML-DSA signatures are slow) only to be thrown away.
        auto estimate = CreateTransaction(wallet, recipients, /*change_pos=*/-1, control, /*sign=*/false);
        if (!estimate) {
            if (util::ErrorString(estimate).original == _("Transaction too large").original && selected.size() > 1) {
                limit = std::max<size_t>(1, selected.size() / 2);
                continue;
            }
            return util::Error{util::ErrorString(estimate)};
        }
        const TxSize max_size = CalculateMaximumSignedTxSize(*estimate->tx, &wallet, &control);
        auto created = sign ? CreateTransaction(wallet, recipients, /*change_pos=*/-1, control, /*sign=*/true)
                            : std::move(estimate);
        if (!created) {
            if (util::ErrorString(created).original == _("Transaction too large").original && selected.size() > 1) {
                limit = std::max<size_t>(1, selected.size() / 2);
                continue;
            }
            return util::Error{util::ErrorString(created)};
        }

        MigrationBatch batch;
        batch.tx = created->tx;
        batch.fee = created->fee;
        batch.selected = std::move(selected);
        batch.selected_value = selected_value;
        batch.selected_effective_value = selected_effective;
        batch.total_inputs = candidates.size();
        batch.total_value = total_value;
        batch.remaining_inputs = candidates.size() - batch.selected.size();
        batch.remaining_value = total_value - selected_value;
        batch.estimated_vsize = max_size.vsize > 0 ? max_size.vsize : GetVirtualTransactionSize(*batch.tx, 0, 0);
        return batch;
    }
    return util::Error{_("Transaction too large")};
}

size_t ClampMigrationBatchInputs(int64_t requested, unsigned int default_inputs)
{
    if (requested <= 0) return default_inputs;
    return static_cast<size_t>(std::min<int64_t>(requested, MAX_MIGRATION_BATCH_INPUTS_OPTION));
}

} // namespace wallet
