// Copyright (c) 2020-2022 The Bitcoin Core developers
// Copyright (c) 2020-2022 Blackcoin Core Developers
// Copyright (c) 2020-2022 Blackcoin More Developers
// Copyright (c) 2020-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <chainparams.h>
#include <consensus/validation.h>
#include <interfaces/chain.h>
#include <interfaces/handler.h>
#include <interfaces/node.h>
#include <rpc/server.h>
#include <test/util/setup_common.h>
#include <script/solver.h>
#include <validation.h>
#include <tinyformat.h>

#include <boost/test/unit_test.hpp>

using interfaces::FoundBlock;

BOOST_FIXTURE_TEST_SUITE(interfaces_tests, TestChain100Setup)

BOOST_AUTO_TEST_CASE(stake_estimator_bounded_frozen_target)
{
    auto node = interfaces::MakeNode(m_node);
    // Synthetic headers exercise a sparse stake history without mining or I/O.
    std::vector<CBlockIndex> headers(1600);
    std::vector<uint256> hashes(headers.size());
    for (size_t i = 0; i < headers.size(); ++i) {
        hashes[i] = uint256S(strprintf("%064x", i + 1));
        headers[i].phashBlock = &hashes[i];
        headers[i].pprev = i ? &headers[i - 1] : nullptr;
        headers[i].nHeight = i;
        headers[i].nTime = 100000 + i * 64;
        headers[i].nBits = 0x1d00ffff;
        if (i % 20 == 0) headers[i].SetProofOfStake();
    }
    LOCK(::cs_main);
    auto& chainman = *m_node.chainman;
    const CBlockIndex* saved = chainman.m_best_header;
    auto restore = interfaces::MakeCleanupHandler([&] { chainman.m_best_header = const_cast<CBlockIndex*>(saved); });
    chainman.m_best_header = &headers[1499];
    const double expected = GetPoSKernelPS(chainman);
    uint256 sampled, current;
    double estimate{-1};
    BOOST_CHECK(!node->tryGetPoSKernelPS(sampled, estimate, current)); // <=512 visits.
    chainman.m_best_header = &headers[1500];
    BOOST_CHECK(!node->tryGetPoSKernelPS(sampled, estimate, current));
    chainman.m_best_header = &headers[1501];
    BOOST_REQUIRE(node->tryGetPoSKernelPS(sampled, estimate, current));
    BOOST_CHECK(sampled == hashes[1499]); // Completed the frozen older target.
    BOOST_CHECK(current == hashes[1501]); // Authoritative identity rejects it as current.
    BOOST_CHECK_EQUAL(estimate, expected);
    const double newer_expected = GetPoSKernelPS(chainman);
    BOOST_CHECK(!node->tryGetPoSKernelPS(sampled, estimate, current));
    BOOST_CHECK(!node->tryGetPoSKernelPS(sampled, estimate, current));
    BOOST_REQUIRE(node->tryGetPoSKernelPS(sampled, estimate, current));
    BOOST_CHECK(sampled == hashes[1501]);
    BOOST_CHECK_EQUAL(estimate, newer_expected);
    BOOST_CHECK(node->tryGetPoSKernelPS(sampled, estimate, current)); // Complete cache hit.
}

BOOST_AUTO_TEST_CASE(stake_estimator_nonmonotonic_timestamps)
{
    auto node = interfaces::MakeNode(m_node);
    std::vector<CBlockIndex> headers(3);
    std::vector<uint256> hashes{uint256S("01"), uint256S("02"), uint256S("03")};
    const uint32_t times[]{1000, 1100, 1050};
    for (size_t i = 0; i < headers.size(); ++i) {
        headers[i].phashBlock = &hashes[i];
        headers[i].pprev = i ? &headers[i - 1] : nullptr;
        headers[i].nHeight = i;
        headers[i].nTime = times[i];
        headers[i].nBits = 0x1d00ffff;
        headers[i].SetProofOfStake();
    }
    LOCK(::cs_main);
    auto& chainman = *m_node.chainman;
    auto* saved = chainman.m_best_header;
    auto restore = interfaces::MakeCleanupHandler([&] { chainman.m_best_header = saved; });
    chainman.m_best_header = &headers.back();
    uint256 sampled, current;
    double estimate{0};
    BOOST_REQUIRE(node->tryGetPoSKernelPS(sampled, estimate, current));
    BOOST_CHECK(sampled == hashes.back());
    BOOST_CHECK(current == hashes.back());
    BOOST_CHECK_EQUAL(estimate, GetPoSKernelPS(chainman));
    const double expected = 2 * 4294967296.0 / 50 * (Params().GetConsensus().nStakeTimestampMask + 1);
    BOOST_CHECK_EQUAL(estimate, expected);
}

BOOST_AUTO_TEST_CASE(findBlock)
{
    LOCK(Assert(m_node.chainman)->GetMutex());
    auto& chain = m_node.chain;
    const CChain& active = Assert(m_node.chainman)->ActiveChain();

    uint256 hash;
    BOOST_CHECK(chain->findBlock(active[10]->GetBlockHash(), FoundBlock().hash(hash)));
    BOOST_CHECK_EQUAL(hash, active[10]->GetBlockHash());

    int height = -1;
    BOOST_CHECK(chain->findBlock(active[20]->GetBlockHash(), FoundBlock().height(height)));
    BOOST_CHECK_EQUAL(height, active[20]->nHeight);

    CBlock data;
    BOOST_CHECK(chain->findBlock(active[30]->GetBlockHash(), FoundBlock().data(data)));
    BOOST_CHECK_EQUAL(data.GetHash(), active[30]->GetBlockHash());

    int64_t time = -1;
    BOOST_CHECK(chain->findBlock(active[40]->GetBlockHash(), FoundBlock().time(time)));
    BOOST_CHECK_EQUAL(time, active[40]->GetBlockTime());

    int64_t max_time = -1;
    BOOST_CHECK(chain->findBlock(active[50]->GetBlockHash(), FoundBlock().maxTime(max_time)));
    BOOST_CHECK_EQUAL(max_time, active[50]->GetBlockTimeMax());

    int64_t mtp_time = -1;
    BOOST_CHECK(chain->findBlock(active[60]->GetBlockHash(), FoundBlock().mtpTime(mtp_time)));
    BOOST_CHECK_EQUAL(mtp_time, active[60]->GetMedianTimePast());

    bool cur_active{false}, next_active{false};
    uint256 next_hash;
    BOOST_CHECK_EQUAL(active.Height(), 100);
    BOOST_CHECK(chain->findBlock(active[99]->GetBlockHash(), FoundBlock().inActiveChain(cur_active).nextBlock(FoundBlock().inActiveChain(next_active).hash(next_hash))));
    BOOST_CHECK(cur_active);
    BOOST_CHECK(next_active);
    BOOST_CHECK_EQUAL(next_hash, active[100]->GetBlockHash());
    cur_active = next_active = false;
    BOOST_CHECK(chain->findBlock(active[100]->GetBlockHash(), FoundBlock().inActiveChain(cur_active).nextBlock(FoundBlock().inActiveChain(next_active))));
    BOOST_CHECK(cur_active);
    BOOST_CHECK(!next_active);

    BOOST_CHECK(!chain->findBlock({}, FoundBlock()));
}

BOOST_AUTO_TEST_CASE(findFirstBlockWithTimeAndHeight)
{
    LOCK(Assert(m_node.chainman)->GetMutex());
    auto& chain = m_node.chain;
    const CChain& active = Assert(m_node.chainman)->ActiveChain();
    uint256 hash;
    int height;
    BOOST_CHECK(chain->findFirstBlockWithTimeAndHeight(/* min_time= */ 0, /* min_height= */ 5, FoundBlock().hash(hash).height(height)));
    BOOST_CHECK_EQUAL(hash, active[5]->GetBlockHash());
    BOOST_CHECK_EQUAL(height, 5);
    BOOST_CHECK(!chain->findFirstBlockWithTimeAndHeight(/* min_time= */ active.Tip()->GetBlockTimeMax() + 1, /* min_height= */ 0));
}

BOOST_AUTO_TEST_CASE(findAncestorByHeight)
{
    LOCK(Assert(m_node.chainman)->GetMutex());
    auto& chain = m_node.chain;
    const CChain& active = Assert(m_node.chainman)->ActiveChain();
    uint256 hash;
    BOOST_CHECK(chain->findAncestorByHeight(active[20]->GetBlockHash(), 10, FoundBlock().hash(hash)));
    BOOST_CHECK_EQUAL(hash, active[10]->GetBlockHash());
    BOOST_CHECK(!chain->findAncestorByHeight(active[10]->GetBlockHash(), 20));
}

BOOST_AUTO_TEST_CASE(findAncestorByHash)
{
    LOCK(Assert(m_node.chainman)->GetMutex());
    auto& chain = m_node.chain;
    const CChain& active = Assert(m_node.chainman)->ActiveChain();
    int height = -1;
    BOOST_CHECK(chain->findAncestorByHash(active[20]->GetBlockHash(), active[10]->GetBlockHash(), FoundBlock().height(height)));
    BOOST_CHECK_EQUAL(height, 10);
    BOOST_CHECK(!chain->findAncestorByHash(active[10]->GetBlockHash(), active[20]->GetBlockHash()));
}

BOOST_AUTO_TEST_CASE(findCommonAncestor)
{
    auto& chain = m_node.chain;
    const CChain& active{*WITH_LOCK(Assert(m_node.chainman)->GetMutex(), return &Assert(m_node.chainman)->ActiveChain())};
    auto* orig_tip = active.Tip();
    for (int i = 0; i < 10; ++i) {
        BlockValidationState state;
        m_node.chainman->ActiveChainstate().InvalidateBlock(state, active.Tip());
    }
    BOOST_CHECK_EQUAL(active.Height(), orig_tip->nHeight - 10);
    coinbaseKey.MakeNewKey(true);
    for (int i = 0; i < 20; ++i) {
        CreateAndProcessBlock({}, GetScriptForRawPubKey(coinbaseKey.GetPubKey()));
    }
    BOOST_CHECK_EQUAL(active.Height(), orig_tip->nHeight + 10);
    uint256 fork_hash;
    int fork_height;
    int orig_height;
    BOOST_CHECK(chain->findCommonAncestor(orig_tip->GetBlockHash(), active.Tip()->GetBlockHash(), FoundBlock().height(fork_height).hash(fork_hash), FoundBlock().height(orig_height)));
    BOOST_CHECK_EQUAL(orig_height, orig_tip->nHeight);
    BOOST_CHECK_EQUAL(fork_height, orig_tip->nHeight - 10);
    BOOST_CHECK_EQUAL(fork_hash, active[fork_height]->GetBlockHash());

    uint256 active_hash, orig_hash;
    BOOST_CHECK(!chain->findCommonAncestor(active.Tip()->GetBlockHash(), {}, {}, FoundBlock().hash(active_hash), {}));
    BOOST_CHECK(!chain->findCommonAncestor({}, orig_tip->GetBlockHash(), {}, {}, FoundBlock().hash(orig_hash)));
    BOOST_CHECK_EQUAL(active_hash, active.Tip()->GetBlockHash());
    BOOST_CHECK_EQUAL(orig_hash, orig_tip->GetBlockHash());
}

BOOST_AUTO_TEST_CASE(hasBlocks)
{
    LOCK(::cs_main);
    auto& chain = m_node.chain;
    const CChain& active = Assert(m_node.chainman)->ActiveChain();

    // Test ranges
    BOOST_CHECK(chain->hasBlocks(active.Tip()->GetBlockHash(), 10, 90));
    BOOST_CHECK(chain->hasBlocks(active.Tip()->GetBlockHash(), 10, {}));
    BOOST_CHECK(chain->hasBlocks(active.Tip()->GetBlockHash(), 0, 90));
    BOOST_CHECK(chain->hasBlocks(active.Tip()->GetBlockHash(), 0, {}));
    BOOST_CHECK(chain->hasBlocks(active.Tip()->GetBlockHash(), -1000, 1000));
    active[5]->nStatus &= ~BLOCK_HAVE_DATA;
    BOOST_CHECK(chain->hasBlocks(active.Tip()->GetBlockHash(), 10, 90));
    BOOST_CHECK(chain->hasBlocks(active.Tip()->GetBlockHash(), 10, {}));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), 0, 90));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), 0, {}));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), -1000, 1000));
    active[95]->nStatus &= ~BLOCK_HAVE_DATA;
    BOOST_CHECK(chain->hasBlocks(active.Tip()->GetBlockHash(), 10, 90));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), 10, {}));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), 0, 90));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), 0, {}));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), -1000, 1000));
    active[50]->nStatus &= ~BLOCK_HAVE_DATA;
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), 10, 90));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), 10, {}));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), 0, 90));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), 0, {}));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), -1000, 1000));

    // Test edge cases
    BOOST_CHECK(chain->hasBlocks(active.Tip()->GetBlockHash(), 6, 49));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), 5, 49));
    BOOST_CHECK(!chain->hasBlocks(active.Tip()->GetBlockHash(), 6, 50));
}

BOOST_AUTO_TEST_SUITE_END()
