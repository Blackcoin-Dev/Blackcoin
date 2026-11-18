// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-2022 Blackcoin Core Developers
// Copyright (c) 2009-2022 Blackcoin More Developers
// Copyright (c) 2009-2022 Blackcoin Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_COMMON_SYSTEM_H
#define BITCOIN_COMMON_SYSTEM_H

#if defined(HAVE_CONFIG_H)
#include <config/bitcoin-config.h>
#endif

#include <compat/assumptions.h>
#include <compat/compat.h>

#include <optional>
#include <set>
#include <stdint.h>
#include <string>
#include <string_view>

// Application startup time (used for uptime calculation)
int64_t GetStartupTime();

void SetupEnvironment();
bool SetupNetworking();
#ifndef WIN32
std::string ShellEscape(const std::string& arg);
#endif
#if HAVE_SYSTEM
void runCommand(const std::string& strCommand);
#endif

/**
 * Return the number of cores available on the current system.
 * @note This does count virtual cores, such as those provided by HyperThreading.
 */
int GetNumCores();

/**
 * Return the physical memory of this system in bytes, or nullopt when it
 * cannot be determined. On Linux a memory limit of the control group the
 * process runs in lowers the result.
 */
std::optional<uint64_t> GetTotalRAM();

/**
 * Return an estimate of the memory in bytes that can be used without
 * swapping (free memory plus what the system can reclaim), or nullopt when it
 * cannot be determined. Never more than GetTotalRAM().
 */
std::optional<uint64_t> GetAvailableRAM();

/**
 * Return the value in bytes of a "<field>:   <n> kB" line of /proc/meminfo
 * style text, or nullopt when the field is absent or malformed.
 */
std::optional<uint64_t> ParseMeminfoField(std::string_view meminfo, std::string_view field);

/**
 * Parse the contents of a control group memory limit file (memory.max or
 * memory.limit_in_bytes). Returns nullopt for "max", zero or malformed text.
 */
std::optional<uint64_t> ParseCgroupMemoryLimit(std::string_view contents);

#endif // BITCOIN_COMMON_SYSTEM_H
