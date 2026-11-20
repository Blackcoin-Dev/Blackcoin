// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <wallet/scheduler_stats.h>

#include <logging.h>
#include <sync.h>
#include <tinyformat.h>
#include <util/strencodings.h>
#include <util/string.h>

#include <algorithm>
#include <mutex>
#include <vector>
#include <string_view>
#include <string>
#include <optional>

#if defined(__APPLE__)
#include <mach/mach.h>
#elif defined(__linux__)
#include <cstdio>
#include <unistd.h>
#endif

namespace wallet {
namespace {

constexpr const char* KIND_NAMES[WALLET_CALLBACK_KINDS] = {"connected", "mempool_add", "mempool_remove", "disconnected"};

// Nesting depth of counted handlers on this thread.
thread_local int t_callback_depth{0};

Mutex g_queue_depth_mutex;
std::function<size_t()> g_queue_depth_provider GUARDED_BY(g_queue_depth_mutex);

void UpdateMax(std::atomic<uint64_t>& max, uint64_t value)
{
    uint64_t current = max.load(std::memory_order_relaxed);
    while (value > current && !max.compare_exchange_weak(current, value, std::memory_order_relaxed)) {
    }
}

uint64_t ToMs(uint64_t us) { return us / 1000; }

constexpr const char* SQLITE_COMMIT_NAMES[SQLITE_COMMIT_KINDS] = {"durable", "non_durable", "bulk_scope", "autocommit"};

std::string FormatHistogram(const std::array<uint64_t, LATENCY_BUCKETS>& h)
{
    return strprintf("%u/%u/%u/%u/%u", h[0], h[1], h[2], h[3], h[4]);
}

} // namespace

size_t LatencyBucket(std::chrono::microseconds duration)
{
    using namespace std::chrono_literals;
    if (duration < 10ms) return 0;
    if (duration < 100ms) return 1;
    if (duration < 1s) return 2;
    if (duration < 10s) return 3;
    return 4;
}

SchedulerStats& SchedulerStats::Instance()
{
    static SchedulerStats stats;
    return stats;
}

void SchedulerStats::Record(WalletCallbackKind kind, std::chrono::microseconds wait, std::chrono::microseconds hold)
{
    Counters& c = m_counters[static_cast<size_t>(kind)];
    const uint64_t wait_us = static_cast<uint64_t>(std::max<int64_t>(0, wait.count()));
    const uint64_t hold_us = static_cast<uint64_t>(std::max<int64_t>(0, hold.count()));
    c.count.fetch_add(1, std::memory_order_relaxed);
    c.wait_total_us.fetch_add(wait_us, std::memory_order_relaxed);
    c.hold_total_us.fetch_add(hold_us, std::memory_order_relaxed);
    UpdateMax(c.wait_max_us, wait_us);
    UpdateMax(c.hold_max_us, hold_us);
    c.wait_histogram[LatencyBucket(std::chrono::microseconds{static_cast<int64_t>(wait_us)})].fetch_add(1, std::memory_order_relaxed);
    c.hold_histogram[LatencyBucket(std::chrono::microseconds{static_cast<int64_t>(hold_us)})].fetch_add(1, std::memory_order_relaxed);
}

CallbackLatencySnapshot SchedulerStats::Snapshot(WalletCallbackKind kind) const
{
    const Counters& c = m_counters[static_cast<size_t>(kind)];
    CallbackLatencySnapshot s;
    s.count = c.count.load(std::memory_order_relaxed);
    s.wait_total_us = c.wait_total_us.load(std::memory_order_relaxed);
    s.wait_max_us = c.wait_max_us.load(std::memory_order_relaxed);
    s.hold_total_us = c.hold_total_us.load(std::memory_order_relaxed);
    s.hold_max_us = c.hold_max_us.load(std::memory_order_relaxed);
    for (size_t i = 0; i < LATENCY_BUCKETS; ++i) {
        s.wait_histogram[i] = c.wait_histogram[i].load(std::memory_order_relaxed);
        s.hold_histogram[i] = c.hold_histogram[i].load(std::memory_order_relaxed);
    }
    return s;
}

void SchedulerStats::Reset()
{
    for (Counters& c : m_counters) {
        c.count = 0;
        c.wait_total_us = 0;
        c.wait_max_us = 0;
        c.hold_total_us = 0;
        c.hold_max_us = 0;
        for (auto& b : c.wait_histogram) b = 0;
        for (auto& b : c.hold_histogram) b = 0;
    }
    m_last_summary_ns = 0;
}

std::string SchedulerStats::FormatSummary() const
{
    std::string line = "Wallet scheduler stats (cumulative; wait and hold of cs_wallet in ms as total/max; histogram counts <10ms/<100ms/<1s/<10s/>=10s):";
    const std::optional<size_t> depth = GetValidationQueueDepth();
    line += depth ? strprintf(" queue=%u", *depth) : std::string{" queue=n/a"};
    for (size_t i = 0; i < WALLET_CALLBACK_KINDS; ++i) {
        const CallbackLatencySnapshot s = Snapshot(static_cast<WalletCallbackKind>(i));
        line += strprintf(" | %s n=%u wait=%u/%u hold=%u/%u waith=%s holdh=%s",
                          KIND_NAMES[i], s.count,
                          ToMs(s.wait_total_us), ToMs(s.wait_max_us),
                          ToMs(s.hold_total_us), ToMs(s.hold_max_us),
                          FormatHistogram(s.wait_histogram), FormatHistogram(s.hold_histogram));
    }
    return line;
}

void SchedulerStats::MaybeLogSummary(std::chrono::steady_clock::time_point now)
{
    const int64_t now_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(now.time_since_epoch()).count();
    const int64_t interval_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(SUMMARY_INTERVAL).count();
    int64_t last = m_last_summary_ns.load(std::memory_order_relaxed);
    do {
        if (last != 0 && now_ns - last < interval_ns) return;
    } while (!m_last_summary_ns.compare_exchange_weak(last, now_ns, std::memory_order_relaxed));

    LogPrintf("%s%s\n", FormatSummary(), FormatSqliteCommits(ProcessSqliteCommits().Take()));
    if (const std::optional<ProcessMemory> memory = GetProcessMemory()) {
        LogPrintf("%s\n", FormatProcessMemory(*memory));
    }
}

void SqliteCommitCounters::Record(SqliteCommitKind kind, std::chrono::microseconds duration)
{
    Counters& c = m_counters[static_cast<size_t>(kind)];
    const uint64_t us = duration.count() < 0 ? 0 : static_cast<uint64_t>(duration.count());
    c.count.fetch_add(1, std::memory_order_relaxed);
    c.total_us.fetch_add(us, std::memory_order_relaxed);
    UpdateMax(c.max_us, us);
}

SqliteCommitSnapshot SqliteCommitCounters::Snapshot() const
{
    SqliteCommitSnapshot out;
    for (size_t i = 0; i < SQLITE_COMMIT_KINDS; ++i) {
        out[i].count = m_counters[i].count.load(std::memory_order_relaxed);
        out[i].total_us = m_counters[i].total_us.load(std::memory_order_relaxed);
        out[i].max_us = m_counters[i].max_us.load(std::memory_order_relaxed);
    }
    return out;
}

SqliteCommitSnapshot SqliteCommitCounters::Take()
{
    SqliteCommitSnapshot out;
    for (size_t i = 0; i < SQLITE_COMMIT_KINDS; ++i) {
        out[i].count = m_counters[i].count.exchange(0, std::memory_order_relaxed);
        out[i].total_us = m_counters[i].total_us.exchange(0, std::memory_order_relaxed);
        out[i].max_us = m_counters[i].max_us.exchange(0, std::memory_order_relaxed);
    }
    return out;
}

void SqliteCommitCounters::Reset()
{
    (void)Take();
}

SqliteCommitCounters& ProcessSqliteCommits()
{
    static SqliteCommitCounters counters;
    return counters;
}

std::string FormatSqliteCommits(const SqliteCommitSnapshot& snapshot)
{
    uint64_t commits{0}, total_us{0}, max_us{0};
    std::string detail;
    for (size_t i = 0; i < SQLITE_COMMIT_KINDS; ++i) {
        const SqliteCommitCounts& c = snapshot[i];
        if (c.count == 0) continue;
        commits += c.count;
        total_us += c.total_us;
        max_us = std::max(max_us, c.max_us);
        detail += strprintf(" %s=%u/%u/%u", SQLITE_COMMIT_NAMES[i], c.count, ToMs(c.total_us), ToMs(c.max_us));
    }
    std::string out = strprintf(" | sqlite commits since last line: n=%u total=%u ms max=%u ms", commits, ToMs(total_us), ToMs(max_us));
    if (!detail.empty()) out += strprintf(" (kind=n/total_ms/max_ms:%s)", detail);
    return out;
}

bool InWalletCallback()
{
    return t_callback_depth > 0;
}

WalletCallbackTimer::WalletCallbackTimer(WalletCallbackKind kind)
    : m_kind{kind}, m_counted{t_callback_depth == 0}, m_start{std::chrono::steady_clock::now()}
{
    ++t_callback_depth;
}

void WalletCallbackTimer::LockAcquired()
{
    m_acquired = std::chrono::steady_clock::now();
    m_have_acquired = true;
}

WalletCallbackTimer::~WalletCallbackTimer()
{
    --t_callback_depth;
    if (!m_counted) return;
    const auto end = std::chrono::steady_clock::now();
    // A handler that returned before taking the lock waited for the whole span and held nothing.
    const auto acquired = m_have_acquired ? m_acquired : end;
    SchedulerStats& stats = SchedulerStats::Instance();
    stats.Record(m_kind,
                 std::chrono::duration_cast<std::chrono::microseconds>(acquired - m_start),
                 std::chrono::duration_cast<std::chrono::microseconds>(end - acquired));
    stats.MaybeLogSummary(end);
}

void SetValidationQueueDepthProvider(std::function<size_t()> provider)
{
    LOCK(g_queue_depth_mutex);
    g_queue_depth_provider = std::move(provider);
}

std::optional<size_t> GetValidationQueueDepth()
{
    std::function<size_t()> provider;
    {
        LOCK(g_queue_depth_mutex);
        provider = g_queue_depth_provider;
    }
    if (!provider) return std::nullopt;
    return provider();
}

std::optional<ProcessMemory> GetProcessMemory()
{
#if defined(__APPLE__)
    ProcessMemory memory;
    mach_task_basic_info_data_t basic{};
    mach_msg_type_number_t basic_count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, reinterpret_cast<task_info_t>(&basic), &basic_count) != KERN_SUCCESS) {
        return std::nullopt;
    }
    memory.resident_bytes = basic.resident_size;
    task_vm_info_data_t vm{};
    mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vm), &vm_count) == KERN_SUCCESS) {
        memory.footprint_bytes = vm.phys_footprint;
        memory.compressed_bytes = vm.compressed;
    }
    return memory;
#elif defined(__linux__)
    std::FILE* file = std::fopen("/proc/self/statm", "r");
    if (!file) return std::nullopt;
    // "size resident shared ...", in pages. Parsed without the C locale.
    char line[128]{};
    const bool got_line = std::fgets(line, sizeof(line), file) != nullptr;
    std::fclose(file);
    if (!got_line) return std::nullopt;
    const std::vector<std::string> fields = SplitString(std::string_view{line}, " \n");
    if (fields.size() < 2) return std::nullopt;
    const std::optional<uint64_t> resident = ToIntegral<uint64_t>(fields[1]);
    if (!ToIntegral<uint64_t>(fields[0]) || !resident) return std::nullopt;
    const uint64_t resident_pages = *resident;
    const long page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) return std::nullopt;
    ProcessMemory memory;
    memory.resident_bytes = resident_pages * static_cast<uint64_t>(page_size);
    return memory;
#else
    return std::nullopt;
#endif
}

std::string FormatProcessMemory(const ProcessMemory& memory)
{
    constexpr uint64_t MIB{1024 * 1024};
    std::string line = strprintf("Process memory: resident=%u MiB", memory.resident_bytes / MIB);
    if (memory.footprint_bytes) line += strprintf(" footprint=%u MiB", *memory.footprint_bytes / MIB);
    if (memory.compressed_bytes) line += strprintf(" compressed=%u MiB", *memory.compressed_bytes / MIB);
    return line;
}

} // namespace wallet
