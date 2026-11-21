// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/migration_batch.h>

#include <consensus/validation.h>
#include <policy/policy.h>
#include <shadow.h>
#include <util/translation.h>
#include <wallet/spend.h>
#include <wallet/wallet.h>
#include <validation.h>

#include <algorithm>
#include <set>

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
                                      int64_t weight_budget, bool require_anchor,
                                      bool force_auxiliary)
{
    MigrationBatchPlan plan;
    std::sort(candidates.begin(), candidates.end(), OrderedBefore);
    std::vector<MigrationBatchInput> legacy;
    std::vector<MigrationBatchInput> auxiliary;
    for (const MigrationBatchInput& c : candidates) (c.auxiliary ? auxiliary : legacy).push_back(c);
    if (legacy.empty() || max_inputs == 0) return plan;

    int64_t weight = fixed_weight;
    std::vector<bool> taken(legacy.size(), false);
    size_t count{0};
    auto try_take = [&](size_t index) {
        if (taken[index] || count >= max_inputs) return false;
        const int64_t w = std::max<int64_t>(1, legacy[index].input_weight);
        if (weight + w > weight_budget) return false;
        taken[index] = true;
        weight += w;
        ++count;
        return true;
    };
    bool use_auxiliary{false};
    auto take_auxiliary = [&]() {
        if (auxiliary.empty()) return false;
        const int64_t w = std::max<int64_t>(1, auxiliary.front().input_weight);
        if (weight + w > weight_budget) return false;
        weight += w;
        use_auxiliary = true;
        return true;
    };

    if (require_anchor) {
        const auto anchor_it = std::find_if(legacy.begin(), legacy.end(),
                                            [](const MigrationBatchInput& c) { return c.anchor; });
        if (anchor_it != legacy.end()) {
            if (!try_take(static_cast<size_t>(anchor_it - legacy.begin()))) return plan;
            if (force_auxiliary) take_auxiliary();
        } else {
            // No legacy anchor is left: a confirmed protected quantum output of the wallet anchors
            // the batch (the batch's own output of an earlier call is one).
            if (!take_auxiliary()) {
                plan.blocked_no_anchor = true;
                return plan;
            }
        }
        for (size_t i = 0; i < legacy.size(); ++i) {
            if (!legacy[i].anchor) try_take(i);
        }
        for (size_t i = 0; i < legacy.size(); ++i) {
            if (legacy[i].anchor) try_take(i);
        }
    } else {
        if (force_auxiliary) take_auxiliary();
        for (size_t i = 0; i < legacy.size(); ++i) try_take(i);
    }

    for (size_t i = 0; i < legacy.size(); ++i) {
        if (taken[i]) plan.selected.push_back(legacy[i]);
    }
    if (use_auxiliary) plan.auxiliary.push_back(auxiliary.front());
    plan.estimated_weight = weight;
    return plan;
}

bool IsMigrationAuxiliaryOutput(const CWallet& wallet, const COutPoint& outpoint, const CTxOut& txout,
                                const Coin& coin, const Consensus::Params& consensus,
                                int64_t spend_time, int spend_height)
{
    if (coin.IsSpent() || coin.IsCoinBase() || !consensus.UsesHeightLifecycle()) return false;
    if (!IsDirectQuantumMigrationScript(txout.scriptPubKey)) return false;
    if (coin.nHeight <= static_cast<uint32_t>(consensus.nGoldRushEndHeight)) return false;
    CScript payout_script;
    if (IsGoldRushSyntheticPayoutInput(wallet.chain().getCoinsTip(), outpoint, consensus, &payout_script)) return false;
    return IsWalletProtectedLineageInput(wallet, outpoint, coin, consensus, spend_time, spend_height);
}

util::Result<MigrationBatch> BuildMigrationBatch(CWallet& wallet, const CCoinControl& base_control,
                                                 const CTxDestination& destination,
                                                 const std::vector<MigrationBatchInput>& candidates,
                                                 size_t max_inputs, bool require_anchor, bool sign)
{
    AssertLockHeld(wallet.cs_wallet);
    CAmount total_value{0};
    size_t total_inputs{0};
    bool auxiliary_available{false};
    for (const MigrationBatchInput& c : candidates) {
        if (c.auxiliary) {
            auxiliary_available = true;
            continue;
        }
        total_value += c.value;
        ++total_inputs;
    }

    size_t limit = max_inputs;
    bool force_auxiliary{false};
    constexpr int MAX_ATTEMPTS = 10;
    for (int attempt = 0; attempt < MAX_ATTEMPTS; ++attempt) {
        const MigrationBatchPlan plan = PlanMigrationBatch(
            candidates, limit, MIGRATION_BATCH_FIXED_WEIGHT, MIGRATION_BATCH_WEIGHT_BUDGET, require_anchor, force_auxiliary);
        if (plan.blocked_no_anchor) {
            return util::Error{_("The remaining spendable legacy coins are witness-only and cannot create a fork-unique migration transaction, and the wallet has no confirmed quantum output to anchor them. If an earlier migration batch is still unconfirmed, wait for it to confirm (its quantum output then anchors the rest). Otherwise add a small P2PKH or non-witness P2SH wallet UTXO as a migration anchor, then repeat the call.")};
        }
        if (plan.selected.empty()) {
            return util::Error{_("No input fits in a standard-size transaction.")};
        }

        CCoinControl control = base_control;
        control.UnSelectAll();
        CAmount selected_value{0};
        CAmount selected_effective{0};
        CAmount auxiliary_value{0};
        std::vector<COutPoint> selected;
        std::vector<COutPoint> auxiliary;
        selected.reserve(plan.selected.size());
        for (const MigrationBatchInput& in : plan.selected) {
            control.Select(in.outpoint);
            selected.push_back(in.outpoint);
            selected_value += in.value;
            selected_effective += in.effective_value;
        }
        for (const MigrationBatchInput& in : plan.auxiliary) {
            control.Select(in.outpoint);
            auxiliary.push_back(in.outpoint);
            auxiliary_value += in.effective_value;
        }

        std::vector<CRecipient> recipients{{destination, selected_effective + auxiliary_value, /*fSubtractFeeFromAmount=*/true}};
        // Estimate with the signing-free path first: the wallet's size check
        // uses the maximum signed size either way, and an oversize batch must
        // not be signed (ML-DSA signatures are slow) only to be thrown away.
        auto estimate = CreateTransaction(wallet, recipients, /*change_pos=*/-1, control, /*sign=*/false);
        if (!estimate) {
            if (util::ErrorString(estimate).original == _("Transaction too large").original && selected.size() > 1) {
                limit = std::max<size_t>(1, selected.size() / 2);
                continue;
            }
            // A tail that cannot pay its own fee is funded by the wallet's quantum output.
            if (!force_auxiliary && auxiliary.empty() && auxiliary_available) {
                force_auxiliary = true;
                continue;
            }
            return util::Error{util::ErrorString(estimate)};
        }
        if (!force_auxiliary && auxiliary.empty() && auxiliary_available &&
            IsDust(estimate->tx->vout[0], wallet.chain().relayDustFee())) {
            force_auxiliary = true;
            continue;
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
        batch.auxiliary = std::move(auxiliary);
        batch.auxiliary_value = auxiliary_value;
        batch.total_inputs = total_inputs;
        batch.total_value = total_value;
        batch.remaining_inputs = total_inputs - batch.selected.size();
        batch.remaining_value = total_value - selected_value;
        batch.estimated_vsize = max_size.vsize > 0 ? max_size.vsize : GetVirtualTransactionSize(*batch.tx, 0, 0);

        if (batch.remaining_inputs > 0) {
            // A partial batch must leave a way to finish: never discover afterwards that the
            // rest cannot be migrated. The batch's own quantum output anchors and funds the
            // continuation, so it must be an ordinary quantum output, large enough to pay what the
            // remainder cannot pay for itself.
            std::set<COutPoint> chosen(batch.selected.begin(), batch.selected.end());
            int64_t remaining_weight{MIGRATION_BATCH_FIXED_WEIGHT};
            CAmount remaining_effective{0};
            bool legacy_anchor_remains{false};
            for (const MigrationBatchInput& c : candidates) {
                if (c.auxiliary || chosen.count(c.outpoint)) continue;
                remaining_weight += std::max<int64_t>(1, c.input_weight);
                remaining_effective += c.effective_value;
                legacy_anchor_remains = legacy_anchor_remains || c.anchor;
            }
            const bool output_can_anchor = IsDirectQuantumMigrationScript(GetScriptForDestination(destination));
            if (require_anchor && !legacy_anchor_remains && !output_can_anchor) {
                return util::Error{_("This batch would leave legacy coins that cannot be migrated afterwards: the destination is not an ordinary quantum address, so its output cannot anchor the next batch. Use an ordinary quantum address, or a larger max_inputs.")};
            }
            const int64_t fee_rate_per_kvb = batch.estimated_vsize > 0 ? batch.fee * 1000 / batch.estimated_vsize : 0;
            const CAmount continuation_fee = fee_rate_per_kvb * ((remaining_weight + WITNESS_SCALE_FACTOR - 1) / WITNESS_SCALE_FACTOR) / 1000 + 1;
            const CAmount dust = GetDustThreshold(batch.tx->vout[0], wallet.chain().relayDustFee());
            if (remaining_effective < continuation_fee + dust && batch.tx->vout[0].nValue < continuation_fee + dust) {
                return util::Error{_("This batch would leave legacy coins that cannot pay for their own migration and the batch output is too small to fund it. Migrate with a larger max_inputs, or add funds first.")};
            }
        }
        return batch;
    }
    return util::Error{_("Transaction too large")};
}

ExcludedLegacyOutputs FindExcludedLegacyOutputs(const CWallet& wallet, const std::set<COutPoint>& considered,
                                                const Consensus::Params& consensus, int next_height)
{
    AssertLockHeld(wallet.cs_wallet);
    ExcludedLegacyOutputs excluded;
    const CCoinsViewCache& view = wallet.chain().chainman().ActiveChainstate().CoinsTip();
    CCoinControl control;
    control.m_include_unsafe_inputs = true;
    CoinFilterParams filter;
    filter.only_spendable = false;
    filter.skip_locked = false;
    filter.include_immature_coinbase = true;
    for (const COutput& out : AvailableCoins(wallet, &control, std::nullopt, filter).All()) {
        const CScript& spk = out.txout.scriptPubKey;
        if (IsQuantumMigrationScript(spk) || IsQuantumColdStakeScript(spk) || IsEUTXOScript(spk)) continue;
        if (considered.count(out.outpoint)) continue;
        ++excluded.count;
        excluded.amount += out.txout.nValue;
        const Coin& coin = view.AccessCoin(out.outpoint);
        if (!coin.IsSpent() && (coin.IsCoinBase() || coin.IsCoinStake())) {
            const int64_t matures = int64_t{coin.nHeight} + int64_t{consensus.nCoinbaseMaturity};
            if (matures >= next_height && (excluded.next_maturity_height == 0 || matures < excluded.next_maturity_height)) {
                excluded.next_maturity_height = matures;
            }
        }
    }
    return excluded;
}

size_t ClampMigrationBatchInputs(int64_t requested, unsigned int default_inputs)
{
    if (requested <= 0) return default_inputs;
    return static_cast<size_t>(std::min<int64_t>(requested, MAX_MIGRATION_BATCH_INPUTS_OPTION));
}

} // namespace wallet
