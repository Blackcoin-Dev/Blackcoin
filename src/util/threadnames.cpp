// Copyright (c) 2018-2022 Blackcoin Core Developers
// Copyright (c) 2018-2022 Blackcoin More Developers
// Copyright (c) 2018-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#if defined(HAVE_CONFIG_H)
#include <config/bitcoin-config.h>
#endif

#include <algorithm>
#include <cstring>
#include <string>
#include <thread>
#include <utility>

#if (defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__DragonFly__))
#include <pthread.h>
#include <pthread_np.h>
#endif

#include <util/threadnames.h>

#ifdef HAVE_SYS_PRCTL_H
#include <sys/prctl.h>
#endif

//! Set the thread's name at the process level. Does not affect the
//! internal name.
static void SetThreadName(const char* name)
{
#if defined(PR_SET_NAME)
    // Only the first 15 characters are used (16 - NUL terminator)
    ::prctl(PR_SET_NAME, name, 0, 0, 0);
#elif (defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__DragonFly__))
    pthread_set_name_np(pthread_self(), name);
#elif defined(MAC_OSX)
    pthread_setname_np(name);
#else
    // Prevent warnings for unused parameters...
    (void)name;
#endif
}

// If we have thread_local, keep the name in a trivially destructible buffer.
#if defined(HAVE_THREAD_LOCAL)

/**
 * Avoid a destructor-bearing thread_local object. Lock-order history can
 * outlive a short-lived worker thread, and diagnostic locations must own a
 * stable copy rather than reference destroyed per-thread storage.
 */
static thread_local char g_thread_name[128]{'\0'};
std::string util::ThreadGetInternalName() { return g_thread_name; }
//! Set the in-memory internal name for this thread. Does not affect the process
//! name.
static void SetInternalName(const std::string& name)
{
    const size_t copy_bytes{std::min(sizeof(g_thread_name) - 1, name.size())};
    std::memcpy(g_thread_name, name.data(), copy_bytes);
    g_thread_name[copy_bytes] = '\0';
}

// Without thread_local available, don't handle internal name at all.
#else

std::string util::ThreadGetInternalName() { return ""; }
static void SetInternalName(const std::string& name) { }
#endif

void util::ThreadRename(const std::string& name)
{
    SetThreadName(("b-" + name).c_str());
    SetInternalName(name);
}

void util::ThreadSetInternalName(const std::string& name)
{
    SetInternalName(name);
}
