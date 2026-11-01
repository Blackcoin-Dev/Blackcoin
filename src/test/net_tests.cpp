// Copyright (c) 2012-2022 The Bitcoin Core developers
// Copyright (c) 2012-2022 Blackcoin Core Developers
// Copyright (c) 2012-2022 Blackcoin More Developers
// Copyright (c) 2012-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <banman.h>
#include <blockencodings.h>
#include <chainparams.h>
#include <clientversion.h>
#include <common/args.h>
#include <compat/compat.h>
#include <consensus/validation.h>
#include <cstdint>
#include <net.h>
#include <net_processing.h>
#include <netaddress.h>
#include <netbase.h>
#include <netmessagemaker.h>
#include <node/blockstorage.h>
#include <serialize.h>
#include <span.h>
#include <streams.h>
#include <test/util/net.h>
#include <test/util/random.h>
#include <test/util/setup_common.h>
#include <test/util/validation.h>
#include <timedata.h>
#include <util/strencodings.h>
#include <util/string.h>
#include <validation.h>
#include <version.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <condition_variable>
#include <ios>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>

using namespace std::literals;

BOOST_FIXTURE_TEST_SUITE(net_tests, RegTestingSetup)

BOOST_AUTO_TEST_CASE(qq_capacity_policy)
{
    for (const int capacity : {0, 1, 2, 8, 16}) {
        ConnmanTestMsg connman{0, 0, *m_node.addrman, *m_node.netgroupman, Params()};
        CConnman::Options options;
        options.nMaxConnections = capacity;
        options.m_max_outbound_full_relay = MAX_OUTBOUND_FULL_RELAY_CONNECTIONS;
        connman.Init(options);
        BOOST_CHECK_EQUAL(connman.GetQQTarget(), capacity / 2);
        options.m_qq_outbound_target = 100;
        connman.Init(options);
        BOOST_CHECK_EQUAL(connman.GetQQTarget(), std::max(0, capacity - 1));
        options.m_qq_outbound_target = 0;
        connman.Init(options);
        BOOST_CHECK_EQUAL(connman.GetQQTarget(), 0);
    }
}

BOOST_AUTO_TEST_CASE(qq_probe_fallback_deadline)
{
    const auto start = qq::Clock::time_point{};
    auto lease = std::make_shared<qq::Probe>(start);
    std::weak_ptr<qq::Probe> outstanding{lease};
    auto fallback = lease;
    lease.reset();
    BOOST_CHECK(!outstanding.expired());
    BOOST_CHECK(!fallback->Expired(start + 119s));
    BOOST_CHECK(fallback->Expired(start + 120s));
    BOOST_CHECK(fallback->Expired(start + 24h)); // Resume coalesces elapsed deadlines.
    fallback.reset();
    BOOST_CHECK(outstanding.expired());
}

BOOST_AUTO_TEST_CASE(qq_queued_fallback_expiration_and_batch)
{
    ConnmanTestMsg connman{0, 0, *m_node.addrman, *m_node.netgroupman, Params()};
    connman.InitReconnectionTest();
    struct SocketFactoryGuard {
        decltype(CreateSock) original{CreateSock};
        ~SocketFactoryGuard() { CreateSock = std::move(original); }
    } socket_factory_guard;
    unsigned int attempted{0};
    CreateSock = [&](const CService&) -> std::unique_ptr<Sock> { ++attempted; return nullptr; };
    auto expired = std::make_shared<qq::Probe>(qq::Clock::now() - qq::PROBE_RESIDENCE);
    std::weak_ptr<qq::Probe> token = expired;
    connman.QueueReconnection(connman.AcquireOutboundPermit(), std::move(expired));
    BOOST_CHECK(!token.expired());
    connman.PerformReconnections();
    BOOST_CHECK(token.expired());
    BOOST_CHECK_EQUAL(attempted, 0U);
    // Expiration returns the actual semaphore permit exactly once.
    auto returned = connman.AcquireOutboundPermit();
    BOOST_CHECK(returned);
    returned.Release();
    connman.QueueReconnection({});
    connman.QueueReconnection({});
    connman.PerformReconnections();
    BOOST_CHECK_EQUAL(attempted, 1U);
    BOOST_CHECK_EQUAL(connman.GetReconnectionCount(), 1U);
    connman.PerformReconnections();
    BOOST_CHECK_EQUAL(attempted, 2U);
}

BOOST_AUTO_TEST_CASE(qq_transient_fairness)
{
    qq::Arbiter arbiter;
    std::array<bool, qq::Arbiter::CLASSES> due;
    due.fill(true);
    for (int cycle = 0; cycle < 100; ++cycle) {
        std::set<int> served;
        for (size_t turn = 0; turn < due.size(); ++turn) served.insert(arbiter.Pick(due));
        BOOST_CHECK_EQUAL(served.size(), due.size());
    }
    due.fill(false);
    BOOST_CHECK_EQUAL(arbiter.Pick(due), -1);
    due[1] = due[5] = true; // Continuous address discovery cannot starve QQ, or vice versa.
    for (int turn = 0; turn < 100; ++turn) BOOST_CHECK_EQUAL(arbiter.Pick(due), turn % 2 ? 5 : 1);
}

BOOST_AUTO_TEST_CASE(addr_fetch_bounded_and_canonical)
{
    ConnmanTestMsg connman{0, 0, *m_node.addrman, *m_node.netgroupman, Params()};
    connman.AddAddrFetch("EXAMPLE.TEST.");
    connman.AddAddrFetch("example.test");
    BOOST_CHECK_EQUAL(connman.GetAddrFetchCount(), 1U);
    BOOST_CHECK_EQUAL(connman.GetAddrFetchFront(), "EXAMPLE.TEST.");
    for (size_t i = 0; i < qq::MAX_ADDR_FETCHES * 2; ++i) connman.AddAddrFetch(strprintf("seed%u.test", i));
    BOOST_CHECK_EQUAL(connman.GetAddrFetchCount(), qq::MAX_ADDR_FETCHES);
}

BOOST_AUTO_TEST_CASE(cnode_listen_port)
{
    // test default
    uint16_t port{GetListenPort()};
    BOOST_CHECK(port == Params().GetDefaultPort());
    // test set port
    uint16_t altPort = 12345;
    BOOST_CHECK(gArgs.SoftSetArg("-port", ToString(altPort)));
    port = GetListenPort();
    BOOST_CHECK(port == altPort);
}

BOOST_AUTO_TEST_CASE(addr_fetch_retains_pending_work)
{
    ConnmanTestMsg connman{0, 0, *m_node.addrman, *m_node.netgroupman, Params()};
    connman.InitAddrFetchTest();

    // Count attempted destinations without creating sockets or using the network.
    struct SocketFactoryGuard {
        decltype(CreateSock) original{CreateSock};
        ~SocketFactoryGuard() { CreateSock = std::move(original); }
    } socket_factory_guard;
    std::vector<CService> attempted;
    CreateSock = [&attempted](const CService& address) -> std::unique_ptr<Sock> {
        attempted.push_back(address);
        return nullptr;
    };

    connman.AddAddrFetch("8.8.8.8:15714");
    connman.AddAddrFetch("9.9.9.9:15714");
    auto occupied{connman.AcquireOutboundPermit()};
    connman.ProcessAddrFetch();
    BOOST_CHECK_EQUAL(connman.GetAddrFetchCount(), 2U);
    BOOST_CHECK(attempted.empty());

    connman.SetNetworkActive(false);
    occupied.Release();
    connman.ProcessAddrFetch();
    BOOST_CHECK_EQUAL(connman.GetAddrFetchCount(), 2U);
    BOOST_CHECK(attempted.empty());

    connman.SetNetworkActive(true);
    connman.ProcessAddrFetch();
    BOOST_CHECK_EQUAL(connman.GetAddrFetchCount(), 1U);
    BOOST_REQUIRE_EQUAL(attempted.size(), 1U);
    BOOST_CHECK(attempted[0] == LookupNumeric("8.8.8.8:15714"));

    connman.ProcessAddrFetch();
    BOOST_CHECK_EQUAL(connman.GetAddrFetchCount(), 0U);
    BOOST_REQUIRE_EQUAL(attempted.size(), 2U);
    BOOST_CHECK(attempted[1] == LookupNumeric("9.9.9.9:15714"));

    connman.ProcessAddrFetch();
    BOOST_CHECK_EQUAL(attempted.size(), 2U);
}

BOOST_AUTO_TEST_CASE(reconnections_with_exhausted_permits)
{
    // Exercise each real worker independently: either one must be able to
    // consume a fallback while both permit pools remain exhausted.
    for (const bool addnode : {false, true}) {
        ConnmanTestMsg connman{0, 0, *m_node.addrman, *m_node.netgroupman, Params()};
        connman.InitReconnectionTest();
        auto outbound{connman.AcquireOutboundPermit()};
        auto manual{connman.AcquireAddnodePermit()};

        struct SocketFactoryGuard {
            decltype(CreateSock) original{CreateSock};
            ~SocketFactoryGuard() { CreateSock = std::move(original); }
        } socket_factory_guard;
        std::mutex mutex;
        std::condition_variable attempted_cv;
        unsigned int attempted{0};
        CreateSock = [&](const CService&) -> std::unique_ptr<Sock> {
            {
                std::lock_guard<std::mutex> lock{mutex};
                ++attempted;
            }
            attempted_cv.notify_one();
            return nullptr;
        };

        connman.StartConnectionWorker(addnode);
        // Let the worker reach its first exhausted-permit acquisition before
        // queueing. No unrelated node or test grant is released to wake it.
        std::this_thread::sleep_for(750ms);
        connman.QueueReconnection(addnode ? std::move(manual) : std::move(outbound));
        bool retried;
        {
            std::unique_lock<std::mutex> lock{mutex};
            retried = attempted_cv.wait_for(lock, 5s, [&] { return attempted != 0; });
        }
        connman.Interrupt();
        connman.StopThreads();
        BOOST_CHECK_MESSAGE(retried, (addnode ? "addnode fallback stalled" : "automatic fallback stalled"));
        BOOST_CHECK_EQUAL(attempted, 1U);
    }
}

BOOST_AUTO_TEST_CASE(reconnections_respect_networkactive_and_interrupt)
{
    ConnmanTestMsg connman{0, 0, *m_node.addrman, *m_node.netgroupman, Params()};
    connman.InitReconnectionTest();
    struct SocketFactoryGuard {
        decltype(CreateSock) original{CreateSock};
        ~SocketFactoryGuard() { CreateSock = std::move(original); }
    } socket_factory_guard;
    unsigned int attempted{0};
    CreateSock = [&](const CService&) -> std::unique_ptr<Sock> {
        ++attempted;
        return nullptr;
    };

    connman.SetNetworkActive(false);
    connman.QueueReconnection(connman.AcquireOutboundPermit());
    connman.PerformReconnections();
    BOOST_CHECK_EQUAL(attempted, 0U);

    connman.SetNetworkActive(true);
    connman.PerformReconnections();
    BOOST_CHECK_EQUAL(attempted, 1U);

    connman.Interrupt();
    connman.QueueReconnection(connman.AcquireOutboundPermit());
    connman.PerformReconnections();
    BOOST_CHECK_EQUAL(attempted, 1U);
}

BOOST_AUTO_TEST_CASE(header_replay_filter_at_capacity)
{
    const int capacity{static_cast<int>(DEFAULT_HEADER_SPAM_FILTER_MAX_SIZE)};
    CBlockIndex first, last;
    first.nHeight = 0;
    last.nHeight = capacity - 1;
    CNodeHeaders full_filter;
    BOOST_REQUIRE(full_filter.addHeaders(&first, &last));
    BlockValidationState initial_state;
    BOOST_REQUIRE(full_filter.updateState(0, initial_state, true));

    // Repeating the lowest retained height must reach the same existing spam
    // threshold as repeating another retained height, without evicting it.
    unsigned int reference_replays{0};
    for (const int height : {capacity - 1, capacity / 2, 0}) {
        CNodeHeaders filter{full_filter};
        CBlockIndex repeated;
        repeated.nHeight = height;
        unsigned int replays{0};
        BlockValidationState state;
        while (replays < DEFAULT_HEADER_SPAM_FILTER_MAX_SIZE * 5) {
            BOOST_REQUIRE(filter.addHeaders(&repeated, &repeated));
            ++replays;
            if (!filter.updateState(0, state, true)) break;
        }
        BOOST_CHECK(state.GetResult() == BlockValidationResult::BLOCK_HEADER_SPAM);
        if (reference_replays == 0) reference_replays = replays;
        BOOST_CHECK_EQUAL(replays, reference_replays);
    }

    // New distinct heights still evict old entries. Without the bound this
    // many fresh heights alone would exceed the unchanged total-count limit.
    CNodeHeaders filter{full_filter};
    first.nHeight = capacity;
    last.nHeight = capacity * 6;
    BOOST_REQUIRE(filter.addHeaders(&first, &last));
    BlockValidationState bounded_state;
    BOOST_CHECK(filter.updateState(0, bounded_state, true));
}

BOOST_AUTO_TEST_CASE(header_replay_compact_counter_equivalence)
{
    // Compare the compact production counter with an independent ordered-map
    // reference over overlapping ranges, retained replays, and new low heights.
    constexpr size_t capacity{17};
    CNodeHeaders compact{capacity, 1000000};
    std::map<int, uint32_t> reference;
    uint32_t sequence{0x6d2b79f5};
    for (int turn = 0; turn < 3000; ++turn) {
        sequence = static_cast<uint32_t>(
            uint64_t{sequence} * 1664525U + 1013904223U);
        const int first_height = (sequence >> 16) % 73;
        const int last_height = first_height + (sequence % 5);
        CBlockIndex first, last;
        first.nHeight = first_height;
        last.nHeight = last_height;
        BOOST_REQUIRE(compact.addHeaders(&first, &last));
        for (int height = first_height; height <= last_height; ++height) {
            auto known = reference.find(height);
            if (known != reference.end()) ++known->second;
            else {
                if (reference.size() == capacity) reference.erase(reference.begin());
                reference.emplace(height, 1);
            }
        }
        BOOST_CHECK_EQUAL(compact.HeightCount(), reference.size());
        for (int height = 0; height < 80; ++height) {
            const auto known = reference.find(height);
            BOOST_CHECK_EQUAL(compact.CountAtHeight(height), known == reference.end() ? 0U : known->second);
        }
    }
    BOOST_CHECK_THROW(CNodeHeaders(MAX_HEADER_SPAM_FILTER_POINTS + 1, 10), std::invalid_argument);
}

BOOST_AUTO_TEST_CASE(header_replay_identity_reserve_and_churn)
{
    CServiceHeaderTracker tracker;
    const auto start = CServiceHeaderTracker::Clock::time_point{};
    const auto address = [](unsigned int value) {
        return LookupNumeric(strprintf("23.%u.%u.1", value / 256, value % 256), 15714);
    };
    constexpr size_t general = CServiceHeaderTracker::MAX_SERVICES - CServiceHeaderTracker::INITIATED_RESERVE;
    CBlockIndex repeated;
    repeated.nHeight = 0;
    for (size_t i = 0; i < general; ++i) {
        const auto service = address(i);
        auto* headers = tracker.GetOrCreate(service, false, 1, start + (i == 0 ? 0s : 60s));
        BOOST_REQUIRE(headers);
        if (i == 0) {
            for (int replay = 0; replay < 3; ++replay) BOOST_REQUIRE(headers->addHeaders(&repeated, &repeated));
        }
        tracker.Disconnected(service, start + (i == 0 ? 0s : 60s));
    }
    BOOST_CHECK_EQUAL(tracker.GeneralSize(), general);
    BOOST_CHECK(!tracker.GetOrCreate(address(general), false, 1, start));
    for (size_t i = general; i < CServiceHeaderTracker::MAX_SERVICES; ++i) {
        const auto service = address(i);
        BOOST_REQUIRE(tracker.GetOrCreate(service, true, 1, start + 60s));
        tracker.Disconnected(service, start + 60s);
    }
    // Unknown identities cannot grow storage, evict existing evidence, or
    // consume unbounded expiry metadata, even under sustained churn.
    for (unsigned int i = 2000; i < 12000; ++i) {
        BOOST_CHECK(!tracker.GetOrCreate(address(i), i % 2, 1, start + 30min));
    }
    BOOST_CHECK_EQUAL(tracker.Size(), CServiceHeaderTracker::MAX_SERVICES);
    auto* retained = tracker.GetOrCreate(address(0), false, 0, start + 30min);
    BOOST_REQUIRE(retained);
    BOOST_CHECK_EQUAL(retained->CountAtHeight(0), 3U);
    BOOST_REQUIRE(retained->addHeaders(&repeated, &repeated));
    BOOST_CHECK_EQUAL(retained->CountAtHeight(0), 4U);
    // Only one record has expired at this boundary. Exactly one admission
    // succeeds and every other unexpired identity still occupies its slot.
    BOOST_REQUIRE(tracker.GetOrCreate(address(12000), false, 1, start + 1h));
    BOOST_CHECK_EQUAL(tracker.Size(), CServiceHeaderTracker::MAX_SERVICES);
    BOOST_CHECK_EQUAL(tracker.GeneralSize(), general);
    BOOST_CHECK(!tracker.GetOrCreate(address(12001), false, 1, start + 1h));
    BOOST_REQUIRE(tracker.GetOrCreate(address(12001), false, 1, start + 1h + 60s));
    BOOST_CHECK_EQUAL(tracker.Size(), 2U);
    BOOST_CHECK_EQUAL(tracker.GeneralSize(), 2U);
}

BOOST_AUTO_TEST_CASE(header_replay_lifecycle_normalization_and_expiry)
{
    CServiceHeaderTracker tracker;
    const auto start = CServiceHeaderTracker::Clock::time_point{};
    const auto first = LookupNumeric("23.1.1.1", 15714);
    const auto second = LookupNumeric("23.1.1.1", 25714);
    const auto key = CServiceHeaderTracker::Normalize(first, true);
    BOOST_CHECK(key == CServiceHeaderTracker::Normalize(second, true));
    BOOST_CHECK(CServiceHeaderTracker::Normalize(first, false) != CServiceHeaderTracker::Normalize(second, false));
    // Lazy admission sees both already-live connections to the same key.
    auto* headers = tracker.GetOrCreate(key, true, 2, start);
    BOOST_REQUIRE(headers);
    CBlockIndex repeated;
    repeated.nHeight = 0;
    BOOST_REQUIRE(headers->addHeaders(&repeated, &repeated));
    tracker.Disconnected(key, start + 1min);
    BOOST_REQUIRE(tracker.GetOrCreate(key, false, 1, start + 2h));
    BOOST_CHECK_EQUAL(tracker.GetOrCreate(key, false, 1, start + 2h)->CountAtHeight(0), 1U);
    tracker.Disconnected(key, start + 2h);
    tracker.Connected(key, start + 2h + 59min);
    headers = tracker.GetOrCreate(key, false, 1, start + 2h + 59min);
    BOOST_REQUIRE(headers);
    BOOST_CHECK_EQUAL(headers->CountAtHeight(0), 1U);
    tracker.Disconnected(key, start + 3h);
    // Reconnection before expiry resets the disconnected retention deadline.
    BOOST_CHECK_EQUAL(tracker.GetOrCreate(key, false, 0, start + 3h + 59min)->CountAtHeight(0), 1U);
    // Connected() removes an expired disconnected record before pinning; the
    // new lazy admission starts with fresh counters at the retention boundary.
    tracker.Connected(key, start + 4h);
    headers = tracker.GetOrCreate(key, false, 1, start + 4h);
    BOOST_REQUIRE(headers);
    BOOST_CHECK_EQUAL(headers->CountAtHeight(0), 0U);
}

BOOST_AUTO_TEST_CASE(header_replay_threshold_survives_reconnect)
{
    CServiceHeaderTracker tracker;
    const auto start = CServiceHeaderTracker::Clock::time_point{};
    const auto service = LookupNumeric("23.2.1.1", 15714);
    auto* headers = tracker.GetOrCreate(service, true, 1, start);
    BOOST_REQUIRE(headers);
    CBlockIndex first, last;
    first.nHeight = 0;
    last.nHeight = DEFAULT_HEADER_SPAM_FILTER_MAX_SIZE - 1;
    BOOST_REQUIRE(headers->addHeaders(&first, &last));
    BlockValidationState state;
    for (unsigned int i = 0; i < DEFAULT_HEADER_SPAM_FILTER_MAX_SIZE * 5 && !state.IsInvalid(); ++i) {
        BOOST_REQUIRE(headers->addHeaders(&first, &first));
        headers->updateState(0, state, true);
    }
    BOOST_REQUIRE(state.GetResult() == BlockValidationResult::BLOCK_HEADER_SPAM);
    const uint32_t evidence = headers->CountAtHeight(0);
    BOOST_CHECK_GT(evidence, 1U);
    tracker.Disconnected(service, start);
    tracker.Connected(service, start + 59min);
    headers = tracker.GetOrCreate(service, true, 1, start + 59min);
    BOOST_REQUIRE(headers);
    BOOST_CHECK_EQUAL(headers->CountAtHeight(0), evidence);
    BlockValidationState reconnect_state;
    BOOST_CHECK(!headers->updateState(1, reconnect_state, true));
    BOOST_CHECK(reconnect_state.GetResult() == BlockValidationResult::BLOCK_HEADER_SPAM);
    tracker.Disconnected(service, start + 59min);
    tracker.Connected(service, start + 2h);
    headers = tracker.GetOrCreate(service, true, 1, start + 2h);
    BOOST_REQUIRE(headers);
    BOOST_CHECK_EQUAL(headers->HeightCount(), 0U);
    BlockValidationState fresh;
    BOOST_CHECK(headers->updateState(2, fresh, true));
}

BOOST_FIXTURE_TEST_CASE(header_replay_capacity_message_paths, TestChain100Setup)
{
    LOCK(NetEventsInterface::g_msgproc_mutex);
    if (m_node.chainman->IsInitialBlockDownload()) {
        static_cast<TestChainstateManager&>(*m_node.chainman).JumpOutOfIbd();
    }
    auto banman = std::make_unique<BanMan>(m_args.GetDataDirBase() / "header-capacity-banlist", nullptr, DEFAULT_MISBEHAVING_BANTIME);
    ConnmanTestMsg connman{0, 0, *m_node.addrman, *m_node.netgroupman, Params()};
    auto peerman = PeerManager::make(connman, *m_node.addrman, banman.get(), *m_node.chainman, *m_node.mempool, {});
    CConnman::Options options;
    options.m_msgproc = peerman.get();
    connman.Init(options);
    NodeId next_id{0};
    const auto address = [](unsigned int value) {
        return LookupNumeric(strprintf("24.%u.%u.1", value / 256, value % 256), 15714);
    };
    const auto make_peer = [&](unsigned int value, uint16_t port = 15714) {
        const CService endpoint{address(value), port};
        auto node = std::make_unique<CNode>(next_id++, nullptr, CAddress{endpoint, NODE_NETWORK},
            0, 0, CAddress{}, "", ConnectionType::INBOUND, false);
        peerman->InitializeNode(*node, NODE_NETWORK);
        node->nVersion = PROTOCOL_VERSION;
        node->SetCommonVersion(PROTOCOL_VERSION);
        node->fSuccessfullyConnected = true;
        return node;
    };
    std::atomic<bool> interrupt{false};
    const CNetMsgMaker maker{PROTOCOL_VERSION};
    const auto deliver = [&](CNode& node, CSerializedNetMsg message) {
        CDataStream stream{message.data, SER_NETWORK};
        peerman->ProcessMessage(node, message.m_type, stream, 0us, interrupt);
    };
    const CBlockHeader known{WITH_LOCK(cs_main, return m_node.chainman->ActiveChain().Tip()->GetBlockHeader())};
    CBlock header_only;
    static_cast<CBlockHeader&>(header_only) = known;
    const auto header_message = [&] { return maker.Make(NetMsgType::HEADERS, TX_WITH_WITNESS(std::vector<CBlock>{header_only})); };
    // Both connections predate lazy record admission. Filtering is initially
    // disabled; enabling it must count the second, still-dormant connection.
    // Neither finalization may underflow or free the other's retained state.
    const bool original_filter = m_node.args->GetBoolArg("-headerspamfilter", DEFAULT_HEADER_SPAM_FILTER);
    struct FilterGuard {
        ArgsManager& args;
        bool original;
        ~FilterGuard() { args.ForceSetArg("-headerspamfilter", original ? "1" : "0"); }
    } filter_guard{*m_node.args, original_filter};
    m_node.args->ForceSetArg("-headerspamfilter", "0");
    auto dormant = make_peer(0);
    auto active = make_peer(0, 25714);
    deliver(*active, header_message());
    BOOST_REQUIRE(!active->fDisconnect);
    m_node.args->ForceSetArg("-headerspamfilter", "1");
    deliver(*active, header_message());
    BOOST_REQUIRE(!active->fDisconnect);
    peerman->FinalizeNode(*active);
    deliver(*dormant, header_message());
    BOOST_REQUIRE(!dormant->fDisconnect);
    peerman->FinalizeNode(*dormant);
    // Populate actual PeerManager accounting through accepted HEADERS, then
    // disconnect. No test hook injects records or overrides the capacity.
    for (size_t i = 0; i < CServiceHeaderTracker::MAX_SERVICES - CServiceHeaderTracker::INITIATED_RESERVE; ++i) {
        auto node = make_peer(i);
        deliver(*node, header_message());
        BOOST_REQUIRE(!node->fDisconnect);
        peerman->FinalizeNode(*node);
    }
    const CBlock candidate = CreateBlock({}, CScript{} << OP_TRUE, m_node.chainman->ActiveChainstate());
    for (const auto& type : {NetMsgType::HEADERS, NetMsgType::CMPCTBLOCK, NetMsgType::BLOCK}) {
        auto node = make_peer(10000 + next_id);
        if (type == NetMsgType::HEADERS) {
            CBlock header;
            static_cast<CBlockHeader&>(header) = candidate.GetBlockHeader();
            deliver(*node, maker.Make(type, TX_WITH_WITNESS(std::vector<CBlock>{header})));
        } else if (type == NetMsgType::CMPCTBLOCK) {
            deliver(*node, maker.Make(type, CBlockHeaderAndShortTxIDs{candidate}));
        } else {
            deliver(*node, maker.Make(type, TX_WITH_WITNESS(candidate)));
        }
        BOOST_CHECK(node->fDisconnect);
        BOOST_CHECK(!banman->IsDiscouraged(node->addr));
        BOOST_CHECK(!banman->IsBanned(node->addr));
        // Resource refusal precedes validation. No caller may fall through to
        // header/block acceptance, mark a valid block invalid, or dereference
        // an absent returned block index.
        BOOST_CHECK(WITH_LOCK(cs_main, return m_node.chainman->m_blockman.LookupBlockIndex(candidate.GetHash()) == nullptr));
        peerman->FinalizeNode(*node);
    }
    auto retained = make_peer(0);
    deliver(*retained, maker.Make(NetMsgType::BLOCK, TX_WITH_WITNESS(candidate)));
    BOOST_CHECK(!retained->fDisconnect);
    BOOST_CHECK(WITH_LOCK(cs_main, return m_node.chainman->ActiveChain().Tip()->GetBlockHash() == candidate.GetHash()));
    peerman->FinalizeNode(*retained);
}

BOOST_AUTO_TEST_CASE(cnode_simple_test)
{
    NodeId id = 0;

    in_addr ipv4Addr;
    ipv4Addr.s_addr = 0xa0b0c001;

    CAddress addr = CAddress(CService(ipv4Addr, 7777), NODE_NETWORK);
    std::string pszDest;

    std::unique_ptr<CNode> pnode1 = std::make_unique<CNode>(id++,
                                                            /*sock=*/nullptr,
                                                            addr,
                                                            /*nKeyedNetGroupIn=*/0,
                                                            /*nLocalHostNonceIn=*/0,
                                                            CAddress(),
                                                            pszDest,
                                                            ConnectionType::OUTBOUND_FULL_RELAY,
                                                            /*inbound_onion=*/false);
    BOOST_CHECK(pnode1->IsFullOutboundConn() == true);
    BOOST_CHECK(pnode1->IsManualConn() == false);
    BOOST_CHECK(pnode1->IsBlockOnlyConn() == false);
    BOOST_CHECK(pnode1->IsFeelerConn() == false);
    BOOST_CHECK(pnode1->IsAddrFetchConn() == false);
    BOOST_CHECK(pnode1->IsInboundConn() == false);
    BOOST_CHECK(pnode1->m_inbound_onion == false);
    BOOST_CHECK_EQUAL(pnode1->ConnectedThroughNetwork(), Network::NET_IPV4);

    std::unique_ptr<CNode> pnode2 = std::make_unique<CNode>(id++,
                                                            /*sock=*/nullptr,
                                                            addr,
                                                            /*nKeyedNetGroupIn=*/1,
                                                            /*nLocalHostNonceIn=*/1,
                                                            CAddress(),
                                                            pszDest,
                                                            ConnectionType::INBOUND,
                                                            /*inbound_onion=*/false);
    BOOST_CHECK(pnode2->IsFullOutboundConn() == false);
    BOOST_CHECK(pnode2->IsManualConn() == false);
    BOOST_CHECK(pnode2->IsBlockOnlyConn() == false);
    BOOST_CHECK(pnode2->IsFeelerConn() == false);
    BOOST_CHECK(pnode2->IsAddrFetchConn() == false);
    BOOST_CHECK(pnode2->IsInboundConn() == true);
    BOOST_CHECK(pnode2->m_inbound_onion == false);
    BOOST_CHECK_EQUAL(pnode2->ConnectedThroughNetwork(), Network::NET_IPV4);

    std::unique_ptr<CNode> pnode3 = std::make_unique<CNode>(id++,
                                                            /*sock=*/nullptr,
                                                            addr,
                                                            /*nKeyedNetGroupIn=*/0,
                                                            /*nLocalHostNonceIn=*/0,
                                                            CAddress(),
                                                            pszDest,
                                                            ConnectionType::OUTBOUND_FULL_RELAY,
                                                            /*inbound_onion=*/false);
    BOOST_CHECK(pnode3->IsFullOutboundConn() == true);
    BOOST_CHECK(pnode3->IsManualConn() == false);
    BOOST_CHECK(pnode3->IsBlockOnlyConn() == false);
    BOOST_CHECK(pnode3->IsFeelerConn() == false);
    BOOST_CHECK(pnode3->IsAddrFetchConn() == false);
    BOOST_CHECK(pnode3->IsInboundConn() == false);
    BOOST_CHECK(pnode3->m_inbound_onion == false);
    BOOST_CHECK_EQUAL(pnode3->ConnectedThroughNetwork(), Network::NET_IPV4);

    std::unique_ptr<CNode> pnode4 = std::make_unique<CNode>(id++,
                                                            /*sock=*/nullptr,
                                                            addr,
                                                            /*nKeyedNetGroupIn=*/1,
                                                            /*nLocalHostNonceIn=*/1,
                                                            CAddress(),
                                                            pszDest,
                                                            ConnectionType::INBOUND,
                                                            /*inbound_onion=*/true);
    BOOST_CHECK(pnode4->IsFullOutboundConn() == false);
    BOOST_CHECK(pnode4->IsManualConn() == false);
    BOOST_CHECK(pnode4->IsBlockOnlyConn() == false);
    BOOST_CHECK(pnode4->IsFeelerConn() == false);
    BOOST_CHECK(pnode4->IsAddrFetchConn() == false);
    BOOST_CHECK(pnode4->IsInboundConn() == true);
    BOOST_CHECK(pnode4->m_inbound_onion == true);
    BOOST_CHECK_EQUAL(pnode4->ConnectedThroughNetwork(), Network::NET_ONION);
}

BOOST_AUTO_TEST_CASE(cnetaddr_basic)
{
    CNetAddr addr;

    // IPv4, INADDR_ANY
    addr = LookupHost("0.0.0.0", false).value();
    BOOST_REQUIRE(!addr.IsValid());
    BOOST_REQUIRE(addr.IsIPv4());

    BOOST_CHECK(addr.IsBindAny());
    BOOST_CHECK(addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), "0.0.0.0");

    // IPv4, INADDR_NONE
    addr = LookupHost("255.255.255.255", false).value();
    BOOST_REQUIRE(!addr.IsValid());
    BOOST_REQUIRE(addr.IsIPv4());

    BOOST_CHECK(!addr.IsBindAny());
    BOOST_CHECK(addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), "255.255.255.255");

    // IPv4, casual
    addr = LookupHost("12.34.56.78", false).value();
    BOOST_REQUIRE(addr.IsValid());
    BOOST_REQUIRE(addr.IsIPv4());

    BOOST_CHECK(!addr.IsBindAny());
    BOOST_CHECK(addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), "12.34.56.78");

    // IPv6, in6addr_any
    addr = LookupHost("::", false).value();
    BOOST_REQUIRE(!addr.IsValid());
    BOOST_REQUIRE(addr.IsIPv6());

    BOOST_CHECK(addr.IsBindAny());
    BOOST_CHECK(addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), "::");

    // IPv6, casual
    addr = LookupHost("1122:3344:5566:7788:9900:aabb:ccdd:eeff", false).value();
    BOOST_REQUIRE(addr.IsValid());
    BOOST_REQUIRE(addr.IsIPv6());

    BOOST_CHECK(!addr.IsBindAny());
    BOOST_CHECK(addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), "1122:3344:5566:7788:9900:aabb:ccdd:eeff");

    // IPv6, scoped/link-local. See https://tools.ietf.org/html/rfc4007
    // We support non-negative decimal integers (uint32_t) as zone id indices.
    // Normal link-local scoped address functionality is to append "%" plus the
    // zone id, for example, given a link-local address of "fe80::1" and a zone
    // id of "32", return the address as "fe80::1%32".
    const std::string link_local{"fe80::1"};
    const std::string scoped_addr{link_local + "%32"};
    addr = LookupHost(scoped_addr, false).value();
    BOOST_REQUIRE(addr.IsValid());
    BOOST_REQUIRE(addr.IsIPv6());
    BOOST_CHECK(!addr.IsBindAny());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), scoped_addr);

    // Test that the delimiter "%" and default zone id of 0 can be omitted for the default scope.
    addr = LookupHost(link_local + "%0", false).value();
    BOOST_REQUIRE(addr.IsValid());
    BOOST_REQUIRE(addr.IsIPv6());
    BOOST_CHECK(!addr.IsBindAny());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), link_local);

    // TORv2, no longer supported
    BOOST_CHECK(!addr.SetSpecial("6hzph5hv6337r6p2.onion"));

    // TORv3
    const char* torv3_addr = "pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscryd.onion";
    BOOST_REQUIRE(addr.SetSpecial(torv3_addr));
    BOOST_REQUIRE(addr.IsValid());
    BOOST_REQUIRE(addr.IsTor());

    BOOST_CHECK(!addr.IsI2P());
    BOOST_CHECK(!addr.IsBindAny());
    BOOST_CHECK(!addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), torv3_addr);

    // TORv3, broken, with wrong checksum
    BOOST_CHECK(!addr.SetSpecial("pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscsad.onion"));

    // TORv3, broken, with wrong version
    BOOST_CHECK(!addr.SetSpecial("pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscrye.onion"));

    // TORv3, malicious
    BOOST_CHECK(!addr.SetSpecial(std::string{
        "pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscryd\0wtf.onion", 66}));

    // TOR, bogus length
    BOOST_CHECK(!addr.SetSpecial(std::string{"mfrggzak.onion"}));

    // TOR, invalid base32
    BOOST_CHECK(!addr.SetSpecial(std::string{"mf*g zak.onion"}));

    // I2P
    const char* i2p_addr = "UDHDrtrcetjm5sxzskjyr5ztpeszydbh4dpl3pl4utgqqw2v4jna.b32.I2P";
    BOOST_REQUIRE(addr.SetSpecial(i2p_addr));
    BOOST_REQUIRE(addr.IsValid());
    BOOST_REQUIRE(addr.IsI2P());

    BOOST_CHECK(!addr.IsTor());
    BOOST_CHECK(!addr.IsBindAny());
    BOOST_CHECK(!addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), ToLower(i2p_addr));

    // I2P, correct length, but decodes to less than the expected number of bytes.
    BOOST_CHECK(!addr.SetSpecial("udhdrtrcetjm5sxzskjyr5ztpeszydbh4dpl3pl4utgqqw2v4jn=.b32.i2p"));

    // I2P, extra unnecessary padding
    BOOST_CHECK(!addr.SetSpecial("udhdrtrcetjm5sxzskjyr5ztpeszydbh4dpl3pl4utgqqw2v4jna=.b32.i2p"));

    // I2P, malicious
    BOOST_CHECK(!addr.SetSpecial("udhdrtrcetjm5sxzskjyr5ztpeszydbh4dpl3pl4utgqqw2v\0wtf.b32.i2p"s));

    // I2P, valid but unsupported (56 Base32 characters)
    // See "Encrypted LS with Base 32 Addresses" in
    // https://geti2p.net/spec/encryptedleaseset.txt
    BOOST_CHECK(
        !addr.SetSpecial("pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscsad.b32.i2p"));

    // I2P, invalid base32
    BOOST_CHECK(!addr.SetSpecial(std::string{"tp*szydbh4dp.b32.i2p"}));

    // Internal
    addr.SetInternal("esffpp");
    BOOST_REQUIRE(!addr.IsValid()); // "internal" is considered invalid
    BOOST_REQUIRE(addr.IsInternal());

    BOOST_CHECK(!addr.IsBindAny());
    BOOST_CHECK(addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), "esffpvrt3wpeaygy.internal");

    // Totally bogus
    BOOST_CHECK(!addr.SetSpecial("totally bogus"));
}

BOOST_AUTO_TEST_CASE(cnetaddr_tostring_canonical_ipv6)
{
    // Test that CNetAddr::ToString formats IPv6 addresses with zero compression as described in
    // RFC 5952 ("A Recommendation for IPv6 Address Text Representation").
    const std::map<std::string, std::string> canonical_representations_ipv6{
        {"0000:0000:0000:0000:0000:0000:0000:0000", "::"},
        {"000:0000:000:00:0:00:000:0000", "::"},
        {"000:000:000:000:000:000:000:000", "::"},
        {"00:00:00:00:00:00:00:00", "::"},
        {"0:0:0:0:0:0:0:0", "::"},
        {"0:0:0:0:0:0:0:1", "::1"},
        {"2001:0:0:1:0:0:0:1", "2001:0:0:1::1"},
        {"2001:0db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"},
        {"2001:0db8:85a3:0000:0000:8a2e:0370:7334", "2001:db8:85a3::8a2e:370:7334"},
        {"2001:0db8::0001", "2001:db8::1"},
        {"2001:0db8::0001:0000", "2001:db8::1:0"},
        {"2001:0db8::1:0:0:1", "2001:db8::1:0:0:1"},
        {"2001:db8:0000:0:1::1", "2001:db8::1:0:0:1"},
        {"2001:db8:0000:1:1:1:1:1", "2001:db8:0:1:1:1:1:1"},
        {"2001:db8:0:0:0:0:2:1", "2001:db8::2:1"},
        {"2001:db8:0:0:0::1", "2001:db8::1"},
        {"2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"},
        {"2001:db8:0:0:1::1", "2001:db8::1:0:0:1"},
        {"2001:DB8:0:0:1::1", "2001:db8::1:0:0:1"},
        {"2001:db8:0:0::1", "2001:db8::1"},
        {"2001:db8:0:0:aaaa::1", "2001:db8::aaaa:0:0:1"},
        {"2001:db8:0:1:1:1:1:1", "2001:db8:0:1:1:1:1:1"},
        {"2001:db8:0::1", "2001:db8::1"},
        {"2001:db8:85a3:0:0:8a2e:370:7334", "2001:db8:85a3::8a2e:370:7334"},
        {"2001:db8::0:1", "2001:db8::1"},
        {"2001:db8::0:1:0:0:1", "2001:db8::1:0:0:1"},
        {"2001:DB8::1", "2001:db8::1"},
        {"2001:db8::1", "2001:db8::1"},
        {"2001:db8::1:0:0:1", "2001:db8::1:0:0:1"},
        {"2001:db8::1:1:1:1:1", "2001:db8:0:1:1:1:1:1"},
        {"2001:db8::aaaa:0:0:1", "2001:db8::aaaa:0:0:1"},
        {"2001:db8:aaaa:bbbb:cccc:dddd:0:1", "2001:db8:aaaa:bbbb:cccc:dddd:0:1"},
        {"2001:db8:aaaa:bbbb:cccc:dddd::1", "2001:db8:aaaa:bbbb:cccc:dddd:0:1"},
        {"2001:db8:aaaa:bbbb:cccc:dddd:eeee:0001", "2001:db8:aaaa:bbbb:cccc:dddd:eeee:1"},
        {"2001:db8:aaaa:bbbb:cccc:dddd:eeee:001", "2001:db8:aaaa:bbbb:cccc:dddd:eeee:1"},
        {"2001:db8:aaaa:bbbb:cccc:dddd:eeee:01", "2001:db8:aaaa:bbbb:cccc:dddd:eeee:1"},
        {"2001:db8:aaaa:bbbb:cccc:dddd:eeee:1", "2001:db8:aaaa:bbbb:cccc:dddd:eeee:1"},
        {"2001:db8:aaaa:bbbb:cccc:dddd:eeee:aaaa", "2001:db8:aaaa:bbbb:cccc:dddd:eeee:aaaa"},
        {"2001:db8:aaaa:bbbb:cccc:dddd:eeee:AAAA", "2001:db8:aaaa:bbbb:cccc:dddd:eeee:aaaa"},
        {"2001:db8:aaaa:bbbb:cccc:dddd:eeee:AaAa", "2001:db8:aaaa:bbbb:cccc:dddd:eeee:aaaa"},
    };
    for (const auto& [input_address, expected_canonical_representation_output] : canonical_representations_ipv6) {
        const std::optional<CNetAddr> net_addr{LookupHost(input_address, false)};
        BOOST_REQUIRE(net_addr.value().IsIPv6());
        BOOST_CHECK_EQUAL(net_addr.value().ToStringAddr(), expected_canonical_representation_output);
    }
}

BOOST_AUTO_TEST_CASE(cnetaddr_serialize_v1)
{
    CNetAddr addr;
    DataStream s{};
    const auto ser_params{CAddress::V1_NETWORK};

    s << WithParams(ser_params, addr);
    BOOST_CHECK_EQUAL(HexStr(s), "00000000000000000000000000000000");
    s.clear();

    addr = LookupHost("1.2.3.4", false).value();
    s << WithParams(ser_params, addr);
    BOOST_CHECK_EQUAL(HexStr(s), "00000000000000000000ffff01020304");
    s.clear();

    addr = LookupHost("1a1b:2a2b:3a3b:4a4b:5a5b:6a6b:7a7b:8a8b", false).value();
    s << WithParams(ser_params, addr);
    BOOST_CHECK_EQUAL(HexStr(s), "1a1b2a2b3a3b4a4b5a5b6a6b7a7b8a8b");
    s.clear();

    // TORv2, no longer supported
    BOOST_CHECK(!addr.SetSpecial("6hzph5hv6337r6p2.onion"));

    BOOST_REQUIRE(addr.SetSpecial("pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscryd.onion"));
    s << WithParams(ser_params, addr);
    BOOST_CHECK_EQUAL(HexStr(s), "00000000000000000000000000000000");
    s.clear();

    addr.SetInternal("a");
    s << WithParams(ser_params, addr);
    BOOST_CHECK_EQUAL(HexStr(s), "fd6b88c08724ca978112ca1bbdcafac2");
    s.clear();
}

BOOST_AUTO_TEST_CASE(cnetaddr_serialize_v2)
{
    CNetAddr addr;
    DataStream s{};
    const auto ser_params{CAddress::V2_NETWORK};

    s << WithParams(ser_params, addr);
    BOOST_CHECK_EQUAL(HexStr(s), "021000000000000000000000000000000000");
    s.clear();

    addr = LookupHost("1.2.3.4", false).value();
    s << WithParams(ser_params, addr);
    BOOST_CHECK_EQUAL(HexStr(s), "010401020304");
    s.clear();

    addr = LookupHost("1a1b:2a2b:3a3b:4a4b:5a5b:6a6b:7a7b:8a8b", false).value();
    s << WithParams(ser_params, addr);
    BOOST_CHECK_EQUAL(HexStr(s), "02101a1b2a2b3a3b4a4b5a5b6a6b7a7b8a8b");
    s.clear();

    // TORv2, no longer supported
    BOOST_CHECK(!addr.SetSpecial("6hzph5hv6337r6p2.onion"));

    BOOST_REQUIRE(addr.SetSpecial("kpgvmscirrdqpekbqjsvw5teanhatztpp2gl6eee4zkowvwfxwenqaid.onion"));
    s << WithParams(ser_params, addr);
    BOOST_CHECK_EQUAL(HexStr(s), "042053cd5648488c4707914182655b7664034e09e66f7e8cbf1084e654eb56c5bd88");
    s.clear();

    BOOST_REQUIRE(addr.SetInternal("a"));
    s << WithParams(ser_params, addr);
    BOOST_CHECK_EQUAL(HexStr(s), "0210fd6b88c08724ca978112ca1bbdcafac2");
    s.clear();
}

BOOST_AUTO_TEST_CASE(cnetaddr_unserialize_v2)
{
    CNetAddr addr;
    DataStream s{};
    const auto ser_params{CAddress::V2_NETWORK};

    // Valid IPv4.
    s << Span{ParseHex("01"          // network type (IPv4)
                       "04"          // address length
                       "01020304")}; // address
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(addr.IsValid());
    BOOST_CHECK(addr.IsIPv4());
    BOOST_CHECK(addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), "1.2.3.4");
    BOOST_REQUIRE(s.empty());

    // Invalid IPv4, valid length but address itself is shorter.
    s << Span{ParseHex("01"      // network type (IPv4)
                       "04"      // address length
                       "0102")}; // address
    BOOST_CHECK_EXCEPTION(s >> WithParams(ser_params, addr), std::ios_base::failure, HasReason("end of data"));
    BOOST_REQUIRE(!s.empty()); // The stream is not consumed on invalid input.
    s.clear();

    // Invalid IPv4, with bogus length.
    s << Span{ParseHex("01"          // network type (IPv4)
                       "05"          // address length
                       "01020304")}; // address
    BOOST_CHECK_EXCEPTION(s >> WithParams(ser_params, addr), std::ios_base::failure,
                          HasReason("BIP155 IPv4 address with length 5 (should be 4)"));
    BOOST_REQUIRE(!s.empty()); // The stream is not consumed on invalid input.
    s.clear();

    // Invalid IPv4, with extreme length.
    s << Span{ParseHex("01"          // network type (IPv4)
                       "fd0102"      // address length (513 as CompactSize)
                       "01020304")}; // address
    BOOST_CHECK_EXCEPTION(s >> WithParams(ser_params, addr), std::ios_base::failure,
                          HasReason("Address too long: 513 > 512"));
    BOOST_REQUIRE(!s.empty()); // The stream is not consumed on invalid input.
    s.clear();

    // Valid IPv6.
    s << Span{ParseHex("02"                                  // network type (IPv6)
                       "10"                                  // address length
                       "0102030405060708090a0b0c0d0e0f10")}; // address
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(addr.IsValid());
    BOOST_CHECK(addr.IsIPv6());
    BOOST_CHECK(addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), "102:304:506:708:90a:b0c:d0e:f10");
    BOOST_REQUIRE(s.empty());

    // Valid IPv6, contains embedded "internal".
    s << Span{ParseHex(
        "02"                                  // network type (IPv6)
        "10"                                  // address length
        "fd6b88c08724ca978112ca1bbdcafac2")}; // address: 0xfd + sha256("bitcoin")[0:5] +
                                              // sha256(name)[0:10]
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(addr.IsInternal());
    BOOST_CHECK(addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), "zklycewkdo64v6wc.internal");
    BOOST_REQUIRE(s.empty());

    // Invalid IPv6, with bogus length.
    s << Span{ParseHex("02"    // network type (IPv6)
                       "04"    // address length
                       "00")}; // address
    BOOST_CHECK_EXCEPTION(s >> WithParams(ser_params, addr), std::ios_base::failure,
                          HasReason("BIP155 IPv6 address with length 4 (should be 16)"));
    BOOST_REQUIRE(!s.empty()); // The stream is not consumed on invalid input.
    s.clear();

    // Invalid IPv6, contains embedded IPv4.
    s << Span{ParseHex("02"                                  // network type (IPv6)
                       "10"                                  // address length
                       "00000000000000000000ffff01020304")}; // address
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(!addr.IsValid());
    BOOST_REQUIRE(s.empty());

    // Invalid IPv6, contains embedded TORv2.
    s << Span{ParseHex("02"                                  // network type (IPv6)
                       "10"                                  // address length
                       "fd87d87eeb430102030405060708090a")}; // address
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(!addr.IsValid());
    BOOST_REQUIRE(s.empty());

    // TORv2, no longer supported.
    s << Span{ParseHex("03"                      // network type (TORv2)
                       "0a"                      // address length
                       "f1f2f3f4f5f6f7f8f9fa")}; // address
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(!addr.IsValid());
    BOOST_REQUIRE(s.empty());

    // Valid TORv3.
    s << Span{ParseHex("04"                               // network type (TORv3)
                       "20"                               // address length
                       "79bcc625184b05194975c28b66b66b04" // address
                       "69f7f6556fb1ac3189a79b40dda32f1f"
                       )};
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(addr.IsValid());
    BOOST_CHECK(addr.IsTor());
    BOOST_CHECK(!addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(),
                      "pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscryd.onion");
    BOOST_REQUIRE(s.empty());

    // Invalid TORv3, with bogus length.
    s << Span{ParseHex("04" // network type (TORv3)
                       "00" // address length
                       "00" // address
                       )};
    BOOST_CHECK_EXCEPTION(s >> WithParams(ser_params, addr), std::ios_base::failure,
                          HasReason("BIP155 TORv3 address with length 0 (should be 32)"));
    BOOST_REQUIRE(!s.empty()); // The stream is not consumed on invalid input.
    s.clear();

    // Valid I2P.
    s << Span{ParseHex("05"                               // network type (I2P)
                       "20"                               // address length
                       "a2894dabaec08c0051a481a6dac88b64" // address
                       "f98232ae42d4b6fd2fa81952dfe36a87")};
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(addr.IsValid());
    BOOST_CHECK(addr.IsI2P());
    BOOST_CHECK(!addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(),
                      "ukeu3k5oycgaauneqgtnvselmt4yemvoilkln7jpvamvfx7dnkdq.b32.i2p");
    BOOST_REQUIRE(s.empty());

    // Invalid I2P, with bogus length.
    s << Span{ParseHex("05" // network type (I2P)
                       "03" // address length
                       "00" // address
                       )};
    BOOST_CHECK_EXCEPTION(s >> WithParams(ser_params, addr), std::ios_base::failure,
                          HasReason("BIP155 I2P address with length 3 (should be 32)"));
    BOOST_REQUIRE(!s.empty()); // The stream is not consumed on invalid input.
    s.clear();

    // Valid CJDNS.
    s << Span{ParseHex("06"                               // network type (CJDNS)
                       "10"                               // address length
                       "fc000001000200030004000500060007" // address
                       )};
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(addr.IsValid());
    BOOST_CHECK(addr.IsCJDNS());
    BOOST_CHECK(!addr.IsAddrV1Compatible());
    BOOST_CHECK_EQUAL(addr.ToStringAddr(), "fc00:1:2:3:4:5:6:7");
    BOOST_REQUIRE(s.empty());

    // Invalid CJDNS, wrong prefix.
    s << Span{ParseHex("06"                               // network type (CJDNS)
                       "10"                               // address length
                       "aa000001000200030004000500060007" // address
                       )};
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(addr.IsCJDNS());
    BOOST_CHECK(!addr.IsValid());
    BOOST_REQUIRE(s.empty());

    // Invalid CJDNS, with bogus length.
    s << Span{ParseHex("06" // network type (CJDNS)
                       "01" // address length
                       "00" // address
                       )};
    BOOST_CHECK_EXCEPTION(s >> WithParams(ser_params, addr), std::ios_base::failure,
                          HasReason("BIP155 CJDNS address with length 1 (should be 16)"));
    BOOST_REQUIRE(!s.empty()); // The stream is not consumed on invalid input.
    s.clear();

    // Unknown, with extreme length.
    s << Span{ParseHex("aa"             // network type (unknown)
                       "fe00000002"     // address length (CompactSize's MAX_SIZE)
                       "01020304050607" // address
                       )};
    BOOST_CHECK_EXCEPTION(s >> WithParams(ser_params, addr), std::ios_base::failure,
                          HasReason("Address too long: 33554432 > 512"));
    BOOST_REQUIRE(!s.empty()); // The stream is not consumed on invalid input.
    s.clear();

    // Unknown, with reasonable length.
    s << Span{ParseHex("aa"       // network type (unknown)
                       "04"       // address length
                       "01020304" // address
                       )};
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(!addr.IsValid());
    BOOST_REQUIRE(s.empty());

    // Unknown, with zero length.
    s << Span{ParseHex("aa" // network type (unknown)
                       "00" // address length
                       ""   // address
                       )};
    s >> WithParams(ser_params, addr);
    BOOST_CHECK(!addr.IsValid());
    BOOST_REQUIRE(s.empty());
}

// prior to PR #14728, this test triggers an undefined behavior
BOOST_AUTO_TEST_CASE(ipv4_peer_with_ipv6_addrMe_test)
{
    // set up local addresses; all that's necessary to reproduce the bug is
    // that a normal IPv4 address is among the entries, but if this address is
    // !IsRoutable the undefined behavior is easier to trigger deterministically
    in_addr raw_addr;
    raw_addr.s_addr = htonl(0x7f000001);
    const CNetAddr mapLocalHost_entry = CNetAddr(raw_addr);
    {
        LOCK(g_maplocalhost_mutex);
        LocalServiceInfo lsi;
        lsi.nScore = 23;
        lsi.nPort = 42;
        mapLocalHost[mapLocalHost_entry] = lsi;
    }

    // create a peer with an IPv4 address
    in_addr ipv4AddrPeer;
    ipv4AddrPeer.s_addr = 0xa0b0c001;
    CAddress addr = CAddress(CService(ipv4AddrPeer, 7777), NODE_NETWORK);
    std::unique_ptr<CNode> pnode = std::make_unique<CNode>(/*id=*/0,
                                                           /*sock=*/nullptr,
                                                           addr,
                                                           /*nKeyedNetGroupIn=*/0,
                                                           /*nLocalHostNonceIn=*/0,
                                                           CAddress{},
                                                           /*pszDest=*/std::string{},
                                                           ConnectionType::OUTBOUND_FULL_RELAY,
                                                           /*inbound_onion=*/false);
    pnode->fSuccessfullyConnected.store(true);

    // the peer claims to be reaching us via IPv6
    in6_addr ipv6AddrLocal;
    memset(ipv6AddrLocal.s6_addr, 0, 16);
    ipv6AddrLocal.s6_addr[0] = 0xcc;
    CAddress addrLocal = CAddress(CService(ipv6AddrLocal, 7777), NODE_NETWORK);
    pnode->SetAddrLocal(addrLocal);

    // before patch, this causes undefined behavior detectable with clang's -fsanitize=memory
    GetLocalAddrForPeer(*pnode);

    // suppress no-checks-run warning; if this test fails, it's by triggering a sanitizer
    BOOST_CHECK(1);

    // Cleanup, so that we don't confuse other tests.
    {
        LOCK(g_maplocalhost_mutex);
        mapLocalHost.erase(mapLocalHost_entry);
    }
}

BOOST_AUTO_TEST_CASE(get_local_addr_for_peer_port)
{
    // Test that GetLocalAddrForPeer() properly selects the address to self-advertise:
    //
    // 1. GetLocalAddrForPeer() calls GetLocalAddress() which returns an address that is
    //    not routable.
    // 2. GetLocalAddrForPeer() overrides the address with whatever the peer has told us
    //    he sees us as.
    // 2.1. For inbound connections we must override both the address and the port.
    // 2.2. For outbound connections we must override only the address.

    // Pretend that we bound to this port.
    const uint16_t bind_port = 20001;
    m_node.args->ForceSetArg("-bind", strprintf("3.4.5.6:%u", bind_port));

    // Our address:port as seen from the peer, completely different from the above.
    in_addr peer_us_addr;
    peer_us_addr.s_addr = htonl(0x02030405);
    const CService peer_us{peer_us_addr, 20002};

    // Create a peer with a routable IPv4 address (outbound).
    in_addr peer_out_in_addr;
    peer_out_in_addr.s_addr = htonl(0x01020304);
    CNode peer_out{/*id=*/0,
                   /*sock=*/nullptr,
                   /*addrIn=*/CAddress{CService{peer_out_in_addr, 15714}, NODE_NETWORK},
                   /*nKeyedNetGroupIn=*/0,
                   /*nLocalHostNonceIn=*/0,
                   /*addrBindIn=*/CAddress{},
                   /*addrNameIn=*/std::string{},
                   /*conn_type_in=*/ConnectionType::OUTBOUND_FULL_RELAY,
                   /*inbound_onion=*/false};
    peer_out.fSuccessfullyConnected = true;
    peer_out.SetAddrLocal(peer_us);

    // Without the fix peer_us:15714 is chosen instead of the proper peer_us:bind_port.
    auto chosen_local_addr = GetLocalAddrForPeer(peer_out);
    BOOST_REQUIRE(chosen_local_addr);
    const CService expected{peer_us_addr, bind_port};
    BOOST_CHECK(*chosen_local_addr == expected);

    // Create a peer with a routable IPv4 address (inbound).
    in_addr peer_in_in_addr;
    peer_in_in_addr.s_addr = htonl(0x05060708);
    CNode peer_in{/*id=*/0,
                  /*sock=*/nullptr,
                  /*addrIn=*/CAddress{CService{peer_in_in_addr, 15714}, NODE_NETWORK},
                  /*nKeyedNetGroupIn=*/0,
                  /*nLocalHostNonceIn=*/0,
                  /*addrBindIn=*/CAddress{},
                  /*addrNameIn=*/std::string{},
                  /*conn_type_in=*/ConnectionType::INBOUND,
                  /*inbound_onion=*/false};
    peer_in.fSuccessfullyConnected = true;
    peer_in.SetAddrLocal(peer_us);

    // Without the fix peer_us:15714 is chosen instead of the proper peer_us:peer_us.GetPort().
    chosen_local_addr = GetLocalAddrForPeer(peer_in);
    BOOST_REQUIRE(chosen_local_addr);
    BOOST_CHECK(*chosen_local_addr == peer_us);

    m_node.args->ForceSetArg("-bind", "");
}

BOOST_AUTO_TEST_CASE(LimitedAndReachable_Network)
{
    BOOST_CHECK(g_reachable_nets.Contains(NET_IPV4));
    BOOST_CHECK(g_reachable_nets.Contains(NET_IPV6));
    BOOST_CHECK(g_reachable_nets.Contains(NET_ONION));
    BOOST_CHECK(g_reachable_nets.Contains(NET_I2P));
    BOOST_CHECK(g_reachable_nets.Contains(NET_CJDNS));

    g_reachable_nets.Remove(NET_IPV4);
    g_reachable_nets.Remove(NET_IPV6);
    g_reachable_nets.Remove(NET_ONION);
    g_reachable_nets.Remove(NET_I2P);
    g_reachable_nets.Remove(NET_CJDNS);

    BOOST_CHECK(!g_reachable_nets.Contains(NET_IPV4));
    BOOST_CHECK(!g_reachable_nets.Contains(NET_IPV6));
    BOOST_CHECK(!g_reachable_nets.Contains(NET_ONION));
    BOOST_CHECK(!g_reachable_nets.Contains(NET_I2P));
    BOOST_CHECK(!g_reachable_nets.Contains(NET_CJDNS));

    g_reachable_nets.Add(NET_IPV4);
    g_reachable_nets.Add(NET_IPV6);
    g_reachable_nets.Add(NET_ONION);
    g_reachable_nets.Add(NET_I2P);
    g_reachable_nets.Add(NET_CJDNS);

    BOOST_CHECK(g_reachable_nets.Contains(NET_IPV4));
    BOOST_CHECK(g_reachable_nets.Contains(NET_IPV6));
    BOOST_CHECK(g_reachable_nets.Contains(NET_ONION));
    BOOST_CHECK(g_reachable_nets.Contains(NET_I2P));
    BOOST_CHECK(g_reachable_nets.Contains(NET_CJDNS));
}

BOOST_AUTO_TEST_CASE(LimitedAndReachable_NetworkCaseUnroutableAndInternal)
{
    // Should be reachable by default.
    BOOST_CHECK(g_reachable_nets.Contains(NET_UNROUTABLE));
    BOOST_CHECK(g_reachable_nets.Contains(NET_INTERNAL));

    g_reachable_nets.RemoveAll();

    BOOST_CHECK(!g_reachable_nets.Contains(NET_UNROUTABLE));
    BOOST_CHECK(!g_reachable_nets.Contains(NET_INTERNAL));

    g_reachable_nets.Add(NET_IPV4);
    g_reachable_nets.Add(NET_IPV6);
    g_reachable_nets.Add(NET_ONION);
    g_reachable_nets.Add(NET_I2P);
    g_reachable_nets.Add(NET_CJDNS);
    g_reachable_nets.Add(NET_UNROUTABLE);
    g_reachable_nets.Add(NET_INTERNAL);
}

CNetAddr UtilBuildAddress(unsigned char p1, unsigned char p2, unsigned char p3, unsigned char p4)
{
    unsigned char ip[] = {p1, p2, p3, p4};

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sockaddr_in)); // initialize the memory block
    memcpy(&(sa.sin_addr), &ip, sizeof(ip));
    return CNetAddr(sa.sin_addr);
}


BOOST_AUTO_TEST_CASE(LimitedAndReachable_CNetAddr)
{
    CNetAddr addr = UtilBuildAddress(0x001, 0x001, 0x001, 0x001); // 1.1.1.1

    g_reachable_nets.Add(NET_IPV4);
    BOOST_CHECK(g_reachable_nets.Contains(addr));

    g_reachable_nets.Remove(NET_IPV4);
    BOOST_CHECK(!g_reachable_nets.Contains(addr));

    g_reachable_nets.Add(NET_IPV4); // have to reset this, because this is stateful.
}


BOOST_AUTO_TEST_CASE(LocalAddress_BasicLifecycle)
{
    CService addr = CService(UtilBuildAddress(0x002, 0x001, 0x001, 0x001), 1000); // 2.1.1.1:1000

    g_reachable_nets.Add(NET_IPV4);

    BOOST_CHECK(!IsLocal(addr));
    BOOST_CHECK(AddLocal(addr, 1000));
    BOOST_CHECK(IsLocal(addr));

    RemoveLocal(addr);
    BOOST_CHECK(!IsLocal(addr));
}

BOOST_AUTO_TEST_CASE(initial_advertise_from_version_message)
{
    LOCK(NetEventsInterface::g_msgproc_mutex);

    // Tests the following scenario:
    // * -bind=3.4.5.6:20001 is specified
    // * we make an outbound connection to a peer
    // * the peer reports he sees us as 2.3.4.5:20002 in the version message
    //   (20002 is a random port assigned by our OS for the outgoing TCP connection,
    //   we cannot accept connections to it)
    // * we should self-advertise to that peer as 2.3.4.5:20001

    // Pretend that we bound to this port.
    const uint16_t bind_port = 20001;
    m_node.args->ForceSetArg("-bind", strprintf("3.4.5.6:%u", bind_port));
    m_node.args->ForceSetArg("-capturemessages", "1");

    // Our address:port as seen from the peer - 2.3.4.5:20002 (different from the above).
    in_addr peer_us_addr;
    peer_us_addr.s_addr = htonl(0x02030405);
    const CService peer_us{peer_us_addr, 20002};

    // Create a peer with a routable IPv4 address.
    in_addr peer_in_addr;
    peer_in_addr.s_addr = htonl(0x01020304);
    CNode peer{/*id=*/0,
               /*sock=*/nullptr,
               /*addrIn=*/CAddress{CService{peer_in_addr, 15714}, NODE_NETWORK},
               /*nKeyedNetGroupIn=*/0,
               /*nLocalHostNonceIn=*/0,
               /*addrBindIn=*/CAddress{},
               /*addrNameIn=*/std::string{},
               /*conn_type_in=*/ConnectionType::OUTBOUND_FULL_RELAY,
               /*inbound_onion=*/false};

    const uint64_t services{NODE_NETWORK | NODE_WITNESS};
    const int64_t time{0};
    const CNetMsgMaker msg_maker{PROTOCOL_VERSION};

    // Force ChainstateManager::IsInitialBlockDownload() to return false.
    // Otherwise PushAddress() isn't called by PeerManager::ProcessMessage().
    auto& chainman = static_cast<TestChainstateManager&>(*m_node.chainman);
    chainman.JumpOutOfIbd();

    m_node.peerman->InitializeNode(peer, NODE_NETWORK);

    std::atomic<bool> interrupt_dummy{false};
    std::chrono::microseconds time_received_dummy{0};

    const auto msg_version =
        msg_maker.Make(NetMsgType::VERSION, PROTOCOL_VERSION, services, time, services, CAddress::V1_NETWORK(peer_us));
    CDataStream msg_version_stream{msg_version.data, SER_NETWORK};

    m_node.peerman->ProcessMessage(
        peer, NetMsgType::VERSION, msg_version_stream, time_received_dummy, interrupt_dummy);

    const auto msg_verack = msg_maker.Make(NetMsgType::VERACK);
    CDataStream msg_verack_stream{msg_verack.data, SER_NETWORK};

    // Will set peer.fSuccessfullyConnected to true (necessary in SendMessages()).
    m_node.peerman->ProcessMessage(
        peer, NetMsgType::VERACK, msg_verack_stream, time_received_dummy, interrupt_dummy);

    // Ensure that peer_us_addr:bind_port is sent to the peer.
    const CService expected{peer_us_addr, bind_port};
    bool sent{false};

    const auto CaptureMessageOrig = CaptureMessage;
    CaptureMessage = [&sent, &expected](const CAddress& addr,
                                        const std::string& msg_type,
                                        Span<const unsigned char> data,
                                        bool is_incoming) -> void {
        if (!is_incoming && msg_type == "addr") {
            DataStream s{data};
            std::vector<CAddress> addresses;

            s >> CAddress::V1_NETWORK(addresses);

            for (const auto& addr : addresses) {
                if (addr == expected) {
                    sent = true;
                    return;
                }
            }
        }
    };

    m_node.peerman->SendMessages(&peer);

    BOOST_CHECK(sent);

    CaptureMessage = CaptureMessageOrig;
    chainman.ResetIbd();
    m_node.args->ForceSetArg("-capturemessages", "0");
    m_node.args->ForceSetArg("-bind", "");
    // PeerManager::ProcessMessage() calls AddTimeData() which changes the internal state
    // in timedata.cpp and later confuses the test "timedata_tests/addtimedata". Thus reset
    // that state as it was before our test was run.
    TestOnlyResetTimeData();
}


BOOST_AUTO_TEST_CASE(advertise_local_address)
{
    auto CreatePeer = [](const CAddress& addr) {
        return std::make_unique<CNode>(/*id=*/0,
                                       /*sock=*/nullptr,
                                       addr,
                                       /*nKeyedNetGroupIn=*/0,
                                       /*nLocalHostNonceIn=*/0,
                                       CAddress{},
                                       /*pszDest=*/std::string{},
                                       ConnectionType::OUTBOUND_FULL_RELAY,
                                       /*inbound_onion=*/false);
    };
    g_reachable_nets.Add(NET_CJDNS);

    CAddress addr_ipv4{Lookup("1.2.3.4", 15714, false).value(), NODE_NONE};
    BOOST_REQUIRE(addr_ipv4.IsValid());
    BOOST_REQUIRE(addr_ipv4.IsIPv4());

    CAddress addr_ipv6{Lookup("1122:3344:5566:7788:9900:aabb:ccdd:eeff", 15714, false).value(), NODE_NONE};
    BOOST_REQUIRE(addr_ipv6.IsValid());
    BOOST_REQUIRE(addr_ipv6.IsIPv6());

    CAddress addr_ipv6_tunnel{Lookup("2002:3344:5566:7788:9900:aabb:ccdd:eeff", 15714, false).value(), NODE_NONE};
    BOOST_REQUIRE(addr_ipv6_tunnel.IsValid());
    BOOST_REQUIRE(addr_ipv6_tunnel.IsIPv6());
    BOOST_REQUIRE(addr_ipv6_tunnel.IsRFC3964());

    CAddress addr_teredo{Lookup("2001:0000:5566:7788:9900:aabb:ccdd:eeff", 15714, false).value(), NODE_NONE};
    BOOST_REQUIRE(addr_teredo.IsValid());
    BOOST_REQUIRE(addr_teredo.IsIPv6());
    BOOST_REQUIRE(addr_teredo.IsRFC4380());

    CAddress addr_onion;
    BOOST_REQUIRE(addr_onion.SetSpecial("pg6mmjiyjmcrsslvykfwnntlaru7p5svn6y2ymmju6nubxndf4pscryd.onion"));
    BOOST_REQUIRE(addr_onion.IsValid());
    BOOST_REQUIRE(addr_onion.IsTor());

    CAddress addr_i2p;
    BOOST_REQUIRE(addr_i2p.SetSpecial("udhdrtrcetjm5sxzskjyr5ztpeszydbh4dpl3pl4utgqqw2v4jna.b32.i2p"));
    BOOST_REQUIRE(addr_i2p.IsValid());
    BOOST_REQUIRE(addr_i2p.IsI2P());

    CService service_cjdns{Lookup("fc00:3344:5566:7788:9900:aabb:ccdd:eeff", 15714, false).value(), NODE_NONE};
    CAddress addr_cjdns{MaybeFlipIPv6toCJDNS(service_cjdns), NODE_NONE};
    BOOST_REQUIRE(addr_cjdns.IsValid());
    BOOST_REQUIRE(addr_cjdns.IsCJDNS());

    const auto peer_ipv4{CreatePeer(addr_ipv4)};
    const auto peer_ipv6{CreatePeer(addr_ipv6)};
    const auto peer_ipv6_tunnel{CreatePeer(addr_ipv6_tunnel)};
    const auto peer_teredo{CreatePeer(addr_teredo)};
    const auto peer_onion{CreatePeer(addr_onion)};
    const auto peer_i2p{CreatePeer(addr_i2p)};
    const auto peer_cjdns{CreatePeer(addr_cjdns)};

    // one local clearnet address - advertise to all but privacy peers
    AddLocal(addr_ipv4);
    BOOST_CHECK(GetLocalAddress(*peer_ipv4) == addr_ipv4);
    BOOST_CHECK(GetLocalAddress(*peer_ipv6) == addr_ipv4);
    BOOST_CHECK(GetLocalAddress(*peer_ipv6_tunnel) == addr_ipv4);
    BOOST_CHECK(GetLocalAddress(*peer_teredo) == addr_ipv4);
    BOOST_CHECK(GetLocalAddress(*peer_cjdns) == addr_ipv4);
    BOOST_CHECK(!GetLocalAddress(*peer_onion).IsValid());
    BOOST_CHECK(!GetLocalAddress(*peer_i2p).IsValid());
    RemoveLocal(addr_ipv4);

    // local privacy addresses - don't advertise to clearnet peers
    AddLocal(addr_onion);
    AddLocal(addr_i2p);
    BOOST_CHECK(!GetLocalAddress(*peer_ipv4).IsValid());
    BOOST_CHECK(!GetLocalAddress(*peer_ipv6).IsValid());
    BOOST_CHECK(!GetLocalAddress(*peer_ipv6_tunnel).IsValid());
    BOOST_CHECK(!GetLocalAddress(*peer_teredo).IsValid());
    BOOST_CHECK(!GetLocalAddress(*peer_cjdns).IsValid());
    BOOST_CHECK(GetLocalAddress(*peer_onion) == addr_onion);
    BOOST_CHECK(GetLocalAddress(*peer_i2p) == addr_i2p);
    RemoveLocal(addr_onion);
    RemoveLocal(addr_i2p);

    // local addresses from all networks
    AddLocal(addr_ipv4);
    AddLocal(addr_ipv6);
    AddLocal(addr_ipv6_tunnel);
    AddLocal(addr_teredo);
    AddLocal(addr_onion);
    AddLocal(addr_i2p);
    AddLocal(addr_cjdns);
    BOOST_CHECK(GetLocalAddress(*peer_ipv4) == addr_ipv4);
    BOOST_CHECK(GetLocalAddress(*peer_ipv6) == addr_ipv6);
    BOOST_CHECK(GetLocalAddress(*peer_ipv6_tunnel) == addr_ipv6);
    BOOST_CHECK(GetLocalAddress(*peer_teredo) == addr_ipv4);
    BOOST_CHECK(GetLocalAddress(*peer_onion) == addr_onion);
    BOOST_CHECK(GetLocalAddress(*peer_i2p) == addr_i2p);
    BOOST_CHECK(GetLocalAddress(*peer_cjdns) == addr_cjdns);
    RemoveLocal(addr_ipv4);
    RemoveLocal(addr_ipv6);
    RemoveLocal(addr_ipv6_tunnel);
    RemoveLocal(addr_teredo);
    RemoveLocal(addr_onion);
    RemoveLocal(addr_i2p);
    RemoveLocal(addr_cjdns);
}

namespace {

CKey GenerateRandomTestKey() noexcept
{
    CKey key;
    uint256 key_data = InsecureRand256();
    key.Set(key_data.begin(), key_data.end(), true);
    return key;
}

/** A class for scenario-based tests of V2Transport
 *
 * Each V2TransportTester encapsulates a V2Transport (the one being tested), and can be told to
 * interact with it. To do so, it also encapsulates a BIP324Cipher to act as the other side. A
 * second V2Transport is not used, as doing so would not permit scenarios that involve sending
 * invalid data, or ones using BIP324 features that are not implemented on the sending
 * side (like decoy packets).
 */
class V2TransportTester
{
    V2Transport m_transport; //!< V2Transport being tested
    BIP324Cipher m_cipher; //!< Cipher to help with the other side
    bool m_test_initiator; //!< Whether m_transport is the initiator (true) or responder (false)

    std::vector<uint8_t> m_sent_garbage; //!< The garbage we've sent to m_transport.
    std::vector<uint8_t> m_recv_garbage; //!< The garbage we've received from m_transport.
    std::vector<uint8_t> m_to_send; //!< Bytes we have queued up to send to m_transport.
    std::vector<uint8_t> m_received; //!< Bytes we have received from m_transport.
    std::deque<CSerializedNetMsg> m_msg_to_send; //!< Messages to be sent *by* m_transport to us.
    bool m_sent_aad{false};

public:
    /** Construct a tester object. test_initiator: whether the tested transport is initiator. */
    V2TransportTester(bool test_initiator) :
        m_transport(0, test_initiator, SER_NETWORK),
        m_cipher{GenerateRandomTestKey(), MakeByteSpan(InsecureRand256())},
        m_test_initiator(test_initiator) {}

    /** Data type returned by Interact:
     *
     * - std::nullopt: transport error occurred
     * - otherwise: a vector of
     *   - std::nullopt: invalid message received
     *   - otherwise: a CNetMessage retrieved
     */
    using InteractResult = std::optional<std::vector<std::optional<CNetMessage>>>;

    /** Send/receive scheduled/available bytes and messages.
     *
     * This is the only function that interacts with the transport being tested; everything else is
     * scheduling things done by Interact(), or processing things learned by it.
     */
    InteractResult Interact()
    {
        std::vector<std::optional<CNetMessage>> ret;
        while (true) {
            bool progress{false};
            // Send bytes from m_to_send to the transport.
            if (!m_to_send.empty()) {
                Span<const uint8_t> to_send = Span{m_to_send}.first(1 + InsecureRandRange(m_to_send.size()));
                size_t old_len = to_send.size();
                if (!m_transport.ReceivedBytes(to_send)) {
                    return std::nullopt; // transport error occurred
                }
                if (old_len != to_send.size()) {
                    progress = true;
                    m_to_send.erase(m_to_send.begin(), m_to_send.begin() + (old_len - to_send.size()));
                }
            }
            // Retrieve messages received by the transport.
            if (m_transport.ReceivedMessageComplete() && (!progress || InsecureRandBool())) {
                bool reject{false};
                auto msg = m_transport.GetReceivedMessage({}, reject);
                if (reject) {
                    ret.emplace_back(std::nullopt);
                } else {
                    ret.emplace_back(std::move(msg));
                }
                progress = true;
            }
            // Enqueue a message to be sent by the transport to us.
            if (!m_msg_to_send.empty() && (!progress || InsecureRandBool())) {
                if (m_transport.SetMessageToSend(m_msg_to_send.front())) {
                    m_msg_to_send.pop_front();
                    progress = true;
                }
            }
            // Receive bytes from the transport.
            const auto& [recv_bytes, _more, _msg_type] = m_transport.GetBytesToSend(!m_msg_to_send.empty());
            if (!recv_bytes.empty() && (!progress || InsecureRandBool())) {
                size_t to_receive = 1 + InsecureRandRange(recv_bytes.size());
                m_received.insert(m_received.end(), recv_bytes.begin(), recv_bytes.begin() + to_receive);
                progress = true;
                m_transport.MarkBytesSent(to_receive);
            }
            if (!progress) break;
        }
        return ret;
    }

    /** Expose the cipher. */
    BIP324Cipher& GetCipher() { return m_cipher; }

    /** Schedule bytes to be sent to the transport. */
    void Send(Span<const uint8_t> data)
    {
        m_to_send.insert(m_to_send.end(), data.begin(), data.end());
    }

    /** Send V1 version message header to the transport. */
    void SendV1Version(const MessageStartChars& magic)
    {
        CMessageHeader hdr(magic, "version", 126 + InsecureRandRange(11));
        CDataStream ser(SER_NETWORK);
        ser << hdr;
        m_to_send.insert(m_to_send.end(), UCharCast(ser.data()), UCharCast(ser.data() + ser.size()));
    }

    /** Schedule bytes to be sent to the transport. */
    void Send(Span<const std::byte> data) { Send(MakeUCharSpan(data)); }

    /** Schedule our ellswift key to be sent to the transport. */
    void SendKey() { Send(m_cipher.GetOurPubKey()); }

    /** Schedule specified garbage to be sent to the transport. */
    void SendGarbage(Span<const uint8_t> garbage)
    {
        // Remember the specified garbage (so we can use it as AAD).
        m_sent_garbage.assign(garbage.begin(), garbage.end());
        // Schedule it for sending.
        Send(m_sent_garbage);
    }

    /** Schedule garbage (of specified length) to be sent to the transport. */
    void SendGarbage(size_t garbage_len)
    {
        // Generate random garbage and send it.
        SendGarbage(g_insecure_rand_ctx.randbytes<uint8_t>(garbage_len));
    }

    /** Schedule garbage (with valid random length) to be sent to the transport. */
    void SendGarbage()
    {
         SendGarbage(InsecureRandRange(V2Transport::MAX_GARBAGE_LEN + 1));
    }

    /** Schedule a message to be sent to us by the transport. */
    void AddMessage(std::string m_type, std::vector<uint8_t> payload)
    {
        CSerializedNetMsg msg;
        msg.m_type = std::move(m_type);
        msg.data = std::move(payload);
        m_msg_to_send.push_back(std::move(msg));
    }

    /** Expect ellswift key to have been received from transport and process it.
     *
     * Many other V2TransportTester functions cannot be called until after ReceiveKey() has been
     * called, as no encryption keys are set up before that point.
     */
    void ReceiveKey()
    {
        // When processing a key, enough bytes need to have been received already.
        BOOST_REQUIRE(m_received.size() >= EllSwiftPubKey::size());
        // Initialize the cipher using it (acting as the opposite side of the tested transport).
        m_cipher.Initialize(MakeByteSpan(m_received).first(EllSwiftPubKey::size()), !m_test_initiator);
        // Strip the processed bytes off the front of the receive buffer.
        m_received.erase(m_received.begin(), m_received.begin() + EllSwiftPubKey::size());
    }

    /** Schedule an encrypted packet with specified content/aad/ignore to be sent to transport
     *  (only after ReceiveKey). */
    void SendPacket(Span<const uint8_t> content, Span<const uint8_t> aad = {}, bool ignore = false)
    {
        // Use cipher to construct ciphertext.
        std::vector<std::byte> ciphertext;
        ciphertext.resize(content.size() + BIP324Cipher::EXPANSION);
        m_cipher.Encrypt(
            /*contents=*/MakeByteSpan(content),
            /*aad=*/MakeByteSpan(aad),
            /*ignore=*/ignore,
            /*output=*/ciphertext);
        // Schedule it for sending.
        Send(ciphertext);
    }

    /** Schedule garbage terminator to be sent to the transport (only after ReceiveKey). */
    void SendGarbageTerm()
    {
        // Schedule the garbage terminator to be sent.
        Send(m_cipher.GetSendGarbageTerminator());
    }

    /** Schedule version packet to be sent to the transport (only after ReceiveKey). */
    void SendVersion(Span<const uint8_t> version_data = {}, bool vers_ignore = false)
    {
        Span<const std::uint8_t> aad;
        // Set AAD to garbage only for first packet.
        if (!m_sent_aad) aad = m_sent_garbage;
        SendPacket(/*content=*/version_data, /*aad=*/aad, /*ignore=*/vers_ignore);
        m_sent_aad = true;
    }

    /** Expect a packet to have been received from transport, process it, and return its contents
     *  (only after ReceiveKey). Decoys are skipped. Optional associated authenticated data (AAD) is
     *  expected in the first received packet, no matter if that is a decoy or not. */
    std::vector<uint8_t> ReceivePacket(Span<const std::byte> aad = {})
    {
        std::vector<uint8_t> contents;
        // Loop as long as there are ignored packets that are to be skipped.
        while (true) {
            // When processing a packet, at least enough bytes for its length descriptor must be received.
            BOOST_REQUIRE(m_received.size() >= BIP324Cipher::LENGTH_LEN);
            // Decrypt the content length.
            size_t size = m_cipher.DecryptLength(MakeByteSpan(Span{m_received}.first(BIP324Cipher::LENGTH_LEN)));
            // Check that the full packet is in the receive buffer.
            BOOST_REQUIRE(m_received.size() >= size + BIP324Cipher::EXPANSION);
            // Decrypt the packet contents.
            contents.resize(size);
            bool ignore{false};
            bool ret = m_cipher.Decrypt(
                /*input=*/MakeByteSpan(
                    Span{m_received}.first(size + BIP324Cipher::EXPANSION).subspan(BIP324Cipher::LENGTH_LEN)),
                /*aad=*/aad,
                /*ignore=*/ignore,
                /*contents=*/MakeWritableByteSpan(contents));
            BOOST_CHECK(ret);
            // Don't expect AAD in further packets.
            aad = {};
            // Strip the processed packet's bytes off the front of the receive buffer.
            m_received.erase(m_received.begin(), m_received.begin() + size + BIP324Cipher::EXPANSION);
            // Stop if the ignore bit is not set on this packet.
            if (!ignore) break;
        }
        return contents;
    }

    /** Expect garbage and garbage terminator to have been received, and process them (only after
     *  ReceiveKey). */
    void ReceiveGarbage()
    {
        // Figure out the garbage length.
        size_t garblen;
        for (garblen = 0; garblen <= V2Transport::MAX_GARBAGE_LEN; ++garblen) {
            BOOST_REQUIRE(m_received.size() >= garblen + BIP324Cipher::GARBAGE_TERMINATOR_LEN);
            auto term_span = MakeByteSpan(Span{m_received}.subspan(garblen, BIP324Cipher::GARBAGE_TERMINATOR_LEN));
            if (term_span == m_cipher.GetReceiveGarbageTerminator()) break;
        }
        // Copy the garbage to a buffer.
        m_recv_garbage.assign(m_received.begin(), m_received.begin() + garblen);
        // Strip garbage + garbage terminator off the front of the receive buffer.
        m_received.erase(m_received.begin(), m_received.begin() + garblen + BIP324Cipher::GARBAGE_TERMINATOR_LEN);
    }

    /** Expect version packet to have been received, and process it (only after ReceiveKey). */
    void ReceiveVersion()
    {
        auto contents = ReceivePacket(/*aad=*/MakeByteSpan(m_recv_garbage));
        // Version packets from real BIP324 peers are expected to be empty, despite the fact that
        // this class supports *sending* non-empty version packets (to test that BIP324 peers
        // correctly ignore version packet contents).
        BOOST_CHECK(contents.empty());
    }

    /** Expect application packet to have been received, with specified short id and payload.
     *  (only after ReceiveKey). */
    void ReceiveMessage(uint8_t short_id, Span<const uint8_t> payload)
    {
        auto ret = ReceivePacket();
        BOOST_CHECK(ret.size() == payload.size() + 1);
        BOOST_CHECK(ret[0] == short_id);
        BOOST_CHECK(Span{ret}.subspan(1) == payload);
    }

    /** Expect application packet to have been received, with specified 12-char message type and
     *  payload (only after ReceiveKey). */
    void ReceiveMessage(const std::string& m_type, Span<const uint8_t> payload)
    {
        auto ret = ReceivePacket();
        BOOST_REQUIRE(ret.size() == payload.size() + 1 + CMessageHeader::COMMAND_SIZE);
        BOOST_CHECK(ret[0] == 0);
        for (unsigned i = 0; i < 12; ++i) {
            if (i < m_type.size()) {
                BOOST_CHECK(ret[1 + i] == m_type[i]);
            } else {
                BOOST_CHECK(ret[1 + i] == 0);
            }
        }
        BOOST_CHECK(Span{ret}.subspan(1 + CMessageHeader::COMMAND_SIZE) == payload);
    }

    /** Schedule an encrypted packet with specified message type and payload to be sent to
     *  transport (only after ReceiveKey). */
    void SendMessage(std::string mtype, Span<const uint8_t> payload)
    {
        // Construct contents consisting of 0x00 + 12-byte message type + payload.
        std::vector<uint8_t> contents(1 + CMessageHeader::COMMAND_SIZE + payload.size());
        std::copy(mtype.begin(), mtype.end(), reinterpret_cast<char*>(contents.data() + 1));
        std::copy(payload.begin(), payload.end(), contents.begin() + 1 + CMessageHeader::COMMAND_SIZE);
        // Send a packet with that as contents.
        SendPacket(contents);
    }

    /** Schedule an encrypted packet with specified short message id and payload to be sent to
     *  transport (only after ReceiveKey). */
    void SendMessage(uint8_t short_id, Span<const uint8_t> payload)
    {
        // Construct contents consisting of short_id + payload.
        std::vector<uint8_t> contents(1 + payload.size());
        contents[0] = short_id;
        std::copy(payload.begin(), payload.end(), contents.begin() + 1);
        // Send a packet with that as contents.
        SendPacket(contents);
    }

    /** Test whether the transport's session ID matches the session ID we expect. */
    void CompareSessionIDs() const
    {
        auto info = m_transport.GetInfo();
        BOOST_CHECK(info.session_id);
        BOOST_CHECK(uint256(MakeUCharSpan(m_cipher.GetSessionID())) == *info.session_id);
    }

    /** Introduce a bit error in the data scheduled to be sent. */
    void Damage()
    {
        m_to_send[InsecureRandRange(m_to_send.size())] ^= (uint8_t{1} << InsecureRandRange(8));
    }
};

} // namespace

BOOST_AUTO_TEST_CASE(v2transport_test)
{
    // A mostly normal scenario, testing a transport in initiator mode.
    for (int i = 0; i < 10; ++i) {
        V2TransportTester tester(true);
        auto ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->empty());
        tester.SendKey();
        tester.SendGarbage();
        tester.ReceiveKey();
        tester.SendGarbageTerm();
        tester.SendVersion();
        ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->empty());
        tester.ReceiveGarbage();
        tester.ReceiveVersion();
        tester.CompareSessionIDs();
        auto msg_data_1 = g_insecure_rand_ctx.randbytes<uint8_t>(InsecureRandRange(100000));
        auto msg_data_2 = g_insecure_rand_ctx.randbytes<uint8_t>(InsecureRandRange(1000));
        tester.SendMessage(uint8_t(4), msg_data_1); // cmpctblock short id
        tester.SendMessage(0, {}); // Invalidly encoded message
        tester.SendMessage("tx", msg_data_2); // 12-character encoded message type
        ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->size() == 3);
        BOOST_CHECK((*ret)[0] && (*ret)[0]->m_type == "cmpctblock" && Span{(*ret)[0]->m_recv} == MakeByteSpan(msg_data_1));
        BOOST_CHECK(!(*ret)[1]);
        BOOST_CHECK((*ret)[2] && (*ret)[2]->m_type == "tx" && Span{(*ret)[2]->m_recv} == MakeByteSpan(msg_data_2));

        // Then send a message with a bit error, expecting failure. It's possible this failure does
        // not occur immediately (when the length descriptor was modified), but it should come
        // eventually, and no messages can be delivered anymore.
        tester.SendMessage("bad", msg_data_1);
        tester.Damage();
        while (true) {
            ret = tester.Interact();
            if (!ret) break; // failure
            BOOST_CHECK(ret->size() == 0); // no message can be delivered
            // Send another message.
            auto msg_data_3 = g_insecure_rand_ctx.randbytes<uint8_t>(InsecureRandRange(10000));
            tester.SendMessage(uint8_t(12), msg_data_3); // getheaders short id
        }
    }

    // Normal scenario, with a transport in responder node.
    for (int i = 0; i < 10; ++i) {
        V2TransportTester tester(false);
        tester.SendKey();
        tester.SendGarbage();
        auto ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->empty());
        tester.ReceiveKey();
        tester.SendGarbageTerm();
        tester.SendVersion();
        ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->empty());
        tester.ReceiveGarbage();
        tester.ReceiveVersion();
        tester.CompareSessionIDs();
        auto msg_data_1 = g_insecure_rand_ctx.randbytes<uint8_t>(InsecureRandRange(100000));
        auto msg_data_2 = g_insecure_rand_ctx.randbytes<uint8_t>(InsecureRandRange(1000));
        tester.SendMessage(uint8_t(14), msg_data_1); // inv short id
        tester.SendMessage(uint8_t(19), msg_data_2); // pong short id
        ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->size() == 2);
        BOOST_CHECK((*ret)[0] && (*ret)[0]->m_type == "inv" && Span{(*ret)[0]->m_recv} == MakeByteSpan(msg_data_1));
        BOOST_CHECK((*ret)[1] && (*ret)[1]->m_type == "pong" && Span{(*ret)[1]->m_recv} == MakeByteSpan(msg_data_2));

        // Then send a too-large message.
        auto msg_data_3 = g_insecure_rand_ctx.randbytes<uint8_t>(MAX_PROTOCOL_MESSAGE_LENGTH + 1);
        tester.SendMessage(uint8_t(11), msg_data_3); // getdata short id
        ret = tester.Interact();
        BOOST_CHECK(!ret);
    }

    // Various valid but unusual scenarios.
    for (int i = 0; i < 50; ++i) {
        /** Whether an initiator or responder is being tested. */
        bool initiator = InsecureRandBool();
        /** Use either 0 bytes or the maximum possible (4095 bytes) garbage length. */
        size_t garb_len = InsecureRandBool() ? 0 : V2Transport::MAX_GARBAGE_LEN;
        /** How many decoy packets to send before the version packet. */
        unsigned num_ignore_version = InsecureRandRange(10);
        /** What data to send in the version packet (ignored by BIP324 peers, but reserved for future extensions). */
        auto ver_data = g_insecure_rand_ctx.randbytes<uint8_t>(InsecureRandBool() ? 0 : InsecureRandRange(1000));
        /** Whether to immediately send key and garbage out (required for responders, optional otherwise). */
        bool send_immediately = !initiator || InsecureRandBool();
        /** How many decoy packets to send before the first and second real message. */
        unsigned num_decoys_1 = InsecureRandRange(1000), num_decoys_2 = InsecureRandRange(1000);
        V2TransportTester tester(initiator);
        if (send_immediately) {
            tester.SendKey();
            tester.SendGarbage(garb_len);
        }
        auto ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->empty());
        if (!send_immediately) {
            tester.SendKey();
            tester.SendGarbage(garb_len);
        }
        tester.ReceiveKey();
        tester.SendGarbageTerm();
        for (unsigned v = 0; v < num_ignore_version; ++v) {
            size_t ver_ign_data_len = InsecureRandBool() ? 0 : InsecureRandRange(1000);
            auto ver_ign_data = g_insecure_rand_ctx.randbytes<uint8_t>(ver_ign_data_len);
            tester.SendVersion(ver_ign_data, true);
        }
        tester.SendVersion(ver_data, false);
        ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->empty());
        tester.ReceiveGarbage();
        tester.ReceiveVersion();
        tester.CompareSessionIDs();
        for (unsigned d = 0; d < num_decoys_1; ++d) {
            auto decoy_data = g_insecure_rand_ctx.randbytes<uint8_t>(InsecureRandRange(1000));
            tester.SendPacket(/*content=*/decoy_data, /*aad=*/{}, /*ignore=*/true);
        }
        auto msg_data_1 = g_insecure_rand_ctx.randbytes<uint8_t>(InsecureRandRange(4000000));
        tester.SendMessage(uint8_t(28), msg_data_1);
        for (unsigned d = 0; d < num_decoys_2; ++d) {
            auto decoy_data = g_insecure_rand_ctx.randbytes<uint8_t>(InsecureRandRange(1000));
            tester.SendPacket(/*content=*/decoy_data, /*aad=*/{}, /*ignore=*/true);
        }
        auto msg_data_2 = g_insecure_rand_ctx.randbytes<uint8_t>(InsecureRandRange(1000));
        tester.SendMessage(uint8_t(13), msg_data_2); // headers short id
        // Send invalidly-encoded message
        tester.SendMessage(std::string("blocktxn\x00\x00\x00a", CMessageHeader::COMMAND_SIZE), {});
        tester.SendMessage("foobar", {}); // test receiving unknown message type
        tester.AddMessage("barfoo", {}); // test sending unknown message type
        ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->size() == 4);
        BOOST_CHECK((*ret)[0] && (*ret)[0]->m_type == "addrv2" && Span{(*ret)[0]->m_recv} == MakeByteSpan(msg_data_1));
        BOOST_CHECK((*ret)[1] && (*ret)[1]->m_type == "headers" && Span{(*ret)[1]->m_recv} == MakeByteSpan(msg_data_2));
        BOOST_CHECK(!(*ret)[2]);
        BOOST_CHECK((*ret)[3] && (*ret)[3]->m_type == "foobar" && (*ret)[3]->m_recv.empty());
        tester.ReceiveMessage("barfoo", {});
    }

    // Too long garbage (initiator).
    {
        V2TransportTester tester(true);
        auto ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->empty());
        tester.SendKey();
        tester.SendGarbage(V2Transport::MAX_GARBAGE_LEN + 1);
        tester.ReceiveKey();
        tester.SendGarbageTerm();
        ret = tester.Interact();
        BOOST_CHECK(!ret);
    }

    // Too long garbage (responder).
    {
        V2TransportTester tester(false);
        tester.SendKey();
        tester.SendGarbage(V2Transport::MAX_GARBAGE_LEN + 1);
        auto ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->empty());
        tester.ReceiveKey();
        tester.SendGarbageTerm();
        ret = tester.Interact();
        BOOST_CHECK(!ret);
    }

    // Send garbage that includes the first 15 garbage terminator bytes somewhere.
    {
        V2TransportTester tester(true);
        auto ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->empty());
        tester.SendKey();
        tester.ReceiveKey();
        /** The number of random garbage bytes before the included first 15 bytes of terminator. */
        size_t len_before = InsecureRandRange(V2Transport::MAX_GARBAGE_LEN - 16 + 1);
        /** The number of random garbage bytes after it. */
        size_t len_after = InsecureRandRange(V2Transport::MAX_GARBAGE_LEN - 16 - len_before + 1);
        // Construct len_before + 16 + len_after random bytes.
        auto garbage = g_insecure_rand_ctx.randbytes<uint8_t>(len_before + 16 + len_after);
        // Replace the designed 16 bytes in the middle with the to-be-sent garbage terminator.
        auto garb_term = MakeUCharSpan(tester.GetCipher().GetSendGarbageTerminator());
        std::copy(garb_term.begin(), garb_term.begin() + 16, garbage.begin() + len_before);
        // Introduce a bit error in the last byte of that copied garbage terminator, making only
        // the first 15 of them match.
        garbage[len_before + 15] ^= (uint8_t(1) << InsecureRandRange(8));
        tester.SendGarbage(garbage);
        tester.SendGarbageTerm();
        tester.SendVersion();
        ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->empty());
        tester.ReceiveGarbage();
        tester.ReceiveVersion();
        tester.CompareSessionIDs();
        auto msg_data_1 = g_insecure_rand_ctx.randbytes<uint8_t>(4000000); // test that receiving 4M payload works
        auto msg_data_2 = g_insecure_rand_ctx.randbytes<uint8_t>(4000000); // test that sending 4M payload works
        tester.SendMessage(uint8_t(InsecureRandRange(223) + 33), {}); // unknown short id
        tester.SendMessage(uint8_t(2), msg_data_1); // "block" short id
        tester.AddMessage("blocktxn", msg_data_2); // schedule blocktxn to be sent to us
        ret = tester.Interact();
        BOOST_REQUIRE(ret && ret->size() == 2);
        BOOST_CHECK(!(*ret)[0]);
        BOOST_CHECK((*ret)[1] && (*ret)[1]->m_type == "block" && Span{(*ret)[1]->m_recv} == MakeByteSpan(msg_data_1));
        tester.ReceiveMessage(uint8_t(3), msg_data_2); // "blocktxn" short id
    }

    // Send correct network's V1 header
    {
        V2TransportTester tester(false);
        tester.SendV1Version(Params().MessageStart());
        auto ret = tester.Interact();
        BOOST_CHECK(ret);
    }

    // Send wrong network's V1 header
    {
        V2TransportTester tester(false);
        tester.SendV1Version(CChainParams::Main()->MessageStart());
        auto ret = tester.Interact();
        BOOST_CHECK(!ret);
    }
}

BOOST_AUTO_TEST_SUITE_END()
