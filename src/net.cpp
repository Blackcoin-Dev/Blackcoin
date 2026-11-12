// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-2022 Blackcoin Core Developers
// Copyright (c) 2009-2022 Blackcoin More Developers
// Copyright (c) 2009-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#if defined(HAVE_CONFIG_H)
#include <config/bitcoin-config.h>
#endif

#include <net.h>

#include <addrdb.h>
#include <addrman.h>
#include <banman.h>
#include <clientversion.h>
#include <common/args.h>
#include <compat/compat.h>
#include <consensus/consensus.h>
#include <crypto/sha256.h>
#include <i2p.h>
#include <https_seed_client.h>
#include <net_https_seed.h>
#include <logging.h>
#include <memusage.h>
#include <net_permissions.h>
#include <netaddress.h>
#include <netbase.h>
#include <node/eviction.h>
#include <node/interface_ui.h>
#include <protocol.h>
#include <random.h>
#include <scheduler.h>
#include <util/fs.h>
#include <util/sock.h>
#include <util/strencodings.h>
#include <util/thread.h>
#include <util/threadinterrupt.h>
#include <util/trace.h>
#include <util/translation.h>
#include <util/vector.h>

#ifdef WIN32
#include <string.h>
#endif

#if HAVE_DECL_GETIFADDRS && HAVE_DECL_FREEIFADDRS
#include <ifaddrs.h>
#endif

#include <algorithm>
#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <unordered_map>

#include <math.h>

/** Maximum number of block-relay-only anchor connections */
static constexpr size_t MAX_BLOCK_RELAY_ONLY_ANCHORS = 2;
static_assert (MAX_BLOCK_RELAY_ONLY_ANCHORS <= static_cast<size_t>(MAX_BLOCK_RELAY_ONLY_CONNECTIONS), "MAX_BLOCK_RELAY_ONLY_ANCHORS must not exceed MAX_BLOCK_RELAY_ONLY_CONNECTIONS.");
/** Anchor IP address database file name */
const char* const ANCHORS_DATABASE_FILENAME = "anchors.dat";

// How often to dump addresses to peers.dat
static constexpr std::chrono::minutes DUMP_PEERS_INTERVAL{15};

/** Number of DNS seeds to query when the number of connections is low. */
static constexpr int DNSSEEDS_TO_QUERY_AT_ONCE = 3;

/** How long to delay before querying DNS seeds
 *
 * If we have more than THRESHOLD entries in addrman, then it's likely
 * that we got those addresses from having previously connected to the P2P
 * network, and that we'll be able to successfully reconnect to the P2P
 * network via contacting one of them. So if that's the case, spend a
 * little longer trying to connect to known peers before querying the
 * DNS seeds.
 */
static constexpr std::chrono::seconds DNSSEEDS_DELAY_FEW_PEERS{11};
static constexpr std::chrono::minutes DNSSEEDS_DELAY_MANY_PEERS{5};
static constexpr int DNSSEEDS_DELAY_PEER_THRESHOLD = 1000; // "many" vs "few" peers

/** The default timeframe for -maxuploadtarget. 1 day. */
static constexpr std::chrono::seconds MAX_UPLOAD_TIMEFRAME{60 * 60 * 24};

// A random time period (0 to 1 seconds) is added to feeler connections to prevent synchronization.
static constexpr auto FEELER_SLEEP_WINDOW{1s};

/** Frequency to attempt extra connections to reachable networks we're not connected to yet **/
static constexpr auto EXTRA_NETWORK_PEER_INTERVAL{5min};

/** Used to pass flags to the Bind() function */
enum BindFlags {
    BF_NONE         = 0,
    BF_REPORT_ERROR = (1U << 0),
    /**
     * Do not call AddLocal() for our special addresses, e.g., for incoming
     * Tor connections, to prevent gossiping them over the network.
     */
    BF_DONT_ADVERTISE = (1U << 1),
};

// The set of sockets cannot be modified while waiting
// The sleep time needs to be small to avoid new sockets stalling
static const uint64_t SELECT_TIMEOUT_MILLISECONDS = 50;

const std::string NET_MESSAGE_TYPE_OTHER = "*other*";

static const uint64_t RANDOMIZER_ID_NETGROUP = 0x6c0edd8036ef4036ULL; // SHA256("netgroup")[0:8]
static const uint64_t RANDOMIZER_ID_LOCALHOSTNONCE = 0xd93e69e2bbfa5735ULL; // SHA256("localhostnonce")[0:8]
static const uint64_t RANDOMIZER_ID_ADDRCACHE = 0x1cf2e4ddd306dda9ULL; // SHA256("addrcache")[0:8]
//
// Global state variables
//
bool fDiscover = true;
bool fListen = true;
GlobalMutex g_maplocalhost_mutex;
std::map<CNetAddr, LocalServiceInfo> mapLocalHost GUARDED_BY(g_maplocalhost_mutex);
std::string strSubVersion;

size_t CSerializedNetMsg::GetMemoryUsage() const noexcept
{
    // Don't count the dynamic memory used for the m_type string, by assuming it fits in the
    // "small string" optimization area (which stores data inside the object itself, up to some
    // size; 15 bytes in modern libstdc++).
    return sizeof(*this) + memusage::DynamicUsage(data);
}

void CConnman::AddAddrFetch(const std::string& strDest)
{
    LOCK(m_addr_fetches_mutex);
    // Deduplicate names without changing an absolute name into a resolver
    // search-list name when the queued destination is actually used.
    const auto canonical = [](const std::string& input) {
        std::string result = ToLower(input);
        if (!result.empty() && result.back() == '.') result.pop_back();
        return result;
    };
    const std::string destination = canonical(strDest);
    if (m_addr_fetches.size() >= qq::MAX_ADDR_FETCHES ||
        std::any_of(m_addr_fetches.begin(), m_addr_fetches.end(), [&](const std::string& queued) {
            return canonical(queued) == destination;
        })) return;
    m_addr_fetches.push_back(strDest);
}

uint16_t GetListenPort()
{
    // If -bind= is provided with ":port" part, use that (first one if multiple are provided).
    for (const std::string& bind_arg : gArgs.GetArgs("-bind")) {
        constexpr uint16_t dummy_port = 0;

        const std::optional<CService> bind_addr{Lookup(bind_arg, dummy_port, /*fAllowLookup=*/false)};
        if (bind_addr.has_value() && bind_addr->GetPort() != dummy_port) return bind_addr->GetPort();
    }

    // Otherwise, if -whitebind= without NetPermissionFlags::NoBan is provided, use that
    // (-whitebind= is required to have ":port").
    for (const std::string& whitebind_arg : gArgs.GetArgs("-whitebind")) {
        NetWhitebindPermissions whitebind;
        bilingual_str error;
        if (NetWhitebindPermissions::TryParse(whitebind_arg, whitebind, error)) {
            if (!NetPermissions::HasFlag(whitebind.m_flags, NetPermissionFlags::NoBan)) {
                return whitebind.m_service.GetPort();
            }
        }
    }

    // Otherwise, if -port= is provided, use that. Otherwise use the default port.
    return static_cast<uint16_t>(gArgs.GetIntArg("-port", Params().GetDefaultPort()));
}

// Determine the "best" local address for a particular peer.
[[nodiscard]] static std::optional<CService> GetLocal(const CNode& peer)
{
    if (!fListen) return std::nullopt;

    std::optional<CService> addr;
    int nBestScore = -1;
    int nBestReachability = -1;
    {
        LOCK(g_maplocalhost_mutex);
        for (const auto& [local_addr, local_service_info] : mapLocalHost) {
            // For privacy reasons, don't advertise our privacy-network address
            // to other networks and don't advertise our other-network address
            // to privacy networks.
            if (local_addr.GetNetwork() != peer.ConnectedThroughNetwork()
                && (local_addr.IsPrivacyNet() || peer.IsConnectedThroughPrivacyNet())) {
                continue;
            }
            const int nScore{local_service_info.nScore};
            const int nReachability{local_addr.GetReachabilityFrom(peer.addr)};
            if (nReachability > nBestReachability || (nReachability == nBestReachability && nScore > nBestScore)) {
                addr.emplace(CService{local_addr, local_service_info.nPort});
                nBestReachability = nReachability;
                nBestScore = nScore;
            }
        }
    }
    return addr;
}

//! Convert the serialized seeds into usable address objects.
static std::vector<CAddress> ConvertSeeds(const std::vector<uint8_t> &vSeedsIn)
{
    // It'll only connect to one or two seed nodes because once it connects,
    // it'll get a pile of addresses with newer timestamps.
    // Seed nodes are given a random 'last seen time' of between one and two
    // weeks ago.
    const auto one_week{7 * 24h};
    std::vector<CAddress> vSeedsOut;
    FastRandomContext rng;
    DataStream underlying_stream{vSeedsIn};
    ParamsStream s{CAddress::V2_NETWORK, underlying_stream};
    while (!s.eof()) {
        CService endpoint;
        s >> endpoint;
        CAddress addr{endpoint, GetDesirableServiceFlags(NODE_NONE)};
        addr.nTime = rng.rand_uniform_delay(Now<NodeSeconds>() - one_week, -one_week);
        LogPrint(BCLog::NET, "Added hardcoded seed: %s\n", addr.ToStringAddrPort());
        vSeedsOut.push_back(addr);
    }
    return vSeedsOut;
}

// Determine the "best" local address for a particular peer.
// If none, return the unroutable 0.0.0.0 but filled in with
// the normal parameters, since the IP may be changed to a useful
// one by discovery.
CService GetLocalAddress(const CNode& peer)
{
    return GetLocal(peer).value_or(CService{CNetAddr(), GetListenPort()});
}

static int GetnScore(const CService& addr)
{
    LOCK(g_maplocalhost_mutex);
    const auto it = mapLocalHost.find(addr);
    return (it != mapLocalHost.end()) ? it->second.nScore : 0;
}

// Is our peer's addrLocal potentially useful as an external IP source?
[[nodiscard]] static bool IsPeerAddrLocalGood(CNode *pnode)
{
    CService addrLocal = pnode->GetAddrLocal();
    return fDiscover && pnode->addr.IsRoutable() && addrLocal.IsRoutable() &&
           g_reachable_nets.Contains(addrLocal);
}

std::optional<CService> GetLocalAddrForPeer(CNode& node)
{
    CService addrLocal{GetLocalAddress(node)};
    if (gArgs.GetBoolArg("-addrmantest", false)) {
        // use IPv4 loopback during addrmantest
        addrLocal = CService(LookupNumeric("127.0.0.1", GetListenPort()));
    }
    // If discovery is enabled, sometimes give our peer the address it
    // tells us that it sees us as in case it has a better idea of our
    // address than we do.
    FastRandomContext rng;
    if (IsPeerAddrLocalGood(&node) && (!addrLocal.IsRoutable() ||
         rng.randbits((GetnScore(addrLocal) > LOCAL_MANUAL) ? 3 : 1) == 0))
    {
        if (node.IsInboundConn()) {
            // For inbound connections, assume both the address and the port
            // as seen from the peer.
            addrLocal = CService{node.GetAddrLocal()};
        } else {
            // For outbound connections, assume just the address as seen from
            // the peer and leave the port in `addrLocal` as returned by
            // `GetLocalAddress()` above. The peer has no way to observe our
            // listening port when we have initiated the connection.
            addrLocal.SetIP(node.GetAddrLocal());
        }
    }
    if (addrLocal.IsRoutable() || gArgs.GetBoolArg("-addrmantest", false))
    {
        LogPrint(BCLog::NET, "Advertising address %s to peer=%d\n", addrLocal.ToStringAddrPort(), node.GetId());
        return addrLocal;
    }
    // Address is unroutable. Don't advertise.
    return std::nullopt;
}

// learn a new local address
bool AddLocal(const CService& addr_, int nScore)
{
    CService addr{MaybeFlipIPv6toCJDNS(addr_)};

    if (!addr.IsRoutable())
        return false;

    if (!fDiscover && nScore < LOCAL_MANUAL)
        return false;

    if (!g_reachable_nets.Contains(addr))
        return false;

    LogPrintf("AddLocal(%s,%i)\n", addr.ToStringAddrPort(), nScore);

    {
        LOCK(g_maplocalhost_mutex);
        const auto [it, is_newly_added] = mapLocalHost.emplace(addr, LocalServiceInfo());
        LocalServiceInfo &info = it->second;
        if (is_newly_added || nScore >= info.nScore) {
            info.nScore = nScore + (is_newly_added ? 0 : 1);
            info.nPort = addr.GetPort();
        }
    }

    return true;
}

bool AddLocal(const CNetAddr &addr, int nScore)
{
    return AddLocal(CService(addr, GetListenPort()), nScore);
}

void RemoveLocal(const CService& addr)
{
    LOCK(g_maplocalhost_mutex);
    LogPrintf("RemoveLocal(%s)\n", addr.ToStringAddrPort());
    mapLocalHost.erase(addr);
}

/** vote for a local address */
bool SeenLocal(const CService& addr)
{
    LOCK(g_maplocalhost_mutex);
    const auto it = mapLocalHost.find(addr);
    if (it == mapLocalHost.end()) return false;
    ++it->second.nScore;
    return true;
}


/** check whether a given address is potentially local */
bool IsLocal(const CService& addr)
{
    LOCK(g_maplocalhost_mutex);
    return mapLocalHost.count(addr) > 0;
}

CNode* CConnman::FindNode(const CNetAddr& ip)
{
    LOCK(m_nodes_mutex);
    for (CNode* pnode : m_nodes) {
      if (static_cast<CNetAddr>(pnode->addr) == ip) {
            return pnode;
        }
    }
    return nullptr;
}

CNode* CConnman::FindNode(const std::string& addrName)
{
    LOCK(m_nodes_mutex);
    for (CNode* pnode : m_nodes) {
        if (pnode->m_addr_name == addrName) {
            return pnode;
        }
    }
    return nullptr;
}

CNode* CConnman::FindNode(const CService& addr)
{
    LOCK(m_nodes_mutex);
    for (CNode* pnode : m_nodes) {
        if (static_cast<CService>(pnode->addr) == addr) {
            return pnode;
        }
    }
    return nullptr;
}

bool CConnman::AlreadyConnectedToAddress(const CAddress& addr)
{
    return FindNode(static_cast<CNetAddr>(addr)) || FindNode(addr.ToStringAddrPort());
}

bool CConnman::CheckIncomingNonce(uint64_t nonce)
{
    LOCK(m_nodes_mutex);
    for (const CNode* pnode : m_nodes) {
        if (!pnode->fSuccessfullyConnected && !pnode->IsInboundConn() && pnode->GetLocalNonce() == nonce)
            return false;
    }
    return true;
}

/** Get the bind address for a socket as CAddress */
static CAddress GetBindAddress(const Sock& sock)
{
    CAddress addr_bind;
    struct sockaddr_storage sockaddr_bind;
    socklen_t sockaddr_bind_len = sizeof(sockaddr_bind);
    if (!sock.GetSockName((struct sockaddr*)&sockaddr_bind, &sockaddr_bind_len)) {
        addr_bind.SetSockAddr((const struct sockaddr*)&sockaddr_bind);
    } else {
        LogPrintLevel(BCLog::NET, BCLog::Level::Warning, "getsockname failed\n");
    }
    return addr_bind;
}

CNode* CConnman::ConnectNode(CAddress addrConnect, const char *pszDest, bool fCountFailure, ConnectionType conn_type, bool use_v2transport, bool& attempted)
{
    attempted = false;
    AssertLockNotHeld(m_unused_i2p_sessions_mutex);
    assert(conn_type != ConnectionType::INBOUND);

    if (pszDest == nullptr) {
        if (IsLocal(addrConnect))
            return nullptr;

        // Look for an existing connection
        CNode* pnode = FindNode(static_cast<CService>(addrConnect));
        if (pnode)
        {
            LogPrintf("Failed to open new connection, already connected\n");
            return nullptr;
        }
    }

    LogPrintLevel(BCLog::NET, BCLog::Level::Debug, "trying %s connection %s lastseen=%.1fhrs\n",
        use_v2transport ? "v2" : "v1",
        pszDest ? pszDest : addrConnect.ToStringAddrPort(),
        Ticks<HoursDouble>(pszDest ? 0h : Now<NodeSeconds>() - addrConnect.nTime));

    // Resolve
    const uint16_t default_port{pszDest != nullptr ? GetDefaultPort(pszDest) :
                                                     m_params.GetDefaultPort()};
    if (pszDest) {
        const std::vector<CService> resolved{Lookup(pszDest, default_port, fNameLookup && !HaveNameProxy(), 256)};
        if (!resolved.empty()) {
            const CService& rnd{resolved[GetRand(resolved.size())]};
            addrConnect = CAddress{MaybeFlipIPv6toCJDNS(rnd), NODE_NONE};
            if (!addrConnect.IsValid()) {
                LogPrint(BCLog::NET, "Resolver returned invalid address %s for %s\n", addrConnect.ToStringAddrPort(), pszDest);
                return nullptr;
            }
            // It is possible that we already have a connection to the IP/port pszDest resolved to.
            // In that case, drop the connection that was just created.
            LOCK(m_nodes_mutex);
            CNode* pnode = FindNode(static_cast<CService>(addrConnect));
            if (pnode) {
                LogPrintf("Failed to open new connection, already connected\n");
                return nullptr;
            }
        }
    }

    // Connect
    bool connected = false;
    std::unique_ptr<Sock> sock;
    Proxy proxy;
    CAddress addr_bind;
    assert(!addr_bind.IsValid());
    std::unique_ptr<i2p::sam::Session> i2p_transient_session;

    if (addrConnect.IsValid()) {
        const bool use_proxy{GetProxy(addrConnect.GetNetwork(), proxy)};
        bool proxyConnectionFailed = false;

        if (addrConnect.IsI2P() && use_proxy) {
            i2p::Connection conn;

            if (m_i2p_sam_session) {
                connected = m_i2p_sam_session->Connect(addrConnect, conn, proxyConnectionFailed, &attempted);
            } else {
                {
                    LOCK(m_unused_i2p_sessions_mutex);
                    if (m_unused_i2p_sessions.empty()) {
                        i2p_transient_session =
                            std::make_unique<i2p::sam::Session>(proxy.proxy, &interruptNet);
                    } else {
                        i2p_transient_session.swap(m_unused_i2p_sessions.front());
                        m_unused_i2p_sessions.pop();
                    }
                }
                connected = i2p_transient_session->Connect(addrConnect, conn, proxyConnectionFailed, &attempted);
                if (!connected) {
                    LOCK(m_unused_i2p_sessions_mutex);
                    if (m_unused_i2p_sessions.size() < MAX_UNUSED_I2P_SESSIONS_SIZE) {
                        m_unused_i2p_sessions.emplace(i2p_transient_session.release());
                    }
                }
            }

            if (connected) {
                sock = std::move(conn.sock);
                addr_bind = CAddress{conn.me, NODE_NONE};
            }
        } else if (use_proxy) {
            sock = CreateSock(proxy.proxy);
            if (!sock) {
                return nullptr;
            }
            connected = ConnectThroughProxy(proxy, addrConnect.ToStringAddr(), addrConnect.GetPort(),
                                            *sock, nConnectTimeout, proxyConnectionFailed, &attempted);
        } else {
            // no proxy needed (none set for target network)
            sock = CreateSock(addrConnect);
            if (!sock) {
                return nullptr;
            }
            connected = ConnectSocketDirectly(addrConnect, *sock, nConnectTimeout,
                                              conn_type == ConnectionType::MANUAL, &attempted);
        }
        // Keep addrman's proxy-failure accounting separate from the transport's
        // report that a destination request was sent.
        if (!proxyConnectionFailed) {
            addrman.Attempt(addrConnect, fCountFailure);
        }
    } else if (pszDest && GetNameProxy(proxy)) {
        sock = CreateSock(proxy.proxy);
        if (!sock) {
            return nullptr;
        }
        std::string host;
        uint16_t port{default_port};
        SplitHostPort(std::string(pszDest), port, host);
        bool proxyConnectionFailed;
        connected = ConnectThroughProxy(proxy, host, port, *sock, nConnectTimeout,
                                        proxyConnectionFailed);
    }
    if (!connected) {
        return nullptr;
    }

    // Add node
    NodeId id = GetNewNodeId();
    uint64_t nonce = GetDeterministicRandomizer(RANDOMIZER_ID_LOCALHOSTNONCE).Write(id).Finalize();
    if (!addr_bind.IsValid()) {
        addr_bind = GetBindAddress(*sock);
    }
    CNode* pnode = new CNode(id,
                             std::move(sock),
                             addrConnect,
                             CalculateKeyedNetGroup(addrConnect),
                             nonce,
                             addr_bind,
                             pszDest ? pszDest : "",
                             conn_type,
                             /*inbound_onion=*/false,
                             CNodeOptions{
                                 .i2p_sam_session = std::move(i2p_transient_session),
                                 .recv_flood_size = nReceiveFloodSize,
                                 .use_v2transport = use_v2transport,
                             });
    pnode->AddRef();

    // We're making a new connection, harvest entropy from the time (and our peer count)
    RandAddEvent((uint32_t)id);

    return pnode;
}

void CNode::CloseSocketDisconnect()
{
    fDisconnect = true;
    LOCK(m_sock_mutex);
    if (m_sock) {
        LogPrint(BCLog::NET, "disconnecting peer=%d\n", id);
        m_sock.reset();
    }
    m_i2p_sam_session.reset();
}

void CConnman::AddWhitelistPermissionFlags(NetPermissionFlags& flags, const CNetAddr &addr) const {
    for (const auto& subnet : vWhitelistedRange) {
        if (subnet.m_subnet.Match(addr)) NetPermissions::AddFlag(flags, subnet.m_flags);
    }
}

CService CNode::GetAddrLocal() const
{
    AssertLockNotHeld(m_addr_local_mutex);
    LOCK(m_addr_local_mutex);
    return addrLocal;
}

void CNode::SetAddrLocal(const CService& addrLocalIn) {
    AssertLockNotHeld(m_addr_local_mutex);
    LOCK(m_addr_local_mutex);
    if (addrLocal.IsValid()) {
        error("Addr local already set for node: %i. Refusing to change from %s to %s", id, addrLocal.ToStringAddrPort(), addrLocalIn.ToStringAddrPort());
    } else {
        addrLocal = addrLocalIn;
    }
}

Network CNode::ConnectedThroughNetwork() const
{
    return m_inbound_onion ? NET_ONION : addr.GetNetClass();
}

bool CNode::IsConnectedThroughPrivacyNet() const
{
    return m_inbound_onion || addr.IsPrivacyNet();
}

#undef X
#define X(name) stats.name = name
void CNode::CopyStats(CNodeStats& stats)
{
    stats.nodeid = this->GetId();
    X(addr);
    X(addrBind);
    stats.m_network = ConnectedThroughNetwork();
    X(m_last_send);
    X(m_last_recv);
    X(m_last_tx_time);
    X(m_last_block_time);
    X(m_connected);
    X(nTimeOffset);
    X(m_addr_name);
    X(nVersion);
    {
        LOCK(m_subver_mutex);
        X(cleanSubVer);
    }
    stats.fInbound = IsInboundConn();
    X(m_bip152_highbandwidth_to);
    X(m_bip152_highbandwidth_from);
    {
        LOCK(cs_vSend);
        X(mapSendBytesPerMsgType);
        X(nSendBytes);
    }
    {
        LOCK(cs_vRecv);
        X(mapRecvBytesPerMsgType);
        X(nRecvBytes);
        Transport::Info info = m_transport->GetInfo();
        stats.m_transport_type = info.transport_type;
        if (info.session_id) stats.m_session_id = HexStr(*info.session_id);
    }
    X(m_permission_flags);

    X(m_last_ping_time);
    X(m_min_ping_time);

    // Leave string empty if addrLocal invalid (not filled in yet)
    CService addrLocalUnlocked = GetAddrLocal();
    stats.addrLocal = addrLocalUnlocked.IsValid() ? addrLocalUnlocked.ToStringAddrPort() : "";

    X(m_conn_type);
}
#undef X

bool CNode::ReceiveMsgBytes(Span<const uint8_t> msg_bytes, bool& complete)
{
    complete = false;
    const auto time = GetTime<std::chrono::microseconds>();
    LOCK(cs_vRecv);
    m_last_recv = std::chrono::duration_cast<std::chrono::seconds>(time);
    nRecvBytes += msg_bytes.size();
    while (msg_bytes.size() > 0) {
        // absorb network data
        if (!m_transport->ReceivedBytes(msg_bytes)) {
            // Serious transport problem, disconnect from the peer.
            return false;
        }

        if (m_transport->ReceivedMessageComplete()) {
            // decompose a transport agnostic CNetMessage from the deserializer
            bool reject_message{false};
            CNetMessage msg = m_transport->GetReceivedMessage(time, reject_message);
            if (reject_message) {
                // Message deserialization failed. Drop the message but don't disconnect the peer.
                // store the size of the corrupt message
                mapRecvBytesPerMsgType.at(NET_MESSAGE_TYPE_OTHER) += msg.m_raw_message_size;
                continue;
            }

            // Store received bytes per message type.
            // To prevent a memory DOS, only allow known message types.
            auto i = mapRecvBytesPerMsgType.find(msg.m_type);
            if (i == mapRecvBytesPerMsgType.end()) {
                i = mapRecvBytesPerMsgType.find(NET_MESSAGE_TYPE_OTHER);
            }
            assert(i != mapRecvBytesPerMsgType.end());
            i->second += msg.m_raw_message_size;

            // push the message to the process queue,
            vRecvMsg.push_back(std::move(msg));

            complete = true;
        }
    }

    return true;
}

V1Transport::V1Transport(const NodeId node_id, int nTypeIn) noexcept :
    m_node_id(node_id), hdrbuf(nTypeIn), vRecv(nTypeIn)
{
    assert(std::size(Params().MessageStart()) == std::size(m_magic_bytes));
    m_magic_bytes = Params().MessageStart();
    LOCK(m_recv_mutex);
    Reset();
}

Transport::Info V1Transport::GetInfo() const noexcept
{
    return {.transport_type = TransportProtocolType::V1, .session_id = {}};
}

int V1Transport::readHeader(Span<const uint8_t> msg_bytes)
{
    AssertLockHeld(m_recv_mutex);
    // copy data to temporary parsing buffer
    unsigned int nRemaining = CMessageHeader::HEADER_SIZE - nHdrPos;
    unsigned int nCopy = std::min<unsigned int>(nRemaining, msg_bytes.size());

    memcpy(&hdrbuf[nHdrPos], msg_bytes.data(), nCopy);
    nHdrPos += nCopy;

    // if header incomplete, exit
    if (nHdrPos < CMessageHeader::HEADER_SIZE)
        return nCopy;

    // deserialize to CMessageHeader
    try {
        hdrbuf >> hdr;
    }
    catch (const std::exception&) {
        LogPrint(BCLog::NET, "Header error: Unable to deserialize, peer=%d\n", m_node_id);
        return -1;
    }

    // Check start string, network magic
    if (hdr.pchMessageStart != m_magic_bytes) {
        LogPrint(BCLog::NET, "Header error: Wrong MessageStart %s received, peer=%d\n", HexStr(hdr.pchMessageStart), m_node_id);
        return -1;
    }

    // reject messages larger than MAX_SIZE or MAX_PROTOCOL_MESSAGE_LENGTH
    if (hdr.nMessageSize > MAX_SIZE || hdr.nMessageSize > MAX_PROTOCOL_MESSAGE_LENGTH) {
        LogPrint(BCLog::NET, "Header error: Size too large (%s, %u bytes), peer=%d\n", SanitizeString(hdr.GetCommand()), hdr.nMessageSize, m_node_id);
        return -1;
    }

    // switch state to reading message data
    in_data = true;

    return nCopy;
}

int V1Transport::readData(Span<const uint8_t> msg_bytes)
{
    AssertLockHeld(m_recv_mutex);
    unsigned int nRemaining = hdr.nMessageSize - nDataPos;
    unsigned int nCopy = std::min<unsigned int>(nRemaining, msg_bytes.size());

    if (vRecv.size() < nDataPos + nCopy) {
        // Allocate up to 256 KiB ahead, but never more than the total message size.
        vRecv.resize(std::min(hdr.nMessageSize, nDataPos + nCopy + 256 * 1024));
    }

    hasher.Write(msg_bytes.first(nCopy));
    memcpy(&vRecv[nDataPos], msg_bytes.data(), nCopy);
    nDataPos += nCopy;

    return nCopy;
}

const uint256& V1Transport::GetMessageHash() const
{
    AssertLockHeld(m_recv_mutex);
    assert(CompleteInternal());
    if (data_hash.IsNull())
        hasher.Finalize(data_hash);
    return data_hash;
}

CNetMessage V1Transport::GetReceivedMessage(const std::chrono::microseconds time, bool& reject_message)
{
    AssertLockNotHeld(m_recv_mutex);
    // Initialize out parameter
    reject_message = false;
    // decompose a single CNetMessage from the TransportDeserializer
    LOCK(m_recv_mutex);
    CNetMessage msg(std::move(vRecv));

    // store message type string, time, and sizes
    msg.m_type = hdr.GetCommand();
    msg.m_time = time;
    msg.m_message_size = hdr.nMessageSize;
    msg.m_raw_message_size = hdr.nMessageSize + CMessageHeader::HEADER_SIZE;

    uint256 hash = GetMessageHash();

    // We just received a message off the wire, harvest entropy from the time (and the message checksum)
    RandAddEvent(ReadLE32(hash.begin()));

    // Check checksum and header message type string
    if (memcmp(hash.begin(), hdr.pchChecksum, CMessageHeader::CHECKSUM_SIZE) != 0) {
        LogPrint(BCLog::NET, "Header error: Wrong checksum (%s, %u bytes), expected %s was %s, peer=%d\n",
                 SanitizeString(msg.m_type), msg.m_message_size,
                 HexStr(Span{hash}.first(CMessageHeader::CHECKSUM_SIZE)),
                 HexStr(hdr.pchChecksum),
                 m_node_id);
        reject_message = true;
    } else if (!hdr.IsCommandValid()) {
        LogPrint(BCLog::NET, "Header error: Invalid message type (%s, %u bytes), peer=%d\n",
                 SanitizeString(hdr.GetCommand()), msg.m_message_size, m_node_id);
        reject_message = true;
    }

    // Always reset the network deserializer (prepare for the next message)
    Reset();
    return msg;
}

bool V1Transport::SetMessageToSend(CSerializedNetMsg& msg) noexcept
{
    AssertLockNotHeld(m_send_mutex);
    // Determine whether a new message can be set.
    LOCK(m_send_mutex);
    if (m_sending_header || m_bytes_sent < m_message_to_send.data.size()) return false;

    // create dbl-sha256 checksum
    uint256 hash = Hash(msg.data);

    // create header
    CMessageHeader hdr(m_magic_bytes, msg.m_type.c_str(), msg.data.size());
    memcpy(hdr.pchChecksum, hash.begin(), CMessageHeader::CHECKSUM_SIZE);

    // serialize header
    m_header_to_send.clear();
    VectorWriter{SER_NETWORK, m_header_to_send, 0, hdr};

    // update state
    m_message_to_send = std::move(msg);
    m_sending_header = true;
    m_bytes_sent = 0;
    return true;
}

Transport::BytesToSend V1Transport::GetBytesToSend(bool have_next_message) const noexcept
{
    AssertLockNotHeld(m_send_mutex);
    LOCK(m_send_mutex);
    if (m_sending_header) {
        return {Span{m_header_to_send}.subspan(m_bytes_sent),
                // We have more to send after the header if the message has payload, or if there
                // is a next message after that.
                have_next_message || !m_message_to_send.data.empty(),
                m_message_to_send.m_type
               };
    } else {
        return {Span{m_message_to_send.data}.subspan(m_bytes_sent),
                // We only have more to send after this message's payload if there is another
                // message.
                have_next_message,
                m_message_to_send.m_type
               };
    }
}

void V1Transport::MarkBytesSent(size_t bytes_sent) noexcept
{
    AssertLockNotHeld(m_send_mutex);
    LOCK(m_send_mutex);
    m_bytes_sent += bytes_sent;
    if (m_sending_header && m_bytes_sent == m_header_to_send.size()) {
        // We're done sending a message's header. Switch to sending its data bytes.
        m_sending_header = false;
        m_bytes_sent = 0;
    } else if (!m_sending_header && m_bytes_sent == m_message_to_send.data.size()) {
        // We're done sending a message's data. Wipe the data vector to reduce memory consumption.
        ClearShrink(m_message_to_send.data);
        m_bytes_sent = 0;
    }
}

size_t V1Transport::GetSendMemoryUsage() const noexcept
{
    AssertLockNotHeld(m_send_mutex);
    LOCK(m_send_mutex);
    // Don't count sending-side fields besides m_message_to_send, as they're all small and bounded.
    return m_message_to_send.GetMemoryUsage();
}

namespace {

/** List of short messages as defined in BIP324, in order.
 *
 * Only message types that are actually implemented in this codebase need to be listed, as other
 * messages get ignored anyway - whether we know how to decode them or not.
 */
const std::array<std::string, 33> V2_MESSAGE_IDS = {
    "", // 12 bytes follow encoding the message type like in V1
    NetMsgType::ADDR,
    NetMsgType::BLOCK,
    NetMsgType::BLOCKTXN,
    NetMsgType::CMPCTBLOCK,
    NetMsgType::FEEFILTER,
    NetMsgType::FILTERADD,
    NetMsgType::FILTERCLEAR,
    NetMsgType::FILTERLOAD,
    NetMsgType::GETBLOCKS,
    NetMsgType::GETBLOCKTXN,
    NetMsgType::GETDATA,
    NetMsgType::GETHEADERS,
    NetMsgType::HEADERS,
    NetMsgType::INV,
    NetMsgType::MEMPOOL,
    NetMsgType::MERKLEBLOCK,
    NetMsgType::NOTFOUND,
    NetMsgType::PING,
    NetMsgType::PONG,
    NetMsgType::SENDCMPCT,
    NetMsgType::TX,
    NetMsgType::GETCFILTERS,
    NetMsgType::CFILTER,
    NetMsgType::GETCFHEADERS,
    NetMsgType::CFHEADERS,
    NetMsgType::GETCFCHECKPT,
    NetMsgType::CFCHECKPT,
    NetMsgType::ADDRV2,
    // Unimplemented message types that are assigned in BIP324:
    "",
    "",
    "",
    ""
};

class V2MessageMap
{
    std::unordered_map<std::string, uint8_t> m_map;

public:
    V2MessageMap() noexcept
    {
        for (size_t i = 1; i < std::size(V2_MESSAGE_IDS); ++i) {
            m_map.emplace(V2_MESSAGE_IDS[i], i);
        }
    }

    std::optional<uint8_t> operator()(const std::string& message_name) const noexcept
    {
        auto it = m_map.find(message_name);
        if (it == m_map.end()) return std::nullopt;
        return it->second;
    }
};

const V2MessageMap V2_MESSAGE_MAP;

CKey GenerateRandomKey() noexcept
{
    CKey key;
    key.MakeNewKey(/*fCompressed=*/true);
    return key;
}

std::vector<uint8_t> GenerateRandomGarbage() noexcept
{
    std::vector<uint8_t> ret;
    FastRandomContext rng;
    ret.resize(rng.randrange(V2Transport::MAX_GARBAGE_LEN + 1));
    rng.fillrand(MakeWritableByteSpan(ret));
    return ret;
}

} // namespace

void V2Transport::StartSendingHandshake() noexcept
{
    AssertLockHeld(m_send_mutex);
    Assume(m_send_state == SendState::AWAITING_KEY);
    Assume(m_send_buffer.empty());
    // Initialize the send buffer with ellswift pubkey + provided garbage.
    m_send_buffer.resize(EllSwiftPubKey::size() + m_send_garbage.size());
    std::copy(std::begin(m_cipher.GetOurPubKey()), std::end(m_cipher.GetOurPubKey()), MakeWritableByteSpan(m_send_buffer).begin());
    std::copy(m_send_garbage.begin(), m_send_garbage.end(), m_send_buffer.begin() + EllSwiftPubKey::size());
    // We cannot wipe m_send_garbage as it will still be used as AAD later in the handshake.
}

V2Transport::V2Transport(NodeId nodeid, bool initiating, int type_in, const CKey& key, Span<const std::byte> ent32, std::vector<uint8_t> garbage) noexcept :
    m_cipher{key, ent32}, m_initiating{initiating}, m_nodeid{nodeid},
    m_v1_fallback{nodeid, type_in}, m_recv_type{type_in},
    m_recv_state{initiating ? RecvState::KEY : RecvState::KEY_MAYBE_V1},
    m_send_garbage{std::move(garbage)},
    m_send_state{initiating ? SendState::AWAITING_KEY : SendState::MAYBE_V1}
{
    Assume(m_send_garbage.size() <= MAX_GARBAGE_LEN);
    // Start sending immediately if we're the initiator of the connection.
    if (initiating) {
        LOCK(m_send_mutex);
        StartSendingHandshake();
    }
}

V2Transport::V2Transport(NodeId nodeid, bool initiating, int type_in) noexcept :
    V2Transport{nodeid, initiating, type_in, GenerateRandomKey(),
                MakeByteSpan(GetRandHash()), GenerateRandomGarbage()} { }

void V2Transport::SetReceiveState(RecvState recv_state) noexcept
{
    AssertLockHeld(m_recv_mutex);
    // Enforce allowed state transitions.
    switch (m_recv_state) {
    case RecvState::KEY_MAYBE_V1:
        Assume(recv_state == RecvState::KEY || recv_state == RecvState::V1);
        break;
    case RecvState::KEY:
        Assume(recv_state == RecvState::GARB_GARBTERM);
        break;
    case RecvState::GARB_GARBTERM:
        Assume(recv_state == RecvState::VERSION);
        break;
    case RecvState::VERSION:
        Assume(recv_state == RecvState::APP);
        break;
    case RecvState::APP:
        Assume(recv_state == RecvState::APP_READY);
        break;
    case RecvState::APP_READY:
        Assume(recv_state == RecvState::APP);
        break;
    case RecvState::V1:
        Assume(false); // V1 state cannot be left
        break;
    }
    // Change state.
    m_recv_state = recv_state;
}

void V2Transport::SetSendState(SendState send_state) noexcept
{
    AssertLockHeld(m_send_mutex);
    // Enforce allowed state transitions.
    switch (m_send_state) {
    case SendState::MAYBE_V1:
        Assume(send_state == SendState::V1 || send_state == SendState::AWAITING_KEY);
        break;
    case SendState::AWAITING_KEY:
        Assume(send_state == SendState::READY);
        break;
    case SendState::READY:
    case SendState::V1:
        Assume(false); // Final states
        break;
    }
    // Change state.
    m_send_state = send_state;
}

bool V2Transport::ReceivedMessageComplete() const noexcept
{
    AssertLockNotHeld(m_recv_mutex);
    LOCK(m_recv_mutex);
    if (m_recv_state == RecvState::V1) return m_v1_fallback.ReceivedMessageComplete();

    return m_recv_state == RecvState::APP_READY;
}

void V2Transport::ProcessReceivedMaybeV1Bytes() noexcept
{
    AssertLockHeld(m_recv_mutex);
    AssertLockNotHeld(m_send_mutex);
    Assume(m_recv_state == RecvState::KEY_MAYBE_V1);
    // We still have to determine if this is a v1 or v2 connection. The bytes being received could
    // be the beginning of either a v1 packet (network magic + "version\x00\x00\x00\x00\x00"), or
    // of a v2 public key. BIP324 specifies that a mismatch with this 16-byte string should trigger
    // sending of the key.
    std::array<uint8_t, V1_PREFIX_LEN> v1_prefix = {0, 0, 0, 0, 'v', 'e', 'r', 's', 'i', 'o', 'n', 0, 0, 0, 0, 0};
    std::copy(std::begin(Params().MessageStart()), std::end(Params().MessageStart()), v1_prefix.begin());
    Assume(m_recv_buffer.size() <= v1_prefix.size());
    if (!std::equal(m_recv_buffer.begin(), m_recv_buffer.end(), v1_prefix.begin())) {
        // Mismatch with v1 prefix, so we can assume a v2 connection.
        SetReceiveState(RecvState::KEY); // Convert to KEY state, leaving received bytes around.
        // Transition the sender to AWAITING_KEY state and start sending.
        LOCK(m_send_mutex);
        SetSendState(SendState::AWAITING_KEY);
        StartSendingHandshake();
    } else if (m_recv_buffer.size() == v1_prefix.size()) {
        // Full match with the v1 prefix, so fall back to v1 behavior.
        LOCK(m_send_mutex);
        Span<const uint8_t> feedback{m_recv_buffer};
        // Feed already received bytes to v1 transport. It should always accept these, because it's
        // less than the size of a v1 header, and these are the first bytes fed to m_v1_fallback.
        bool ret = m_v1_fallback.ReceivedBytes(feedback);
        Assume(feedback.empty());
        Assume(ret);
        SetReceiveState(RecvState::V1);
        SetSendState(SendState::V1);
        // Reset v2 transport buffers to save memory.
        ClearShrink(m_recv_buffer);
        ClearShrink(m_send_buffer);
    } else {
        // We have not received enough to distinguish v1 from v2 yet. Wait until more bytes come.
    }
}

bool V2Transport::ProcessReceivedKeyBytes() noexcept
{
    AssertLockHeld(m_recv_mutex);
    AssertLockNotHeld(m_send_mutex);
    Assume(m_recv_state == RecvState::KEY);
    Assume(m_recv_buffer.size() <= EllSwiftPubKey::size());

    // As a special exception, if bytes 4-16 of the key on a responder connection match the
    // corresponding bytes of a V1 version message, but bytes 0-4 don't match the network magic
    // (if they did, we'd have switched to V1 state already), assume this is a peer from
    // another network, and disconnect them. They will almost certainly disconnect us too when
    // they receive our uniformly random key and garbage, but detecting this case specially
    // means we can log it.
    static constexpr std::array<uint8_t, 12> MATCH = {'v', 'e', 'r', 's', 'i', 'o', 'n', 0, 0, 0, 0, 0};
    static constexpr size_t OFFSET = std::tuple_size_v<MessageStartChars>;
    if (!m_initiating && m_recv_buffer.size() >= OFFSET + MATCH.size()) {
        if (std::equal(MATCH.begin(), MATCH.end(), m_recv_buffer.begin() + OFFSET)) {
            LogPrint(BCLog::NET, "V2 transport error: V1 peer with wrong MessageStart %s\n",
                     HexStr(Span(m_recv_buffer).first(OFFSET)));
            return false;
        }
    }

    if (m_recv_buffer.size() == EllSwiftPubKey::size()) {
        // Other side's key has been fully received, and can now be Diffie-Hellman combined with
        // our key to initialize the encryption ciphers.

        // Initialize the ciphers.
        EllSwiftPubKey ellswift(MakeByteSpan(m_recv_buffer));
        LOCK(m_send_mutex);
        m_cipher.Initialize(ellswift, m_initiating);

        // Switch receiver state to GARB_GARBTERM.
        SetReceiveState(RecvState::GARB_GARBTERM);
        m_recv_buffer.clear();

        // Switch sender state to READY.
        SetSendState(SendState::READY);

        // Append the garbage terminator to the send buffer.
        m_send_buffer.resize(m_send_buffer.size() + BIP324Cipher::GARBAGE_TERMINATOR_LEN);
        std::copy(m_cipher.GetSendGarbageTerminator().begin(),
                  m_cipher.GetSendGarbageTerminator().end(),
                  MakeWritableByteSpan(m_send_buffer).last(BIP324Cipher::GARBAGE_TERMINATOR_LEN).begin());

        // Construct version packet in the send buffer, with the sent garbage data as AAD.
        m_send_buffer.resize(m_send_buffer.size() + BIP324Cipher::EXPANSION + VERSION_CONTENTS.size());
        m_cipher.Encrypt(
            /*contents=*/VERSION_CONTENTS,
            /*aad=*/MakeByteSpan(m_send_garbage),
            /*ignore=*/false,
            /*output=*/MakeWritableByteSpan(m_send_buffer).last(BIP324Cipher::EXPANSION + VERSION_CONTENTS.size()));
        // We no longer need the garbage.
        ClearShrink(m_send_garbage);
    } else {
        // We still have to receive more key bytes.
    }
    return true;
}

bool V2Transport::ProcessReceivedGarbageBytes() noexcept
{
    AssertLockHeld(m_recv_mutex);
    Assume(m_recv_state == RecvState::GARB_GARBTERM);
    Assume(m_recv_buffer.size() <= MAX_GARBAGE_LEN + BIP324Cipher::GARBAGE_TERMINATOR_LEN);
    if (m_recv_buffer.size() >= BIP324Cipher::GARBAGE_TERMINATOR_LEN) {
        if (MakeByteSpan(m_recv_buffer).last(BIP324Cipher::GARBAGE_TERMINATOR_LEN) == m_cipher.GetReceiveGarbageTerminator()) {
            // Garbage terminator received. Store garbage to authenticate it as AAD later.
            m_recv_aad = std::move(m_recv_buffer);
            m_recv_aad.resize(m_recv_aad.size() - BIP324Cipher::GARBAGE_TERMINATOR_LEN);
            m_recv_buffer.clear();
            SetReceiveState(RecvState::VERSION);
        } else if (m_recv_buffer.size() == MAX_GARBAGE_LEN + BIP324Cipher::GARBAGE_TERMINATOR_LEN) {
            // We've reached the maximum length for garbage + garbage terminator, and the
            // terminator still does not match. Abort.
            LogPrint(BCLog::NET, "V2 transport error: missing garbage terminator, peer=%d\n", m_nodeid);
            return false;
        } else {
            // We still need to receive more garbage and/or garbage terminator bytes.
        }
    } else {
        // We have less than GARBAGE_TERMINATOR_LEN (16) bytes, so we certainly need to receive
        // more first.
    }
    return true;
}

bool V2Transport::ProcessReceivedPacketBytes() noexcept
{
    AssertLockHeld(m_recv_mutex);
    Assume(m_recv_state == RecvState::VERSION || m_recv_state == RecvState::APP);

    // The maximum permitted contents length for a packet, consisting of:
    // - 0x00 byte: indicating long message type encoding
    // - 12 bytes of message type
    // - payload
    static constexpr size_t MAX_CONTENTS_LEN =
        1 + CMessageHeader::COMMAND_SIZE +
        std::min<size_t>(MAX_SIZE, MAX_PROTOCOL_MESSAGE_LENGTH);

    if (m_recv_buffer.size() == BIP324Cipher::LENGTH_LEN) {
        // Length descriptor received.
        m_recv_len = m_cipher.DecryptLength(MakeByteSpan(m_recv_buffer));
        if (m_recv_len > MAX_CONTENTS_LEN) {
            LogPrint(BCLog::NET, "V2 transport error: packet too large (%u bytes), peer=%d\n", m_recv_len, m_nodeid);
            return false;
        }
    } else if (m_recv_buffer.size() > BIP324Cipher::LENGTH_LEN && m_recv_buffer.size() == m_recv_len + BIP324Cipher::EXPANSION) {
        // Ciphertext received, decrypt it into m_recv_decode_buffer.
        // Note that it is impossible to reach this branch without hitting the branch above first,
        // as GetMaxBytesToProcess only allows up to LENGTH_LEN into the buffer before that point.
        m_recv_decode_buffer.resize(m_recv_len);
        bool ignore{false};
        bool ret = m_cipher.Decrypt(
            /*input=*/MakeByteSpan(m_recv_buffer).subspan(BIP324Cipher::LENGTH_LEN),
            /*aad=*/MakeByteSpan(m_recv_aad),
            /*ignore=*/ignore,
            /*contents=*/MakeWritableByteSpan(m_recv_decode_buffer));
        if (!ret) {
            LogPrint(BCLog::NET, "V2 transport error: packet decryption failure (%u bytes), peer=%d\n", m_recv_len, m_nodeid);
            return false;
        }
        // We have decrypted a valid packet with the AAD we expected, so clear the expected AAD.
        ClearShrink(m_recv_aad);
        // Feed the last 4 bytes of the Poly1305 authentication tag (and its timing) into our RNG.
        RandAddEvent(ReadLE32(m_recv_buffer.data() + m_recv_buffer.size() - 4));

        // At this point we have a valid packet decrypted into m_recv_decode_buffer. If it's not a
        // decoy, which we simply ignore, use the current state to decide what to do with it.
        if (!ignore) {
            switch (m_recv_state) {
            case RecvState::VERSION:
                // Version message received; transition to application phase. The contents is
                // ignored, but can be used for future extensions.
                SetReceiveState(RecvState::APP);
                break;
            case RecvState::APP:
                // Application message decrypted correctly. It can be extracted using GetMessage().
                SetReceiveState(RecvState::APP_READY);
                break;
            default:
                // Any other state is invalid (this function should not have been called).
                Assume(false);
            }
        }
        // Wipe the receive buffer where the next packet will be received into.
        ClearShrink(m_recv_buffer);
        // In all but APP_READY state, we can wipe the decoded contents.
        if (m_recv_state != RecvState::APP_READY) ClearShrink(m_recv_decode_buffer);
    } else {
        // We either have less than 3 bytes, so we don't know the packet's length yet, or more
        // than 3 bytes but less than the packet's full ciphertext. Wait until those arrive.
    }
    return true;
}

size_t V2Transport::GetMaxBytesToProcess() noexcept
{
    AssertLockHeld(m_recv_mutex);
    switch (m_recv_state) {
    case RecvState::KEY_MAYBE_V1:
        // During the KEY_MAYBE_V1 state we do not allow more than the length of v1 prefix into the
        // receive buffer.
        Assume(m_recv_buffer.size() <= V1_PREFIX_LEN);
        // As long as we're not sure if this is a v1 or v2 connection, don't receive more than what
        // is strictly necessary to distinguish the two (16 bytes). If we permitted more than
        // the v1 header size (24 bytes), we may not be able to feed the already-received bytes
        // back into the m_v1_fallback V1 transport.
        return V1_PREFIX_LEN - m_recv_buffer.size();
    case RecvState::KEY:
        // During the KEY state, we only allow the 64-byte key into the receive buffer.
        Assume(m_recv_buffer.size() <= EllSwiftPubKey::size());
        // As long as we have not received the other side's public key, don't receive more than
        // that (64 bytes), as garbage follows, and locating the garbage terminator requires the
        // key exchange first.
        return EllSwiftPubKey::size() - m_recv_buffer.size();
    case RecvState::GARB_GARBTERM:
        // Process garbage bytes one by one (because terminator may appear anywhere).
        return 1;
    case RecvState::VERSION:
    case RecvState::APP:
        // These three states all involve decoding a packet. Process the length descriptor first,
        // so that we know where the current packet ends (and we don't process bytes from the next
        // packet or decoy yet). Then, process the ciphertext bytes of the current packet.
        if (m_recv_buffer.size() < BIP324Cipher::LENGTH_LEN) {
            return BIP324Cipher::LENGTH_LEN - m_recv_buffer.size();
        } else {
            // Note that BIP324Cipher::EXPANSION is the total difference between contents size
            // and encoded packet size, which includes the 3 bytes due to the packet length.
            // When transitioning from receiving the packet length to receiving its ciphertext,
            // the encrypted packet length is left in the receive buffer.
            return BIP324Cipher::EXPANSION + m_recv_len - m_recv_buffer.size();
        }
    case RecvState::APP_READY:
        // No bytes can be processed until GetMessage() is called.
        return 0;
    case RecvState::V1:
        // Not allowed (must be dealt with by the caller).
        Assume(false);
        return 0;
    }
    Assume(false); // unreachable
    return 0;
}

bool V2Transport::ReceivedBytes(Span<const uint8_t>& msg_bytes) noexcept
{
    AssertLockNotHeld(m_recv_mutex);
    /** How many bytes to allocate in the receive buffer at most above what is received so far. */
    static constexpr size_t MAX_RESERVE_AHEAD = 256 * 1024;

    LOCK(m_recv_mutex);
    if (m_recv_state == RecvState::V1) return m_v1_fallback.ReceivedBytes(msg_bytes);

    // Process the provided bytes in msg_bytes in a loop. In each iteration a nonzero number of
    // bytes (decided by GetMaxBytesToProcess) are taken from the beginning om msg_bytes, and
    // appended to m_recv_buffer. Then, depending on the receiver state, one of the
    // ProcessReceived*Bytes functions is called to process the bytes in that buffer.
    while (!msg_bytes.empty()) {
        // Decide how many bytes to copy from msg_bytes to m_recv_buffer.
        size_t max_read = GetMaxBytesToProcess();

        // Reserve space in the buffer if there is not enough.
        if (m_recv_buffer.size() + std::min(msg_bytes.size(), max_read) > m_recv_buffer.capacity()) {
            switch (m_recv_state) {
            case RecvState::KEY_MAYBE_V1:
            case RecvState::KEY:
            case RecvState::GARB_GARBTERM:
                // During the initial states (key/garbage), allocate once to fit the maximum (4111
                // bytes).
                m_recv_buffer.reserve(MAX_GARBAGE_LEN + BIP324Cipher::GARBAGE_TERMINATOR_LEN);
                break;
            case RecvState::VERSION:
            case RecvState::APP: {
                // During states where a packet is being received, as much as is expected but never
                // more than MAX_RESERVE_AHEAD bytes in addition to what is received so far.
                // This means attackers that want to cause us to waste allocated memory are limited
                // to MAX_RESERVE_AHEAD above the largest allowed message contents size, and to
                // MAX_RESERVE_AHEAD more than they've actually sent us.
                size_t alloc_add = std::min(max_read, msg_bytes.size() + MAX_RESERVE_AHEAD);
                m_recv_buffer.reserve(m_recv_buffer.size() + alloc_add);
                break;
            }
            case RecvState::APP_READY:
                // The buffer is empty in this state.
                Assume(m_recv_buffer.empty());
                break;
            case RecvState::V1:
                // Should have bailed out above.
                Assume(false);
                break;
            }
        }

        // Can't read more than provided input.
        max_read = std::min(msg_bytes.size(), max_read);
        // Copy data to buffer.
        m_recv_buffer.insert(m_recv_buffer.end(), UCharCast(msg_bytes.data()), UCharCast(msg_bytes.data() + max_read));
        msg_bytes = msg_bytes.subspan(max_read);

        // Process data in the buffer.
        switch (m_recv_state) {
        case RecvState::KEY_MAYBE_V1:
            ProcessReceivedMaybeV1Bytes();
            if (m_recv_state == RecvState::V1) return true;
            break;

        case RecvState::KEY:
            if (!ProcessReceivedKeyBytes()) return false;
            break;

        case RecvState::GARB_GARBTERM:
            if (!ProcessReceivedGarbageBytes()) return false;
            break;

        case RecvState::VERSION:
        case RecvState::APP:
            if (!ProcessReceivedPacketBytes()) return false;
            break;

        case RecvState::APP_READY:
            return true;

        case RecvState::V1:
            // We should have bailed out before.
            Assume(false);
            break;
        }
        // Make sure we have made progress before continuing.
        Assume(max_read > 0);
    }

    return true;
}

std::optional<std::string> V2Transport::GetMessageType(Span<const uint8_t>& contents) noexcept
{
    if (contents.size() == 0) return std::nullopt; // Empty contents
    uint8_t first_byte = contents[0];
    contents = contents.subspan(1); // Strip first byte.

    if (first_byte != 0) {
        // Short (1 byte) encoding.
        if (first_byte < std::size(V2_MESSAGE_IDS)) {
            // Valid short message id.
            return V2_MESSAGE_IDS[first_byte];
        } else {
            // Unknown short message id.
            return std::nullopt;
        }
    }

    if (contents.size() < CMessageHeader::COMMAND_SIZE) {
        return std::nullopt; // Long encoding needs 12 message type bytes.
    }

    size_t msg_type_len{0};
    while (msg_type_len < CMessageHeader::COMMAND_SIZE && contents[msg_type_len] != 0) {
        // Verify that message type bytes before the first 0x00 are in range.
        if (contents[msg_type_len] < ' ' || contents[msg_type_len] > 0x7F) {
            return {};
        }
        ++msg_type_len;
    }
    std::string ret{reinterpret_cast<const char*>(contents.data()), msg_type_len};
    while (msg_type_len < CMessageHeader::COMMAND_SIZE) {
        // Verify that message type bytes after the first 0x00 are also 0x00.
        if (contents[msg_type_len] != 0) return {};
        ++msg_type_len;
    }
    // Strip message type bytes of contents.
    contents = contents.subspan(CMessageHeader::COMMAND_SIZE);
    return {std::move(ret)};
}

CNetMessage V2Transport::GetReceivedMessage(std::chrono::microseconds time, bool& reject_message) noexcept
{
    AssertLockNotHeld(m_recv_mutex);
    LOCK(m_recv_mutex);
    if (m_recv_state == RecvState::V1) return m_v1_fallback.GetReceivedMessage(time, reject_message);

    Assume(m_recv_state == RecvState::APP_READY);
    Span<const uint8_t> contents{m_recv_decode_buffer};
    auto msg_type = GetMessageType(contents);
    CDataStream ret(m_recv_type);
    CNetMessage msg{std::move(ret)};
    // Note that BIP324Cipher::EXPANSION also includes the length descriptor size.
    msg.m_raw_message_size = m_recv_decode_buffer.size() + BIP324Cipher::EXPANSION;
    if (msg_type) {
        reject_message = false;
        msg.m_type = std::move(*msg_type);
        msg.m_time = time;
        msg.m_message_size = contents.size();
        msg.m_recv.resize(contents.size());
        std::copy(contents.begin(), contents.end(), UCharCast(msg.m_recv.data()));
    } else {
        LogPrint(BCLog::NET, "V2 transport error: invalid message type (%u bytes contents), peer=%d\n", m_recv_decode_buffer.size(), m_nodeid);
        reject_message = true;
    }
    ClearShrink(m_recv_decode_buffer);
    SetReceiveState(RecvState::APP);

    return msg;
}

bool V2Transport::SetMessageToSend(CSerializedNetMsg& msg) noexcept
{
    AssertLockNotHeld(m_send_mutex);
    LOCK(m_send_mutex);
    if (m_send_state == SendState::V1) return m_v1_fallback.SetMessageToSend(msg);
    // We only allow adding a new message to be sent when in the READY state (so the packet cipher
    // is available) and the send buffer is empty. This limits the number of messages in the send
    // buffer to just one, and leaves the responsibility for queueing them up to the caller.
    if (!(m_send_state == SendState::READY && m_send_buffer.empty())) return false;
    // Construct contents (encoding message type + payload).
    std::vector<uint8_t> contents;
    auto short_message_id = V2_MESSAGE_MAP(msg.m_type);
    if (short_message_id) {
        contents.resize(1 + msg.data.size());
        contents[0] = *short_message_id;
        std::copy(msg.data.begin(), msg.data.end(), contents.begin() + 1);
    } else {
        // Initialize with zeroes, and then write the message type string starting at offset 1.
        // This means contents[0] and the unused positions in contents[1..13] remain 0x00.
        contents.resize(1 + CMessageHeader::COMMAND_SIZE + msg.data.size(), 0);
        std::copy(msg.m_type.begin(), msg.m_type.end(), contents.data() + 1);
        std::copy(msg.data.begin(), msg.data.end(), contents.begin() + 1 + CMessageHeader::COMMAND_SIZE);
    }
    // Construct ciphertext in send buffer.
    m_send_buffer.resize(contents.size() + BIP324Cipher::EXPANSION);
    m_cipher.Encrypt(MakeByteSpan(contents), {}, false, MakeWritableByteSpan(m_send_buffer));
    m_send_type = msg.m_type;
    // Release memory
    ClearShrink(msg.data);
    return true;
}

Transport::BytesToSend V2Transport::GetBytesToSend(bool have_next_message) const noexcept
{
    AssertLockNotHeld(m_send_mutex);
    LOCK(m_send_mutex);
    if (m_send_state == SendState::V1) return m_v1_fallback.GetBytesToSend(have_next_message);

    if (m_send_state == SendState::MAYBE_V1) Assume(m_send_buffer.empty());
    Assume(m_send_pos <= m_send_buffer.size());
    return {
        Span{m_send_buffer}.subspan(m_send_pos),
        // We only have more to send after the current m_send_buffer if there is a (next)
        // message to be sent, and we're capable of sending packets. */
        have_next_message && m_send_state == SendState::READY,
        m_send_type
    };
}

void V2Transport::MarkBytesSent(size_t bytes_sent) noexcept
{
    AssertLockNotHeld(m_send_mutex);
    LOCK(m_send_mutex);
    if (m_send_state == SendState::V1) return m_v1_fallback.MarkBytesSent(bytes_sent);

    if (m_send_state == SendState::AWAITING_KEY && m_send_pos == 0 && bytes_sent > 0) {
        LogPrint(BCLog::NET, "start sending v2 handshake to peer=%d\n", m_nodeid);
    }

    m_send_pos += bytes_sent;
    Assume(m_send_pos <= m_send_buffer.size());
    if (m_send_pos >= CMessageHeader::HEADER_SIZE) {
        m_sent_v1_header_worth = true;
    }
    // Wipe the buffer when everything is sent.
    if (m_send_pos == m_send_buffer.size()) {
        m_send_pos = 0;
        ClearShrink(m_send_buffer);
    }
}

bool V2Transport::ShouldReconnectV1() const noexcept
{
    AssertLockNotHeld(m_send_mutex);
    AssertLockNotHeld(m_recv_mutex);
    // Only outgoing connections need reconnection.
    if (!m_initiating) return false;

    LOCK(m_recv_mutex);
    // We only reconnect in the very first state and when the receive buffer is empty. Together
    // these conditions imply nothing has been received so far.
    if (m_recv_state != RecvState::KEY) return false;
    if (!m_recv_buffer.empty()) return false;
    // Check if we've sent enough for the other side to disconnect us (if it was V1).
    LOCK(m_send_mutex);
    return m_sent_v1_header_worth;
}

size_t V2Transport::GetSendMemoryUsage() const noexcept
{
    AssertLockNotHeld(m_send_mutex);
    LOCK(m_send_mutex);
    if (m_send_state == SendState::V1) return m_v1_fallback.GetSendMemoryUsage();

    return sizeof(m_send_buffer) + memusage::DynamicUsage(m_send_buffer);
}

Transport::Info V2Transport::GetInfo() const noexcept
{
    AssertLockNotHeld(m_recv_mutex);
    LOCK(m_recv_mutex);
    if (m_recv_state == RecvState::V1) return m_v1_fallback.GetInfo();

    Transport::Info info;

    // Do not report v2 and session ID until the version packet has been received
    // and verified (confirming that the other side very likely has the same keys as us).
    if (m_recv_state != RecvState::KEY_MAYBE_V1 && m_recv_state != RecvState::KEY &&
        m_recv_state != RecvState::GARB_GARBTERM && m_recv_state != RecvState::VERSION) {
        info.transport_type = TransportProtocolType::V2;
        info.session_id = uint256(MakeUCharSpan(m_cipher.GetSessionID()));
    } else {
        info.transport_type = TransportProtocolType::DETECTING;
    }

    return info;
}

std::pair<size_t, bool> CConnman::SocketSendData(CNode& node) const
{
    auto it = node.vSendMsg.begin();
    size_t nSentSize = 0;
    bool data_left{false}; //!< second return value (whether unsent data remains)
    std::optional<bool> expected_more;

    while (true) {
        if (it != node.vSendMsg.end()) {
            // If possible, move one message from the send queue to the transport. This fails when
            // there is an existing message still being sent, or (for v2 transports) when the
            // handshake has not yet completed.
            size_t memusage = it->GetMemoryUsage();
            if (node.m_transport->SetMessageToSend(*it)) {
                // Update memory usage of send buffer (as *it will be deleted).
                node.m_send_memusage -= memusage;
                ++it;
            }
        }
        const auto& [data, more, msg_type] = node.m_transport->GetBytesToSend(it != node.vSendMsg.end());
        // We rely on the 'more' value returned by GetBytesToSend to correctly predict whether more
        // bytes are still to be sent, to correctly set the MSG_MORE flag. As a sanity check,
        // verify that the previously returned 'more' was correct.
        if (expected_more.has_value()) Assume(!data.empty() == *expected_more);
        expected_more = more;
        data_left = !data.empty(); // will be overwritten on next loop if all of data gets sent
        int nBytes = 0;
        if (!data.empty()) {
            LOCK(node.m_sock_mutex);
            // There is no socket in case we've already disconnected, or in test cases without
            // real connections. In these cases, we bail out immediately and just leave things
            // in the send queue and transport.
            if (!node.m_sock) {
                break;
            }
            int flags = MSG_NOSIGNAL | MSG_DONTWAIT;
#ifdef MSG_MORE
            if (more) {
                flags |= MSG_MORE;
            }
#endif
            nBytes = node.m_sock->Send(reinterpret_cast<const char*>(data.data()), data.size(), flags);
        }
        if (nBytes > 0) {
            node.m_last_send = GetTime<std::chrono::seconds>();
            node.nSendBytes += nBytes;
            // Notify transport that bytes have been processed.
            node.m_transport->MarkBytesSent(nBytes);
            // Update statistics per message type.
            if (!msg_type.empty()) { // don't report v2 handshake bytes for now
                node.AccountForSentBytes(msg_type, nBytes);
            }
            nSentSize += nBytes;
            if ((size_t)nBytes != data.size()) {
                // could not send full message; stop sending more
                break;
            }
        } else {
            if (nBytes < 0) {
                // error
                int nErr = WSAGetLastError();
                if (nErr != WSAEWOULDBLOCK && nErr != WSAEMSGSIZE && nErr != WSAEINTR && nErr != WSAEINPROGRESS) {
                    LogPrint(BCLog::NET, "socket send error for peer=%d: %s\n", node.GetId(), NetworkErrorString(nErr));
                    node.CloseSocketDisconnect();
                }
            }
            break;
        }
    }

    node.fPauseSend = node.m_send_memusage + node.m_transport->GetSendMemoryUsage() > nSendBufferMaxSize;

    if (it == node.vSendMsg.end()) {
        assert(node.m_send_memusage == 0);
    }
    node.vSendMsg.erase(node.vSendMsg.begin(), it);
    return {nSentSize, data_left};
}

/** Try to find a connection to evict when the node is full.
 *  Extreme care must be taken to avoid opening the node to attacker
 *   triggered network partitioning.
 *  The strategy used here is to protect a small number of peers
 *   for each of several distinct characteristics which are difficult
 *   to forge.  In order to partition a node the attacker must be
 *   simultaneously better at all of them than honest peers.
 */
bool CConnman::AttemptToEvictConnection()
{
    std::vector<NodeEvictionCandidate> vEvictionCandidates;
    {

        LOCK(m_nodes_mutex);
        for (const CNode* node : m_nodes) {
            if (node->fDisconnect)
                continue;
            NodeEvictionCandidate candidate{
                .id = node->GetId(),
                .m_connected = node->m_connected,
                .m_min_ping_time = node->m_min_ping_time,
                .m_last_block_time = node->m_last_block_time,
                .m_last_tx_time = node->m_last_tx_time,
                .fRelevantServices = node->m_has_all_wanted_services,
                .m_relay_txs = node->m_relays_txs.load(),
                .fBloomFilter = node->m_bloom_filter_loaded.load(),
                .nKeyedNetGroup = node->nKeyedNetGroup,
                .prefer_evict = node->m_prefer_evict,
                .m_is_local = node->addr.IsLocal(),
                .m_network = node->ConnectedThroughNetwork(),
                .m_noban = node->HasPermission(NetPermissionFlags::NoBan),
                .m_conn_type = node->m_conn_type,
            };
            vEvictionCandidates.push_back(candidate);
        }
    }
    const std::optional<NodeId> node_id_to_evict = SelectNodeToEvict(std::move(vEvictionCandidates));
    if (!node_id_to_evict) {
        return false;
    }
    LOCK(m_nodes_mutex);
    for (CNode* pnode : m_nodes) {
        if (pnode->GetId() == *node_id_to_evict) {
            LogPrint(BCLog::NET, "selected %s connection for eviction peer=%d; disconnecting\n", pnode->ConnectionTypeAsString(), pnode->GetId());
            pnode->fDisconnect = true;
            return true;
        }
    }
    return false;
}

void CConnman::AcceptConnection(const ListenSocket& hListenSocket) {
    struct sockaddr_storage sockaddr;
    socklen_t len = sizeof(sockaddr);
    auto sock = hListenSocket.sock->Accept((struct sockaddr*)&sockaddr, &len);
    CAddress addr;

    if (!sock) {
        const int nErr = WSAGetLastError();
        if (nErr != WSAEWOULDBLOCK) {
            LogPrintf("socket error accept failed: %s\n", NetworkErrorString(nErr));
        }
        return;
    }

    if (!addr.SetSockAddr((const struct sockaddr*)&sockaddr)) {
        LogPrintLevel(BCLog::NET, BCLog::Level::Warning, "Unknown socket family\n");
    } else {
        addr = CAddress{MaybeFlipIPv6toCJDNS(addr), NODE_NONE};
    }

    const CAddress addr_bind{MaybeFlipIPv6toCJDNS(GetBindAddress(*sock)), NODE_NONE};

    NetPermissionFlags permission_flags = NetPermissionFlags::None;
    hListenSocket.AddSocketPermissionFlags(permission_flags);

    CreateNodeFromAcceptedSocket(std::move(sock), permission_flags, addr_bind, addr);
}

void CConnman::CreateNodeFromAcceptedSocket(std::unique_ptr<Sock>&& sock,
                                            NetPermissionFlags permission_flags,
                                            const CAddress& addr_bind,
                                            const CAddress& addr)
{
    int nInbound = 0;
    int nMaxInbound = nMaxConnections - m_max_outbound;

    AddWhitelistPermissionFlags(permission_flags, addr);
    if (NetPermissions::HasFlag(permission_flags, NetPermissionFlags::Implicit)) {
        NetPermissions::ClearFlag(permission_flags, NetPermissionFlags::Implicit);
        if (gArgs.GetBoolArg("-whitelistforcerelay", DEFAULT_WHITELISTFORCERELAY)) NetPermissions::AddFlag(permission_flags, NetPermissionFlags::ForceRelay);
        if (gArgs.GetBoolArg("-whitelistrelay", DEFAULT_WHITELISTRELAY)) NetPermissions::AddFlag(permission_flags, NetPermissionFlags::Relay);
        NetPermissions::AddFlag(permission_flags, NetPermissionFlags::Mempool);
        NetPermissions::AddFlag(permission_flags, NetPermissionFlags::NoBan);
    }

    {
        LOCK(m_nodes_mutex);
        for (const CNode* pnode : m_nodes) {
            if (pnode->IsInboundConn()) nInbound++;
        }
    }

    if (!fNetworkActive) {
        LogPrint(BCLog::NET, "connection from %s dropped: not accepting new connections\n", addr.ToStringAddrPort());
        return;
    }

    if (!sock->IsSelectable()) {
        LogPrintf("connection from %s dropped: non-selectable socket\n", addr.ToStringAddrPort());
        return;
    }

    // According to the internet TCP_NODELAY is not carried into accepted sockets
    // on all platforms.  Set it again here just to be sure.
    const int on{1};
    if (sock->SetSockOpt(IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on)) == SOCKET_ERROR) {
        LogPrint(BCLog::NET, "connection from %s: unable to set TCP_NODELAY, continuing anyway\n",
                 addr.ToStringAddrPort());
    }

    // Don't accept connections from banned peers.
    bool banned = m_banman && m_banman->IsBanned(addr);
    if (!NetPermissions::HasFlag(permission_flags, NetPermissionFlags::NoBan) && banned)
    {
        LogPrint(BCLog::NET, "connection from %s dropped (banned)\n", addr.ToStringAddrPort());
        return;
    }

    // Only accept connections from discouraged peers if our inbound slots aren't (almost) full.
    bool discouraged = m_banman && m_banman->IsDiscouraged(addr);
    if (!NetPermissions::HasFlag(permission_flags, NetPermissionFlags::NoBan) && nInbound + 1 >= nMaxInbound && discouraged)
    {
        LogPrint(BCLog::NET, "connection from %s dropped (discouraged)\n", addr.ToStringAddrPort());
        return;
    }

    if (nInbound >= nMaxInbound)
    {
        if (!AttemptToEvictConnection()) {
            // No connection to evict, disconnect the new connection
            LogPrint(BCLog::NET, "failed to find an eviction candidate - connection dropped (full)\n");
            return;
        }
    }

    NodeId id = GetNewNodeId();
    uint64_t nonce = GetDeterministicRandomizer(RANDOMIZER_ID_LOCALHOSTNONCE).Write(id).Finalize();

    ServiceFlags nodeServices = nLocalServices;
    if (NetPermissions::HasFlag(permission_flags, NetPermissionFlags::BloomFilter)) {
        nodeServices = static_cast<ServiceFlags>(nodeServices | NODE_BLOOM);
    }

    const bool inbound_onion = std::find(m_onion_binds.begin(), m_onion_binds.end(), addr_bind) != m_onion_binds.end();
    // The V2Transport transparently falls back to V1 behavior when an incoming V1 connection is
    // detected, so use it whenever we signal NODE_P2P_V2.
    const bool use_v2transport(nodeServices & NODE_P2P_V2);

    CNode* pnode = new CNode(id,
                             std::move(sock),
                             addr,
                             CalculateKeyedNetGroup(addr),
                             nonce,
                             addr_bind,
                             /*addrNameIn=*/"",
                             ConnectionType::INBOUND,
                             inbound_onion,
                             CNodeOptions{
                                 .permission_flags = permission_flags,
                                 .prefer_evict = discouraged,
                                 .recv_flood_size = nReceiveFloodSize,
                                 .use_v2transport = use_v2transport,
                             });
    pnode->AddRef();
    m_msgproc->InitializeNode(*pnode, nodeServices);

    LogPrint(BCLog::NET, "connection from %s accepted\n", addr.ToStringAddrPort());

    {
        LOCK(m_nodes_mutex);
        m_nodes.push_back(pnode);
    }

    // We received a new connection, harvest entropy from the time (and our peer count)
    RandAddEvent((uint32_t)id);
}

bool CConnman::AddConnection(const std::string& address, ConnectionType conn_type)
{
    AssertLockNotHeld(m_unused_i2p_sessions_mutex);
    std::optional<int> max_connections;
    switch (conn_type) {
    case ConnectionType::INBOUND:
    case ConnectionType::MANUAL:
        return false;
    case ConnectionType::OUTBOUND_FULL_RELAY:
        max_connections = m_max_outbound_full_relay;
        break;
    case ConnectionType::BLOCK_RELAY:
        max_connections = m_max_outbound_block_relay;
        break;
    // no limit for ADDR_FETCH because -seednode has no limit either
    case ConnectionType::ADDR_FETCH:
        break;
    // no limit for FEELER connections since they're short-lived
    case ConnectionType::FEELER:
        break;
    } // no default case, so the compiler can warn about missing cases

    // Count existing connections
    int existing_connections = WITH_LOCK(m_nodes_mutex,
                                         return std::count_if(m_nodes.begin(), m_nodes.end(), [conn_type](CNode* node) { return node->m_conn_type == conn_type; }););

    // Max connections of specified type already exist
    if (max_connections != std::nullopt && existing_connections >= max_connections) return false;

    // Max total outbound connections already exist
    CSemaphoreGrant grant(*semOutbound, true);
    if (!grant) return false;

    OpenNetworkConnection(CAddress(), false, std::move(grant), address.c_str(), conn_type, /*use_v2transport=*/false);
    return true;
}

void CConnman::DisconnectNodes()
{
    AssertLockNotHeld(m_nodes_mutex);
    AssertLockNotHeld(m_reconnections_mutex);

    // Use a temporary variable to accumulate desired reconnections, so we don't need
    // m_reconnections_mutex while holding m_nodes_mutex.
    decltype(m_reconnections) reconnections_to_add;

    {
        LOCK(m_nodes_mutex);

        if (!fNetworkActive) {
            // Disconnect any connected nodes
            for (CNode* pnode : m_nodes) {
                if (!pnode->fDisconnect) {
                    LogPrint(BCLog::NET, "Network not active, dropping peer=%d\n", pnode->GetId());
                    pnode->fDisconnect = true;
                }
            }
        }

        // Disconnect unused nodes
        std::vector<CNode*> nodes_copy = m_nodes;
        for (CNode* pnode : nodes_copy)
        {
            const bool expired_probe = pnode->m_qq_probe && pnode->m_qq_probe->Expired(qq::Clock::now());
            if (expired_probe) pnode->fDisconnect = true;
            if (pnode->fDisconnect)
            {
                // remove from m_nodes
                m_nodes.erase(remove(m_nodes.begin(), m_nodes.end(), pnode), m_nodes.end());

                // Add to reconnection list if appropriate. We don't reconnect right here, because
                // the creation of a connection is a blocking operation (up to several seconds),
                // and we don't want to hold up the socket handler thread for that long.
                if (!expired_probe && fNetworkActive && pnode->m_transport->ShouldReconnectV1()) {
                    reconnections_to_add.push_back({
                        .addr_connect = pnode->addr,
                        .grant = std::move(pnode->grantOutbound),
                        .destination = pnode->m_dest,
                        .conn_type = pnode->m_conn_type,
                        .use_v2transport = false,
                        .qq_probe = pnode->m_qq_probe});
                    LogPrint(BCLog::NET, "retrying with v1 transport protocol for peer=%d\n", pnode->GetId());
                }

                // release outbound grant (if any)
                pnode->grantOutbound.Release();

                // close socket and cleanup
                pnode->CloseSocketDisconnect();

                // update connection count by network
                if (pnode->IsManualOrFullOutboundConn()) --m_network_conn_counts[pnode->addr.GetNetwork()];

                // hold in disconnected pool until all refs are released
                pnode->Release();
                m_nodes_disconnected.push_back(pnode);
            }
        }
    }
    {
        // Delete disconnected nodes
        std::list<CNode*> nodes_disconnected_copy = m_nodes_disconnected;
        for (CNode* pnode : nodes_disconnected_copy)
        {
            // Destroy the object only after other threads have stopped using it.
            if (pnode->GetRefCount() <= 0) {
                m_nodes_disconnected.remove(pnode);
                DeleteNode(pnode);
            }
        }
    }
    {
        // Move entries from reconnections_to_add to m_reconnections.
        LOCK(m_reconnections_mutex);
        m_reconnections.splice(m_reconnections.end(), std::move(reconnections_to_add));
    }
}

void CConnman::NotifyNumConnectionsChanged()
{
    size_t nodes_size;
    {
        LOCK(m_nodes_mutex);
        nodes_size = m_nodes.size();
    }
    if(nodes_size != nPrevNodeCount) {
        nPrevNodeCount = nodes_size;
        if (m_client_interface) {
            m_client_interface->NotifyNumConnectionsChanged(nodes_size);
        }
    }
}

bool CConnman::ShouldRunInactivityChecks(const CNode& node, std::chrono::seconds now) const
{
    return node.m_connected + m_peer_connect_timeout < now;
}

bool CConnman::InactivityCheck(const CNode& node) const
{
    // Tests that see disconnects after using mocktime can start nodes with a
    // large timeout. For example, -peertimeout=999999999.
    const auto now{GetTime<std::chrono::seconds>()};
    const auto last_send{node.m_last_send.load()};
    const auto last_recv{node.m_last_recv.load()};

    if (!ShouldRunInactivityChecks(node, now)) return false;

    if (last_recv.count() == 0 || last_send.count() == 0) {
        LogPrint(BCLog::NET, "socket no message in first %i seconds, %d %d peer=%d\n", count_seconds(m_peer_connect_timeout), last_recv.count() != 0, last_send.count() != 0, node.GetId());
        return true;
    }

    if (now > last_send + TIMEOUT_INTERVAL) {
        LogPrint(BCLog::NET, "socket sending timeout: %is peer=%d\n", count_seconds(now - last_send), node.GetId());
        return true;
    }

    if (now > last_recv + TIMEOUT_INTERVAL) {
        LogPrint(BCLog::NET, "socket receive timeout: %is peer=%d\n", count_seconds(now - last_recv), node.GetId());
        return true;
    }

    if (!node.fSuccessfullyConnected) {
        LogPrint(BCLog::NET, "version handshake timeout peer=%d\n", node.GetId());
        return true;
    }

    return false;
}

Sock::EventsPerSock CConnman::GenerateWaitSockets(Span<CNode* const> nodes)
{
    Sock::EventsPerSock events_per_sock;

    for (const ListenSocket& hListenSocket : vhListenSocket) {
        events_per_sock.emplace(hListenSocket.sock, Sock::Events{Sock::RECV});
    }

    for (CNode* pnode : nodes) {
        bool select_recv = !pnode->fPauseRecv;
        bool select_send;
        {
            LOCK(pnode->cs_vSend);
            // Sending is possible if either there are bytes to send right now, or if there will be
            // once a potential message from vSendMsg is handed to the transport. GetBytesToSend
            // determines both of these in a single call.
            const auto& [to_send, more, _msg_type] = pnode->m_transport->GetBytesToSend(!pnode->vSendMsg.empty());
            select_send = !to_send.empty() || more;
        }
        if (!select_recv && !select_send) continue;

        LOCK(pnode->m_sock_mutex);
        if (pnode->m_sock) {
            Sock::Event event = (select_send ? Sock::SEND : 0) | (select_recv ? Sock::RECV : 0);
            events_per_sock.emplace(pnode->m_sock, Sock::Events{event});
        }
    }

    return events_per_sock;
}

void CConnman::SocketHandler()
{
    AssertLockNotHeld(m_total_bytes_sent_mutex);

    Sock::EventsPerSock events_per_sock;

    {
        const NodesSnapshot snap{*this, /*shuffle=*/false};

        const auto timeout = std::chrono::milliseconds(SELECT_TIMEOUT_MILLISECONDS);

        // Check for the readiness of the already connected sockets and the
        // listening sockets in one call ("readiness" as in poll(2) or
        // select(2)). If none are ready, wait for a short while and return
        // empty sets.
        events_per_sock = GenerateWaitSockets(snap.Nodes());
        if (events_per_sock.empty() || !events_per_sock.begin()->first->WaitMany(timeout, events_per_sock)) {
            interruptNet.sleep_for(timeout);
        }

        // Service (send/receive) each of the already connected nodes.
        SocketHandlerConnected(snap.Nodes(), events_per_sock);
    }

    // Accept new connections from listening sockets.
    SocketHandlerListening(events_per_sock);
}

void CConnman::SocketHandlerConnected(const std::vector<CNode*>& nodes,
                                      const Sock::EventsPerSock& events_per_sock)
{
    AssertLockNotHeld(m_total_bytes_sent_mutex);

    for (CNode* pnode : nodes) {
        if (interruptNet)
            return;

        //
        // Receive
        //
        bool recvSet = false;
        bool sendSet = false;
        bool errorSet = false;
        {
            LOCK(pnode->m_sock_mutex);
            if (!pnode->m_sock) {
                continue;
            }
            const auto it = events_per_sock.find(pnode->m_sock);
            if (it != events_per_sock.end()) {
                recvSet = it->second.occurred & Sock::RECV;
                sendSet = it->second.occurred & Sock::SEND;
                errorSet = it->second.occurred & Sock::ERR;
            }
        }

        if (sendSet) {
            // Send data
            auto [bytes_sent, data_left] = WITH_LOCK(pnode->cs_vSend, return SocketSendData(*pnode));
            if (bytes_sent) {
                RecordBytesSent(bytes_sent);

                // If both receiving and (non-optimistic) sending were possible, we first attempt
                // sending. If that succeeds, but does not fully drain the send queue, do not
                // attempt to receive. This avoids needlessly queueing data if the remote peer
                // is slow at receiving data, by means of TCP flow control. We only do this when
                // sending actually succeeded to make sure progress is always made; otherwise a
                // deadlock would be possible when both sides have data to send, but neither is
                // receiving.
                if (data_left) recvSet = false;
            }
        }

        if (recvSet || errorSet)
        {
            // typical socket buffer is 8K-64K
            uint8_t pchBuf[0x10000];
            int nBytes = 0;
            {
                LOCK(pnode->m_sock_mutex);
                if (!pnode->m_sock) {
                    continue;
                }
                nBytes = pnode->m_sock->Recv(pchBuf, sizeof(pchBuf), MSG_DONTWAIT);
            }
            if (nBytes > 0)
            {
                bool notify = false;
                if (!pnode->ReceiveMsgBytes({pchBuf, (size_t)nBytes}, notify)) {
                    pnode->CloseSocketDisconnect();
                }
                RecordBytesRecv(nBytes);
                if (notify) {
                    pnode->MarkReceivedMsgsForProcessing();
                    WakeMessageHandler();
                }
            }
            else if (nBytes == 0)
            {
                // socket closed gracefully
                if (!pnode->fDisconnect) {
                    LogPrint(BCLog::NET, "socket closed for peer=%d\n", pnode->GetId());
                }
                pnode->CloseSocketDisconnect();
            }
            else if (nBytes < 0)
            {
                // error
                int nErr = WSAGetLastError();
                if (nErr != WSAEWOULDBLOCK && nErr != WSAEMSGSIZE && nErr != WSAEINTR && nErr != WSAEINPROGRESS)
                {
                    if (!pnode->fDisconnect) {
                        LogPrint(BCLog::NET, "socket recv error for peer=%d: %s\n", pnode->GetId(), NetworkErrorString(nErr));
                    }
                    pnode->CloseSocketDisconnect();
                }
            }
        }

        if (InactivityCheck(*pnode)) pnode->fDisconnect = true;
    }
}

void CConnman::SocketHandlerListening(const Sock::EventsPerSock& events_per_sock)
{
    for (const ListenSocket& listen_socket : vhListenSocket) {
        if (interruptNet) {
            return;
        }
        const auto it = events_per_sock.find(listen_socket.sock);
        if (it != events_per_sock.end() && it->second.occurred & Sock::RECV) {
            AcceptConnection(listen_socket);
        }
    }
}

void CConnman::ThreadSocketHandler()
{
    AssertLockNotHeld(m_total_bytes_sent_mutex);

    while (!interruptNet)
    {
        DisconnectNodes();
        NotifyNumConnectionsChanged();
        SocketHandler();
    }
}

void CConnman::WakeMessageHandler()
{
    {
        LOCK(mutexMsgProc);
        fMsgProcWake = true;
    }
    condMsgProc.notify_one();
}

void CConnman::ThreadHTTPSAddressSeed()
{
    FastRandomContext rng;
    const auto* hooks = m_https_seed_test_hooks;
    const auto worker_now = [&] { return hooks && hooks->now ? hooks->now() : qq::Clock::now(); };
    auto next_round = worker_now();
    if (addrman.Size()) {
        next_round += addrman.Size() >= DNSSEEDS_DELAY_PEER_THRESHOLD ?
            std::chrono::seconds{DNSSEEDS_DELAY_MANY_PEERS} : DNSSEEDS_DELAY_FEW_PEERS;
    }
    // Consecutive unproductive rounds (failed fetch, rejected body, no usable hint).
    size_t unproductive_rounds{0};
    // A round that ends without a usable hint is retried sooner (qq::HTTPS_BACKOFF),
    // then the normal cadence resumes. A round with at least one hint resets this.
    const auto unproductive = [&](const char* outcome) {
        auto retry = std::chrono::seconds{0};
        if (unproductive_rounds < qq::HTTPS_BACKOFF_STEPS) {
            retry = qq::HTTPS_BACKOFF[unproductive_rounds];
            next_round = worker_now() + retry;
        }
        ++unproductive_rounds;
        LogPrintf("HTTPS seed round: outcome=%s hints=0 retry_in=%ds\n", outcome,
                  retry.count() ? retry.count() : std::chrono::duration_cast<std::chrono::seconds>(next_round - worker_now()).count());
    };
    while (!interruptNet) {
        if (!(hooks && hooks->wait ? hooks->wait() : interruptNet.sleep_for(1s))) return;
        const bool ipv4 = g_reachable_nets.Contains(NET_IPV4);
        const bool ipv6 = g_reachable_nets.Contains(NET_IPV6);
        httpsseed::Policy policy{m_params.GetChainType() == ChainType::MAIN,
            m_https_seed_enabled, gArgs.GetBoolArg("-dnsseed", DEFAULT_DNSSEED),
            gArgs.GetBoolArg("-dns", DEFAULT_NAME_LOOKUP), m_use_addrman_outgoing,
            fNetworkActive, nMaxConnections, ipv4, ipv6};
        if (!httpsseed::Enabled(policy)) continue;
        const auto now = worker_now();
        if (now < next_round) continue;
        int connected{0};
        ForEachNode([&](CNode* node) { if (node->IsFullOutboundConn()) ++connected; });
        const bool deficit = GetQQStatus().deficit > 0;
        // Each provider owns its startup and refresh rounds. Healthy peers,
        // including peers found by DNS, must not suppress this source.
        next_round = now + qq::DNS_COOLDOWN + std::chrono::seconds{rng.randrange(300)};
        httpsseed::TransportOptions options;
        options.ipv4 = ipv4;
        options.ipv6 = ipv6;
        options.user_agent = "Blackcoin-Core/" + FormatFullVersion() + " HTTPSSeed/1";
        Proxy proxy, proxy4, proxy6;
        if (GetNameProxy(proxy)) {
            options.proxy = proxy;
        } else {
            const bool via4 = ipv4 && GetProxy(NET_IPV4, proxy4);
            const bool via6 = ipv6 && GetProxy(NET_IPV6, proxy6);
            // Do not invent a direct route for an ambiguous proxy topology.
            if (ipv4 && ipv6 && (via4 != via6 || (via4 &&
                (proxy4.proxy != proxy6.proxy || proxy4.randomize_credentials != proxy6.randomize_credentials)))) {
                LogPrint(BCLog::NET, "HTTPS discovery skipped: mixed proxy routes\n");
                continue;
            }
            if (via4 || via6) options.proxy = via4 ? proxy4 : proxy6;
        }
        policy.explicit_onlynet = gArgs.IsArgSet("-onlynet");
        policy.hostname_proxy = options.proxy.has_value();
        if (!httpsseed::Enabled(policy)) {
            LogPrint(BCLog::NET, "HTTPS discovery skipped: proxy cannot enforce explicit origin IP family\n");
            continue;
        }
        const auto generation = m_https_seed_generation.load();
        const auto cancelled = [&] { return interruptNet || !fNetworkActive ||
            m_https_seed_generation.load() != generation; };
        const auto response = hooks && hooks->fetch ? hooks->fetch(options, cancelled) : httpsseed::Fetch(options, cancelled);
        if (!response.success) {
            LogPrint(BCLog::NET, "HTTPS discovery failed: %s\n", response.error);
            if (!cancelled()) unproductive("fetch-failed");
            continue;
        }
        const auto parsed = httpsseed::Parse(response.body, TicksSinceEpoch<std::chrono::seconds>(NodeClock::now()),
            m_netgroupman, ipv4, ipv6, [](const CNetAddr& address) { return IsLocal(CService{address, 0}); });
        if (!parsed.valid) {
            LogPrint(BCLog::NET, "HTTPS discovery rejected: %s\n", parsed.error);
            unproductive("rejected");
            continue;
        }
        CNetAddr source;
        if (!source.SetInternal("httpsseed.projectblackcoin.org/v1")) continue;
        {
            LOCK(m_https_seed_mutex);
            if (cancelled()) continue;
            // Only address hints enter addrman. Live QQ state is P2P-owned.
            addrman.Add(parsed.peers, source);
        }
        LogPrint(BCLog::NET, "HTTPS discovery round: hints=%u qq_deficit=%d outage=%d\n",
            parsed.peers.size(), deficit, connected == 0);
        if (parsed.peers.empty()) {
            unproductive("accepted-empty");
        } else {
            unproductive_rounds = 0;
            LogPrintf("HTTPS seed round: outcome=accepted hints=%u retry_in=%ds\n", parsed.peers.size(),
                      std::chrono::duration_cast<std::chrono::seconds>(next_round - worker_now()).count());
        }
    }
}

void CConnman::ThreadDNSAddressSeed()
{
    FastRandomContext rng;
    const auto* hooks = m_dns_seed_test_hooks;
    const auto worker_now = [&] { return hooks && hooks->now ? hooks->now() : qq::Clock::now(); };
    auto next_round = worker_now();
    const bool independent_mainnet = m_params.GetChainType() == ChainType::MAIN;
    const bool forced = gArgs.GetBoolArg("-forcednsseed", DEFAULT_FORCEDNSSEED);
    if (addrman.Size() && !forced) {
        const auto delay = addrman.Size() >= DNSSEEDS_DELAY_PEER_THRESHOLD ? DNSSEEDS_DELAY_MANY_PEERS : DNSSEEDS_DELAY_FEW_PEERS;
        next_round += delay;
        LogPrint(BCLog::NET, "Waiting %d seconds before querying DNS seeds.\n", delay.count());
    }
    bool startup = true;
    while (!interruptNet) {
        if (!(hooks && hooks->wait ? hooks->wait() : interruptNet.sleep_for(1s))) return;
        if (!fNetworkActive || !m_use_addrman_outgoing ||
            !gArgs.GetBoolArg("-dnsseed", DEFAULT_DNSSEED) ||
            (independent_mainnet && nMaxConnections <= 0)) continue;
        const auto now = worker_now();
        if (now < next_round) continue;
        const auto status = GetQQStatus();
        int connected = 0;
        ForEachNode([&](CNode* node) { if (node->IsFullOutboundConn()) ++connected; });
        const bool deficit = status.deficit > 0;
        const bool outage = connected == 0;
        if (!independent_mainnet && !(startup && forced) && !outage && !deficit && (!startup || connected >= 2)) {
            if (startup) LogPrint(BCLog::NET, "P2P peers available. Skipped DNS seeding.\n");
            startup = false;
            continue;
        }
        // Coalesce overdue causes after suspension. Cooldown is never reset by a signal.
        next_round = now + qq::DNS_COOLDOWN + std::chrono::seconds{rng.randrange(300)};
        startup = false;
        if (deficit) RecordQQDNSRound();
        const auto generation = m_https_seed_generation.load();
        const auto cancelled = [&] { return interruptNet || !fNetworkActive || !m_use_addrman_outgoing ||
            !gArgs.GetBoolArg("-dnsseed", DEFAULT_DNSSEED) ||
            (independent_mainnet && m_https_seed_generation.load() != generation); };
        auto seeds = m_params.DNSSeeds();
        Shuffle(seeds.begin(), seeds.end(), rng);
        size_t queried = 0;
        for (const auto& seed : seeds) {
            if (queried >= DNSSEEDS_TO_QUERY_AT_ONCE || cancelled()) break;
            LogPrint(BCLog::NET, "Loading addresses from DNS seed %s\n", seed);
            // Name-proxy mode never performs local seed resolution, including QQ filters.
            if (HaveNameProxy()) {
                AddAddrFetch(seed);
                ++queried;
                continue;
            }
            // Do not leak direct seed queries in privacy-only configurations.
            if (!g_reachable_nets.Contains(NET_IPV4) && !g_reachable_nets.Contains(NET_IPV6)) break;
            ++queried;
            const auto base_services = GetDesirableServiceFlags(NODE_NONE);
            const auto query = [&](const std::string& host, ServiceFlags services) {
                CNetAddr source;
                if (!source.SetInternal(host)) return false;
                // -dns controls destination lookup; explicit -dnsseed controls
                // this resolver. No Core lock is held during system resolution.
                const auto addresses = LookupHost(host, 256, true);
                if (cancelled()) return false;
                std::vector<CAddress> addrs;
                for (const auto& ip : addresses) {
                    if (!g_reachable_nets.Contains(ip)) continue;
                    CAddress addr{CService(ip, m_params.GetDefaultPort()), services};
                    addr.nTime = rng.rand_uniform_delay(Now<NodeSeconds>() - 3 * 24h, -4 * 24h);
                    addrs.push_back(addr);
                }
                if (!addrs.empty()) {
                    LOCK(m_https_seed_mutex);
                    if (cancelled()) return false;
                    addrman.Add(addrs, source);
                }
                return !addrs.empty();
            };
            if (independent_mainnet) {
                // Always retain legacy-compatible discovery. QQ-filter misses
                // cannot replace or starve the base source. The plain hostname
                // is a legacy fallback when the service-filtered seed is empty.
                const bool base_found = query(strprintf("x%x.%s", base_services, seed), base_services);
                if (cancelled()) break;
                if (!base_found) query(seed, base_services);
                if (cancelled()) break;
                if (deficit) {
                    const auto qq_services = ServiceFlags(base_services | NODE_QUANTUM_QUASAR);
                    query(strprintf("x%x.%s", qq_services, seed), qq_services);
                }
            } else {
                const auto services = ServiceFlags(base_services | (deficit ? NODE_QUANTUM_QUASAR : NODE_NONE));
                if (!query(strprintf("x%x.%s", services, seed), services) && !interruptNet && fNetworkActive && m_use_addrman_outgoing) AddAddrFetch(seed);
            }
        }
        LogPrint(BCLog::NET, "DNS discovery round: providers=%u qq_deficit=%d outage=%d\n", queried, deficit, outage);
    }
}

void CConnman::DumpAddresses()
{
    const auto start{SteadyClock::now()};

    DumpPeerAddresses(::gArgs, addrman);

    LogPrint(BCLog::NET, "Flushed %d addresses to peers.dat  %dms\n",
             addrman.Size(), Ticks<std::chrono::milliseconds>(SteadyClock::now() - start));
}

void CConnman::ProcessAddrFetch()
{
    AssertLockNotHeld(m_unused_i2p_sessions_mutex);
    if (interruptNet || !fNetworkActive) return;

    // Keep discovery work queued until there is capacity to attempt it.
    CSemaphoreGrant grant(*semOutbound, /*fTry=*/true);
    if (!grant) return;

    std::string strDest;
    {
        LOCK(m_addr_fetches_mutex);
        if (interruptNet || !fNetworkActive || m_addr_fetches.empty())
            return;
        strDest = m_addr_fetches.front();
        m_addr_fetches.pop_front();
    }
    // Attempt v2 connection if we support v2 - we'll reconnect with v1 if our
    // peer doesn't support it or immediately disconnects us for another reason.
    const bool use_v2transport(GetLocalServices() & NODE_P2P_V2);
    CAddress addr;
    OpenNetworkConnection(addr, false, std::move(grant), strDest.c_str(), ConnectionType::ADDR_FETCH, use_v2transport);
}

bool CConnman::GetTryNewOutboundPeer() const
{
    return m_try_another_outbound_peer;
}

void CConnman::SetTryNewOutboundPeer(bool flag)
{
    m_try_another_outbound_peer = flag;
    LogPrint(BCLog::NET, "setting try another outbound peer=%s\n", flag ? "true" : "false");
}

void CConnman::StartExtraBlockRelayPeers()
{
    LogPrint(BCLog::NET, "enabling extra block-relay-only peers\n");
    m_start_extra_block_relay_peers = true;
}

// Return the number of peers we have over our outbound connection limit
// Exclude peers that are marked for disconnect, or are going to be
// disconnected soon (eg ADDR_FETCH and FEELER)
// Also exclude peers that haven't finished initial connection handshake yet
// (so that we don't decide we're over our desired connection limit, and then
// evict some peer that has finished the handshake)
int CConnman::GetFullOutboundCount() const
{
    LOCK(m_nodes_mutex);
    return std::count_if(m_nodes.begin(), m_nodes.end(), [](const CNode* node) {
        return node->IsFullOutboundConn() && !node->fDisconnect;
    });
}

int CConnman::GetExtraFullOutboundCount() const
{
    int full_outbound_peers = 0;
    {
        LOCK(m_nodes_mutex);
        for (const CNode* pnode : m_nodes) {
            if (pnode->fSuccessfullyConnected && !pnode->fDisconnect && pnode->IsFullOutboundConn()) {
                ++full_outbound_peers;
            }
        }
    }
    return std::max(full_outbound_peers - m_max_outbound_full_relay, 0);
}

int CConnman::GetExtraBlockRelayCount() const
{
    int block_relay_peers = 0;
    {
        LOCK(m_nodes_mutex);
        for (const CNode* pnode : m_nodes) {
            if (pnode->fSuccessfullyConnected && !pnode->fDisconnect && pnode->IsBlockOnlyConn()) {
                ++block_relay_peers;
            }
        }
    }
    return std::max(block_relay_peers - m_max_outbound_block_relay, 0);
}

std::unordered_set<Network> CConnman::GetReachableEmptyNetworks() const
{
    std::unordered_set<Network> networks{};
    for (int n = 0; n < NET_MAX; n++) {
        enum Network net = (enum Network)n;
        if (net == NET_UNROUTABLE || net == NET_INTERNAL) continue;
        if (g_reachable_nets.Contains(net) && addrman.Size(net, std::nullopt) == 0) {
            networks.insert(net);
        }
    }
    return networks;
}

bool CConnman::MultipleManualOrFullOutboundConns(Network net) const
{
    AssertLockHeld(m_nodes_mutex);
    return m_network_conn_counts[net] > 1;
}

bool CConnman::MaybePickPreferredNetwork(std::optional<Network>& network)
{
    std::array<Network, 5> nets{NET_IPV4, NET_IPV6, NET_ONION, NET_I2P, NET_CJDNS};
    Shuffle(nets.begin(), nets.end(), FastRandomContext());

    LOCK(m_nodes_mutex);
    for (const auto net : nets) {
        if (g_reachable_nets.Contains(net) && m_network_conn_counts[net] == 0 && addrman.Size(net) != 0) {
            network = net;
            return true;
        }
    }

    return false;
}

void CConnman::ThreadOpenConnections(const std::vector<std::string> connect)
{
    AssertLockNotHeld(m_unused_i2p_sessions_mutex);
    AssertLockNotHeld(m_reconnections_mutex);
    FastRandomContext rng;
    // Connect to specific addresses
    if (!connect.empty())
    {
        // Attempt v2 connection if we support v2 - we'll reconnect with v1 if our
        // peer doesn't support it or immediately disconnects us for another reason.
        const bool use_v2transport(GetLocalServices() & NODE_P2P_V2);
        for (int64_t nLoop = 0;; nLoop++)
        {
            for (const std::string& strAddr : connect)
            {
                CAddress addr(CService(), NODE_NONE);
                OpenNetworkConnection(addr, false, {}, strAddr.c_str(), ConnectionType::MANUAL, /*use_v2transport=*/use_v2transport);
                for (int i = 0; i < 10 && i < nLoop; i++)
                {
                    if (!interruptNet.sleep_for(std::chrono::milliseconds(500)))
                        return;
                }
            }
            if (!interruptNet.sleep_for(std::chrono::milliseconds(500)))
                return;
            PerformReconnections();
        }
    }

    // Initiate network connections
    auto start = GetTime<std::chrono::microseconds>();

    // Minimum time before next feeler connection (in microseconds).
    auto next_feeler = GetExponentialRand(start, FEELER_INTERVAL);
    auto next_extra_block_relay = GetExponentialRand(start, EXTRA_BLOCK_RELAY_ONLY_PEER_INTERVAL);
    auto next_extra_network_peer{GetExponentialRand(start, EXTRA_NETWORK_PEER_INTERVAL)};
    const bool dnsseed = gArgs.GetBoolArg("-dnsseed", DEFAULT_DNSSEED);
    bool add_fixed_seeds = gArgs.GetBoolArg("-fixedseeds", DEFAULT_FIXEDSEEDS);
    qq::Arbiter transient_arbiter;
    std::weak_ptr<qq::Probe> outstanding_qq;
    bool recovery_addr_fetch_turn{true};
    unsigned preferred_qq_attempts{0};
    bool tried_legacy_at_target{false};
    // Legacy-first dials that did not connect, with the time of the failure.
    std::map<CService, std::chrono::microseconds> legacy_failed;
    // Zero-peer diagnostics: window start and the dial counters at that moment.
    std::optional<std::chrono::microseconds> zero_peers_since;
    std::optional<std::chrono::microseconds> zero_peers_last_log;
    uint64_t zero_peers_attempts{0}, zero_peers_failures{0};
    const auto is_legacy_full_relay = [](const CNode& node) {
        return node.IsFullOutboundConn() && !node.IsQQProbe() && !(node.m_accepted_services & NODE_QUANTUM_QUASAR);
    };
    auto next_qq_probe = qq::Clock::now();
    const bool use_seednodes{gArgs.IsArgSet("-seednode")};

    if (!add_fixed_seeds) {
        LogPrintf("Fixed seeds are disabled\n");
    }

    while (!interruptNet)
    {
        if (!interruptNet.sleep_for(std::chrono::milliseconds(500)))
            return;

        PerformReconnections();

        {
            // One unconditional line when the node has had no peer for a minute,
            // at most once per ten minutes. No addresses.
            int live_peers{0};
            ForEachNode([&](const CNode* node) { if (node->fSuccessfullyConnected) ++live_peers; });
            const auto clock_now = GetTime<std::chrono::microseconds>();
            if (live_peers > 0) {
                zero_peers_since.reset();
            } else if (!zero_peers_since) {
                zero_peers_since = clock_now;
                zero_peers_attempts = m_dial_attempts;
                zero_peers_failures = m_dial_failures;
            } else if (clock_now - *zero_peers_since >= qq::ZERO_PEER_LOG_AFTER &&
                       (!zero_peers_last_log || clock_now - *zero_peers_last_log >= qq::ZERO_PEER_LOG_EVERY)) {
                zero_peers_last_log = clock_now;
                LogPrintf("No peers for %d seconds: addrman=%u dial_attempts=%u dial_failures=%u\n",
                          std::chrono::duration_cast<std::chrono::seconds>(clock_now - *zero_peers_since).count(),
                          addrman.Size(), m_dial_attempts - zero_peers_attempts, m_dial_failures - zero_peers_failures);
            }
        }

        // Queued v1 fallbacks retain their permits. Keep draining them even
        // when every outbound permit is held by a node or queued fallback.
        CSemaphoreGrant grant(*semOutbound, /*fTry=*/true);
        if (interruptNet)
            return;
        if (!fNetworkActive) continue;
        if (!grant) {
            // A successful legacy handshake can fill the final permit. Observe
            // that recovery so a subsequent loss gets a fresh legacy-first turn.
            if (tried_legacy_at_target) {
                ForEachNode([&](const CNode* node) {
                    if (is_legacy_full_relay(*node)) tried_legacy_at_target = false;
                });
            }
            continue;
        }

        const std::unordered_set<Network> fixed_seed_networks{GetReachableEmptyNetworks()};
        if (add_fixed_seeds && !fixed_seed_networks.empty()) {
            // When the node starts with an empty peers.dat, there are a few other sources of peers before
            // we fallback on to fixed seeds: -dnsseed, -seednode, -addnode
            // If none of those are available, we fallback on to fixed seeds immediately, else we allow
            // 60 seconds for any of those sources to populate addrman.
            bool add_fixed_seeds_now = false;
            // It is cheapest to check if enough time has passed first.
            if (GetTime<std::chrono::seconds>() > start + std::chrono::minutes{1}) {
                add_fixed_seeds_now = true;
                LogPrintf("Adding fixed seeds as 60 seconds have passed and addrman is empty for at least one reachable network\n");
            }

            // Perform cheap checks before locking a mutex.
            else if (!dnsseed && !use_seednodes) {
                LOCK(m_added_nodes_mutex);
                if (m_added_node_params.empty()) {
                    add_fixed_seeds_now = true;
                    LogPrintf("Adding fixed seeds as -dnsseed=0 (or IPv4/IPv6 connections are disabled via -onlynet) and neither -addnode nor -seednode are provided\n");
                }
            }

            if (add_fixed_seeds_now) {
                std::vector<CAddress> seed_addrs{ConvertSeeds(m_params.FixedSeeds())};
                // We will not make outgoing connections to peers that are unreachable
                // (e.g. because of -onlynet configuration).
                // Therefore, we do not add them to addrman in the first place.
                // In case previously unreachable networks become reachable
                // (e.g. in case of -onlynet changes by the user), fixed seeds will
                // be loaded only for networks for which we have no addresses.
                seed_addrs.erase(std::remove_if(seed_addrs.begin(), seed_addrs.end(),
                                                [&fixed_seed_networks](const CAddress& addr) { return fixed_seed_networks.count(addr.GetNetwork()) == 0; }),
                                 seed_addrs.end());
                CNetAddr local;
                local.SetInternal("fixedseeds");
                addrman.Add(seed_addrs, local);
                add_fixed_seeds = false;
                LogPrintf("Added %d fixed seeds from reachable networks.\n", seed_addrs.size());
            }
        }

        //
        // Choose an address to connect to based on most recently seen
        //
        CAddress addrConnect;

        // Only connect out to one peer per ipv4/ipv6 network group (/16 for IPv4).
        int nOutboundFullRelay = 0;
        int nOutboundBlockRelay = 0;
        int connected_full_relay{0};
        bool qq_peer_connected{false};
        bool has_legacy_full_relay{false};
        int outbound_privacy_network_peers = 0;
        std::set<std::vector<unsigned char>> outbound_ipv46_peer_netgroups;

        {
            LOCK(m_nodes_mutex);
            for (const CNode* pnode : m_nodes) {
                if (pnode->IsFullOutboundConn()) {
                    nOutboundFullRelay++;
                    has_legacy_full_relay |= NodeFullyConnected(pnode) && is_legacy_full_relay(*pnode);
                    if (NodeFullyConnected(pnode)) {
                        if (!pnode->IsQQProbe()) ++connected_full_relay;
                        qq_peer_connected |= static_cast<bool>(pnode->m_accepted_services & NODE_QUANTUM_QUASAR);
                    }
                }
                if (pnode->IsBlockOnlyConn()) nOutboundBlockRelay++;

                // Make sure our persistent outbound slots to ipv4/ipv6 peers belong to different netgroups.
                switch (pnode->m_conn_type) {
                    // We currently don't take inbound connections into account. Since they are
                    // free to make, an attacker could make them to prevent us from connecting to
                    // certain peers.
                    case ConnectionType::INBOUND:
                    // Short-lived outbound connections should not affect how we select outbound
                    // peers from addrman.
                    case ConnectionType::ADDR_FETCH:
                    case ConnectionType::FEELER:
                        break;
                    case ConnectionType::MANUAL:
                    case ConnectionType::OUTBOUND_FULL_RELAY:
                    case ConnectionType::BLOCK_RELAY:
                        const CAddress address{pnode->addr};
                        if (address.IsTor() || address.IsI2P() || address.IsCJDNS()) {
                            // Since our addrman-groups for these networks are
                            // random, without relation to the route we
                            // take to connect to these peers or to the
                            // difficulty in obtaining addresses with diverse
                            // groups, we don't worry about diversity with
                            // respect to our addrman groups when connecting to
                            // these networks.
                            ++outbound_privacy_network_peers;
                        } else {
                            outbound_ipv46_peer_netgroups.insert(m_netgroupman.GetGroup(address));
                        }
                } // no default case, so the compiler can warn about missing cases
            }
        }

        ConnectionType conn_type = ConnectionType::OUTBOUND_FULL_RELAY;
        auto now = GetTime<std::chrono::microseconds>();
        bool anchor = false;
        bool fFeeler = false;
        std::optional<Network> preferred_net;
        const auto qq_status = GetQQStatus();
        const auto steady_now = qq::Clock::now();
        const auto pending = outstanding_qq.lock();
        // The deficit cannot be met while the chain is not ready (IBD), so it
        // does not steer dialing unless a QQ peer is already connected.
        const bool chain_ready = qq_status.constraint != "chain-not-ready" && qq_status.constraint != "initializing";
        const bool qq_deficit = qq::EffectiveDeficit(qq_status.deficit, chain_ready, qq_peer_connected) > 0;
        if (!qq_deficit) preferred_qq_attempts = 0;
        const bool full_relay_vacancy = nOutboundFullRelay < m_max_outbound_full_relay;
        // Without recent proof that QQ peers are reachable, or below the floor
        // of connected full-relay peers, legacy addresses go first and QQ
        // pursuit does not shape the draws. Above the floor it may use only
        // the remaining vacancies; it never disconnects an established peer.
        const bool legacy_first = full_relay_vacancy &&
            qq::LegacyFirst(qq_status.target, connected_full_relay, m_max_outbound_full_relay,
                            qq_peer_connected || HasRecentQQHandshake(steady_now));
        const bool prefer_qq_for_vacancy = qq_deficit && full_relay_vacancy && !legacy_first;
        const bool seek_legacy_at_target = qq_status.target > 0 && !qq_deficit && !has_legacy_full_relay;
        if (!seek_legacy_at_target) tried_legacy_at_target = false;
        const bool legacy_turn = full_relay_vacancy &&
            ((prefer_qq_for_vacancy && preferred_qq_attempts >= 2) || (seek_legacy_at_target && !tried_legacy_at_target));
        const bool qq_probe_allowed = HasQQProbeHeadroom() &&
            qq_status.constraint != "chain-not-ready" && qq_status.constraint != "initializing";
        bool qq_probe = false;
        bool prefer_qq = prefer_qq_for_vacancy;
        bool addr_fetch_due;
        { LOCK(m_addr_fetches_mutex); addr_fetch_due = !m_addr_fetches.empty(); }

        // Determine what type of connection to open. Opening
        // BLOCK_RELAY connections to addresses from anchors.dat gets the highest
        // priority. Then we open OUTBOUND_FULL_RELAY priority until we
        // meet our full-relay capacity. Then we open BLOCK_RELAY connection
        // until we hit our block-relay-only peer limit.
        // GetTryNewOutboundPeer() gets set when a stale tip is detected, so we
        // try opening an additional OUTBOUND_FULL_RELAY connection. If none of
        // these conditions are met, check to see if it's time to try an extra
        // block-relay-only peer (to confirm our tip is current, see below) or the next_feeler
        // timer to decide if we should open a FEELER.

        if (!m_anchors.empty() && (nOutboundBlockRelay < m_max_outbound_block_relay)) {
            conn_type = ConnectionType::BLOCK_RELAY;
            anchor = true;
        } else if (addr_fetch_due && recovery_addr_fetch_turn &&
                   (nOutboundFullRelay < m_max_outbound_full_relay ||
                    nOutboundBlockRelay < m_max_outbound_block_relay)) {
            // Seed connections must also run before ordinary slots are full:
            // an empty addrman may depend on their response to fill any slot.
            // Alternate with ordinary recovery so neither class monopolizes it.
            recovery_addr_fetch_turn = false;
            grant.Release();
            ProcessAddrFetch();
            continue;
        } else if (nOutboundFullRelay < m_max_outbound_full_relay) {
            recovery_addr_fetch_turn = true;
            // OUTBOUND_FULL_RELAY
        } else if (nOutboundBlockRelay < m_max_outbound_block_relay) {
            recovery_addr_fetch_turn = true;
            conn_type = ConnectionType::BLOCK_RELAY;
        } else {
            // Six transient classes share existing semaphore headroom. Periodic
            // deadlines are consumed only when their class receives a permit.
            const bool network_due = nOutboundFullRelay == m_max_outbound_full_relay &&
                m_max_outbound_full_relay == MAX_OUTBOUND_FULL_RELAY_CONNECTIONS && now > next_extra_network_peer;
            const std::array<bool, qq::Arbiter::CLASSES> due{{
                now > next_feeler, addr_fetch_due, GetTryNewOutboundPeer(),
                now > next_extra_block_relay && m_start_extra_block_relay_peers,
                network_due, qq_deficit && qq_probe_allowed && steady_now >= next_qq_probe && (!pending || !pending->active)}};
            const int admitted = transient_arbiter.Pick(due);
            if (admitted < 0) continue;
            switch (admitted) {
            case 0:
                next_feeler = GetExponentialRand(now, FEELER_INTERVAL);
                conn_type = ConnectionType::FEELER;
                fFeeler = true;
                break;
            case 1:
                grant.Release();
                ProcessAddrFetch();
                continue;
            case 2: break; // Existing stale-tip request remains independently owned.
            case 3:
                next_extra_block_relay = GetExponentialRand(now, EXTRA_BLOCK_RELAY_ONLY_PEER_INTERVAL);
                conn_type = ConnectionType::BLOCK_RELAY;
                break;
            case 4:
                next_extra_network_peer = GetExponentialRand(now, EXTRA_NETWORK_PEER_INTERVAL);
                if (!MaybePickPreferredNetwork(preferred_net)) continue;
                break;
            case 5:
                qq_probe = prefer_qq = true;
                next_qq_probe = steady_now + qq::RETRY_INTERVAL + std::chrono::seconds{rng.randrange(30)};
                break;
            }
        }

        addrman.ResolveCollisions();

        const auto current_time{NodeClock::now()};
        int nTries = 0;
        CAddress qq_recovery_fallback;
        while (!interruptNet)
        {
            if (anchor && !m_anchors.empty()) {
                const CAddress addr = m_anchors.back();
                m_anchors.pop_back();
                if (!addr.IsValid() || IsLocal(addr) || !g_reachable_nets.Contains(addr) ||
                    !HasAllDesirableServiceFlags(addr.nServices) ||
                    outbound_ipv46_peer_netgroups.count(m_netgroupman.GetGroup(addr))) continue;
                addrConnect = addr;
                LogPrint(BCLog::NET, "Trying to make an anchor connection to %s\n", addrConnect.ToStringAddrPort());
                break;
            }

            // If we didn't find an appropriate destination after trying 100 addresses fetched from addrman,
            // stop this loop, and let the outer loop run again (which sleeps, adds seed nodes, recalculates
            // already-connected network ranges, ...) before trying new addrman addresses.
            nTries++;
            if (nTries > qq::MAX_CANDIDATE_DRAWS)
                break;

            CAddress addr;
            NodeSeconds addr_last_try{0s};

            if (fFeeler) {
                // First, try to get a tried table collision address. This returns
                // an empty (invalid) address if there are no collisions to try.
                std::tie(addr, addr_last_try) = addrman.SelectTriedCollision();

                if (!addr.IsValid()) {
                    // No tried table collisions. Select a new table address
                    // for our feeler.
                    std::tie(addr, addr_last_try) = addrman.Select(true);
                } else if (AlreadyConnectedToAddress(addr)) {
                    // If test-before-evict logic would have us connect to a
                    // peer that we're already connected to, just mark that
                    // address as Good(). We won't be able to initiate the
                    // connection anyway, so this avoids inadvertently evicting
                    // a currently-connected peer.
                    addrman.Good(addr);
                    // Select a new table address for our feeler instead.
                    std::tie(addr, addr_last_try) = addrman.Select(true);
                }
            } else {
                // Not a feeler
                // If preferred_net has a value set, pick an extra outbound
                // peer from that network. The eviction logic in net_processing
                // ensures that a peer from another network will be evicted.
                std::tie(addr, addr_last_try) = addrman.Select(false, preferred_net);
            }

            // Require outbound IPv4/IPv6 connections, other than feelers, to be to distinct network groups
            if (!fFeeler && outbound_ipv46_peer_netgroups.count(m_netgroupman.GetGroup(addr))) {
                continue;
            }

            // if we selected an invalid or local address, restart
            if (!addr.IsValid() || IsLocal(addr)) {
                break;
            }

            if (!g_reachable_nets.Contains(addr)) {
                continue;
            }

            // only consider very recently tried nodes after 30 failed attempts
            if (current_time - addr_last_try < 10min && nTries < 30) {
                continue;
            }

            // for non-feelers, require all the services we'll want,
            // for feelers, only require they be a full node (only because most
            // SPV clients don't have a good address DB available)
            if (!fFeeler && !HasAllDesirableServiceFlags(addr.nServices)) {
                continue;
            } else if (fFeeler && !MayHaveUsefulAddressDB(addr.nServices)) {
                continue;
            }

            // Do not connect to bad ports, unless 50 invalid addresses have been selected already.
            if (nTries < 50 && (addr.IsIPv4() || addr.IsIPv6()) && IsBadPort(addr.GetPort())) {
                continue;
            }

            // Do not make automatic outbound connections to addnode peers, to
            // not use our limited outbound slots for them and to ensure
            // addnode connections benefit from their intended protections.
            if (AddedNodesContain(addr)) {
                LogPrintLevel(BCLog::NET, BCLog::Level::Debug, "Not making automatic %s%s connection to %s peer selected for manual (addnode) connection%s\n",
                              preferred_net.has_value() ? "network-specific " : "",
                              ConnectionTypeAsString(conn_type), GetNetworkName(addr.GetNetwork()),
                              fLogIPs ? strprintf(": %s", addr.ToStringAddrPort()) : "");
                continue;
            }

            // Legacy-first: QQ-flagged hints wait until the later draws, and a legacy
            // address that just failed a dial yields to them, so one dead legacy entry
            // cannot monopolize a vacancy.
            if (legacy_first && conn_type == ConnectionType::OUTBOUND_FULL_RELAY && !qq_probe &&
                nTries <= qq::MAX_CANDIDATE_DRAWS / 2) {
                if (addr.nServices & NODE_QUANTUM_QUASAR) continue;
                const auto failed = legacy_failed.find(addr);
                if (failed != legacy_failed.end() && now - failed->second < qq::LEGACY_FIRST_FAILED_MEMORY) continue;
            }

            // Give legacy addresses a turn after two QQ attempts, or when
            // replenishing without a legacy relay after reaching the QQ target.
            // Keep a fully checked fallback for QQ-only pools.
            if (legacy_turn && conn_type == ConnectionType::OUTBOUND_FULL_RELAY) {
                if (addr.nServices & NODE_QUANTUM_QUASAR) {
                    if (!qq_recovery_fallback.IsValid()) qq_recovery_fallback = addr;
                    continue;
                }
            } else if (prefer_qq && (qq_probe || nTries <= qq::MAX_CANDIDATE_DRAWS / 2) && !(addr.nServices & NODE_QUANTUM_QUASAR)) continue;
            addrConnect = addr;
            break;
        }

        if (!addrConnect.IsValid() && qq_recovery_fallback.IsValid()) addrConnect = qq_recovery_fallback;
        if (qq_probe) RecordQQSelection(nTries, addrConnect.IsValid());
        if (addrConnect.IsValid()) {
            if (fFeeler) {
                // Add small amount of random noise before connection to avoid synchronization.
                if (!interruptNet.sleep_for(rng.rand_uniform_duration<CThreadInterrupt::Clock>(FEELER_SLEEP_WINDOW))) {
                    return;
                }
                LogPrint(BCLog::NET, "Making feeler connection to %s\n", addrConnect.ToStringAddrPort());
            }

            if (preferred_net != std::nullopt) LogPrint(BCLog::NET, "Making network specific connection to %s on %s.\n", addrConnect.ToStringAddrPort(), GetNetworkName(preferred_net.value()));

            // Record addrman failure attempts when node has at least 2 persistent outbound connections to peers with
            // different netgroups in ipv4/ipv6 networks + all peers in Tor/I2P/CJDNS networks.
            // Don't record addrman failure attempts when node is offline. This can be identified since all local
            // network connections (if any) belong in the same netgroup, and the size of `outbound_ipv46_peer_netgroups` would only be 1.
            const bool count_failures{((int)outbound_ipv46_peer_netgroups.size() + outbound_privacy_network_peers) >= std::min(nMaxConnections - 1, 2)};
            // Use BIP324 transport when both us and them have NODE_V2_P2P set.
            const bool use_v2transport(addrConnect.nServices & GetLocalServices() & NODE_P2P_V2);
            std::shared_ptr<qq::Probe> probe;
            if (qq_probe) {
                probe = std::make_shared<qq::Probe>(qq::Clock::now());
                outstanding_qq = probe;
                TrackQQProbe(probe);
            }
            bool attempted{false};
            OpenNetworkConnection(addrConnect, count_failures, std::move(grant), /*strDest=*/nullptr, conn_type, use_v2transport, std::move(probe), &attempted);
            if (attempted && legacy_first && conn_type == ConnectionType::OUTBOUND_FULL_RELAY &&
                !(addrConnect.nServices & NODE_QUANTUM_QUASAR) && !AlreadyConnectedToAddress(addrConnect)) {
                if (legacy_failed.size() >= 64) legacy_failed.erase(legacy_failed.begin());
                legacy_failed[addrConnect] = now;
            }
            if (attempted && full_relay_vacancy && conn_type == ConnectionType::OUTBOUND_FULL_RELAY) {
                const bool qq_hint = addrConnect.nServices & NODE_QUANTUM_QUASAR;
                if (prefer_qq_for_vacancy) {
                    preferred_qq_attempts = qq_hint ? std::min(preferred_qq_attempts + 1, 2U) : 0;
                }
                // A stale legacy hint must not monopolize a vacancy when
                // the only reachable peers advertise QQ.
                if (seek_legacy_at_target) tried_legacy_at_target = !qq_hint;
            }
        }
    }
}

std::vector<CAddress> CConnman::GetCurrentBlockRelayOnlyConns() const
{
    std::vector<CAddress> ret;
    LOCK(m_nodes_mutex);
    for (const CNode* pnode : m_nodes) {
        if (pnode->IsBlockOnlyConn()) {
            ret.push_back(pnode->addr);
        }
    }

    return ret;
}

std::vector<AddedNodeInfo> CConnman::GetAddedNodeInfo() const
{
    std::vector<AddedNodeInfo> ret;

    std::list<AddedNodeParams> lAddresses(0);
    {
        LOCK(m_added_nodes_mutex);
        ret.reserve(m_added_node_params.size());
        std::copy(m_added_node_params.cbegin(), m_added_node_params.cend(), std::back_inserter(lAddresses));
    }


    // Build a map of all already connected addresses (by IP:port and by name) to inbound/outbound and resolved CService
    std::map<CService, bool> mapConnected;
    std::map<std::string, std::pair<bool, CService>> mapConnectedByName;
    {
        LOCK(m_nodes_mutex);
        for (const CNode* pnode : m_nodes) {
            if (pnode->addr.IsValid()) {
                mapConnected[pnode->addr] = pnode->IsInboundConn();
            }
            std::string addrName{pnode->m_addr_name};
            if (!addrName.empty()) {
                mapConnectedByName[std::move(addrName)] = std::make_pair(pnode->IsInboundConn(), static_cast<const CService&>(pnode->addr));
            }
        }
    }

    for (const auto& addr : lAddresses) {
        CService service{MaybeFlipIPv6toCJDNS(LookupNumeric(addr.m_added_node, GetDefaultPort(addr.m_added_node)))};
        AddedNodeInfo addedNode{addr, CService(), false, false};
        if (service.IsValid()) {
            // strAddNode is an IP:port
            auto it = mapConnected.find(service);
            if (it != mapConnected.end()) {
                addedNode.resolvedAddress = service;
                addedNode.fConnected = true;
                addedNode.fInbound = it->second;
            }
        } else {
            // strAddNode is a name
            auto it = mapConnectedByName.find(addr.m_added_node);
            if (it != mapConnectedByName.end()) {
                addedNode.resolvedAddress = it->second.second;
                addedNode.fConnected = true;
                addedNode.fInbound = it->second.first;
            }
        }
        ret.emplace_back(std::move(addedNode));
    }

    return ret;
}

void CConnman::ThreadOpenAddedConnections()
{
    AssertLockNotHeld(m_unused_i2p_sessions_mutex);
    AssertLockNotHeld(m_reconnections_mutex);
    while (true)
    {
        // A queued fallback can own the last addnode permit, so do not block
        // this worker before it can reach PerformReconnections().
        CSemaphoreGrant grant(*semAddnode, /*fTry=*/true);
        std::vector<AddedNodeInfo> vInfo = GetAddedNodeInfo();
        bool tried = false;
        for (const AddedNodeInfo& info : vInfo) {
            if (!info.fConnected) {
                if (!grant) {
                    // If we've used up our semaphore and need a new one, let's not wait here since while we are waiting
                    // the addednodeinfo state might change.
                    break;
                }
                tried = true;
                CAddress addr(CService(), NODE_NONE);
                OpenNetworkConnection(addr, false, std::move(grant), info.m_params.m_added_node.c_str(), ConnectionType::MANUAL, info.m_params.m_use_v2transport);
                if (!interruptNet.sleep_for(std::chrono::milliseconds(500))) return;
                grant = CSemaphoreGrant(*semAddnode, /*fTry=*/true);
            }
        }
        // See if any reconnections are desired.
        PerformReconnections();
        // Retry every 60 seconds if a connection was attempted, otherwise two seconds
        if (!interruptNet.sleep_for(std::chrono::seconds(tried ? 60 : 2)))
            return;
    }
}

// if successful, this moves the passed grant to the constructed node
void CConnman::OpenNetworkConnection(const CAddress& addrConnect, bool fCountFailure, CSemaphoreGrant&& grant_outbound, const char *pszDest, ConnectionType conn_type, bool use_v2transport, std::shared_ptr<qq::Probe> qq_probe, bool* attempted)
{
    if (attempted) *attempted = false;
    AssertLockNotHeld(m_unused_i2p_sessions_mutex);
    assert(conn_type != ConnectionType::INBOUND);

    //
    // Initiate outbound network connection
    //
    if (interruptNet || (qq_probe && (qq_probe->Expired(qq::Clock::now()) || !m_use_addrman_outgoing))) {
        return;
    }
    if (!fNetworkActive) {
        return;
    }
    if (!pszDest) {
        bool banned_or_discouraged = m_banman && (m_banman->IsDiscouraged(addrConnect) || m_banman->IsBanned(addrConnect));
        if (IsLocal(addrConnect) || banned_or_discouraged || AlreadyConnectedToAddress(addrConnect)) {
            return;
        }
    } else if (FindNode(std::string(pszDest)))
        return;

    bool connection_attempted{false};
    CNode* pnode = ConnectNode(addrConnect, pszDest, fCountFailure, conn_type, use_v2transport, connection_attempted);
    if (attempted) *attempted = connection_attempted;
    if (connection_attempted) {
        ++m_dial_attempts;
        if (!pnode) ++m_dial_failures;
    }
    if (qq_probe) RecordQQConnect(pnode == nullptr);

    if (!pnode)
        return;
    pnode->grantOutbound = std::move(grant_outbound);
    pnode->m_qq_probe = std::move(qq_probe);

    m_msgproc->InitializeNode(*pnode, nLocalServices);
    {
        LOCK(m_nodes_mutex);
        m_nodes.push_back(pnode);

        // update connection count by network
        if (pnode->IsManualOrFullOutboundConn()) ++m_network_conn_counts[pnode->addr.GetNetwork()];
    }
}

Mutex NetEventsInterface::g_msgproc_mutex;

void CConnman::ThreadMessageHandler()
{
    LOCK(NetEventsInterface::g_msgproc_mutex);

    while (!flagInterruptMsgProc)
    {
        bool fMoreWork = false;

        {
            // Randomize the order in which we process messages from/to our peers.
            // This prevents attacks in which an attacker exploits having multiple
            // consecutive connections in the m_nodes list.
            const NodesSnapshot snap{*this, /*shuffle=*/true};

            for (CNode* pnode : snap.Nodes()) {
                if (pnode->fDisconnect)
                    continue;

                // Receive messages
                bool fMoreNodeWork = m_msgproc->ProcessMessages(pnode, flagInterruptMsgProc);
                fMoreWork |= (fMoreNodeWork && !pnode->fPauseSend);
                if (flagInterruptMsgProc)
                    return;
                // Send messages
                m_msgproc->SendMessages(pnode);

                if (flagInterruptMsgProc)
                    return;
            }
        }

        WAIT_LOCK(mutexMsgProc, lock);
        if (!fMoreWork) {
            condMsgProc.wait_until(lock, std::chrono::steady_clock::now() + std::chrono::milliseconds(100), [this]() EXCLUSIVE_LOCKS_REQUIRED(mutexMsgProc) { return fMsgProcWake; });
        }
        fMsgProcWake = false;
    }
}

void CConnman::ThreadI2PAcceptIncoming()
{
    static constexpr auto err_wait_begin = 1s;
    static constexpr auto err_wait_cap = 5min;
    auto err_wait = err_wait_begin;

    bool advertising_listen_addr = false;
    i2p::Connection conn;

    auto SleepOnFailure = [&]() {
        interruptNet.sleep_for(err_wait);
        if (err_wait < err_wait_cap) {
            err_wait += 1s;
        }
    };

    while (!interruptNet) {

        if (!m_i2p_sam_session->Listen(conn)) {
            if (advertising_listen_addr && conn.me.IsValid()) {
                RemoveLocal(conn.me);
                advertising_listen_addr = false;
            }
            SleepOnFailure();
            continue;
        }

        if (!advertising_listen_addr) {
            AddLocal(conn.me, LOCAL_MANUAL);
            advertising_listen_addr = true;
        }

        if (!m_i2p_sam_session->Accept(conn)) {
            SleepOnFailure();
            continue;
        }

        CreateNodeFromAcceptedSocket(std::move(conn.sock), NetPermissionFlags::None,
                                     CAddress{conn.me, NODE_NONE}, CAddress{conn.peer, NODE_NONE});

        err_wait = err_wait_begin;
    }
}

bool CConnman::BindListenPort(const CService& addrBind, bilingual_str& strError, NetPermissionFlags permissions)
{
    int nOne = 1;

    // Create socket for listening for incoming connections
    struct sockaddr_storage sockaddr;
    socklen_t len = sizeof(sockaddr);
    if (!addrBind.GetSockAddr((struct sockaddr*)&sockaddr, &len))
    {
        strError = strprintf(Untranslated("Bind address family for %s not supported"), addrBind.ToStringAddrPort());
        LogPrintLevel(BCLog::NET, BCLog::Level::Error, "%s\n", strError.original);
        return false;
    }

    std::unique_ptr<Sock> sock = CreateSock(addrBind);
    if (!sock) {
        strError = strprintf(Untranslated("Couldn't open socket for incoming connections (socket returned error %s)"), NetworkErrorString(WSAGetLastError()));
        LogPrintLevel(BCLog::NET, BCLog::Level::Error, "%s\n", strError.original);
        return false;
    }

    // Allow binding if the port is still in TIME_WAIT state after
    // the program was closed and restarted.
    if (sock->SetSockOpt(SOL_SOCKET, SO_REUSEADDR, (sockopt_arg_type)&nOne, sizeof(int)) == SOCKET_ERROR) {
        strError = strprintf(Untranslated("Error setting SO_REUSEADDR on socket: %s, continuing anyway"), NetworkErrorString(WSAGetLastError()));
        LogPrintf("%s\n", strError.original);
    }

    // some systems don't have IPV6_V6ONLY but are always v6only; others do have the option
    // and enable it by default or not. Try to enable it, if possible.
    if (addrBind.IsIPv6()) {
#ifdef IPV6_V6ONLY
        if (sock->SetSockOpt(IPPROTO_IPV6, IPV6_V6ONLY, (sockopt_arg_type)&nOne, sizeof(int)) == SOCKET_ERROR) {
            strError = strprintf(Untranslated("Error setting IPV6_V6ONLY on socket: %s, continuing anyway"), NetworkErrorString(WSAGetLastError()));
            LogPrintf("%s\n", strError.original);
        }
#endif
#ifdef WIN32
        int nProtLevel = PROTECTION_LEVEL_UNRESTRICTED;
        if (sock->SetSockOpt(IPPROTO_IPV6, IPV6_PROTECTION_LEVEL, (const char*)&nProtLevel, sizeof(int)) == SOCKET_ERROR) {
            strError = strprintf(Untranslated("Error setting IPV6_PROTECTION_LEVEL on socket: %s, continuing anyway"), NetworkErrorString(WSAGetLastError()));
            LogPrintf("%s\n", strError.original);
        }
#endif
    }

    if (sock->Bind(reinterpret_cast<struct sockaddr*>(&sockaddr), len) == SOCKET_ERROR) {
        int nErr = WSAGetLastError();
        if (nErr == WSAEADDRINUSE)
            strError = strprintf(_("Unable to bind to %s on this computer. %s is probably already running."), addrBind.ToStringAddrPort(), PACKAGE_NAME);
        else
            strError = strprintf(_("Unable to bind to %s on this computer (bind returned error %s)"), addrBind.ToStringAddrPort(), NetworkErrorString(nErr));
        LogPrintLevel(BCLog::NET, BCLog::Level::Error, "%s\n", strError.original);
        return false;
    }
    LogPrintf("Bound to %s\n", addrBind.ToStringAddrPort());

    // Listen for incoming connections
    if (sock->Listen(SOMAXCONN) == SOCKET_ERROR)
    {
        strError = strprintf(_("Listening for incoming connections failed (listen returned error %s)"), NetworkErrorString(WSAGetLastError()));
        LogPrintLevel(BCLog::NET, BCLog::Level::Error, "%s\n", strError.original);
        return false;
    }

    vhListenSocket.emplace_back(std::move(sock), permissions);
    return true;
}

void Discover()
{
    if (!fDiscover)
        return;

#ifdef WIN32
    // Get local host IP
    char pszHostName[256] = "";
    if (gethostname(pszHostName, sizeof(pszHostName)) != SOCKET_ERROR)
    {
        const std::vector<CNetAddr> addresses{LookupHost(pszHostName, 0, true)};
        for (const CNetAddr& addr : addresses)
        {
            if (AddLocal(addr, LOCAL_IF))
                LogPrintf("%s: %s - %s\n", __func__, pszHostName, addr.ToStringAddr());
        }
    }
#elif (HAVE_DECL_GETIFADDRS && HAVE_DECL_FREEIFADDRS)
    // Get local host ip
    struct ifaddrs* myaddrs;
    if (getifaddrs(&myaddrs) == 0)
    {
        for (struct ifaddrs* ifa = myaddrs; ifa != nullptr; ifa = ifa->ifa_next)
        {
            if (ifa->ifa_addr == nullptr) continue;
            if ((ifa->ifa_flags & IFF_UP) == 0) continue;
            if (strcmp(ifa->ifa_name, "lo") == 0) continue;
            if (strcmp(ifa->ifa_name, "lo0") == 0) continue;
            if (ifa->ifa_addr->sa_family == AF_INET)
            {
                struct sockaddr_in* s4 = (struct sockaddr_in*)(ifa->ifa_addr);
                CNetAddr addr(s4->sin_addr);
                if (AddLocal(addr, LOCAL_IF))
                    LogPrintf("%s: IPv4 %s: %s\n", __func__, ifa->ifa_name, addr.ToStringAddr());
            }
            else if (ifa->ifa_addr->sa_family == AF_INET6)
            {
                struct sockaddr_in6* s6 = (struct sockaddr_in6*)(ifa->ifa_addr);
                CNetAddr addr(s6->sin6_addr);
                if (AddLocal(addr, LOCAL_IF))
                    LogPrintf("%s: IPv6 %s: %s\n", __func__, ifa->ifa_name, addr.ToStringAddr());
            }
        }
        freeifaddrs(myaddrs);
    }
#endif
}

void CConnman::SetNetworkActive(bool active)
{
    LogPrintf("%s: %s\n", __func__, active);
    {
        LOCK(m_https_seed_mutex);
        if (fNetworkActive == active) return;
        // A quick false->true toggle must still invalidate the older transfer.
        ++m_https_seed_generation;
        fNetworkActive = active;
    }
    if (m_client_interface) {
        m_client_interface->NotifyNetworkActiveChanged(fNetworkActive);
    }
}

CConnman::CConnman(uint64_t nSeed0In, uint64_t nSeed1In, AddrMan& addrman_in,
                   const NetGroupManager& netgroupman, const CChainParams& params, bool network_active)
    : addrman(addrman_in)
    , m_netgroupman{netgroupman}
    , nSeed0(nSeed0In)
    , nSeed1(nSeed1In)
    , m_params(params)
{
    SetTryNewOutboundPeer(false);

    Options connOptions;
    Init(connOptions);
    SetNetworkActive(network_active);
}

NodeId CConnman::GetNewNodeId()
{
    return nLastNodeId.fetch_add(1, std::memory_order_relaxed);
}

uint16_t CConnman::GetDefaultPort(Network net) const
{
    return net == NET_I2P ? I2P_SAM31_PORT : m_params.GetDefaultPort();
}

uint16_t CConnman::GetDefaultPort(const std::string& addr) const
{
    CNetAddr a;
    return a.SetSpecial(addr) ? GetDefaultPort(a.GetNetwork()) : m_params.GetDefaultPort();
}

bool CConnman::Bind(const CService& addr_, unsigned int flags, NetPermissionFlags permissions)
{
    const CService addr{MaybeFlipIPv6toCJDNS(addr_)};

    bilingual_str strError;
    if (!BindListenPort(addr, strError, permissions)) {
        if ((flags & BF_REPORT_ERROR) && m_client_interface) {
            m_client_interface->ThreadSafeMessageBox(strError, "", CClientUIInterface::MSG_ERROR);
        }
        return false;
    }

    if (addr.IsRoutable() && fDiscover && !(flags & BF_DONT_ADVERTISE) && !NetPermissions::HasFlag(permissions, NetPermissionFlags::NoBan)) {
        AddLocal(addr, LOCAL_BIND);
    }

    return true;
}

bool CConnman::InitBinds(const Options& options)
{
    bool fBound = false;
    for (const auto& addrBind : options.vBinds) {
        fBound |= Bind(addrBind, BF_REPORT_ERROR, NetPermissionFlags::None);
    }
    for (const auto& addrBind : options.vWhiteBinds) {
        fBound |= Bind(addrBind.m_service, BF_REPORT_ERROR, addrBind.m_flags);
    }
    for (const auto& addr_bind : options.onion_binds) {
        fBound |= Bind(addr_bind, BF_DONT_ADVERTISE, NetPermissionFlags::None);
    }
    if (options.bind_on_any) {
        struct in_addr inaddr_any;
        inaddr_any.s_addr = htonl(INADDR_ANY);
        struct in6_addr inaddr6_any = IN6ADDR_ANY_INIT;
        fBound |= Bind(CService(inaddr6_any, GetListenPort()), BF_NONE, NetPermissionFlags::None);
        fBound |= Bind(CService(inaddr_any, GetListenPort()), !fBound ? BF_REPORT_ERROR : BF_NONE, NetPermissionFlags::None);
    }
    return fBound;
}

bool CConnman::Start(CScheduler& scheduler, const Options& connOptions)
{
    AssertLockNotHeld(m_total_bytes_sent_mutex);
    Init(connOptions);

    if (fListen && !InitBinds(connOptions)) {
        if (m_client_interface) {
            m_client_interface->ThreadSafeMessageBox(
                _("Failed to listen on any port. Use -listen=0 if you want this."),
                "", CClientUIInterface::MSG_ERROR);
        }
        return false;
    }

    Proxy i2p_sam;
    if (GetProxy(NET_I2P, i2p_sam) && connOptions.m_i2p_accept_incoming) {
        m_i2p_sam_session = std::make_unique<i2p::sam::Session>(gArgs.GetDataDirNet() / "i2p_private_key",
                                                                i2p_sam.proxy, &interruptNet);
    }

    for (const auto& strDest : connOptions.vSeedNodes) {
        AddAddrFetch(strDest);
    }

    if (m_use_addrman_outgoing) {
        // Load addresses from anchors.dat
        m_anchors = ReadAnchors(gArgs.GetDataDirNet() / ANCHORS_DATABASE_FILENAME);
        if (m_anchors.size() > MAX_BLOCK_RELAY_ONLY_ANCHORS) {
            m_anchors.resize(MAX_BLOCK_RELAY_ONLY_ANCHORS);
        }
        LogPrintf("%i block-relay-only anchors will be tried for connections.\n", m_anchors.size());
    }

    if (m_client_interface) {
        m_client_interface->InitMessage(_("Starting network threads…").translated);
    }

    fAddressesInitialized = true;

    if (semOutbound == nullptr) {
        // initialize semaphore
        semOutbound = std::make_unique<CSemaphore>(std::min(m_max_outbound, nMaxConnections));
    }
    if (semAddnode == nullptr) {
        // initialize semaphore
        semAddnode = std::make_unique<CSemaphore>(nMaxAddnode);
    }

    //
    // Start threads
    //
    assert(m_msgproc);
    InterruptSocks5(false);
    interruptNet.reset();
    flagInterruptMsgProc = false;

    {
        LOCK(mutexMsgProc);
        fMsgProcWake = false;
    }

    // Send and receive from sockets, accept connections
    threadSocketHandler = std::thread(&util::TraceThread, "net", [this] { ThreadSocketHandler(); });

    if (!gArgs.GetBoolArg("-dnsseed", DEFAULT_DNSSEED))
        LogPrintf("DNS seeding disabled\n");
    else
        threadDNSAddressSeed = std::thread(&util::TraceThread, "dnsseed", [this] { ThreadDNSAddressSeed(); });

    if (m_https_seed_enabled && m_params.GetChainType() == ChainType::MAIN && m_use_addrman_outgoing && nMaxConnections > 0) {
        if (httpsseed::InitializeTransport()) {
            threadHTTPSAddressSeed = std::thread(&util::TraceThread, "httpsseed", [this] { ThreadHTTPSAddressSeed(); });
        } else {
            LogPrintf("HTTPS discovery unavailable: TLS transport initialization failed\n");
        }
    }

    // Initiate manual connections
    threadOpenAddedConnections = std::thread(&util::TraceThread, "addcon", [this] { ThreadOpenAddedConnections(); });

    if (connOptions.m_use_addrman_outgoing && !connOptions.m_specified_outgoing.empty()) {
        if (m_client_interface) {
            m_client_interface->ThreadSafeMessageBox(
                _("Cannot provide specific connections and have addrman find outgoing connections at the same time."),
                "", CClientUIInterface::MSG_ERROR);
        }
        return false;
    }
    if (connOptions.m_use_addrman_outgoing || !connOptions.m_specified_outgoing.empty()) {
        threadOpenConnections = std::thread(
            &util::TraceThread, "opencon",
            [this, connect = connOptions.m_specified_outgoing] { ThreadOpenConnections(connect); });
    }

    // Process messages
    threadMessageHandler = std::thread(&util::TraceThread, "msghand", [this] { ThreadMessageHandler(); });

    if (m_i2p_sam_session) {
        threadI2PAcceptIncoming =
            std::thread(&util::TraceThread, "i2paccept", [this] { ThreadI2PAcceptIncoming(); });
    }

    // Dump network addresses
    scheduler.scheduleEvery([this] { DumpAddresses(); }, DUMP_PEERS_INTERVAL);

    return true;
}

class CNetCleanup
{
public:
    CNetCleanup() = default;

    ~CNetCleanup()
    {
#ifdef WIN32
        // Shutdown Windows Sockets
        WSACleanup();
#endif
    }
};
static CNetCleanup instance_of_cnetcleanup;

void CConnman::Interrupt()
{
    {
        LOCK(mutexMsgProc);
        flagInterruptMsgProc = true;
    }
    condMsgProc.notify_all();

    interruptNet();
    InterruptSocks5(true);

    if (semOutbound) {
        for (int i=0; i<m_max_outbound; i++) {
            semOutbound->post();
        }
    }

    if (semAddnode) {
        for (int i=0; i<nMaxAddnode; i++) {
            semAddnode->post();
        }
    }
}

void CConnman::StopThreads()
{
    if (threadI2PAcceptIncoming.joinable()) {
        threadI2PAcceptIncoming.join();
    }
    if (threadMessageHandler.joinable())
        threadMessageHandler.join();
    if (threadOpenConnections.joinable())
        threadOpenConnections.join();
    if (threadOpenAddedConnections.joinable())
        threadOpenAddedConnections.join();
    if (threadHTTPSAddressSeed.joinable())
        threadHTTPSAddressSeed.join();
    if (threadDNSAddressSeed.joinable())
        threadDNSAddressSeed.join();
    if (threadSocketHandler.joinable())
        threadSocketHandler.join();
}

void CConnman::StopNodes()
{
    if (fAddressesInitialized) {
        DumpAddresses();
        fAddressesInitialized = false;

        if (m_use_addrman_outgoing) {
            // Anchor connections are only dumped during clean shutdown.
            std::vector<CAddress> anchors_to_dump = GetCurrentBlockRelayOnlyConns();
            if (anchors_to_dump.size() > MAX_BLOCK_RELAY_ONLY_ANCHORS) {
                anchors_to_dump.resize(MAX_BLOCK_RELAY_ONLY_ANCHORS);
            }
            DumpAnchors(gArgs.GetDataDirNet() / ANCHORS_DATABASE_FILENAME, anchors_to_dump);
        }
    }

    // Delete peer connections.
    std::vector<CNode*> nodes;
    WITH_LOCK(m_nodes_mutex, nodes.swap(m_nodes));
    for (CNode* pnode : nodes) {
        pnode->CloseSocketDisconnect();
        DeleteNode(pnode);
    }

    for (CNode* pnode : m_nodes_disconnected) {
        DeleteNode(pnode);
    }
    m_nodes_disconnected.clear();
    vhListenSocket.clear();
    // Queued fallbacks own grants too. Return them before destroying either
    // semaphore, including shutdown while networking is paused.
    WITH_LOCK(m_reconnections_mutex, m_reconnections.clear());
    semOutbound.reset();
    semAddnode.reset();
}

void CConnman::DeleteNode(CNode* pnode)
{
    assert(pnode);
    m_msgproc->FinalizeNode(*pnode);
    delete pnode;
}

CConnman::~CConnman()
{
    Interrupt();
    Stop();
}

std::vector<CAddress> CConnman::GetAddresses(size_t max_addresses, size_t max_pct, std::optional<Network> network) const
{
    std::vector<CAddress> addresses = addrman.GetAddr(max_addresses, max_pct, network);
    if (m_banman) {
        addresses.erase(std::remove_if(addresses.begin(), addresses.end(),
                        [this](const CAddress& addr){return m_banman->IsDiscouraged(addr) || m_banman->IsBanned(addr);}),
                        addresses.end());
    }
    return addresses;
}

std::vector<CAddress> CConnman::GetAddresses(CNode& requestor, size_t max_addresses, size_t max_pct)
{
    auto local_socket_bytes = requestor.addrBind.GetAddrBytes();
    uint64_t cache_id = GetDeterministicRandomizer(RANDOMIZER_ID_ADDRCACHE)
        .Write(requestor.ConnectedThroughNetwork())
        .Write(local_socket_bytes)
        // For outbound connections, the port of the bound address is randomly
        // assigned by the OS and would therefore not be useful for seeding.
        .Write(requestor.IsInboundConn() ? requestor.addrBind.GetPort() : 0)
        .Finalize();
    const auto current_time = GetTime<std::chrono::microseconds>();
    auto r = m_addr_response_caches.emplace(cache_id, CachedAddrResponse{});
    CachedAddrResponse& cache_entry = r.first->second;
    if (cache_entry.m_cache_entry_expiration < current_time) { // If emplace() added new one it has expiration 0.
        cache_entry.m_addrs_response_cache = GetAddresses(max_addresses, max_pct, /*network=*/std::nullopt);
        // Choosing a proper cache lifetime is a trade-off between the privacy leak minimization
        // and the usefulness of ADDR responses to honest users.
        //
        // Longer cache lifetime makes it more difficult for an attacker to scrape
        // enough AddrMan data to maliciously infer something useful.
        // By the time an attacker scraped enough AddrMan records, most of
        // the records should be old enough to not leak topology info by
        // e.g. analyzing real-time changes in timestamps.
        //
        // It takes only several hundred requests to scrape everything from an AddrMan containing 100,000 nodes,
        // so ~24 hours of cache lifetime indeed makes the data less inferable by the time
        // most of it could be scraped (considering that timestamps are updated via
        // ADDR self-announcements and when nodes communicate).
        // We also should be robust to those attacks which may not require scraping *full* victim's AddrMan
        // (because even several timestamps of the same handful of nodes may leak privacy).
        //
        // On the other hand, longer cache lifetime makes ADDR responses
        // outdated and less useful for an honest requestor, e.g. if most nodes
        // in the ADDR response are no longer active.
        //
        // However, the churn in the network is known to be rather low. Since we consider
        // nodes to be "terrible" (see IsTerrible()) if the timestamps are older than 30 days,
        // max. 24 hours of "penalty" due to cache shouldn't make any meaningful difference
        // in terms of the freshness of the response.
        cache_entry.m_cache_entry_expiration = current_time + std::chrono::hours(21) + GetRandMillis(std::chrono::hours(6));
    }
    return cache_entry.m_addrs_response_cache;
}

bool CConnman::AddNode(const AddedNodeParams& add)
{
    LOCK(m_added_nodes_mutex);
    for (const auto& it : m_added_node_params) {
        if (add.m_added_node == it.m_added_node) return false;
    }

    m_added_node_params.push_back(add);
    return true;
}

bool CConnman::RemoveAddedNode(const std::string& strNode)
{
    LOCK(m_added_nodes_mutex);
    for (auto it = m_added_node_params.begin(); it != m_added_node_params.end(); ++it) {
        if (strNode == it->m_added_node) {
            m_added_node_params.erase(it);
            return true;
        }
    }
    return false;
}

bool CConnman::AddedNodesContain(const CAddress& addr) const
{
    AssertLockNotHeld(m_added_nodes_mutex);
    const std::string addr_str{addr.ToStringAddr()};
    const std::string addr_port_str{addr.ToStringAddrPort()};
    LOCK(m_added_nodes_mutex);
    return (m_added_node_params.size() < 24 // bound the query to a reasonable limit
            && std::any_of(m_added_node_params.cbegin(), m_added_node_params.cend(),
                           [&](const auto& p) { return p.m_added_node == addr_str || p.m_added_node == addr_port_str; }));
}

size_t CConnman::GetNodeCount(ConnectionDirection flags) const
{
    LOCK(m_nodes_mutex);
    if (flags == ConnectionDirection::Both) // Shortcut if we want total
        return m_nodes.size();

    int nNum = 0;
    for (const auto& pnode : m_nodes) {
        if (flags & (pnode->IsInboundConn() ? ConnectionDirection::In : ConnectionDirection::Out)) {
            nNum++;
        }
    }

    return nNum;
}

uint32_t CConnman::GetMappedAS(const CNetAddr& addr) const
{
    return m_netgroupman.GetMappedAS(addr);
}

void CConnman::GetNodeStats(std::vector<CNodeStats>& vstats) const
{
    vstats.clear();
    LOCK(m_nodes_mutex);
    vstats.reserve(m_nodes.size());
    for (CNode* pnode : m_nodes) {
        vstats.emplace_back();
        pnode->CopyStats(vstats.back());
        vstats.back().m_mapped_as = GetMappedAS(pnode->addr);
    }
}

bool CConnman::DisconnectNode(const std::string& strNode)
{
    LOCK(m_nodes_mutex);
    if (CNode* pnode = FindNode(strNode)) {
        LogPrint(BCLog::NET, "disconnect by address%s matched peer=%d; disconnecting\n", (fLogIPs ? strprintf("=%s", strNode) : ""), pnode->GetId());
        pnode->fDisconnect = true;
        return true;
    }
    return false;
}

bool CConnman::DisconnectNode(const CSubNet& subnet)
{
    bool disconnected = false;
    LOCK(m_nodes_mutex);
    for (CNode* pnode : m_nodes) {
        if (subnet.Match(pnode->addr)) {
            LogPrint(BCLog::NET, "disconnect by subnet%s matched peer=%d; disconnecting\n", (fLogIPs ? strprintf("=%s", subnet.ToString()) : ""), pnode->GetId());
            pnode->fDisconnect = true;
            disconnected = true;
        }
    }
    return disconnected;
}

bool CConnman::DisconnectNode(const CNetAddr& addr)
{
    return DisconnectNode(CSubNet(addr));
}

bool CConnman::DisconnectNode(NodeId id)
{
    LOCK(m_nodes_mutex);
    for(CNode* pnode : m_nodes) {
        if (id == pnode->GetId()) {
            LogPrint(BCLog::NET, "disconnect by id peer=%d; disconnecting\n", pnode->GetId());
            pnode->fDisconnect = true;
            return true;
        }
    }
    return false;
}

void CConnman::RecordBytesRecv(uint64_t bytes)
{
    nTotalBytesRecv += bytes;
}

void CConnman::RecordBytesSent(uint64_t bytes)
{
    AssertLockNotHeld(m_total_bytes_sent_mutex);
    LOCK(m_total_bytes_sent_mutex);

    nTotalBytesSent += bytes;

    const auto now = GetTime<std::chrono::seconds>();
    if (nMaxOutboundCycleStartTime + MAX_UPLOAD_TIMEFRAME < now)
    {
        // timeframe expired, reset cycle
        nMaxOutboundCycleStartTime = now;
        nMaxOutboundTotalBytesSentInCycle = 0;
    }

    nMaxOutboundTotalBytesSentInCycle += bytes;
}

uint64_t CConnman::GetMaxOutboundTarget() const
{
    AssertLockNotHeld(m_total_bytes_sent_mutex);
    LOCK(m_total_bytes_sent_mutex);
    return nMaxOutboundLimit;
}

std::chrono::seconds CConnman::GetMaxOutboundTimeframe() const
{
    return MAX_UPLOAD_TIMEFRAME;
}

std::chrono::seconds CConnman::GetMaxOutboundTimeLeftInCycle() const
{
    AssertLockNotHeld(m_total_bytes_sent_mutex);
    LOCK(m_total_bytes_sent_mutex);
    return GetMaxOutboundTimeLeftInCycle_();
}

std::chrono::seconds CConnman::GetMaxOutboundTimeLeftInCycle_() const
{
    AssertLockHeld(m_total_bytes_sent_mutex);

    if (nMaxOutboundLimit == 0)
        return 0s;

    if (nMaxOutboundCycleStartTime.count() == 0)
        return MAX_UPLOAD_TIMEFRAME;

    const std::chrono::seconds cycleEndTime = nMaxOutboundCycleStartTime + MAX_UPLOAD_TIMEFRAME;
    const auto now = GetTime<std::chrono::seconds>();
    return (cycleEndTime < now) ? 0s : cycleEndTime - now;
}

bool CConnman::OutboundTargetReached(bool historicalBlockServingLimit) const
{
    AssertLockNotHeld(m_total_bytes_sent_mutex);
    LOCK(m_total_bytes_sent_mutex);
    if (nMaxOutboundLimit == 0)
        return false;

    if (historicalBlockServingLimit)
    {
        // keep a large enough buffer to at least relay each block once
        const std::chrono::seconds timeLeftInCycle = GetMaxOutboundTimeLeftInCycle_();
        const uint64_t buffer = timeLeftInCycle / std::chrono::minutes{10} * MAX_BLOCK_SERIALIZED_SIZE;
        if (buffer >= nMaxOutboundLimit || nMaxOutboundTotalBytesSentInCycle >= nMaxOutboundLimit - buffer)
            return true;
    }
    else if (nMaxOutboundTotalBytesSentInCycle >= nMaxOutboundLimit)
        return true;

    return false;
}

uint64_t CConnman::GetOutboundTargetBytesLeft() const
{
    AssertLockNotHeld(m_total_bytes_sent_mutex);
    LOCK(m_total_bytes_sent_mutex);
    if (nMaxOutboundLimit == 0)
        return 0;

    return (nMaxOutboundTotalBytesSentInCycle >= nMaxOutboundLimit) ? 0 : nMaxOutboundLimit - nMaxOutboundTotalBytesSentInCycle;
}

uint64_t CConnman::GetTotalBytesRecv() const
{
    return nTotalBytesRecv;
}

uint64_t CConnman::GetTotalBytesSent() const
{
    AssertLockNotHeld(m_total_bytes_sent_mutex);
    LOCK(m_total_bytes_sent_mutex);
    return nTotalBytesSent;
}

ServiceFlags CConnman::GetLocalServices() const
{
    return nLocalServices;
}

static std::unique_ptr<Transport> MakeTransport(NodeId id, bool use_v2transport, bool inbound) noexcept
{
    if (use_v2transport) {
        return std::make_unique<V2Transport>(id, /*initiating=*/!inbound, SER_NETWORK);
    } else {
        return std::make_unique<V1Transport>(id, SER_NETWORK);
    }
}

CNode::CNode(NodeId idIn,
             std::shared_ptr<Sock> sock,
             const CAddress& addrIn,
             uint64_t nKeyedNetGroupIn,
             uint64_t nLocalHostNonceIn,
             const CAddress& addrBindIn,
             const std::string& addrNameIn,
             ConnectionType conn_type_in,
             bool inbound_onion,
             CNodeOptions&& node_opts)
    : m_transport{MakeTransport(idIn, node_opts.use_v2transport, conn_type_in == ConnectionType::INBOUND)},
      m_permission_flags{node_opts.permission_flags},
      m_sock{sock},
      m_connected{GetTime<std::chrono::seconds>()},
      addr{addrIn},
      addrBind{addrBindIn},
      m_addr_name{addrNameIn.empty() ? addr.ToStringAddrPort() : addrNameIn},
      m_dest(addrNameIn),
      m_inbound_onion{inbound_onion},
      m_prefer_evict{node_opts.prefer_evict},
      nKeyedNetGroup{nKeyedNetGroupIn},
      m_conn_type{conn_type_in},
      id{idIn},
      nLocalHostNonce{nLocalHostNonceIn},
      m_recv_flood_size{node_opts.recv_flood_size},
      m_i2p_sam_session{std::move(node_opts.i2p_sam_session)}
{
    if (inbound_onion) assert(conn_type_in == ConnectionType::INBOUND);

    for (const std::string &msg : getAllNetMessageTypes())
        mapRecvBytesPerMsgType[msg] = 0;
    mapRecvBytesPerMsgType[NET_MESSAGE_TYPE_OTHER] = 0;

    if (fLogIPs) {
        LogPrint(BCLog::NET, "Added connection to %s peer=%d\n", m_addr_name, id);
    } else {
        LogPrint(BCLog::NET, "Added connection peer=%d\n", id);
    }
}

void CNode::MarkReceivedMsgsForProcessing()
{
    AssertLockNotHeld(m_msg_process_queue_mutex);

    size_t nSizeAdded = 0;
    for (const auto& msg : vRecvMsg) {
        // vRecvMsg contains only completed CNetMessage
        // the single possible partially deserialized message are held by TransportDeserializer
        nSizeAdded += msg.m_raw_message_size;
    }

    LOCK(m_msg_process_queue_mutex);
    m_msg_process_queue.splice(m_msg_process_queue.end(), vRecvMsg);
    m_msg_process_queue_size += nSizeAdded;
    fPauseRecv = m_msg_process_queue_size > m_recv_flood_size;
}

std::optional<std::pair<CNetMessage, bool>> CNode::PollMessage()
{
    LOCK(m_msg_process_queue_mutex);
    if (m_msg_process_queue.empty()) return std::nullopt;

    std::list<CNetMessage> msgs;
    // Just take one message
    msgs.splice(msgs.begin(), m_msg_process_queue, m_msg_process_queue.begin());
    m_msg_process_queue_size -= msgs.front().m_raw_message_size;
    fPauseRecv = m_msg_process_queue_size > m_recv_flood_size;

    return std::make_pair(std::move(msgs.front()), !m_msg_process_queue.empty());
}

bool CConnman::NodeFullyConnected(const CNode* pnode)
{
    return pnode && pnode->fSuccessfullyConnected && !pnode->fDisconnect;
}

void CConnman::PushMessage(CNode* pnode, CSerializedNetMsg&& msg)
{
    AssertLockNotHeld(m_total_bytes_sent_mutex);
    size_t nMessageSize = msg.data.size();
    LogPrint(BCLog::NET, "sending %s (%d bytes) peer=%d\n", msg.m_type, nMessageSize, pnode->GetId());
    if (gArgs.GetBoolArg("-capturemessages", false)) {
        CaptureMessage(pnode->addr, msg.m_type, msg.data, /*is_incoming=*/false);
    }

    TRACE6(net, outbound_message,
        pnode->GetId(),
        pnode->m_addr_name.c_str(),
        pnode->ConnectionTypeAsString().c_str(),
        msg.m_type.c_str(),
        msg.data.size(),
        msg.data.data()
    );

    size_t nBytesSent = 0;
    {
        LOCK(pnode->cs_vSend);
        // Check if the transport still has unsent bytes, and indicate to it that we're about to
        // give it a message to send.
        const auto& [to_send, more, _msg_type] =
            pnode->m_transport->GetBytesToSend(/*have_next_message=*/true);
        const bool queue_was_empty{to_send.empty() && pnode->vSendMsg.empty()};

        // Update memory usage of send buffer.
        pnode->m_send_memusage += msg.GetMemoryUsage();
        if (pnode->m_send_memusage + pnode->m_transport->GetSendMemoryUsage() > nSendBufferMaxSize) pnode->fPauseSend = true;
        // Move message to vSendMsg queue.
        pnode->vSendMsg.push_back(std::move(msg));

        // If there was nothing to send before, and there is now (predicted by the "more" value
        // returned by the GetBytesToSend call above), attempt "optimistic write":
        // because the poll/select loop may pause for SELECT_TIMEOUT_MILLISECONDS before actually
        // doing a send, try sending from the calling thread if the queue was empty before.
        // With a V1Transport, more will always be true here, because adding a message always
        // results in sendable bytes there, but with V2Transport this is not the case (it may
        // still be in the handshake).
        if (queue_was_empty && more) {
            std::tie(nBytesSent, std::ignore) = SocketSendData(*pnode);
        }
    }
    if (nBytesSent) RecordBytesSent(nBytesSent);
}

bool CConnman::ForNode(NodeId id, std::function<bool(CNode* pnode)> func)
{
    CNode* found = nullptr;
    LOCK(m_nodes_mutex);
    for (auto&& pnode : m_nodes) {
        if(pnode->GetId() == id) {
            found = pnode;
            break;
        }
    }
    return found != nullptr && NodeFullyConnected(found) && func(found);
}

CSipHasher CConnman::GetDeterministicRandomizer(uint64_t id) const
{
    return CSipHasher(nSeed0, nSeed1).Write(id);
}

uint64_t CConnman::CalculateKeyedNetGroup(const CAddress& address) const
{
    std::vector<unsigned char> vchNetGroup(m_netgroupman.GetGroup(address));

    return GetDeterministicRandomizer(RANDOMIZER_ID_NETGROUP).Write(vchNetGroup).Finalize();
}

void CConnman::PerformReconnections()
{
    AssertLockNotHeld(m_reconnections_mutex);
    AssertLockNotHeld(m_unused_i2p_sessions_mutex);
    for (int batch = 0; batch < 1 && !interruptNet && fNetworkActive; ++batch) {
        // Bound synchronous reconnect work so selection and timers get a turn.
        // Move first element of m_reconnections to todo (avoiding an allocation inside the lock).
        decltype(m_reconnections) todo;
        {
            LOCK(m_reconnections_mutex);
            if (m_reconnections.empty()) break;
            todo.splice(todo.end(), m_reconnections, m_reconnections.begin());
        }

        auto& item = *todo.begin();
        OpenNetworkConnection(item.addr_connect,
                              // We only reconnect if the first attempt to connect succeeded at
                              // connection time, but then failed after the CNode object was
                              // created. Since we already know connecting is possible, do not
                              // count failure to reconnect.
                              /*fCountFailure=*/false,
                              std::move(item.grant),
                              item.destination.empty() ? nullptr : item.destination.c_str(),
                              item.conn_type,
                              item.use_v2transport,
                              std::move(item.qq_probe));
    }
}

// Dump binary message to file, with timestamp.
static void CaptureMessageToFile(const CAddress& addr,
                                 const std::string& msg_type,
                                 Span<const unsigned char> data,
                                 bool is_incoming)
{
    // Note: This function captures the message at the time of processing,
    // not at socket receive/send time.
    // This ensures that the messages are always in order from an application
    // layer (processing) perspective.
    auto now = GetTime<std::chrono::microseconds>();

    // Windows folder names cannot include a colon
    std::string clean_addr = addr.ToStringAddrPort();
    std::replace(clean_addr.begin(), clean_addr.end(), ':', '_');

    fs::path base_path = gArgs.GetDataDirNet() / "message_capture" / fs::u8path(clean_addr);
    fs::create_directories(base_path);

    fs::path path = base_path / (is_incoming ? "msgs_recv.dat" : "msgs_sent.dat");
    AutoFile f{fsbridge::fopen(path, "ab")};

    ser_writedata64(f, now.count());
    f << Span{msg_type};
    for (auto i = msg_type.length(); i < CMessageHeader::COMMAND_SIZE; ++i) {
        f << uint8_t{'\0'};
    }
    uint32_t size = data.size();
    ser_writedata32(f, size);
    f << data;
}

std::function<void(const CAddress& addr,
                   const std::string& msg_type,
                   Span<const unsigned char> data,
                   bool is_incoming)>
    CaptureMessage = CaptureMessageToFile;
