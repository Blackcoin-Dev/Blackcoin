// Copyright (c) 2026 The Blackcoin Core developers
// Distributed under the MIT software license, see COPYING.
#include <addrman.h>
#include <https_seed_client.h>
#include <net_processing.h>
#include <netmessagemaker.h>
#include <logging.h>
#include <test/util/logging.h>
#include <test/util/net.h>
#include <util/time.h>
#include <util/strencodings.h>
#include <util/string.h>
#include <version.h>
#include <net_https_seed.h>
#include <timedata.h>
#include <netgroup.h>
#include <test/util/setup_common.h>
#include <univalue.h>
#include <util/sock.h>

#include <openssl/ssl.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <condition_variable>
#include <fstream>
#include <sstream>
#include <mutex>
#include <limits>
#include <memory>
#include <stdexcept>
#include <thread>
#include <string>

#if !defined(WIN32) && !defined(SO_NOSIGPIPE)
#include <future>
#include <pthread.h>
#include <signal.h>
#endif

namespace {
constexpr int64_t NOW{1793670000};
UniValue Peer(const std::string& address = "8.8.8.8", int port = 23800)
{
    UniValue row{UniValue::VOBJ};
    row.pushKV("address", address);
    row.pushKV("port", port);
    row.pushKV("services", "0000000001000001");
    row.pushKV("last_success", NOW - 10);
    return row;
}
UniValue Document()
{
    UniValue doc{UniValue::VOBJ};
    doc.pushKV("schema", "blackcoin.bootstrap/1");
    doc.pushKV("network", "main");
    doc.pushKV("generated_at", NOW);
    doc.pushKV("expires_at", NOW + 120);
    UniValue peers{UniValue::VARR};
    peers.push_back(Peer());
    doc.pushKV("peers", peers);
    return doc;
}
const NetGroupManager GROUPS{{}};
httpsseed::ParseResult Parse(const std::string& body) { return httpsseed::Parse(body, NOW, GROUPS, true, true); }
} // namespace

BOOST_FIXTURE_TEST_SUITE(https_seed_tests, BasicTestingSetup)

BOOST_AUTO_TEST_CASE(contract_and_untrusted_services)
{
    auto doc = Document();
    auto parsed = Parse(doc.write());
    BOOST_REQUIRE(parsed.valid);
    BOOST_REQUIRE_EQUAL(parsed.peers.size(), 1U);
    BOOST_CHECK_EQUAL(parsed.peers[0].ToStringAddrPort(), "8.8.8.8:23800");
    BOOST_CHECK_EQUAL(parsed.peers[0].nServices, NODE_NETWORK | NODE_QUANTUM_QUASAR);
    BOOST_CHECK_EQUAL(parsed.peers[0].nTime.time_since_epoch().count(), NOW - 10);
    for (const auto& service : {"0000000000000001", "0000000001000000", "000000000100000A", "0000000001000003", "0000000001000400", "1000001"}) {
        auto peer = Peer();
        peer.pushKV("services", service);
        UniValue rows{UniValue::VARR}; rows.push_back(peer);
        doc.pushKV("peers", rows);
        auto result = Parse(doc.write());
        BOOST_CHECK(result.valid);
        BOOST_CHECK(result.peers.empty());
    }
    auto peer = Peer(); peer.pushKV("services", "0000000001000408");
    UniValue rows{UniValue::VARR}; rows.push_back(peer); doc.pushKV("peers", rows);
    parsed = Parse(doc.write());
    BOOST_REQUIRE_EQUAL(parsed.peers.size(), 1U);
    BOOST_CHECK_EQUAL(parsed.peers[0].nServices, NODE_NETWORK_LIMITED | NODE_WITNESS | NODE_QUANTUM_QUASAR);
}

BOOST_AUTO_TEST_CASE(envelope_and_integer_freshness)
{
    for (const auto& field : {"generated_at", "expires_at"}) {
        for (const auto& value : {"1793670000", "1e9", "1.0", "-1", "9223372036854775808"}) {
            auto doc = Document();
            if (std::string{value} == "1793670000") doc.pushKV(field, value);
            else { UniValue number{UniValue::VNUM, value}; doc.pushKV(field, number); }
            BOOST_CHECK(!Parse(doc.write()).valid);
        }
    }
    for (int64_t age : {-6, 121}) {
        auto doc = Document(); doc.pushKV("generated_at", NOW - age);
        BOOST_CHECK(!Parse(doc.write()).valid);
    }
    for (int64_t expiry : {NOW - 6, NOW, NOW + 121, std::numeric_limits<int64_t>::max()}) {
        auto doc = Document(); doc.pushKV("expires_at", expiry);
        BOOST_CHECK(!Parse(doc.write()).valid);
    }
    auto doc = Document(); doc.pushKV("network", "test"); BOOST_CHECK(!Parse(doc.write()).valid);
    doc = Document(); doc.pushKV("schema", "blackcoin.bootstrap/2"); BOOST_CHECK(!Parse(doc.write()).valid);
    BOOST_CHECK(!httpsseed::Parse(Document().write(), std::numeric_limits<int64_t>::max(), GROUPS, true, true).valid);
    for (const int64_t success : {NOW - 901, NOW + 6}) {
        doc = Document(); auto peer = Peer(); peer.pushKV("last_success", success);
        UniValue rows{UniValue::VARR}; rows.push_back(peer); doc.pushKV("peers", rows);
        BOOST_CHECK(Parse(doc.write()).peers.empty());
    }
}

BOOST_AUTO_TEST_CASE(json_encoding_duplicates_and_depth)
{
    const auto valid = Document().write();
    BOOST_CHECK(!Parse(std::string(httpsseed::MAX_BODY + 1, ' ')).valid);
    BOOST_CHECK(!Parse("{}").valid);
    BOOST_CHECK(!Parse(valid + "{}").valid);
    auto dup = valid; dup.insert(1, "\"schema\":\"blackcoin.bootstrap/1\",");
    BOOST_CHECK(!Parse(dup).valid);
    dup = valid; dup.insert(dup.find("\"address\""), "\"address\":\"1.1.1.1\",");
    BOOST_CHECK(!Parse(dup).valid);
    dup = valid; dup.insert(1, "\"ignored\":{\"x\":1,\"x\":2},");
    BOOST_CHECK(!Parse(dup).valid);
    for (const std::string bad : {std::string("\0", 1), std::string("\xc0\xaf", 2), std::string("\xed\xa0\x80", 3), std::string("\xf4\x90\x80\x80", 4), std::string("\xff\xfe", 2)}) {
        auto body = valid; body.insert(1, "\"ignored\":\"" + bad + "\",");
        BOOST_CHECK(!Parse(body).valid);
    }
    auto body = valid; body.insert(1, "\"ignored\":\"\\\"[[[[\\\\🪙\",");
    BOOST_CHECK(Parse(body).valid);
    for (int depth : {15, 16}) {
        body = valid; body.insert(1, "\"ignored\":" + std::string(depth, '[') + "0" + std::string(depth, ']') + ',');
        BOOST_CHECK_EQUAL(Parse(body).valid, depth == 15); // Root object counts as one.
    }
}

BOOST_AUTO_TEST_CASE(utf8_multibyte_boundaries)
{
    const auto valid = Document().write();
    for (const std::string text : {
             std::string("\xc2\x80", 2), std::string("\xdf\xbf", 2),
             std::string("\xe0\xa0\x80", 3), std::string("\xed\x9f\xbf", 3),
             std::string("\xee\x80\x80", 3), std::string("\xef\xbf\xbf", 3),
             std::string("\xf0\x90\x80\x80", 4), std::string("\xf4\x8f\xbf\xbf", 4)}) {
        auto body = valid; body.insert(1, "\"ignored\":\"" + text + "\",");
        BOOST_CHECK(Parse(body).valid);
    }
    for (const std::string text : {
             std::string("\xe0\x80\x80", 3), std::string("\xf0\x80\x80\x80", 4),
             std::string("\xed\xbf\xbf", 3), std::string("\xe2\x28\xa1", 3),
             std::string("\xf0\x90\x80\x41", 4)}) {
        auto body = valid; body.insert(1, "\"ignored\":\"" + text + "\",");
        const auto result = Parse(body);
        BOOST_CHECK(!result.valid);
        BOOST_CHECK_EQUAL(result.error, "encoding-or-depth");
    }
    for (const std::string text : {std::string("\xc2", 1), std::string("\xe2\x82", 2),
                                   std::string("\xf0\x90\x80", 3)}) {
        const auto result = Parse(valid + text);
        BOOST_CHECK(!result.valid);
        BOOST_CHECK_EQUAL(result.error, "encoding-or-depth");
    }
}

BOOST_AUTO_TEST_CASE(addresses_ports_families_exclusions_and_diversity)
{
    for (const std::string address : {"127.0.0.1", "10.0.0.1", "100.64.0.1", "192.0.2.1", "224.0.0.1", "::1", "::ffff:8.8.8.8", "2002:808:808::1", "2001::1", "2606:4700:4700::1111%en0", "2606:4700:4700:0:0:0:0:1111", "dns.example", "8.8.8.08"}) {
        CNetAddr parsed;
        BOOST_CHECK_MESSAGE(!httpsseed::ParsePublicAddress(address, parsed), address);
    }
    for (const int port : {0, 65536, -1}) {
        auto doc = Document(); UniValue rows{UniValue::VARR}; rows.push_back(Peer("8.8.8.8", port)); doc.pushKV("peers", rows);
        BOOST_CHECK(Parse(doc.write()).peers.empty());
    }
    auto doc = Document(); UniValue rows{UniValue::VARR};
    for (const std::string ip : {"8.8.8.8", "8.8.8.8", "8.8.4.4", "8.8.1.1", "1.1.1.1", "2606:4700:4700::1111"}) rows.push_back(Peer(ip));
    doc.pushKV("peers", rows);
    BOOST_CHECK_EQUAL(Parse(doc.write()).peers.size(), 4U);
    BOOST_CHECK_EQUAL(httpsseed::Parse(doc.write(), NOW, GROUPS, true, false).peers.size(), 3U);
    BOOST_CHECK_EQUAL(httpsseed::Parse(doc.write(), NOW, GROUPS, false, true).peers.size(), 1U);
    BOOST_CHECK_EQUAL(httpsseed::Parse(doc.write(), NOW, GROUPS, false, false).peers.size(), 0U);
    CNetAddr excluded; BOOST_REQUIRE(httpsseed::ParsePublicAddress("2606:4700:4700::1111", excluded));
    BOOST_CHECK_EQUAL(httpsseed::Parse(doc.write(), NOW, GROUPS, true, true, [&](const CNetAddr& ip) { return ip == excluded; }).peers.size(), 3U);
    rows.clear(); rows.setArray();
    for (size_t i = 0; i <= httpsseed::MAX_PEERS; ++i) rows.push_back(Peer());
    doc.pushKV("peers", rows); BOOST_CHECK(!Parse(doc.write()).valid);
}

BOOST_AUTO_TEST_CASE(policy_optouts_and_proxy_family)
{
    httpsseed::Policy p{true, true, true, true, true, true, 16, true, true};
    BOOST_CHECK(httpsseed::Enabled(p));
    for (bool httpsseed::Policy::* flag : {&httpsseed::Policy::mainnet, &httpsseed::Policy::enabled, &httpsseed::Policy::dnsseed, &httpsseed::Policy::dns, &httpsseed::Policy::automatic, &httpsseed::Policy::network_active}) {
        auto disabled = p; disabled.*flag = false; BOOST_CHECK(!httpsseed::Enabled(disabled));
    }
    auto disabled = p; disabled.max_connections = 0; BOOST_CHECK(!httpsseed::Enabled(disabled));
    disabled = p; disabled.ipv4 = disabled.ipv6 = false; BOOST_CHECK(!httpsseed::Enabled(disabled));
    p.hostname_proxy = true;
    p.explicit_onlynet = true;
    BOOST_CHECK(httpsseed::Enabled(p));
    p.ipv6 = false;
    BOOST_CHECK(!httpsseed::Enabled(p));
    p.explicit_onlynet = false; // Incidental missing family is not an explicit routing restriction.
    BOOST_CHECK(httpsseed::Enabled(p));
    p.explicit_onlynet = true; p.hostname_proxy = false;
    BOOST_CHECK(httpsseed::Enabled(p));
}

BOOST_AUTO_TEST_CASE(transport_preflight_cancellation)
{
    httpsseed::TransportOptions options;
    options.ipv4 = true;
    httpsseed::test::Endpoint endpoint;
    endpoint.hostname = "bootstrap.invalid"; endpoint.path = "/"; endpoint.ca_bundle = "test";
    endpoint.numeric_addresses = {"127.0.0.1"};
    const auto result = httpsseed::test::Fetch(options, [] { return true; }, endpoint);
    BOOST_CHECK(!result.success);
    BOOST_CHECK(result.body.empty());
}


namespace {
using TestClock = std::chrono::steady_clock;
class TestSocket : public Sock {
public:
    using Sock::Sock;
    SOCKET Descriptor() const { return m_socket; }
};

/** All sockets stay on loopback. Certificates are generated in memory per test. */
class LocalTLS {
    std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> key{nullptr, EVP_PKEY_free};
    std::unique_ptr<X509, decltype(&X509_free)> cert{nullptr, X509_free};
    std::unique_ptr<SSL_CTX, decltype(&SSL_CTX_free)> ctx{nullptr, SSL_CTX_free};
    TestSocket listener{static_cast<SOCKET>(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP))};
    std::thread thread;
    std::atomic<bool> stopping{false};
#if !defined(WIN32) && defined(SO_NOSIGPIPE)
    bool socket_signal_setup_failed{false}; // Read after the worker joins.
#endif
    const std::string response;
    const bool socks, refuse;
    const int stall;
    static void Check(bool ok) { if (!ok) throw std::runtime_error("local TLS fixture initialization"); }

    bool Pause(TestSocket& socket)
    {
        if (stopping) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds{1});
        Sock::Event occurred;
        return socket.Wait(std::chrono::milliseconds{10}, Sock::RECV | Sock::SEND, &occurred);
    }
    std::string Read(TestSocket& socket, size_t length)
    {
        std::string bytes(length, '\0');
        size_t offset{0};
        while (offset < length && !stopping) {
            const auto count = socket.Recv(bytes.data() + offset, length - offset, 0);
            if (count > 0) offset += count;
            else if (count == 0 || !Pause(socket)) break;
        }
        bytes.resize(offset);
        return bytes;
    }
    bool Send(TestSocket& socket, const std::string& bytes)
    {
        size_t offset{0};
        while (offset < bytes.size() && !stopping) {
            const auto count = socket.Send(bytes.data() + offset, bytes.size() - offset, MSG_NOSIGNAL);
            if (count > 0) offset += count;
            else if (!Pause(socket)) break;
        }
        return offset == bytes.size();
    }
    void Serve()
    {
        while (!stopping) {
            Sock::Event occurred{0};
            if (!listener.Wait(std::chrono::milliseconds{10}, Sock::RECV, &occurred)) return;
            if (!(occurred & Sock::RECV)) continue;
            const SOCKET fd = static_cast<SOCKET>(accept(listener.Descriptor(), nullptr, nullptr));
            if (fd == INVALID_SOCKET) continue;
            TestSocket socket{fd};
#if !defined(WIN32) && defined(SO_NOSIGPIPE)
            // Darwin can deliver socket SIGPIPE outside the calling thread.
            // Suppress it on this socket before attaching the OpenSSL BIO.
            const int enabled{1};
            if (socket.SetSockOpt(SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) {
                socket_signal_setup_failed = true;
                return;
            }
#endif
            if (!socket.SetNonBlocking()) return;
            ++connections;
            if (socks) {
                auto greeting = Read(socket, 2);
                if (greeting.size() != 2 || greeting[0] != 5) return;
                auto methods = Read(socket, static_cast<unsigned char>(greeting[1]));
                const unsigned char method = methods.find(char{2}) != std::string::npos ? 2 : 0;
                if (!Send(socket, std::string{char{5}, static_cast<char>(method)})) return;
                if (method == 2) {
                    auto auth = Read(socket, 2);
                    if (auth.size() != 2 || auth[0] != 1) return;
                    username = Read(socket, static_cast<unsigned char>(auth[1]));
                    auto size = Read(socket, 1); if (size.size() != 1) return;
                    password = Read(socket, static_cast<unsigned char>(size[0]));
                    if (!Send(socket, std::string{char{1}, char{0}})) return;
                }
                const auto request = Read(socket, 4);
                if (request != std::string{char{5}, char{1}, char{0}, char{3}}) return;
                auto size = Read(socket, 1); if (size.size() != 1) return;
                hostname = Read(socket, static_cast<unsigned char>(size[0]));
                if (Read(socket, 2).size() != 2) return;
                if (stall == 4) { while (!stopping) std::this_thread::sleep_for(std::chrono::milliseconds{10}); return; }
                if (!Send(socket, std::string{char{5}, static_cast<char>(refuse ? 1 : 0), char{0}, char{1}, char{0}, char{0}, char{0}, char{0}, char{0}, char{0}}) || refuse) return;
            }
            if (stall == 1) { while (!stopping) std::this_thread::sleep_for(std::chrono::milliseconds{10}); return; }
            std::unique_ptr<SSL, decltype(&SSL_free)> ssl{SSL_new(ctx.get()), SSL_free};
            if (!ssl || SSL_set_fd(ssl.get(), static_cast<int>(fd)) != 1) return;
            bool established{false};
            while (!stopping) {
                const int status = SSL_accept(ssl.get());
                if (status == 1) { established = true; break; }
                const int error = SSL_get_error(ssl.get(), status);
                if ((error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE) || !Pause(socket)) return;
            }
            if (!established) return;
            std::string request;
            while (request.find("\r\n\r\n") == std::string::npos && request.size() < 8192 && !stopping) {
                std::array<char, 1024> bytes{};
                const int count = SSL_read(ssl.get(), bytes.data(), bytes.size());
                if (count > 0) request.append(bytes.data(), count);
                else {
                    const int error = SSL_get_error(ssl.get(), count);
                    if ((error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE) || !Pause(socket)) return;
                }
            }
            request_headers = request;
            if (stall == 2) { while (!stopping) std::this_thread::sleep_for(std::chrono::milliseconds{10}); return; }
            size_t sent{0};
            while (sent < response.size() && !stopping) {
                const int count = SSL_write(ssl.get(), response.data() + sent, response.size() - sent);
                if (count > 0) sent += count;
                else {
                    const int error = SSL_get_error(ssl.get(), count);
                    if ((error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE) || !Pause(socket)) return;
                }
            }
            if (stall == 3) { while (!stopping) std::this_thread::sleep_for(std::chrono::milliseconds{10}); }
            return;
        }
    }
public:
    std::string ca, hostname, username, password, request_headers;
    uint16_t port{0};
    std::atomic<unsigned> connections{0};
    LocalTLS(std::string reply, bool wrong_hostname = false, bool expired = false,
             bool via_socks = false, bool reject_proxy = false, int stall_stage = 0)
        : response{std::move(reply)}, socks{via_socks}, refuse{reject_proxy}, stall{stall_stage}
    {
        std::unique_ptr<EVP_PKEY_CTX, decltype(&EVP_PKEY_CTX_free)> gen{EVP_PKEY_CTX_new_id(EVP_PKEY_EC, nullptr), EVP_PKEY_CTX_free};
        Check(gen && EVP_PKEY_keygen_init(gen.get()) == 1 && EVP_PKEY_CTX_set_ec_paramgen_curve_nid(gen.get(), NID_X9_62_prime256v1) == 1);
        EVP_PKEY* generated{nullptr}; Check(EVP_PKEY_keygen(gen.get(), &generated) == 1); key.reset(generated);
        cert.reset(X509_new()); Check(cert != nullptr);
        Check(X509_set_version(cert.get(), 2) == 1 && ASN1_INTEGER_set(X509_get_serialNumber(cert.get()), 1) == 1);
        Check(X509_gmtime_adj(X509_getm_notBefore(cert.get()), expired ? -172800 : -3600) != nullptr);
        Check(X509_gmtime_adj(X509_getm_notAfter(cert.get()), expired ? -86400 : 86400) != nullptr);
        Check(X509_set_pubkey(cert.get(), key.get()) == 1);
        auto* name = X509_get_subject_name(cert.get());
        Check(X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
            reinterpret_cast<const unsigned char*>(wrong_hostname ? "wrong.invalid" : "bootstrap.invalid"), -1, -1, 0) == 1);
        Check(X509_set_issuer_name(cert.get(), name) == 1);
        X509V3_CTX extension_context{};
        X509V3_set_ctx(&extension_context, cert.get(), cert.get(), nullptr, nullptr, 0);
        for (const auto& item : {std::pair<int, const char*>{NID_basic_constraints, "critical,CA:TRUE"},
                {NID_subject_alt_name, wrong_hostname ? "DNS:wrong.invalid" : "DNS:bootstrap.invalid"}}) {
            std::unique_ptr<X509_EXTENSION, decltype(&X509_EXTENSION_free)> extension{
                X509V3_EXT_conf_nid(nullptr, &extension_context, item.first, item.second), X509_EXTENSION_free};
            Check(extension && X509_add_ext(cert.get(), extension.get(), -1) == 1);
        }
        Check(X509_sign(cert.get(), key.get(), EVP_sha256()) > 0);
        std::unique_ptr<BIO, decltype(&BIO_free)> bio{BIO_new(BIO_s_mem()), BIO_free};
        Check(bio && PEM_write_bio_X509(bio.get(), cert.get()) == 1);
        char* pem{nullptr}; const long size = BIO_get_mem_data(bio.get(), &pem); Check(size > 0);
        ca.assign(pem, size);
        ctx.reset(SSL_CTX_new(TLS_server_method()));
        Check(ctx && SSL_CTX_use_certificate(ctx.get(), cert.get()) == 1 && SSL_CTX_use_PrivateKey(ctx.get(), key.get()) == 1);
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        Check(listener.Descriptor() != INVALID_SOCKET && listener.SetNonBlocking());
        Check(listener.Bind(reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0 && listener.Listen(1) == 0);
        socklen_t length{sizeof(address)};
        Check(listener.GetSockName(reinterpret_cast<sockaddr*>(&address), &length) == 0);
        port = ntohs(address.sin_port);
#if !defined(WIN32) && !defined(SO_NOSIGPIPE)
        std::promise<bool> signal_ready;
        auto ready = signal_ready.get_future();
        thread = std::thread([this, signal_ready = std::move(signal_ready)]() mutable {
            // OpenSSL socket BIOs can write during handshake, reads and writes.
            // Keep SIGPIPE blocked until this worker exits so a pending signal
            // cannot be delivered when the fixture stops.
            sigset_t blocked{};
            const bool ok = sigemptyset(&blocked) == 0 && sigaddset(&blocked, SIGPIPE) == 0 &&
                pthread_sigmask(SIG_BLOCK, &blocked, nullptr) == 0;
            signal_ready.set_value(ok);
            if (ok) Serve();
        });
        if (!ready.get()) {
            thread.join();
            throw std::runtime_error("local TLS fixture could not block SIGPIPE");
        }
#else
        thread = std::thread([this] { Serve(); });
#endif
    }
    void Stop()
    {
        stopping = true;
        if (!thread.joinable()) return;
        thread.join();
#if !defined(WIN32) && defined(SO_NOSIGPIPE)
        if (socket_signal_setup_failed) BOOST_ERROR("local TLS fixture could not set SO_NOSIGPIPE");
#endif
    }
    ~LocalTLS() { Stop(); }
    httpsseed::test::Endpoint Endpoint() const
    {
        return {"bootstrap.invalid", port, "/", ca, {"127.0.0.1"}, std::chrono::milliseconds{1500}};
    }
};
std::string Reply(const std::string& body = "{}")
{
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + ToString(body.size()) + "\r\nConnection: close\r\n\r\n" + body;
}
httpsseed::TransportOptions Options()
{
    httpsseed::TransportOptions options;
    options.ipv4 = options.ipv6 = true;
    options.user_agent = "Blackcoin-HTTPSSeed-Test/1";
    return options;
}
} // namespace

BOOST_AUTO_TEST_CASE(tls_verification_http_limits_and_redirects)
{
    BOOST_REQUIRE(httpsseed::InitializeTransport());
    {
        LocalTLS server{Reply(Document().write())};
        auto result = httpsseed::test::Fetch(Options(), [] { return false; }, server.Endpoint());
        server.Stop();
        BOOST_REQUIRE_MESSAGE(result.success, result.error);
        BOOST_CHECK(Parse(result.body).valid);
        BOOST_CHECK(server.request_headers.find("Blackcoin-HTTPSSeed-Test/1") != std::string::npos);
        BOOST_CHECK(server.request_headers.find("Accept: application/json") != std::string::npos);
        BOOST_CHECK(server.request_headers.find("Cookie:") == std::string::npos);
        BOOST_CHECK(server.request_headers.find("Authorization:") == std::string::npos);
    }
    for (const int defect : {0, 1, 2}) {
        LocalTLS server{Reply(), defect == 0, defect == 1};
        auto endpoint = server.Endpoint();
        if (defect == 2) { LocalTLS other{Reply()}; endpoint.ca_bundle = other.ca; }
        BOOST_CHECK(!httpsseed::test::Fetch(Options(), [] { return false; }, endpoint).success);
    }
    for (const auto& response : {
            "HTTP/1.1 302 Found\r\nLocation: https://bootstrap.invalid/redirect\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.1 503 Unavailable\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 65537\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\nxx\r\n0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\n{}"}) {
        LocalTLS server{response};
        BOOST_CHECK(!httpsseed::test::Fetch(Options(), [] { return false; }, server.Endpoint()).success);
        BOOST_CHECK_EQUAL(server.connections.load(), 1U);
    }
    {
        LocalTLS server{"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n" + std::string(65537, 'x')};
        BOOST_CHECK(!httpsseed::test::Fetch(Options(), [] { return false; }, server.Endpoint()).success);
    }
    {
        LocalTLS server{"HTTP/1.1 200 OK\r\nX-Fill: " + std::string(16384, 'x') + "\r\n\r\n"};
        BOOST_CHECK(!httpsseed::test::Fetch(Options(), [] { return false; }, server.Endpoint()).success);
    }
}

BOOST_AUTO_TEST_CASE(proxy_remote_hostname_credentials_and_no_direct_retry)
{
    LocalTLS server{Reply(), false, false, true};
    auto endpoint = server.Endpoint();
    endpoint.numeric_addresses.clear();
    auto options = Options();
    in_addr loopback{}; loopback.s_addr = htonl(INADDR_LOOPBACK);
    options.proxy = Proxy{CService{CNetAddr{loopback}, server.port}, true};
    auto result = httpsseed::test::Fetch(options, [] { return false; }, endpoint);
    server.Stop();
    BOOST_REQUIRE_MESSAGE(result.success, result.error);
    BOOST_CHECK_EQUAL(server.hostname, "bootstrap.invalid");
    BOOST_CHECK(!server.username.empty());
    BOOST_CHECK(!server.password.empty());
    BOOST_CHECK(server.username != server.password);
    LocalTLS refused{Reply(), false, false, true, true};
    LocalTLS direct_trap{Reply()};
    options.proxy = Proxy{CService{CNetAddr{loopback}, refused.port}, false};
    endpoint = direct_trap.Endpoint();
    result = httpsseed::test::Fetch(options, [] { return false; }, endpoint);
    refused.Stop();
    BOOST_CHECK(!result.success);
    BOOST_CHECK_EQUAL(refused.hostname, "bootstrap.invalid");
    BOOST_CHECK_EQUAL(direct_trap.connections.load(), 0U);
    BOOST_CHECK(refused.username.empty());
}

BOOST_AUTO_TEST_CASE(total_deadline_and_cancellation_during_transport_stages)
{
    for (int stage : {1, 2, 3, 4}) {
        for (bool cancel : {false, true}) {
            LocalTLS server{stage == 3 ? "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 10\r\n\r\n{" : Reply(), false, false, stage == 4, false, stage};
            auto endpoint = server.Endpoint(); endpoint.timeout = std::chrono::milliseconds{250};
            auto options = Options();
            if (stage == 4) {
                in_addr loopback{}; loopback.s_addr = htonl(INADDR_LOOPBACK);
                options.proxy = Proxy{CService{CNetAddr{loopback}, server.port}, false};
            }
            const auto start = TestClock::now();
            auto result = httpsseed::test::Fetch(options, [&] { return cancel && TestClock::now() - start >= std::chrono::milliseconds{75}; }, endpoint);
            const auto elapsed = TestClock::now() - start;
            BOOST_CHECK(!result.success);
            BOOST_CHECK(elapsed < std::chrono::milliseconds{750});
            if (!cancel) BOOST_CHECK(elapsed >= std::chrono::milliseconds{200});
        }
    }
}


BOOST_AUTO_TEST_CASE(direct_dns_total_deadline_and_cancellation)
{
    for (const auto& families : {std::pair{true, false}, std::pair{false, true}, std::pair{true, true}}) {
        for (const bool cancel : {false, true}) {
            TestSocket dns{static_cast<SOCKET>(socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP))};
            BOOST_REQUIRE(dns.Descriptor() != INVALID_SOCKET && dns.SetNonBlocking());
            sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            BOOST_REQUIRE_EQUAL(dns.Bind(reinterpret_cast<sockaddr*>(&address), sizeof(address)), 0);
            socklen_t length{sizeof(address)};
            BOOST_REQUIRE_EQUAL(dns.GetSockName(reinterpret_cast<sockaddr*>(&address), &length), 0);
            LocalTLS server{Reply()};
            auto endpoint = server.Endpoint();
            endpoint.numeric_addresses.clear();
            endpoint.hostname = "seed.bootstrap.test";
            endpoint.dns_server = "127.0.0.1:" + ToString(ntohs(address.sin_port));
            endpoint.timeout = std::chrono::milliseconds{250};
            auto options = Options();
            options.ipv4 = families.first;
            options.ipv6 = families.second;
            const auto start = TestClock::now();
            auto result = httpsseed::test::Fetch(options, [&] { return cancel && TestClock::now() - start >= std::chrono::milliseconds{75}; }, endpoint);
            const auto elapsed = TestClock::now() - start;
            BOOST_CHECK(!result.success);
            BOOST_CHECK(elapsed < std::chrono::milliseconds{750});
            if (!cancel) BOOST_CHECK(elapsed >= std::chrono::milliseconds{200});
            std::array<char, 1024> query{};
            BOOST_CHECK(dns.Recv(query.data(), query.size(), 0) > 0);
            BOOST_CHECK_EQUAL(server.connections.load(), 0U);
        }
    }
}


namespace {
class ScopedEnvironment {
    const std::string key;
    const bool existed;
    const std::string previous;
    static void Put(const std::string& key, const char* value)
    {
#ifdef WIN32
        _putenv_s(key.c_str(), value ? value : "");
#else
        if (value) setenv(key.c_str(), value, 1);
        else unsetenv(key.c_str());
#endif
    }
public:
    ScopedEnvironment(std::string name, const std::string& value)
        : key{std::move(name)}, existed{std::getenv(key.c_str()) != nullptr},
          previous{existed ? std::getenv(key.c_str()) : ""}
    { Put(key, value.c_str()); }
    ~ScopedEnvironment() { Put(key, existed ? previous.c_str() : nullptr); }
};
} // namespace
BOOST_AUTO_TEST_CASE(environment_cannot_override_core_proxy_policy)
{
    LocalTLS unwanted{Reply(), false, false, true};
    const std::string poison = "socks5h://127.0.0.1:" + ToString(unwanted.port);
    ScopedEnvironment https_proxy{"HTTPS_PROXY", poison}, all_proxy{"ALL_PROXY", poison};
    ScopedEnvironment no_proxy{"NO_PROXY", "*"}, no_proxy_lower{"no_proxy", "*"};
    LocalTLS direct{Reply()};
    BOOST_CHECK(httpsseed::test::Fetch(Options(), [] { return false; }, direct.Endpoint()).success);
    BOOST_CHECK_EQUAL(unwanted.connections.load(), 0U);
    LocalTLS proxy{Reply(), false, false, true};
    auto endpoint = proxy.Endpoint(); endpoint.numeric_addresses.clear();
    auto options = Options();
    in_addr loopback{}; loopback.s_addr = htonl(INADDR_LOOPBACK);
    options.proxy = Proxy{CService{CNetAddr{loopback}, proxy.port}, false};
    BOOST_CHECK(httpsseed::test::Fetch(options, [] { return false; }, endpoint).success);
    proxy.Stop();
    BOOST_CHECK_EQUAL(proxy.hostname, "bootstrap.invalid");
    BOOST_CHECK_EQUAL(unwanted.connections.load(), 0U);
}


BOOST_AUTO_TEST_CASE(unsupported_build_backend_disables_https_only)
{
    BOOST_CHECK(httpsseed::SupportedBackend(0x081700, true, "OpenSSL/3.5.9"));
    BOOST_CHECK(!httpsseed::SupportedBackend(0x081700, true, "SecureTransport"));
    BOOST_CHECK(!httpsseed::SupportedBackend(0x081700, true, "GnuTLS/3"));
    BOOST_CHECK(!httpsseed::SupportedBackend(0x081700, false, "OpenSSL/3.5.9"));
    BOOST_CHECK(!httpsseed::SupportedBackend(0x074c00, true, "OpenSSL/3.5.9"));
    BOOST_CHECK(!httpsseed::SupportedBackend(0x081700, true, ""));
    // CConnman handles InitializeTransport()==false by warning and starting
    // its existing discovery workers. No alternate backend is selected here.
}


BOOST_AUTO_TEST_CASE(public_unicast_contract_boundaries)
{
    const std::vector<std::pair<std::string, bool>> boundaries{
        {"0.0.0.0", false}, {"0.255.255.255", false}, {"1.0.0.0", true},
        {"9.255.255.255", true}, {"10.0.0.0", false}, {"10.255.255.255", false}, {"11.0.0.0", true},
        {"100.63.255.255", true}, {"100.64.0.0", false}, {"100.127.255.255", false}, {"100.128.0.0", true},
        {"126.255.255.255", true}, {"127.0.0.0", false}, {"127.255.255.255", false}, {"128.0.0.0", true},
        {"169.253.255.255", true}, {"169.254.0.0", false}, {"169.254.255.255", false}, {"169.255.0.0", true},
        {"172.15.255.255", true}, {"172.16.0.0", false}, {"172.31.255.255", false}, {"172.32.0.0", true},
        {"191.255.255.255", true}, {"192.0.0.0", false}, {"192.0.0.8", false}, {"192.0.0.255", false}, {"192.0.1.0", true},
        {"192.0.1.255", true}, {"192.0.2.0", false}, {"192.0.2.255", false}, {"192.0.3.0", true},
        {"192.88.98.255", true}, {"192.88.99.0", false}, {"192.88.99.255", false}, {"192.88.100.0", true},
        {"192.167.255.255", true}, {"192.168.0.0", false}, {"192.168.255.255", false}, {"192.169.0.0", true},
        {"198.17.255.255", true}, {"198.18.0.0", false}, {"198.19.255.255", false}, {"198.20.0.0", true},
        {"198.51.99.255", true}, {"198.51.100.0", false}, {"198.51.100.255", false}, {"198.51.101.0", true},
        {"203.0.112.255", true}, {"203.0.113.0", false}, {"203.0.113.255", false}, {"203.0.114.0", true},
        {"223.255.255.255", true}, {"224.0.0.0", false}, {"239.255.255.255", false}, {"240.0.0.0", false}, {"255.255.255.255", false},
        {"1fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false}, {"2000::", true},
        {"2000:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true}, {"2001::", false}, {"2001:2::1", false},
        {"2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff", false}, {"2001:200::", true},
        {"2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", true}, {"2001:db8::", false},
        {"2001:db8:ffff:ffff:ffff:ffff:ffff:ffff", false}, {"2001:db9::", true},
        {"2001:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true}, {"2002::", false},
        {"2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false}, {"2003::", true},
        {"3ffe:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true}, {"3fff::1", false},
        {"3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff", false}, {"3fff:1000::", true},
        {"3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true}, {"4000::", false},
        {"2606:4700:4700::1111", true}, {"2606:4700:4700:0:0:0:0:1111", false},
        {"2606:4700:4700::ABCD", false}, {"2606:4700:4700::abcd", true}
    };
    for (const auto& [text, expected] : boundaries) {
        CNetAddr address;
        BOOST_CHECK_MESSAGE(httpsseed::ParsePublicAddress(text, address) == expected, text);
    }
}

BOOST_AUTO_TEST_CASE(witness_is_preserved_never_synthesized)
{
    auto doc = Document();
    for (const auto& [flags, valid] : std::vector<std::pair<std::string, bool>>{
            {"0000000001000001", true}, {"0000000001000009", true},
            {"0000000001000400", false}, {"0000000001000408", true}}) {
        auto peer = Peer(); peer.pushKV("services", flags);
        UniValue rows{UniValue::VARR}; rows.push_back(peer); doc.pushKV("peers", rows);
        const auto parsed = Parse(doc.write());
        BOOST_REQUIRE(parsed.valid);
        BOOST_CHECK_EQUAL(parsed.peers.size(), valid ? 1U : 0U);
        if (valid) {
            const bool witness = flags.back() == '8' || flags.back() == '9';
            BOOST_CHECK_EQUAL(bool(parsed.peers[0].nServices & NODE_WITNESS), witness);
            if (parsed.peers[0].nServices & NODE_NETWORK_LIMITED) {
                SetServiceFlagsIBDCache(true);
                BOOST_CHECK(HasAllDesirableServiceFlags(parsed.peers[0].nServices));
                SetServiceFlagsIBDCache(false);
            }
        }
    }
}

namespace {
bool Eventually(const std::function<bool()>& ready, std::chrono::milliseconds timeout = std::chrono::milliseconds{5000})
{
    const auto until = TestClock::now() + timeout;
    while (TestClock::now() < until) {
        if (ready()) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds{2});
    }
    return ready();
}

class WorkerGate {
    ConnmanTestMsg& connman;
    std::mutex mutex;
    std::condition_variable condition;
    unsigned tokens{0};
public:
    std::atomic<int64_t> seconds{0};
    std::atomic<unsigned> waits{0};
    explicit WorkerGate(ConnmanTestMsg& node) : connman{node} {}
    bool Wait()
    {
        std::unique_lock<std::mutex> lock{mutex};
        ++waits;
        while (!tokens && !connman.HTTPSInterruptedForTest()) condition.wait_for(lock, std::chrono::milliseconds{10});
        if (connman.HTTPSInterruptedForTest()) return false;
        --tokens;
        return true;
    }
    void Tick(int64_t elapsed = 0)
    {
        seconds += elapsed;
        { std::lock_guard<std::mutex> lock{mutex}; ++tokens; }
        condition.notify_all();
    }
    bool Step(int64_t elapsed = 0)
    {
        const auto previous = waits.load();
        Tick(elapsed);
        return Eventually([&] { return waits > previous; });
    }
    TestClock::time_point Now() const { return TestClock::time_point{std::chrono::seconds{seconds.load()}}; }
};

class WorkerRun {
    ConnmanTestMsg& connman;
    bool stopped{false};
public:
    WorkerRun(ConnmanTestMsg& node, WorkerGate& gate, const httpsseed::WorkerHooks& hooks) : connman{node}
    {
        connman.StartHTTPSForTest(hooks);
        if (!Eventually([&] { return gate.waits > 0; })) {
            connman.StopHTTPSForTest();
            throw std::runtime_error("HTTPS worker did not enter its real wait loop");
        }
    }
    void Stop() { if (!stopped) { connman.StopHTTPSForTest(); stopped = true; } }
    ~WorkerRun() { Stop(); }
};

/** PeerManager::ProcessMessage(VERSION) feeds AddTimeData(), which keeps process-wide state (sample filter, one-shot
 * clock warning). A later timedata_tests/addtimedata needs it pristine, so reset it when a handshake scope ends. */
struct TimeDataScope {
    ~TimeDataScope() { TestOnlyResetTimeData(); }
};

struct DNSLookupScope {
    DNSLookupFn previous{g_dns_lookup};
    ~DNSLookupScope() { g_dns_lookup = std::move(previous); }
};

void PrepareWorker(ConnmanTestMsg& connman, node::NodeContext& node)
{
    gArgs.ForceSetArg("-dnsseed", "1");
    gArgs.ForceSetArg("-dns", "1");
    gArgs.ForceSetArg("-fixedseeds", "0");
    SetMockTime(NOW);
    CConnman::Options options;
    options.nMaxConnections = 3;
    options.m_max_outbound_full_relay = 2;
    options.m_qq_outbound_target = 1;
    options.m_msgproc = node.peerman.get();
    options.m_banman = node.banman.get();
    options.nLocalServices = NODE_NETWORK;
    options.nSendBufferMaxSize = options.nReceiveFloodSize = 1024 * 1024;
    options.m_https_seed = true;
    connman.Init(options);
}

httpsseed::FetchResult LocalFetch(const httpsseed::TransportOptions& options, const httpsseed::Cancel& cancelled,
                                int port = 23800, int stall = 0)
{
    if (options.proxy) return {false, {}, "unexpected fixture proxy"};
    auto doc = Document();
    doc.pushKV("generated_at", GetTime<std::chrono::seconds>().count());
    doc.pushKV("expires_at", GetTime<std::chrono::seconds>().count() + 120);
    auto peer = Peer("8.8.8.8", port); peer.pushKV("last_success", GetTime<std::chrono::seconds>().count() - 10);
    UniValue rows{UniValue::VARR}; rows.push_back(peer); doc.pushKV("peers", rows);
    LocalTLS server{Reply(doc.write()), false, false, false, false, stall};
    return httpsseed::test::Fetch(options, cancelled, server.Endpoint());
}

struct SocketFactoryScope {
    decltype(CreateSock) previous{CreateSock};
    ~SocketFactoryScope() { CreateSock = std::move(previous); }
};

class RedirectSocket : public Sock {
    const uint16_t port;
public:
    explicit RedirectSocket(uint16_t target)
        : Sock{static_cast<SOCKET>(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP))}, port{target}
    { if (!SetNonBlocking()) throw std::runtime_error("loopback redirect nonblocking"); }
    int Connect(const sockaddr*, socklen_t) const override
    {
        sockaddr_in address{}; address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = htons(port);
        return Sock::Connect(reinterpret_cast<sockaddr*>(&address), sizeof(address));
    }
};
} // namespace

BOOST_FIXTURE_TEST_CASE(actual_connman_https_addrman_automatic_peer, TestingSetup)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    PrepareWorker(connman, m_node);
    BOOST_REQUIRE_EQUAL(m_node.addrman->Size(), 0U);
    TestSocket listener{static_cast<SOCKET>(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP))};
    sockaddr_in local{}; local.sin_family = AF_INET; local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOST_REQUIRE(listener.SetNonBlocking());
    BOOST_REQUIRE_EQUAL(listener.Bind(reinterpret_cast<sockaddr*>(&local), sizeof(local)), 0);
    BOOST_REQUIRE_EQUAL(listener.Listen(1), 0);
    socklen_t size{sizeof(local)}; BOOST_REQUIRE_EQUAL(listener.GetSockName(reinterpret_cast<sockaddr*>(&local), &size), 0);
    const auto port = ntohs(local.sin_port);
    BOOST_REQUIRE(port != Params().GetDefaultPort());
    SocketFactoryScope factory;
    std::atomic<unsigned> correct_attempts{0}, unexpected_attempts{0}, fetches{0};
    CreateSock = [&](const CService& address) -> std::unique_ptr<Sock> {
        if (address.ToStringAddrPort() != "8.8.8.8:" + ToString(port)) { ++unexpected_attempts; return nullptr; }
        ++correct_attempts;
        return std::make_unique<RedirectSocket>(port);
    };
    WorkerGate gate{connman};
    httpsseed::WorkerHooks hooks;
    hooks.now = [&] { return gate.Now(); };
    hooks.wait = [&] { return gate.Wait(); };
    hooks.fetch = [&](const auto& options, const auto& cancelled) { ++fetches; return LocalFetch(options, cancelled, port); };
    WorkerRun worker{connman, gate, hooks};
    BOOST_REQUIRE(gate.Step());
    BOOST_CHECK_EQUAL(fetches.load(), 1U);
    BOOST_REQUIRE_EQUAL(m_node.addrman->Size(), 1U);
    BOOST_CHECK_EQUAL(connman.GetQQStatus().confirmed, 0);
    BOOST_CHECK_EQUAL(connman.GetQQStatus().eligible, 0);
    connman.StartHTTPSAutomaticConnectionsForTest();
    CNode* learned{nullptr};
    BOOST_REQUIRE(Eventually([&] {
        learned = connman.FindHTTPSNodeForTest("8.8.8.8:" + ToString(port));
        return learned != nullptr;
    }));
    BOOST_CHECK(correct_attempts > 0);
    BOOST_CHECK_EQUAL(unexpected_attempts.load(), 0U);
    const SOCKET peer_fd = static_cast<SOCKET>(accept(listener.Descriptor(), nullptr, nullptr));
    BOOST_REQUIRE(peer_fd != INVALID_SOCKET);
    TestSocket accepted{peer_fd};
    // Complete the real PeerManager VERSION/VERACK path using the existing
    // serialized-message fixture. Socket selection above was automatic and real.
    TimeDataScope time_data_scope;
    LOCK(NetEventsInterface::g_msgproc_mutex);
    connman.FlushSendBuffer(*learned);
    const CNetMsgMaker messages{0};
    auto version = messages.Make(NetMsgType::VERSION, PROTOCOL_VERSION,
        Using<CustomUintFormatter<8>>(ServiceFlags{NODE_NETWORK}), int64_t{NOW},
        int64_t{}, CNetAddr::V1(CService{}), int64_t{}, CNetAddr::V1(CService{}),
        uint64_t{1}, std::string{}, int32_t{}, true);
    BOOST_REQUIRE(connman.ReceiveMsgFrom(*learned, std::move(version)));
    connman.ProcessMessagesOnce(*learned);
    m_node.peerman->SendMessages(learned);
    connman.FlushSendBuffer(*learned);
    BOOST_REQUIRE(!learned->fDisconnect);
    BOOST_REQUIRE(connman.ReceiveMsgFrom(*learned, messages.Make(NetMsgType::VERACK)));
    connman.ProcessMessagesOnce(*learned);
    BOOST_CHECK(learned->fSuccessfullyConnected);
    BOOST_CHECK(!(learned->m_accepted_services & NODE_QUANTUM_QUASAR));
    BOOST_CHECK_EQUAL(connman.GetQQStatus().confirmed, 0);
    BOOST_CHECK_EQUAL(connman.GetQQStatus().eligible, 0);
}

namespace {
/** Add outbound full-relay peers that completed VERSION/VERACK. A QQ peer also records QQ handshake evidence. */
void AddConnectedFullRelay(node::NodeContext& node, unsigned count, bool qq, unsigned first_octet = 30)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*node.connman);
    LOCK(NetEventsInterface::g_msgproc_mutex);
    for (unsigned i = 0; i < count; ++i) {
        auto* peer = new CNode{static_cast<NodeId>(1000 + first_octet * 100 + i), /*sock=*/nullptr,
                               CAddress{LookupNumeric(strprintf("%u.%u.0.1", first_octet + i, i), 15714), NODE_NETWORK},
                               /*nKeyedNetGroupIn=*/0, /*nLocalHostNonceIn=*/0, CAddress{}, /*addrNameIn=*/"",
                               ConnectionType::OUTBOUND_FULL_RELAY, /*inbound_onion=*/false};
        connman.Handshake(*peer, /*successfully_connected=*/true,
                          ServiceFlags(NODE_NETWORK | (qq ? NODE_QUANTUM_QUASAR : NODE_NONE)),
                          ServiceFlags(NODE_NETWORK), PROTOCOL_VERSION, /*relay_txs=*/true);
        BOOST_REQUIRE(peer->fSuccessfullyConnected);
        connman.AddTestNode(*peer); // Owned (and finalized) by the connman at teardown.
    }
}

/** Bootstrap state in which QQ pursuit applies: proof QQ peers are reachable, and enough peers connected. */
void EnableQQPursuit(node::NodeContext& node, unsigned floor_peers = qq::LEGACY_FIRST_FLOOR, bool qq_peers = false)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*node.connman);
    connman.PublishQQStatus(0, 0, false, ""); // Chain ready, deficit at target.
    AddConnectedFullRelay(node, floor_peers, qq_peers);
    connman.NoteQQHandshake();
}

void PreparePersistedBootstrap(node::NodeContext& node, bool legacy = true, int qq_target = 8, unsigned legacy_stride = 10)
{
    // Actual deterministic addrman and actual Connman/PeerManager, not a selector mock.
    node.peerman.reset();
    node.connman.reset();
    node.addrman = std::make_unique<AddrMan>(*node.netgroupman, true, 0);
    node.connman = std::make_unique<ConnmanTestMsg>(0x1337, 0x1337, *node.addrman, *node.netgroupman, Params());
    PeerManager::Options peer_options;
    peer_options.deterministic_rng = true;
    node.peerman = PeerManager::make(*node.connman, *node.addrman, node.banman.get(), *node.chainman, *node.mempool, peer_options);
    auto& connman = static_cast<ConnmanTestMsg&>(*node.connman);
    PrepareWorker(connman, node);
    CConnman::Options options;
    options.nMaxConnections = 125;
    options.m_max_outbound_full_relay = 16;
    options.m_qq_outbound_target = qq_target;
    options.m_msgproc = node.peerman.get();
    options.m_banman = node.banman.get();
    options.nLocalServices = NODE_NETWORK;
    options.nSendBufferMaxSize = options.nReceiveFloodSize = 1024 * 1024;
    connman.Init(options);
    connman.PublishQQStatus(0, 0, false, "chain-not-ready");
    for (unsigned i = 0; node.addrman->Size() < 6446 && i < 30000; ++i) {
        const bool qq = !legacy || i % legacy_stride != 0;
        const auto address = LookupNumeric(strprintf("11.%u.%u.1", i / 256, i % 256), qq ? 46005 : 15714);
        CAddress entry{address, ServiceFlags(NODE_NETWORK | (qq ? NODE_QUANTUM_QUASAR : NODE_NONE))};
        entry.nTime = NodeSeconds{std::chrono::seconds{NOW - (qq ? 60 * 86400 : 60)}};
        const auto source = LookupNumeric(strprintf("12.%u.%u.1", i / 256, i % 256), 15714);
        node.addrman->Add({entry}, source);
    }
    BOOST_REQUIRE_EQUAL(node.addrman->Size(), 6446U);
}

class RefusedBootstrapSocket : public Sock {
    const std::function<void()> attempted;
public:
    explicit RefusedBootstrapSocket(std::function<void()> callback) : Sock{INVALID_SOCKET}, attempted{std::move(callback)} {}
    int Connect(const sockaddr*, socklen_t) const override
    {
        attempted(); // Observe the actual socket Connect boundary, not CreateSock/selection.
        errno = ECONNREFUSED;
        return SOCKET_ERROR;
    }
};
} // namespace

BOOST_FIXTURE_TEST_CASE(actual_connman_persisted_qq_pool_bootstrap_attempt_fairness, TestingSetup)
{
    // N1a: the QQ,QQ,legacy cadence now applies only with recent QQ handshake
    // evidence and at least four connected full-relay peers. Same assertions
    // as in RC5; only this precondition was added to the fixture.
    PreparePersistedBootstrap(m_node);
    EnableQQPursuit(m_node);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    SocketFactoryScope factory;
    std::mutex mutex;
    std::vector<bool> attempts;
    CreateSock = [&](const CService& address) -> std::unique_ptr<Sock> {
        const bool qq = address.GetPort() == 46005;
        return std::make_unique<RefusedBootstrapSocket>([&, qq] {
            std::lock_guard<std::mutex> lock{mutex};
            attempts.push_back(qq);
            if (attempts.size() == 9) connman.Interrupt();
        });
    };
    connman.StartHTTPSAutomaticConnectionsForTest();
    const bool completed = Eventually([&] { std::lock_guard<std::mutex> lock{mutex}; return attempts.size() >= 9; }, std::chrono::seconds{10});
    connman.StopHTTPSForTest();
    BOOST_REQUIRE(completed);
    BOOST_REQUIRE_EQUAL(attempts.size(), 9U);
    std::string observed;
    for (bool qq : attempts) observed += qq ? 'Q' : 'L';
    BOOST_TEST_MESSAGE("Actual socket-attempt classes: " << observed);
    BOOST_CHECK_MESSAGE(std::find(attempts.begin(), attempts.begin() + 3, false) != attempts.begin() + 3,
                        "A legacy attempt must receive an opportunity after at most two QQ-hint attempts: " << observed);
    for (size_t offset = 0; offset < attempts.size(); offset += 3) {
        BOOST_CHECK(std::find(attempts.begin() + offset, attempts.begin() + offset + 3, false) != attempts.begin() + offset + 3);
    }
    BOOST_CHECK_EQUAL(connman.GetQQTarget(), 8);
    BOOST_CHECK_EQUAL(connman.GetQQStatus().connect_attempts, 0U); // Ordinary attempts are not QQ probes.
}

BOOST_FIXTURE_TEST_CASE(actual_connman_bootstrap_target_zero_does_not_force_legacy, TestingSetup)
{
    PreparePersistedBootstrap(m_node, true, 0);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    SocketFactoryScope factory;
    std::mutex mutex;
    std::vector<bool> attempts;
    CreateSock = [&](const CService& address) -> std::unique_ptr<Sock> {
        const bool qq = address.GetPort() == 46005;
        return std::make_unique<RefusedBootstrapSocket>([&, qq] {
            std::lock_guard<std::mutex> lock{mutex};
            attempts.push_back(qq);
            if (attempts.size() == 9) connman.Interrupt();
        });
    };
    connman.StartHTTPSAutomaticConnectionsForTest();
    const bool completed = Eventually([&] { std::lock_guard<std::mutex> lock{mutex}; return attempts.size() >= 9; }, std::chrono::seconds{10});
    connman.StopHTTPSForTest();
    BOOST_REQUIRE(completed);
    std::string observed;
    for (bool qq : attempts) observed += qq ? 'Q' : 'L';
    BOOST_TEST_MESSAGE("Policy-off actual socket-attempt classes: " << observed);
    // This deterministic QQ-rich pool must not be rewritten into QQL cycles
    // when the caller explicitly disabled QQ pursuit.
    BOOST_REQUIRE(attempts.size() >= 3);
    BOOST_CHECK(attempts[0] && attempts[1] && attempts[2]);
    BOOST_CHECK_EQUAL(connman.GetQQTarget(), 0);
}

namespace {
/** Run the real open-connections thread against refusing sockets and return the first `count` attempt classes (Q: QQ-flagged hint, L: legacy). */
std::string ObserveBootstrapAttempts(ConnmanTestMsg& connman, size_t count, std::chrono::seconds timeout = std::chrono::seconds{60})
{
    SocketFactoryScope factory;
    std::mutex mutex;
    std::string seen;
    CreateSock = [&](const CService& address) -> std::unique_ptr<Sock> {
        const bool qq = address.GetPort() == 46005;
        return std::make_unique<RefusedBootstrapSocket>([&, qq] {
            std::lock_guard<std::mutex> lock{mutex};
            seen += qq ? 'Q' : 'L';
            if (seen.size() == count) connman.Interrupt();
        });
    };
    connman.StartHTTPSAutomaticConnectionsForTest();
    const bool completed = Eventually([&] { std::lock_guard<std::mutex> lock{mutex}; return seen.size() >= count; }, timeout);
    connman.StopHTTPSForTest();
    BOOST_REQUIRE(completed);
    std::lock_guard<std::mutex> lock{mutex};
    return seen.substr(0, count);
}

std::string DebugLogText()
{
    std::ifstream file{LogInstance().m_file_path};
    std::stringstream text;
    text << file.rdbuf();
    return text.str();
}

size_t CountOf(const std::string& text, const std::string& needle)
{
    size_t count{0};
    for (auto at = text.find(needle); at != std::string::npos; at = text.find(needle, at + 1)) ++count;
    return count;
}
} // namespace

BOOST_AUTO_TEST_CASE(qq_legacy_first_policy_rules)
{
    // Floor: four connected full-relay peers, or all of a smaller capacity.
    BOOST_CHECK_EQUAL(qq::LegacyFirstFloor(16), 4);
    BOOST_CHECK_EQUAL(qq::LegacyFirstFloor(4), 4);
    BOOST_CHECK_EQUAL(qq::LegacyFirstFloor(3), 3);
    BOOST_CHECK_EQUAL(qq::LegacyFirstFloor(0), 0);
    BOOST_CHECK_EQUAL(qq::LegacyFirstFloor(-1), 0);
    // No QQ evidence: legacy-first at every peer count, including a full set.
    for (int peers = 0; peers <= 16; ++peers) BOOST_CHECK(qq::LegacyFirst(8, peers, 16, false));
    // Evidence: legacy-first below the floor only.
    for (int peers = 0; peers < 4; ++peers) BOOST_CHECK(qq::LegacyFirst(8, peers, 16, true));
    for (int peers = 4; peers <= 16; ++peers) BOOST_CHECK(!qq::LegacyFirst(8, peers, 16, true));
    BOOST_CHECK(qq::LegacyFirst(2, 2, 3, true));
    BOOST_CHECK(!qq::LegacyFirst(2, 3, 3, true));
    // Policy off: selection is never reordered.
    BOOST_CHECK(!qq::LegacyFirst(0, 0, 16, false));
    // Deficit is 0 in IBD unless a QQ peer is already connected.
    BOOST_CHECK_EQUAL(qq::EffectiveDeficit(8, false, false), 0);
    BOOST_CHECK_EQUAL(qq::EffectiveDeficit(8, false, true), 8);
    BOOST_CHECK_EQUAL(qq::EffectiveDeficit(8, true, false), 8);
    BOOST_CHECK_EQUAL(qq::EffectiveDeficit(0, true, true), 0);
    // Backoff schedule.
    BOOST_CHECK_EQUAL(qq::HTTPS_BACKOFF_STEPS, 4U);
    const int64_t expected[]{60, 120, 300, 600};
    for (size_t i = 0; i < 4; ++i) BOOST_CHECK_EQUAL(qq::HTTPS_BACKOFF[i].count(), expected[i]);
}

BOOST_AUTO_TEST_CASE(qq_legacy_first_qq_turn_policy_rules)
{
    // The turn comes after two consecutive legacy-first dials, and only in legacy-first.
    BOOST_CHECK(!qq::LegacyFirstQQTurn(true, 0));
    BOOST_CHECK(!qq::LegacyFirstQQTurn(true, 1));
    BOOST_CHECK(qq::LegacyFirstQQTurn(true, 2));
    BOOST_CHECK(qq::LegacyFirstQQTurn(true, 7));
    for (unsigned streak = 0; streak < 10; ++streak) BOOST_CHECK(!qq::LegacyFirstQQTurn(false, streak));
    // The streak: a failed legacy-first dial to a non-QQ address adds one.
    BOOST_CHECK_EQUAL(qq::NextLegacyFirstStreak(0, true, false, false, false), 1U);
    BOOST_CHECK_EQUAL(qq::NextLegacyFirstStreak(1, true, false, false, false), 2U);
    // A QQ turn resets it whatever it dialed.
    BOOST_CHECK_EQUAL(qq::NextLegacyFirstStreak(2, true, true, true, false), 0U);
    BOOST_CHECK_EQUAL(qq::NextLegacyFirstStreak(2, true, true, false, true), 0U);
    // A dial that connected, a QQ-flagged dial in any other selection, or any
    // dial outside legacy-first resets it.
    BOOST_CHECK_EQUAL(qq::NextLegacyFirstStreak(1, true, false, false, true), 0U);
    BOOST_CHECK_EQUAL(qq::NextLegacyFirstStreak(1, true, false, true, false), 0U);
    BOOST_CHECK_EQUAL(qq::NextLegacyFirstStreak(1, false, false, false, false), 0U);
    // Simulated cadence of failing dials: two legacy, one QQ turn, repeat.
    unsigned streak{0};
    std::string cadence;
    for (int i = 0; i < 9; ++i) {
        const bool turn = qq::LegacyFirstQQTurn(true, streak);
        cadence += turn ? 'Q' : 'L';
        streak = qq::NextLegacyFirstStreak(streak, true, turn, turn, false);
    }
    BOOST_CHECK_EQUAL(cadence, "LLQLLQLLQ");
    // A legacy peer that connects shows the pool works: no turn is earned.
    streak = 0;
    for (int i = 0; i < 6; ++i) {
        BOOST_CHECK(!qq::LegacyFirstQQTurn(true, streak));
        streak = qq::NextLegacyFirstStreak(streak, true, false, false, true);
    }
    // The legacy-first predicate itself is unchanged, and policy off stays off.
    BOOST_CHECK(!qq::LegacyFirst(0, 0, 16, false));
}

BOOST_FIXTURE_TEST_CASE(qq_seed_hint_evidence_window, TestingSetup)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    const auto start = qq::Clock::now();
    BOOST_CHECK(!connman.HasQQEvidence(start));
    // An empty round is not evidence.
    connman.NoteQQSeedHints(0, start);
    BOOST_CHECK(!connman.HasRecentQQSeedHints(start));
    connman.NoteQQSeedHints(3, start);
    BOOST_CHECK(connman.HasQQEvidence(start));
    BOOST_CHECK(connman.HasQQEvidence(start + qq::EVIDENCE_WINDOW));
    BOOST_CHECK(!connman.HasQQEvidence(start + qq::EVIDENCE_WINDOW + std::chrono::seconds{1}));
    // A later empty round does not erase a recent hint round, and does not extend it.
    connman.NoteQQSeedHints(0, start + std::chrono::minutes{10});
    BOOST_CHECK(connman.HasQQEvidence(start + std::chrono::minutes{20}));
    // Seed hints are not a handshake and do not change what the handshake reports.
    BOOST_CHECK(!connman.HasRecentQQHandshake(start));
}

namespace {
/** Mostly dead legacy addresses and a few QQ-flagged hints, as on a real node after a seed round. */
void PrepareLegacyHeavyPool(node::NodeContext& node, unsigned qq_hints)
{
    PreparePersistedBootstrap(node, /*legacy=*/true, /*qq_target=*/8, /*legacy_stride=*/1); // Every entry legacy.
    // A bucket collision with an existing entry rejects an add; move to another group until it lands.
    for (unsigned i = 0, probe = 0; i < qq_hints; ++probe) {
        BOOST_REQUIRE(probe < 500);
        CAddress hint{LookupNumeric(strprintf("13.%u.0.1", probe), 46005), ServiceFlags(NODE_NETWORK | NODE_QUANTUM_QUASAR)};
        hint.nTime = NodeSeconds{std::chrono::seconds{NOW - 60}};
        if (node.addrman->Add({hint}, LookupNumeric(strprintf("14.%u.0.1", probe), 15714))) ++i;
    }
    BOOST_REQUIRE_EQUAL(node.addrman->Size(), 6446U + qq_hints);
    unsigned flagged{0};
    for (const auto& entry : node.addrman->GetAddr(0, 0, std::nullopt)) flagged += (entry.nServices & NODE_QUANTUM_QUASAR) ? 1 : 0;
    BOOST_REQUIRE_EQUAL(flagged, qq_hints);
}
} // namespace

BOOST_FIXTURE_TEST_CASE(actual_connman_legacy_first_gives_qq_hint_a_turn, TestingSetup)
{
    // The field defect: thousands of dead legacy entries, three QQ hints, no
    // peers, no evidence. Legacy-first alone never dials a hint.
    PrepareLegacyHeavyPool(m_node, 3);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    connman.PublishQQStatus(0, 0, false, "");
    const auto observed = ObserveBootstrapAttempts(connman, 15);
    BOOST_TEST_MESSAGE("Legacy-heavy pool, three hints, zero peers: " << observed);
    // One distinct hint per turn. Once every hint was offered in the last ten
    // minutes the turn falls back to an ordinary draw, which here is legacy.
    BOOST_CHECK_EQUAL(observed.substr(0, 9), "LLQLLQLLQ");
    BOOST_CHECK_EQUAL(std::count(observed.begin(), observed.end(), 'Q'), 3);
}

BOOST_FIXTURE_TEST_CASE(actual_connman_qq_turn_reaches_a_lone_hint_in_a_large_pool, TestingSetup)
{
    // One hint among thousands of dead legacy entries: the first turn dials it.
    PrepareLegacyHeavyPool(m_node, 1);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    connman.PublishQQStatus(0, 0, false, "");
    const auto observed = ObserveBootstrapAttempts(connman, 3);
    BOOST_TEST_MESSAGE("Legacy-heavy pool, one hint, zero peers: " << observed);
    BOOST_CHECK_EQUAL(observed, "LLQ");
}

BOOST_FIXTURE_TEST_CASE(actual_connman_qq_turn_costs_nothing_without_qq_addresses, TestingSetup)
{
    // No QQ-flagged address at all: the turn falls back to any valid address and
    // every attempt still dials the legacy pool.
    PrepareLegacyHeavyPool(m_node, 0);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    connman.PublishQQStatus(0, 0, false, "");
    const auto observed = ObserveBootstrapAttempts(connman, 12);
    BOOST_TEST_MESSAGE("Legacy-only pool: " << observed);
    BOOST_CHECK_EQUAL(observed, std::string(12, 'L'));
}

BOOST_FIXTURE_TEST_CASE(actual_connman_seed_hints_are_evidence_at_the_floor, TestingSetup)
{
    // Four connected peers and a fresh seed round with hints: pursuit resumes
    // without any handshake. Without the round it stays legacy-first.
    PreparePersistedBootstrap(m_node, true, 8, 4);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    connman.PublishQQStatus(0, 0, false, "");
    AddConnectedFullRelay(m_node, qq::LEGACY_FIRST_FLOOR, false);
    BOOST_REQUIRE(!connman.HasQQEvidence());
    connman.NoteQQSeedHints(3);
    BOOST_REQUIRE(connman.HasQQEvidence());
    BOOST_REQUIRE(!connman.HasRecentQQHandshake());
    const auto observed = ObserveBootstrapAttempts(connman, 12);
    BOOST_TEST_MESSAGE("Seed-hint evidence with 4 peers: " << observed);
    BOOST_CHECK_EQUAL(observed, "QQLQQLQQLQQL");
}

BOOST_FIXTURE_TEST_CASE(qq_handshake_evidence_window, TestingSetup)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    const auto start = qq::Clock::now();
    BOOST_CHECK(!connman.HasRecentQQHandshake(start));
    connman.NoteQQHandshake(start);
    BOOST_CHECK(connman.HasRecentQQHandshake(start));
    BOOST_CHECK(connman.HasRecentQQHandshake(start + qq::EVIDENCE_WINDOW));
    BOOST_CHECK(!connman.HasRecentQQHandshake(start + qq::EVIDENCE_WINDOW + std::chrono::seconds{1}));
    connman.NoteQQHandshake(start + std::chrono::hours{1});
    BOOST_CHECK(connman.HasRecentQQHandshake(start + std::chrono::hours{1} + std::chrono::minutes{29}));
}

BOOST_FIXTURE_TEST_CASE(actual_connman_zero_qq_evidence_prefers_legacy, TestingSetup)
{
    // Thousands of dead QQ-flagged entries, a quarter legacy, no peers, no QQ
    // evidence, chain ready (deficit at target): legacy first, with one QQ
    // turn after every two legacy dials.
    PreparePersistedBootstrap(m_node, true, 8, 4);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    connman.PublishQQStatus(0, 0, false, "");
    BOOST_REQUIRE_EQUAL(connman.GetQQStatus().deficit, 8);
    const auto observed = ObserveBootstrapAttempts(connman, 20);
    BOOST_TEST_MESSAGE("Zero QQ evidence, zero peers: " << observed);
    BOOST_CHECK_EQUAL(observed, "LLQLLQLLQLLQLLQLLQLL");
    BOOST_CHECK_EQUAL(connman.GetQQStatus().connect_attempts, 0U);
}

BOOST_FIXTURE_TEST_CASE(actual_connman_qq_evidence_below_floor_stays_legacy_first, TestingSetup)
{
    // Recent QQ evidence, but one connected peer short of the floor of four.
    PreparePersistedBootstrap(m_node, true, 8, 4);
    EnableQQPursuit(m_node, qq::LEGACY_FIRST_FLOOR - 1);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    BOOST_REQUIRE(connman.HasRecentQQHandshake());
    const auto observed = ObserveBootstrapAttempts(connman, 12);
    BOOST_TEST_MESSAGE("Evidence with 3 peers: " << observed);
    BOOST_CHECK_EQUAL(observed, "LLQLLQLLQLLQ");
}

BOOST_FIXTURE_TEST_CASE(actual_connman_qq_evidence_at_floor_resumes_pursuit, TestingSetup)
{
    PreparePersistedBootstrap(m_node, true, 8, 4);
    EnableQQPursuit(m_node, qq::LEGACY_FIRST_FLOOR);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    const auto observed = ObserveBootstrapAttempts(connman, 12);
    BOOST_TEST_MESSAGE("Evidence with 4 peers: " << observed);
    BOOST_CHECK_EQUAL(observed, "QQLQQLQQLQQL");
}

BOOST_FIXTURE_TEST_CASE(actual_connman_expired_qq_evidence_is_legacy_first, TestingSetup)
{
    // The only QQ handshake is older than the window: no pursuit even with a full floor.
    PreparePersistedBootstrap(m_node, true, 8, 4);
    EnableQQPursuit(m_node, qq::LEGACY_FIRST_FLOOR);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    connman.NoteQQHandshake(qq::Clock::now() - qq::EVIDENCE_WINDOW - std::chrono::minutes{1});
    BOOST_REQUIRE(!connman.HasRecentQQHandshake());
    const auto observed = ObserveBootstrapAttempts(connman, 12);
    BOOST_TEST_MESSAGE("Expired evidence with 4 peers: " << observed);
    BOOST_CHECK_EQUAL(observed, "LLQLLQLLQLLQ");
}

BOOST_FIXTURE_TEST_CASE(actual_connman_ibd_treats_qq_deficit_as_zero, TestingSetup)
{
    // Evidence and four legacy peers (pursuit would apply), but the chain is not
    // ready: the published deficit stays at target, the dial preference is off,
    // so the QQ,QQ,legacy cadence must not appear in a QQ-rich pool.
    PreparePersistedBootstrap(m_node, true, 8, 4);
    EnableQQPursuit(m_node, qq::LEGACY_FIRST_FLOOR);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    connman.PublishQQStatus(0, 0, false, "chain-not-ready");
    BOOST_REQUIRE_EQUAL(connman.GetQQStatus().deficit, 8);
    const auto observed = ObserveBootstrapAttempts(connman, 30);
    BOOST_TEST_MESSAGE("IBD, legacy peers only: " << observed);
    // The cadence never puts two legacy attempts side by side, and never three QQ ones.
    BOOST_CHECK_MESSAGE(observed.find("LL") != std::string::npos || observed.find("QQQ") != std::string::npos,
                        "IBD must not shape draws: " << observed);
    BOOST_CHECK_EQUAL(connman.GetQQStatus().deficit, 8);
}

BOOST_FIXTURE_TEST_CASE(actual_connman_ibd_with_connected_qq_peers_keeps_pursuit, TestingSetup)
{
    // A connected QQ peer keeps the deficit alive in IBD.
    PreparePersistedBootstrap(m_node, true, 8, 4);
    EnableQQPursuit(m_node, qq::LEGACY_FIRST_FLOOR, /*qq_peers=*/true);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    connman.PublishQQStatus(4, 0, false, "chain-not-ready");
    const auto observed = ObserveBootstrapAttempts(connman, 12);
    BOOST_TEST_MESSAGE("IBD with connected QQ peers: " << observed);
    BOOST_CHECK_EQUAL(observed, "QQLQQLQQLQQL");
}

BOOST_FIXTURE_TEST_CASE(actual_connman_https_backoff_schedule_and_reset, TestingSetup)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    PrepareWorker(connman, m_node);
    enum Step { FAIL, REJECT, EMPTY, HINT };
    const std::vector<Step> script{FAIL, REJECT, EMPTY, FAIL, FAIL, HINT, FAIL, HINT};
    std::atomic<unsigned> fetches{0};
    WorkerGate gate{connman};
    httpsseed::WorkerHooks hooks;
    hooks.now = [&] { return gate.Now(); };
    hooks.wait = [&] { return gate.Wait(); };
    hooks.fetch = [&](const auto&, const auto&) -> httpsseed::FetchResult {
        const auto step = script.at(fetches++);
        if (step == FAIL) return {false, {}, "fixture failure"};
        if (step == REJECT) return {true, "not json", {}};
        UniValue doc{UniValue::VOBJ};
        doc.pushKV("schema", "blackcoin.bootstrap/1");
        doc.pushKV("network", "main");
        doc.pushKV("generated_at", NOW);
        doc.pushKV("expires_at", NOW + 120);
        UniValue peers{UniValue::VARR};
        if (step == HINT) peers.push_back(Peer());
        doc.pushKV("peers", peers);
        return {true, doc.write(), {}};
    };
    WorkerRun worker{connman, gate, hooks};
    {
        ASSERT_DEBUG_LOG("HTTPS seed round: outcome=fetch-failed hints=0 retry_in=60s");
        BOOST_REQUIRE(gate.Step());
        BOOST_CHECK_EQUAL(fetches.load(), 1U);
    }
    // Each unproductive round is retried at 60, 120, 300, 600 s.
    const auto retry_after = [&](int64_t gap) {
        const auto before = fetches.load();
        BOOST_REQUIRE(gate.Step(gap - 1));
        BOOST_CHECK_EQUAL(fetches.load(), before);
        BOOST_REQUIRE(gate.Step(1));
        BOOST_CHECK_EQUAL(fetches.load(), before + 1);
    };
    retry_after(60);   // round 2: rejected body
    retry_after(120);  // round 3: accepted, zero hints
    retry_after(300);  // round 4: failed
    retry_after(600);  // round 5: failed
    // Backoff exhausted: the normal 30 to 35 minute cadence resumes.
    BOOST_REQUIRE(gate.Step(1799));
    BOOST_CHECK_EQUAL(fetches.load(), 5U);
    {
        ASSERT_DEBUG_LOG("HTTPS seed round: outcome=accepted hints=1");
        BOOST_REQUIRE(gate.Step(301)); // round 6: one usable hint resets the backoff
        BOOST_CHECK_EQUAL(fetches.load(), 6U);
    }
    BOOST_CHECK_EQUAL(m_node.addrman->Size(), 1U);
    BOOST_REQUIRE(gate.Step(1799));
    BOOST_CHECK_EQUAL(fetches.load(), 6U);
    BOOST_REQUIRE(gate.Step(301)); // round 7: failed, after the reset
    BOOST_CHECK_EQUAL(fetches.load(), 7U);
    retry_after(60);   // back to the first backoff step
    BOOST_CHECK_EQUAL(fetches.load(), 8U);
}

BOOST_FIXTURE_TEST_CASE(actual_connman_zero_peers_logs_once_per_ten_minutes_without_addresses, TestingSetup)
{
    PreparePersistedBootstrap(m_node);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    SocketFactoryScope factory;
    std::atomic<unsigned> attempts{0};
    CreateSock = [&](const CService&) -> std::unique_ptr<Sock> {
        return std::make_unique<RefusedBootstrapSocket>([&] { ++attempts; });
    };
    connman.StartHTTPSAutomaticConnectionsForTest();
    struct Stop { ConnmanTestMsg& c; ~Stop() { c.StopHTTPSForTest(); } } stop{connman};
    const auto passes = [&](unsigned more) {
        const auto target = attempts.load() + more;
        BOOST_REQUIRE(Eventually([&] { return attempts.load() >= target; }, std::chrono::seconds{30}));
    };
    passes(2); // The zero-peer window is open.
    BOOST_CHECK_EQUAL(CountOf(DebugLogText(), "No peers for"), 0U);
    SetMockTime(NOW + 61);
    passes(2);
    BOOST_REQUIRE(Eventually([&] { return CountOf(DebugLogText(), "No peers for") == 1; }));
    const auto text = DebugLogText();
    const auto at = text.find("No peers for 61 seconds: addrman=6446 dial_attempts=");
    BOOST_REQUIRE(at != std::string::npos);
    const auto line = text.substr(at, text.find('\n', at) - at);
    BOOST_TEST_MESSAGE(line);
    BOOST_CHECK(line.find('.') == std::string::npos); // No address in the line.
    const std::string prefix{"No peers for 61 seconds: addrman=6446 dial_attempts="};
    const auto separator = line.find(" dial_failures=");
    BOOST_REQUIRE(separator != std::string::npos);
    const auto hints_at = line.find(" qq_hints=");
    const auto dials_at = line.find(" qq_dials=");
    BOOST_REQUIRE(hints_at != std::string::npos && dials_at != std::string::npos && separator < hints_at && hints_at < dials_at);
    uint64_t logged_attempts{0}, logged_failures{0}, logged_hints{1}, logged_qq_dials{0};
    BOOST_REQUIRE(ParseUInt64(line.substr(prefix.size(), separator - prefix.size()), &logged_attempts));
    const std::string failures_label{" dial_failures="};
    BOOST_REQUIRE(ParseUInt64(line.substr(separator + failures_label.size(), hints_at - separator - failures_label.size()), &logged_failures));
    BOOST_REQUIRE(ParseUInt64(line.substr(hints_at + std::string{" qq_hints="}.size(), dials_at - hints_at - std::string{" qq_hints="}.size()), &logged_hints));
    // qq_dials is followed by the failure breakdown, which later fields append to.
    const auto dials_value_at = dials_at + std::string{" qq_dials="}.size();
    const auto dials_end = line.find(' ', dials_value_at);
    BOOST_REQUIRE(dials_end != std::string::npos);
    BOOST_REQUIRE(ParseUInt64(line.substr(dials_value_at, dials_end - dials_value_at), &logged_qq_dials));
    // The breakdown classifies exactly the failures counted in dial_failures.
    uint64_t classified{0};
    for (const std::string label : {" fail_timeout=", " fail_refused=", " fail_unreachable=", " fail_addrnotavail=", " fail_other="}) {
        const auto at_label = line.find(label);
        BOOST_REQUIRE(at_label != std::string::npos);
        const auto value_at = at_label + label.size();
        uint64_t value{0};
        BOOST_REQUIRE(ParseUInt64(line.substr(value_at, line.find(' ', value_at) - value_at), &value));
        classified += value;
    }
    BOOST_CHECK_EQUAL(classified, logged_failures);
    BOOST_CHECK(line.find(" last_fail=") != std::string::npos);
    BOOST_CHECK(line.find(" handshake_fail=0 network_active=1") != std::string::npos);
    BOOST_CHECK(logged_attempts >= 2);
    BOOST_CHECK_EQUAL(logged_attempts, logged_failures);
    BOOST_CHECK_EQUAL(logged_hints, 0U); // No accepted seed round in this test.
    BOOST_CHECK(logged_qq_dials <= logged_attempts);
    // Rate limit: nothing more for ten minutes of (mock) time.
    SetMockTime(NOW + 61 + 599);
    passes(3);
    BOOST_CHECK_EQUAL(CountOf(DebugLogText(), "No peers for"), 1U);
    SetMockTime(NOW + 61 + 600);
    passes(2);
    BOOST_REQUIRE(Eventually([&] { return CountOf(DebugLogText(), "No peers for") == 2; }));
}

namespace {
class BootstrapProxySocket : public Sock {
    const std::vector<uint8_t> responses;
    const bool fail_connect_send;
    mutable size_t offset{0};
public:
    mutable unsigned tcp_attempts{0}, target_requests{0};
    BootstrapProxySocket(std::vector<uint8_t> data, bool fail = false) : Sock{INVALID_SOCKET}, responses{std::move(data)}, fail_connect_send{fail} {}
    int Connect(const sockaddr*, socklen_t) const override { ++tcp_attempts; return 0; }
    ssize_t Send(const void* data, size_t length, int) const override
    {
        const auto* bytes = static_cast<const uint8_t*>(data);
        if (length > 3 && bytes[0] == 5 && bytes[1] == 1) {
            if (fail_connect_send) return 0;
            ++target_requests;
        }
        return length;
    }
    ssize_t Recv(void* data, size_t length, int) const override
    {
        const auto count = std::min(length, responses.size() - offset);
        std::memcpy(data, responses.data() + offset, count);
        offset += count;
        return count;
    }
};
} // namespace

BOOST_AUTO_TEST_CASE(bootstrap_proxy_target_attempt_boundary)
{
    InterruptSocks5(false); // Earlier owned-worker Stop cancels SOCKS globally, as Start resets it.
    const Proxy proxy{LookupNumeric("127.0.0.1", 9050), false};
    // Failed greeting or failed CONNECT send is not a destination attempt.
    for (bool partial : {false, true}) {
        BootstrapProxySocket socket{partial ? std::vector<uint8_t>{5, 0} : std::vector<uint8_t>{4, 0}, partial};
        bool proxy_failed{false}, attempted{true};
        BOOST_CHECK(!ConnectThroughProxy(proxy, "8.8.8.8", 15714, socket, 100, proxy_failed, &attempted));
        BOOST_CHECK_EQUAL(socket.tcp_attempts, 1U);
        BOOST_CHECK_EQUAL(socket.target_requests, 0U);
        BOOST_CHECK(!attempted);
    }
    BootstrapProxySocket refused{{5, 0, 5, 5, 0, 1}};
    bool proxy_failed{false}, attempted{false};
    BOOST_CHECK(!ConnectThroughProxy(proxy, "8.8.8.8", 15714, refused, 100, proxy_failed, &attempted));
    BOOST_CHECK(attempted);
    BOOST_CHECK_EQUAL(refused.target_requests, 1U);
    const ProxyCredentials auth{"fixture", "fixture"};
    BootstrapProxySocket bad_auth{{5, 2, 1, 1}};
    attempted = true;
    BOOST_CHECK(!Socks5("8.8.8.8", 15714, &auth, bad_auth, &attempted));
    BOOST_CHECK(!attempted);
    BOOST_CHECK_EQUAL(bad_auth.target_requests, 0U);
}

BOOST_FIXTURE_TEST_CASE(actual_connman_bootstrap_qq_only_pool_keeps_attempting, TestingSetup)
{
    PreparePersistedBootstrap(m_node, false);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    SocketFactoryScope factory;
    std::atomic<unsigned> attempts{0};
    CreateSock = [&](const CService&) -> std::unique_ptr<Sock> {
        return std::make_unique<RefusedBootstrapSocket>([&] { if (++attempts == 6) connman.Interrupt(); });
    };
    connman.StartHTTPSAutomaticConnectionsForTest();
    const bool completed = Eventually([&] { return attempts >= 6; }, std::chrono::seconds{10});
    connman.StopHTTPSForTest();
    BOOST_REQUIRE(completed);
    BOOST_CHECK_EQUAL(attempts.load(), 6U);
    BOOST_CHECK_EQUAL(connman.GetQQTarget(), 8);
}

BOOST_FIXTURE_TEST_CASE(actual_connman_bootstrap_socket_creation_is_not_attempt, TestingSetup)
{
    PreparePersistedBootstrap(m_node);
    EnableQQPursuit(m_node);
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    SocketFactoryScope factory;
    unsigned rejected{0};
    std::mutex mutex;
    std::vector<bool> attempts;
    CreateSock = [&](const CService& address) -> std::unique_ptr<Sock> {
        if (rejected < 2) { ++rejected; return nullptr; }
        const bool qq = address.GetPort() == 46005;
        return std::make_unique<RefusedBootstrapSocket>([&, qq] {
            std::lock_guard<std::mutex> lock{mutex};
            attempts.push_back(qq);
            if (attempts.size() == 3) connman.Interrupt();
        });
    };
    connman.StartHTTPSAutomaticConnectionsForTest();
    const bool completed = Eventually([&] { std::lock_guard<std::mutex> lock{mutex}; return attempts.size() >= 3; }, std::chrono::seconds{10});
    connman.StopHTTPSForTest();
    BOOST_REQUIRE(completed);
    BOOST_REQUIRE_EQUAL(attempts.size(), 3U);
    BOOST_CHECK_EQUAL(rejected, 2U);
    BOOST_CHECK(attempts[0] && attempts[1] && !attempts[2]);
}

namespace {
class RecordingBootstrapSocket : public RedirectSocket {
    const std::function<void()> attempted;
public:
    RecordingBootstrapSocket(uint16_t target, std::function<void()> callback) : RedirectSocket{target}, attempted{std::move(callback)} {}
    int Connect(const sockaddr* address, socklen_t length) const override
    {
        const int result = RedirectSocket::Connect(address, length);
        const int error = errno;
        attempted();
        errno = error;
        return result;
    }
};

void CompleteBootstrapHandshake(ConnmanTestMsg& connman, node::NodeContext& node, CNode& peer)
{
    TimeDataScope time_data_scope;
    LOCK(NetEventsInterface::g_msgproc_mutex);
    connman.FlushSendBuffer(peer);
    const CNetMsgMaker messages{0};
    auto version = messages.Make(NetMsgType::VERSION, PROTOCOL_VERSION,
        Using<CustomUintFormatter<8>>(ServiceFlags{NODE_NETWORK}), int64_t{NOW},
        int64_t{}, CNetAddr::V1(CService{}), int64_t{}, CNetAddr::V1(CService{}),
        uint64_t{1}, std::string{}, int32_t{}, true);
    BOOST_REQUIRE(connman.ReceiveMsgFrom(peer, std::move(version)));
    connman.ProcessMessagesOnce(peer);
    node.peerman->SendMessages(&peer);
    connman.FlushSendBuffer(peer);
    BOOST_REQUIRE(!peer.fDisconnect);
    BOOST_REQUIRE(connman.ReceiveMsgFrom(peer, messages.Make(NetMsgType::VERACK)));
    connman.ProcessMessagesOnce(peer);
    BOOST_REQUIRE(peer.fSuccessfullyConnected);
}

void LegacyReplenishmentAfterBootstrap(node::NodeContext& node, bool handshake)
{
    PreparePersistedBootstrap(node);
    EnableQQPursuit(node);
    auto& connman = static_cast<ConnmanTestMsg&>(*node.connman);
    TestSocket listener{static_cast<SOCKET>(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP))};
    sockaddr_in local{}; local.sin_family = AF_INET; local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOST_REQUIRE(listener.SetNonBlocking());
    BOOST_REQUIRE_EQUAL(listener.Bind(reinterpret_cast<sockaddr*>(&local), sizeof(local)), 0);
    BOOST_REQUIRE_EQUAL(listener.Listen(2), 0);
    socklen_t size{sizeof(local)};
    BOOST_REQUIRE_EQUAL(listener.GetSockName(reinterpret_cast<sockaddr*>(&local), &size), 0);
    SocketFactoryScope factory;
    std::mutex mutex;
    std::condition_variable condition;
    std::vector<bool> attempts;
    std::vector<std::string> legacy_endpoints;
    bool released{false}, pause_timed_out{false};
    std::vector<std::unique_ptr<TestSocket>> accepted;
    struct StopOnExit {
        ConnmanTestMsg& connman;
        std::mutex& mutex;
        std::condition_variable& condition;
        bool& released;
        ~StopOnExit()
        {
            { std::lock_guard<std::mutex> lock{mutex}; released = true; }
            condition.notify_all();
            connman.StopHTTPSForTest();
        }
    } stop_on_exit{connman, mutex, condition, released};
    const auto record = [&](bool qq) {
        std::unique_lock<std::mutex> lock{mutex};
        attempts.push_back(qq);
        if (attempts.size() == 5) {
            if (!condition.wait_for(lock, std::chrono::seconds{5}, [&] { return released; })) pause_timed_out = true;
        }
        if (attempts.size() == 6) connman.Interrupt();
    };
    CreateSock = [&](const CService& address) -> std::unique_ptr<Sock> {
        const bool qq = address.GetPort() == 46005;
        if (!qq && legacy_endpoints.size() < 2) {
            legacy_endpoints.push_back(address.ToStringAddrPort());
            return std::make_unique<RecordingBootstrapSocket>(ntohs(local.sin_port), [&, qq] { record(qq); });
        }
        return std::make_unique<RefusedBootstrapSocket>([&, qq] { record(qq); });
    };
    connman.StartHTTPSAutomaticConnectionsForTest();
    const bool paused = Eventually([&] { std::lock_guard<std::mutex> lock{mutex}; return attempts.size() == 5; }, std::chrono::seconds{10});
    if (paused) {
        BOOST_REQUIRE(!legacy_endpoints.empty());
        auto* peer = connman.FindHTTPSNodeForTest(legacy_endpoints.front());
        BOOST_REQUIRE(peer != nullptr);
        BOOST_CHECK(!peer->fSuccessfullyConnected); // A socket alone must not retire outage fairness.
        const SOCKET peer_fd = static_cast<SOCKET>(accept(listener.Descriptor(), nullptr, nullptr));
        BOOST_REQUIRE(peer_fd != INVALID_SOCKET);
        accepted.push_back(std::make_unique<TestSocket>(peer_fd));
        if (handshake) CompleteBootstrapHandshake(connman, node, *peer);
    }
    { std::lock_guard<std::mutex> lock{mutex}; released = true; }
    condition.notify_all();
    const bool completed = Eventually([&] { std::lock_guard<std::mutex> lock{mutex}; return attempts.size() >= 6; }, std::chrono::seconds{10});
    connman.StopHTTPSForTest();
    BOOST_REQUIRE(paused && completed);
    BOOST_REQUIRE_EQUAL(attempts.size(), 6U);
    BOOST_CHECK(!pause_timed_out);
    BOOST_CHECK(attempts[0] && attempts[1] && !attempts[2] && attempts[3] && attempts[4]);
    std::string observed;
    for (const bool qq : attempts) observed += qq ? 'Q' : 'L';
    BOOST_TEST_MESSAGE("Actual socket-attempt classes during relay replenishment: " << observed);
    BOOST_REQUIRE_MESSAGE(!attempts[5], "Two QQ-hinted attempts must give the next legacy peer a turn even after a full-relay handshake: " << observed);
    BOOST_REQUIRE_EQUAL(legacy_endpoints.size(), 2U);
    auto* replenished = connman.FindHTTPSNodeForTest(legacy_endpoints.back());
    BOOST_REQUIRE(replenished);
    BOOST_CHECK(replenished->IsFullOutboundConn());
    BOOST_CHECK(!replenished->IsQQProbe());
    const SOCKET peer_fd = static_cast<SOCKET>(accept(listener.Descriptor(), nullptr, nullptr));
    BOOST_REQUIRE(peer_fd != INVALID_SOCKET);
    accepted.push_back(std::make_unique<TestSocket>(peer_fd));
    // StopThreads interrupts message processing too. The new persistent
    // socket is observable here; the first peer exercised actual VERSION/VERACK.
    BOOST_CHECK(!replenished->fDisconnect);
    auto* first = connman.FindHTTPSNodeForTest(legacy_endpoints.front());
    BOOST_REQUIRE(first);
    BOOST_CHECK_EQUAL(first->fSuccessfullyConnected.load(), handshake);
    BOOST_CHECK(!first->fDisconnect);
    BOOST_CHECK_EQUAL(connman.GetQQTarget(), 8);
}
} // namespace

BOOST_FIXTURE_TEST_CASE(actual_connman_bootstrap_socket_without_handshake_keeps_recovery, TestingSetup)
{
    LegacyReplenishmentAfterBootstrap(m_node, false);
}

BOOST_FIXTURE_TEST_CASE(actual_connman_replenishes_legacy_after_a_completed_handshake, TestingSetup)
{
    LegacyReplenishmentAfterBootstrap(m_node, true);
}

BOOST_FIXTURE_TEST_CASE(actual_connman_toggle_discards_completed_old_response, TestingSetup)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    PrepareWorker(connman, m_node);
    WorkerGate gate{connman};
    std::atomic<unsigned> fetches{0};
    std::atomic<bool> ready{false}, release{false}, old_cancelled{false};
    httpsseed::WorkerHooks hooks;
    hooks.now = [&] { return gate.Now(); };
    hooks.wait = [&] { return gate.Wait(); };
    hooks.fetch = [&](const auto& options, const auto& cancelled) {
        const auto attempt = ++fetches;
        auto response = LocalFetch(options, cancelled);
        if (attempt == 1) {
            ready = true;
            while (!release && !connman.HTTPSInterruptedForTest()) std::this_thread::sleep_for(std::chrono::milliseconds{1});
            old_cancelled = cancelled();
        }
        return response; // Deliberately return success despite old cancellation.
    };
    WorkerRun worker{connman, gate, hooks};
    gate.Tick();
    BOOST_REQUIRE(Eventually([&] { return ready.load(); }));
    connman.SetNetworkActive(false);
    connman.SetNetworkActive(true);
    release = true;
    BOOST_REQUIRE(Eventually([&] { return gate.waits >= 2; }));
    BOOST_CHECK(old_cancelled);
    BOOST_CHECK_EQUAL(m_node.addrman->Size(), 0U);
    BOOST_REQUIRE(gate.Step(1799));
    BOOST_CHECK_EQUAL(fetches.load(), 1U);
    BOOST_REQUIRE(gate.Step(501)); // Past maximum cooldown plus jitter.
    BOOST_CHECK_EQUAL(fetches.load(), 2U);
    BOOST_CHECK_EQUAL(m_node.addrman->Size(), 1U);
}

BOOST_FIXTURE_TEST_CASE(actual_connman_cooldown_wall_jump_and_resume_coalesce, TestingSetup)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    PrepareWorker(connman, m_node);
    WorkerGate gate{connman};
    std::atomic<unsigned> fetches{0};
    httpsseed::WorkerHooks hooks;
    hooks.now = [&] { return gate.Now(); };
    hooks.wait = [&] { return gate.Wait(); };
    hooks.fetch = [&](const auto& options, const auto& cancelled) { ++fetches; return LocalFetch(options, cancelled); };
    WorkerRun worker{connman, gate, hooks};
    BOOST_REQUIRE(gate.Step());
    BOOST_REQUIRE_EQUAL(fetches.load(), 1U);
    SetMockTime(NOW + 86400);
    connman.SetNetworkActive(false); connman.SetNetworkActive(true);
    BOOST_REQUIRE(gate.Step(1799));
    BOOST_CHECK_EQUAL(fetches.load(), 1U);
    BOOST_REQUIRE(gate.Step(3 * 86400));
    BOOST_CHECK_EQUAL(fetches.load(), 2U);
    BOOST_REQUIRE(gate.Step());
    BOOST_CHECK_EQUAL(fetches.load(), 2U); // Resume causes one round, not a backlog.
}

BOOST_FIXTURE_TEST_CASE(actual_connman_interrupt_joins_stalled_https, TestingSetup)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    PrepareWorker(connman, m_node);
    WorkerGate gate{connman};
    std::atomic<bool> in_fetch{false};
    httpsseed::WorkerHooks hooks;
    hooks.now = [&] { return gate.Now(); };
    hooks.wait = [&] { return gate.Wait(); };
    hooks.fetch = [&](const auto& options, const auto& cancelled) {
        in_fetch = true;
        return LocalFetch(options, cancelled, 23800, 2); // Real TLS, no headers.
    };
    WorkerRun worker{connman, gate, hooks};
    gate.Tick();
    BOOST_REQUIRE(Eventually([&] { return in_fetch.load(); }));
    std::this_thread::sleep_for(std::chrono::milliseconds{75});
    const auto start = TestClock::now();
    worker.Stop();
    BOOST_CHECK(TestClock::now() - start < std::chrono::milliseconds{500});
    BOOST_CHECK_EQUAL(m_node.addrman->Size(), 0U);
}

BOOST_FIXTURE_TEST_CASE(actual_connman_regtest_gate_stays_closed, RegTestingSetup)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    PrepareWorker(connman, m_node);
    WorkerGate gate{connman};
    std::atomic<unsigned> fetches{0};
    httpsseed::WorkerHooks hooks;
    hooks.now = [&] { return gate.Now(); };
    hooks.wait = [&] { return gate.Wait(); };
    hooks.fetch = [&](const auto&, const auto&) { ++fetches; return httpsseed::FetchResult{}; };
    WorkerRun worker{connman, gate, hooks};
    BOOST_REQUIRE(gate.Step(86400));
    BOOST_CHECK_EQUAL(fetches.load(), 0U);
    BOOST_CHECK_EQUAL(m_node.addrman->Size(), 0U);
}

void PairedWorkerRace(node::NodeContext& node, bool dns_first)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*node.connman);
    PrepareWorker(connman, node);
    // Simulate two occupied full-relay slots and a satisfied QQ target.
    for (int i = 0; i < 2; ++i) {
        auto* peer = new CNode{i, nullptr, CAddress{LookupNumeric("11.1.1.1", 15714), NODE_NETWORK},
            0, 0, CAddress{}, "", ConnectionType::OUTBOUND_FULL_RELAY, false};
        peer->fSuccessfullyConnected = true;
        connman.AddTestNode(*peer);
    }
    connman.PublishQQStatus(1, 1, false, "");
    const auto cached = LookupNumeric("1.1.1.1", 15714);
    const auto dns_ip = LookupNumeric("9.9.9.9", 15714);
    CNetAddr source;
    BOOST_REQUIRE(source.SetInternal("cached-test"));
    BOOST_REQUIRE(node.addrman->Add({CAddress{cached, NODE_NETWORK}}, source));
    DNSLookupScope lookup_scope;
    std::atomic<unsigned> base{0}, plain{0}, qq{0}, https{0};
    g_dns_lookup = [&](const std::string& host, bool) -> std::vector<CNetAddr> {
        if (host.rfind("x1000001.", 0) == 0) { ++qq; return {}; }
        if (host.rfind("x1.", 0) == 0) {
            ++base;
            return dns_first ? std::vector<CNetAddr>{} : std::vector<CNetAddr>{dns_ip};
        }
        ++plain;
        if (base > 6) return {}; // Empty DNS round must not suppress HTTPS.
        return {dns_ip};
    };
    WorkerGate dg{connman}, hg{connman};
    httpsseed::WorkerHooks dh, hh;
    dh.now = [&] { return dg.Now(); }; dh.wait = [&] { return dg.Wait(); };
    hh.now = [&] { return hg.Now(); }; hh.wait = [&] { return hg.Wait(); };
    hh.fetch = [&](const auto&, const auto&) {
        const auto attempt = ++https;
        if (!dns_first && attempt == 1) return httpsseed::FetchResult{true, "invalid", {}};
        if (!dns_first && attempt == 2) return httpsseed::FetchResult{false, {}, "fixture failure"};
        auto doc = Document();
        return httpsseed::FetchResult{true, doc.write(), {}};
    };
    connman.StartDNSForTest(dh);
    WorkerRun workers{connman, hg, hh};
    BOOST_REQUIRE(Eventually([&] { return dg.waits > 0; }));
    BOOST_REQUIRE(dg.Step(10));
    BOOST_REQUIRE(hg.Step(10));
    BOOST_CHECK_EQUAL(base.load(), 0U);
    BOOST_CHECK_EQUAL(https.load(), 0U);
    if (dns_first) {
        BOOST_REQUIRE(dg.Step(1));
        BOOST_REQUIRE(hg.Step(1));
    } else {
        BOOST_REQUIRE(hg.Step(1));
        BOOST_REQUIRE(dg.Step(1));
    }
    BOOST_CHECK_EQUAL(base.load(), 3U);
    BOOST_CHECK_EQUAL(plain.load(), dns_first ? 3U : 0U);
    BOOST_CHECK_EQUAL(qq.load(), 0U);
    BOOST_CHECK_EQUAL(https.load(), 1U);
    auto found = node.addrman->GetAddr(0, 0, std::nullopt);
    const auto hint = std::find_if(found.begin(), found.end(), [&](const auto& a) { return a == dns_ip; });
    BOOST_REQUIRE(hint != found.end());
    BOOST_CHECK_EQUAL(hint->GetPort(), 15714);
    BOOST_CHECK_EQUAL(hint->nServices, NODE_NETWORK);
    BOOST_REQUIRE(dg.Step(1799));
    BOOST_REQUIRE(hg.Step(1799));
    BOOST_CHECK_EQUAL(base.load(), 3U);
    // N1b: a rejected body (round 1) is retried after 60 s, so the failed
    // round 2 already ran inside this jump (RC5 waited a full cadence).
    BOOST_CHECK_EQUAL(https.load(), dns_first ? 1U : 2U);
    // Only DNS is due; the HTTPS clock remains unchanged.
    connman.PublishQQStatus(0, 0, false, "");
    BOOST_REQUIRE(dg.Step(501));
    BOOST_CHECK_EQUAL(base.load(), 6U);
    BOOST_CHECK_EQUAL(plain.load(), dns_first ? 6U : 0U);
    BOOST_CHECK_EQUAL(qq.load(), 3U);
    BOOST_CHECK_EQUAL(https.load(), dns_first ? 1U : 2U);
    BOOST_REQUIRE(hg.Step(501)); // Past the 120 s retry after round 2 (or the normal cadence).
    BOOST_CHECK_EQUAL(https.load(), dns_first ? 2U : 3U);
    connman.SetNetworkActive(false);
    BOOST_REQUIRE(dg.Step(2300));
    BOOST_REQUIRE(hg.Step(2300));
    BOOST_CHECK_EQUAL(base.load(), 6U);
    BOOST_CHECK_EQUAL(https.load(), dns_first ? 2U : 3U);
    connman.SetNetworkActive(true);
    BOOST_REQUIRE(hg.Step());
    BOOST_REQUIRE(dg.Step());
    BOOST_CHECK_EQUAL(base.load(), 9U);
    BOOST_CHECK_EQUAL(https.load(), dns_first ? 3U : 4U);
    workers.Stop();
    connman.ClearTestNodes();
}

BOOST_FIXTURE_TEST_CASE(actual_paired_workers_dns_first, TestingSetup) { PairedWorkerRace(m_node, true); }
BOOST_FIXTURE_TEST_CASE(actual_paired_workers_https_first, TestingSetup) { PairedWorkerRace(m_node, false); }

BOOST_FIXTURE_TEST_CASE(actual_dns_discards_response_after_network_toggle, TestingSetup)
{
    auto& connman = static_cast<ConnmanTestMsg&>(*m_node.connman);
    PrepareWorker(connman, m_node);
    const auto ip = LookupNumeric("9.9.9.9", 15714);
    DNSLookupScope lookup_scope;
    std::atomic<unsigned> queries{0};
    g_dns_lookup = [&](const std::string&, bool) -> std::vector<CNetAddr> {
        ++queries;
        connman.SetNetworkActive(false);
        connman.SetNetworkActive(true);
        return {ip};
    };
    WorkerGate dg{connman}, hg{connman};
    httpsseed::WorkerHooks dh, hh;
    dh.now = [&] { return dg.Now(); }; dh.wait = [&] { return dg.Wait(); };
    hh.now = [&] { return hg.Now(); }; hh.wait = [&] { return hg.Wait(); };
    connman.StartDNSForTest(dh);
    WorkerRun workers{connman, hg, hh};
    BOOST_REQUIRE(Eventually([&] { return dg.waits > 0; }));
    BOOST_REQUIRE(dg.Step());
    BOOST_CHECK_EQUAL(queries.load(), 1U);
    BOOST_CHECK_EQUAL(m_node.addrman->Size(), 0U);
}
BOOST_AUTO_TEST_SUITE_END()
