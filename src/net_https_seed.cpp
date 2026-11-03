// Copyright (c) 2026 The Blackcoin Core developers
// Distributed under the MIT software license, see COPYING.
#include <net_https_seed.h>

#include <compat/compat.h>
#include <netgroup.h>
#include <univalue.h>
#include <util/strencodings.h>

#include <algorithm>
#include <limits>
#include <map>
#include <set>

namespace httpsseed {
namespace {
bool ValidUTF8(std::string_view input)
{
    for (size_t i = 0; i < input.size();) {
        const auto first = static_cast<unsigned char>(input[i++]);
        if (!first) return false;
        if (first < 0x80) continue;
        unsigned remaining;
        uint32_t value, minimum;
        if (first >= 0xc2 && first <= 0xdf) { remaining = 1; value = first & 0x1f; minimum = 0x80; }
        else if (first >= 0xe0 && first <= 0xef) { remaining = 2; value = first & 0x0f; minimum = 0x800; }
        else if (first >= 0xf0 && first <= 0xf4) { remaining = 3; value = first & 0x07; minimum = 0x10000; }
        else return false;
        if (input.size() - i < remaining) return false;
        while (remaining--) {
            const auto next = static_cast<unsigned char>(input[i++]);
            if ((next & 0xc0) != 0x80) return false;
            value = (value << 6) | (next & 0x3f);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;
    }
    return true;
}

bool BoundedDepth(std::string_view input)
{
    unsigned depth{0};
    bool quoted{false}, escaped{false};
    for (const char ch : input) {
        if (quoted) {
            if (escaped) escaped = false;
            else if (ch == '\\') escaped = true;
            else if (ch == '"') quoted = false;
        } else if (ch == '"') quoted = true;
        else if (ch == '{' || ch == '[') { if (++depth > MAX_DEPTH) return false; }
        else if (ch == '}' || ch == ']') { if (!depth) return false; --depth; }
    }
    return !quoted && depth == 0;
}

bool UniqueKeys(const UniValue& value)
{
    if (value.isObject()) {
        const auto& keys = value.getKeys();
        if (std::set<std::string>(keys.begin(), keys.end()).size() != keys.size()) return false;
    }
    if (value.isObject() || value.isArray()) {
        for (const auto& child : value.getValues()) if (!UniqueKeys(child)) return false;
    }
    return true;
}

bool Integer(const UniValue& value, int64_t& number)
{
    if (!value.isNum()) return false;
    const auto& text = value.getValStr();
    if (text.empty() || text.find_first_not_of("0123456789") != std::string::npos) return false;
    return ParseInt64(text, &number);
}

bool Recent(int64_t value, int64_t now, int64_t maximum_age)
{
    return value >= now - maximum_age && value <= now + 5;
}
} // namespace

bool Enabled(const Policy& p)
{
    return p.mainnet && p.enabled && p.dnsseed && p.dns && p.automatic &&
           p.network_active && p.max_connections > 0 && (p.ipv4 || p.ipv6) &&
           (!p.hostname_proxy || !p.explicit_onlynet || p.ipv4 == p.ipv6);
}

bool ParsePublicAddress(std::string_view text, CNetAddr& address)
{
    if (text.empty() || text.size() > 45 || text.find('\0') != std::string_view::npos ||
        text.find('%') != std::string_view::npos) return false;
    const std::string numeric{text};
    in_addr v4{};
    in6_addr v6{};
    if (inet_pton(AF_INET, numeric.c_str(), &v4) == 1) {
        // Match the website's conservative public-unicast contract. Core's
        // historical routability predicate alone permits special-purpose space.
        const uint32_t ip = ntohl(v4.s_addr);
        const unsigned a = ip >> 24, b = (ip >> 16) & 255, c = (ip >> 8) & 255;
        if (a == 0 || a == 10 || a == 127 || a >= 224 ||
            (a == 100 && b >= 64 && b <= 127) || (a == 169 && b == 254) ||
            (a == 172 && b >= 16 && b <= 31) ||
            (a == 192 && ((b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99) || b == 168)) ||
            (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
            (a == 203 && b == 0 && c == 113)) return false;
        address = CNetAddr{v4};
    }
    else if (inet_pton(AF_INET6, numeric.c_str(), &v6) == 1) {
        // The contract permits native global-unicast IPv6 only (2000::/3).
        const unsigned first = (unsigned{v6.s6_addr[0]} << 8) | v6.s6_addr[1];
        const unsigned second = (unsigned{v6.s6_addr[2]} << 8) | v6.s6_addr[3];
        if (first < 0x2000 || first > 0x3fff ||
            (first == 0x2001 && (second < 0x0200 || second == 0x0db8)) ||
            first == 0x2002 || (first == 0x3fff && second < 0x1000)) return false;
        address = CNetAddr{v6};
        if (address.IsRFC3964() || address.IsRFC4380() || address.IsRFC6052() || address.IsRFC6145()) return false;
    } else return false;
    return address.IsValid() && address.IsRoutable() && address.ToStringAddr() == text;
}

ParseResult Parse(std::string_view body, int64_t now, const NetGroupManager& groups,
                  bool ipv4, bool ipv6, const std::function<bool(const CNetAddr&)>& excluded)
{
    ParseResult result;
    auto fail = [&](const char* reason) { result.error = reason; return result; };
    if (body.size() > MAX_BODY) return fail("body-limit");
    if (now < 900 || now > std::numeric_limits<int64_t>::max() - 1000) return fail("clock-range");
    if (!ValidUTF8(body) || !BoundedDepth(body)) return fail("encoding-or-depth");
    UniValue doc;
    if (!doc.read(body) || !doc.isObject() || !UniqueKeys(doc)) return fail("json");
    if (!doc["schema"].isStr() || doc["schema"].get_str() != "blackcoin.bootstrap/1" ||
        !doc["network"].isStr() || doc["network"].get_str() != "main") return fail("schema-or-network");
    int64_t generated, expires;
    if (!Integer(doc["generated_at"], generated) || !Integer(doc["expires_at"], expires) ||
        !Recent(generated, now, 120) || expires <= generated || expires - generated > 120 ||
        expires < now - 5) return fail("freshness");
    const auto& rows = doc["peers"];
    if (!rows.isArray() || rows.size() > MAX_PEERS) return fail("peer-limit");
    std::set<CNetAddr> seen;
    std::map<std::vector<unsigned char>, unsigned> counts;
    for (const auto& row : rows.getValues()) {
        if (!row.isObject() || !row["address"].isStr() || !row["services"].isStr()) continue;
        CNetAddr address;
        if (!ParsePublicAddress(row["address"].get_str(), address) ||
            (address.IsIPv4() ? !ipv4 : !ipv6) || (excluded && excluded(address))) continue;
        int64_t port, success;
        if (!Integer(row["port"], port) || port < 1 || port > 65535 ||
            !Integer(row["last_success"], success) || !Recent(success, now, 900) || success > generated + 5) continue;
        const auto& services = row["services"].get_str();
        if (services.size() != 16 || services.find_first_not_of("0123456789abcdef") != std::string::npos) continue;
        uint64_t bits{0};
        for (const char ch : services) bits = (bits << 4) | (ch <= '9' ? ch - '0' : ch - 'a' + 10);
        constexpr uint64_t allowed = NODE_NETWORK | NODE_NETWORK_LIMITED | NODE_WITNESS | NODE_QUANTUM_QUASAR;
        if ((bits & ~allowed) || !(bits & NODE_QUANTUM_QUASAR) ||
            (!(bits & NODE_NETWORK) && (bits & (NODE_NETWORK_LIMITED | NODE_WITNESS)) != (NODE_NETWORK_LIMITED | NODE_WITNESS))) continue;
        const auto group = groups.GetGroup(address);
        if (seen.count(address) || counts[group] >= 2) continue;
        seen.insert(address);
        ++counts[group];
        CAddress peer{CService{address, static_cast<uint16_t>(port)}, static_cast<ServiceFlags>(bits)};
        peer.nTime = NodeSeconds{std::chrono::seconds{success}};
        result.peers.push_back(peer);
    }
    result.valid = true;
    return result;
}
} // namespace httpsseed
