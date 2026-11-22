// Copyright (c) 2014-2023 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

// Staking start/stop algos by Qtum
// Copyright (c) 2016-2023 The Qtum developers

#include <index/txindex.h>
#include <addresstype.h>
#include <chain.h>
#include <common/args.h>
#include <consensus/demurrage.h>
#include <crypto/mldsa.h>
#include <key_io.h>
#include <node/quantum_pool.h>
#include <policy/policy.h>
#include <wallet/coincontrol.h>
#include <wallet/fees.h>
#include <wallet/migration_batch.h>
#include <wallet/quantum_return_backup.h>
#include <wallet/receive.h>
#include <wallet/redelegation.h>
#include <wallet/staking.h>
#include <wallet/spend.h>
#include <hash.h>
#include <node/miner.h>
#include <script/signingprovider.h>
#include <shadow.h>
#include <support/cleanse.h>
#include <txmempool.h>
#include <util/check.h>
#include <util/moneystr.h>
#include <util/result.h>
#include <util/time.h>
#include <util/translation.h>
#include <undo.h>
#include <validation.h>
#include <wallet/walletdb.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <limits>
#include <map>
#include <set>
#include <string_view>
#include <thread>

namespace wallet {

static int64_t GetStakeCombineThreshold() { return 500 * COIN; }
static int64_t GetStakeSplitThreshold() { return 2 * GetStakeCombineThreshold(); }

static bool IsKnownColdStakeOutput(CWallet& wallet, const CTxOut& output) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    (void)wallet;
    return IsQuantumColdStakeScript(output.scriptPubKey);
}

static bool CoinStakeSpendsKnownColdStake(CWallet& wallet, const CMutableTransaction& txNew, const std::vector<CTransactionRef>& prev_txs) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    if (txNew.vin.size() != prev_txs.size()) {
        return false;
    }

    for (size_t i = 0; i < txNew.vin.size(); ++i) {
        const CTxIn& txin = txNew.vin[i];
        const CTransactionRef& prev_tx = prev_txs[i];
        if (!prev_tx || prev_tx->GetHash() != txin.prevout.hash || txin.prevout.n >= prev_tx->vout.size()) {
            return false;
        }
        if (IsKnownColdStakeOutput(wallet, prev_tx->vout[txin.prevout.n])) {
            return true;
        }
    }
    return false;
}

namespace {

struct AutoRedelegationSource
{
    CTxDestination source_dest;
    std::vector<unsigned char> witness_program;
    uint256 staker_pubkey_hash;
    CAmount amount{0};
    int activation_height{0};
    int last_win_height{0};
};

/** Whether the output is a Gold Rush payout that is still locked at the given evaluation point. The
 *  point is the block the scan describes (the next block for the staker, a later one for a projection):
 *  a payout that is locked now is not locked in the first Final block. */
bool IsGeneratedQuantumStakeCandidate(const CWallet& wallet, const COutPoint& outpoint, const CScript& script_pub_key,
                                      int spend_height, int64_t spend_time)
{
    if (!IsQuantumMigrationScript(script_pub_key)) return false;

    CScript marker_script;
    return IsLockedGoldRushPayoutOutput(wallet.chain().getCoinsTip(), outpoint,
        Params().GetConsensus(), spend_time, spend_height, &marker_script) && marker_script == script_pub_key;
}

bool IsDemurrageLockedStakeCandidate(const CWallet& wallet, const COutPoint& outpoint, const CScript& script_pub_key, int spend_height, int64_t spend_time)
{
    const Consensus::Params& consensus = Params().GetConsensus();
    if (!consensus.IsDemurrageActive(spend_height, spend_time)) return false;

    std::map<COutPoint, Coin> coins;
    coins.emplace(outpoint, Coin{});
    wallet.chain().findCoins(coins);
    const auto it = coins.find(outpoint);
    if (it == coins.end() || it->second.out.IsNull()) return false;

    const std::optional<Consensus::DemurrageAttestationState> latest_attestation = Consensus::LatestDemurrageAttestationStateForScript(
        wallet.chain().getCoinsTip(), script_pub_key);
    return Consensus::EvaluateDemurrage(
        it->second, consensus, spend_height, spend_time,
        latest_attestation ? std::optional<int>{latest_attestation->height} : std::nullopt,
        latest_attestation ? std::optional<int>{static_cast<int>(latest_attestation->coverage_start_height)} : std::nullopt).locked;
}

bool HasUnderCapRedelegationAlternative(const node::QuantumPoolShareCalculator& pool_shares, const uint256& source_staker_hash, const uint256& target_staker_hash, CAmount delegation_amount)
{
    std::vector<QuantumRedelegationCandidate> candidates;
    for (const uint256& staker_hash : node::ListQuantumPoolOperators()) {
        if (staker_hash == source_staker_hash || staker_hash == target_staker_hash) continue;
        const node::QuantumPoolShare share = pool_shares.ComputeShare(staker_hash, node::GetQuantumPoolClaims(staker_hash));
        QuantumRedelegationCandidate candidate;
        candidate.staker_pubkey_hash = staker_hash;
        candidate.staker_pubkey = share.operator_share.staker_pubkey;
        candidate.operator_value = share.operator_share.verified_value;
        candidate.total_coldstake = share.total_coldstake;
        candidate.operator_commitment_verified = share.operator_share.operator_commitment_verified;
        candidate.current_operator = false;
        candidates.push_back(std::move(candidate));
    }
    return HasUnderCapQuantumRedelegationCandidate(candidates, delegation_amount);
}

struct AutoShadowSignalCandidate
{
    CScript target;
    uint32_t solve_height{0};
    uint256 solve_hash;
    int scan_height{-1};
};

static constexpr const char* SHADOW_SIGNAL_COMMENT{"PoS Claim"};
static constexpr const char* OLD_SHADOW_SIGNAL_COMMENT{"Quantum PoS Claim"};
static constexpr unsigned int DEFAULT_SHADOW_SIGNAL_MAX_RETRY_FAILURES{6};
static constexpr int64_t DEFAULT_SHADOW_SIGNAL_RETRY_BASE_MILLIS{1000};

static unsigned int ShadowSignalMaxRetryFailures()
{
    if (!Params().IsTestChain()) return DEFAULT_SHADOW_SIGNAL_MAX_RETRY_FAILURES;
    return static_cast<unsigned int>(std::clamp<int64_t>(
        gArgs.GetIntArg("-qqshadowsignalmaxretryfailures", DEFAULT_SHADOW_SIGNAL_MAX_RETRY_FAILURES), 1, 64));
}

static int64_t ShadowSignalRetryBaseMillis()
{
    if (!Params().IsTestChain()) return DEFAULT_SHADOW_SIGNAL_RETRY_BASE_MILLIS;
    return std::clamp<int64_t>(
        gArgs.GetIntArg("-qqshadowsignalretrybasemillis", DEFAULT_SHADOW_SIGNAL_RETRY_BASE_MILLIS), 1, 60000);
}

static int64_t ShadowSignalSteadyMillis()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(SteadyClock::now().time_since_epoch()).count();
}

class AutoShadowSignalAttemptGuard
{
public:
    explicit AutoShadowSignalAttemptGuard(CWallet& wallet) : m_wallet(wallet)
    {
        const int64_t now = ShadowSignalSteadyMillis();
        if (now < wallet.m_shadow_signal_next_retry_ms.load()) return;

        bool expected{false};
        m_acquired = wallet.m_shadow_signal_inflight.compare_exchange_strong(expected, true);
        // Recheck the deadline after winning the race in case the previous
        // attempt published its backoff immediately before releasing inflight.
        if (m_acquired && now < wallet.m_shadow_signal_next_retry_ms.load()) {
            wallet.m_shadow_signal_inflight = false;
            m_acquired = false;
        }
    }

    AutoShadowSignalAttemptGuard(const AutoShadowSignalAttemptGuard&) = delete;
    AutoShadowSignalAttemptGuard& operator=(const AutoShadowSignalAttemptGuard&) = delete;

    ~AutoShadowSignalAttemptGuard()
    {
        if (m_acquired) m_wallet.m_shadow_signal_inflight = false;
    }

    explicit operator bool() const { return m_acquired; }

private:
    CWallet& m_wallet;
    bool m_acquired{false};
};

void ResetAutoShadowSignalBackoff(CWallet& wallet)
{
    wallet.m_shadow_signal_retry_failures = 0;
    wallet.m_shadow_signal_next_retry_ms = 0;
}

void ResetAutoShadowSignalScanHeight(CWallet& wallet, int scan_height)
{
    if (scan_height < 0) return;
    LOCK(wallet.cs_wallet);
    if (wallet.m_shadow_signal_last_auto_scan_height == scan_height) {
        wallet.m_shadow_signal_last_auto_scan_height = scan_height - 1;
        wallet.m_shadow_signal_last_auto_scan_tip.SetNull();
    }
}

void ScheduleAutoShadowSignalRetry(CWallet& wallet, int scan_height, const std::string& reason)
{
    const unsigned int max_failures = ShadowSignalMaxRetryFailures();
    const unsigned int failures = std::min(wallet.m_shadow_signal_retry_failures.fetch_add(1) + 1,
                                           max_failures);
    wallet.m_shadow_signal_retry_failures = failures;
    const unsigned int delay_shift = std::min<unsigned int>(failures - 1, 16);
    const int64_t delay_ms = std::min<int64_t>(ShadowSignalRetryBaseMillis() * (int64_t{1} << delay_shift), 60000);
    wallet.m_shadow_signal_next_retry_ms = ShadowSignalSteadyMillis() + delay_ms;
    ResetAutoShadowSignalScanHeight(wallet, scan_height);
    LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: retry in %dms after %s\n", delay_ms, reason);
}

bool IsWalletShadowSignal(const CWalletTx& wtx)
{
    const auto comment = wtx.mapValue.find("comment");
    return TransactionHasShadowSignal(*wtx.tx) && comment != wtx.mapValue.end() &&
           (comment->second == SHADOW_SIGNAL_COMMENT || comment->second == OLD_SHADOW_SIGNAL_COMMENT);
}

bool IsTerminalShadowSignalReject(const std::string& reject_reason)
{
    static constexpr std::array<std::string_view, 6> TERMINAL_REJECTS{
        "shadow-signal-inactive",
        "shadow-signal-invalid-location",
        "shadow-signal-invalid",
        "shadow-signal-target",
        "shadow-signal-input-mismatch",
        "shadow-signal-stale-solve",
    };
    return std::any_of(TERMINAL_REJECTS.begin(), TERMINAL_REJECTS.end(), [&](const std::string_view reason) {
        return reject_reason.find(reason) != std::string::npos;
    });
}

enum class PendingShadowSignalState {
    NONE,
    LIVE,
    RETRY,
};

bool TryAbandonInactiveShadowSignal(CWallet& wallet, const uint256& txid)
{
    // Regtest-only barrier used to prove a peer insertion racing cleanup is
    // observed by the atomic mempool/wallet recheck below.
    if (Params().IsTestChain()) {
        const int64_t delay_ms = std::clamp<int64_t>(gArgs.GetIntArg("-qqshadowsignalcleanupdelaymillis", 0), 0, 10000);
        if (delay_ms > 0) {
            LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: cleanup race barrier reached for %s\n", txid.ToString());
            std::this_thread::sleep_for(std::chrono::milliseconds{delay_ms});
        }
    }

    // Keep mempool membership and wallet state in one snapshot using the
    // established wallet -> mempool order used by wallet notifications.
    // Nonblocking acquisition keeps the staking worker from delaying either
    // validation or foreground wallet work. Holding both locks through
    // AbandonTransaction prevents a peer from inserting the exact transaction
    // between the membership test and the state transition.
    const CTxMemPool& mempool = wallet.chain().mempool();
    TRY_LOCK(wallet.cs_wallet, wallet_lock);
    if (!wallet_lock) return false;
    TRY_LOCK(mempool.cs, mempool_lock);
    if (!mempool_lock || mempool.exists(GenTxid::Txid(txid))) return false;
    const CWalletTx* wtx = wallet.GetWalletTx(txid);
    if (!wtx || !wtx->isUnconfirmed() || wtx->InMempool()) return false;
    return wallet.AbandonTransaction(txid);
}

PendingShadowSignalState ReconcilePendingShadowSignals(CWallet& wallet, std::string& retry_reason)
{
    std::vector<std::pair<uint256, CTransactionRef>> pending;
    {
        LOCK(wallet.cs_wallet);
        for (const uint256& txid : wallet.GetPendingShadowSignalTxids()) {
            const auto it = wallet.mapWallet.find(txid);
            if (it == wallet.mapWallet.end()) continue;
            const CWalletTx& wtx = it->second;
            if (!wtx.isUnconfirmed() || wtx.isAbandoned() || wtx.isConflicted() || !IsWalletShadowSignal(wtx)) continue;
            pending.emplace_back(txid, wtx.tx);
        }
    }

    for (const auto& pending_signal : pending) {
        const uint256& txid = pending_signal.first;
        const CTransactionRef& signal_tx = pending_signal.second;
        if (wallet.chain().isInMempool(txid)) return PendingShadowSignalState::LIVE;

        // Classify against a single active-tip snapshot even if wallet relay is
        // disabled. Otherwise a terminally stale signal can reserve its input
        // forever merely because SubmitTxMemoryPoolAndRelay returns before
        // validation under -walletbroadcast=0.
        const MempoolAcceptResult accept = [&] {
            LOCK(::cs_main);
            return wallet.chain().chainman().ProcessTransaction(signal_tx, /*test_accept=*/true);
        }();
        if (accept.m_result_type != MempoolAcceptResult::ResultType::VALID) {
            if (wallet.chain().isInMempool(txid)) return PendingShadowSignalState::LIVE;
            const std::string reject_reason = accept.m_state.GetRejectReason();
            const std::string failure = reject_reason.empty() ? accept.m_state.ToString() : reject_reason;
            const bool terminal_reject = IsTerminalShadowSignalReject(failure);
            const unsigned int failed_attempt = wallet.m_shadow_signal_retry_failures.load() + 1;
            if ((terminal_reject || failed_attempt >= ShadowSignalMaxRetryFailures()) &&
                TryAbandonInactiveShadowSignal(wallet, txid)) {
                wallet.WalletLogPrintf("Automatically abandoned Gold Rush PoS signal %s and released its inputs after %u failed validations: %s\n",
                                       txid.ToString(), failed_attempt, failure);
                continue;
            }

            // Policy rejects such as txn-mempool-conflict, missing inputs, or
            // changing minimum fees can persist indefinitely. They are retried
            // with bounded backoff, then enter the same safe abandonment path
            // as a terminal phase reject. Confirmed, conflicted, or newly-live
            // transactions cannot pass TryAbandonInactiveShadowSignal.
            retry_reason = (terminal_reject || failed_attempt >= ShadowSignalMaxRetryFailures())
                ? strprintf("signal cleanup is waiting for wallet state: %s", failure)
                : failure;
            return PendingShadowSignalState::RETRY;
        }

        // An evicted or restart-orphaned signal may still be valid. Resubmit it
        // before considering a replacement so the wallet never double-spends
        // its own signaling input.
        std::string broadcast_error;
        if (wallet.SubmitTxMemoryPoolAndRelay(txid, broadcast_error, /*relay=*/true) ||
            wallet.chain().isInMempool(txid)) {
            wallet.WalletLogPrintf("Gold Rush PoS signal resubmitted after mempool eviction: txid=%s\n", txid.ToString());
            return PendingShadowSignalState::LIVE;
        }

        const unsigned int failed_attempt = wallet.m_shadow_signal_retry_failures.load() + 1;
        if (failed_attempt >= ShadowSignalMaxRetryFailures() &&
            broadcast_error != "wallet-broadcast-in-flight") {
            // A locally valid but persistently dropped signal is replaceable:
            // it has no shadow effect until confirmed. After the bounded retry
            // window, release its wallet input instead of reserving that coin
            // forever. The audit record remains in the wallet as abandoned.
            if (TryAbandonInactiveShadowSignal(wallet, txid)) {
                wallet.WalletLogPrintf("Abandoned unrelayed Gold Rush PoS signal %s after %u failed resubmissions and released its inputs: %s\n",
                                       txid.ToString(), failed_attempt,
                                       broadcast_error.empty() ? "wallet broadcasting is disabled" : broadcast_error);
                continue;
            }
        }

        retry_reason = broadcast_error.empty() ? "valid pending signal could not be resubmitted" : broadcast_error;
        return PendingShadowSignalState::RETRY;
    }
    return PendingShadowSignalState::NONE;
}

bool HasPendingShadowSignal(CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    for (const uint256& txid : wallet.GetPendingShadowSignalTxids()) {
        const auto it = wallet.mapWallet.find(txid);
        if (it == wallet.mapWallet.end()) continue;
        const CWalletTx& wtx = it->second;
        const auto comment = wtx.mapValue.find("comment");
        if (comment == wtx.mapValue.end() || (comment->second != SHADOW_SIGNAL_COMMENT && comment->second != OLD_SHADOW_SIGNAL_COMMENT)) continue;
        if (wtx.isUnconfirmed()) return true;
    }
    return false;
}

bool FindAutoShadowSignalCandidate(CWallet& wallet, AutoShadowSignalCandidate& candidate)
{
    const Consensus::Params& consensus = Params().GetConsensus();
    int scan_height{-1};
    uint256 scan_tip_hash;
    {
        TRY_LOCK(::cs_main, main_lock);
        if (!main_lock) {
            LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: skipped because chain lock is busy\n");
            return false;
        }
        const CBlockIndex* tip = wallet.chain().chainman().ActiveChain().Tip();
        if (!tip) return false;
        scan_height = tip->nHeight;
        scan_tip_hash = tip->GetBlockHash();
        if (!IsShadowGoldRushRewardActive(consensus, tip->GetMedianTimePast(), scan_height + 1)) {
            LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: inactive at height=%d\n", scan_height);
            return false;
        }
    }

    // Derive exact solver references from this wallet's confirmed coinstakes.
    // This in-memory wallet snapshot deliberately runs without cs_main. The
    // former implementation held both locks while Cursor() scanned the entire
    // chainstate UTXO database, freezing chain RPC and GUI progress on large
    // nodes. Each entry below is later checked by its deterministic marker
    // outpoint, so automatic discovery never needs CCoinsView::Cursor.
    std::vector<WalletShadowSolveReference> wallet_solves;
    {
        TRY_LOCK(wallet.cs_wallet, wallet_lock);
        if (!wallet_lock) {
            LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: skipped because wallet lock is busy\n");
            return false;
        }
        if (DecideAutoScan(wallet.m_shadow_signal_last_auto_scan_height,
                           wallet.m_shadow_signal_last_auto_scan_tip, scan_height, scan_tip_hash,
                           wallet.m_shadow_signal_last_reorg_scan,
                           std::chrono::steady_clock::now()) != AutoScanVerdict::SCAN) {
            LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: already scanned height=%d (or a reorganisation rescan is rate limited)\n", scan_height);
            return false;
        }
        wallet.m_shadow_signal_last_auto_scan_height = scan_height;
        wallet.m_shadow_signal_last_auto_scan_tip = scan_tip_hash;
        if (HasPendingShadowSignal(wallet)) {
            LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: pending signal already exists\n");
            return false;
        }

        wallet_solves = GetWalletShadowSolveReferences(wallet, scan_height);
    }

    bool retry_scan{false};
    {
        TRY_LOCK(::cs_main, main_lock);
        if (!main_lock) {
            retry_scan = true;
        } else {
            const CBlockIndex* tip = wallet.chain().chainman().ActiveChain().Tip();
            if (!tip || tip->nHeight != scan_height || tip->GetBlockHash() != scan_tip_hash) {
                // The wallet snapshot belongs to a different active tip. Do
                // not mix it with current chainstate; retry on the next loop.
                retry_scan = true;
            } else {
                const CCoinsViewCache& view = wallet.chain().chainman().ActiveChainstate().CoinsTip();
                const std::map<CScript, CScript> active_signals = GetActiveShadowSignalPayouts(view, tip);
                unsigned int whitelisted_solves{0};
                unsigned int recent_solves{0};
                unsigned int already_active_solves{0};

                // Prefer the newest qualified solve. Validation is an O(1)
                // lookup of SolverOutpoint(target, height, hash), not a UTXO
                // cursor or an 18,900-block reverse walk.
                const CChain& active_chain = wallet.chain().chainman().ActiveChain();
                for (const WalletShadowSolveReference& solve : wallet_solves) {
                    if (!IsWhitelisted(view, solve.target)) continue;
                    ++whitelisted_solves;
                    const CBlockIndex* solved = active_chain[solve.solve_height];
                    if (!solved || solved->GetBlockHash() != solve.solve_hash ||
                        !HasRecentShadowSolverActivity(view, tip, solve.target, solve.solve_height, solve.solve_hash)) {
                        continue;
                    }
                    ++recent_solves;
                    if (active_signals.count(solve.target)) {
                        ++already_active_solves;
                        continue;
                    }
                    candidate.target = solve.target;
                    candidate.solve_height = solve.solve_height;
                    candidate.solve_hash = solve.solve_hash;
                    candidate.scan_height = scan_height;
                    LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: candidate found solve_height=%u wallet_solves=%u\n",
                             candidate.solve_height, wallet_solves.size());
                    return true;
                }

                if (already_active_solves > 0) {
                    LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: wallet signal already active (wallet_active=%u wallet_recent=%u active_network=%u)\n",
                             already_active_solves, recent_solves, active_signals.size());
                } else {
                    LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: no eligible wallet solve needing a signal (wallet_solves=%u wallet_whitelisted=%u wallet_recent=%u active_network=%u)\n",
                             wallet_solves.size(), whitelisted_solves, recent_solves, active_signals.size());
                }
            }
        }
    }
    if (retry_scan) ResetAutoShadowSignalScanHeight(wallet, scan_height);
    return false;
}

struct AutoShadowSignalFeeCandidate
{
    COutPoint outpoint;
    CTxOut txout;
    int confirmed_height{0};
    bool coinbase{false};
    bool coinstake{false};
    int64_t smart_time{0};
};

struct AutoShadowSignalFeeScan
{
    std::vector<AutoShadowSignalFeeCandidate> candidates;
    size_t transactions_scanned{0};
    size_t outputs_scanned{0};
};

AutoShadowSignalFeeScan FindAutoShadowSignalFeeCandidates(CWallet& wallet, const CScript& target)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet)
{
    AutoShadowSignalFeeScan result;
    if (wallet.mapWallet.empty()) return result;

    // Automatic QQSIGNAL construction used to call AvailableCoins(), sort its
    // complete result, and only then discard every output not owned by target.
    // Walk a resumable slice of wallet history instead. This deterministically
    // bounds each attempt even for a long-lived wallet. Under stable wallet
    // history the saved outpoint resumes at the following output on each retry.
    auto tx_it = wallet.mapWallet.begin();
    uint32_t first_vout{0};
    const COutPoint resume_after = wallet.m_shadow_signal_coin_scan_cursor;
    if (!resume_after.hash.IsNull()) {
        tx_it = wallet.mapWallet.find(resume_after.hash);
        if (tx_it != wallet.mapWallet.end()) {
            if (!tx_it->second.tx) {
                ++tx_it;
            } else {
                const size_t next_vout = resume_after.n == std::numeric_limits<uint32_t>::max()
                    ? tx_it->second.tx->vout.size()
                    : static_cast<size_t>(resume_after.n) + 1;
                if (next_vout < tx_it->second.tx->vout.size()) {
                    first_vout = static_cast<uint32_t>(next_vout);
                } else {
                    ++tx_it;
                }
            }
        }
    }
    if (tx_it == wallet.mapWallet.end()) tx_it = wallet.mapWallet.begin();

    const size_t transaction_budget = std::min(
        wallet.mapWallet.size(), MAX_AUTO_SHADOW_SIGNAL_WALLET_TX_SCAN);
    const std::set<COutPoint> protected_rgb_seals = wallet.GetProtectedRGBSeals();
    static constexpr size_t MAX_CANDIDATES_PER_ATTEMPT{256};

    while (result.transactions_scanned < transaction_budget &&
           result.outputs_scanned < MAX_AUTO_SHADOW_SIGNAL_WALLET_OUTPUT_SCAN &&
           result.candidates.size() < MAX_CANDIDATES_PER_ATTEMPT) {
        if (wallet.IsStakeClosing()) break;
        if (tx_it == wallet.mapWallet.end()) tx_it = wallet.mapWallet.begin();

        const uint256 txid = tx_it->first;
        const CWalletTx& wtx = tx_it->second;
        ++result.transactions_scanned;

        if (!wtx.tx) {
            wallet.m_shadow_signal_coin_scan_cursor =
                COutPoint{txid, std::numeric_limits<uint32_t>::max()};
            ++tx_it;
            continue;
        }

        const int depth = wallet.GetTxDepthInMainChain(wtx);
        const TxStateConfirmed* confirmed = wtx.state<TxStateConfirmed>();
        const bool eligible_transaction = confirmed && depth > 0 &&
            depth <= DEFAULT_MAX_DEPTH && !wallet.IsTxImmature(wtx);

        const size_t output_begin = std::min<size_t>(first_vout, wtx.tx->vout.size());
        first_vout = 0;
        if (wtx.tx->vout.empty()) {
            wallet.m_shadow_signal_coin_scan_cursor =
                COutPoint{txid, std::numeric_limits<uint32_t>::max()};
        }
        for (size_t output_index = output_begin;
             output_index < wtx.tx->vout.size() &&
             result.outputs_scanned < MAX_AUTO_SHADOW_SIGNAL_WALLET_OUTPUT_SCAN &&
             result.candidates.size() < MAX_CANDIDATES_PER_ATTEMPT;
             ++output_index) {
            if (output_index > std::numeric_limits<uint32_t>::max()) break;
            const COutPoint outpoint{txid, static_cast<uint32_t>(output_index)};
            wallet.m_shadow_signal_coin_scan_cursor = outpoint;
            ++result.outputs_scanned;
            if (!eligible_transaction) continue;

            const CTxOut& output = wtx.tx->vout[output_index];
            if (output.nValue <= 0 ||
                CanonicalizeLegacyStakeScript(output.scriptPubKey) != target ||
                wallet.IsLockedCoin(outpoint) || wallet.IsSpent(outpoint) ||
                protected_rgb_seals.count(outpoint) ||
                (wallet.IsMine(output) & ISMINE_SPENDABLE) == ISMINE_NO) {
                continue;
            }
            result.candidates.push_back(AutoShadowSignalFeeCandidate{
                outpoint,
                output,
                confirmed->confirmed_block_height,
                wtx.IsCoinBase(),
                wtx.IsCoinStake(),
                wtx.nTimeSmart,
            });
        }
        ++tx_it;
    }

    std::sort(result.candidates.begin(), result.candidates.end(),
              [](const AutoShadowSignalFeeCandidate& a, const AutoShadowSignalFeeCandidate& b) {
        if (a.txout.nValue != b.txout.nValue) return a.txout.nValue < b.txout.nValue;
        return a.outpoint < b.outpoint;
    });
    return result;
}

bool BuildAutoShadowSignalTransaction(CWallet& wallet, const AutoShadowSignalCandidate& candidate, const CScript& payout_script, CMutableTransaction& signal_tx, std::map<COutPoint, Coin>& coins, CAmount& fee, bilingual_str& error)
{
    std::vector<unsigned char> signal;
    if (!BuildShadowSignalData(candidate.target, payout_script, candidate.solve_height, candidate.solve_hash, signal)) {
        error = _("Failed to build Gold Rush PoS signal payload.");
        return false;
    }

    CTxDestination target_dest;
    if (!ExtractDestination(candidate.target, target_dest) || !IsValidDestination(target_dest)) {
        error = _("Gold Rush PoS signal target does not resolve to a wallet address.");
        return false;
    }

    CCoinControl coin_control;
    coin_control.destChange = target_dest;
    coin_control.m_allow_other_inputs = false;
    coin_control.m_avoid_address_reuse = false;
    signal_tx = CMutableTransaction();
    fee = 0;
    coins.clear();

    LOCK2(::cs_main, wallet.cs_wallet);
    const CBlockIndex* tip = wallet.chain().getTip();
    if (!tip) return false;
    const CCoinsViewCache& view = wallet.chain().getCoinsTip();
    if (GetActiveShadowSignalPayouts(view, tip).count(candidate.target)) {
        LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: candidate became active before build\n");
        return false;
    }
    if (!HasRecentShadowSolverActivity(view, tip, candidate.target, candidate.solve_height, candidate.solve_hash)) {
        LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: candidate solve marker missing before build\n");
        return false;
    }
    if (HasPendingShadowSignal(wallet)) {
        LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: pending signal appeared before build\n");
        return false;
    }

    const int64_t current_time = GetAdjustedTimeSeconds();
    const CFeeRate fee_rate = GetMinimumFeeRate(wallet, coin_control, current_time);
    const AutoShadowSignalFeeScan fee_scan =
        FindAutoShadowSignalFeeCandidates(wallet, candidate.target);
    for (const AutoShadowSignalFeeCandidate& output : fee_scan.candidates) {
        CMutableTransaction tx;
        tx.nVersion = CTransaction::CURRENT_VERSION;
        tx.nTime = current_time;
        static constexpr uint32_t MAX_SEQUENCE_NONFINAL = 0xfffffffe;
        tx.vin.emplace_back(output.outpoint, CScript(), MAX_SEQUENCE_NONFINAL);
        tx.vout.emplace_back(output.txout.nValue, candidate.target);
        tx.vout.emplace_back(0, CScript() << OP_RETURN << signal);

        const TxSize tx_size = CalculateMaximumSignedTxSize(CTransaction(tx), &wallet, &coin_control);
        if (tx_size.vsize <= 0) continue;
        const CAmount candidate_fee = std::max(GetMinFee(static_cast<size_t>(tx_size.vsize), static_cast<uint32_t>(current_time)), fee_rate.GetFee(static_cast<uint32_t>(tx_size.vsize)));
        const CAmount candidate_change = output.txout.nValue - candidate_fee;
        CTxOut change_out(candidate_change, candidate.target);
        if (!MoneyRange(candidate_change) || candidate_change <= 0 || IsDust(change_out, wallet.chain().relayDustFee())) continue;
        if (candidate_fee > wallet.m_default_max_tx_fee) {
            error = strprintf(_("Gold Rush PoS signal fee exceeds wallet max transaction fee (%s)."), FormatMoney(wallet.m_default_max_tx_fee));
            return false;
        }

        coins.emplace(output.outpoint, Coin(output.txout, output.confirmed_height,
                                            output.coinbase, output.coinstake,
                                            output.smart_time));

        tx.vout[0].nValue = candidate_change;
        signal_tx = std::move(tx);
        fee = candidate_fee;
        return true;
    }

    error = strprintf(
        _("No spendable non-dust UTXO found for the Gold Rush PoS signal address in the bounded wallet scan (%u transactions, %u outputs); retry will resume from the saved cursor."),
        static_cast<unsigned int>(fee_scan.transactions_scanned),
        static_cast<unsigned int>(fee_scan.outputs_scanned));
    return false;
}

QuantumRedelegationPolicy AutoRedelegationPolicyFromArgs()
{
    QuantumRedelegationPolicy policy;
    policy.trigger_multiplier = gArgs.GetIntArg("-qqredelegationtriggermultiplier", policy.trigger_multiplier);
    policy.max_patience_blocks = gArgs.GetIntArg("-qqredelegationmaxpatienceblocks", policy.max_patience_blocks);
    policy.min_trigger_blocks = gArgs.GetIntArg("-qqredelegationmintriggerblocks", policy.min_trigger_blocks);
    policy.rate_limit_blocks = gArgs.GetIntArg("-qqredelegationratelimitblocks", policy.rate_limit_blocks);
    policy.probation_blocks = gArgs.GetIntArg("-qqredelegationprobationblocks", policy.probation_blocks);
    policy.stampede_jitter_blocks = gArgs.GetIntArg("-qqredelegationjitterblocks", policy.stampede_jitter_blocks);
    policy.liveness_improvement_blocks = gArgs.GetIntArg("-qqredelegationlivenessimprovementblocks", policy.liveness_improvement_blocks);
    policy.top_liveness_candidates = gArgs.GetIntArg("-qqredelegationtopcandidates", policy.top_liveness_candidates);
    if (policy.trigger_multiplier <= 0) policy.trigger_multiplier = 1;
    if (policy.max_patience_blocks <= 0) policy.max_patience_blocks = 1;
    if (policy.min_trigger_blocks <= 0) policy.min_trigger_blocks = 1;
    if (policy.rate_limit_blocks < 0) policy.rate_limit_blocks = 0;
    if (policy.probation_blocks < 0) policy.probation_blocks = 0;
    if (policy.stampede_jitter_blocks < 0) policy.stampede_jitter_blocks = 0;
    if (policy.liveness_improvement_blocks <= 0) policy.liveness_improvement_blocks = 1;
    if (policy.top_liveness_candidates <= 0) policy.top_liveness_candidates = 1;
    return policy;
}

int WalletTxHeight(const CWallet& wallet, const CWalletTx& wtx, int current_height) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    const int depth = wallet.GetTxDepthInMainChain(wtx);
    if (depth <= 0 || current_height <= 0 || depth > current_height + 1) return 0;
    return current_height - depth + 1;
}

int64_t AutoRedelegationExpectedIntervalBlocks(CAmount delegation_amount, CAmount total_coldstake)
{
    if (delegation_amount <= 0 || total_coldstake <= 0) return 0;
    return std::max<int64_t>(1, (total_coldstake + delegation_amount - 1) / delegation_amount);
}

bool IsSafeDemurrageAttestationFeeOutput(const COutput& out, const Coin& coin, const Consensus::Params& consensus, int evaluation_height, int64_t evaluation_time, const CCoinsViewCache& view)
{
    if (!out.spendable || !out.safe || out.input_bytes < 0) return false;
    if (IsQuantumColdStakeScript(out.txout.scriptPubKey) || IsEUTXOScript(out.txout.scriptPubKey)) return false;
    if (!IsQuantumMigrationScript(out.txout.scriptPubKey)) {
        return !consensus.IsDemurrageActive(evaluation_height, evaluation_time);
    }

    const std::optional<Consensus::DemurrageAttestationState> latest_attestation =
        Consensus::LatestDemurrageAttestationStateForScript(view, out.txout.scriptPubKey);
    const Consensus::DemurrageEvaluation eval = Consensus::EvaluateDemurrage(
        coin, consensus, evaluation_height, evaluation_time,
        latest_attestation ? std::optional<int>{latest_attestation->height} : std::nullopt,
        latest_attestation ? std::optional<int>{static_cast<int>(latest_attestation->coverage_start_height)} : std::nullopt);
    return !eval.locked && eval.burned_value == 0;
}

bool GetCoinStakeInputPrincipal(const CCoinsViewCache& view, const COutPoint& outpoint, const Consensus::Params& consensus, int spend_height, int64_t spend_time, CAmount& principal)
{
    Coin coin;
    if (!view.GetCoin(outpoint, coin) || coin.IsSpent()) return false;
    if (!consensus.IsDemurrageActive(spend_height, spend_time)) {
        principal = coin.out.nValue;
        return principal > 0 && MoneyRange(principal);
    }

    const std::optional<Consensus::DemurrageAttestationState> latest_attestation =
        Consensus::LatestDemurrageAttestationStateForScript(view, coin.out.scriptPubKey);
    const Consensus::DemurrageEvaluation eval = Consensus::EvaluateDemurrage(
        coin, consensus, spend_height, spend_time,
        latest_attestation ? std::optional<int>{latest_attestation->height} : std::nullopt,
        latest_attestation ? std::optional<int>{static_cast<int>(latest_attestation->coverage_start_height)} : std::nullopt);
    if (eval.locked) return false;
    principal = eval.effective_value;
    return principal > 0 && MoneyRange(principal);
}

std::vector<COutPoint> SafeDemurrageAttestationFeeOutpoints(CWallet& wallet, const Consensus::Params& consensus, int evaluation_height, int64_t evaluation_time)
{
    std::vector<COutPoint> fee_outpoints;
    LOCK2(cs_main, wallet.cs_wallet);
    CoinFilterParams fee_filter;
    fee_filter.only_spendable = true;
    fee_filter.skip_locked = true;
    fee_filter.include_immature_coinbase = false;
    // The wallet's own choice of a fee input never takes the final stake reserve.
    fee_filter.avoid_final_stake_reserve = true;
    CCoinControl fee_scan_control;
    CoinsResult fee_outputs = AvailableCoins(wallet, &fee_scan_control, std::nullopt, fee_filter);
    std::vector<COutput> sorted_fee_outputs = fee_outputs.All();
    std::sort(sorted_fee_outputs.begin(), sorted_fee_outputs.end(), [](const COutput& a, const COutput& b) {
        if (a.txout.nValue != b.txout.nValue) return a.txout.nValue < b.txout.nValue;
        return a.outpoint < b.outpoint;
    });

    std::map<COutPoint, Coin> chain_coins;
    for (const COutput& out : sorted_fee_outputs) {
        chain_coins.emplace(out.outpoint, Coin{});
    }
    wallet.chain().findCoins(chain_coins);

    const CCoinsViewCache& view = wallet.chain().getCoinsTip();
    for (const COutput& out : sorted_fee_outputs) {
        const auto coin_it = chain_coins.find(out.outpoint);
        if (coin_it == chain_coins.end() || coin_it->second.IsSpent()) continue;
        if (!IsSafeDemurrageAttestationFeeOutput(out, coin_it->second, consensus, evaluation_height, evaluation_time, view)) continue;
        fee_outpoints.push_back(out.outpoint);
    }
    return fee_outpoints;
}

bool ValidateSelectedDemurrageAttestationFeeOutpoints(CWallet& wallet,
                                                      const CCoinControl& coin_control,
                                                      const Consensus::Params& consensus,
                                                      int evaluation_height,
                                                      int64_t evaluation_time,
                                                      bilingual_str& error)
{
    const std::vector<COutPoint> selected = coin_control.ListSelected();
    if (selected.empty()) {
        error = _("Unable to select a fee input for demurrage attestation");
        return false;
    }

    LOCK2(cs_main, wallet.cs_wallet);
    CoinFilterParams fee_filter;
    fee_filter.only_spendable = true;
    fee_filter.skip_locked = true;
    fee_filter.include_immature_coinbase = false;
    CCoinControl fee_scan_control;
    CoinsResult fee_outputs = AvailableCoins(wallet, &fee_scan_control, std::nullopt, fee_filter);

    std::set<COutPoint> selected_set(selected.begin(), selected.end());
    std::map<COutPoint, COutput> available_by_outpoint;
    for (const COutput& out : fee_outputs.All()) {
        if (selected_set.count(out.outpoint)) {
            available_by_outpoint.emplace(out.outpoint, out);
        }
    }

    std::map<COutPoint, Coin> chain_coins;
    for (const COutPoint& outpoint : selected) {
        chain_coins.emplace(outpoint, Coin{});
    }
    wallet.chain().findCoins(chain_coins);

    const CCoinsViewCache& view = wallet.chain().getCoinsTip();
    for (const COutPoint& outpoint : selected) {
        if (coin_control.IsExternalSelected(outpoint)) {
            error = _("External inputs cannot be used to fund a demurrage attestation");
            return false;
        }
        const auto output_it = available_by_outpoint.find(outpoint);
        const auto coin_it = chain_coins.find(outpoint);
        if (output_it == available_by_outpoint.end() || coin_it == chain_coins.end() || coin_it->second.IsSpent()) {
            error = _("Selected demurrage attestation fee input is unavailable, locked, or unsafe");
            return false;
        }
        if (!IsSafeDemurrageAttestationFeeOutput(output_it->second, coin_it->second, consensus, evaluation_height, evaluation_time, view)) {
            error = _("Selected demurrage attestation fee input would decay or is not safe");
            return false;
        }
    }
    return true;
}

} // namespace

namespace {
//! The comment the automatic path gives the attestation transactions it creates; no other transaction
//! carries it, so it tells what the automatic path may clean up.
constexpr const char* AUTO_DEMURRAGE_ATTEST_COMMENT{"Quantum Quasar demurrage auto-attestation"};
} // namespace

/** The attestations of this wallet's unconfirmed, not abandoned transactions. A retry record is erased when
 *  a block is disconnected, but the attestation transaction that block held is back in the wallet as
 *  unconfirmed (or, after a restart, was never confirmed): signing another one for the same key and state
 *  would only add churn, so the automatic path first looks here. */
std::vector<PendingWalletAttestation> PendingWalletDemurrageAttestations(const CWallet& wallet)
{
    AssertLockHeld(wallet.cs_wallet);
    std::vector<PendingWalletAttestation> pending;
    for (const auto& [txid, wtx] : wallet.mapWallet) {
        if (!wtx.isUnconfirmed() || !wtx.tx || wtx.tx->IsCoinBase()) continue;
        const auto comment = wtx.mapValue.find("comment");
        const bool automatic = comment != wtx.mapValue.end() && comment->second == AUTO_DEMURRAGE_ATTEST_COMMENT;
        for (const Consensus::DemurrageAttestation& attestation : Consensus::ExtractDemurrageAttestations(*wtx.tx)) {
            if (attestation.height < 0) continue; // not a well-formed payload
            PendingWalletAttestation entry;
            entry.key_hash = attestation.pubkey_hash;
            entry.previous_height = attestation.previous_height;
            entry.previous_time = attestation.previous_time;
            entry.previous_coverage_start_height = attestation.previous_coverage_start_height;
            entry.previous_source = attestation.previous_source;
            entry.target = attestation.target_outpoint;
            entry.txid = txid;
            entry.in_mempool = wtx.InMempool();
            entry.automatic = automatic;
            pending.push_back(std::move(entry));
        }
    }
    return pending;
}

bool PendingAttestationReferencesRecord(const PendingWalletAttestation& entry,
                                        const std::optional<Consensus::DemurrageAttestationRecord>& record)
{
    if (record.has_value() != entry.previous_height.has_value()) return false;
    if (record.has_value() != entry.previous_source.has_value()) return false;
    if (!record) return entry.previous_time == 0 && entry.previous_coverage_start_height == 0;
    // The complete referenced state, source included: equal coordinates on a competing history are a
    // different state, and the attestation protocol binds the source block, transaction and output.
    return record->state.height == *entry.previous_height && record->state.time == entry.previous_time &&
           record->state.coverage_start_height == entry.previous_coverage_start_height &&
           record->source_block_hash == entry.previous_source->block_hash &&
           record->source_txid == entry.previous_source->txid &&
           record->source_output_index == entry.previous_source->output_index;
}

/** The pending attestation, if any, that refreshes this key from this very state: the same logical action. */
const PendingWalletAttestation* FindPendingAttestationForState(const std::vector<PendingWalletAttestation>& pending,
                                                               const uint256& key_hash,
                                                               const std::optional<Consensus::DemurrageAttestationRecord>& record)
{
    for (const PendingWalletAttestation& entry : pending) {
        if (entry.key_hash != key_hash) continue;
        if (PendingAttestationReferencesRecord(entry, record)) return &entry;
    }
    return nullptr;
}

PendingAttestationUse ClassifyPendingAttestation(const CWallet& wallet, const CCoinsViewCache& view,
                                                 const Consensus::Params& consensus, int evaluation_height,
                                                 int64_t evaluation_time, const PendingWalletAttestation& entry,
                                                 const std::optional<Consensus::DemurrageAttestationRecord>& record)
{
    AssertLockHeld(wallet.cs_wallet);
    // The referenced state is no longer the key's current state: the mempool would refuse it as stale.
    if (!PendingAttestationReferencesRecord(entry, record)) return PendingAttestationUse::UNUSABLE;

    // The target must still be a live coin the key controls, and not locked by demurrage.
    Coin target;
    if (!view.GetCoin(entry.target, target) || target.IsSpent()) return PendingAttestationUse::UNUSABLE;
    const std::optional<uint256> controlling_key = Consensus::DemurrageControllingKeyHashForScript(target.out.scriptPubKey);
    if (!controlling_key || *controlling_key != entry.key_hash) return PendingAttestationUse::UNUSABLE;
    const Consensus::DemurrageEvaluation eval = Consensus::EvaluateDemurrage(
        target, consensus, evaluation_height, evaluation_time,
        record ? std::optional<int>{record->state.height} : std::nullopt,
        record ? std::optional<int>{static_cast<int>(record->state.coverage_start_height)} : std::nullopt);
    if (eval.locked) return PendingAttestationUse::UNUSABLE;

    // Every input must still exist: a coin of the chain, or an output of another unconfirmed, not
    // abandoned transaction of this wallet.
    const auto wtx_it = wallet.mapWallet.find(entry.txid);
    if (wtx_it == wallet.mapWallet.end() || !wtx_it->second.tx) return PendingAttestationUse::UNUSABLE;
    for (const CTxIn& txin : wtx_it->second.tx->vin) {
        Coin coin;
        if (view.GetCoin(txin.prevout, coin) && !coin.IsSpent()) continue;
        const auto parent = wallet.mapWallet.find(txin.prevout.hash);
        if (parent != wallet.mapWallet.end() && parent->second.isUnconfirmed() &&
            txin.prevout.n < parent->second.tx->vout.size()) {
            continue;
        }
        return PendingAttestationUse::UNUSABLE;
    }

    // Still usable, but the wallet cannot offer it to the network now.
    if (!wallet.GetBroadcastTransactions()) return PendingAttestationUse::TEMPORARILY_UNAVAILABLE;
    return PendingAttestationUse::REUSABLE;
}

KeyPendingDecision DecidePendingAttestationsForKey(const CWallet& wallet, const CCoinsViewCache& view,
                                                   const Consensus::Params& consensus, int evaluation_height,
                                                   int64_t evaluation_time, const CScript& key_script,
                                                   const std::vector<const PendingWalletAttestation*>& key_pending)
{
    AssertLockHeld(wallet.cs_wallet);
    KeyPendingDecision decision;
    // LatestDemurrageAttestationRecord answers "none" for a missing record and for a malformed one alike.
    // Only an authenticated absence may be matched against; on a malformed local state nothing is decided
    // from it, so nothing is abandoned and no reservation is released.
    const std::optional<uint256> key_hash = Consensus::DemurrageControllingKeyHashForScript(key_script);
    if (!key_hash || !Consensus::IsDemurrageStateSaneForScript(view, key_script)) {
        decision.local_state_invalid = true;
        decision.suppress_construction = true;
        return decision;
    }
    const std::optional<Consensus::DemurrageAttestationRecord> record =
        Consensus::LatestDemurrageAttestationRecord(view, *key_hash);
    std::vector<const PendingWalletAttestation*> unusable_automatic;
    const PendingWalletAttestation* resubmit{nullptr};
    bool usable_in_mempool{false};
    for (const PendingWalletAttestation* entry : key_pending) {
        // An entry that references another state is classified unusable by the same call.
        const PendingAttestationUse use = ClassifyPendingAttestation(
            wallet, view, consensus, evaluation_height, evaluation_time, *entry, record);
        if (use == PendingAttestationUse::UNUSABLE) {
            // Only a transaction the automatic path created is cleaned up, and never one the mempool holds.
            if (entry->automatic && !entry->in_mempool) unusable_automatic.push_back(entry);
            continue;
        }
        decision.suppress_construction = true;
        if (!decision.reported || (entry->in_mempool && !decision.reported->in_mempool)) {
            decision.reported = entry;
            decision.reported_use = use;
        }
        if (entry->in_mempool) {
            usable_in_mempool = true;
        } else if (use == PendingAttestationUse::REUSABLE && !resubmit) {
            resubmit = entry;
        }
    }
    if (resubmit && !usable_in_mempool) decision.to_resubmit.push_back(resubmit->txid);
    // Whether a candidate has an unconfirmed descendant anywhere in the wallet is decided at execution
    // (AbandonStaleAutomaticAttestations), across all keys.
    for (const PendingWalletAttestation* entry : unusable_automatic) decision.to_abandon.push_back(entry->txid);
    return decision;
}

size_t AbandonStaleAutomaticAttestations(CWallet& wallet, const std::set<uint256>& candidates)
{
    size_t abandoned{0};
    LOCK(wallet.cs_wallet);
    for (const uint256& txid : candidates) {
        // Abandoning a transaction abandons everything in the wallet that spends it, whatever key it
        // belongs to and whatever its local state. A candidate with any unconfirmed, not abandoned
        // descendant is left for a later pass.
        bool has_descendant{false};
        for (const auto& [other_txid, other] : wallet.mapWallet) {
            if (other_txid == txid || !other.tx || !other.isUnconfirmed()) continue;
            for (const CTxIn& txin : other.tx->vin) {
                if (txin.prevout.hash == txid) {
                    has_descendant = true;
                    break;
                }
            }
            if (has_descendant) break;
        }
        if (has_descendant) {
            wallet.WalletLogPrintf("Demurrage auto-attest: stale pending attestation %s kept for now: an unconfirmed transaction of this wallet spends it\n", txid.ToString());
            continue;
        }
        if (wallet.AbandonTransaction(txid)) {
            ++abandoned;
            wallet.WalletLogPrintf("Demurrage auto-attest: pending attestation %s can no longer confirm (its state, target or an input is gone); abandoned\n", txid.ToString());
        } else {
            wallet.WalletLogPrintf("Demurrage auto-attest: pending attestation %s could not be abandoned\n", txid.ToString());
        }
    }
    return abandoned;
}


std::vector<WalletShadowSolveReference> GetWalletShadowSolveReferences(const CWallet& wallet, int tip_height)
{
    AssertLockHeld(wallet.cs_wallet);
    return wallet.GetRecentShadowSolveReferences(tip_height, MAX_WALLET_SHADOW_SOLVE_REFERENCES);
}

bool CreateDemurrageAttestationTransaction(
    CWallet& wallet,
    const std::vector<unsigned char>& witness_program,
    const CCoinControl& coin_control,
    bool sign,
    DemurrageAttestationTxResult& result,
    bilingual_str& error,
    const std::optional<COutPoint>& preferred_target)
{
    result = {};
    result.witness_program = witness_program;

    const Consensus::Params& consensus = Params().GetConsensus();
    int evaluation_height{-1};
    int64_t evaluation_time{0};
    std::vector<unsigned char> public_key;
    CKeyingMaterial private_key;
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        const CBlockIndex* tip = wallet.chain().getTip();
        if (!tip) {
            error = _("Unable to build a demurrage attestation without an active chain tip");
            return false;
        }
        evaluation_height = tip->nHeight + 1;
        evaluation_time = tip->GetMedianTimePast();
        if (!consensus.IsDemurrageActive(evaluation_height, evaluation_time)) {
            error = _("Demurrage is not active for the next block");
            return false;
        }
        if (wallet.IsLocked()) {
            error = _("Wallet is locked");
            return false;
        }
        if (sign && wallet.m_wallet_unlock_staking_only) {
            error = _("Wallet is unlocked for staking only");
            return false;
        }
        bilingual_str key_error;
        if (!wallet.GetQuantumKey(witness_program, public_key, private_key, key_error)) {
            error = key_error;
            return false;
        }
    }

    std::vector<unsigned char> private_key_bytes(private_key.begin(), private_key.end());
    if (!private_key.empty()) memory_cleanse(private_key.data(), private_key.size());
    auto cleanse_private_key_bytes = [&]() {
        if (!private_key_bytes.empty()) memory_cleanse(private_key_bytes.data(), private_key_bytes.size());
    };

    COutPoint target_outpoint;
    std::optional<Consensus::DemurrageAttestationRecord> previous_record;
    std::optional<Consensus::DemurrageAttestationState> previous_state;
    {
        LOCK2(cs_main, wallet.cs_wallet);
        const CBlockIndex* tip = wallet.chain().getTip();
        if (!tip) {
            cleanse_private_key_bytes();
            error = _("Unable to build a demurrage attestation without an active chain tip");
            return false;
        }
        evaluation_height = tip->nHeight + 1;
        evaluation_time = tip->GetMedianTimePast();
        if (!consensus.IsDemurrageActive(evaluation_height, evaluation_time)) {
            cleanse_private_key_bytes();
            error = _("Demurrage is not active for the next block");
            return false;
        }

        const CScript target_script = GetScriptForDestination(WitnessUnknown{
            QUANTUM_MIGRATION_WITNESS_VERSION, witness_program});
        const uint256 controlling_key = Consensus::DemurragePubKeyHash(public_key);
        const CCoinsViewCache& coins_view = wallet.chain().getCoinsTip();
        previous_record = Consensus::LatestDemurrageAttestationRecord(coins_view, controlling_key);
        if (previous_record) previous_state = previous_record->state;
        CoinsResult available = AvailableCoinsListUnspent(wallet);
        std::vector<COutPoint> candidates;
        for (const COutput& out : available.All()) {
            if (out.txout.scriptPubKey == target_script) candidates.push_back(out.outpoint);
        }
        std::sort(candidates.begin(), candidates.end());
        // The target must be a coin of the confirmed chain view: the mempool refuses an attestation whose
        // target is not (demurrage-attestation-target-unconfirmed), so an unconfirmed output of the key
        // (trusted change, say) is never chosen. The caller's own candidate output is preferred.
        const auto usable_target = [&](const COutPoint& outpoint) {
            Coin target_coin;
            if (!coins_view.GetCoin(outpoint, target_coin) || target_coin.IsSpent()) return false;
            const Consensus::DemurrageEvaluation target_evaluation = Consensus::EvaluateDemurrage(
                target_coin, consensus, evaluation_height, evaluation_time,
                previous_state ? std::optional<int>{previous_state->height} : std::nullopt,
                previous_state ? std::optional<int>{static_cast<int>(previous_state->coverage_start_height)} : std::nullopt);
            return !target_evaluation.locked;
        };
        if (preferred_target && std::binary_search(candidates.begin(), candidates.end(), *preferred_target) &&
            usable_target(*preferred_target)) {
            target_outpoint = *preferred_target;
        } else {
            for (const COutPoint& outpoint : candidates) {
                if (!usable_target(outpoint)) continue;
                target_outpoint = outpoint;
                break;
            }
        }
        if (target_outpoint.IsNull()) {
            cleanse_private_key_bytes();
            error = _("Demurrage attestation requires a live wallet UTXO controlled by this quantum key");
            return false;
        }
    }

    if (previous_state &&
        evaluation_height - previous_state->height < consensus.DemurrageAutoAttestBlocks()) {
        cleanse_private_key_bytes();
        error = _("This quantum key was attested too recently");
        return false;
    }

    const std::vector<unsigned char> dummy_signature(ML_DSA::SIGNATURE_BYTES, 0);
    const COutPoint placeholder_anchor{};
    const CScript placeholder_script = Consensus::BuildDemurrageAttestationScript(
        placeholder_anchor, target_outpoint,
        previous_state ? std::optional<int>{previous_state->height} : std::nullopt,
        previous_state ? previous_state->time : 0,
        previous_state ? previous_state->coverage_start_height : 0,
        previous_record
            ? std::optional<Consensus::DemurrageAttestationSource>{
                  Consensus::DemurrageAttestationSource{
                      previous_record->source_block_hash,
                      previous_record->source_txid,
                      previous_record->source_output_index}}
            : std::nullopt,
        public_key, dummy_signature);

    constexpr int RANDOM_CHANGE_POSITION = -1;
    std::vector<CRecipient> placeholder_recipients;
    placeholder_recipients.push_back({placeholder_script, 0, /*subtract_fee=*/false});

    const auto ensure_existing_change = [&](CCoinControl& attempt) -> bool {
        if (IsValidDestination(attempt.destChange)) return true;
        std::vector<COutPoint> selected = attempt.ListSelected();
        std::sort(selected.begin(), selected.end());
        LOCK(wallet.cs_wallet);
        for (const COutPoint& outpoint : selected) {
            const CWalletTx* wtx = wallet.GetWalletTx(outpoint.hash);
            if (!wtx || outpoint.n >= wtx->tx->vout.size()) continue;
            CTxDestination fee_dest;
            if (!ExtractDestination(wtx->tx->vout[outpoint.n].scriptPubKey, fee_dest) ||
                !IsQuantumMigrationScript(wtx->tx->vout[outpoint.n].scriptPubKey) ||
                !wallet.GetQuantumKeyInfo(fee_dest).has_value()) {
                continue;
            }
            attempt.destChange = fee_dest;
            return true;
        }
        error = _("Demurrage attestation requires an existing wallet-owned direct quantum change address. Select a safe fee input from that address or configure -qqdemurragechangeaddress; no key or transaction was created.");
        return false;
    };

    std::vector<CCoinControl> attempts;
    if (coin_control.HasSelected()) {
        if (coin_control.IsSelected(target_outpoint)) {
            cleanse_private_key_bytes();
            error = _("Demurrage attestation target cannot also fund the attestation transaction");
            return false;
        }
        bilingual_str selected_error;
        if (!ValidateSelectedDemurrageAttestationFeeOutpoints(wallet, coin_control, consensus, evaluation_height, evaluation_time, selected_error)) {
            cleanse_private_key_bytes();
            error = selected_error;
            return false;
        }
        CCoinControl selected_attempt = coin_control;
        selected_attempt.m_allow_other_inputs = false;
        if (!ensure_existing_change(selected_attempt)) {
            cleanse_private_key_bytes();
            return false;
        }
        attempts.push_back(std::move(selected_attempt));
    } else {
        std::vector<COutPoint> safe_outpoints = SafeDemurrageAttestationFeeOutpoints(
            wallet, consensus, evaluation_height, evaluation_time);
        safe_outpoints.erase(std::remove(safe_outpoints.begin(), safe_outpoints.end(), target_outpoint),
                             safe_outpoints.end());
        if (safe_outpoints.empty()) {
            cleanse_private_key_bytes();
            error = _("Unable to select a safe non-decaying fee input for demurrage attestation");
            return false;
        }
        for (const COutPoint& outpoint : safe_outpoints) {
            CCoinControl attempt = coin_control;
            attempt.m_allow_other_inputs = false;
            attempt.Select(outpoint);
            if (!ensure_existing_change(attempt)) continue;
            attempts.push_back(std::move(attempt));
        }
        if (attempts.empty()) {
            cleanse_private_key_bytes();
            return false;
        }
        error.clear();
    }

    bilingual_str last_error;
    for (const CCoinControl& attempt_control : attempts) {
        auto planned = CreateTransaction(wallet, placeholder_recipients, RANDOM_CHANGE_POSITION, attempt_control, /*sign=*/false);
        if (!planned) {
            last_error = util::ErrorString(planned);
            continue;
        }
        if (planned->tx->vin.empty()) {
            last_error = _("Unable to select a fee input for demurrage attestation");
            continue;
        }

        const COutPoint replay_anchor = planned->tx->vin.front().prevout;
        if (std::any_of(planned->tx->vin.begin(), planned->tx->vin.end(), [&](const CTxIn& txin) {
                return txin.prevout == target_outpoint;
            })) {
            last_error = _("Demurrage attestation target cannot also fund the attestation transaction");
            continue;
        }
        const std::optional<int> previous_height = previous_state
            ? std::optional<int>{previous_state->height}
            : std::nullopt;
        const uint32_t previous_time = previous_state ? previous_state->time : 0;
        const uint32_t previous_coverage_start_height = previous_state ? previous_state->coverage_start_height : 0;
        const std::optional<Consensus::DemurrageAttestationSource> previous_source = previous_record
            ? std::optional<Consensus::DemurrageAttestationSource>{
                  Consensus::DemurrageAttestationSource{
                      previous_record->source_block_hash,
                      previous_record->source_txid,
                      previous_record->source_output_index}}
            : std::nullopt;
        const uint256 msg_hash = Consensus::DemurrageAttestationMessageHash(
            replay_anchor, target_outpoint, previous_height, previous_time,
            previous_coverage_start_height, previous_source, public_key,
            consensus.nQuantumSighashChainId);
        std::vector<unsigned char> signature;
        if (!ML_DSA::Sign(private_key_bytes, msg_hash.begin(), uint256::size(), signature)) {
            cleanse_private_key_bytes();
            error = _("Failed to sign demurrage attestation");
            return false;
        }

        const CScript attestation_script = Consensus::BuildDemurrageAttestationScript(
            replay_anchor, target_outpoint, previous_height, previous_time,
            previous_coverage_start_height, previous_source, public_key, signature);
        CCoinControl anchored_control = attempt_control;
        anchored_control.m_allow_other_inputs = false;
        for (const CTxIn& txin : planned->tx->vin) {
            anchored_control.Select(txin.prevout);
        }
        std::vector<CRecipient> recipients;
        recipients.push_back({attestation_script, 0, /*subtract_fee=*/false});
        auto res = CreateTransaction(wallet, recipients, RANDOM_CHANGE_POSITION, anchored_control, /*sign=*/sign);
        if (!res) {
            last_error = util::ErrorString(res);
            continue;
        }
        const CTransactionRef& tx = res->tx;
        if (tx->vin.empty() || tx->vin.front().prevout != replay_anchor) {
            last_error = _("Unable to preserve demurrage attestation replay anchor");
            continue;
        }
        const auto attestation_out = std::find_if(tx->vout.begin(), tx->vout.end(), [&](const CTxOut& txout) {
            return txout.nValue == 0 && txout.scriptPubKey == attestation_script;
        });
        if (attestation_out == tx->vout.end()) {
            last_error = _("Demurrage attestation transaction did not preserve attestation output");
            continue;
        }

        cleanse_private_key_bytes();
        result.tx = tx;
        result.public_key = std::move(public_key);
        result.replay_anchor = replay_anchor;
        result.target_outpoint = target_outpoint;
        result.attestation_vout = static_cast<int>(std::distance(tx->vout.begin(), attestation_out));
        result.fee = res->fee;
        return true;
    }

    cleanse_private_key_bytes();
    error = last_error.empty() ? _("Unable to select a fee input for demurrage attestation") : last_error;
    return false;
}

bool CreateQuantumColdStakeRedelegationTransaction(
    CWallet& wallet,
    const CTxDestination& source_dest,
    const std::vector<unsigned char>& target_staking_pubkey,
    const QuantumColdStakeRedelegationOptions& options,
    QuantumColdStakeRedelegationResult& result,
    bilingual_str& error)
{
    result = {};
    result.dry_run = options.dry_run;
    result.source_dest = source_dest;
    result.cap_enforced = options.enforce_pool_cap;
    std::optional<CTxDestination> created_owner_key;
    const auto fail_after_created_key = [&](const bilingual_str& failure) {
        if (created_owner_key) {
            error = Untranslated(strprintf(
                "Cold-stake redelegation failed after creating durable non-HD ML-DSA owner key %s. The key remains in this wallet even though no successful redelegation was reported. Back up the wallet now; an older backup cannot recover it. Original error: %s",
                EncodeDestination(*created_owner_key),
                failure.original));
        } else {
            error = failure;
        }
        return false;
    };

    if (!options.dry_run && !options.allow_new_quantum_key) {
        error = _("Broadcast redelegation creates a new non-HD ML-DSA owner key. Retry with allow_new_quantum_key=true only after authorizing that key creation, then back up the wallet. No key, transaction, or wallet metadata was created.");
        return false;
    }

    if (!IsValidDestination(source_dest) || !IsQuantumColdStakeDestination(source_dest)) {
        error = _("source_coldstake_address is not a Quantum Cold-Stake address");
        return false;
    }
    if (target_staking_pubkey.size() != ML_DSA::PUBLICKEY_BYTES) {
        error = strprintf(_("target_staking_pubkey must be exactly %u bytes"), ML_DSA::PUBLICKEY_BYTES);
        return false;
    }

    wallet.BlockUntilSyncedToCurrentChain();

    CCoinControl coin_control;
    coin_control.m_allow_other_inputs = false;
    coin_control.destChange = source_dest;
    if (options.fee_rate) {
        coin_control.m_feerate = options.fee_rate;
        coin_control.fOverrideFeeRate = true;
    }

    CAmount input_amount{0};
    unsigned int selected_inputs{0};
    uint256 source_staker_hash;
    uint256 source_owner_hash;
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        if (wallet.IsLocked()) {
            error = _("Wallet is locked");
            return false;
        }
        if (wallet.m_wallet_unlock_staking_only) {
            error = _("Wallet unlocked for staking only, unable to redelegate");
            return false;
        }

        const auto source_info = wallet.GetQuantumColdStakeDelegationInfo(source_dest);
        if (!source_info || !source_info->has_owner_key) {
            error = _("Wallet does not have the owner key for source_coldstake_address");
            return false;
        }
        const int spend_height = wallet.GetLastBlockHeight() + 1;
        if (source_info->tiered && source_info->unlock_height == 0) {
            error = _("Bonded cold-stake funds must be unbonded before redelegating");
            return false;
        }
        if (source_info->tiered && source_info->unlock_height > static_cast<uint32_t>(std::max(0, spend_height))) {
            error = strprintf(_("Cold-stake funds are unbonding and cannot be redelegated until block %u"), source_info->unlock_height);
            return false;
        }
        source_staker_hash = source_info->staker_pubkey_hash;
        source_owner_hash = source_info->owner_pubkey_hash;

        CoinFilterParams filter;
        filter.only_spendable = true;
        filter.skip_locked = true;
        filter.avoid_final_stake_reserve = options.avoid_final_stake_reserve;
        for (const COutput& out : AvailableCoins(wallet, &coin_control, std::nullopt, filter).All()) {
            CTxDestination dest;
            if (!ExtractDestination(out.txout.scriptPubKey, dest) || !(dest == source_dest) || !out.spendable) continue;
            coin_control.Select(out.outpoint);
            if (!MoneyRange(input_amount + out.txout.nValue)) {
                error = _("Unable to select source_coldstake_address amount");
                return false;
            }
            input_amount += out.txout.nValue;
            ++selected_inputs;
        }
    }
    if (selected_inputs == 0 || input_amount <= 0) {
        error = _("No spendable owner-controlled UTXOs found for source_coldstake_address");
        return false;
    }

    const uint256 target_staker_hash = node::QuantumPoolHashPubKey(target_staking_pubkey);
    {
        LOCK(cs_main);
        const CCoinsViewCache& view = wallet.chain().getCoinsTip();
        const node::QuantumPoolShareCalculator pool_shares{view};
        const node::QuantumPoolShare share = pool_shares.ComputeShare(target_staker_hash, node::GetQuantumPoolClaims(target_staker_hash));
        if (options.require_verified_operator && !share.operator_share.operator_commitment_verified) {
            error = _("Target Quantum cold-stake operator commitment is not verified in the local registry");
            return false;
        }

        CAmount projected_operator_value = share.operator_share.verified_value;
        if (source_staker_hash == target_staker_hash && projected_operator_value >= input_amount) {
            projected_operator_value -= input_amount;
        }
        if (!MoneyRange(projected_operator_value + input_amount)) {
            error = _("Unable to project redelegation pool totals");
            return false;
        }
        projected_operator_value += input_amount;
        const bool would_exceed_cap = node::WouldQuantumPoolExceedCap(share.total_coldstake, projected_operator_value, 0);
        const bool has_under_cap_alternative = would_exceed_cap && HasUnderCapRedelegationAlternative(pool_shares, source_staker_hash, target_staker_hash, input_amount);
        if (options.enforce_pool_cap && would_exceed_cap && has_under_cap_alternative) {
            error = _("Target Quantum cold-stake pool cap would be exceeded by this redelegation");
            return false;
        }
    }

    const std::string label = options.label.empty() ? "redelegated-coldstake" : options.label;
    CTxDestination target_dest;
    bool target_wallet_backed{false};
    if (options.dry_run) {
        target_dest = WitnessUnknown{
            QUANTUM_COLDSTAKE_WITNESS_VERSION,
            QuantumColdStakeProgramForKeyHashes(target_staker_hash, source_owner_hash)};
    } else {
        const std::string owner_label = label + " owner";
        auto owner_dest = wallet.GetNewQuantumDestination(owner_label);
        if (!owner_dest) {
            error = util::ErrorString(owner_dest);
            return false;
        }
        created_owner_key = *owner_dest;
        std::vector<unsigned char> owner_pubkey;
        {
            LOCK(wallet.cs_wallet);
            const auto owner_info = wallet.GetQuantumKeyInfo(*owner_dest);
            if (!owner_info) {
                return fail_after_created_key(_("New redelegation owner key is not confirmed stored in the wallet"));
            }
            owner_pubkey = owner_info->public_key;
        }
        auto target_dest_result = wallet.AddQuantumColdStakeDelegation(target_staking_pubkey, owner_pubkey, label, GetTime());
        if (!target_dest_result) {
            return fail_after_created_key(util::ErrorString(target_dest_result));
        }
        target_dest = *target_dest_result;
        target_wallet_backed = true;
    }

    std::vector<CRecipient> recipients;
    recipients.push_back({target_dest, input_amount, /*fSubtractFeeFromAmount=*/true});

    constexpr int RANDOM_CHANGE_POSITION = -1;
    auto res = CreateTransaction(wallet, recipients, RANDOM_CHANGE_POSITION, coin_control, /*sign=*/!options.dry_run);
    if (!res) {
        return fail_after_created_key(util::ErrorString(res));
    }
    const CTransactionRef& tx = res->tx;
    if (tx->vout.empty() || IsDust(tx->vout[0], wallet.chain().relayDustFee())) {
        return fail_after_created_key(_("Redelegation output would be dust after fees"));
    }
    if (tx->vout.size() != 1 || tx->vout[0].scriptPubKey != GetScriptForDestination(target_dest)) {
        return fail_after_created_key(_("Redelegation transaction unexpectedly produced change or a non-target output"));
    }

    const CAmount output_amount = tx->vout[0].nValue;
    {
        LOCK(cs_main);
        const CCoinsViewCache& view = wallet.chain().getCoinsTip();
        const node::QuantumPoolShareCalculator pool_shares{view};
        const node::QuantumPoolShare share = pool_shares.ComputeShare(target_staker_hash, node::GetQuantumPoolClaims(target_staker_hash));
        if (options.require_verified_operator && !share.operator_share.operator_commitment_verified) {
            return fail_after_created_key(_("Target Quantum cold-stake operator commitment is not verified in the local registry"));
        }
        if (share.total_coldstake < input_amount || !MoneyRange(share.total_coldstake - input_amount + output_amount)) {
            return fail_after_created_key(_("Unable to project post-redelegation pool totals"));
        }
        CAmount post_operator_value = share.operator_share.verified_value;
        if (source_staker_hash == target_staker_hash && post_operator_value >= input_amount) {
            post_operator_value -= input_amount;
        }
        if (!MoneyRange(post_operator_value + output_amount)) {
            return fail_after_created_key(_("Unable to project post-redelegation operator total"));
        }
        post_operator_value += output_amount;
        const CAmount post_total_coldstake = share.total_coldstake - input_amount + output_amount;
        const bool would_exceed_cap = node::WouldQuantumPoolExceedCap(post_total_coldstake, post_operator_value, 0);
        const bool cap_filter_unlocked = would_exceed_cap && !HasUnderCapRedelegationAlternative(pool_shares, source_staker_hash, target_staker_hash, output_amount);
        if (would_exceed_cap && options.enforce_pool_cap && !cap_filter_unlocked) {
            return fail_after_created_key(_("Target Quantum cold-stake pool cap would be exceeded by this redelegation"));
        }

        result.operator_commitment_verified = share.operator_share.operator_commitment_verified;
        result.post_total_coldstake = post_total_coldstake;
        result.post_operator_value = post_operator_value;
        result.post_share_bps = node::QuantumPoolShareBps(post_operator_value, post_total_coldstake);
        result.would_exceed_cap = would_exceed_cap;
        result.cap_filter_unlocked = cap_filter_unlocked;
    }

    result.target_dest = target_dest;
    result.target_wallet_backed = target_wallet_backed;
    result.input_amount = input_amount;
    result.output_amount = output_amount;
    result.fee = res->fee;
    result.vsize = static_cast<int>(GetVirtualTransactionSize(*tx, 0, 0));
    result.tx = tx;

    if (!options.dry_run) {
        if (options.avoid_final_stake_reserve && SpendsFinalStakeReserve(wallet, *tx)) {
            return fail_after_created_key(_("Redelegation would spend the final stake reserve"));
        }
        mapValue_t map_value;
        map_value["comment"] = "Quantum Quasar cold-stake redelegation";
        std::string broadcast_error;
        if (!wallet.CommitTransaction(tx, std::move(map_value), {}, &broadcast_error)) {
            if (!wallet.AbandonTransaction(tx->GetHash())) {
                wallet.WalletLogPrintf("Cold-stake redelegation could not be abandoned after broadcast failure: txid=%s\n", tx->GetHash().ToString());
            }
            return fail_after_created_key(strprintf(
                _("Broadcasting cold-stake redelegation failed: %s"),
                broadcast_error.empty() ? "transaction was not accepted into the mempool" : broadcast_error));
        }
    }
    return true;
}

int MaybeAutoDemurrageAttest(CWallet& wallet)
{
    if (!gArgs.GetBoolArg("-qqautodemurrageattest", DEFAULT_AUTO_DEMURRAGE_ATTEST)) return 0;

    {
        LOCK(wallet.cs_wallet);
        if (!wallet.m_enabled_staking.load() ||
            wallet.IsLocked() ||
            wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS) ||
            wallet.m_wallet_unlock_staking_only) {
            return 0;
        }
    }

    const Consensus::Params& consensus = Params().GetConsensus();
    int evaluation_height{-1};
    int64_t evaluation_time{0};
    uint256 evaluation_tip;
    {
        LOCK(cs_main);
        const CBlockIndex* tip = wallet.chain().getTip();
        if (!tip) return 0;
        evaluation_height = tip->nHeight + 1;
        evaluation_time = tip->GetMedianTimePast();
        evaluation_tip = tip->GetBlockHash();
    }
    if (!consensus.IsDemurrageActive(evaluation_height, evaluation_time)) {
        return 0;
    }

    {
        LOCK(wallet.cs_wallet);
        if (DecideAutoScan(wallet.m_demurrage_last_auto_attest_scan_height,
                           wallet.m_demurrage_last_auto_attest_scan_tip, evaluation_height, evaluation_tip,
                           wallet.m_demurrage_last_reorg_scan,
                           std::chrono::steady_clock::now()) != AutoScanVerdict::SCAN) {
            return 0;
        }
        wallet.m_demurrage_last_auto_attest_scan_height = evaluation_height;
        wallet.m_demurrage_last_auto_attest_scan_tip = evaluation_tip;
    }

    std::vector<AutoDemurrageAttestCandidate> candidates;
    std::vector<COutPoint> fee_outpoints;
    std::set<uint256> to_resubmit; // pending attestations of the wallet that are not in the mempool
    std::set<uint256> to_abandon;  // pending attestations of the automatic path that can no longer confirm
    std::set<COutPoint> pending_targets; // targets of the wallet's pending attestations
    {
        LOCK2(cs_main, wallet.cs_wallet);
        CoinsResult available_list = AvailableCoinsListUnspent(wallet);
        std::map<COutPoint, Coin> chain_coins;
        for (const COutput& out : available_list.All()) {
            chain_coins.emplace(out.outpoint, Coin{});
        }
        wallet.chain().findCoins(chain_coins);

        const CCoinsViewCache& view = wallet.chain().getCoinsTip();
        std::map<uint256, AutoDemurrageAttestCandidate> by_key;
        std::vector<PendingWalletAttestation> pending_attestations;
        bool pending_scanned{false};
        std::set<uint256> suppressed_keys;
        std::map<uint256, KeyPendingDecision> key_decisions;
        std::map<uint256, std::vector<const PendingWalletAttestation*>> pending_by_key;
        for (const COutput& out : available_list.All()) {
            if (!IsQuantumMigrationScript(out.txout.scriptPubKey)) continue;
            CTxDestination dest;
            if (!ExtractDestination(out.txout.scriptPubKey, dest)) continue;
            const auto key_info = wallet.GetQuantumKeyInfo(dest);
            if (!key_info) continue;

            const auto key_hash = Consensus::DemurrageControllingKeyHashForScript(out.txout.scriptPubKey);
            if (!key_hash) continue;

            const auto coin_it = chain_coins.find(out.outpoint);
            if (coin_it == chain_coins.end() || coin_it->second.IsSpent()) continue;

            const std::optional<Consensus::DemurrageAttestationState> latest_attestation =
                Consensus::LatestDemurrageAttestationStateForScript(view, out.txout.scriptPubKey);
            const Consensus::DemurrageEvaluation eval = Consensus::EvaluateDemurrage(
                coin_it->second, consensus, evaluation_height, evaluation_time,
                latest_attestation ? std::optional<int>{latest_attestation->height} : std::nullopt,
                latest_attestation ? std::optional<int>{static_cast<int>(latest_attestation->coverage_start_height)} : std::nullopt);
            if (eval.locked || eval.inactive_blocks < consensus.DemurrageAutoAttestBlocks()) continue;

            const int retry_blocks = std::max(1, consensus.DemurrageBlocksPerMonth() / 30);
            const auto last_attempt = wallet.m_demurrage_last_auto_attest_attempt_height.find(*key_hash);
            if (last_attempt != wallet.m_demurrage_last_auto_attest_attempt_height.end() &&
                evaluation_height - last_attempt->second < retry_blocks) {
                continue;
            }

            // An attestation for this key and state that the wallet already holds (made before a block
            // was disconnected, or before a restart): reuse it instead of signing another.
            if (!pending_scanned) {
                pending_attestations = PendingWalletDemurrageAttestations(wallet);
                // Indexed by key once, so that a wallet with many outputs and many pending transactions does a
                // lookup per key instead of walking the whole pending list for every output.
                // Considered in transaction id order, so that the choice among several usable entries does not
                // depend on the wallet's unordered map.
                std::sort(pending_attestations.begin(), pending_attestations.end(),
                          [](const PendingWalletAttestation& a, const PendingWalletAttestation& b) {
                              return a.txid < b.txid;
                          });
                for (const PendingWalletAttestation& entry : pending_attestations) {
                    pending_by_key[entry.key_hash].push_back(&entry);
                }
                pending_scanned = true;
            }
            auto decision_it = key_decisions.find(*key_hash);
            if (decision_it == key_decisions.end()) {
                // The key-level decision, once per scan: every pending entry for the key is examined, and any
                // usable one suppresses a new attestation.
                const auto key_pending_it = pending_by_key.find(*key_hash);
                const std::vector<const PendingWalletAttestation*> no_pending;
                decision_it = key_decisions.emplace(*key_hash, DecidePendingAttestationsForKey(
                    wallet, view, consensus, evaluation_height, evaluation_time, out.txout.scriptPubKey,
                    key_pending_it == pending_by_key.end() ? no_pending : key_pending_it->second)).first;
                to_resubmit.insert(decision_it->second.to_resubmit.begin(), decision_it->second.to_resubmit.end());
                to_abandon.insert(decision_it->second.to_abandon.begin(), decision_it->second.to_abandon.end());
            }
            const KeyPendingDecision& key_decision = decision_it->second;
            if (key_decision.local_state_invalid) {
                if (suppressed_keys.insert(*key_hash).second) {
                    wallet.WalletLogPrintf("Demurrage auto-attest suppressed for key %s: its local attestation state is invalid (not merely absent); pending attestations and their inputs are kept untouched until it is repaired\n",
                                           key_hash->ToString());
                }
                continue;
            }
            if (key_decision.suppress_construction) {
                if (suppressed_keys.insert(*key_hash).second) {
                    const PendingWalletAttestation& pending = *key_decision.reported;
                    wallet.WalletLogPrintf("Demurrage auto-attest suppressed for key %s: attestation %s for the same state is already pending in this wallet%s\n",
                                           key_hash->ToString(), pending.txid.ToString(),
                                           pending.in_mempool ? "" : (key_decision.reported_use == PendingAttestationUse::REUSABLE ? " (submitting it again)" : " (kept: it cannot be submitted now)"));
                }
                continue;
            }

            AutoDemurrageAttestCandidate candidate;
            candidate.witness_program = key_info->witness_program;
            candidate.key_hash = *key_hash;
            candidate.inactive_blocks = eval.inactive_blocks;
            candidate.outpoint = out.outpoint;
            candidate.state = latest_attestation;

            auto [it, inserted] = by_key.emplace(*key_hash, candidate);
            if (!inserted && candidate.inactive_blocks > it->second.inactive_blocks) {
                it->second = std::move(candidate);
            }
        }

        CoinFilterParams fee_filter;
        fee_filter.only_spendable = true;
        fee_filter.skip_locked = true;
        fee_filter.include_immature_coinbase = false;
        fee_filter.avoid_final_stake_reserve = true;
        CCoinControl fee_scan_control;
        CoinsResult fee_outputs = AvailableCoins(wallet, &fee_scan_control, std::nullopt, fee_filter);
        std::vector<COutput> sorted_fee_outputs = fee_outputs.All();
        std::sort(sorted_fee_outputs.begin(), sorted_fee_outputs.end(), [](const COutput& a, const COutput& b) {
            if (a.txout.nValue != b.txout.nValue) return a.txout.nValue < b.txout.nValue;
            return a.outpoint < b.outpoint;
        });
        for (const COutput& out : sorted_fee_outputs) {
            const auto coin_it = chain_coins.find(out.outpoint);
            if (coin_it == chain_coins.end() || coin_it->second.IsSpent()) continue;
            if (!IsSafeDemurrageAttestationFeeOutput(out, coin_it->second, consensus, evaluation_height, evaluation_time, view)) continue;
            fee_outpoints.push_back(out.outpoint);
        }

        for (auto& [key_hash, candidate] : by_key) {
            candidates.push_back(std::move(candidate));
        }
        for (const PendingWalletAttestation& entry : pending_attestations) {
            pending_targets.insert(entry.target);
        }
    }

    // Reuse: offer a pending attestation that the mempool does not hold again (after a restart that did not
    // keep the mempool, or a reorganisation). Outside the wallet and chain locks. A failed submission is not
    // evidence that it is unusable (broadcasting may be off, the mempool may refuse it for now, the node may
    // have failed locally): it is kept and offered again on a later scan.
    for (const uint256& txid : to_resubmit) {
        std::string submit_error;
        if (!wallet.SubmitTxMemoryPoolAndRelay(txid, submit_error, /*relay=*/true)) {
            wallet.WalletLogPrintf("Demurrage auto-attest: pending attestation %s was not accepted again (%s); keeping it\n",
                                   txid.ToString(), submit_error.empty() ? "not submitted" : submit_error);
        }
    }
    // Clean up: a transaction of the automatic path whose referenced state, target or inputs are gone cannot
    // confirm and would otherwise keep its inputs reserved.
    AbandonStaleAutomaticAttestations(wallet, to_abandon);

    CCoinControl automatic_change_control;
    if (!candidates.empty()) {
        bilingual_str change_error;
        if (!wallet.PrepareAutomaticDemurrageChangeAddress(automatic_change_control, change_error)) {
            wallet.WalletLogPrintf("Demurrage auto-attest skipped: %s\n", change_error.original);
            return 0;
        }
    }

    const AutoDemurrageAttestAttemptFn attempt = [&](const AutoDemurrageAttestCandidate& candidate, const COutPoint& fee_outpoint) {
        AutoDemurrageAttestAttempt result;
        CCoinControl coin_control = automatic_change_control;
        coin_control.m_allow_other_inputs = false;
        coin_control.m_avoid_address_reuse = false;
        coin_control.Select(fee_outpoint);

        DemurrageAttestationTxResult tx_result;
        bilingual_str error;
        if (!CreateDemurrageAttestationTransaction(wallet, candidate.witness_program, coin_control, /*sign=*/true, tx_result, error, candidate.outpoint)) {
            result.error = error.original;
            return result;
        }
        // The recheck before the commit: the attestation's fee input must not be in the final stake reserve.
        if (SpendsFinalStakeReserve(wallet, *tx_result.tx)) {
            result.error = "the fee input is in the final stake reserve";
            return result;
        }

        mapValue_t map_value;
        map_value["comment"] = AUTO_DEMURRAGE_ATTEST_COMMENT;
        std::string broadcast_error;
        if (!wallet.CommitTransaction(tx_result.tx, std::move(map_value), {}, &broadcast_error)) {
            if (!wallet.AbandonTransaction(tx_result.tx->GetHash())) {
                wallet.WalletLogPrintf("Demurrage auto-attestation could not be abandoned after broadcast failure: txid=%s\n", tx_result.tx->GetHash().ToString());
            }
            result.reject_reason = broadcast_error;
            result.error = strprintf("broadcast failed: %s", broadcast_error.empty() ? "transaction was not accepted into the mempool" : broadcast_error);
            return result;
        }
        wallet.WalletLogPrintf("Demurrage auto-attested demurrage key %s at height %d with tx %s (inactive %d blocks, fee %d)\n",
                               candidate.key_hash.ToString(), evaluation_height, tx_result.tx->GetHash().ToString(), candidate.inactive_blocks, tx_result.fee);
        result.success = true;
        result.target = tx_result.target_outpoint;
        return result;
    };
    return RunAutoDemurrageAttestAttempts(wallet, std::move(candidates), fee_outpoints, std::move(pending_targets),
                                          evaluation_height, attempt).submitted;
}

bool IsTerminalAutoAttestRejection(const std::string& reject_reason, bool fee_input_is_pending_target)
{
    static constexpr std::array<std::string_view, 4> TERMINAL_REJECTS{
        "demurrage-attestation-target-unconfirmed",
        "stale-demurrage-attestation-state",
        "demurrage-attestation-target-locked",
        "demurrage-attestation-too-soon",
    };
    static constexpr std::string_view TARGET_CONFLICT{"demurrage-attestation-target-conflict"};
    const auto starts_with = [&](std::string_view reason) { return reject_reason.compare(0, reason.size(), reason) == 0; };
    if (std::any_of(TERMINAL_REJECTS.begin(), TERMINAL_REJECTS.end(), starts_with)) return true;
    // The mempool also uses the conflict reason when the fee input is a pending attestation's target; another
    // fee input cures that one.
    return starts_with(TARGET_CONFLICT) && !fee_input_is_pending_target;
}

AutoDemurrageAttestPassStats RunAutoDemurrageAttestAttempts(CWallet& wallet,
                                                            std::vector<AutoDemurrageAttestCandidate> candidates,
                                                            const std::vector<COutPoint>& fee_outpoints,
                                                            std::set<COutPoint> pending_targets,
                                                            int evaluation_height,
                                                            const AutoDemurrageAttestAttemptFn& attempt)
{
    AutoDemurrageAttestPassStats stats;
    {
        // Least recently attempted first. Keys the pass could not reach are not stamped, so they come first in
        // the next pass, and the keys visited (which failed or were given up on) go behind them. Memory only:
        // the stamps are the existing attempt heights.
        LOCK(wallet.cs_wallet);
        std::vector<std::pair<int, AutoDemurrageAttestCandidate>> ordered;
        ordered.reserve(candidates.size());
        for (AutoDemurrageAttestCandidate& candidate : candidates) {
            const auto stamp = wallet.m_demurrage_last_auto_attest_attempt_height.find(candidate.key_hash);
            const int last = stamp == wallet.m_demurrage_last_auto_attest_attempt_height.end() ? std::numeric_limits<int>::min() : stamp->second;
            ordered.emplace_back(last, std::move(candidate));
        }
        std::stable_sort(ordered.begin(), ordered.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
        candidates.clear();
        for (auto& entry : ordered) candidates.push_back(std::move(entry.second));
    }

    bool logged_no_fee{false};
    bool budget_exhausted{false};
    std::set<COutPoint> used_fee_outpoints;
    for (size_t index = 0; index < candidates.size(); ++index) {
        const AutoDemurrageAttestCandidate& candidate = candidates[index];
        if (stats.submitted >= static_cast<int>(Consensus::MAX_DEMURRAGE_ATTESTATIONS_PER_BLOCK)) {
            wallet.WalletLogPrintf("Demurrage auto-attest deferred %u additional key(s) to a later block to respect the consensus attestation cap\n",
                                   static_cast<unsigned int>(candidates.size() - index));
            stats.deferred_keys = candidates.size() - index;
            break;
        }
        if (stats.failed >= MAX_AUTO_DEMURRAGE_ATTEST_FAILED_ATTEMPTS_PER_PASS) {
            budget_exhausted = true;
            stats.deferred_keys = candidates.size() - index;
            break;
        }
        {
            LOCK(wallet.cs_wallet);
            wallet.m_demurrage_last_auto_attest_attempt_height[candidate.key_hash] = evaluation_height;
        }
        stats.visited.push_back(candidate.key_hash);

        bool committed{false};
        bool terminal{false};
        std::string last_error;
        for (const COutPoint& fee_outpoint : fee_outpoints) {
            if (used_fee_outpoints.count(fee_outpoint)) continue;
            if (stats.failed >= MAX_AUTO_DEMURRAGE_ATTEST_FAILED_ATTEMPTS_PER_PASS) {
                budget_exhausted = true;
                break;
            }

            ++stats.attempts;
            const AutoDemurrageAttestAttempt result = attempt(candidate, fee_outpoint);
            if (!result.success) {
                ++stats.failed;
                last_error = result.error;
                // The failed attempt has already been cleaned up by `attempt`; a rejection that no other fee
                // input can cure ends the key's turn.
                if (IsTerminalAutoAttestRejection(result.reject_reason, pending_targets.count(fee_outpoint) > 0)) {
                    terminal = true;
                    ++stats.terminal_keys;
                    break;
                }
                continue;
            }
            used_fee_outpoints.insert(fee_outpoint);
            pending_targets.insert(result.target);
            ++stats.submitted;
            committed = true;
            break;
        }

        if (!committed) {
            if (fee_outpoints.empty() && !logged_no_fee) {
                wallet.WalletLogPrintf("Demurrage auto-attest skipped: no safe spendable fee input is available\n");
                logged_no_fee = true;
            } else if (!last_error.empty()) {
                wallet.WalletLogPrintf("Demurrage auto-attest skipped for key %s%s: %s\n", candidate.key_hash.ToString(),
                                       terminal ? " (no other fee input can cure it)" : "", last_error);
            }
        }
        if (budget_exhausted) {
            stats.deferred_keys = candidates.size() - index - 1;
            break;
        }
    }
    if (budget_exhausted) {
        wallet.WalletLogPrintf("Demurrage auto-attest stopped after %d failed attempt(s) in one pass; %u key(s) not reached are tried first in the next pass\n",
                               stats.failed, static_cast<unsigned int>(stats.deferred_keys));
    }
    if (stats.attempts > 0) {
        wallet.WalletLogPrintf("Demurrage auto-attest pass: attempts=%d submitted=%d failed=%d terminal_keys=%d deferred_keys=%u\n",
                               stats.attempts, stats.submitted, stats.failed, stats.terminal_keys,
                               static_cast<unsigned int>(stats.deferred_keys));
    }
    return stats;
}

int MaybeAutoShadowSignal(CWallet& wallet)
{
    // Cheap when the return address is already set: the legacy-stake quantum return
    // must exist before the window opens, so it is kept ready whenever the wallet
    // is fully unlocked (never creating a key the policy forbids).
    MaybeAutoSetQuantumStakeReturn(wallet);
    ScopedDisallowShadowSolverActivityFullScan no_full_solver_scan;
    if (!gArgs.GetBoolArg("-qqautoshadowsignal", DEFAULT_AUTO_SHADOW_SIGNAL)) return 0;
    if (!wallet.m_enabled_staking.load() || wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)) {
        return 0;
    }

    AutoShadowSignalAttemptGuard attempt(wallet);
    if (!attempt || wallet.IsStakeClosing()) return 0;

    if (Params().IsTestChain()) {
        const int64_t delay_ms = std::clamp<int64_t>(
            gArgs.GetIntArg("-qqshadowsignalsubmissiondelaymillis", 0), 0, 10000);
        if (delay_ms > 0) {
            wallet.WalletLogPrintf("Gold Rush PoS auto-signal test barrier reached; delaying %dms\n", delay_ms);
            const auto deadline = SteadyClock::now() + std::chrono::milliseconds{delay_ms};
            while (SteadyClock::now() < deadline) {
                if (wallet.IsStakeClosing()) return 0;
                std::this_thread::sleep_for(std::min(
                    std::chrono::milliseconds{25},
                    std::chrono::duration_cast<std::chrono::milliseconds>(deadline - SteadyClock::now())));
            }
        }
    }

    std::string pending_retry_reason;
    const PendingShadowSignalState pending_state = ReconcilePendingShadowSignals(wallet, pending_retry_reason);
    if (pending_state == PendingShadowSignalState::LIVE) {
        ResetAutoShadowSignalBackoff(wallet);
        return 0;
    }
    if (pending_state == PendingShadowSignalState::RETRY) {
        ScheduleAutoShadowSignalRetry(wallet, /*scan_height=*/-1, pending_retry_reason);
        return 0;
    }

    // Respect a non-broadcasting wallet after cleaning any terminal or
    // retry-exhausted signal above. Creating another signed transaction here
    // would immediately reserve a fresh input with no path to the mempool.
    if (!wallet.GetBroadcastTransactions()) {
        ResetAutoShadowSignalBackoff(wallet);
        return 0;
    }

    if (wallet.IsLocked() || wallet.m_wallet_unlock_staking_only) {
        LogPrint(BCLog::COINSTAKE, "Gold Rush PoS auto-signal: normal wallet unlock required (locked=%d staking_only=%d)\n",
                 wallet.IsLocked(), wallet.m_wallet_unlock_staking_only);
        return 0;
    }

    AutoShadowSignalCandidate candidate;
    if (!FindAutoShadowSignalCandidate(wallet, candidate)) {
        ResetAutoShadowSignalBackoff(wallet);
        return 0;
    }

    if (wallet.IsStakeClosing()) return 0;

    CScript payout_script;
    std::string payout_address;
    bilingual_str error;
    if (!wallet.EnsureShadowSignalPayoutAddress(payout_script, payout_address, error)) {
        wallet.WalletLogPrintf("Gold Rush PoS signal skipped: %s\n", error.original);
        ScheduleAutoShadowSignalRetry(wallet, candidate.scan_height, error.original);
        return 0;
    }

    if (wallet.IsStakeClosing()) return 0;

    CMutableTransaction signal_tx;
    std::map<COutPoint, Coin> coins;
    CAmount fee{0};
    if (!BuildAutoShadowSignalTransaction(wallet, candidate, payout_script, signal_tx, coins, fee, error)) {
        if (!error.empty()) {
            wallet.WalletLogPrintf("Gold Rush PoS signal skipped: %s\n", error.original);
        }
        ScheduleAutoShadowSignalRetry(wallet, candidate.scan_height,
                                      error.empty() ? "candidate changed during transaction construction" : error.original);
        return 0;
    }

    if (wallet.IsStakeClosing()) return 0;

    std::map<int, bilingual_str> input_errors;
    if (!wallet.SignTransaction(signal_tx, coins, SIGHASH_DEFAULT, input_errors)) {
        if (!input_errors.empty()) {
            error = strprintf(_("Signing Gold Rush PoS signal failed: %s"), input_errors.begin()->second.original);
        } else {
            error = _("Signing Gold Rush PoS signal failed.");
        }
        wallet.WalletLogPrintf("%s\n", error.original);
        ScheduleAutoShadowSignalRetry(wallet, candidate.scan_height, error.original);
        return 0;
    }

    if (wallet.IsStakeClosing()) return 0;

    CTransactionRef tx = MakeTransactionRef(std::move(signal_tx));
    {
        ChainstateManager& chainman = wallet.chain().chainman();
        LOCK(::cs_main);
        const MempoolAcceptResult accept = chainman.ProcessTransaction(tx, /*test_accept=*/true);
        if (accept.m_result_type != MempoolAcceptResult::ResultType::VALID) {
            wallet.WalletLogPrintf("Gold Rush PoS signal rejected: %s\n", accept.m_state.ToString());
            ScheduleAutoShadowSignalRetry(wallet, candidate.scan_height, accept.m_state.ToString());
            return 0;
        }
    }

    if (wallet.IsStakeClosing()) return 0;

    mapValue_t map_value;
    map_value["comment"] = SHADOW_SIGNAL_COMMENT;
    map_value["qq_shadow_signal_source"] = "automatic";
    try {
        std::string broadcast_error;
        if (!wallet.CommitTransaction(tx, std::move(map_value), {}, &broadcast_error)) {
            wallet.WalletLogPrintf("Broadcasting Gold Rush PoS signal failed: %s\n", broadcast_error.empty() ? "transaction was not accepted into the mempool" : broadcast_error);
            // This is automatic cleanup, not a user abandon request. Avoid
            // recording manual provenance so an identical safe retry may
            // reopen the persisted transaction after a restart.
            if (!wallet.AbandonTransaction(tx->GetHash(), /*automatic_shadow_stale=*/true)) {
                wallet.WalletLogPrintf("Gold Rush PoS signal could not be abandoned after broadcast failure: txid=%s\n", tx->GetHash().ToString());
            }
            ScheduleAutoShadowSignalRetry(wallet, candidate.scan_height,
                                          broadcast_error.empty() ? "transaction was not accepted into the mempool" : broadcast_error);
            return 0;
        }
    } catch (const std::exception& e) {
        wallet.WalletLogPrintf("Broadcasting Gold Rush PoS signal failed: %s\n", e.what());
        const bool added_to_wallet = WITH_LOCK(wallet.cs_wallet, return wallet.GetWalletTx(tx->GetHash()) != nullptr);
        if (added_to_wallet && !wallet.AbandonTransaction(tx->GetHash(), /*automatic_shadow_stale=*/true)) {
            wallet.WalletLogPrintf("Gold Rush PoS signal could not be abandoned after broadcast exception: txid=%s\n",
                                   tx->GetHash().ToString());
        }
        ScheduleAutoShadowSignalRetry(wallet, candidate.scan_height, e.what());
        return 0;
    }

    CTxDestination signal_dest;
    std::string signal_address;
    if (ExtractDestination(candidate.target, signal_dest) && IsValidDestination(signal_dest)) {
        signal_address = EncodeDestination(signal_dest);
    } else {
        signal_address = HexStr(candidate.target);
    }
    wallet.WalletLogPrintf("Gold Rush PoS signal submitted: txid=%s address=%s solve_height=%u payout=%s fee=%s\n",
                           tx->GetHash().ToString(), signal_address, candidate.solve_height, payout_address, FormatMoney(fee));
    ResetAutoShadowSignalBackoff(wallet);
    return 1;
}

int MaybeAutoRedelegateQuantumColdStake(CWallet& wallet)
{
    if (!gArgs.GetBoolArg("-qqautoredelegate", DEFAULT_AUTO_REDELEGATE)) return 0;
    if (!gArgs.GetBoolArg("-qqallowautokeycreation", DEFAULT_ALLOW_AUTO_QUANTUM_KEY_CREATION)) {
        wallet.WalletLogPrintf("Automatic Quantum cold-stake redelegation is disabled because explicit -qqallowautokeycreation=1 consent is absent. Disable -qqautoredelegate or restart with both options enabled and back up every new non-HD key.\n");
        return 0;
    }
    if (wallet.IsLocked() || wallet.m_wallet_unlock_staking_only || wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)) {
        return 0;
    }

    int current_height{0};
    uint256 current_tip;
    {
        LOCK(cs_main);
        const CBlockIndex* tip = wallet.chain().getTip();
        if (!tip) return 0;
        current_height = tip->nHeight;
        current_tip = tip->GetBlockHash();
    }

    {
        LOCK(wallet.cs_wallet);
        if (DecideAutoScan(wallet.m_redelegation_last_auto_scan_height,
                           wallet.m_redelegation_last_auto_scan_tip, current_height, current_tip,
                           wallet.m_redelegation_last_reorg_scan,
                           std::chrono::steady_clock::now()) != AutoScanVerdict::SCAN) {
            return 0;
        }
        wallet.m_redelegation_last_auto_scan_height = current_height;
        wallet.m_redelegation_last_auto_scan_tip = current_tip;
        WalletBatch batch(wallet.GetDatabase());
        batch.WriteQuantumRedelegationAutoScanHeight(current_height);
        batch.WriteQuantumRedelegationAutoScanTip(current_height, current_tip);
    }

    std::vector<AutoRedelegationSource> sources;
    {
        LOCK2(cs_main, wallet.cs_wallet);
        CoinFilterParams filter;
        filter.only_spendable = true;
        filter.skip_locked = true;
        filter.include_immature_coinbase = false;
        filter.avoid_final_stake_reserve = true;
        CCoinControl coin_control;
        const CoinsResult available = AvailableCoins(wallet, &coin_control, std::nullopt, filter);
        std::map<std::vector<unsigned char>, AutoRedelegationSource> grouped;
        for (const COutput& out : available.All()) {
            if (!IsQuantumColdStakeScript(out.txout.scriptPubKey) || !out.spendable || !out.safe || out.input_bytes < 0) continue;
            CTxDestination dest;
            if (!ExtractDestination(out.txout.scriptPubKey, dest)) continue;
            const auto info = wallet.GetQuantumColdStakeDelegationInfo(dest);
            if (!info || !info->has_owner_key) continue;
            const CWalletTx* wtx = wallet.GetWalletTx(out.outpoint.hash);
            if (!wtx) continue;
            const int height = WalletTxHeight(wallet, *wtx, current_height);
            if (height <= 0) continue;

            AutoRedelegationSource& source = grouped[info->witness_program];
            if (source.witness_program.empty()) {
                source.source_dest = dest;
                source.witness_program = info->witness_program;
                source.staker_pubkey_hash = info->staker_pubkey_hash;
                source.activation_height = height;
            } else {
                source.activation_height = std::max(source.activation_height, height);
            }
            if (!MoneyRange(source.amount + out.txout.nValue)) continue;
            source.amount += out.txout.nValue;
        }
        for (auto& [_, source] : grouped) {
            if (source.amount > 0 && source.activation_height > 0) {
                const auto win = wallet.m_redelegation_last_win_height.find(source.witness_program);
                if (win != wallet.m_redelegation_last_win_height.end()) {
                    source.last_win_height = win->second;
                }
                sources.push_back(std::move(source));
            }
        }
    }

    const QuantumRedelegationPolicy policy = AutoRedelegationPolicyFromArgs();
    std::map<uint256, int> operator_last_win_height;
    {
        LOCK(wallet.cs_wallet);
        for (const QuantumColdStakeDelegationInfo& info : wallet.ListQuantumColdStakeDelegationInfos()) {
            const auto win = wallet.m_redelegation_last_win_height.find(info.witness_program);
            if (win == wallet.m_redelegation_last_win_height.end()) continue;
            auto& height = operator_last_win_height[info.staker_pubkey_hash];
            height = std::max(height, win->second);
        }
    }

    for (const AutoRedelegationSource& source : sources) {
        int last_attempt_height{0};
        int last_success_height{0};
        {
            LOCK(wallet.cs_wallet);
            const auto it = wallet.m_redelegation_last_auto_attempt_height.find(source.witness_program);
            if (it != wallet.m_redelegation_last_auto_attempt_height.end()) {
                last_attempt_height = it->second;
            }
            const auto success_it = wallet.m_redelegation_last_auto_success_height.find(source.witness_program);
            if (success_it != wallet.m_redelegation_last_auto_success_height.end()) {
                last_success_height = success_it->second;
            }
        }

        std::vector<QuantumRedelegationCandidate> candidates;
        CAmount total_coldstake{0};
        {
            LOCK(cs_main);
            const CCoinsViewCache& view = wallet.chain().getCoinsTip();
            const node::QuantumPoolShareCalculator pool_shares{view};
            const node::QuantumPoolShare current_share = pool_shares.ComputeShare(source.staker_pubkey_hash, node::GetQuantumPoolClaims(source.staker_pubkey_hash));
            total_coldstake = current_share.total_coldstake;
            for (const uint256& staker_hash : node::ListQuantumPoolOperators()) {
                const node::QuantumPoolShare share = pool_shares.ComputeShare(staker_hash, node::GetQuantumPoolClaims(staker_hash));
                QuantumRedelegationCandidate candidate;
                candidate.staker_pubkey_hash = staker_hash;
                candidate.staker_pubkey = share.operator_share.staker_pubkey;
                candidate.operator_value = share.operator_share.verified_value;
                candidate.total_coldstake = share.total_coldstake;
                const auto win = operator_last_win_height.find(staker_hash);
                candidate.last_win_height = win == operator_last_win_height.end() ? 0 : win->second;
                candidate.operator_commitment_verified = share.operator_share.operator_commitment_verified;
                candidate.current_operator = staker_hash == source.staker_pubkey_hash;
                candidates.push_back(std::move(candidate));
            }
        }
        const int64_t expected_interval_blocks = AutoRedelegationExpectedIntervalBlocks(source.amount, total_coldstake);
        if (expected_interval_blocks <= 0) continue;

        HashWriter delegation_id_writer{};
        delegation_id_writer << std::string{"Blackcoin auto delegation id"};
        delegation_id_writer << source.witness_program;
        const uint256 delegation_id = delegation_id_writer.GetHash();

        const int last_win_height = source.last_win_height > 0 ? source.last_win_height : source.activation_height;
        const int64_t zero_win_blocks = std::max<int64_t>(0, current_height - last_win_height);
        const QuantumRedelegationStatus status = EvaluateQuantumRedelegation(
            zero_win_blocks,
            expected_interval_blocks,
            current_height,
            last_attempt_height,
            last_success_height,
            source.activation_height,
            delegation_id,
            source.staker_pubkey_hash,
            policy);
        if (!status.should_redelegate) continue;

        const auto ranked = RankQuantumRedelegationCandidates(candidates, source.amount, policy);
        const auto selected = SelectQuantumRedelegationTarget(ranked, source.last_win_height, delegation_id, policy);
        if (!selected) continue;

        {
            LOCK(wallet.cs_wallet);
            wallet.m_redelegation_last_auto_attempt_height[source.witness_program] = current_height;
            WalletBatch batch(wallet.GetDatabase());
            batch.WriteQuantumRedelegationLastAttemptHeight(source.witness_program, current_height);
        }

        QuantumColdStakeRedelegationOptions options;
        options.dry_run = false;
        options.allow_new_quantum_key = gArgs.GetBoolArg("-qqallowautokeycreation", DEFAULT_ALLOW_AUTO_QUANTUM_KEY_CREATION);
        options.enforce_pool_cap = true;
        options.require_verified_operator = true;
        options.avoid_final_stake_reserve = true;
        options.label = "auto-redelegated-coldstake";

        QuantumColdStakeRedelegationResult redelegation;
        bilingual_str error;
        if (!CreateQuantumColdStakeRedelegationTransaction(wallet, source.source_dest, selected->candidate.staker_pubkey, options, redelegation, error)) {
            wallet.WalletLogPrintf("Auto-redelegation skipped for %s at height %d: %s\n",
                                   EncodeDestination(source.source_dest), current_height, error.original);
            continue;
        }
        {
            LOCK(wallet.cs_wallet);
            wallet.m_redelegation_last_auto_success_height[source.witness_program] = current_height;
            WalletBatch batch(wallet.GetDatabase());
            batch.WriteQuantumRedelegationLastSuccessHeight(source.witness_program, current_height);
        }

        wallet.WalletLogPrintf("Auto-redelegated %s to %s at height %d with tx %s after %d zero-win blocks\n",
                               EncodeDestination(source.source_dest),
                               EncodeDestination(redelegation.target_dest),
                               current_height,
                               redelegation.tx->GetHash().ToString(),
                               zero_win_blocks);
        return 1;
    }
    return 0;
}

void StakeCoins(CWallet& wallet, bool fStake) {
    node::StakeCoins(fStake, &wallet, wallet.threadStakeMinerGroup);
}

void StartStake(CWallet& wallet) {
    LOCK(wallet.m_staking_thread_mutex);
    if (wallet.threadStakeMinerGroup && !wallet.threadStakeMinerGroup->empty()) {
        // Concurrent/repeated enable requests must not join or replace the
        // running thread. The worker is self-restarting until StopStake sets
        // the closing flag.
        wallet.SetStakingEnabled(true);
        return;
    }
    if (wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)) {
        wallet.WalletLogPrintf("Wallet can't contain any private keys - staking disabled\n");
        wallet.SetStakingEnabled(false);
    }
    else if (wallet.IsWalletFlagSet(WALLET_FLAG_BLANK_WALLET)) {
        wallet.WalletLogPrintf("Wallet is blank - staking disabled\n");
        wallet.SetStakingEnabled(false);
    }
    else if (!WITH_LOCK(wallet.cs_wallet, return wallet.GetKeyPoolSize() || !wallet.ListQuantumKeyInfos().empty())) {
        wallet.WalletLogPrintf("Error: Keypool is empty and no quantum staking keys are available, please add keys or call keypoolrefill and restart the staking thread\n");
        wallet.SetStakingEnabled(false);
    }
    else {
        wallet.m_stop_staking_thread = false;
        wallet.SetStakingEnabled(true);
        wallet.PublishStakingTelemetry(
            StakingTelemetryState::STARTING, uint256{}, -1,
            /*worker_running=*/false, "staking worker start requested");
    }
    StakeCoins(wallet, wallet.m_enabled_staking);
}

void StopStake(CWallet& wallet) {
    LOCK(wallet.m_staking_thread_mutex);
    if (!wallet.threadStakeMinerGroup) {
        wallet.SetStakingEnabled(false);
        wallet.PublishStakingTelemetry(
            StakingTelemetryState::DISABLED, uint256{}, -1,
            /*worker_running=*/false, "staking is disabled");
    }
    else {
        wallet.m_stop_staking_thread = true;
        wallet.SetStakingEnabled(false);
        StakeCoins(wallet, false);
        wallet.threadStakeMinerGroup.reset();
        wallet.m_stop_staking_thread = false;
        wallet.PublishStakingTelemetry(
            StakingTelemetryState::DISABLED, uint256{}, -1,
            /*worker_running=*/false, "staking is disabled");
    }
}

bool IsStakeSourceImmatureForNextBlock(const CWallet& wallet, const CWalletTx& wtx, int spend_height)
{
    AssertLockHeld(wallet.cs_wallet);
    if (!(wtx.IsCoinBase() || wtx.IsCoinStake())) return false;
    const TxStateConfirmed* confirmed = wtx.state<TxStateConfirmed>();
    if (!confirmed) return true;
    // The condition CheckProofOfStake and the input maturity check apply to a
    // block at spend_height: its height minus the output's height must reach
    // the coinbase maturity.
    return spend_height - confirmed->confirmed_block_height < Params().GetConsensus().nCoinbaseMaturity;
}

struct StakeTransactionEligibility
{
    bool active{false};
    bool immature{false};
};

struct StakeCandidateScanContext
{
    const CCoinControl* coin_control;
    const CoinFilterParams& params;
    const Consensus::Params& consensus;
    const std::set<COutPoint>& protected_rgb_seals;
    int min_depth;
    int max_depth;
    int spend_height;
    int64_t spend_time;
    bool allow_used_addresses;
    bool lineage_active;
    bool final_quantum_lockout;
    bool spend_state_prevalidated{false};
    // True when the caller walks only outputs that already passed IsStakeCandidateScript.
    bool script_class_prevalidated{false};
    std::set<uint256> trusted_parents;
    std::map<uint256, StakeTransactionEligibility> transaction_eligibility;
    // Set when a legacy kernel could only return its principal to an output
    // that cannot mature before Final and the wallet has no quantum stake
    // return address ready (see IsLegacyStakeBarredByMigrationEnd).
    bool legacy_stake_barred{false};
    // The scan looks this many blocks past the next block (readiness reports only;
    // 0 for the staker). spend_height already includes it.
    int blocks_ahead{0};
    // Why the last evaluated output was rejected (the first failing test).
    StakeExclusion exclusion{StakeExclusion::NONE};
    // Judge a coinbase or coinstake output mature by the wallet's own rule (CWallet::IsTxImmature: one block
    // after consensus would accept it as a kernel) instead of the next-block kernel rule. Only the claim
    // miner's stake reserve sets it: its selection of fee inputs must stay exactly what v30.1.6 did, and
    // the wallet's claim candidate list uses that same wallet rule (see GetBoundedLegacyStakeCandidates).
    bool wallet_maturity_rule{false};
};

static bool StakeSourceImmature(const CWallet& wallet, const CWalletTx& wtx, const StakeCandidateScanContext& context)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    return context.wallet_maturity_rule ? wallet.IsTxImmature(wtx)
                                        : IsStakeSourceImmatureForNextBlock(wallet, wtx, context.spend_height);
}

std::optional<int64_t> LastLegacyStakeHeight(const Consensus::Params& consensus)
{
    // Only the height-authoritative schedule names the Migration end exactly.
    // A wall-clock-only test schedule cannot be turned into a height.
    if (!consensus.UsesHeightLifecycle() || !consensus.IsMigrationEndScheduled()) return std::nullopt;
    return int64_t{consensus.nQuantumMigrationEndHeight} - int64_t{consensus.nCoinbaseMaturity} -
           int64_t{LEGACY_STAKE_MIGRATION_MARGIN_BLOCKS};
}

bool IsLegacyStakeBarredByMigrationEnd(const Consensus::Params& consensus, int stake_height)
{
    const std::optional<int64_t> last = LastLegacyStakeHeight(consensus);
    return last && int64_t{stake_height} > *last;
}

std::optional<int64_t> FirstOpportunisticLegacyReturnHeight(const Consensus::Params& consensus)
{
    if (!LastLegacyStakeHeight(consensus)) return std::nullopt;
    const int64_t final_height = int64_t{consensus.nQuantumMigrationEndHeight} + 1;
    const int64_t first_migration = int64_t{consensus.nGoldRushEndHeight} + 1;
    return std::max(first_migration,
                    final_height - int64_t{LEGACY_STAKE_OPPORTUNISTIC_RETURN_MATURITIES} * int64_t{consensus.nCoinbaseMaturity});
}

bool IsLegacyStakeInOpportunisticReturnWindow(const Consensus::Params& consensus, int stake_height)
{
    const std::optional<int64_t> last = LastLegacyStakeHeight(consensus);
    const std::optional<int64_t> first = FirstOpportunisticLegacyReturnHeight(consensus);
    return last && first && int64_t{stake_height} >= *first && int64_t{stake_height} <= *last;
}

std::optional<int64_t> DemurrageFirstReductionCountdown(const Consensus::Params& consensus,
                                                        const CScript& script_pub_key,
                                                        const Consensus::DemurrageEvaluation& eval,
                                                        int evaluation_height, int64_t evaluation_time)
{
    // Permanent exemption comes from the script and holds before activation too.
    if (!Consensus::DemurragePermanentExemption(script_pub_key, consensus).empty()) return std::nullopt;
    if (eval.locked) return std::nullopt;
    if (consensus.IsDemurrageActive(evaluation_height, evaluation_time)) {
        // Active. An output in grace (young) or protected by an attestation is exempt only for now: its
        // inactive blocks (counted from its age, the activation or its attestation) say how long is left.
        return Consensus::DemurrageBlocksUntilFirstReduction(eval.inactive_blocks, consensus);
    }
    // Not active yet. Only a height-given activation makes a countdown.
    if (!consensus.UsesHeightLifecycle()) return std::nullopt;
    const int activation = consensus.EffectiveDemurrageActivationHeight();
    if (activation == std::numeric_limits<int>::max() || evaluation_height >= activation) return std::nullopt;
    return int64_t{activation} - int64_t{evaluation_height} + Consensus::DemurrageBlocksUntilFirstReduction(0, consensus);
}

std::string QuantumStakeReturnBackupAction()
{
    return "Make a fresh wallet backup now (backupwallet, or Backup Wallet in the File menu) and keep it safe. Quantum keys are "
           "random and are not derived from a seed, so a backup made before this key was created cannot recover coins paid to it.";
}

std::string QuantumStakeReturnPendingAction()
{
    return "Wait for the wallet's own retry, or call setquantumstakereturn again after fixing the backup directory "
           "(-quantumkeybackupdir). The key stays in the wallet and is retried as it is; it becomes the return address only "
           "after a verified wallet backup. The previous return address, if any, stays in use.";
}

std::string LegacyStakingNotice(const Consensus::Params& consensus, int next_height,
                                const LegacyStakeQuantumReturn& quantum_return)
{
    const std::optional<int64_t> last = LastLegacyStakeHeight(consensus);
    if (!last || int64_t{next_height} > int64_t{consensus.nQuantumMigrationEndHeight}) return "";
    const int64_t final_height = int64_t{consensus.nQuantumMigrationEndHeight} + 1;
    const int64_t first_quantum = *last + 1;
    const std::string unstaked = strprintf(
        "Legacy coins that never win a stake stay legacy: migrate them to a quantum address before height %d "
        "(the first Final block) or they can never be spent.", final_height);
    // A stake at first_quantum matures in the very last Migration block, which the wallet does not
    // rely on (a margin of one block); from first_quantum + 1 on it could not mature before Final.
    const std::string why = strprintf(
        "The wallet starts one block early to keep a migration margin: a legacy stake at height %d would mature only in the "
        "last Migration block, and from height %d on it could not mature before the Final phase at all.",
        first_quantum, first_quantum + 1);
    std::string head;
    if (int64_t{next_height} > *last) {
        head = strprintf("Legacy stakes are now paid to a quantum address of this wallet (from height %d). %s", first_quantum, why);
    } else {
        head = strprintf("From height %d (%d blocks from now), legacy stakes are paid to a quantum address of this wallet. %s",
                         first_quantum, first_quantum - int64_t{next_height}, why);
    }
    std::string ready;
    if (quantum_return.available) {
        // A return made at height h can stake again at h + maturity. The first return (made at first_quantum,
        // which is the last Migration block minus the maturity) can stake in the last Migration block; one made
        // a block later only from the first Final block on.
        ready = strprintf("Return address READY: %s. Legacy coins that stake in the window leave as quantum coins, which "
                          "can stake again when they are %d blocks old: the first one (made at height %d) in the last Migration "
                          "block (%d), any later one from the first Final block (%d) on.",
                          quantum_return.address, consensus.nCoinbaseMaturity, first_quantum,
                          int64_t{consensus.nQuantumMigrationEndHeight}, final_height);
        if (!quantum_return.backup_verified) ready += " " + QuantumStakeReturnBackupAction();
    } else {
        ready = strprintf("Return address NOT READY: %s Until it is, this wallet will not stake legacy coins from height %d.",
                          quantum_return.reason, first_quantum);
    }
    // A key made for the return address that is not in a verified backup yet: said apart from the readiness of
    // the active destination above.
    if (quantum_return.pending) {
        ready += quantum_return.pending_error.empty()
            ? strprintf(" A new return key (%s) is waiting for its first verified wallet backup before it becomes the "
                        "return address.", quantum_return.pending_address)
            : strprintf(" A new return key (%s) is NOT active: its wallet backup failed (%s). It stays pending and the "
                        "backup is retried with the same key; fix the backup directory (-quantumkeybackupdir) or run "
                        "setquantumstakereturn again.", quantum_return.pending_address, quantum_return.pending_error);
    }
    // The opportunistic window opens earlier: with a ready return address a legacy stake is already paid as
    // quantum coins; without one it stakes as before, and the return address is the action to take.
    std::string opportunistic;
    if (const std::optional<int64_t> first_opportunistic = FirstOpportunisticLegacyReturnHeight(consensus);
        first_opportunistic && *first_opportunistic < first_quantum) {
        if (int64_t{next_height} >= *first_opportunistic) {
            opportunistic = quantum_return.available
                ? strprintf("Opportunistic return is ON: since height %d a legacy stake is paid to that address as one quantum output.",
                            *first_opportunistic)
                : strprintf("Opportunistic return is OFF since height %d because the return address is not ready, so legacy stakes "
                            "still pay legacy outputs. Make it ready now: %s",
                            *first_opportunistic, quantum_return.reason);
        } else {
            opportunistic = strprintf("From height %d (%d blocks from now) a legacy stake is already paid to that address as one "
                                      "quantum output when it is ready; without one it stakes as before.",
                                      *first_opportunistic, *first_opportunistic - int64_t{next_height});
        }
    }
    return head + " " + ready + (opportunistic.empty() ? "" : " " + opportunistic) + " " + unstaked;
}

std::optional<CTxDestination> ChooseLegacyStakeQuantumReturn(const std::vector<QuantumReturnCandidate>& candidates)
{
    static const std::array<const char*, 3> staker_labels{
        "PoS - Quantum Stake Address", "Quantum PoS Reward Address", "goldrush-pos"};
    std::optional<CTxDestination> best;
    int best_rank{-1};
    int64_t best_time{0};
    std::string best_encoded;
    for (const QuantumReturnCandidate& candidate : candidates) {
        if (candidate.is_change || !IsValidDestination(candidate.destination)) continue;
        if (!IsDirectQuantumMigrationScript(GetScriptForDestination(candidate.destination))) continue;
        int rank{1};
        for (size_t i = 0; i < staker_labels.size(); ++i) {
            if (candidate.label == staker_labels[i]) rank = static_cast<int>(10 - i);
        }
        const std::string encoded = EncodeDestination(candidate.destination);
        const bool better = !best || rank > best_rank ||
                            (rank == best_rank && (candidate.creation_time < best_time ||
                                                   (candidate.creation_time == best_time && encoded < best_encoded)));
        if (better) {
            best = candidate.destination;
            best_rank = rank;
            best_time = candidate.creation_time;
            best_encoded = encoded;
        }
    }
    return best;
}

QuantumReturnChoice ChooseQuantumStakeReturn(const CTxDestination& saved, const CTxDestination& configured,
                                             const CTxDestination& claim_key,
                                             const std::vector<QuantumReturnCandidate>& candidates)
{
    if (IsValidDestination(saved)) return {QuantumReturnSource::SAVED, saved};
    if (IsValidDestination(configured)) return {QuantumReturnSource::CONFIGURED, configured};
    if (IsValidDestination(claim_key)) return {QuantumReturnSource::CLAIM_KEY, claim_key};
    if (const auto pick = ChooseLegacyStakeQuantumReturn(candidates)) return {QuantumReturnSource::RANKED, *pick};
    return {};
}

namespace {
//! Why dest cannot be the quantum stake return address; empty when it can.
std::string QuantumStakeReturnProblem(const CWallet& wallet, const CTxDestination& dest)
{
    AssertLockHeld(wallet.cs_wallet);
    if (!IsValidDestination(dest) || !IsQuantumMigrationDestination(dest) ||
        !IsDirectQuantumMigrationScript(GetScriptForDestination(dest))) {
        return "it is not an ordinary quantum address.";
    }
    const auto info = wallet.GetQuantumKeyInfo(dest);
    if (!info) return "it is not backed by a quantum key of this wallet.";
    if (!info->durably_stored) return "its quantum key is not durably stored yet.";
    // A key made for the return address stays out of every use as the destination until its backup succeeded.
    if (wallet.IsQuantumStakeReturnPendingKey(dest)) return "it is a new key still waiting for its first verified wallet backup.";
    return "";
}
} // namespace

LegacyStakeQuantumReturn ResolveLegacyStakeQuantumReturn(const CWallet& wallet)
{
    AssertLockHeld(wallet.cs_wallet);
    LegacyStakeQuantumReturn result;
    if (wallet.m_quantum_return_pending) {
        result.pending = true;
        result.pending_address = EncodeDestination(WitnessUnknown{QUANTUM_MIGRATION_WITNESS_VERSION, wallet.m_quantum_return_pending->witness_program});
        result.pending_error = wallet.m_quantum_return_pending_error;
    }
    if (wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)) {
        result.reason = "this wallet has no private keys.";
        return result;
    }
    if (wallet.m_quantum_stake_return.empty()) {
        result.reason = "no quantum stake return address is set. Unlock the wallet normally (not for staking only) "
                        "so it can choose one, or run setquantumstakereturn.";
        return result;
    }
    const CTxDestination dest = DecodeDestination(wallet.m_quantum_stake_return);
    const std::string problem = QuantumStakeReturnProblem(wallet, dest);
    if (!problem.empty()) {
        result.reason = strprintf("the saved quantum stake return address %s cannot be used: %s Run setquantumstakereturn "
                                  "with another address.", wallet.m_quantum_stake_return, problem);
        return result;
    }
    result.available = true;
    result.script = GetScriptForDestination(dest);
    result.address = wallet.m_quantum_stake_return;
    if (const auto info = wallet.GetQuantumKeyInfo(dest)) result.backup_verified = info->backup_verified;
    return result;
}

bool SetQuantumStakeReturn(CWallet& wallet, const CTxDestination& dest, bilingual_str& error)
{
    LOCK(wallet.cs_wallet);
    const std::string problem = QuantumStakeReturnProblem(wallet, dest);
    if (!problem.empty()) {
        error = Untranslated("The address cannot be the quantum stake return address: " + problem);
        return false;
    }
    const std::string encoded = EncodeDestination(dest);
    WalletBatch batch(wallet.GetDatabase());
    if (!batch.WriteQuantumStakeReturn(encoded)) {
        error = _("Failed to write the quantum stake return address to the wallet database.");
        return false;
    }
    wallet.m_quantum_stake_return = encoded;
    // The candidate set depends on it inside the window; never serve a stale selection.
    DropStakeSlotCache(wallet);
    if (const auto info = wallet.GetQuantumKeyInfo(dest); info && !info->backup_verified) {
        wallet.WalletLogPrintf("Quantum stake return address %s is not in a verified wallet backup yet. %s\n",
                               encoded, QuantumStakeReturnBackupAction());
    }
    return true;
}

/** Whether the wallet holds a live legacy output of a kind the staker can stake: of a script class kernels can
 *  be built for (not a quantum, cold-stake or EUTXO script), owned by this wallet with a spendable key and
 *  signable here, and not a protected asset. The live candidate index is only a prefilter on script shape
 *  (it also holds outputs of other parties that sit in the wallet's transaction history), so ownership and
 *  signability are decided here, with the tests the staking evaluator applies. Stops at the first one. */
bool WalletHoldsLegacyStakableCoin(const CWallet& wallet)
{
    AssertLockHeld(wallet.cs_wallet);
    if (wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)) return false;
    const std::set<COutPoint> protected_seals = wallet.GetProtectedRGBSeals();
    std::map<CScript, bool> signable; // per script, looked up once
    for (const COutPoint& outpoint : wallet.GetLiveUnspentStakeCandidateOutpoints()) {
        const auto it = wallet.mapWallet.find(outpoint.hash);
        if (it == wallet.mapWallet.end() || !it->second.tx || outpoint.n >= it->second.tx->vout.size()) continue;
        const CTxOut& out = it->second.tx->vout[outpoint.n];
        if (out.nValue < wallet.m_min_staking_amount) continue;
        if (IsQuantumMigrationScript(out.scriptPubKey) || IsQuantumColdStakeScript(out.scriptPubKey) ||
            IsEUTXOScript(out.scriptPubKey)) {
            continue;
        }
        if (!IsStakeCandidateScript(out.scriptPubKey) || protected_seals.count(outpoint)) continue;
        if ((wallet.IsMine(out) & ISMINE_SPENDABLE) == ISMINE_NO) continue;
        auto [sign_it, inserted] = signable.try_emplace(out.scriptPubKey, false);
        if (inserted) sign_it->second = CalculateMaximumSignedInputSize(out, &wallet, /*coin_control=*/nullptr) > 0;
        if (!sign_it->second) continue;
        return true;
    }
    return false;
}

namespace {
//! How long the wallet's own retry waits after a failed backup of the pending key.
constexpr std::chrono::seconds QUANTUM_RETURN_AUTOMATIC_RETRY_INTERVAL{60};

//! A crash point for functional tests: on a test chain, with -quantumreturncrashpoint=<point>, the process
//! ends here without any cleanup, as a power loss would. Never reachable on a production chain.
void QuantumReturnCrashPoint(const CWallet& wallet, const char* point)
{
    if (!Params().IsTestChain()) return;
    if (gArgs.GetArg("-quantumreturncrashpoint", "") != point) return;
    wallet.WalletLogPrintf("Quantum stake return test crash point %s reached; exiting without cleanup.\n", point);
    std::_Exit(7);
}

/** Back the wallet up, with every quantum key reopened and challenged, into the wallet's backup directory and
 *  record the generation next to it. No wallet or chain lock is held: this is file system work. */
bool BackupQuantumReturnKey(CWallet& wallet, std::string& error)
{
    AssertLockNotHeld(::cs_main);
    AssertLockNotHeld(wallet.cs_wallet);
    const fs::path directory = QuantumKeyBackupDirectory(wallet.GetName());
    if (!EnsureQuantumKeyBackupDirectory(directory, error)) return false;
    const QuantumKeyBackupKeySet keys = WITH_LOCK(wallet.cs_wallet, return wallet.GetQuantumKeyPrograms());
    const std::optional<int> height = wallet.HaveChain() ? wallet.chain().getHeight() : std::nullopt;
    const std::string file_name = QuantumKeyBackupFileName(GetTime(), height.value_or(0), NewQuantumKeyBackupSuffix());
    const uint64_t sequence = NextQuantumKeyBackupSequence(directory);
    bilingual_str backup_error;
    if (!wallet.BackupWallet(fs::PathToString(directory / fs::PathFromString(file_name)), &backup_error, /*verify_quantum_keys=*/true)) {
        error = backup_error.original.empty() ? "the wallet backup failed" : backup_error.original;
        return false;
    }
    QuantumReturnCrashPoint(wallet, "after_backup_install");
    return WriteQuantumKeyBackupManifest(directory, file_name, sequence, keys, error);
}

/** Make the pending key the destination (unless a valid destination was saved meanwhile) and clear the pending
 *  record, in one durable database transaction. Memory follows only after the commit. */
bool ActivatePendingQuantumStakeReturn(CWallet& wallet, const CTxDestination& dest, bool& became_destination, bilingual_str& error)
{
    LOCK(wallet.cs_wallet);
    became_destination = false;
    if (!wallet.m_quantum_return_pending) return true;
    const bool set_destination = !ResolveLegacyStakeQuantumReturn(wallet).available;
    const std::string encoded = EncodeDestination(dest);
    WalletBatch batch(wallet.GetDatabase());
    if (!batch.TxnBegin(/*durable=*/true)) {
        error = _("Failed to begin the database transaction that activates the quantum stake return address.");
        return false;
    }
    if (set_destination && !batch.WriteQuantumStakeReturn(encoded)) {
        batch.TxnAbort();
        error = _("Failed to write the quantum stake return address to the wallet database.");
        return false;
    }
    if (!batch.EraseQuantumStakeReturnPending()) {
        batch.TxnAbort();
        error = _("Failed to clear the pending quantum stake return record.");
        return false;
    }
    if (!batch.TxnCommit()) {
        batch.TxnAbort();
        error = _("Failed to commit the activation of the quantum stake return address.");
        return false;
    }
    if (set_destination) wallet.m_quantum_stake_return = encoded;
    wallet.m_quantum_return_pending.reset();
    wallet.m_quantum_return_pending_error.clear();
    // The candidate set depends on it inside the window; never serve a stale selection.
    DropStakeSlotCache(wallet);
    became_destination = set_destination;
    return true;
}

/** The pending key: back it up, then activate it. prep carries what the caller knows already. Holds the
 *  wallet's preparation mutex (the caller), no other lock. */
QuantumStakeReturnPreparation FinishPendingQuantumStakeReturn(CWallet& wallet, QuantumStakeReturnPreparation prep)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.m_quantum_return_prepare_mutex)
{
    using Outcome = QuantumStakeReturnPreparation::Outcome;
    CTxDestination dest;
    {
        LOCK(wallet.cs_wallet);
        if (!wallet.m_quantum_return_pending) {
            prep.detail = "no key is waiting for its backup";
            return prep;
        }
        dest = WitnessUnknown{QUANTUM_MIGRATION_WITNESS_VERSION, wallet.m_quantum_return_pending->witness_program};
    }
    prep.address = EncodeDestination(dest);
    prep.key_created = true;
    const auto still_pending = [&](const std::string& why) {
        {
            LOCK(wallet.cs_wallet);
            wallet.m_quantum_return_pending_error = why;
        }
        wallet.WalletLogPrintf("The new quantum stake return key %s is not active yet: %s. The key stays in the wallet and the previous return address stays in use; the backup is retried with the same key.\n",
                               prep.address, why);
        wallet.m_quantum_return_retry_at = SteadyClock::now() + QUANTUM_RETURN_AUTOMATIC_RETRY_INTERVAL;
        prep.outcome = Outcome::PENDING_BACKUP;
        prep.detail = why;
        return prep;
    };
    std::string backup_error;
    if (!BackupQuantumReturnKey(wallet, backup_error)) return still_pending(backup_error);
    QuantumReturnCrashPoint(wallet, "before_activation");
    bool became_destination{false};
    bilingual_str activation_error;
    if (!ActivatePendingQuantumStakeReturn(wallet, dest, became_destination, activation_error)) {
        return still_pending(activation_error.original);
    }
    QuantumReturnCrashPoint(wallet, "after_activation");
    wallet.m_quantum_return_retry_at = {};
    // Only after the activation is durable: keep the newest generations and the sole protectors of any key.
    {
        const QuantumKeyBackupKeySet live = WITH_LOCK(wallet.cs_wallet, return wallet.GetQuantumKeyPrograms());
        PruneQuantumKeyBackups(QuantumKeyBackupDirectory(wallet.GetName()), live, QUANTUM_KEY_BACKUP_KEEP_GENERATIONS);
    }
    if (!became_destination) {
        prep.outcome = Outcome::NO_ACTION;
        prep.detail = "the new key is in a verified backup; the return address saved meanwhile stays";
        return prep;
    }
    wallet.WalletLogPrintf("Quantum stake return address set to %s after a verified wallet backup: legacy stakes in the last %d blocks of Migration are paid there.\n",
                           prep.address, Params().GetConsensus().nCoinbaseMaturity + LEGACY_STAKE_MIGRATION_MARGIN_BLOCKS);
    prep.outcome = Outcome::CREATED_ADDRESS;
    return prep;
}
} // namespace

QuantumStakeReturnPreparation PrepareQuantumStakeReturn(CWallet& wallet, QuantumStakeReturnTrigger trigger, bool allow_new_key)
{
    using Outcome = QuantumStakeReturnPreparation::Outcome;
    QuantumStakeReturnPreparation prep;
    const Consensus::Params& consensus = Params().GetConsensus();
    if (!LastLegacyStakeHeight(consensus)) {
        prep.detail = "no height-authoritative Migration schedule";
        return prep;
    }
    if (wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS) || wallet.IsLocked() ||
        wallet.m_wallet_unlock_staking_only) {
        prep.detail = "the wallet cannot create or choose a key in its current unlock state";
        return prep;
    }
    // The chain's own height: no wallet lock, and no assertion for a wallet that has not processed a block yet.
    const std::optional<int> tip_height = wallet.HaveChain() ? wallet.chain().getHeight() : std::nullopt;
    if (!tip_height) {
        prep.detail = "the chain has no tip yet";
        return prep;
    }
    if (int64_t{*tip_height} + 1 > int64_t{consensus.nQuantumMigrationEndHeight} && trigger == QuantumStakeReturnTrigger::AUTOMATIC) {
        prep.detail = "the window has passed";
        return prep;
    }
    // One preparation at a time per wallet, so concurrent callers produce one key. The mutex is taken before
    // any wallet lock, and the backup below runs with no wallet and no chain lock held.
    AssertLockNotHeld(::cs_main);
    AssertLockNotHeld(wallet.cs_wallet);
    LOCK(wallet.m_quantum_return_prepare_mutex);
    // A key made earlier whose backup did not finish is completed first, whoever asks and whatever the other
    // conditions of an automatic preparation are: it already has its consent. Retrying here is also what a
    // restart does, since the record is loaded with the wallet.
    if (WITH_LOCK(wallet.cs_wallet, return wallet.m_quantum_return_pending.has_value())) {
        if (trigger == QuantumStakeReturnTrigger::AUTOMATIC && SteadyClock::now() < wallet.m_quantum_return_retry_at) {
            prep.detail = "the last backup of the pending key failed a moment ago; it is retried soon";
            return prep;
        }
        return FinishPendingQuantumStakeReturn(wallet, prep);
    }
    if (trigger == QuantumStakeReturnTrigger::AUTOMATIC) {
        // Not before Gold Rush has ended, and only for a wallet with legacy coins to return: a pre-end chain
        // and a wallet with nothing to stake see no key, record or backup prompt appear on their own.
        if (int64_t{*tip_height} + 1 <= int64_t{consensus.nGoldRushEndHeight}) {
            prep.detail = "Gold Rush has not ended; the explicit command is available";
            return prep;
        }
        if (!WITH_LOCK(wallet.cs_wallet, return WalletHoldsLegacyStakableCoin(wallet))) {
            prep.detail = "this wallet holds no legacy coin the staker could stake";
            return prep;
        }
    }
    QuantumReturnChoice choice;
    {
        LOCK(wallet.cs_wallet);
        const LegacyStakeQuantumReturn current = ResolveLegacyStakeQuantumReturn(wallet);
        if (current.available) {
            prep.address = current.address;
            prep.detail = "a quantum stake return address is already saved";
            return prep;
        }
        CTxDestination configured_dest;
        const std::vector<std::string> configured = gArgs.GetArgs("-qqpospayoutaddress");
        if (configured.size() == 1) {
            const CTxDestination dest = DecodeDestination(configured.front());
            if (QuantumStakeReturnProblem(wallet, dest).empty()) configured_dest = dest;
        }
        CTxDestination claim_dest;
        if (!IsValidDestination(configured_dest)) {
            const CTxDestination dest = wallet.GetRecordedPowPayoutKey();
            if (QuantumStakeReturnProblem(wallet, dest).empty()) claim_dest = dest;
        }
        std::vector<QuantumReturnCandidate> candidates;
        if (!IsValidDestination(configured_dest) && !IsValidDestination(claim_dest)) {
            wallet.ForEachAddrBookEntry([&](const CTxDestination& dest, const std::string& label, bool is_change,
                                            const std::optional<AddressPurpose> purpose) {
                if (is_change || !purpose || *purpose != AddressPurpose::RECEIVE) return;
                if (!QuantumStakeReturnProblem(wallet, dest).empty()) return;
                const auto info = wallet.GetQuantumKeyInfo(dest);
                candidates.push_back({dest, label, is_change, info ? info->creation_time : 0});
            });
        }
        choice = ChooseQuantumStakeReturn(CTxDestination{}, configured_dest, claim_dest, candidates);
    }
    // The wallet lock is not held from here: key generation and the database writes below take
    // the locks they need themselves.
    if (choice.source == QuantumReturnSource::NONE) {
        // The existing key-creation policy decides whether a new key may exist.
        const bool automatic_consent = gArgs.GetBoolArg("-qqallowautokeycreation", DEFAULT_ALLOW_AUTO_QUANTUM_KEY_CREATION);
        if (!allow_new_key && !automatic_consent) {
            prep.detail = "no quantum address to reuse and automatic key creation is not allowed";
            return prep;
        }
        const auto key = wallet.AddQuantumStakeReturnKey("PoS - Quantum Stake Address", allow_new_key ? "explicit" : "automatic");
        if (!key) {
            wallet.WalletLogPrintf("Quantum stake return address not created: %s\n", util::ErrorString(key).original);
            prep.outcome = Outcome::FAILED;
            prep.detail = util::ErrorString(key).original;
            return prep;
        }
        wallet.WalletLogPrintf("Created quantum stake address %s for legacy stakes paid as quantum coins. It becomes the return address after a verified wallet backup.\n",
                               EncodeDestination(*key));
        prep.address = EncodeDestination(*key);
        prep.key_created = true;
        QuantumReturnCrashPoint(wallet, "after_key_insertion");
        return FinishPendingQuantumStakeReturn(wallet, prep);
    }
    bilingual_str error;
    if (!SetQuantumStakeReturn(wallet, choice.destination, error)) {
        wallet.WalletLogPrintf("Quantum stake return address not set: %s\n", error.original);
        prep.outcome = Outcome::FAILED;
        prep.address = EncodeDestination(choice.destination);
        prep.detail = error.original;
        return prep;
    }
    wallet.WalletLogPrintf("Quantum stake return address set to %s: legacy stakes in the last %d blocks of Migration are paid there.\n",
                           EncodeDestination(choice.destination), consensus.nCoinbaseMaturity + LEGACY_STAKE_MIGRATION_MARGIN_BLOCKS);
    prep.outcome = Outcome::REUSED_ADDRESS;
    prep.address = EncodeDestination(choice.destination);
    return prep;
}

bool MaybeAutoSetQuantumStakeReturn(CWallet& wallet)
{
    return PrepareQuantumStakeReturn(wallet, QuantumStakeReturnTrigger::AUTOMATIC).Saved();
}

/**
 * The staking eligibility predicate exactly as it stood before the per-slot
 * scan was narrowed (same conjuncts, same order, eager solvability). It is only
 * used by AvailableCoinsForStakingReference so tests can prove the narrowed
 * scan selects the identical set.
 */
static bool EvaluateStakeCandidateReference(const CWallet& wallet, const COutPoint& outpoint,
                                   const CWalletTx& wtx, StakeCandidateScanContext& context,
                                   bool& spendable)
{
    spendable = false;
    if (!wtx.tx || outpoint.n >= wtx.tx->vout.size()) return false;

    auto [eligibility, inserted] = context.transaction_eligibility.emplace(
        wtx.GetHash(), StakeTransactionEligibility{});
    if (inserted) {
        const int depth = wallet.GetTxDepthInMainChain(wtx);
        const bool active = depth >= 0 &&
            !(depth == 0 && !wtx.InMempool()) &&
            (context.blocks_ahead == 0 || depth > 0) &&
            depth + context.blocks_ahead >= context.min_depth && depth <= context.max_depth &&
            CachedTxIsTrusted(wallet, wtx, context.trusted_parents);
        eligibility->second = {active, StakeSourceImmature(wallet, wtx, context)};
    }
    if (!eligibility->second.active) return false;

    const CTxOut& output = wtx.tx->vout[outpoint.n];
    // Immature for the next block (which also covers a Gold Rush payout, whose
    // maturity is the same).
    if (eligibility->second.immature) return false;

    if (output.nValue < wallet.m_min_staking_amount ||
        output.nValue < context.params.min_amount ||
        output.nValue > context.params.max_amount) {
        return false;
    }
    if (wallet.IsLockedCoin(outpoint) && context.params.skip_locked) return false;

    // The exact live-unspent index should make this redundant. Keep the check
    // as a fail-closed invariant guard if a future wallet mutation path is
    // introduced without an index hook.
    if (!context.spend_state_prevalidated && wallet.IsSpent(outpoint)) {
        return false;
    }

    if (context.lineage_active) {
        const Coin& coin = wallet.chain().getCoinsTip().AccessCoin(outpoint);
        if (coin.IsSpent() || !IsWalletProtectedLineageInput(
                wallet, outpoint, coin, context.consensus,
                context.spend_time, context.spend_height)) {
            return false;
        }
    }

    const bool quantum_output = IsQuantumMigrationScript(output.scriptPubKey) ||
                                IsQuantumColdStakeScript(output.scriptPubKey);
    if ((quantum_output && !context.lineage_active) ||
        (context.final_quantum_lockout && !quantum_output) ||
        (context.legacy_stake_barred && !quantum_output)) {
        return false;
    }

    if (IsGeneratedQuantumStakeCandidate(wallet, outpoint, output.scriptPubKey,
                                         context.spend_height, context.spend_time) ||
        IsDemurrageLockedStakeCandidate(wallet, outpoint, output.scriptPubKey,
                                        context.spend_height, context.spend_time) ||
        context.protected_rgb_seals.count(outpoint)) {
        return false;
    }

    const isminetype mine = wallet.IsMine(output);
    if (mine == ISMINE_NO) return false;
    if (!context.allow_used_addresses && wallet.IsSpentKey(output.scriptPubKey)) return false;

    std::unique_ptr<SigningProvider> provider = wallet.GetSolvingProvider(output.scriptPubKey);
    bool solvable = quantum_output;
    if (!solvable && provider) {
        if (auto desc = InferDescriptor(output.scriptPubKey, *provider)) {
            solvable = desc->IsSolvable();
        }
    }
    spendable = ((mine & ISMINE_SPENDABLE) != ISMINE_NO) ||
        (((mine & ISMINE_WATCH_ONLY) != ISMINE_NO) &&
         (context.coin_control && context.coin_control->fAllowWatchOnly && solvable));
    if (!spendable && context.params.only_spendable) return false;

    // CreateCoinStake can only construct kernels for these legacy types. Keep
    // status weight and actual kernel selection on the same candidate set.
    if (!quantum_output) {
        std::vector<std::vector<unsigned char>> solutions;
        const TxoutType type = Solver(output.scriptPubKey, solutions);
        if (type != TxoutType::PUBKEY && type != TxoutType::PUBKEYHASH &&
            type != TxoutType::WITNESS_V0_KEYHASH && type != TxoutType::WITNESS_V1_TAPROOT) {
            return false;
        }
    }

    return true;
}

/**
 * Authoritative producer-side staking eligibility check. The wallet index is
 * intentionally only a live-unspent, stakable-script prefilter; every mutable
 * policy and phase rule is evaluated here for both stake weight and kernel
 * selection.
 *
 * Maturity is the consensus condition for the next block (see
 * IsStakeSourceImmatureForNextBlock): a coinbase or coinstake output is a
 * kernel from the block `maturity` above it, whatever its kind.
 *
 * The result is the conjunction of independent side-effect-free tests. They
 * run cheapest first (amount, lock, ownership) so an output that cannot stake
 * never reaches the chain-view lookups, and solvability, which builds a
 * signing provider, is only computed when it can change the answer.
 */
static bool EvaluateStakeCandidate(const CWallet& wallet, const COutPoint& outpoint,
                                   const CWalletTx& wtx, StakeCandidateScanContext& context,
                                   bool& spendable)
{
    spendable = false;
    context.exclusion = StakeExclusion::NONE;
    // Every rejection names its reason (the first failing test) for the readiness
    // report; the staker itself only looks at the result.
    const auto exclude = [&context](StakeExclusion reason) {
        context.exclusion = reason;
        return false;
    };
    if (!wtx.tx || outpoint.n >= wtx.tx->vout.size()) return exclude(StakeExclusion::OTHER);

    const CTxOut& output = wtx.tx->vout[outpoint.n];
    if (output.nValue < wallet.m_min_staking_amount ||
        output.nValue < context.params.min_amount) {
        return exclude(StakeExclusion::BELOW_MINIMUM);
    }
    if (output.nValue > context.params.max_amount) return exclude(StakeExclusion::OTHER);
    if (wallet.IsLockedCoin(outpoint) && context.params.skip_locked) return exclude(StakeExclusion::LOCKED);

    const bool quantum_output = IsQuantumMigrationScript(output.scriptPubKey) ||
                                IsQuantumColdStakeScript(output.scriptPubKey);
    if ((quantum_output && !context.lineage_active) ||
        (context.final_quantum_lockout && !quantum_output) ||
        (context.legacy_stake_barred && !quantum_output)) {
        return exclude(StakeExclusion::OTHER);
    }

    // CreateCoinStake can only construct kernels for these legacy types. Keep
    // status weight and actual kernel selection on the same candidate set.
    if (!quantum_output && !context.script_class_prevalidated &&
        !IsStakeCandidateScript(output.scriptPubKey)) {
        return exclude(StakeExclusion::OTHER);
    }

    const isminetype mine = wallet.IsMine(output);
    if (mine == ISMINE_NO) return exclude(StakeExclusion::OTHER);
    if (!context.allow_used_addresses && wallet.IsSpentKey(output.scriptPubKey)) return exclude(StakeExclusion::OTHER);

    // Without watch-only access the result cannot depend on solvability.
    const bool watch_only_allowed = (mine & ISMINE_WATCH_ONLY) != ISMINE_NO &&
        context.coin_control && context.coin_control->fAllowWatchOnly;
    const bool mine_spendable = (mine & ISMINE_SPENDABLE) != ISMINE_NO;
    if (!mine_spendable && !watch_only_allowed && context.params.only_spendable) {
        return exclude(StakeExclusion::SIGNER_UNAVAILABLE);
    }

    auto [eligibility, inserted] = context.transaction_eligibility.emplace(
        wtx.GetHash(), StakeTransactionEligibility{});
    if (inserted) {
        const int depth = wallet.GetTxDepthInMainChain(wtx);
        const bool active = depth >= 0 &&
            !(depth == 0 && !wtx.InMempool()) &&
            (context.blocks_ahead == 0 || depth > 0) &&
            depth + context.blocks_ahead >= context.min_depth && depth <= context.max_depth &&
            CachedTxIsTrusted(wallet, wtx, context.trusted_parents);
        eligibility->second = {active, StakeSourceImmature(wallet, wtx, context)};
    }
    if (!eligibility->second.active) {
        const int depth = wallet.GetTxDepthInMainChain(wtx);
        // Waiting to confirm or to age counts as immature; a transaction that is no
        // longer in the chain or the mempool (replaced by a reorganisation) does not.
        const bool waiting = depth > 0 ? depth + context.blocks_ahead < context.min_depth
                                       : (depth == 0 && wtx.InMempool());
        return exclude(waiting ? StakeExclusion::IMMATURE : StakeExclusion::OTHER);
    }
    // Immature for the next block (which also covers a Gold Rush payout, whose
    // maturity is the same).
    if (eligibility->second.immature) return exclude(StakeExclusion::IMMATURE);

    // The exact live-unspent index should make this redundant. Keep the check
    // as a fail-closed invariant guard if a future wallet mutation path is
    // introduced without an index hook.
    if (!context.spend_state_prevalidated && wallet.IsSpent(outpoint)) {
        return exclude(StakeExclusion::OTHER);
    }

    if (context.lineage_active) {
        const Coin& coin = wallet.chain().getCoinsTip().AccessCoin(outpoint);
        if (coin.IsSpent() || !IsWalletProtectedLineageInput(
                wallet, outpoint, coin, context.consensus,
                context.spend_time, context.spend_height)) {
            return exclude(StakeExclusion::OTHER);
        }
    }

    if (IsGeneratedQuantumStakeCandidate(wallet, outpoint, output.scriptPubKey,
                                         context.spend_height, context.spend_time) ||
        IsDemurrageLockedStakeCandidate(wallet, outpoint, output.scriptPubKey,
                                        context.spend_height, context.spend_time)) {
        return exclude(StakeExclusion::LOCKED);
    }
    if (context.protected_rgb_seals.count(outpoint)) return exclude(StakeExclusion::OTHER);

    bool solvable = quantum_output;
    if (!mine_spendable && watch_only_allowed && !solvable) {
        std::unique_ptr<SigningProvider> provider = wallet.GetSolvingProvider(output.scriptPubKey);
        if (provider) {
            if (auto desc = InferDescriptor(output.scriptPubKey, *provider)) {
                solvable = desc->IsSolvable();
            }
        }
    }
    spendable = mine_spendable || (watch_only_allowed && solvable);
    if (!spendable && context.params.only_spendable) return exclude(StakeExclusion::SIGNER_UNAVAILABLE);

    return true;
}

BoundedLegacyStakeCandidates GetBoundedLegacyStakeCandidates(
    const CWallet& wallet,
    const std::vector<BoundedLegacyStakeSource>& sources,
    const std::set<COutPoint>& protected_rgb_seals,
    int active_height, int64_t median_time_past,
    const CCoinControl* coin_control,
    const CoinFilterParams& params)
{
    AssertLockNotHeld(::cs_main);
    AssertLockHeld(wallet.cs_wallet);

    BoundedLegacyStakeCandidates result;
    const Consensus::Params& consensus = Params().GetConsensus();
    const int spend_height = active_height + 1;
    if (active_height < 0 ||
        !IsShadowGoldRushRewardActive(
            consensus, median_time_past, spend_height)) {
        return result;
    }
    const bool allow_used_addresses =
        !wallet.IsWalletFlagSet(WALLET_FLAG_AVOID_REUSE);
    StakeCandidateScanContext context{
        coin_control,
        params,
        consensus,
        protected_rgb_seals,
        std::max(DEFAULT_MIN_DEPTH, consensus.nCoinbaseMaturity),
        DEFAULT_MAX_DEPTH,
        spend_height,
        median_time_past,
        allow_used_addresses,
        /*lineage_active=*/false,
        /*final_quantum_lockout=*/false,
        /*spend_state_prevalidated=*/true,
        /*script_class_prevalidated=*/false,
        {},
        {},
    };
    context.legacy_stake_barred = IsLegacyStakeBarredByMigrationEnd(consensus, spend_height) &&
                                  !ResolveLegacyStakeQuantumReturn(wallet).available;
    context.wallet_maturity_rule = true;
    result.candidates.reserve(sources.size());
    for (const BoundedLegacyStakeSource& source : sources) {
        const COutPoint& outpoint = source.outpoint;
        const CWalletTx* wallet_tx = source.wallet_tx;
        if (!wallet_tx || !wallet_tx->tx ||
            outpoint.n >= wallet_tx->tx->vout.size()) {
            continue;
        }
        const CScript& script =
            wallet_tx->tx->vout[outpoint.n].scriptPubKey;
        if (script.empty() || script.IsUnspendable() ||
            IsQuantumMigrationScript(script) ||
            IsQuantumColdStakeScript(script) || IsEUTXOScript(script)) {
            continue;
        }
        // The wallet's own maturity rule, exactly as in v30.1.6: this list only feeds the claim miner's stake
        // reserve (which coins stay out of claim fee-input selection), and the claim candidates it is set
        // against are judged by the same wallet rule. See the note at wallet_maturity_rule.
        if (wallet.IsTxImmature(*wallet_tx)) continue;
        bool spendable{false};
        if (!EvaluateStakeCandidate(
                wallet, outpoint, *wallet_tx, context,
                spendable) ||
            !spendable) {
            continue;
        }
        result.candidates.push_back(
            {outpoint,
             wallet_tx->tx->vout[outpoint.n].nValue});
    }
    return result;
}

template <bool REFERENCE>
static void AvailableCoinsForStakingImpl(const CWallet& wallet,
                           std::vector<std::pair<const CWalletTx*, unsigned int> >& vCoins,
                           const CCoinControl* coinControl,
                           const CoinFilterParams& params,
                           int blocks_ahead = 0,
                           const StakeScanObserver* observer = nullptr)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(wallet.cs_wallet);

    vCoins.clear();
    CAmount nTotal = 0;
    // Either the WALLET_FLAG_AVOID_REUSE flag is not set (in which case we always allow), or we default to avoiding, and only in the case where
    // a coin control object is provided, and has the avoid address reuse flag set to false, do we allow already used addresses
    bool allow_used_addresses = !wallet.IsWalletFlagSet(WALLET_FLAG_AVOID_REUSE);
    const int min_depth = std::max(DEFAULT_MIN_DEPTH, Params().GetConsensus().nCoinbaseMaturity);
    const int max_depth = DEFAULT_MAX_DEPTH;
    const CBlockIndex* tip = wallet.chain().getTip();
    const int spend_height = (tip ? tip->nHeight + 1 : 0) + blocks_ahead;
    const int64_t spend_time = tip ? tip->GetMedianTimePast() : 0;
    const Consensus::Params& consensus = Params().GetConsensus();
    const bool lineage_active = IsQuantumWitnessSpendActive(consensus, spend_time, spend_height);

    // Never stake UTXOs carrying live RGB single-use-seal or EUTXO state.
    const std::set<COutPoint> protected_rgb_seals = wallet.GetProtectedRGBSeals();

    StakeCandidateScanContext context{
        coinControl,
        params,
        consensus,
        protected_rgb_seals,
        min_depth,
        max_depth,
        spend_height,
        spend_time,
        allow_used_addresses,
        lineage_active,
        consensus.IsQuantumFinalLockout(spend_time, spend_height),
        /*spend_state_prevalidated=*/false,
        /*script_class_prevalidated=*/!REFERENCE,
        {},
        {},
    };

    context.blocks_ahead = blocks_ahead;
    context.legacy_stake_barred = IsLegacyStakeBarredByMigrationEnd(consensus, spend_height) &&
                                  !ResolveLegacyStakeQuantumReturn(wallet).available;

    // The candidate subset holds exactly the live outpoints whose script can
    // stake, in the same order, so the selected set equals a walk of the full
    // live index; the reference path walks the full index to prove that.
    const std::set<COutPoint>& scan_set = REFERENCE ? wallet.GetLiveUnspentStakeOutpoints()
                                                    : wallet.GetLiveUnspentStakeCandidateOutpoints();
    for (const COutPoint& outpoint : scan_set) {
        const auto wallet_tx = wallet.mapWallet.find(outpoint.hash);
        if (wallet_tx == wallet.mapWallet.end()) continue;

        bool spendable{false};
        const bool evaluated = REFERENCE
            ? EvaluateStakeCandidateReference(wallet, outpoint, wallet_tx->second, context, spendable)
            : EvaluateStakeCandidate(wallet, outpoint, wallet_tx->second, context, spendable);
        if (observer) (*observer)(outpoint, wallet_tx->second, evaluated && spendable, context.exclusion);
        if (!evaluated) continue;

        const CTxOut& output = wallet_tx->second.tx->vout[outpoint.n];
        if (spendable) vCoins.emplace_back(&wallet_tx->second, outpoint.n);

        nTotal += output.nValue;
        if (params.min_sum_amount != MAX_MONEY && nTotal >= params.min_sum_amount) return;
        if (params.max_count > 0 && vCoins.size() >= params.max_count) return;
    }
}

void AvailableCoinsForStaking(const CWallet& wallet,
                           std::vector<std::pair<const CWalletTx*, unsigned int> >& vCoins,
                           const CCoinControl* coinControl,
                           const CoinFilterParams& params)
{
    AvailableCoinsForStakingImpl</*REFERENCE=*/false>(wallet, vCoins, coinControl, params);
}

void AvailableCoinsForStakingAhead(const CWallet& wallet,
                           std::vector<std::pair<const CWalletTx*, unsigned int> >& vCoins,
                           const CCoinControl* coinControl,
                           const CoinFilterParams& params,
                           int blocks_ahead,
                           const StakeScanObserver& observer)
{
    AvailableCoinsForStakingImpl</*REFERENCE=*/false>(wallet, vCoins, coinControl, params, blocks_ahead, &observer);
}

void AvailableCoinsForStakingReference(const CWallet& wallet,
                           std::vector<std::pair<const CWalletTx*, unsigned int> >& vCoins,
                           const CCoinControl* coinControl,
                           const CoinFilterParams& params)
{
    AvailableCoinsForStakingImpl</*REFERENCE=*/true>(wallet, vCoins, coinControl, params);
}

int64_t FinalStakeReserveTarget(int64_t n)
{
    if (n <= 0) return 0;
    return std::min(MAX_FINAL_STAKE_RESERVE_OUTPUTS, (n + 1) / 2);
}

/** M and F for the reserve guard, or nullopt without a complete height schedule. */
static std::optional<int64_t> FinalStakeReserveLastMigrationHeight(const Consensus::Params& consensus)
{
    if (!consensus.UsesHeightLifecycle() || !consensus.IsMigrationEndScheduled() ||
        consensus.nQuantumMigrationEndHeight == std::numeric_limits<int>::max()) {
        return std::nullopt;
    }
    return int64_t{consensus.nQuantumMigrationEndHeight};
}

bool IsFinalStakeReserveGuardActive(const Consensus::Params& consensus, int candidate_height)
{
    const std::optional<int64_t> last = FinalStakeReserveLastMigrationHeight(consensus);
    if (!last) return false;
    return int64_t{candidate_height} >= *last + 1 - int64_t{consensus.nCoinbaseMaturity} && int64_t{candidate_height} <= *last;
}

FinalStakeReservePlan PlanFinalStakeReserve(std::vector<FinalStakeReserveSource> unspent, const std::set<COutPoint>& consumed)
{
    // One entry per outpoint, whatever the caller passed.
    std::set<COutPoint> distinct;
    unspent.erase(std::remove_if(unspent.begin(), unspent.end(),
                                 [&distinct](const FinalStakeReserveSource& source) { return !distinct.insert(source.outpoint).second; }),
                  unspent.end());
    std::sort(unspent.begin(), unspent.end(), [](const FinalStakeReserveSource& a, const FinalStakeReserveSource& b) {
        if (a.effective_value != b.effective_value) return a.effective_value > b.effective_value;
        return a.outpoint < b.outpoint; // transaction hash, then output index, both ascending
    });
    std::set<COutPoint> all(consumed);
    all.insert(distinct.begin(), distinct.end());

    FinalStakeReservePlan plan;
    plan.n = static_cast<int64_t>(all.size());
    plan.target = FinalStakeReserveTarget(plan.n);
    const size_t take = static_cast<size_t>(std::min<int64_t>(plan.target, static_cast<int64_t>(unspent.size())));
    plan.reserved.assign(unspent.begin(), unspent.begin() + take);
    plan.shortfall = plan.target - static_cast<int64_t>(take);
    return plan;
}

bool IsFinalStakeReserveSourceScript(const CWallet& wallet, const CScript& script)
{
    AssertLockHeld(wallet.cs_wallet);
    if (IsQuantumMigrationScript(script)) {
        return (wallet.IsMine(script) & ISMINE_SPENDABLE) != ISMINE_NO;
    }
    if (IsQuantumColdStakeScript(script)) {
        int witness_version{0};
        std::vector<unsigned char> witness_program;
        if (!script.IsWitnessProgram(witness_version, witness_program)) return false;
        const auto delegation = wallet.GetQuantumColdStakeDelegationInfo(witness_program);
        return delegation && delegation->has_staker_key;
    }
    return false;
}

std::set<COutPoint> FinalStakeReserveConsumedSources(const CWallet& wallet, int64_t first_guard_height, int64_t last_height,
                                                     int64_t last_source_height)
{
    AssertLockHeld(wallet.cs_wallet);
    std::set<COutPoint> consumed;
    for (const auto& entry : wallet.mapWallet) {
        const CWalletTx& wtx = entry.second;
        if (!wtx.tx || !wtx.tx->IsCoinStake()) continue;
        const TxStateConfirmed* confirmed = wtx.state<TxStateConfirmed>();
        if (!confirmed) continue;
        if (int64_t{confirmed->confirmed_block_height} < first_guard_height || int64_t{confirmed->confirmed_block_height} > last_height) continue;
        if (wallet.GetTxDepthInMainChain(wtx) <= 0) continue;
        for (const CTxIn& txin : wtx.tx->vin) {
            const auto parent_it = wallet.mapWallet.find(txin.prevout.hash);
            if (parent_it == wallet.mapWallet.end() || !parent_it->second.tx) continue;
            const CWalletTx& parent = parent_it->second;
            if (txin.prevout.n >= parent.tx->vout.size()) continue;
            const TxStateConfirmed* parent_state = parent.state<TxStateConfirmed>();
            if (!parent_state || int64_t{parent_state->confirmed_block_height} > last_source_height) continue;
            const CTxOut& out = parent.tx->vout[txin.prevout.n];
            if (out.nValue < wallet.m_min_staking_amount) continue;
            if (!IsFinalStakeReserveSourceScript(wallet, out.scriptPubKey)) continue;
            consumed.insert(txin.prevout);
        }
    }
    return consumed;
}

FinalStakeReserve ComputeFinalStakeReserve(const CWallet& wallet)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(wallet.cs_wallet);
    FinalStakeReserve reserve;
    reserve.enabled = gArgs.GetBoolArg("-finalstakereserve", DEFAULT_FINAL_STAKE_RESERVE);
    const Consensus::Params& consensus = Params().GetConsensus();
    const CBlockIndex* tip = wallet.chain().getTip();
    if (!tip) return reserve;
    reserve.candidate_height = tip->nHeight + 1;
    const std::optional<int64_t> last_migration = FinalStakeReserveLastMigrationHeight(consensus);
    if (!last_migration) return reserve;
    reserve.schedule_known = true;
    reserve.final_height = *last_migration + 1;
    reserve.guard_first_height = reserve.final_height - int64_t{consensus.nCoinbaseMaturity};
    if (!reserve.enabled || int64_t{reserve.candidate_height} > *last_migration) return reserve;
    reserve.active = int64_t{reserve.candidate_height} >= reserve.guard_first_height;

    // U: the staker's own candidate scan evaluated for the first Final block (maturity, lineage, covenants, locks and the
    // wallet's other staking requirements as they will be at F), restricted to the outputs the wallet stakes quantum with.
    std::vector<FinalStakeReserveSource> unspent;
    const int blocks_ahead = static_cast<int>(reserve.final_height - int64_t{reserve.candidate_height});
    const int64_t scan_time = tip->GetMedianTimePast();
    const StakeScanObserver observer = [&](const COutPoint& outpoint, const CWalletTx& wtx, bool eligible, StakeExclusion why) {
        const CScript& script = wtx.tx->vout[outpoint.n].scriptPubKey;
        const bool cold_stake = IsQuantumColdStakeScript(script);
        if (!IsQuantumMigrationScript(script) && !cold_stake) return;
        if (!eligible) {
            StakeExclusionTally& tally = reserve.excluded[why == StakeExclusion::NONE ? StakeExclusion::OTHER : why];
            ++tally.count;
            tally.value += wtx.tx->vout[outpoint.n].nValue;
            return;
        }
        if (!IsFinalStakeReserveSourceScript(wallet, script)) {
            if (cold_stake) {
                ++reserve.missing_staker_key.count;
                reserve.missing_staker_key.value += wtx.tx->vout[outpoint.n].nValue;
            }
            return;
        }
        CAmount principal{0};
        if (!GetCoinStakeInputPrincipal(wallet.chain().getCoinsTip(), outpoint, consensus, static_cast<int>(reserve.final_height),
                                        scan_time, principal)) {
            ++reserve.no_effective_value.count;
            reserve.no_effective_value.value += wtx.tx->vout[outpoint.n].nValue;
            return;
        }
        unspent.push_back({outpoint, principal});
    };
    std::vector<std::pair<const CWalletTx*, unsigned int>> scanned;
    CCoinControl coin_control;
    AvailableCoinsForStakingAhead(wallet, scanned, &coin_control, CoinFilterParams{}, blocks_ahead, observer);

    // S: sources already consumed by this wallet's confirmed coinstakes since the guard began; a source qualifies when it
    // was created at or before F - maturity.
    const std::set<COutPoint> consumed = FinalStakeReserveConsumedSources(
        wallet, reserve.guard_first_height, *last_migration, reserve.guard_first_height);

    for (const FinalStakeReserveSource& source : unspent) reserve.eligible_weight += source.effective_value;
    reserve.eligible_count = static_cast<int64_t>(unspent.size());
    reserve.consumed = static_cast<int64_t>(consumed.size());
    FinalStakeReservePlan plan = PlanFinalStakeReserve(std::move(unspent), consumed);
    reserve.n = plan.n;
    reserve.target = plan.target;
    reserve.shortfall = plan.shortfall;
    reserve.reserved = std::move(plan.reserved);
    for (const FinalStakeReserveSource& source : reserve.reserved) {
        reserve.reserved_weight += source.effective_value;
        if (reserve.active) reserve.enforced.insert(source.outpoint);
    }
    return reserve;
}

std::set<COutPoint> FinalStakeReserveEnforcedOutpoints(const CWallet& wallet)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(wallet.cs_wallet);
    if (!gArgs.GetBoolArg("-finalstakereserve", DEFAULT_FINAL_STAKE_RESERVE)) return {};
    const CBlockIndex* tip = wallet.chain().getTip();
    if (!tip || !IsFinalStakeReserveGuardActive(Params().GetConsensus(), tip->nHeight + 1)) return {};
    return ComputeFinalStakeReserve(wallet).enforced;
}

bool SpendsFinalStakeReserve(CWallet& wallet, const CTransaction& tx)
{
    LOCK2(::cs_main, wallet.cs_wallet);
    const std::set<COutPoint> reserve = FinalStakeReserveEnforcedOutpoints(wallet);
    if (reserve.empty()) return false;
    return std::any_of(tx.vin.begin(), tx.vin.end(), [&reserve](const CTxIn& txin) { return reserve.count(txin.prevout) > 0; });
}

const char* StakeExclusionName(StakeExclusion reason)
{
    switch (reason) {
    case StakeExclusion::NONE: return "none";
    case StakeExclusion::IMMATURE: return "immature";
    case StakeExclusion::LOCKED: return "locked";
    case StakeExclusion::BELOW_MINIMUM: return "below_minimum";
    case StakeExclusion::SIGNER_UNAVAILABLE: return "signer_unavailable";
    case StakeExclusion::OTHER: return "other";
    }
    return "other";
}

QuantumStakeReadiness AssessQuantumStakeReadiness(const CWallet& wallet)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(wallet.cs_wallet);
    const Consensus::Params& consensus = Params().GetConsensus();
    const CBlockIndex* tip = wallet.chain().getTip();

    QuantumStakeReadiness result;
    result.next_height = tip ? tip->nHeight + 1 : 0;
    // A Final height needs a complete height-authoritative schedule. A time-only schedule (or none)
    // gives no block count, so it is reported as unknown instead of as a height made of default values.
    result.final_height_known = consensus.UsesHeightLifecycle() && consensus.IsMigrationEndScheduled() &&
                                consensus.nQuantumMigrationEndHeight < std::numeric_limits<int>::max();
    result.final_height = result.final_height_known ? consensus.nQuantumMigrationEndHeight + 1 : 0;
    const int blocks_ahead_final = result.final_height_known && result.final_height > result.next_height
        ? result.final_height - result.next_height : 0;
    result.blocks_to_final = blocks_ahead_final;
    result.wallet_locked = wallet.IsLocked();
    result.staking_only_unlock = wallet.m_wallet_unlock_staking_only;
    result.reserve_balance = wallet.m_reserve_balance;
    result.min_stake_amount = wallet.m_min_staking_amount;
    result.stake_return = ResolveLegacyStakeQuantumReturn(wallet);
    result.final_reserve = ComputeFinalStakeReserve(wallet);
    // A fully locked wallet has no signing key available: the staker idles
    // (ThreadStakeMiner waits while IsLocked), so nothing it would select can stake.
    const bool cannot_sign = wallet.IsLocked() || wallet.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS);
    const int64_t scan_time = tip ? tip->GetMedianTimePast() : 0;

    const auto scan = [&](int blocks_ahead, StakeHorizonReadiness& horizon, bool count_total) {
        horizon.height = result.next_height + blocks_ahead;
        CAmount legacy_eligible{0};
        std::vector<CAmount> effective_principals; // of each selected quantum output, in the scan's order
        std::vector<std::pair<const CWalletTx*, unsigned int>> coins;
        CCoinControl coin_control;
        // The very scan the staker runs (SelectCoinsForStaking); the observer only listens.
        const StakeScanObserver observer = [&](const COutPoint& outpoint, const CWalletTx& wtx, bool eligible, StakeExclusion why) {
            const CTxOut& out = wtx.tx->vout[outpoint.n];
            const bool quantum = IsQuantumMigrationScript(out.scriptPubKey) || IsQuantumColdStakeScript(out.scriptPubKey);
            if (quantum && count_total) {
                ++result.quantum_outputs;
                result.quantum_total += out.nValue;
            }
            if (eligible && cannot_sign) {
                eligible = false;
                why = StakeExclusion::SIGNER_UNAVAILABLE;
            }
            if (eligible) {
                if (quantum) {
                    ++horizon.eligible_outputs;
                    horizon.eligible_nominal += out.nValue;
                    CAmount principal{0};
                    // The constructor's own principal, for the block this describes; a coin it cannot
                    // use (locked by demurrage, no value left) contributes none and cannot be a kernel.
                    if (!GetCoinStakeInputPrincipal(wallet.chain().getCoinsTip(), outpoint, consensus, horizon.height,
                                                    scan_time, principal)) {
                        principal = 0;
                    }
                    effective_principals.push_back(principal);
                    horizon.eligible_effective += principal;
                } else {
                    legacy_eligible += out.nValue;
                }
            } else if (quantum) {
                StakeExclusionTally& tally = horizon.excluded[why];
                ++tally.count;
                tally.value += out.nValue;
            }
        };
        AvailableCoinsForStakingAhead(wallet, coins, &coin_control, CoinFilterParams{}, blocks_ahead, observer);
        // The constructor's condition (CreateCoinStake): the selected set must exceed the reserve, a kernel
        // is one output, and its principal may not exceed what is left of the set after the reserve.
        horizon.candidate_total = legacy_eligible + horizon.eligible_nominal;
        horizon.allowed_balance = horizon.candidate_total > wallet.m_reserve_balance
            ? horizon.candidate_total - wallet.m_reserve_balance : 0;
        for (const CAmount principal : effective_principals) {
            if (principal <= 0 || principal > horizon.allowed_balance) continue;
            ++horizon.stakeable_outputs;
            horizon.stakeable_effective += principal;
            horizon.largest_kernel = std::max(horizon.largest_kernel, principal);
        }
    };
    scan(0, result.next_block, /*count_total=*/true);
    if (!result.final_height_known) {
        result.at_final = StakeHorizonReadiness{};
    } else if (blocks_ahead_final > 0) {
        scan(blocks_ahead_final, result.at_final, /*count_total=*/false);
    } else {
        result.at_final = result.next_block;
    }

    // Legacy coins that still have to move: spendable now (the migration sweep's
    // own candidates) plus those it cannot consider yet.
    std::set<COutPoint> considered;
    const int next_height = result.next_height;
    for (const COutput& out : AvailableCoinsListUnspent(wallet).All()) {
        const CScript& spk = out.txout.scriptPubKey;
        if (IsQuantumMigrationScript(spk) || IsQuantumColdStakeScript(spk) || IsEUTXOScript(spk) || !out.spendable) continue;
        considered.insert(out.outpoint);
        ++result.legacy_outputs;
        result.legacy_to_migrate += out.txout.nValue;
    }
    const ExcludedLegacyOutputs excluded = FindExcludedLegacyOutputs(wallet, considered, consensus, next_height);
    result.legacy_outputs += excluded.count;
    result.legacy_to_migrate += excluded.amount;
    return result;
}

// Publish the stake weight of a completed full scan for status RPC/GUI readers.
static void PublishCachedStakeWeight(const CWallet& wallet, CAmount value_in)
{
    const CAmount available = value_in > wallet.m_reserve_balance
        ? value_in - wallet.m_reserve_balance
        : 0;
    // Publish the cache pair under the same mutex used to assemble the
    // typed staking snapshot. The atomics keep legacy low-latency readers
    // available, while telemetry never combines weight from one scan with
    // the height from another.
    LOCK(wallet.m_staking_telemetry_mutex);
    wallet.m_cached_stake_weight.store(static_cast<uint64_t>(available), std::memory_order_relaxed);
    const CBlockIndex* tip = wallet.chain().getTip();
    wallet.m_cached_stake_weight_height.store(tip ? tip->nHeight : -1, std::memory_order_release);
}

// Select some coins without random shuffle or best subset approximation
bool SelectCoinsForStaking(const CWallet& wallet, CAmount& nTargetValue, std::set<std::pair<const CWalletTx *, unsigned int> > &setCoinsRet, CAmount& nValueRet)
{
    std::vector<std::pair<const CWalletTx*, unsigned int> > vCoins;
    CCoinControl coincontrol;
    AvailableCoinsForStaking(wallet, vCoins, &coincontrol);

    setCoinsRet.clear();
    nValueRet = 0;

    for (const std::pair<const CWalletTx*, unsigned int> &output : vCoins)
    {

        const CWalletTx *pcoin = output.first;
        int i = output.second;

        // Stop if we've chosen enough inputs
        if (nValueRet >= nTargetValue)
            break;

        int64_t n = pcoin->tx->vout[i].nValue;

        std::pair<int64_t,std::pair<const CWalletTx*,unsigned int> > coin = std::make_pair(n,std::make_pair(pcoin, i));

        if (n >= nTargetValue)
        {
            // If input value is greater or equal to target then simply insert
            // it into the current subset and exit
            setCoinsRet.insert(coin.second);
            nValueRet += coin.first;
            break;
        }
        else if (n < nTargetValue + CENT)
        {
            setCoinsRet.insert(coin.second);
            nValueRet += coin.first;
        }
    }

    // Both current callers request the complete staking set. Publish that
    // completed scan for status RPC/GUI readers so they never need to repeat
    // the O(wallet history) walk on a latency-sensitive thread.
    if (nTargetValue == MAX_MONEY) PublishCachedStakeWeight(wallet, nValueRet);

    return true;
}

std::atomic<bool> g_stake_slot_cache_enabled{true};

StakeSlotCacheState& CWallet::GetStakeSlotCacheStateLocked() const
{
    AssertLockHeld(cs_wallet);
    if (!m_stake_slot_cache) m_stake_slot_cache = std::make_shared<StakeSlotCacheState>();
    return *m_stake_slot_cache;
}

void DropStakeSlotCache(const CWallet& wallet)
{
    AssertLockHeld(wallet.cs_wallet);
    wallet.GetStakeSlotCacheStateLocked().cache.reset();
}

/** True while every input of the selection is what the cache was built from. */
static bool StakeSlotCacheIsCurrent(const CWallet& wallet, const StakeSlotCache& cache, const CBlockIndex* tip)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    return cache.tip_hash == tip->GetBlockHash() &&
           cache.live_generation == wallet.GetLiveUnspentStakeGenerationLocked() &&
           cache.balance_marker == wallet.GetBalanceScanMarker() &&
           cache.coin_lock_generation == wallet.GetCoinLockGenerationLocked() &&
           cache.wallet_locked == wallet.IsLocked() &&
           cache.staking_only == wallet.m_wallet_unlock_staking_only.load() &&
           cache.protected_rgb_seals == wallet.GetProtectedRGBSeals() &&
           cache.final_reserve_enabled == gArgs.GetBoolArg("-finalstakereserve", DEFAULT_FINAL_STAKE_RESERVE) &&
           std::chrono::steady_clock::now() - cache.built_at < STAKE_SLOT_CACHE_MAX_AGE;
}

static std::shared_ptr<StakeSlotCache> BuildStakeSlotCache(const CWallet& wallet, CBlockIndex* tip, bool with_kernels)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet)
{
    auto cache = std::make_shared<StakeSlotCache>();
    cache->tip_hash = tip->GetBlockHash();
    cache->live_generation = wallet.GetLiveUnspentStakeGenerationLocked();
    cache->balance_marker = wallet.GetBalanceScanMarker();
    cache->coin_lock_generation = wallet.GetCoinLockGenerationLocked();
    cache->wallet_locked = wallet.IsLocked();
    cache->staking_only = wallet.m_wallet_unlock_staking_only.load();
    cache->protected_rgb_seals = wallet.GetProtectedRGBSeals();
    cache->final_reserve_enabled = gArgs.GetBoolArg("-finalstakereserve", DEFAULT_FINAL_STAKE_RESERVE);
    cache->built_at = std::chrono::steady_clock::now();
    CAmount target{MAX_MONEY};
    SelectCoinsForStaking(wallet, target, cache->coins, cache->value_in);
    // The final stake reserve of this tip: outputs the staker must leave alone while the guard is on. They stay in
    // `coins` (the selection is what the status weight reports), and every user of the cache skips them.
    if (cache->final_reserve_enabled && IsFinalStakeReserveGuardActive(Params().GetConsensus(), tip->nHeight + 1)) {
        FinalStakeReserve reserve = ComputeFinalStakeReserve(wallet);
        cache->final_reserve_active = reserve.active;
        cache->final_reserve = std::move(reserve.enforced);
        for (const auto& [wtx, n] : cache->coins) {
            if (cache->final_reserve.count(COutPoint{wtx->GetHash(), n})) cache->final_reserve_value += wtx->tx->vout[n].nValue;
        }
    }
    // Under demurrage a kernel value depends on the live coin view, which
    // CheckKernel reads per call whatever the cache holds.
    if (with_kernels &&
        !Params().GetConsensus().IsDemurrageActive(tip->nHeight + 1, tip->GetMedianTimePast())) {
        CCoinsViewCache& view = wallet.chain().getCoinsTip();
        for (const auto& [wtx, n] : cache->coins) {
            CacheKernel(cache->kernels, COutPoint{wtx->GetHash(), n}, tip, view);
        }
    }
    return cache;
}

std::shared_ptr<const StakeSlotCache> AcquireStakeSlotCache(const CWallet& wallet, CBlockIndex* tip)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(wallet.cs_wallet);
    StakeSlotCacheState& state = wallet.GetStakeSlotCacheStateLocked();
    if (!g_stake_slot_cache_enabled.load()) {
        // Select as before the cache existed and leave the stored one alone;
        // it is checked against its key before it is ever served again.
        return BuildStakeSlotCache(wallet, tip, /*with_kernels=*/false);
    }
    if (state.cache && StakeSlotCacheIsCurrent(wallet, *state.cache, tip)) {
        ++state.stats.hits;
        PublishCachedStakeWeight(wallet, state.cache->value_in);
        return state.cache;
    }
    state.cache = BuildStakeSlotCache(wallet, tip, /*with_kernels=*/true);
    ++state.stats.rebuilds;
    return state.cache;
}

StakeSlotKernel CheckStakeSlotKernel(const CWallet& wallet, const StakeSlotCache& slot, CBlockIndex* tip,
                                     unsigned int nBits, uint32_t nTime, const COutPoint& prevout)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(wallet.cs_wallet);
    CCoinsViewCache& view = wallet.chain().getCoinsTip();
    if (!CheckKernel(tip, nBits, nTime, prevout, view, slot.kernels)) return StakeSlotKernel::NONE;
    // The slot's candidate selection may come from the cache, so a kernel is
    // only reported once a fresh uncached selection gives the same candidates.
    // This holds on every path: an output with no kernel entry (every output
    // once demurrage is active, any CacheKernel miss) was checked against the
    // coins view above, but its membership in the selection still rests on the
    // cache. An output with an entry is also confirmed against the coins view
    // the way validation would see it.
    const bool has_entry = slot.kernels.find(prevout) != slot.kernels.end();
    bool confirmed = !has_entry || CheckKernel(tip, nBits, nTime, prevout, view);
    if (confirmed) {
        std::set<std::pair<const CWalletTx*, unsigned int>> fresh;
        CAmount fresh_value{0};
        CAmount target{MAX_MONEY};
        SelectCoinsForStaking(wallet, target, fresh, fresh_value);
        confirmed = fresh == slot.coins && fresh_value == slot.value_in;
    }
    if (confirmed && slot.final_reserve_active) {
        // The reserve is derived from the wallet and the chain, so a kernel is only reported once a fresh derivation
        // agrees with the cached one, and never from an output that is in it.
        const std::set<COutPoint> fresh_reserve = ComputeFinalStakeReserve(wallet).enforced;
        if (fresh_reserve != slot.final_reserve) {
            confirmed = false;
        } else if (fresh_reserve.count(prevout)) {
            return StakeSlotKernel::NONE;
        }
    }
    if (!confirmed) {
        StakeSlotCacheState& state = wallet.GetStakeSlotCacheStateLocked();
        ++state.stats.rejections;
        state.cache.reset();
        LogPrint(BCLog::COINSTAKE, "CheckStakeSlotKernel : cached kernel for %s not confirmed, cache dropped\n", prevout.ToString());
        return StakeSlotKernel::CACHE_REJECTED;
    }
    return StakeSlotKernel::FOUND;
}

std::vector<StakeKernelHit> ScanStakeKernels(const CWallet& wallet, unsigned int nBits, uint32_t nTime,
                                             int64_t nSearchInterval, bool use_cache, bool* rejected)
{
    AssertLockHeld(::cs_main);
    AssertLockHeld(wallet.cs_wallet);
    if (rejected) *rejected = false;
    std::vector<StakeKernelHit> hits;
    CBlockIndex* tip = wallet.chain().getTip();
    if (!tip) return hits;
    const bool previous = g_stake_slot_cache_enabled.exchange(use_cache);
    const auto slot = AcquireStakeSlotCache(wallet, tip);
    g_stake_slot_cache_enabled.store(previous);
    for (const auto& [wtx, n] : slot->coins) {
        const COutPoint prevout{wtx->GetHash(), n};
        for (unsigned int i = 0; i < std::min<int64_t>(nSearchInterval, 60); ++i) {
            const StakeSlotKernel result = CheckStakeSlotKernel(wallet, *slot, tip, nBits, nTime - i, prevout);
            if (result == StakeSlotKernel::CACHE_REJECTED) {
                if (rejected) *rejected = true;
                return hits;
            }
            if (result == StakeSlotKernel::FOUND) {
                hits.push_back({prevout, nTime - i});
                break;
            }
        }
    }
    return hits;
}

// peercoin: create coin stake transaction
typedef std::vector<unsigned char> valtype;
std::string LegacyReturnWindowCoinstakeProblem(const CMutableTransaction& coinstake, bool returns_to_quantum,
                                               const LegacyStakeQuantumReturn& legacy_return)
{
    if (!returns_to_quantum || !legacy_return.available) {
        return "refusing a legacy-return coinstake in the quantum return window";
    }
    size_t valued_outputs{0};
    for (size_t i = 1; i < coinstake.vout.size(); ++i) {
        if (coinstake.vout[i].nValue == 0) continue;
        ++valued_outputs;
        if (coinstake.vout[i].scriptPubKey != legacy_return.script) {
            return "a legacy kernel in the quantum return window may pay only its quantum return output";
        }
    }
    if (valued_outputs != 1) {
        return "a legacy kernel in the quantum return window must pay exactly one output";
    }
    return "";
}

bool CreateCoinStake(CWallet& wallet, unsigned int nBits, int64_t nSearchInterval,
                     CMutableTransaction& txNew, CAmount& nFees,
                     CTxDestination destination,
                     const std::vector<CTransactionRef>& selected_txs,
                     std::optional<COutPoint> forced_kernel)
{
    arith_uint256 bnTargetPerCoinDay;
    bnTargetPerCoinDay.SetCompact(nBits);

    LOCK(cs_main);
    TRY_LOCK(wallet.cs_wallet, wallet_lock);
    if (!wallet_lock) {
        // Wallet RPCs and coin selection may need short active-chain queries.
        // Never wait here while holding cs_main; skip this staking iteration
        // and let the next kernel interval retry.
        return false;
    }
    CBlockIndex* pindexPrev = wallet.chain().getTip();
    if (!pindexPrev) return false;
    txNew.vin.clear();
    txNew.vout.clear();

    // Mark coin stake transaction
    CScript scriptEmpty;
    scriptEmpty.clear();
    txNew.vout.push_back(CTxOut(0, scriptEmpty));

    std::vector<CTransactionRef> vwtxPrev;
    CAmount nValueIn = 0;
    const int64_t stake_mtp = pindexPrev->GetMedianTimePast();
    const int stake_height = pindexPrev->nHeight + 1;
    const Consensus::Params& consensus = Params().GetConsensus();
    const bool quantum_stake_rules_active = IsQuantumWitnessSpendActive(consensus, stake_mtp, stake_height);
    const bool final_quantum_lockout = consensus.IsQuantumFinalLockout(stake_mtp, stake_height);
    const bool stake_reward_split_active = consensus.IsStakeRewardSplitActive(stake_height);
    // In the quantum return window a legacy kernel pays one quantum output of
    // this wallet (principal plus reward, nothing else). Checked here as well
    // as in the candidate filter. Without a ready return address, or if an exact
    // reward split (which fixes the return script) were already active, no
    // legacy kernel may stake: a legacy-return coinstake this late could never
    // be spent before Final.
    const bool legacy_mandatory_window = IsLegacyStakeBarredByMigrationEnd(consensus, stake_height);
    // Earlier, in the opportunistic window, a legacy self-stake is also paid as one quantum output, but only while a
    // return destination is ready (and no exact reward split fixes the return script); without one it stakes as
    // it always did. The mandatory predicate above is never widened by it.
    const bool legacy_opportunistic_window = IsLegacyStakeInOpportunisticReturnWindow(consensus, stake_height);
    const LegacyStakeQuantumReturn legacy_return = (legacy_mandatory_window || legacy_opportunistic_window)
        ? ResolveLegacyStakeQuantumReturn(wallet) : LegacyStakeQuantumReturn{};
    const bool legacy_stake_barred = legacy_mandatory_window && (!legacy_return.available || stake_reward_split_active);
    const bool legacy_in_window = legacy_mandatory_window ||
        (legacy_opportunistic_window && legacy_return.available && !stake_reward_split_active);
    bool fReturnToQuantum = false;

    // Select coins with suitable depth. The selection and the kernel inputs
    // are shared by every slot of this tip (see StakeSlotCache).
    const std::shared_ptr<const StakeSlotCache> stake_slot = AcquireStakeSlotCache(wallet, pindexPrev);
    const std::set<std::pair<const CWalletTx*, unsigned int>>& setCoins = stake_slot->coins;
    // The final stake reserve is not available to this coinstake: not as the kernel, not as an added input, and not
    // as value the reserve balance may be taken from.
    const std::set<COutPoint>& final_reserve = stake_slot->final_reserve;
    nValueIn = stake_slot->value_in - stake_slot->final_reserve_value;

    if (setCoins.empty() || nValueIn <= wallet.m_reserve_balance)
        return false;

    CAmount nAllowedBalance = nValueIn - wallet.m_reserve_balance;

    // Reserve both transaction inputs and demurrage-attestation targets. The
    // target is not spent by its attestation, but consensus requires it to
    // remain live at the end of the block. A coinstake must therefore not use
    // it as either its kernel or an aggregated input.
    std::set<COutPoint> selected_tx_reserved_outpoints;
    for (const CTransactionRef& tx : selected_txs) {
        if (!tx) continue;
        for (const CTxIn& txin : tx->vin) {
            if (!txin.prevout.IsNull()) selected_tx_reserved_outpoints.insert(txin.prevout);
        }
        for (const Consensus::DemurrageAttestation& attestation : Consensus::ExtractDemurrageAttestations(*tx)) {
            if (attestation.height >= 0 && !attestation.target_outpoint.IsNull()) {
                selected_tx_reserved_outpoints.insert(attestation.target_outpoint);
            }
        }
    }

    CAmount nCredit = 0;
    bool fKernelFound = false;
    CScript scriptPubKeyKernel, scriptPubKeyOut;
    bool bMinterKey = false;
    bool fQuantumKernel = false;
    bool fQuantumColdStakeKernel = false;
    CScript operatorRewardScript;

    for (const std::pair<const CWalletTx*, unsigned int> &pcoin : setCoins)
    {
        const COutPoint prevoutStake{pcoin.first->GetHash(), pcoin.second};
        if (forced_kernel && prevoutStake != *forced_kernel) continue;
        if (selected_tx_reserved_outpoints.count(prevoutStake)) continue;
        if (final_reserve.count(prevoutStake)) continue;
        if (final_quantum_lockout &&
            !IsQuantumMigrationScript(pcoin.first->tx->vout[pcoin.second].scriptPubKey) &&
            !IsQuantumColdStakeScript(pcoin.first->tx->vout[pcoin.second].scriptPubKey)) {
            continue;
        }
        if (legacy_stake_barred &&
            !IsQuantumMigrationScript(pcoin.first->tx->vout[pcoin.second].scriptPubKey) &&
            !IsQuantumColdStakeScript(pcoin.first->tx->vout[pcoin.second].scriptPubKey)) {
            continue;
        }

        CTransactionRef tx = pcoin.first->tx;
        if (!tx) {
            LogPrint(BCLog::COINSTAKE, "CreateCoinStake : wallet transaction unavailable for %s\n", pcoin.first->GetHash().ToString());
            continue;
        }

        static int nMaxStakeSearchInterval = 60;
        for (unsigned int n=0; n<std::min(nSearchInterval,(int64_t)nMaxStakeSearchInterval) && !fKernelFound; n++)
        {
            // Search backward in time from the given txNew timestamp
            // Search nSearchInterval seconds back up to nMaxStakeSearchInterval
            const uint32_t kernel_time = txNew.nTime - n;
            const StakeSlotKernel kernel_result = CheckStakeSlotKernel(wallet, *stake_slot, pindexPrev, nBits, kernel_time, prevoutStake);
            // The cache is dropped; the next slot rebuilds it from scratch.
            if (kernel_result == StakeSlotKernel::CACHE_REJECTED) return false;
            if (kernel_result == StakeSlotKernel::FOUND)
            {
                CAmount kernel_principal{0};
                if (!GetCoinStakeInputPrincipal(wallet.chain().getCoinsTip(), prevoutStake, consensus, pindexPrev->nHeight + 1, stake_mtp, kernel_principal)) {
                    LogPrint(BCLog::COINSTAKE, "CreateCoinStake : skipping kernel with no demurrage-effective principal\n");
                    break;
                }
                // Found a kernel
                LogPrint(BCLog::COINSTAKE, "CreateCoinStake : kernel found\n");
                std::vector<valtype> vSolutions;
                scriptPubKeyKernel = pcoin.first->tx->vout[pcoin.second].scriptPubKey;
                TxoutType whichType = Solver(scriptPubKeyKernel, vSolutions);
                const bool quantum_migration_kernel = IsQuantumMigrationScript(scriptPubKeyKernel);
                const bool quantum_coldstake_kernel = IsQuantumColdStakeScript(scriptPubKeyKernel);
                const bool quantum_kernel = quantum_migration_kernel || quantum_coldstake_kernel;
                if (quantum_kernel && !quantum_stake_rules_active)
                {
                    LogPrint(BCLog::COINSTAKE, "CreateCoinStake : skipping quantum kernel before new-network staking is active\n");
                    break;
                }

                if (!quantum_kernel && legacy_stake_barred)
                {
                    LogPrint(BCLog::COINSTAKE, "CreateCoinStake : skipping legacy kernel that could not mature before Final\n");
                    break;
                }
                if (!quantum_kernel && whichType != TxoutType::PUBKEY && whichType != TxoutType::PUBKEYHASH && whichType != TxoutType::WITNESS_V0_KEYHASH && whichType != TxoutType::WITNESS_V1_TAPROOT)
                {
                    LogPrint(BCLog::COINSTAKE, "CreateCoinStake : no support for kernel type=%s\n", GetTxnOutputType(whichType));
                    break;  // only support pay to public key and pay to address and pay to witness keyhash
                }
                if (quantum_kernel)
                {
                    int witness_version{0};
                    std::vector<unsigned char> witness_program;
                    const bool parsed_quantum = scriptPubKeyKernel.IsWitnessProgram(witness_version, witness_program) &&
                                                (IsQuantumMigrationWitnessProgram(witness_version, witness_program) ||
                                                 IsQuantumColdStakeWitnessProgram(witness_version, witness_program));
                    CHECK_NONFATAL(parsed_quantum);
                    std::vector<unsigned char> quantum_pubkey;
                    CKeyingMaterial quantum_private_key;
                    bilingual_str error;
                    std::vector<unsigned char> signing_program = witness_program;
                    if (quantum_coldstake_kernel) {
                        const auto delegation = wallet.GetQuantumColdStakeDelegationInfo(witness_program);
                        if (!delegation || !delegation->has_staker_key) {
                            LogPrint(BCLog::COINSTAKE, "CreateCoinStake : skipping quantum cold-stake kernel without loaded staker delegation metadata\n");
                            break;
                        }
                        signing_program.assign(delegation->staker_pubkey_hash.begin(), delegation->staker_pubkey_hash.end());
                    }
                    if (!wallet.GetQuantumKey(signing_program, quantum_pubkey, quantum_private_key, error)) {
                        LogPrint(BCLog::COINSTAKE, "CreateCoinStake : failed to get quantum key for output %s: %s\n", pcoin.first->tx->vout[pcoin.second].ToString(), error.original);
                        break;
                    }
                    if (quantum_coldstake_kernel) {
                        operatorRewardScript = GetScriptForDestination(WitnessUnknown{
                            QUANTUM_MIGRATION_WITNESS_VERSION,
                            QuantumMigrationProgramForPubkey(quantum_pubkey)});
                    }
                    scriptPubKeyOut << OP_RETURN << quantum_pubkey;
                    bMinterKey = true;
                }
                else if (whichType == TxoutType::PUBKEYHASH) // pay to address
                {
                    // convert to pay to public key type
                    CKey key;
                    if (wallet.IsLegacy()) {
                        auto scriptPubKeyMan = wallet.GetLegacyScriptPubKeyMan();
                        if (!scriptPubKeyMan) {
                            LogPrint(BCLog::COINSTAKE, "CreateCoinStake : failed to get scriptpubkeyman for kernel type=%s\n", GetTxnOutputType(whichType));
                            break;  // unable to find corresponding public key
                        }
                        if (!scriptPubKeyMan->GetKey(CKeyID(uint160(vSolutions[0])), key))
                        {
                            LogPrint(BCLog::COINSTAKE, "CreateCoinStake : failed to get key for kernel type=%s\n", GetTxnOutputType(whichType));
                            break;  // unable to find corresponding public key
                        }
                        scriptPubKeyOut << ToByteVector(key.GetPubKey()) << OP_CHECKSIG;
                    }
                    else {
                        std::unique_ptr<SigningProvider> provider = wallet.GetSolvingProvider(scriptPubKeyKernel);
                        if (!provider) {
                            LogPrint(BCLog::COINSTAKE, "CreateCoinStake : failed to get signing provider for output %s\n", pcoin.first->tx->vout[pcoin.second].ToString());
                            break;
                        }
                        CKeyID ckey = CKeyID(uint160(vSolutions[0]));
                        CPubKey pkey;
                        if (!provider.get()->GetPubKey(ckey, pkey)) {
                            LogPrint(BCLog::COINSTAKE, "CreateCoinStake : failed to get key for output %s\n", pcoin.first->tx->vout[pcoin.second].ToString());
                            break;
                        }
                        scriptPubKeyOut << ToByteVector(pkey) << OP_CHECKSIG;
                    }
                }
                else if (whichType == TxoutType::PUBKEY)
                    scriptPubKeyOut = scriptPubKeyKernel;
                else if (whichType == TxoutType::WITNESS_V0_KEYHASH || whichType == TxoutType::WITNESS_V1_TAPROOT) // pay to witness keyhash
                {
                    std::vector<valtype> vSolutionsTmp;
                    CScript scriptPubKeyTmp = GetScriptForDestination(destination);
                    Solver(scriptPubKeyTmp, vSolutionsTmp);
                    std::unique_ptr<SigningProvider> provider = wallet.GetSolvingProvider(scriptPubKeyTmp);
                    if (!provider) {
                        LogPrint(BCLog::COINSTAKE, "CreateCoinStake : failed to get signing provider for output %s\n", pcoin.first->tx->vout[pcoin.second].ToString());
                        break;
                    }
                    CKeyID ckey = CKeyID(uint160(vSolutionsTmp[0]));
                    CPubKey pkey;
                    if (!provider.get()->GetPubKey(ckey, pkey)) {
                        LogPrint(BCLog::COINSTAKE, "CreateCoinStake : failed to get key for output %s\n", pcoin.first->tx->vout[pcoin.second].ToString());
                        break;
                    }
                    scriptPubKeyOut << ToByteVector(pkey) << OP_CHECKSIG;
                    bMinterKey = true;
                }

                if (!quantum_kernel && legacy_in_window) {
                    // The legacy key stays the block-signing key (the value-0
                    // minter output); the value goes to the quantum output.
                    bMinterKey = true;
                    fReturnToQuantum = true;
                }

                txNew.nTime = kernel_time;
                txNew.vin.push_back(CTxIn(pcoin.first->GetHash(), pcoin.second));
                nCredit += kernel_principal;
                vwtxPrev.push_back(tx);
                fQuantumKernel = quantum_kernel;
                fQuantumColdStakeKernel = quantum_coldstake_kernel;

                if (bMinterKey) {
                    // extra output for minter key
                    txNew.vout.push_back(CTxOut(0, scriptPubKeyOut));
                    // redefine scriptPubKeyOut to send output to input address
                    // (or, for a legacy kernel in the window, to the quantum return)
                    scriptPubKeyOut = fReturnToQuantum ? legacy_return.script : scriptPubKeyKernel;
                }
    
                txNew.vout.push_back(CTxOut(0, scriptPubKeyOut));
                LogPrint(BCLog::COINSTAKE, "CreateCoinStake : added kernel type=%d\n", (int)whichType);
                fKernelFound = true;
                break;
            }
        }
        if (fKernelFound)
            break; // if kernel is found stop searching
    }
    if (!fKernelFound)
        return false;
    if (nCredit == 0 || nCredit > nAllowedBalance)
        return false;

    for (const std::pair<const CWalletTx*, unsigned int> &pcoin : setCoins)
    {
        if (selected_tx_reserved_outpoints.count(COutPoint(pcoin.first->GetHash(), pcoin.second))) continue;
        if (final_reserve.count(COutPoint(pcoin.first->GetHash(), pcoin.second))) continue;
        CTransactionRef tx = pcoin.first->tx;
        if (!tx) {
            LogPrint(BCLog::COINSTAKE, "CreateCoinStake : wallet transaction unavailable for %s\n", pcoin.first->GetHash().ToString());
            continue;
        }

        // Attempt to add more inputs
        // Only add coins of the same key/address as kernel
        if (txNew.vout.size() == 2 && ((pcoin.first->tx->vout[pcoin.second].scriptPubKey == scriptPubKeyKernel || pcoin.first->tx->vout[pcoin.second].scriptPubKey == txNew.vout[1].scriptPubKey))
            && pcoin.first->GetHash() != txNew.vin[0].prevout.hash)
        {
            // Stop adding more inputs if already too many inputs
            if (txNew.vin.size() >= 10)
                break;
            // Stop adding more inputs if value is already pretty significant
            if (nCredit >= GetStakeCombineThreshold())
                break;
            const COutPoint candidate_outpoint(pcoin.first->GetHash(), pcoin.second);
            CAmount candidate_principal{0};
            if (!GetCoinStakeInputPrincipal(wallet.chain().getCoinsTip(), candidate_outpoint, consensus, pindexPrev->nHeight + 1, stake_mtp, candidate_principal))
                continue;
            // Stop adding inputs if reached reserve limit
            if (nCredit + candidate_principal > nAllowedBalance)
                break;
            // Do not add additional significant input
            if (candidate_principal >= GetStakeCombineThreshold())
                continue;

            txNew.vin.push_back(CTxIn(pcoin.first->GetHash(), pcoin.second));
            nCredit += candidate_principal;
            vwtxPrev.push_back(tx);
        }
    }

    // Calculate reward. Before the stake-reward split activates, V4 cold-stake
    // delegation is deliberately less profitable than self-staking.
    const bool fColdStakeReward = quantum_stake_rules_active && CoinStakeSpendsKnownColdStake(wallet, txNew, vwtxPrev);
    CAmount nReward = 0;
    CAmount nOperatorCredit = 0;
    if (stake_reward_split_active) {
        const CAmount base_reward = GetProofOfStakeSubsidy();
        if (fColdStakeReward) {
            if (!fQuantumColdStakeKernel || operatorRewardScript.empty()) {
                return error("CreateCoinStake : missing operator reward script for cold-stake reward split");
            }
            const CAmount operator_floor = (base_reward * 5) / 100;
            nOperatorCredit = std::max(operator_floor, nFees);
            const CAmount operator_shortfall = nOperatorCredit > nFees ? nOperatorCredit - nFees : 0;
            if (operator_shortfall > base_reward) {
                return error("CreateCoinStake : invalid operator reward split");
            }
            nReward = base_reward - operator_shortfall;
            LogPrint(BCLog::COINSTAKE, "CreateCoinStake : cold-stake split applied delegator_reward=%d operator_comp=%d fees=%d\n", nReward, nOperatorCredit, nFees);
        } else {
            nReward = nFees + base_reward;
        }
    } else {
        nReward = nFees + GetProofOfStakeSubsidyForCoinstake(fColdStakeReward);
    }
    if (nReward < 0)
        return false;
    if (fColdStakeReward && !stake_reward_split_active) {
        LogPrint(BCLog::COINSTAKE, "CreateCoinStake : cold-stake subsidy discount applied\n");
    }

    const CScript qq_development_script =
        Params().GetQQDevelopmentDonationScript();
    const unsigned int qq_development_percentage =
        wallet.GetQQDevelopmentDonationPercentage();
    bool qq_development_donation_enabled =
        qq_development_percentage > 0 &&
        quantum_stake_rules_active && !fReturnToQuantum &&
        IsDirectQuantumMigrationScript(qq_development_script);

    // This is wallet policy, never a consensus treasury or required payment.
    // Exact reward-split formats cannot carry an additional optional output.
    if (stake_reward_split_active) {
        qq_development_donation_enabled = false;
    }

    CAmount nQQDevelopmentCredit = 0;
    CAmount nMinerCredit = 0;

    if (qq_development_donation_enabled)
    {
        nQQDevelopmentCredit = (nReward * qq_development_percentage) / 100;
        nMinerCredit = nReward - nQQDevelopmentCredit;
        nCredit += nMinerCredit;
    }
    else
    {
        nCredit += nReward;
    }

    // Split stake
    if (nCredit >= GetStakeSplitThreshold() && !fReturnToQuantum)
        txNew.vout.push_back(CTxOut(0, scriptPubKeyOut));

    if (qq_development_donation_enabled)
        txNew.vout.push_back(CTxOut(0, qq_development_script));

    // Set output amount
    if (txNew.vout.size() == (qq_development_donation_enabled ? 4u : 3u) + bMinterKey) {
        txNew.vout[1 + bMinterKey].nValue = (nCredit / 2 / CENT) * CENT;
        txNew.vout[2 + bMinterKey].nValue = nCredit - txNew.vout[1 + bMinterKey].nValue;
        if (qq_development_donation_enabled)
            txNew.vout[3 + bMinterKey].nValue = nQQDevelopmentCredit;
    }
    else
    {
        txNew.vout[1 + bMinterKey].nValue = nCredit;
        if (qq_development_donation_enabled)
            txNew.vout[2 + bMinterKey].nValue = nQQDevelopmentCredit;
    }

    if (stake_reward_split_active && nOperatorCredit > 0) {
        txNew.vout.push_back(CTxOut(nOperatorCredit, operatorRewardScript));
    }

    if (IsShadowGoldRushRewardActive(consensus, stake_mtp, stake_height) &&
        !final_quantum_lockout) {
        txNew.vout.push_back(CTxOut(0, BuildQuantumQuasarBlockNoticeScript()));
    }

    // The independent guard: this wallet never emits a legacy-return coinstake in
    // the window. A legacy kernel there has exactly one output of value, a
    // quantum output of the wallet, and nothing else of value.
    if (legacy_in_window && !fQuantumKernel) {
        const std::string shape_problem = LegacyReturnWindowCoinstakeProblem(txNew, fReturnToQuantum, legacy_return);
        if (!shape_problem.empty()) return error("CreateCoinStake : %s", shape_problem);
    }

    // The recheck before the coinstake is committed: a fresh derivation of the reserve, from the same wallet and chain
    // state the coinstake was built from, must not contain any of its inputs.
    if (stake_slot->final_reserve_active) {
        const std::set<COutPoint> fresh_reserve = ComputeFinalStakeReserve(wallet).enforced;
        for (const CTxIn& txin : txNew.vin) {
            if (fresh_reserve.count(txin.prevout)) {
                LogPrint(BCLog::COINSTAKE, "CreateCoinStake : refusing a coinstake that spends the final stake reserve\n");
                return false;
            }
        }
    }

    // Sign
    const int nStakeHashType = SIGHASH_ALL | (quantum_stake_rules_active ? SIGHASH_FORKID : 0);

    // Use the wallet's phase-aware transaction signer for every wallet type.
    // The historical legacy-only SignSignature path has no spent-output/domain
    // context and would create a legacy digest carrying byte 0x41 after G.
    std::map<COutPoint, Coin> coins;
    for (const CTxIn& txin : txNew.vin) {
        coins[txin.prevout];
    }
    wallet.chain().findCoins(coins);
    std::map<int, bilingual_str> input_errors;
    const int nTime = txNew.nTime;
    if (!wallet.SignTransaction(txNew, coins, nStakeHashType, input_errors)) {
        for (const auto& [input_index, error] : input_errors) {
            LogPrintf("CreateCoinStake : failed to sign input %d: %s\n", input_index, error.original);
        }
        return error("CreateCoinStake : failed to sign coinstake");
    }
    txNew.nTime = nTime;

    // Limit size
    unsigned int nBytes = ::GetSerializeSize(TX_WITH_WITNESS(txNew));
    if (nBytes >= 1000000/5)
        return error("CreateCoinStake : exceeded coinstake size limit");

    // Successfully generated coinstake
    return true;
}

AutoScanVerdict DecideAutoScan(int last_height, const uint256& last_tip,
                               int height, const uint256& tip,
                               std::chrono::steady_clock::time_point& last_reorg_scan,
                               std::chrono::steady_clock::time_point now)
{
    if (height > last_height || last_tip.IsNull()) return AutoScanVerdict::SCAN;
    if (height == last_height && tip == last_tip) return AutoScanVerdict::SKIP_SAME_TIP;
    if (last_reorg_scan != std::chrono::steady_clock::time_point{} &&
        now - last_reorg_scan < AUTO_SCAN_REORG_MIN_INTERVAL) {
        return AutoScanVerdict::SKIP_REORG_BOUND;
    }
    last_reorg_scan = now;
    return AutoScanVerdict::SCAN;
}

} // namespace wallet
