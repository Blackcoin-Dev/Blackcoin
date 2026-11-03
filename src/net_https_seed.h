// Copyright (c) 2026 The Blackcoin Core developers
// Distributed under the MIT software license, see COPYING.
#ifndef BITCOIN_NET_HTTPS_SEED_H
#define BITCOIN_NET_HTTPS_SEED_H

#include <https_seed_client.h>
#include <netaddress.h>
#include <protocol.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <vector>

class NetGroupManager;
namespace httpsseed {
inline constexpr std::size_t MAX_BODY{64 * 1024};
inline constexpr std::size_t MAX_PEERS{64};
inline constexpr unsigned MAX_DEPTH{16};

struct Policy {
    bool mainnet{false};
    bool enabled{false};
    bool dnsseed{false};
    bool dns{false};
    bool automatic{false};
    bool network_active{false};
    int max_connections{0};
    bool ipv4{false};
    bool ipv6{false};
    bool explicit_onlynet{false};
    bool hostname_proxy{false};
};
bool Enabled(const Policy& policy);

struct ParseResult {
    bool valid{false};
    std::vector<CAddress> peers;
    std::string error;
};
/** Parse an untrusted directory. No lookup, socket, addrman or live-peer side effects. */
ParseResult Parse(std::string_view body, int64_t now, const NetGroupManager& groups,
                  bool ipv4, bool ipv6,
                  const std::function<bool(const CNetAddr&)>& excluded = {});
/** Canonical numeric public IP only; mapped/transition/scoped addresses are rejected. */
bool ParsePublicAddress(std::string_view text, CNetAddr& address);
/** Friend-only worker seam. Installed before a test thread starts and removed
 * after join. No production argument, RPC, network or trust override selects it. */
struct WorkerHooks {
    std::function<std::chrono::steady_clock::time_point()> now;
    std::function<bool()> wait;
    std::function<FetchResult(const TransportOptions&, const Cancel&)> fetch;
};
} // namespace httpsseed
#endif
