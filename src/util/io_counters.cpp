// Copyright (c) 2026 Blackcoin Core Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <util/io_counters.h>

#include <sync.h>

#include <chrono>
#include <thread>

namespace iocounters {
namespace {
std::atomic<int64_t> g_read_delay_us{0};
std::atomic<int64_t> g_commit_delay_us{0};
std::atomic<bool> g_record{false};

Mutex g_record_mutex;
std::vector<std::string> g_recorded GUARDED_BY(g_record_mutex);

void RefreshHooks()
{
    g_read_hook.store(g_read_delay_us.load() > 0 || g_record.load(), std::memory_order_relaxed);
    g_commit_hook.store(g_commit_delay_us.load() > 0, std::memory_order_relaxed);
}
} // namespace

void ReadHook(Span<const std::byte> key)
{
    if (g_record.load(std::memory_order_relaxed)) {
        LOCK(g_record_mutex);
        if (g_recorded.size() < MAX_RECORDED_KEYS) {
            g_recorded.emplace_back(reinterpret_cast<const char*>(key.data()), key.size());
        }
    }
    const int64_t delay = g_read_delay_us.load(std::memory_order_relaxed);
    if (delay > 0) std::this_thread::sleep_for(std::chrono::microseconds{delay});
}

void CommitHook()
{
    const int64_t delay = g_commit_delay_us.load(std::memory_order_relaxed);
    if (delay > 0) std::this_thread::sleep_for(std::chrono::microseconds{delay});
}

Snapshot Read()
{
    Snapshot s;
    s.chainstate_get_coin = g_chainstate_get_coin.load(std::memory_order_relaxed);
    s.chainstate_have_coin = g_chainstate_have_coin.load(std::memory_order_relaxed);
    s.db_reads = g_db_reads.load(std::memory_order_relaxed);
    s.db_exists = g_db_exists.load(std::memory_order_relaxed);
    s.wallet_commits = g_wallet_commits.load(std::memory_order_relaxed);
    s.wallet_commits_in_handler = g_wallet_commits_in_handler.load(std::memory_order_relaxed);
    return s;
}

void SetDbReadDelayUs(int64_t us)
{
    g_read_delay_us.store(us < 0 ? 0 : us);
    RefreshHooks();
}

void SetWalletCommitDelayUs(int64_t us)
{
    g_commit_delay_us.store(us < 0 ? 0 : us);
    RefreshHooks();
}

int64_t GetDbReadDelayUs() { return g_read_delay_us.load(); }
int64_t GetWalletCommitDelayUs() { return g_commit_delay_us.load(); }

void SetKeyRecorder(bool on)
{
    g_record.store(on);
    RefreshHooks();
}

void ClearRecordedKeys()
{
    LOCK(g_record_mutex);
    g_recorded.clear();
}

size_t RecordedKeyCount()
{
    LOCK(g_record_mutex);
    return g_recorded.size();
}

std::vector<std::string> RecordedKeys(size_t first)
{
    LOCK(g_record_mutex);
    if (first >= g_recorded.size()) return {};
    return std::vector<std::string>(g_recorded.begin() + first, g_recorded.end());
}

KeyOrderReport KeyOrder(const std::vector<std::string>& keys, unsigned char prefix)
{
    KeyOrderReport report;
    const std::string* previous{nullptr};
    for (const std::string& key : keys) {
        if (key.empty() || static_cast<unsigned char>(key[0]) != prefix) continue;
        ++report.keys;
        if (previous && key < *previous) ++report.inversions;
        previous = &key;
    }
    return report;
}

KeyOrderReport RecordedKeyOrder(unsigned char prefix, size_t first)
{
    return KeyOrder(RecordedKeys(first), prefix);
}

std::optional<std::string> CheckTestDelayOption(const std::string& name, int64_t value, bool is_regtest)
{
    if (!is_regtest) return name + " is only supported on regtest.";
    if (value < 0 || value > MAX_TEST_DELAY_US) return name + " must be between 0 and 1000000 microseconds.";
    return std::nullopt;
}

} // namespace iocounters
