// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <util/thread_qos.h>

#include <tinyformat.h>

#include <atomic>
#include <ctime>

#if defined(__APPLE__)
#include <pthread.h>
#include <pthread/qos.h>
#endif

namespace util {

namespace {
// 0 unknown, 1 inactive, 2 active
std::atomic<int> g_app_active_hint{0};
std::atomic<bool> g_default_qos_user_initiated{false};
} // namespace

bool SetCurrentThreadQosUserInitiated()
{
#if defined(__APPLE__)
    return pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) == 0;
#else
    return false;
#endif
}

void SetDefaultThreadQosUserInitiated(bool enabled)
{
    g_default_qos_user_initiated.store(enabled, std::memory_order_relaxed);
}

void ApplyDefaultThreadQos()
{
    if (g_default_qos_user_initiated.load(std::memory_order_relaxed)) SetCurrentThreadQosUserInitiated();
}

std::optional<std::string> CurrentThreadQosName()
{
#if defined(__APPLE__)
    switch (qos_class_self()) {
    case QOS_CLASS_USER_INTERACTIVE: return "user-interactive";
    case QOS_CLASS_USER_INITIATED: return "user-initiated";
    case QOS_CLASS_DEFAULT: return "default";
    case QOS_CLASS_UTILITY: return "utility";
    case QOS_CLASS_BACKGROUND: return "background";
    case QOS_CLASS_UNSPECIFIED: return "unspecified";
    }
    return "unknown";
#else
    return std::nullopt;
#endif
}

std::optional<int64_t> CurrentThreadCpuMicros()
{
#if defined(CLOCK_THREAD_CPUTIME_ID)
    timespec ts{};
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) return std::nullopt;
    return int64_t{ts.tv_sec} * 1000000 + ts.tv_nsec / 1000;
#else
    return std::nullopt;
#endif
}

void SetApplicationActiveHint(bool active)
{
    g_app_active_hint.store(active ? 2 : 1, std::memory_order_relaxed);
}

std::optional<bool> GetApplicationActiveHint()
{
    switch (g_app_active_hint.load(std::memory_order_relaxed)) {
    case 1: return false;
    case 2: return true;
    default: return std::nullopt;
    }
}

std::string FormatThreadLoadContext(std::optional<int64_t> cpu_start_us)
{
    std::string out;
    if (cpu_start_us) {
        if (const std::optional<int64_t> now = CurrentThreadCpuMicros()) {
            out += strprintf(" thread-cpu=%d ms", (*now - *cpu_start_us) / 1000);
        }
    }
    if (const std::optional<std::string> qos = CurrentThreadQosName()) out += strprintf(" qos=%s", *qos);
    if (const std::optional<bool> active = GetApplicationActiveHint()) out += strprintf(" app=%s", *active ? "active" : "inactive");
    return out;
}

} // namespace util
