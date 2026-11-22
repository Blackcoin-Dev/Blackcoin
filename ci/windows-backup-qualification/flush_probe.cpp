// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

// Qualification-only probe for the one branch the daemon-level tests cannot reach: the FlushFileBuffers call that
// makes a backup directory durable on Windows (src/wallet/quantum_return_backup.cpp, FlushDirectoryWindows).
//
// The REAL implementation file is compiled into this executable, by including it below; nothing of its algorithm is
// copied. Everything it calls is the real Windows API (CreateFileW, GetFinalPathNameByHandleW,
// GetVolumeInformationByHandleW, GetDriveTypeW, CloseHandle), with ONE exception: FlushFileBuffers is renamed by a
// macro, after <windows.h> declared the real function and before the real file is included, to a shim that either
// forwards to the real FlushFileBuffers or, for a selected directory, fails with ERROR_WRITE_FAULT. The shipping
// daemon is not changed and is not involved.
//
// What is stubbed, and why (the real file pulls in the whole wallet-less base of the node otherwise): Params() (a
// regtest chain object with no consensus data: the file asks only IsTestChain()), GetRandBytes (a generator for the
// random file-name suffix, which is not under test), assertion_fail, GetUniquePath. Everything else is the real
// source file of the tree (see build-probe.sh for the list).
//
// Usage: flush_probe.exe --root <existing empty directory on a local NTFS volume>
// Prints one JSON document to stdout and exits 0 when every check passed, 1 otherwise, 2 on a usage error.

#ifdef WIN32
#include <windows.h>
#include <winerror.h>

//! The shim, declared before the real implementation file is included (defined below it).
BOOL WINAPI qualification_FlushFileBuffers(HANDLE handle);
#define FlushFileBuffers qualification_FlushFileBuffers
#endif

// The real implementation, not a copy.
#include <wallet/quantum_return_backup.cpp>

#ifdef WIN32
#undef FlushFileBuffers
#endif

#include <chainparams.h>
#include <chainparamsbase.h>
#include <common/args.h>
#include <random.h>
#include <util/check.h>
#include <util/getuniquepath.h>

#include <cstdlib>
#include <iostream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

// ----- stubs for what the real file needs and the probe does not test -----
namespace {
struct ProbeParams : CChainParams {
    ProbeParams() { m_chain_type = ChainType::REGTEST; }
};
} // namespace

const CChainParams& Params()
{
    static const ProbeParams params;
    return params;
}

void GetRandBytes(Span<unsigned char> bytes) noexcept
{
    std::random_device device;
    for (unsigned char& byte : bytes) byte = static_cast<unsigned char>(device());
}

void assertion_fail(std::string_view file, int line, std::string_view func, std::string_view assertion)
{
    std::cerr << "assertion failed: " << file << ":" << line << " " << func << " " << assertion << std::endl;
    std::abort();
}

fs::path GetUniquePath(const fs::path& base)
{
    std::random_device device;
    std::ostringstream name;
    name << device();
    return base / fs::PathFromString(name.str());
}

// ----- the injection shim -----
namespace {
//! Which directory handles fail: the final path component that selects them (empty: injection is off).
std::string g_inject_name;
int g_calls{0};      //!< every call the real code made
int g_forwarded{0};  //!< calls forwarded to the real FlushFileBuffers
int g_forwarded_ok{0};
int g_injected{0};   //!< calls that were made to fail
std::vector<std::string> g_seen; //!< the final component of each handle, in call order

std::string Narrow(const std::wstring& wide)
{
    std::string narrow;
    for (const wchar_t c : wide) narrow.push_back(c < 0x80 ? static_cast<char>(c) : '?');
    return narrow;
}

std::string Num(int value)
{
    std::ostringstream out;
    out << value;
    return out.str();
}

std::string Lower(std::string value)
{
    for (char& c : value) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c);
    return value;
}

#ifdef WIN32
//! The final component of the directory a handle is open on (GetFinalPathNameByHandleW, DOS names).
std::string FinalComponent(HANDLE handle)
{
    wchar_t buffer[4096];
    const DWORD length = ::GetFinalPathNameByHandleW(handle, buffer, 4096, 0);
    if (length == 0 || length >= 4096) return "?";
    std::wstring path{buffer, length};
    while (path.size() > 3 && path.back() == L'\\') path.pop_back();
    const size_t slash = path.find_last_of(L'\\');
    return Narrow(slash == std::wstring::npos ? path : path.substr(slash + 1));
}
#endif
} // namespace

#ifdef WIN32
BOOL WINAPI qualification_FlushFileBuffers(HANDLE handle)
{
    ++g_calls;
    const std::string name = FinalComponent(handle);
    g_seen.push_back(name);
    if (!g_inject_name.empty() && Lower(name) == Lower(g_inject_name)) {
        ++g_injected;
        ::SetLastError(ERROR_WRITE_FAULT);
        return FALSE;
    }
    ++g_forwarded;
    const BOOL ok = ::FlushFileBuffers(handle); // the real function: the macro is undefined here
    if (ok) ++g_forwarded_ok;
    return ok;
}
#endif

// ----- the checks -----
namespace {
struct Check {
    std::string name;
    std::string expected;
    std::string observed;
    bool pass;
};
std::vector<Check> g_checks;

void Record(const std::string& name, const std::string& expected, const std::string& observed, bool pass)
{
    g_checks.push_back({name, expected, observed, pass});
}

std::string Escape(const std::string& text)
{
    std::string out;
    for (const char c : text) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                out += '?';
            } else {
                out += c;
            }
        }
    }
    return out;
}

std::string Join(const std::vector<std::string>& items)
{
    std::string out;
    for (const std::string& item : items) out += (out.empty() ? "" : ",") + item;
    return out;
}

bool Contains(const std::string& text, const std::string& needle)
{
    return text.find(needle) != std::string::npos;
}

void ResetCounters()
{
    g_calls = g_forwarded = g_forwarded_ok = g_injected = 0;
    g_seen.clear();
}

int Report(const std::string& root, const std::string& detail)
{
    bool all = !g_checks.empty();
    for (const Check& check : g_checks) all = all && check.pass;
    std::cout << "{\"tool\":\"flush_probe\",\"source\":\"src/wallet/quantum_return_backup.cpp compiled in\",\"root\":\""
              << Escape(root) << "\",\"detail\":\"" << Escape(detail) << "\",\"pass\":" << (all ? "true" : "false")
              << ",\"checks\":[";
    for (size_t i = 0; i < g_checks.size(); ++i) {
        const Check& check = g_checks[i];
        std::cout << (i ? "," : "") << "{\"name\":\"" << Escape(check.name) << "\",\"expected\":\"" << Escape(check.expected)
                  << "\",\"observed\":\"" << Escape(check.observed) << "\",\"pass\":" << (check.pass ? "true" : "false") << "}";
    }
    std::cout << "]}" << std::endl;
    return all ? 0 : 1;
}
} // namespace

int main(int argc, char** argv)
{
    std::string root_arg;
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::string{argv[i]} == "--root") root_arg = argv[i + 1];
    }
    if (root_arg.empty()) {
        std::cerr << "usage: flush_probe --root <existing directory>" << std::endl;
        return 2;
    }
    const fs::path root = fs::absolute(fs::PathFromString(root_arg));
    if (!fs::is_directory(root)) {
        std::cerr << "the root is not an existing directory: " << root_arg << std::endl;
        return 2;
    }
    const fs::path datadir = root / "data";
    fs::create_directories(datadir / "regtest");
    gArgs.ForceSetArg("-datadir", fs::PathToString(datadir));
    SelectBaseParams(ChainType::REGTEST);
    const fs::path network_dir = gArgs.GetDataDirNet();
    const fs::path base = network_dir / "quantum-key-backups";
    std::string detail = "network datadir " + fs::PathToString(network_dir);

#ifndef WIN32
    // Not a Windows build: the injection needs the Windows API. Build and link are exercised, the checks are not.
    Record("windows-only", "this probe runs on Windows", "built without WIN32; nothing was injected", false);
    return Report(fs::PathToString(root), detail);
#else
    // 1. Real success, no injection. The walk flushes the wallet directory, then each ancestor up to the datadir.
    {
        const fs::path directory = base / "n_realok";
        std::string error;
        ResetCounters();
        const bool ok = wallet::EnsureQuantumKeyBackupDirectory(directory, error);
        // n_realok, quantum-key-backups, regtest: three directory handles, each flushed by the real API.
        Record("real-success", "EnsureQuantumKeyBackupDirectory succeeds; 3 directory handles flushed by the real FlushFileBuffers",
               "returned " + std::string(ok ? "true" : "false") + ", error '" + error + "', calls " + Num(g_calls) +
                   ", real successes " + Num(g_forwarded_ok) + ", handles " + Join(g_seen),
               ok && error.empty() && g_calls == 3 && g_forwarded == 3 && g_forwarded_ok == 3 && g_injected == 0);
        std::error_code ec;
        Record("real-success-directory-exists", "the wallet directory exists", fs::is_directory(directory, ec) ? "yes" : "no",
               fs::is_directory(directory, ec));
    }

    // 2. Injected ERROR_WRITE_FAULT on the handle of the wallet's own directory.
    const fs::path injected_dir = base / "n_inject";
    {
        std::string error;
        g_inject_name = "n_inject";
        ResetCounters();
        const bool ok = wallet::EnsureQuantumKeyBackupDirectory(injected_dir, error);
        Record("injected-leaf-fails", "returns false, error names the directory and 'flushing it failed', the shim injected once",
               "returned " + std::string(ok ? "true" : "false") + ", error '" + error + "', injected " + Num(g_injected),
               !ok && g_injected == 1 && Contains(error, "cannot make the backup directory") && Contains(error, "n_inject") &&
                   Contains(error, "flushing it failed"));
        std::error_code ec;
        Record("injected-leaf-keeps-directory", "the directory made by the failed attempt still exists",
               fs::is_directory(injected_dir, ec) ? "yes" : "no", fs::is_directory(injected_dir, ec));
    }

    // 3. Injection off: the retry on the EXISTING directories succeeds.
    {
        std::string error;
        g_inject_name.clear();
        ResetCounters();
        const bool ok = wallet::EnsureQuantumKeyBackupDirectory(injected_dir, error);
        Record("retry-after-leaf-failure", "succeeds on the existing directories, 3 real flushes",
               "returned " + std::string(ok ? "true" : "false") + ", error '" + error + "', calls " + Num(g_calls),
               ok && error.empty() && g_calls == 3 && g_forwarded_ok == 3 && g_injected == 0);
    }

    // 4. Injected on an ANCESTOR (the base directory): the walk reaches it after the wallet directory flushed fine.
    const fs::path ancestor_dir = base / "n_inject_ancestor";
    {
        std::string error;
        g_inject_name = "quantum-key-backups";
        ResetCounters();
        const bool ok = wallet::EnsureQuantumKeyBackupDirectory(ancestor_dir, error);
        Record("injected-ancestor-fails", "returns false, error names quantum-key-backups and 'flushing it failed'; the wallet directory flushed first",
               "returned " + std::string(ok ? "true" : "false") + ", error '" + error + "', injected " + Num(g_injected) +
                   ", handles " + Join(g_seen),
               !ok && g_injected == 1 && Contains(error, "quantum-key-backups") && Contains(error, "flushing it failed") &&
                   g_seen.size() == 2 && g_seen[0] == "n_inject_ancestor");
        g_inject_name.clear();
        ResetCounters();
        const bool retried = wallet::EnsureQuantumKeyBackupDirectory(ancestor_dir, error);
        Record("retry-after-ancestor-failure", "succeeds on the existing directories", retried ? "true" : "false: " + error,
               retried && g_forwarded_ok == 3);
    }

    // 5. Control: the real API was reached in every success case and the shim is the only difference.
    Record("shim-forwards", "the shim forwarded real calls (it is not the whole implementation)",
           "forwarded in the last run: " + Num(g_forwarded), g_forwarded >= 3);
    return Report(fs::PathToString(root), detail);
#endif
}
