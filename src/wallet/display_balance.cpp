// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/display_balance.h>

#include <chain.h>
#include <interfaces/chain.h>
#include <logging.h>
#include <sync.h>
#include <util/thread_qos.h>
#include <util/threadnames.h>
#include <wallet/coincontrol.h>
#include <wallet/wallet.h>

#include <algorithm>
#include <tuple>

namespace wallet {

int PickDisplayWallet(const std::vector<DisplayCandidate>& candidates, int64_t now_ms)
{
    int best{-1};
    // Smaller is better: the class, then (class 0) the wallet shown before
    // the others or (class 2) the age of the snapshot, then who was served
    // longest ago.
    std::tuple<int, int64_t, int64_t> best_key;
    for (size_t i = 0; i < candidates.size(); ++i) {
        const DisplayCandidate& c = candidates[i];
        if (!c.needs_work) continue;
        int cls;
        if (c.foreground && c.need_since_ms != 0 && now_ms - c.need_since_ms >= DISPLAY_FOREGROUND_MAX_WAIT_MS) {
            cls = -1;
        } else if (c.never_published) {
            cls = 0;
        } else if (c.foreground) {
            cls = 1;
        } else {
            cls = 2;
        }
        const int64_t within = cls == 2 ? c.last_publish_ms : cls == 0 ? (c.foreground ? 0 : 1) : 0;
        const std::tuple<int, int64_t, int64_t> key{cls, within, c.last_served_ms};
        if (best < 0 || key < best_key) {
            best = static_cast<int>(i);
            best_key = key;
        }
    }
    return best;
}

int64_t WalletDisplayBalance::NowMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count() + 1;
}

WalletDisplayBalance::WalletDisplayBalance(CWallet& wallet)
    : m_wallet(wallet), m_load_ms(NowMs()), m_last_summary_ms(m_load_ms) {}

std::shared_ptr<const DisplayBalanceSnapshot> WalletDisplayBalance::Snapshot() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_snapshot;
}

std::string DisplayBalanceState::ToString() const
{
    switch (status) {
    case DisplayBalanceStatus::NONE: return "none";
    case DisplayBalanceStatus::FAILED: return "failed";
    case DisplayBalanceStatus::EXACT: return "exact";
    case DisplayBalanceStatus::CURRENT_UNVERIFIED: return "current-unverified";
    case DisplayBalanceStatus::BEHIND: return strprintf("behind(%d)", behind_blocks);
    }
    return "none";
}

int64_t DisplayBalanceState::SummaryIntervalMs(bool foreground) const
{
    // A wallet that is not shown is recomputed at most once a minute while a
    // block arrives about as often, so at any moment it is routinely a block
    // or two behind. That is not news: only the wallet on screen, or one that
    // has fallen further behind, is reported at the minute cadence.
    const bool minute = status == DisplayBalanceStatus::NONE ||
        (status == DisplayBalanceStatus::BEHIND &&
         (foreground || behind_blocks >= WalletDisplayBalance::BEHIND_LOG_MIN_BLOCKS));
    return minute ? WalletDisplayBalance::SUMMARY_INTERVAL_STALE_MS : WalletDisplayBalance::SUMMARY_INTERVAL_EXACT_MS;
}

DisplayBalanceState ClassifyDisplayBalance(const DisplayBalanceSnapshot* snapshot, bool failed, bool marker_current,
                                           int reference_height, const std::optional<uint256>& reference_hash)
{
    DisplayBalanceState state;
    if (failed) {
        state.status = DisplayBalanceStatus::FAILED;
    } else if (!snapshot) {
        state.status = DisplayBalanceStatus::NONE;
    } else if (reference_height >= 0 &&
               (snapshot->tip_height < reference_height ||
                (reference_hash && *reference_hash != snapshot->tip_hash))) {
        state.status = DisplayBalanceStatus::BEHIND;
        state.behind_blocks = std::max(1, reference_height - snapshot->tip_height);
    } else {
        state.status = marker_current ? DisplayBalanceStatus::EXACT : DisplayBalanceStatus::CURRENT_UNVERIFIED;
    }
    return state;
}

DisplayBalanceState WalletDisplayBalance::State(int reference_height, const std::optional<uint256>& reference_hash) const
{
    const uint64_t marker = m_wallet.GetBalanceScanMarkerUnlocked();
    std::lock_guard<std::mutex> lock(m_mutex);
    return ClassifyDisplayBalance(m_snapshot.get(), m_failed, m_snapshot && m_snapshot->marker == marker,
                                  reference_height, reference_hash);
}

bool WalletDisplayBalance::IsCurrent(const DisplayBalanceSnapshot& snapshot) const
{
    return snapshot.marker == m_wallet.GetBalanceScanMarkerUnlocked();
}

bool WalletDisplayBalance::Failed() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_failed;
}

bool WalletDisplayBalance::SetInterest(bool foreground, std::optional<bool> send_family_quantum, bool retry_send)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    const bool changed = m_foreground != foreground || m_send_family != send_family_quantum || retry_send;
    m_foreground = foreground;
    m_send_family = send_family_quantum;
    if (retry_send) {
        m_send_force = true;
        m_send_not_before_ms = 0;
    }
    return changed;
}

DisplayBalanceOutcome WalletDisplayBalance::RequestAndWait(std::optional<bool> send_family_quantum,
                                                           std::chrono::milliseconds timeout,
                                                           const std::function<void()>& wake)
{
    uint64_t ticket;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_aborted) return {};
        ticket = ++m_ticket_requested;
        if (send_family_quantum) {
            // Not everything the send-family balance depends on moves the
            // wallet change marker (coin locks): a caller that asks gets a
            // fresh one.
            m_ticket_send_family = send_family_quantum;
            m_send_force = true;
            m_send_not_before_ms = 0;
        }
    }
    wake();
    std::unique_lock<std::mutex> lock(m_mutex);
    DisplayBalanceOutcome outcome;
    if (!m_cv.wait_for(lock, timeout, [&] { return m_ticket_done >= ticket; })) return outcome;
    if (m_aborted) return outcome;
    outcome.ok = m_outcome_ok;
    outcome.exception = m_outcome_exception;
    outcome.snapshot = m_snapshot;
    return outcome;
}

void WalletDisplayBalance::AbortWaiters()
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_aborted = true;
        m_ticket_done = m_ticket_serving = m_ticket_requested;
        m_outcome_ok = false;
        m_outcome_exception = nullptr;
        m_ticket_send_family.reset();
    }
    m_cv.notify_all();
}

std::optional<bool> WalletDisplayBalance::WantedSendFamily() const
{
    if (m_ticket_requested > m_ticket_done && m_ticket_send_family) return m_ticket_send_family;
    return m_send_family;
}

bool WalletDisplayBalance::SendFamilyDue(const DisplayBalanceSnapshot& snapshot, int64_t now_ms) const
{
    const std::optional<bool> wanted = WantedSendFamily();
    if (!wanted) return false;
    if (m_send_force) return true;
    if (snapshot.send_family_quantum == wanted && snapshot.send_family_balance) return false;
    if (m_send_attempted && *m_send_attempted == std::make_tuple(snapshot.tip_hash, snapshot.marker, *wanted)) return false;
    return now_ms >= m_send_not_before_ms;
}

DisplayCandidate WalletDisplayBalance::Candidate(int64_t now_ms)
{
    const uint64_t marker = m_wallet.GetBalanceScanMarkerUnlocked();
    std::lock_guard<std::mutex> lock(m_mutex);
    DisplayCandidate c;
    const bool waited = m_ticket_requested > m_ticket_done;
    c.never_published = !m_snapshot;
    c.foreground = m_foreground || waited;
    c.last_publish_ms = m_snapshot ? m_snapshot->published_ms : 0;
    // After an error the next attempt waits, unless the wallet has changed.
    const bool ready = now_ms >= m_not_before_ms || (m_failed && marker != m_failed_marker);
    const bool dirty = !m_snapshot || m_snapshot->marker != marker;
    // A wallet that is not shown keeps its snapshot for a while.
    const bool throttled = m_snapshot && !c.foreground &&
        now_ms - m_snapshot->published_ms < BACKGROUND_MIN_INTERVAL_MS;
    const bool want_pass = dirty && ready && !throttled;
    const bool want_send = m_snapshot && !dirty && ready && SendFamilyDue(*m_snapshot, now_ms);
    const bool want_warmup = m_warmup_armed.load() && ready;
    c.needs_work = waited || want_pass || want_send || want_warmup;
    if (!c.needs_work) {
        m_need_since_ms = 0;
    } else if (m_need_since_ms == 0) {
        m_need_since_ms = now_ms;
    }
    c.need_since_ms = m_need_since_ms;
    return c;
}

bool WalletDisplayBalance::ValidationBusy() const
{
    return m_wallet.HaveChain() && m_wallet.chain().validationCallbacksBusy();
}

bool WalletDisplayBalance::ShutdownRequested() const
{
    return m_wallet.HaveChain() && m_wallet.chain().shutdownRequested();
}

void WalletDisplayBalance::NoteDeferral()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    ++m_counters.busy_deferrals;
}

void WalletDisplayBalance::Account(const LifecycleSliceReport& report)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    if (report.result == LifecycleSliceResult::LOCK_BUSY) {
        ++m_counters.lock_busy;
        return;
    }
    ++m_counters.slices;
    ++m_total_slices;
    const int64_t held = report.held.count();
    if (report.held_wallet) {
        m_counters.max_wallet_us = std::max(m_counters.max_wallet_us, held);
        m_pass_wallet_us += held;
    }
    if (report.held_main) {
        m_counters.max_main_us = std::max(m_counters.max_main_us, held);
        m_pass_main_us += held;
    }
}

void WalletDisplayBalance::BackOff(int64_t first_ms, int64_t max_ms)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_backoff_ms = std::clamp<int64_t>(m_backoff_ms == 0 ? first_ms : m_backoff_ms * 2, first_ms, max_ms);
    m_not_before_ms = NowMs() + m_backoff_ms;
}

void WalletDisplayBalance::ClearBackOff()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    m_backoff_ms = 0;
    m_not_before_ms = 0;
}

void WalletDisplayBalance::SetFailed(bool failed)
{
    bool changed;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        changed = m_failed != failed;
        m_failed = failed;
        if (failed) {
            ++m_counters.failures;
            m_failed_marker = m_wallet.GetBalanceScanMarkerUnlocked();
        }
    }
    if (changed) NotifyChanged();
}

void WalletDisplayBalance::FinishOutcome(End end, std::exception_ptr exception)
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_ticket_serving > m_ticket_done) {
            m_ticket_done = m_ticket_serving;
            m_outcome_ok = end == End::OK;
            m_outcome_exception = exception;
            if (m_ticket_requested == m_ticket_done) m_ticket_send_family.reset();
        }
    }
    m_cv.notify_all();
}

void WalletDisplayBalance::Publish(std::shared_ptr<DisplayBalanceSnapshot> snapshot)
{
    std::optional<std::string> first_line;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        const int64_t now_ms = NowMs();
        snapshot->sequence = ++m_sequence;
        snapshot->published_ms = now_ms;
        m_snapshot = std::move(snapshot);
        m_failed = false;
        if (!m_first_exact_logged) {
            m_first_exact_logged = true;
            // The text shape is kept from the per-wallet scan it replaces;
            // attempts counts slices now.
            first_line = strprintf("GUI balance scan: wallet=%s first balance ready after %d ms (attempts=%d)",
                                   m_wallet.GetName(), now_ms - m_load_ms, m_total_slices);
        }
    }
    if (first_line) m_wallet.WalletLogPrintf("%s\n", *first_line);
    NotifyChanged();
}

void WalletDisplayBalance::MaybeLogSummary(int64_t now_ms)
{
    // The wallet's last processed block is the reference the snapshot is
    // judged against. Only a try-lock: the line is advisory and the worker
    // must not wait for a busy wallet. Without it the worker's own latest
    // view of the tip height stands in (no hash to compare).
    int reference_height{-1};
    std::optional<uint256> reference_hash;
    {
        TRY_LOCK(m_wallet.cs_wallet, locked);
        if (locked) {
            if (const std::optional<int> height = m_wallet.GetLastBlockHeightIfSet()) {
                reference_height = *height;
                reference_hash = m_wallet.GetLastBlockHash();
            }
        }
    }
    const uint64_t marker = m_wallet.GetBalanceScanMarkerUnlocked();
    std::string line;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (reference_height < 0) reference_height = m_last_seen_tip_height;
        const DisplayBalanceState state = ClassifyDisplayBalance(
            m_snapshot.get(), m_failed, m_snapshot && m_snapshot->marker == marker, reference_height, reference_hash);
        if (now_ms - m_last_summary_ms < state.SummaryIntervalMs(m_foreground)) return;
        m_last_summary_ms = now_ms;
        const int snapshot_height = m_snapshot ? m_snapshot->tip_height : -1;
        // The age is measured against the same block as the state: the
        // wallet's last processed block. (It used to be measured against the
        // tip this worker saw when it last started a pass of this wallet,
        // which for a wallet that had no turn since is the snapshot's own
        // block: "behind(7) snapshot_age_blocks=0".) A snapshot of another
        // block at the wallet's height, after a reorg, is one block behind.
        const int age_blocks = !m_snapshot ? -1
            : state.status == DisplayBalanceStatus::BEHIND ? state.behind_blocks : 0;
        line = strprintf("GUI balance worker: wallet=%s state=%s snapshot_height=%d wallet_height=%d snapshot_age_blocks=%d "
                         "slices=%d max_wallet_slice_ms=%.1f max_main_slice_ms=%.1f max_send_family_ms=%.1f "
                         "warmup_remaining=%d warmup_walked_pct=%d "
                         "restarts_tip_moved=%d restarts_marker_moved=%d busy_deferrals=%d "
                         "lock_busy=%d not_synced=%d passes=%d failures=%d since_load_s=%d",
                         m_wallet.GetName(), state.ToString(),
                         snapshot_height, reference_height, age_blocks,
                         m_counters.slices, m_counters.max_wallet_us / 1000.0, m_counters.max_main_us / 1000.0,
                         m_counters.max_send_family_us / 1000.0,
                         m_warmup_waiting, m_warmup_walked_percent,
                         m_counters.restarts_tip, m_counters.restarts_marker, m_counters.busy_deferrals,
                         m_counters.lock_busy, m_counters.not_synced, m_counters.passes, m_counters.failures,
                         (now_ms - m_load_ms) / 1000);
        m_counters = {};
    }
    m_wallet.WalletLogPrintf("%s\n", line);
}

void WalletDisplayBalance::NoteMismatches()
{
    while (m_journal_mismatches_seen < m_journal.mismatches) {
        ++m_journal_mismatches_seen;
        m_mismatch_heights.push_back(m_tip_height_seen);
    }
    while (!m_mismatch_heights.empty() &&
           m_tip_height_seen - m_mismatch_heights.front() > MISMATCH_WINDOW_BLOCKS) {
        m_mismatch_heights.pop_front();
    }
    // One entry in 1024 is compared with the chainstate per tip. A single
    // disagreement is repaired where it was found. Several close together
    // mean that the entries nobody looked at cannot be trusted either.
    if (m_mismatch_heights.size() >= MISMATCH_CLEAR_COUNT) {
        m_journal.clear_all = true;
        m_mismatch_heights.clear();
    }
}

void WalletDisplayBalance::RunJob(const std::function<bool()>& turn)
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_limits = m_next_limits;
    }
    try {
        std::function<void()> fault;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            fault = m_job_fault_for_test;
        }
        if (fault) fault();
        RunJobInner(turn);
    } catch (const std::exception& e) {
        HandleJobException(e.what(), std::current_exception());
    } catch (...) {
        HandleJobException("unknown exception", std::current_exception());
    }
    // The wallet has had a turn: its wait for one starts again.
    std::lock_guard<std::mutex> lock(m_mutex);
    m_need_since_ms = 0;
}

void WalletDisplayBalance::HandleJobException(const std::string& what, std::exception_ptr exception)
{
    // Nothing thrown here may leave the worker thread: it serves every wallet
    // of the process and an escaped exception would end the process.
    try {
        bool log{false};
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            const int64_t now_ms = NowMs();
            if (m_last_job_error_log_ms == 0 || now_ms - m_last_job_error_log_ms >= 60000) {
                m_last_job_error_log_ms = now_ms;
                log = true;
            }
            // The waiters of this attempt get the failure, not a wait for the back-off.
            m_ticket_serving = m_ticket_requested;
        }
        if (log) m_wallet.WalletLogPrintf("GUI balance worker job failed: %s\n", what);
        // The half-finished state of the failed job is not resumed.
        m_pass.Reset();
        m_warmup.reset();
        FinishOutcome(End::FAILED, exception);
        BackOff(10000, 10000);
        SetFailed(true);
    } catch (...) {
    }
}

void WalletDisplayBalance::RunJobInner(const std::function<bool()>& turn)
{
    if (m_warmup_armed.load()) {
        RunWarmup(turn);
        return;
    }
    const uint64_t marker = m_wallet.GetBalanceScanMarkerUnlocked();
    bool send_only;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        const bool waited = m_ticket_requested > m_ticket_done;
        const bool dirty = !m_snapshot || m_snapshot->marker != marker;
        send_only = !waited && !dirty && m_pass.stage == LifecyclePass::Stage::TIP &&
            SendFamilyDue(*m_snapshot, NowMs());
    }
    if (send_only) {
        if (turn()) RunSendFamilyOnly();
        return;
    }
    RunPass(turn);
}

void WalletDisplayBalance::RunWarmup(const std::function<bool()>& turn)
{
    if (!m_warmup) {
        m_warmup.emplace();
        m_warmup_stored_base = m_journal.stored;
    }
    for (;;) {
        if (!turn()) return;
        const LifecycleWarmup::Stage before = m_warmup->stage;
        const LifecycleSliceReport report = RunLifecycleWarmupSlice(m_wallet, *m_warmup, m_journal, m_limits);
        Account(report);
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_warmup_waiting = static_cast<int64_t>(m_warmup->Waiting(m_journal));
            m_warmup_walked_percent = m_warmup->WalkedPercent();
        }
        if (report.result == LifecycleSliceResult::LOCK_BUSY) {
            if (++m_consecutive_busy >= 20) {
                m_consecutive_busy = 0;
                BackOff(100, 2000);
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds{5});
            continue;
        }
        m_consecutive_busy = 0;
        if (report.result == LifecycleSliceResult::DONE) {
            const uint64_t stored = m_journal.stored - m_warmup_stored_base;
            // A warm-up that could store nothing would be asked for again by
            // the next pass, for ever. Let that pass resolve the outputs
            // itself; it reports what is wrong with them.
            m_warmup_was_useless = stored == 0;
            m_wallet.WalletLogPrintf("GUI balance warm-up: wallet=%s done outputs=%d stored=%d skipped=%d rewinds=%d slices=%d\n",
                                     m_wallet.GetName(), m_warmup->collected, stored, m_warmup->skipped,
                                     m_warmup->rewinds, m_warmup->slices);
            m_warmup.reset();
            m_warmup_armed.store(false);
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                m_warmup_waiting = -1;
                m_warmup_walked_percent = 100;
            }
            ClearBackOff();
            return;
        }
        // One batch (collect, fetch, store) is one turn of this wallet.
        if (before == LifecycleWarmup::Stage::STORE && m_warmup->stage == LifecycleWarmup::Stage::COLLECT) return;
    }
}

void WalletDisplayBalance::RunPass(const std::function<bool()>& turn)
{
    for (;;) {
        if (!turn()) return;
        const bool starting = m_pass.stage == LifecyclePass::Stage::TIP;
        if (starting) {
            // A pass that starts now reads everything after this point, so it
            // answers every synchronous request made so far.
            std::lock_guard<std::mutex> lock(m_mutex);
            m_ticket_serving = m_ticket_requested;
            m_pass.known = m_snapshot ? std::optional{std::make_pair(m_snapshot->tip_hash, m_snapshot->marker)} : std::nullopt;
            m_pass.warmup_threshold = m_warmup_was_useless ? 0 : WARMUP_THRESHOLD;
            m_pass_start_ms = NowMs();
            m_pass_wallet_us = 0;
            m_pass_main_us = 0;
        }
        LifecycleSliceReport report;
        std::exception_ptr exception;
        try {
            report = RunLifecyclePassSlice(m_wallet, m_pass, m_journal, m_attestations, m_limits);
        } catch (const std::exception& e) {
            exception = std::current_exception();
            report.error = e.what();
        } catch (...) {
            exception = std::current_exception();
            report.error = "unknown exception";
        }
        if (exception) {
            m_wallet.WalletLogPrintf("Unable to calculate lifecycle-adjusted GUI balance: %s\n", report.error);
            SetFailed(true);
            FinishOutcome(End::FAILED, exception);
            BackOff(10000, 10000);
            return;
        }
        Account(report);
        if (starting && m_pass.stage == LifecyclePass::Stage::WALK) {
            m_tip_height_seen = m_pass.tip.height;
            std::lock_guard<std::mutex> lock(m_mutex);
            m_last_seen_tip_height = m_tip_height_seen;
        }
        NoteMismatches();

        switch (report.result) {
        case LifecycleSliceResult::MORE:
            m_consecutive_busy = 0;
            continue;
        case LifecycleSliceResult::LOCK_BUSY:
            if (++m_consecutive_busy >= 20) {
                m_consecutive_busy = 0;
                BackOff(100, 2000);
                return;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds{5});
            continue;
        case LifecycleSliceResult::DONE: {
            auto snapshot = std::make_shared<DisplayBalanceSnapshot>();
            snapshot->tip_hash = m_pass.tip.hash;
            snapshot->tip_height = m_pass.tip.height;
            snapshot->marker = m_pass.marker;
            snapshot->balance = m_pass.balance;
            snapshot->lifecycle = m_pass.summary;
            snapshot->have_watch_only = m_pass.have_watch_only;
            int64_t wallet_us, main_us;
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                ++m_counters.passes;
                wallet_us = m_pass_wallet_us;
                main_us = m_pass_main_us;
            }
            LogPrint(BCLog::WALLETDB, "[%s] GUI balance pass: height=%d outputs=%d memo_hits=%d database_reads=%d pending=%d memo_mismatches=%d slices=%d wallet_ms=%.1f main_ms=%.1f took_ms=%d\n",
                     m_wallet.GetName(), m_pass.tip.height, m_pass.stats.outputs, m_pass.stats.memo_hits,
                     m_pass.stats.database_reads, m_pass.stats.pending, m_pass.stats.memo_mismatches,
                     m_pass.slices, wallet_us / 1000.0, main_us / 1000.0, NowMs() - m_pass_start_ms);
            m_pass.Reset();
            m_warmup_was_useless = false;
            m_consecutive_busy = 0;
            ClearBackOff();
            // The send-family balance takes both locks for longer than a
            // slice. It joins this snapshot only when the validation
            // interface is idle; otherwise the snapshot is published without
            // it and it follows as a job of its own, through the gate.
            std::exception_ptr send_exception;
            try {
                if (!ValidationBusy()) RunSendFamily(*snapshot);
            } catch (...) {
                send_exception = std::current_exception();
            }
            Publish(std::move(snapshot));
            FinishOutcome(send_exception ? End::FAILED : End::OK, send_exception);
            return;
        }
        case LifecycleSliceResult::UP_TO_DATE: {
            m_consecutive_busy = 0;
            ClearBackOff();
            SetFailed(false);
            std::exception_ptr send_exception;
            try {
                if (!ValidationBusy()) RunSendFamilyOnly();
            } catch (...) {
                send_exception = std::current_exception();
            }
            FinishOutcome(send_exception ? End::FAILED : End::OK, send_exception);
            return;
        }
        case LifecycleSliceResult::NOT_SYNCED:
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                ++m_counters.not_synced;
            }
            FinishOutcome(End::FAILED, nullptr);
            BackOff(250, 5000);
            return;
        case LifecycleSliceResult::TIP_MOVED:
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                ++m_counters.restarts_tip;
            }
            return;
        case LifecycleSliceResult::WALLET_MOVED:
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                ++m_counters.restarts_marker;
            }
            return;
        case LifecycleSliceResult::NEED_WARMUP:
            m_warmup_armed.store(true);
            return;
        case LifecycleSliceResult::FAILED:
            m_wallet.WalletLogPrintf("Unable to calculate lifecycle-adjusted GUI balance: %s\n", report.error);
            SetFailed(true);
            FinishOutcome(End::FAILED, nullptr);
            BackOff(10000, 10000);
            return;
        }
    }
}

bool WalletDisplayBalance::RunSendFamily(DisplayBalanceSnapshot& snapshot)
{
    bool quantum;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!SendFamilyDue(snapshot, NowMs())) return true;
        quantum = *WantedSendFamily();
    }
    // The one place the display path holds both locks: AvailableCoins needs
    // them. It runs on demand only (a send-family balance was asked for,
    // which the send dialog of the shown wallet does), once per snapshot,
    // and is cut off after SEND_FAMILY_BUDGET.
    std::optional<CAmount> amount;
    bool interrupted{false};
    int64_t held_us{0};
    {
        TRY_LOCK(::cs_main, locked_main);
        if (!locked_main) return false;
        TRY_LOCK(m_wallet.cs_wallet, locked_wallet);
        if (!locked_wallet) return false;
        const CBlockIndex* tip = m_wallet.HaveChain() ? m_wallet.chain().getTip() : nullptr;
        const std::optional<int> wallet_height = m_wallet.GetLastBlockHeightIfSet();
        if (!tip || tip->GetBlockHash() != snapshot.tip_hash || !wallet_height ||
            *wallet_height != snapshot.tip_height || m_wallet.GetLastBlockHash() != snapshot.tip_hash ||
            m_wallet.GetBalanceScanMarker() != snapshot.marker) return false;
        const auto start = std::chrono::steady_clock::now();
        const auto deadline = start + SEND_FAMILY_BUDGET;
        CCoinControl control;
        control.m_input_family = quantum ? CCoinControl::InputFamily::QUANTUM_MIGRATION : CCoinControl::InputFamily::LEGACY;
        control.m_exclude_generated_quantum_inputs = quantum;
        CoinFilterParams params;
        params.interrupt = [&] { return std::chrono::steady_clock::now() >= deadline; };
        CoinsResult coins = AvailableCoins(m_wallet, &control, /*feerate=*/std::nullopt, params);
        interrupted = coins.interrupted;
        if (!interrupted) amount = coins.GetTotalAmount();
        held_us = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count();
    }
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_send_attempted = std::make_tuple(snapshot.tip_hash, snapshot.marker, quantum);
        m_send_force = false;
        // Not a slice: both locks, up to SEND_FAMILY_BUDGET by design. It has
        // a figure of its own so that it is not read as a slice that overran.
        m_counters.max_send_family_us = std::max(m_counters.max_send_family_us, held_us);
        // A wallet too large for the bound is not asked again at every block.
        if (interrupted) m_send_not_before_ms = NowMs() + BACKGROUND_MIN_INTERVAL_MS;
    }
    if (interrupted) {
        LogPrint(BCLog::WALLETDB, "[%s] GUI send-family balance not computed within %d ms\n",
                 m_wallet.GetName(), SEND_FAMILY_BUDGET.count());
        return true;
    }
    snapshot.send_family_quantum = quantum;
    snapshot.send_family_balance = amount;
    return true;
}

void WalletDisplayBalance::RunSendFamilyOnly()
{
    std::shared_ptr<DisplayBalanceSnapshot> copy;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (!m_snapshot || !SendFamilyDue(*m_snapshot, NowMs())) return;
        copy = std::make_shared<DisplayBalanceSnapshot>(*m_snapshot);
    }
    copy->send_family_quantum.reset();
    copy->send_family_balance.reset();
    if (!RunSendFamily(*copy)) {
        BackOff(50, 1000);
        return;
    }
    if (copy->send_family_balance) Publish(std::move(copy));
}

DisplayBalanceWorker& DisplayBalanceWorker::Global()
{
    static DisplayBalanceWorker instance;
    return instance;
}

DisplayBalanceWorker::~DisplayBalanceWorker()
{
    std::lock_guard<std::mutex> lifecycle(m_lifecycle_mutex);
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_stop = true;
    }
    m_cv.notify_all();
    if (m_thread.joinable()) m_thread.join();
}

std::shared_ptr<WalletDisplayBalance> DisplayBalanceWorker::Acquire(CWallet& wallet)
{
    std::lock_guard<std::mutex> lifecycle(m_lifecycle_mutex);
    std::shared_ptr<WalletDisplayBalance> state;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        Entry& entry = m_entries[&wallet];
        if (!entry.state) entry.state = std::make_shared<WalletDisplayBalance>(wallet);
        ++entry.refs;
        state = entry.state;
        m_stop = false;
        m_wake = true;
    }
    if (!m_thread.joinable()) m_thread = std::thread([this] { Run(); });
    m_cv.notify_all();
    return state;
}

void DisplayBalanceWorker::Release(CWallet& wallet)
{
    std::lock_guard<std::mutex> lifecycle(m_lifecycle_mutex);
    bool last{false};
    {
        std::unique_lock<std::mutex> lock(m_mutex);
        const auto it = m_entries.find(&wallet);
        if (it == m_entries.end()) return;
        if (--it->second.refs > 0) return;
        // The slice in progress (if any) ends within its bound; every lock
        // the worker takes is a try-lock, so this cannot wait on the caller.
        it->second.removing = true;
        m_cv.notify_all();
        m_cv.wait(lock, [&] { return !it->second.running; });
        // Nothing serves the wallet's outstanding synchronous requests any more.
        it->second.state->AbortWaiters();
        m_entries.erase(it);
        last = m_entries.empty();
        if (last) m_stop = true;
    }
    if (last) {
        m_cv.notify_all();
        if (m_thread.joinable()) m_thread.join();
    }
}

void DisplayBalanceWorker::Wake()
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_wake = true;
    }
    m_cv.notify_all();
}

size_t DisplayBalanceWorker::WalletCount()
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_entries.size();
}

bool DisplayBalanceWorker::WaitTurn(Entry& entry)
{
    std::unique_lock<std::mutex> lock(m_mutex);
    // Leave a gap between two slices, of this wallet or of two wallets:
    // whoever waits for the lock that was just released gets it.
    m_cv.wait_for(lock, SLICE_GAP, [&] { return m_stop || entry.removing; });
    for (;;) {
        if (m_stop || entry.removing) return false;
        lock.unlock();
        const bool shutdown = entry.state->ShutdownRequested();
        const bool busy = !shutdown && entry.state->ValidationBusy();
        lock.lock();
        if (shutdown || m_stop || entry.removing) return false;
        if (m_gate.MayRun(WalletDisplayBalance::NowMs(), busy)) {
            m_deferring = false;
            return true;
        }
        if (!m_deferring) {
            // Count a deferral once, not every time the gate is asked.
            m_deferring = true;
            lock.unlock();
            entry.state->NoteDeferral();
            lock.lock();
            continue;
        }
        m_cv.wait_for(lock, std::chrono::milliseconds{5}, [&] { return m_stop || entry.removing; });
    }
}

void DisplayBalanceWorker::Run()
{
    util::ThreadRename("guibalance");
    // This worker computes the balance the window shows. It starts lazily
    // from whichever thread first asked for a balance, so say explicitly that
    // it is user-initiated work rather than inherit a lower class. A no-op
    // off macOS.
    util::SetCurrentThreadQosUserInitiated();
    std::unique_lock<std::mutex> lock(m_mutex);
    while (!m_stop) {
        const int64_t now_ms = WalletDisplayBalance::NowMs();
        std::vector<Entry*> entries;
        std::vector<DisplayCandidate> candidates;
        bool shutdown{false};
        for (auto& [wallet, entry] : m_entries) {
            if (entry.removing) continue;
            if (entry.state->ShutdownRequested()) {
                shutdown = true;
                break;
            }
            entry.state->MaybeLogSummary(now_ms);
            DisplayCandidate candidate = entry.state->Candidate(now_ms);
            candidate.last_served_ms = entry.last_served_ms;
            entries.push_back(&entry);
            candidates.push_back(candidate);
        }
        if (shutdown) {
            // No pass will run again: a caller blocked on one must not wait out its timeout.
            for (auto& [wallet, entry] : m_entries) entry.state->AbortWaiters();
        }
        const int pick = shutdown ? -1 : PickDisplayWallet(candidates, now_ms);
        if (pick < 0) {
            // Wallet changes are noticed by polling their change markers
            // (one atomic read per wallet); requests wake the thread.
            m_wake = false;
            m_cv.wait_for(lock, std::chrono::milliseconds{250}, [&] { return m_stop || m_wake; });
            continue;
        }
        Entry& entry = *entries[pick];
        entry.running = true;
        entry.last_served_ms = now_ms;
        const std::shared_ptr<WalletDisplayBalance> state = entry.state;
        lock.unlock();
        try {
            state->RunJob([&] { return WaitTurn(entry); });
        } catch (...) {
            // RunJob reports its own failures; this is the last line of defence.
        }
        lock.lock();
        entry.running = false;
        m_cv.notify_all();
    }
}

} // namespace wallet
