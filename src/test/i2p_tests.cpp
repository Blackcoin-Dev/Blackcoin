// Copyright (c) 2021-2022 Blackcoin Core Developers
// Copyright (c) 2021-2022 Blackcoin More Developers
// Copyright (c) 2021-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <common/args.h>
#include <i2p.h>
#include <logging.h>
#include <netaddress.h>
#include <test/util/logging.h>
#include <test/util/net.h>
#include <test/util/setup_common.h>
#include <util/readwritefile.h>
#include <util/threadinterrupt.h>

#include <boost/test/unit_test.hpp>

#include <memory>
#include <string>
#include <string_view>

/// Save the log level and the value of CreateSock and restore them when the test ends.
class EnvTestingSetup : public BasicTestingSetup
{
public:
    explicit EnvTestingSetup(const ChainType chainType = ChainType::MAIN,
                             const std::vector<const char*>& extra_args = {})
        : BasicTestingSetup{chainType, extra_args},
          m_prev_log_level{LogInstance().LogLevel()},
          m_create_sock_orig{CreateSock}
    {
        LogInstance().SetLogLevel(BCLog::Level::Trace);
    }

    ~EnvTestingSetup()
    {
        CreateSock = m_create_sock_orig;
        LogInstance().SetLogLevel(m_prev_log_level);
    }

private:
    const BCLog::Level m_prev_log_level;
    const std::function<std::unique_ptr<Sock>(const CService&)> m_create_sock_orig;
};

namespace {
class SamConnectSock : public StaticContentsSock
{
public:
    SamConnectSock(const std::string& replies, CThreadInterrupt& interrupt, std::string& stream_request, bool partial_stream)
        : StaticContentsSock{replies}, m_interrupt{interrupt}, m_stream_request{stream_request}, m_partial_stream{partial_stream}
    {
    }

    ssize_t Send(const void* data, size_t size, int flags) const override
    {
        const std::string_view message{static_cast<const char*>(data), size};
        if (message.substr(0, 15) != "STREAM CONNECT ") return StaticContentsSock::Send(data, size, flags);
        if (m_partial_stream) {
            --size;
            m_interrupt();
        }
        m_stream_request.assign(message.substr(0, size));
        return size;
    }

private:
    CThreadInterrupt& m_interrupt;
    std::string& m_stream_request;
    const bool m_partial_stream;
};
} // namespace

BOOST_FIXTURE_TEST_SUITE(i2p_tests, EnvTestingSetup)

BOOST_AUTO_TEST_CASE(connect_destination_attempt_boundary)
{
    const std::string hello{"HELLO REPLY RESULT=OK VERSION=3.1\n"};
    const std::string naming{"NAMING REPLY RESULT=OK VALUE=mock-destination\n"};
    CNetAddr destination;
    BOOST_REQUIRE(destination.SetSpecial(std::string(52, 'a') + ".b32.i2p"));
    const CService proxy{in6_addr(IN6ADDR_LOOPBACK_INIT), 7656};

    struct Scenario {
        const char* name;
        std::string replies;
        bool success{false};
        bool attempted{false};
        bool proxy_error{true};
        bool partial_stream{false};
        uint16_t port{I2P_SAM31_PORT};
    };
    for (const auto& scenario : std::vector<Scenario>{
             {.name = "invalid port", .replies = "", .proxy_error = false, .port = 1},
             {.name = "HELLO failure", .replies = "HELLO REPLY RESULT=I2P_ERROR\n"},
             {.name = "NAMING failure", .replies = hello + "NAMING REPLY RESULT=KEY_NOT_FOUND\n"},
             {.name = "partial STREAM CONNECT", .replies = hello + naming, .partial_stream = true},
             {.name = "destination refusal", .replies = hello + naming + "STREAM STATUS RESULT=CANT_REACH_PEER\n", .attempted = true, .proxy_error = false},
             {.name = "destination timeout", .replies = hello + naming + "STREAM STATUS RESULT=TIMEOUT\n", .attempted = true, .proxy_error = false},
             {.name = "proxy error after send", .replies = hello + naming + "STREAM STATUS RESULT=I2P_ERROR\n", .attempted = true},
             {.name = "EOF after send", .replies = hello + naming, .attempted = true},
             {.name = "success", .replies = hello + naming + "STREAM STATUS RESULT=OK\n", .success = true, .attempted = true},
         }) {
        BOOST_TEST_CONTEXT(scenario.name)
        {
            unsigned sockets{0};
            std::string stream_request;
            CThreadInterrupt interrupt;
            CreateSock = [&](const CService& address) -> std::unique_ptr<Sock> {
                BOOST_CHECK(address == proxy);
                if (++sockets == 1) {
                    // A synthetic 387-byte destination with an empty certificate.
                    return std::make_unique<StaticContentsSock>(hello + "SESSION STATUS RESULT=OK DESTINATION=" + std::string(516, 'A') + "\n");
                }
                return std::make_unique<SamConnectSock>(scenario.replies, interrupt, stream_request, scenario.partial_stream);
            };
            i2p::sam::Session session(proxy, &interrupt);
            i2p::Connection conn;
            bool proxy_error{false};
            bool attempted{true};
            BOOST_CHECK_EQUAL(session.Connect(CService{destination, scenario.port}, conn, proxy_error, &attempted), scenario.success);
            BOOST_CHECK_EQUAL(attempted, scenario.attempted);
            BOOST_CHECK_EQUAL(!stream_request.empty() && stream_request.back() == '\n', scenario.attempted);
            BOOST_CHECK_EQUAL(static_cast<bool>(conn.sock), scenario.success);
            BOOST_CHECK_EQUAL(sockets, scenario.port == I2P_SAM31_PORT ? 2U : 0U);
            if (scenario.partial_stream) BOOST_CHECK(!stream_request.empty());
            if (!scenario.success) BOOST_CHECK_EQUAL(proxy_error, scenario.proxy_error);
        }
    }
}

BOOST_AUTO_TEST_CASE(unlimited_recv)
{
    // Mock CreateSock() to create MockSock.
    CreateSock = [](const CService&) {
        return std::make_unique<StaticContentsSock>(std::string(i2p::sam::MAX_MSG_SIZE + 1, 'a'));
    };

    CThreadInterrupt interrupt;
    i2p::sam::Session session(gArgs.GetDataDirNet() / "test_i2p_private_key", CService{}, &interrupt);

    {
        ASSERT_DEBUG_LOG("Creating persistent SAM session");
        ASSERT_DEBUG_LOG("too many bytes without a terminator");

        i2p::Connection conn;
        bool proxy_error;
        BOOST_REQUIRE(!session.Connect(CService{}, conn, proxy_error));
    }
}

BOOST_AUTO_TEST_CASE(listen_ok_accept_fail)
{
    size_t num_sockets{0};
    CreateSock = [&num_sockets](const CService&) {
        // clang-format off
        ++num_sockets;
        // First socket is the control socket for creating the session.
        if (num_sockets == 1) {
            return std::make_unique<StaticContentsSock>(
                // reply to HELLO
                "HELLO REPLY RESULT=OK VERSION=3.1\n"
                // reply to DEST GENERATE
                "DEST REPLY PUB=WnGOLXRBqHQhdVjFlWqRxJwz9hxx~2~wGc2Vplta1KhacY4tdEGodCF1WMWVapHEnDP2HHH~b~AZzZWmW1rUqFpxji10Qah0IXVYxZVqkcScM~Yccf9v8BnNlaZbWtSoWnGOLXRBqHQhdVjFlWqRxJwz9hxx~2~wGc2Vplta1KhacY4tdEGodCF1WMWVapHEnDP2HHH~b~AZzZWmW1rUqFpxji10Qah0IXVYxZVqkcScM~Yccf9v8BnNlaZbWtSoWnGOLXRBqHQhdVjFlWqRxJwz9hxx~2~wGc2Vplta1KhacY4tdEGodCF1WMWVapHEnDP2HHH~b~AZzZWmW1rUqFpxji10Qah0IXVYxZVqkcScM~Yccf9v8BnNlaZbWtSoWnGOLXRBqHQhdVjFlWqRxJwz9hxx~2~wGc2Vplta1KhacY4tdEGodCF1WMWVapHEnDP2HHH~b~AZzZWmW1rUqLE4SD-yjT48UNI7qiTUfIPiDitCoiTTz2cr4QGfw89rBQAEAAcAAA== PRIV=WnGOLXRBqHQhdVjFlWqRxJwz9hxx~2~wGc2Vplta1KhacY4tdEGodCF1WMWVapHEnDP2HHH~b~AZzZWmW1rUqFpxji10Qah0IXVYxZVqkcScM~Yccf9v8BnNlaZbWtSoWnGOLXRBqHQhdVjFlWqRxJwz9hxx~2~wGc2Vplta1KhacY4tdEGodCF1WMWVapHEnDP2HHH~b~AZzZWmW1rUqFpxji10Qah0IXVYxZVqkcScM~Yccf9v8BnNlaZbWtSoWnGOLXRBqHQhdVjFlWqRxJwz9hxx~2~wGc2Vplta1KhacY4tdEGodCF1WMWVapHEnDP2HHH~b~AZzZWmW1rUqFpxji10Qah0IXVYxZVqkcScM~Yccf9v8BnNlaZbWtSoWnGOLXRBqHQhdVjFlWqRxJwz9hxx~2~wGc2Vplta1KhacY4tdEGodCF1WMWVapHEnDP2HHH~b~AZzZWmW1rUqLE4SD-yjT48UNI7qiTUfIPiDitCoiTTz2cr4QGfw89rBQAEAAcAAOvuCIKTyv5f~1QgGq7XQl-IqBULTB5WzB3gw5yGPtd1p0AeoADrq1ccZggLPQ4ZLUsGK-HVw373rcTfvxrcuwenqVjiN4tbbYLWtP7xXGWj6fM6HyORhU63GphrjEePpMUHDHXd3o7pWGM-ieVVQSK~1MzF9P93pQWI3Do52EeNAayz4HbpPjNhVBzG1hUEFwznfPmUZBPuaOR4-uBm1NEWEuONlNOCctE4-U0Ukh94z-Qb55U5vXjR5G4apmBblr68t6Wm1TKlzpgFHzSqLryh3stWqrOKY1H0z9eZ2z1EkHFOpD5LyF6nf51e-lV7HLMl44TYzoEHK8RRVodtLcW9lacVdBpv~tOzlZERIiDziZODPETENZMz5oy9DQ7UUw==\n"
                // reply to SESSION CREATE
                "SESSION STATUS RESULT=OK\n"
                // dummy to avoid reporting EOF on the socket
                "a"
            );
        }
        // Subsequent sockets are for recreating the session or for listening and accepting incoming connections.
        if (num_sockets % 2 == 0) {
            // Replies to Listen() and Accept()
            return std::make_unique<StaticContentsSock>(
                // reply to HELLO
                "HELLO REPLY RESULT=OK VERSION=3.1\n"
                // reply to STREAM ACCEPT
                "STREAM STATUS RESULT=OK\n"
                // continued reply to STREAM ACCEPT, violating the protocol described at
                // https://geti2p.net/en/docs/api/samv3#Accept%20Response
                // should be base64, something like
                // "IchV608baDoXbqzQKSqFDmTXPVgoDbPAhZJvNRXXxi4hyFXrTxtoOhdurNApKoUOZNc9WCgNs8CFkm81FdfGLiHIVetPG2g6F26s0CkqhQ5k1z1YKA2zwIWSbzUV18YuIchV608baDoXbqzQKSqFDmTXPVgoDbPAhZJvNRXXxi4hyFXrTxtoOhdurNApKoUOZNc9WCgNs8CFkm81FdfGLiHIVetPG2g6F26s0CkqhQ5k1z1YKA2zwIWSbzUV18YuIchV608baDoXbqzQKSqFDmTXPVgoDbPAhZJvNRXXxi4hyFXrTxtoOhdurNApKoUOZNc9WCgNs8CFkm81FdfGLiHIVetPG2g6F26s0CkqhQ5k1z1YKA2zwIWSbzUV18YuIchV608baDoXbqzQKSqFDmTXPVgoDbPAhZJvNRXXxi4hyFXrTxtoOhdurNApKoUOZNc9WCgNs8CFkm81FdfGLlSreVaCuCS5sdb-8ToWULWP7kt~lRPDeUNxQMq3cRSBBQAEAAcAAA==\n"
                "STREAM STATUS RESULT=I2P_ERROR MESSAGE=\"Session was closed\"\n"
            );
        } else {
            // Another control socket, but without creating a destination (it is cached in the session).
            return std::make_unique<StaticContentsSock>(
                // reply to HELLO
                "HELLO REPLY RESULT=OK VERSION=3.1\n"
                // reply to SESSION CREATE
                "SESSION STATUS RESULT=OK\n"
                // dummy to avoid reporting EOF on the socket
                "a"
            );
        }
        // clang-format on
    };

    CThreadInterrupt interrupt;
    i2p::sam::Session session(gArgs.GetDataDirNet() / "test_i2p_private_key",
                              CService{in6_addr(IN6ADDR_LOOPBACK_INIT), /*port=*/7656},
                              &interrupt);

    i2p::Connection conn;
    for (size_t i = 0; i < 5; ++i) {
        ASSERT_DEBUG_LOG("Creating persistent SAM session");
        ASSERT_DEBUG_LOG("Persistent SAM session" /* ... created */);
        ASSERT_DEBUG_LOG("Error accepting");
        ASSERT_DEBUG_LOG("Destroying SAM session");
        BOOST_REQUIRE(session.Listen(conn));
        BOOST_REQUIRE(!session.Accept(conn));
    }
}

BOOST_AUTO_TEST_CASE(damaged_private_key)
{
    const auto CreateSockOrig = CreateSock;

    CreateSock = [](const CService&) {
        return std::make_unique<StaticContentsSock>("HELLO REPLY RESULT=OK VERSION=3.1\n"
                                                    "SESSION STATUS RESULT=OK DESTINATION=\n");
    };

    const auto i2p_private_key_file = m_args.GetDataDirNet() / "test_i2p_private_key_damaged";

    for (const auto& [file_contents, expected_error] : std::vector<std::tuple<std::string, std::string>>{
             {"", "The private key is too short (0 < 387)"},

             {"abcd", "The private key is too short (4 < 387)"},

             {std::string(386, '\0'), "The private key is too short (386 < 387)"},

             {std::string(385, '\0') + '\0' + '\1',
              "Certificate length (1) designates that the private key should be 388 bytes, but it is only "
              "387 bytes"},

             {std::string(385, '\0') + '\0' + '\5' + "abcd",
              "Certificate length (5) designates that the private key should be 392 bytes, but it is only "
              "391 bytes"}}) {
        BOOST_REQUIRE(WriteBinaryFile(i2p_private_key_file, file_contents));

        CThreadInterrupt interrupt;
        i2p::sam::Session session(i2p_private_key_file, CService{}, &interrupt);

        {
            ASSERT_DEBUG_LOG("Creating persistent SAM session");
            ASSERT_DEBUG_LOG(expected_error);

            i2p::Connection conn;
            bool proxy_error;
            BOOST_CHECK(!session.Connect(CService{}, conn, proxy_error));
        }
    }

    CreateSock = CreateSockOrig;
}

BOOST_AUTO_TEST_CASE(session_error_redacts_private_key)
{
    CreateSock = [](const CService&) {
        return std::make_unique<StaticContentsSock>(
            "HELLO REPLY RESULT=OK VERSION=3.1\n"
            "SESSION STATUS RESULT=I2P_ERROR\n");
    };
    const auto key_file = m_args.GetDataDirNet() / "test_i2p_redaction";
    BOOST_REQUIRE(WriteBinaryFile(key_file, "synthetic-private-key"));

    for (const bool listen : {true, false}) {
        CThreadInterrupt interrupt;
        i2p::sam::Session session(key_file, CService{}, &interrupt);
        ASSERT_DEBUG_LOG("Unexpected reply to \"SESSION CREATE ...\"");
        DebugLogHelper no_private_key{"DESTINATION=", [](const std::string* line) {
            BOOST_CHECK(line == nullptr);
            return false;
        }};
        i2p::Connection conn;
        bool proxy_error;
        BOOST_CHECK(!(listen ? session.Listen(conn) : session.Connect(CService{}, conn, proxy_error)));
    }
}

BOOST_AUTO_TEST_SUITE_END()
