// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/migration_batch.h>

#include <consensus/validation.h>
#include <policy/policy.h>
#include <shadow.h>
#include <timedata.h>
#include <util/moneystr.h>
#include <util/translation.h>
#include <wallet/fees.h>
#include <wallet/spend.h>
#include <wallet/wallet.h>
#include <validation.h>

#include <algorithm>
#include <map>
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

namespace {
//! Fee one batch of this weight pays at the rate: the same rounding as the wallet's estimate, plus one unit.
CAmount ContinuationFee(int64_t fee_rate_per_kvb, int64_t weight)
{
    return fee_rate_per_kvb * ((weight + WITNESS_SCALE_FACTOR - 1) / WITNESS_SCALE_FACTOR) / 1000 + 1;
}
constexpr unsigned int MAX_SIMULATED_CONTINUATION_BATCHES{512};
} // namespace

MigrationContinuation PlanMigrationContinuation(std::vector<MigrationBatchInput> pool,
                                                const MigrationContinuationParams& p)
{
    MigrationContinuation result;
    size_t legacy_left = std::count_if(pool.begin(), pool.end(), [](const MigrationBatchInput& c) { return !c.auxiliary; });
    if (legacy_left == 0) return result;
    auto fail = [&](std::string reason) {
        result.feasible = false;
        result.reason = std::move(reason);
        return result;
    };
    if (p.max_inputs == 0) return fail("no input is allowed per batch");

    uint32_t synthetic{0};
    if (p.output_can_anchor) {
        MigrationBatchInput first;
        first.outpoint = COutPoint{Txid{}, 0xFFFFFF00U + synthetic++};
        first.value = first.effective_value = p.first_output;
        first.input_weight = std::max<int64_t>(1, p.auxiliary_input_weight);
        first.anchor = true;
        first.auxiliary = true;
        first.depth = 1;
        pool.push_back(first);
    }

    result.min_blocks = 1;
    while (legacy_left > 0) {
        if (result.batches >= MAX_SIMULATED_CONTINUATION_BATCHES) {
            // Whole-budget fee for every batch that is left: a bound that cannot be too low.
            CAmount value{0};
            int64_t weight{0};
            for (const MigrationBatchInput& c : pool) {
                value += c.effective_value;
                if (!c.auxiliary) weight += std::max<int64_t>(1, c.input_weight);
            }
            const int64_t room = std::max<int64_t>(1, p.weight_budget - p.fixed_weight - std::max<int64_t>(1, p.auxiliary_input_weight));
            const int64_t by_weight = (weight + room - 1) / room;
            const int64_t by_count = (static_cast<int64_t>(legacy_left) + static_cast<int64_t>(p.max_inputs) - 1) / static_cast<int64_t>(p.max_inputs);
            const int64_t left = std::max(by_weight, by_count);
            const CAmount worst = ContinuationFee(p.fee_rate_per_kvb, p.weight_budget) * left + p.dust;
            result.batches += static_cast<unsigned int>(left);
            result.fees += worst - p.dust;
            result.min_blocks += static_cast<unsigned int>(left);
            if (value < worst) return fail("the rest of the legacy value cannot pay for the batches it still needs");
            return result;
        }
        MigrationBatchPlan plan = PlanMigrationBatch(pool, p.max_inputs, p.fixed_weight, p.weight_budget, p.require_anchor, false);
        if (plan.blocked_no_anchor) return fail("a later batch would have no anchor");
        if (plan.selected.empty()) return fail("no remaining input fits a standard transaction");
        auto output_of = [&](const MigrationBatchPlan& pl, CAmount& fee_out) {
            CAmount in{0};
            for (const MigrationBatchInput& c : pl.selected) in += c.effective_value;
            for (const MigrationBatchInput& c : pl.auxiliary) in += c.effective_value;
            fee_out = ContinuationFee(p.fee_rate_per_kvb, pl.estimated_weight);
            return in - fee_out;
        };
        CAmount fee{0};
        CAmount out = output_of(plan, fee);
        const bool aux_available = std::any_of(pool.begin(), pool.end(), [](const MigrationBatchInput& c) { return c.auxiliary; });
        if (out < p.dust && plan.auxiliary.empty() && aux_available) {
            plan = PlanMigrationBatch(pool, p.max_inputs, p.fixed_weight, p.weight_budget, p.require_anchor, true);
            if (plan.selected.empty()) return fail("no remaining input fits a standard transaction");
            out = output_of(plan, fee);
        }
        if (out < p.dust) return fail("a later batch could not pay its fee and leave an output above dust");

        int depth{1};
        for (const MigrationBatchInput& c : plan.auxiliary) depth = std::max(depth, c.depth + 1);
        result.min_blocks = std::max<unsigned int>(result.min_blocks, static_cast<unsigned int>(depth));
        ++result.batches;
        result.fees += fee;
        legacy_left -= plan.selected.size();
        std::set<COutPoint> used;
        for (const MigrationBatchInput& c : plan.selected) used.insert(c.outpoint);
        for (const MigrationBatchInput& c : plan.auxiliary) used.insert(c.outpoint);
        pool.erase(std::remove_if(pool.begin(), pool.end(), [&](const MigrationBatchInput& c) { return used.count(c.outpoint) > 0; }), pool.end());
        if (p.output_can_anchor && legacy_left > 0) {
            MigrationBatchInput next;
            next.outpoint = COutPoint{Txid{}, 0xFFFFFF00U + synthetic++};
            next.value = next.effective_value = out;
            next.input_weight = std::max<int64_t>(1, p.auxiliary_input_weight);
            next.anchor = true;
            next.auxiliary = true;
            next.depth = depth;
            pool.push_back(next);
        }
    }
    return result;
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
            // A partial batch must leave a way to finish: never discover afterwards that the rest
            // cannot be migrated. Simulate every later batch with the same planner: the batch's own
            // quantum output anchors and funds the continuation (it must be an ordinary quantum
            // output), and each later batch pays its own fee at no less than this batch's rate and
            // the wallet and relay minimums, for the actual auxiliary input weight and the selected
            // max_inputs.
            std::set<COutPoint> chosen(batch.selected.begin(), batch.selected.end());
            std::set<COutPoint> used_auxiliary(batch.auxiliary.begin(), batch.auxiliary.end());
            std::vector<MigrationBatchInput> pool;
            bool legacy_anchor_remains{false};
            for (const MigrationBatchInput& c : candidates) {
                if (chosen.count(c.outpoint) || used_auxiliary.count(c.outpoint)) continue;
                pool.push_back(c);
                legacy_anchor_remains = legacy_anchor_remains || (c.anchor && !c.auxiliary);
            }
            const bool output_can_anchor = IsDirectQuantumMigrationScript(GetScriptForDestination(destination));
            if (require_anchor && !legacy_anchor_remains && !output_can_anchor &&
                std::none_of(pool.begin(), pool.end(), [](const MigrationBatchInput& c) { return c.auxiliary; })) {
                return util::Error{_("This batch would leave legacy coins that cannot be migrated afterwards: the destination is not an ordinary quantum address, so its output cannot anchor the next batch. Use an ordinary quantum address, or a larger max_inputs.")};
            }
            MigrationContinuationParams cont;
            cont.max_inputs = limit;
            cont.require_anchor = require_anchor;
            const int64_t batch_rate = batch.estimated_vsize > 0 ? batch.fee * 1000 / batch.estimated_vsize : 0;
            // The rate a later batch must at least pay: this batch's, the relay minimum, and what the
            // wallet's required fee (the consensus minimum fee included) comes to for a full-size batch.
            const unsigned int full_vsize = static_cast<unsigned int>((MIGRATION_BATCH_WEIGHT_BUDGET + WITNESS_SCALE_FACTOR - 1) / WITNESS_SCALE_FACTOR);
            const CAmount full_min_fee = GetMinimumFee(wallet, full_vsize, control, GetAdjustedTimeSeconds());
            cont.fee_rate_per_kvb = std::max<int64_t>({batch_rate, wallet.chain().relayMinFee().GetFeePerK(),
                                                       (full_min_fee * 1000 + full_vsize - 1) / full_vsize, 1});
            cont.dust = GetDustThreshold(batch.tx->vout[0], wallet.chain().relayDustFee());
            const int own_vsize = CalculateMaximumSignedInputSize(batch.tx->vout[0], &wallet, &control);
            cont.auxiliary_input_weight = std::max<int64_t>(MIGRATION_QUANTUM_INPUT_FALLBACK_WEIGHT,
                                                            own_vsize > 0 ? int64_t{own_vsize} * WITNESS_SCALE_FACTOR : 0);
            cont.first_output = batch.tx->vout[0].nValue;
            cont.output_can_anchor = output_can_anchor;
            const MigrationContinuation continuation = PlanMigrationContinuation(std::move(pool), cont);
            if (!continuation.feasible) {
                return util::Error{strprintf(_("This batch would leave legacy coins that cannot be migrated afterwards (%s). Migrate with a larger max_inputs, or add funds first."),
                                             continuation.reason)};
            }
            batch.continuation_batches = continuation.batches;
            batch.continuation_fees = continuation.fees;
            batch.continuation_min_blocks = continuation.min_blocks;
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
    const std::set<COutPoint> protected_seals = wallet.GetProtectedRGBSeals();
    // Whether this wallet has what it takes to sign for a script: private keys at all, ownership that
    // is not watch-only, and a signing provider that can size the spend. Looked up once per script.
    std::map<CScript, bool> can_sign_memo;
    auto CanSign = [&](const CTxOut& txout) {
        auto [it, inserted] = can_sign_memo.try_emplace(txout.scriptPubKey, false);
        if (inserted) {
            it->second = !wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS) &&
                         (wallet.IsMine(txout) & ISMINE_SPENDABLE) != ISMINE_NO &&
                         CalculateMaximumSignedInputSize(txout, &wallet, /*coin_control=*/nullptr) > 0;
        }
        return it->second;
    };
    // An inventory of everything the wallet owns and has not spent, not a filtered coin-selection
    // view: the filters of AvailableCoins (protected seals, unconfirmed transactions outside the
    // mempool, reuse and script rules) would hide exactly the outputs a sweep did not consider.
    for (const auto& [txid, wtx] : wallet.mapWallet) {
        const int depth = wallet.GetTxDepthInMainChain(wtx);
        for (unsigned int n = 0; n < wtx.tx->vout.size(); ++n) {
            const CTxOut& txout = wtx.tx->vout[n];
            const COutPoint outpoint(txid, n);
            if (txout.nValue <= 0) continue;
            const CScript& spk = txout.scriptPubKey;
            if (IsQuantumMigrationScript(spk) || IsQuantumColdStakeScript(spk) || IsEUTXOScript(spk)) continue;
            if (considered.count(outpoint)) continue;
            const isminetype mine = wallet.IsMine(txout);
            if (mine == ISMINE_NO) continue;
            if (wallet.IsSpent(outpoint)) continue;
            // An abandoned or conflicted transaction holds no coin the wallet can move.
            if (depth < 0 || wtx.isAbandoned()) continue;

            ResidualCategory* category = &excluded.other;
            const bool immature = wallet.IsTxImmature(wtx) && !(depth >= consensus.nCoinbaseMaturity);
            if (protected_seals.count(outpoint)) {
                category = &excluded.protected_asset;
            } else if (wallet.IsLockedCoin(outpoint)) {
                category = &excluded.locked;
            } else if (immature) {
                category = &excluded.immature;
            } else if (depth == 0) {
                category = &excluded.unconfirmed;
            } else if (!CanSign(txout)) {
                category = &excluded.signer_unavailable;
            }
            ++category->count;
            category->amount += txout.nValue;
            ++excluded.count;
            excluded.amount += txout.nValue;
            const Coin& coin = view.AccessCoin(outpoint);
            if (!coin.IsSpent() && (coin.IsCoinBase() || coin.IsCoinStake())) {
                const int64_t matures = int64_t{coin.nHeight} + int64_t{consensus.nCoinbaseMaturity};
                if (matures >= next_height && (excluded.next_maturity_height == 0 || matures < excluded.next_maturity_height)) {
                    excluded.next_maturity_height = matures;
                }
            }
        }
    }
    return excluded;
}

std::string DescribeExcludedLegacyOutputs(const ExcludedLegacyOutputs& excluded)
{
    std::string out;
    auto add = [&](const ResidualCategory& c, const char* name) {
        if (c.count == 0) return;
        if (!out.empty()) out += ", ";
        out += strprintf("%u %s (%s)", c.count, name, FormatMoney(c.amount));
    };
    add(excluded.protected_asset, "protected asset");
    add(excluded.locked, "locked");
    add(excluded.immature, "immature");
    add(excluded.unconfirmed, "unconfirmed");
    add(excluded.signer_unavailable, "without a signer here");
    add(excluded.other, "other");
    return out;
}

size_t ClampMigrationBatchInputs(int64_t requested, unsigned int default_inputs)
{
    if (requested <= 0) return default_inputs;
    return static_cast<size_t>(std::min<int64_t>(requested, MAX_MIGRATION_BATCH_INPUTS_OPTION));
}

} // namespace wallet
