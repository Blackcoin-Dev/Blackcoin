// Copyright (c) 2026 The Blackcoin Core developers
// Distributed under the MIT software license, see COPYING.
#ifndef BITCOIN_HTTPS_SEED_CLIENT_H
#define BITCOIN_HTTPS_SEED_CLIENT_H

#include <netbase.h>

#include <chrono>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <cstdint>
#include <vector>

namespace httpsseed {
struct TransportOptions {
    bool ipv4{false};
    bool ipv6{false};
    std::optional<Proxy> proxy;
    std::string user_agent;
};
struct FetchResult {
    bool success{false};
    std::string body;
    std::string error;
};
using Cancel = std::function<bool()>;
/** Global initialization runs before network workers. No process-global cleanup races. */
bool InitializeTransport();
/** Unsupported builds disable only this supplementary source. */
bool SupportedBackend(uint32_t version, bool has_tls, std::string_view backend);
FetchResult Fetch(const TransportOptions& options, const Cancel& cancelled);

namespace test {
/** C++ harness injection only. Production has no URL/CA/deadline override argument. */
struct Endpoint {
    std::string hostname;
    uint16_t port{443};
    std::string path;
    std::string ca_bundle;
    std::vector<std::string> numeric_addresses;
    std::chrono::milliseconds timeout{10000};
    std::string dns_server; // Isolated numeric nameserver injection for cancellation tests.
};
FetchResult Fetch(const TransportOptions& options, const Cancel& cancelled, const Endpoint& endpoint);
} // namespace test
} // namespace httpsseed
#endif
