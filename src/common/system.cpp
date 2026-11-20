// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-present The Bitcoin Core developers
// Copyright (c) 2009-2022 Blackcoin Core Developers
// Copyright (c) 2009-2022 Blackcoin More Developers
// Copyright (c) 2009-2022 Blackcoin Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <common/system.h>

#include <logging.h>
#include <util/strencodings.h>
#include <util/string.h>
#include <util/time.h>

#ifndef WIN32
#include <sys/stat.h>
#include <unistd.h>
#else
#include <codecvt>
#endif

#if defined(__APPLE__)
#include <mach/mach.h>
#include <sys/sysctl.h>
#endif

#ifdef HAVE_MALLOPT_ARENA_MAX
#include <malloc.h>
#endif

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <locale>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>

// Application startup time (used for uptime calculation)
const int64_t nStartupTime = GetTime();

#ifndef WIN32
std::string ShellEscape(const std::string& arg)
{
    std::string escaped = arg;
    ReplaceAll(escaped, "'", "'\"'\"'");
    return "'" + escaped + "'";
}
#endif

#if HAVE_SYSTEM
void runCommand(const std::string& strCommand)
{
    if (strCommand.empty()) return;
#ifndef WIN32
    int nErr = ::system(strCommand.c_str());
#else
    int nErr = ::_wsystem(std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>,wchar_t>().from_bytes(strCommand).c_str());
#endif
    if (nErr)
        LogPrintf("runCommand error: system(%s) returned %d\n", strCommand, nErr);
}
#endif

void SetupEnvironment()
{
#ifdef HAVE_MALLOPT_ARENA_MAX
    // glibc-specific: On 32-bit systems set the number of arenas to 1.
    // By default, since glibc 2.10, the C library will create up to two heap
    // arenas per core. This is known to cause excessive virtual address space
    // usage in our usage. Work around it by setting the maximum number of
    // arenas to 1.
    if (sizeof(void*) == 4) {
        mallopt(M_ARENA_MAX, 1);
    }
#endif
    // On most POSIX systems (e.g. Linux, but not BSD) the environment's locale
    // may be invalid, in which case the "C.UTF-8" locale is used as fallback.
#if !defined(WIN32) && !defined(MAC_OSX) && !defined(__FreeBSD__) && !defined(__OpenBSD__) && !defined(__NetBSD__)
    try {
        std::locale(""); // Raises a runtime error if current locale is invalid
    } catch (const std::runtime_error&) {
        setenv("LC_ALL", "C.UTF-8", 1);
    }
#elif defined(WIN32)
    // Set the default input/output charset is utf-8
    SetConsoleCP(CP_UTF8);
    SetConsoleOutputCP(CP_UTF8);
#endif

#ifndef WIN32
    constexpr mode_t private_umask = 0077;
    umask(private_umask);
#endif
}

bool SetupNetworking()
{
#ifdef WIN32
    // Initialize Windows Sockets
    WSADATA wsadata;
    int ret = WSAStartup(MAKEWORD(2,2), &wsadata);
    if (ret != NO_ERROR || LOBYTE(wsadata.wVersion ) != 2 || HIBYTE(wsadata.wVersion) != 2)
        return false;
#endif
    return true;
}

int GetNumCores()
{
    return std::thread::hardware_concurrency();
}

std::optional<uint64_t> ParseMeminfoField(std::string_view meminfo, std::string_view field)
{
    for (const std::string& line : SplitString(meminfo, '\n')) {
        const std::string_view view{line};
        if (view.size() <= field.size() || view.substr(0, field.size()) != field || view[field.size()] != ':') continue;
        const std::string_view rest{TrimStringView(view.substr(field.size() + 1))};
        const std::string_view digits{rest.substr(0, std::min(rest.find_first_not_of("0123456789"), rest.size()))};
        const std::optional<uint64_t> kib{ToIntegral<uint64_t>(digits)};
        if (!kib || *kib > std::numeric_limits<uint64_t>::max() / 1024) return std::nullopt;
        return *kib * 1024;
    }
    return std::nullopt;
}

std::optional<uint64_t> ParseCgroupMemoryLimit(std::string_view contents)
{
    const std::optional<uint64_t> limit{ToIntegral<uint64_t>(TrimStringView(contents))};
    if (!limit || *limit == 0) return std::nullopt;
    return limit;
}

#if defined(__linux__)
namespace {
std::optional<std::string> ReadSmallFile(const std::string& path)
{
    std::ifstream file{path};
    if (!file.is_open()) return std::nullopt;
    std::ostringstream contents;
    contents << file.rdbuf();
    return contents.str();
}

//! The lowest memory limit of the control group of this process, if any.
std::optional<uint64_t> GetCgroupMemoryLimit()
{
    std::optional<uint64_t> lowest;
    const auto consider = [&lowest](const std::string& path) {
        const std::optional<std::string> contents{ReadSmallFile(path)};
        if (!contents) return;
        const std::optional<uint64_t> limit{ParseCgroupMemoryLimit(*contents)};
        if (limit && (!lowest || *limit < *lowest)) lowest = limit;
    };
    // Control groups v2: the group named in /proc/self/cgroup, then the root
    // of the mounted hierarchy (which is the group itself in a container).
    if (const std::optional<std::string> self{ReadSmallFile("/proc/self/cgroup")}) {
        for (const std::string& line : SplitString(*self, '\n')) {
            if (line.size() > 4 && line.substr(0, 4) == "0::/" && line.find("..") == std::string::npos) {
                consider("/sys/fs/cgroup" + line.substr(3) + "/memory.max");
            }
        }
    }
    consider("/sys/fs/cgroup/memory.max");
    // Control groups v1.
    consider("/sys/fs/cgroup/memory/memory.limit_in_bytes");
    return lowest;
}
} // namespace
#endif // __linux__

std::optional<uint64_t> GetTotalRAM()
{
#if defined(WIN32)
    MEMORYSTATUSEX status;
    status.dwLength = sizeof(status);
    if (!GlobalMemoryStatusEx(&status) || status.ullTotalPhys == 0) return std::nullopt;
    return uint64_t{status.ullTotalPhys};
#elif defined(__APPLE__)
    uint64_t bytes{0};
    size_t size{sizeof(bytes)};
    if (sysctlbyname("hw.memsize", &bytes, &size, nullptr, 0) != 0 || size != sizeof(bytes) || bytes == 0) return std::nullopt;
    return bytes;
#elif defined(_SC_PHYS_PAGES) && defined(_SC_PAGESIZE)
    const long pages{sysconf(_SC_PHYS_PAGES)};
    const long page_size{sysconf(_SC_PAGESIZE)};
    if (pages <= 0 || page_size <= 0) return std::nullopt;
    uint64_t total{static_cast<uint64_t>(pages) * static_cast<uint64_t>(page_size)};
#if defined(__linux__)
    if (const std::optional<uint64_t> limit{GetCgroupMemoryLimit()}) total = std::min(total, *limit);
#endif
    return total;
#else
    return std::nullopt;
#endif
}

std::optional<uint64_t> GetAvailableRAM()
{
    std::optional<uint64_t> available;
#if defined(WIN32)
    MEMORYSTATUSEX status;
    status.dwLength = sizeof(status);
    if (GlobalMemoryStatusEx(&status)) available = uint64_t{status.ullAvailPhys};
#elif defined(__APPLE__)
    const mach_port_t host{mach_host_self()};
    vm_statistics64_data_t stats;
    mach_msg_type_number_t count{HOST_VM_INFO64_COUNT};
    const kern_return_t result{host_statistics64(host, HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&stats), &count)};
    mach_port_deallocate(mach_task_self(), host);
    const long page_size{sysconf(_SC_PAGESIZE)};
    if (result == KERN_SUCCESS && page_size > 0) {
        available = (uint64_t{stats.free_count} + uint64_t{stats.inactive_count}) * static_cast<uint64_t>(page_size);
    }
#elif defined(__linux__)
    {
        std::ifstream meminfo{"/proc/meminfo"};
        if (meminfo.is_open()) {
            std::ostringstream contents;
            contents << meminfo.rdbuf();
            available = ParseMeminfoField(contents.str(), "MemAvailable");
        }
    }
#endif
    if (!available) return std::nullopt;
    if (const std::optional<uint64_t> total{GetTotalRAM()}) available = std::min(*available, *total);
    return available;
}

// Obtain the application startup time (used for uptime calculation)
int64_t GetStartupTime()
{
    return nStartupTime;
}
