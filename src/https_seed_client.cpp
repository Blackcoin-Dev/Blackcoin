// Copyright (c) 2026 The Blackcoin Core developers
// Distributed under the MIT software license, see COPYING.
#include <https_seed_client.h>

#include <compat/compat.h>
#include <httpsseed_ca.h>
#include <net_https_seed.h>
#include <random.h>
#include <util/strencodings.h>
#include <util/string.h>

#include <curl/curl.h>
#include <event2/dns.h>
#include <event2/event.h>
#include <event2/util.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <limits>
#include <memory>
#include <thread>

namespace httpsseed {
namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t MAX_HEADERS{16 * 1024};

struct CurlGlobal {
    bool ready{curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK};
    ~CurlGlobal() { if (ready) curl_global_cleanup(); }
};

struct DNSResult {
    bool complete{false};
    bool failed{false};
    std::vector<std::string> addresses;
};

void DNSCallback(int error, evutil_addrinfo* addresses, void* context)
{
    auto& result = *static_cast<DNSResult*>(context);
    result.complete = true;
    result.failed = error != 0;
    for (const auto* item = addresses; item; item = item->ai_next) {
        std::array<char, INET6_ADDRSTRLEN> text{};
        const void* raw{nullptr};
        if (item->ai_family == AF_INET && item->ai_addrlen >= sizeof(sockaddr_in)) {
            raw = &reinterpret_cast<const sockaddr_in*>(item->ai_addr)->sin_addr;
        } else if (item->ai_family == AF_INET6 && item->ai_addrlen >= sizeof(sockaddr_in6)) {
            raw = &reinterpret_cast<const sockaddr_in6*>(item->ai_addr)->sin6_addr;
        }
        if (raw && evutil_inet_ntop(item->ai_family, raw, text.data(), text.size())) {
            CNetAddr address;
            if (ParsePublicAddress(text.data(), address) && result.addresses.size() < 16) result.addresses.emplace_back(text.data());
        }
    }
    if (addresses) evutil_freeaddrinfo(addresses);
}

std::vector<std::string> Resolve(const std::string& hostname, const TransportOptions& options,
                                 Clock::time_point deadline, const Cancel& cancelled, const std::string& nameserver)
{
    std::unique_ptr<event_base, decltype(&event_base_free)> base{event_base_new(), event_base_free};
    if (!base) return {};
    std::unique_ptr<evdns_base, void(*)(evdns_base*)> dns{
        evdns_base_new(base.get(), nameserver.empty() ? EVDNS_BASE_INITIALIZE_NAMESERVERS : 0),
        [](evdns_base* ptr) { evdns_base_free(ptr, 0); }};
    if (!dns || (!nameserver.empty() && evdns_base_nameserver_ip_add(dns.get(), nameserver.c_str()) != 0)) return {};
    evutil_addrinfo hints{};
    hints.ai_family = options.ipv4 && options.ipv6 ? AF_UNSPEC : options.ipv4 ? AF_INET : AF_INET6;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    DNSResult result;
    auto* query = evdns_getaddrinfo(dns.get(), hostname.c_str(), nullptr, &hints, DNSCallback, &result);
    if (!query && !result.complete) return {};
    while (!result.complete && !cancelled() && Clock::now() < deadline) {
        if (event_base_loop(base.get(), EVLOOP_NONBLOCK) < 0) break;
        if (!result.complete) std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }
    if (!result.complete && query) {
        // libevent invokes the cancellation callback before the query is freed.
        evdns_getaddrinfo_cancel(query);
        result.failed = true;
    }
    // Free all resolver state while callback context is still alive, including
    // implementations that defer cancellation completion until base teardown.
    dns.reset();
    base.reset();
    if (cancelled() || Clock::now() >= deadline || !result.complete || result.failed) return {};
    return result.addresses;
}

struct Transfer {
    const Cancel& cancelled;
    Clock::time_point deadline;
    std::string body;
    size_t headers{0};
    bool bad{false};
    bool content_type{false};
    bool content_length{false};
    bool Stop() const { return cancelled() || Clock::now() >= deadline; }
};

size_t Write(char* bytes, size_t size, size_t count, void* context)
{
    auto& transfer = *static_cast<Transfer*>(context);
    if (size && count > std::numeric_limits<size_t>::max() / size) return 0;
    const size_t length = size * count;
    if (transfer.Stop() || length > MAX_BODY - transfer.body.size()) return 0;
    transfer.body.append(bytes, length);
    return length;
}

std::string LowerTrim(std::string_view text)
{
    while (!text.empty() && (text.front() == ' ' || text.front() == '\t')) text.remove_prefix(1);
    while (!text.empty() && (text.back() == ' ' || text.back() == '\t' || text.back() == '\r' || text.back() == '\n')) text.remove_suffix(1);
    std::string lower{text};
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return ToLower(c); });
    return lower;
}

size_t Header(char* bytes, size_t size, size_t count, void* context)
{
    auto& transfer = *static_cast<Transfer*>(context);
    if (size && count > std::numeric_limits<size_t>::max() / size) return 0;
    const size_t length = size * count;
    if (transfer.Stop() || length > MAX_HEADERS - transfer.headers) return 0;
    transfer.headers += length;
    const std::string_view line{bytes, length};
    const auto separator = line.find(':');
    if (separator == std::string_view::npos) return length;
    const auto name = LowerTrim(line.substr(0, separator));
    const auto value = LowerTrim(line.substr(separator + 1));
    if (name == "content-encoding" && value != "identity") transfer.bad = true;
    if (name == "content-type") {
        if (transfer.content_type || (value != "application/json" && value != "application/json; charset=utf-8")) transfer.bad = true;
        transfer.content_type = true;
    }
    if (name == "content-length") {
        uint64_t value_size{0};
        if (transfer.content_length || value.empty() || value.find_first_not_of("0123456789") != std::string::npos ||
            !ParseUInt64(value, &value_size) || value_size > MAX_BODY) transfer.bad = true;
        transfer.content_length = true;
    }
    return transfer.bad ? 0 : length;
}

int Progress(void* context, curl_off_t, curl_off_t, curl_off_t, curl_off_t)
{
    return static_cast<Transfer*>(context)->Stop() ? 1 : 0;
}

template <typename T>
bool Set(CURL* handle, CURLoption option, T value) { return curl_easy_setopt(handle, option, value) == CURLE_OK; }

FetchResult FetchConfigured(const TransportOptions& options, const Cancel& cancelled, const test::Endpoint& endpoint)
{
    FetchResult result;
    auto fail = [&](const char* reason) { result.error = reason; return result; };
    if (!InitializeTransport()) return fail("transport-init");
    if ((!options.ipv4 && !options.ipv6) || cancelled() || endpoint.ca_bundle.empty() || endpoint.timeout.count() <= 0) return fail("disabled");
    const auto deadline = Clock::now() + endpoint.timeout;
    // All host/port/path inputs are compiled constants or isolated C++ test injection.
    if (endpoint.hostname.empty() || endpoint.hostname.find_first_of("/:@?#\\\r\n") != std::string::npos ||
        !endpoint.port || endpoint.path.empty() || endpoint.path.front() != '/' ||
        endpoint.path.find_first_of("\r\n") != std::string::npos) return fail("endpoint");
    std::vector<std::string> addresses = endpoint.numeric_addresses;
    if (!options.proxy && addresses.empty()) addresses = Resolve(endpoint.hostname, options, deadline, cancelled, endpoint.dns_server);
    if (cancelled() || Clock::now() >= deadline) return fail("cancelled-or-deadline");
    if (!options.proxy && addresses.empty()) return fail("dns");

    std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> easy{curl_easy_init(), curl_easy_cleanup};
    std::unique_ptr<CURLM, decltype(&curl_multi_cleanup)> multi{curl_multi_init(), curl_multi_cleanup};
    if (!easy || !multi) return fail("allocation");
    std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> resolution{nullptr, curl_slist_free_all};
    if (!options.proxy) {
        std::string mapping = endpoint.hostname + ':' + ToString(endpoint.port) + ':';
        for (size_t i = 0; i < addresses.size(); ++i) {
            // For tests loopback is intentional; production resolver already screened routability.
            in_addr v4{};
            in6_addr v6{};
            const bool is_v4 = evutil_inet_pton(AF_INET, addresses[i].c_str(), &v4) == 1;
            const bool is_v6 = evutil_inet_pton(AF_INET6, addresses[i].c_str(), &v6) == 1;
            if ((!is_v4 && !is_v6) || (is_v4 && !options.ipv4) || (is_v6 && !options.ipv6)) return fail("resolution-family");
            if (i) mapping += ',';
            mapping += is_v6 ? '[' + addresses[i] + ']' : addresses[i];
        }
        resolution.reset(curl_slist_append(nullptr, mapping.c_str()));
        if (!resolution || !Set(easy.get(), CURLOPT_RESOLVE, resolution.get())) return fail("resolve-option");
    }
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
    if (remaining <= 0) return fail("deadline");
    const std::string url = "https://" + endpoint.hostname + ':' + ToString(endpoint.port) + endpoint.path;
    const std::string ca{endpoint.ca_bundle};
    curl_blob blob{const_cast<char*>(ca.data()), ca.size(), CURL_BLOB_COPY};
    Transfer transfer{cancelled, deadline, {}, 0, false, false, false};
    const auto timeout = static_cast<long>(std::min<int64_t>(remaining, std::numeric_limits<long>::max()));
    CURL* handle = easy.get();
#if LIBCURL_VERSION_NUM >= 0x075500
    if (!Set(handle, CURLOPT_PROTOCOLS_STR, "https") || !Set(handle, CURLOPT_REDIR_PROTOCOLS_STR, "https")) return fail("protocol-option");
#else
    if (!Set(handle, CURLOPT_PROTOCOLS, static_cast<long>(CURLPROTO_HTTPS)) ||
        !Set(handle, CURLOPT_REDIR_PROTOCOLS, static_cast<long>(CURLPROTO_HTTPS))) return fail("protocol-option");
#endif
    if (!Set(handle, CURLOPT_URL, url.c_str()) || !Set(handle, CURLOPT_USERAGENT, options.user_agent.c_str()) ||
        !Set(handle, CURLOPT_FOLLOWLOCATION, 0L) || !Set(handle, CURLOPT_MAXREDIRS, 0L) ||
        !Set(handle, CURLOPT_HTTP_VERSION, static_cast<long>(CURL_HTTP_VERSION_1_1)) ||
        !Set(handle, CURLOPT_SSL_VERIFYPEER, 1L) || !Set(handle, CURLOPT_SSL_VERIFYHOST, 2L) ||
        !Set(handle, CURLOPT_SSLVERSION, static_cast<long>(CURL_SSLVERSION_TLSv1_2)) ||
        !Set(handle, CURLOPT_CAINFO_BLOB, &blob) ||
        !Set(handle, CURLOPT_SSL_OPTIONS, 0L) ||
        !Set(handle, CURLOPT_HTTPAUTH, static_cast<long>(CURLAUTH_NONE)) || !Set(handle, CURLOPT_HTTP_CONTENT_DECODING, 0L) ||
        !Set(handle, CURLOPT_NOSIGNAL, 1L) || !Set(handle, CURLOPT_TIMEOUT_MS, timeout) ||
        !Set(handle, CURLOPT_CONNECTTIMEOUT_MS, std::min(5000L, timeout)) ||
        !Set(handle, CURLOPT_IPRESOLVE, static_cast<long>(options.proxy || (options.ipv4 && options.ipv6) ? CURL_IPRESOLVE_WHATEVER : options.ipv4 ? CURL_IPRESOLVE_V4 : CURL_IPRESOLVE_V6)) ||
        !Set(handle, CURLOPT_NOPROXY, "") || !Set(handle, CURLOPT_WRITEFUNCTION, Write) ||
        !Set(handle, CURLOPT_WRITEDATA, &transfer) || !Set(handle, CURLOPT_HEADERFUNCTION, Header) ||
        !Set(handle, CURLOPT_HEADERDATA, &transfer) || !Set(handle, CURLOPT_NOPROGRESS, 0L) ||
        !Set(handle, CURLOPT_XFERINFOFUNCTION, Progress) || !Set(handle, CURLOPT_XFERINFODATA, &transfer)) return fail("curl-option");
    // The pinned curl compiles netrc out. Host development builds must explicitly
    // ignore it; UNKNOWN_OPTION also means this old option was compiled out.
    const auto netrc = curl_easy_setopt(handle, CURLOPT_NETRC, static_cast<long>(CURL_NETRC_IGNORED));
    if (netrc != CURLE_OK && netrc != CURLE_UNKNOWN_OPTION && netrc != CURLE_NOT_BUILT_IN) return fail("netrc-option");
    std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> headers{curl_slist_append(nullptr, "Accept: application/json"), curl_slist_free_all};
    if (!headers || !Set(handle, CURLOPT_HTTPHEADER, headers.get())) return fail("header-option");
    if (options.proxy) {
        const auto& proxy = *options.proxy;
        if (!proxy.IsValid() || !Set(handle, CURLOPT_PROXY, proxy.proxy.ToStringAddrPort().c_str()) ||
            !Set(handle, CURLOPT_PROXYTYPE, static_cast<long>(CURLPROXY_SOCKS5_HOSTNAME))) return fail("proxy-option");
        if (proxy.randomize_credentials) {
            const std::string user = GetRandHash().GetHex();
            const std::string password = GetRandHash().GetHex();
            if (!Set(handle, CURLOPT_PROXYUSERNAME, user.c_str()) || !Set(handle, CURLOPT_PROXYPASSWORD, password.c_str())) return fail("proxy-auth");
        }
    } else if (!Set(handle, CURLOPT_PROXY, "")) return fail("proxy-disable");
    if (curl_multi_add_handle(multi.get(), handle) != CURLM_OK) return fail("multi-add");
    int running{1};
    CURLMcode code{CURLM_OK};
    while (running && !transfer.Stop()) {
        code = curl_multi_perform(multi.get(), &running);
        if (code != CURLM_OK || !running) break;
        const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
        if (left <= 0) break;
        code = curl_multi_poll(multi.get(), nullptr, 0, static_cast<int>(std::min<int64_t>(100, left)), nullptr);
        if (code != CURLM_OK) break;
    }
    CURLcode completion{CURLE_ABORTED_BY_CALLBACK};
    int pending{0};
    while (auto* message = curl_multi_info_read(multi.get(), &pending)) {
        if (message->msg == CURLMSG_DONE && message->easy_handle == handle) completion = message->data.result;
    }
    curl_multi_remove_handle(multi.get(), handle);
    long status{0};
    if (transfer.Stop()) return fail("cancelled-or-deadline");
    if (code != CURLM_OK || completion != CURLE_OK || transfer.bad || !transfer.content_type ||
        curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &status) != CURLE_OK || status != 200) return fail("https-response");
    result.success = true;
    result.body = std::move(transfer.body);
    return result;
}
} // namespace

bool SupportedBackend(uint32_t version, bool has_tls, std::string_view backend)
{
    return has_tls && version >= 0x074d00 && backend.find("OpenSSL/") == 0;
}

bool InitializeTransport()
{
    static CurlGlobal global;
    if (!global.ready) return false;
    const auto* info = curl_version_info(CURLVERSION_NOW);
    return info && info->ssl_version &&
           SupportedBackend(info->version_num, info->features & CURL_VERSION_SSL, info->ssl_version);
}

FetchResult Fetch(const TransportOptions& options, const Cancel& cancelled)
{
    test::Endpoint endpoint;
    endpoint.hostname = "projectblackcoin.org";
    endpoint.path = "/api/bootstrap/v1/peers";
    endpoint.ca_bundle.assign(CA_BUNDLE, CA_BUNDLE_SIZE);
    return FetchConfigured(options, cancelled, endpoint);
}

FetchResult test::Fetch(const TransportOptions& options, const Cancel& cancelled, const Endpoint& endpoint)
{
    return FetchConfigured(options, cancelled, endpoint);
}
} // namespace httpsseed
