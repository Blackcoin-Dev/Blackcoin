// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_UTIL_THREAD_QOS_H
#define BITCOIN_UTIL_THREAD_QOS_H

#include <cstdint>
#include <optional>
#include <string>

namespace util {

/**
 * Ask the scheduler to treat the calling thread as user-initiated work. On
 * macOS this is pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED); a
 * thread left at the default or a background class can be put on the
 * efficiency cores. Threads created afterwards by this thread inherit the
 * class. Returns true when the class was set; always false on a platform that
 * has no such notion (nothing changes there).
 */
bool SetCurrentThreadQosUserInitiated();

/**
 * Opt the whole process in to running every thread started with
 * util::TraceThread as user-initiated work (see above). A thread started by a
 * thread of this class does not inherit the class (measured on macOS), so the
 * GUI sets this once before it starts the node and every node thread asks for
 * the class itself as it starts. Off by default: the daemon is unchanged.
 */
void SetDefaultThreadQosUserInitiated(bool enabled);
/** Called by util::TraceThread at thread start: sets the class when the process opted in. */
void ApplyDefaultThreadQos();

/** Name of the calling thread's QoS class ("user-interactive", "user-initiated", ...); nullopt off macOS. */
std::optional<std::string> CurrentThreadQosName();

/** CPU time used so far by the calling thread, in microseconds; nullopt where the platform has no per-thread clock. */
std::optional<int64_t> CurrentThreadCpuMicros();

/**
 * Whether the application is the active (frontmost) one, as last reported by
 * the GUI. The wallet has no Qt dependency, so the GUI publishes the state
 * here and the wallet load log lines read it. Unknown until the GUI sets it
 * (always unknown in the daemon).
 */
void SetApplicationActiveHint(bool active);
std::optional<bool> GetApplicationActiveHint();

/** " cpu=N ms qos=X app=active" style suffix for load timing lines; start is a CurrentThreadCpuMicros() reading. */
std::string FormatThreadLoadContext(std::optional<int64_t> cpu_start_us);

} // namespace util

#endif // BITCOIN_UTIL_THREAD_QOS_H
