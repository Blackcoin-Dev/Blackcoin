// Copyright (c) 2020-2022 Blackcoin Core Developers
// Copyright (c) 2020-2022 Blackcoin More Developers
// Copyright (c) 2020-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <addresstype.h>
#include <chainparams.h>
#include <common/args.h>
#include <consensus/consensus.h>
#include <consensus/merkle.h>
#include <dbwrapper.h>
#include <hash.h>
#include <index/coinstatsindex.h>
#include <index/shadowindex.h>
#include <interfaces/chain.h>
#include <kernel/chain.h>
#include <kernel/coinstats.h>
#include <pow.h>
#include <shadow.h>
#include <test/util/index.h>
#include <test/util/setup_common.h>
#include <test/util/validation.h>
#include <validation.h>

#include <boost/test/unit_test.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <future>
#include <cstddef>
#include <limits>
#include <memory>
#include <utility>
#include <vector>

/** Exercise the exact custom/base commit boundary without a process-timing race. */
struct ShadowIndexTestAccess
{
    static void SetRewindBatchHook(ShadowIndex& index, std::function<void()> hook)
    {
        index.m_after_rewind_batch_for_testing = std::move(hook);
    }

    static bool Rewind(ShadowIndex& index, const CBlockIndex* from, const CBlockIndex* to)
    {
        return index.CustomRewind({from->GetBlockHash(), from->nHeight}, {to->GetBlockHash(), to->nHeight});
    }

    static CDBWrapper& Database(ShadowIndex& index) { return index.GetDB(); }

    static void Commit(ShadowIndex& index, const CBlockIndex* tip)
    {
        index.ChainStateFlushed(ChainstateRole::NORMAL, GetLocator(tip));
    }

    static bool AppendReturnsError(ShadowIndex& index, const CBlock& block, const CBlockIndex* pindex)
    {
        return index.CustomAppendWithStatus(kernel::MakeBlockInfo(pindex, &block)) == ShadowIndex::AppendResult::FAILED;
    }
};

namespace {

class BoundedShadowIndexTestingSetup : public TestChain100Setup
{
public:
    BoundedShadowIndexTestingSetup()
        : TestChain100Setup{ChainType::REGTEST, {
              "-regtest",
              "-shadowwhitelistheight=100",
              "-shadowgoldrushstartheight=101",
              "-shadowgoldrushblocks=4",
              "-shadowcompetingclaimsheight=101",
          }}
    {
    }
};

struct RawIndexBytes
{
    std::vector<std::byte> bytes;

    template <typename Stream>
    void Unserialize(Stream& stream)
    {
        bytes.resize(stream.size());
        stream.read(bytes);
    }
};

using IndexRows = std::vector<std::pair<std::vector<std::byte>, std::vector<std::byte>>>;

IndexRows ReadIndexRows(ShadowIndex& index)
{
    IndexRows rows;
    std::unique_ptr<CDBIterator> iterator{ShadowIndexTestAccess::Database(index).NewIterator()};
    for (iterator->SeekToFirst(); iterator->Valid(); iterator->Next()) {
        RawIndexBytes key, value;
        BOOST_REQUIRE(iterator->GetKey(key));
        BOOST_REQUIRE(iterator->GetValue(value));
        rows.emplace_back(std::move(key.bytes), std::move(value.bytes));
    }
    return rows;
}

/** Callbacks own their state. Destruction releases a blocked callback even
 * when a test assertion throws before the index is stopped. */
class IndexCallbackBarrier
{
    struct State {
        std::promise<void> entered;
        std::promise<void> release;
        std::future<void> entered_future{entered.get_future()};
        std::shared_future<void> release_future{release.get_future().share()};
        std::atomic<bool> used{false};
        std::atomic<bool> released{false};
        std::atomic<bool> timed_out{false};
    };
    std::shared_ptr<State> m_state{std::make_shared<State>()};

public:
    ~IndexCallbackBarrier() { Release(); }
    std::function<void()> Callback() const
    {
        return [state = m_state] {
            if (state->used.exchange(true)) return;
            state->entered.set_value();
            if (state->release_future.wait_for(std::chrono::seconds{30}) != std::future_status::ready) {
                state->timed_out.store(true);
            }
        };
    }
    bool Wait() { return m_state->entered_future.wait_for(std::chrono::seconds{10}) == std::future_status::ready; }
    void Release()
    {
        if (!m_state->released.exchange(true)) m_state->release.set_value();
    }
    bool TimedOut() const { return m_state->timed_out.load(); }
};

/** Stop while the complete derived index and its callback captures live.
 * Unregistering alone does not wait for an already executing callback. */
class ScopedIndexStop
{
    BaseIndex& m_index;
    IndexCallbackBarrier* m_barrier;
    bool m_stopped{false};

public:
    explicit ScopedIndexStop(BaseIndex& index, IndexCallbackBarrier* barrier = nullptr)
        : m_index{index}, m_barrier{barrier} {}
    ~ScopedIndexStop() { Stop(); }
    void Stop()
    {
        if (m_stopped) return;
        if (m_barrier) m_barrier->Release();
        m_index.Interrupt();
        SyncWithValidationInterfaceQueue();
        m_index.Stop();
        m_stopped = true;
    }
};

// This regression uses only the original ShadowIndex API. The identical
// fixture is applied to the unchanged release source for the baseline run.
class ShadowIndexQueuedTestingSetup : public BoundedShadowIndexTestingSetup
{
public:
    void CheckQueuedReorg(bool replacement)
    {
        ChainstateManager& chainman = *Assert(m_node.chainman);
        Chainstate& chainstate = chainman.ActiveChainstate();
        const CScript old_script = GetScriptForDestination(WitnessUnknown{2, std::vector<unsigned char>(32, 0x64)});
        const CScript new_script = GetScriptForDestination(WitnessUnknown{2, std::vector<unsigned char>(32, 0x65)});
        IndexRows recovered_rows;
        const CBlockIndex* active_tip{nullptr};
        {
            std::vector<uint256> connected_events;
            ShadowIndex index{interfaces::MakeChain(m_node), 1 << 20, false, false,
                [&](bool connected, const ShadowIndexBlockEvent& event) {
                    if (connected) connected_events.push_back(event.block_hash);
                }};
            IndexCallbackBarrier barrier;
            ScopedIndexStop stop_index{index, &barrier};
            BOOST_REQUIRE(index.Init());
            BOOST_REQUIRE(index.StartBackgroundSync());
            IndexWaitSynced(index);
            SyncWithValidationInterfaceQueue();
            CallFunctionInValidationInterfaceQueue(barrier.Callback());
            BOOST_REQUIRE(barrier.Wait());
            const CBlock old_block = CreateAndProcessBlock({}, old_script);
            CBlockIndex* invalidated = WITH_LOCK(cs_main, return chainman.m_blockman.LookupBlockIndex(old_block.GetHash()));
            BOOST_REQUIRE(invalidated);
            BlockValidationState state;
            BOOST_REQUIRE(chainstate.InvalidateBlock(state, invalidated));
            BOOST_REQUIRE_MESSAGE(state.IsValid(), state.ToString());
            if (replacement) CreateAndProcessBlock({}, new_script);
            active_tip = WITH_LOCK(cs_main, return chainstate.m_chain.Tip());
            // One old connect, one disconnect, one replacement keeps the
            // paused queue below validation's ten-callback drain threshold.
            barrier.Release();
            SyncWithValidationInterfaceQueue();
            BOOST_REQUIRE(!barrier.TimedOut());
            BOOST_REQUIRE_EQUAL(m_node.exit_status.load(), EXIT_SUCCESS);
            BOOST_CHECK(index.GetSummary().best_block_hash == active_tip->GetBlockHash());
            ShadowIndexBlockRecord removed;
            BOOST_CHECK(!index.LookupBlock(old_block.GetHash(), removed));
            BOOST_CHECK(std::find(connected_events.begin(), connected_events.end(), old_block.GetHash()) == connected_events.end());
            const CBlock next = CreateAndProcessBlock({}, new_script);
            SyncWithValidationInterfaceQueue();
            active_tip = WITH_LOCK(cs_main, return chainstate.m_chain.Tip());
            BOOST_CHECK(index.GetSummary().best_block_hash == next.GetHash());
            BOOST_REQUIRE(!connected_events.empty());
            BOOST_CHECK(connected_events.back() == next.GetHash());
            ShadowIndexTestAccess::Commit(index, active_tip);
            stop_index.Stop();
            recovered_rows = ReadIndexRows(index);
        }
        {
            ShadowIndex restarted{interfaces::MakeChain(m_node), 1 << 20};
            ScopedIndexStop stop_restarted{restarted};
            BOOST_REQUIRE(restarted.Init());
            BOOST_REQUIRE(restarted.StartBackgroundSync());
            IndexWaitSynced(restarted);
            SyncWithValidationInterfaceQueue();
            BOOST_CHECK(restarted.GetSummary().best_block_hash == active_tip->GetBlockHash());
            stop_restarted.Stop();
            BOOST_CHECK(ReadIndexRows(restarted) == recovered_rows);
        }
        ShadowIndex clean{interfaces::MakeChain(m_node), 1 << 20, true, true};
        ScopedIndexStop stop_clean{clean};
        BOOST_REQUIRE(clean.Init());
        BOOST_REQUIRE(clean.StartBackgroundSync());
        IndexWaitSynced(clean);
        SyncWithValidationInterfaceQueue();
        stop_clean.Stop();
        BOOST_CHECK(ReadIndexRows(clean) == recovered_rows);
    }
};

class BarrierShadowIndex : public ShadowIndex
{
    int m_pause_height{-1};
    bool m_after{false};
    std::function<void()> m_pause;

protected:
    AppendResult CustomAppendWithStatus(const interfaces::BlockInfo& block) override
    {
        if (!m_after && block.height == m_pause_height) m_pause();
        return ShadowIndex::CustomAppendWithStatus(block);
    }
    bool AppendPrepared(const interfaces::BlockInfo& block, const CBlockIndex* pindex,
                        int64_t block_mtp,
                        const std::vector<ShadowSyntheticPayoutTransaction>& payouts,
                        const ShadowPowAccountingContext& context) override
    {
        if (m_after && block.height == m_pause_height) m_pause();
        return ShadowIndex::AppendPrepared(block, pindex, block_mtp, payouts, context);
    }

public:
    using ShadowIndex::ShadowIndex;
    void PauseAt(int height, bool after, std::function<void()> pause)
    {
        m_pause_height = height;
        m_after = after;
        m_pause = std::move(pause);
    }
};

class ShadowIndexStaleTestingSetup : public BoundedShadowIndexTestingSetup
{
public:
    void CheckReorg(bool after_snapshot, bool background, bool replacement)
    {
        ChainstateManager& chainman = *Assert(m_node.chainman);
        Chainstate& chainstate = chainman.ActiveChainstate();
        const CScript old_script = GetScriptForDestination(WitnessUnknown{2, std::vector<unsigned char>(32, 0x61)});
        const CScript new_script = GetScriptForDestination(WitnessUnknown{2, std::vector<unsigned char>(32, 0x62)});
        std::vector<CBlock> old_blocks;
        if (background) {
            for (int i = 0; i < 3; ++i) old_blocks.push_back(CreateAndProcessBlock({}, old_script));
            SyncWithValidationInterfaceQueue();
        }

        IndexRows recovered_rows;
        const CBlockIndex* active_tip{nullptr};
        {
            std::vector<uint256> connected_events;
            BarrierShadowIndex index{interfaces::MakeChain(m_node), 1 << 20, false, false,
                [&](bool connected, const ShadowIndexBlockEvent& event) {
                    if (connected) connected_events.push_back(event.block_hash);
                }};
            IndexCallbackBarrier barrier;
            ScopedIndexStop stop_index{index, &barrier};
            BOOST_REQUIRE(index.Init());
            if (background || after_snapshot) {
                // Background sync has already written height101 when its
                // selected height102 is invalidated before its snapshot.
                const int pause_height = SHADOW_REWARD_START_HEIGHT + (background ? 1 : 0);
                index.PauseAt(pause_height, after_snapshot, barrier.Callback());
            }
            BOOST_REQUIRE(index.StartBackgroundSync());
            if (!background) {
                IndexWaitSynced(index);
                SyncWithValidationInterfaceQueue();
                if (!after_snapshot) {
                    CallFunctionInValidationInterfaceQueue(barrier.Callback());
                    BOOST_REQUIRE(barrier.Wait());
                }
                old_blocks.push_back(CreateAndProcessBlock({}, old_script));
                if (after_snapshot) BOOST_REQUIRE(barrier.Wait());
            } else {
                BOOST_REQUIRE(barrier.Wait());
            }

            CBlockIndex* invalidated = WITH_LOCK(cs_main, return chainman.m_blockman.LookupBlockIndex(old_blocks.front().GetHash()));
            BOOST_REQUIRE(invalidated);
            BlockValidationState state;
            BOOST_REQUIRE(chainstate.InvalidateBlock(state, invalidated));
            BOOST_REQUIRE_MESSAGE(state.IsValid(), state.ToString());
            if (replacement) {
                for (int i = 0; i < (background ? 3 : 1); ++i) CreateAndProcessBlock({}, new_script);
            }
            if (background) {
                // Drain notifications while m_synced is still false; only
                // ThreadSync can reconcile this branch switch or shrink.
                SyncWithValidationInterfaceQueue();
            }
            active_tip = WITH_LOCK(cs_main, return chainstate.m_chain.Tip());
            barrier.Release();
            IndexWaitSynced(index);
            SyncWithValidationInterfaceQueue();
            BOOST_CHECK(!barrier.TimedOut());
            BOOST_CHECK_EQUAL(m_node.exit_status.load(), EXIT_SUCCESS);
            BOOST_CHECK(index.GetSummary().best_block_hash == active_tip->GetBlockHash());
            BOOST_CHECK_EQUAL(index.GetSummary().best_block_height, active_tip->nHeight);
            for (const CBlock& old : old_blocks) {
                ShadowIndexBlockRecord removed;
                BOOST_CHECK(!index.LookupBlock(old.GetHash(), removed));
                if (!after_snapshot) {
                    BOOST_CHECK(std::find(connected_events.begin(), connected_events.end(), old.GetHash()) == connected_events.end());
                }
            }
            ShadowIndexTestAccess::Commit(index, active_tip);
            stop_index.Stop();
            recovered_rows = ReadIndexRows(index);
        }
        {
            ShadowIndex restarted{interfaces::MakeChain(m_node), 1 << 20};
            ScopedIndexStop stop_restarted{restarted};
            BOOST_REQUIRE(restarted.Init());
            BOOST_REQUIRE(restarted.StartBackgroundSync());
            IndexWaitSynced(restarted);
            SyncWithValidationInterfaceQueue();
            BOOST_CHECK(restarted.GetSummary().best_block_hash == active_tip->GetBlockHash());
            stop_restarted.Stop();
            BOOST_CHECK(ReadIndexRows(restarted) == recovered_rows);
        }
        ShadowIndex clean{interfaces::MakeChain(m_node), 1 << 20, true, true};
        ScopedIndexStop stop_clean{clean};
        BOOST_REQUIRE(clean.Init());
        BOOST_REQUIRE(clean.StartBackgroundSync());
        IndexWaitSynced(clean);
        SyncWithValidationInterfaceQueue();
        stop_clean.Stop();
        // All records, undo, supply rows, witness rows and persisted locator
        // must match a fresh index on the replacement branch or shortened tip.
        BOOST_CHECK(ReadIndexRows(clean) == recovered_rows);
    }
};

struct InterruptedShadowRewind {};

class ShadowIndexRewindTestingSetup : public BoundedShadowIndexTestingSetup
{
public:
    void CheckInterruptedRewind(int disconnect_count, size_t stop_after)
    {
        ChainstateManager& chainman = *Assert(m_node.chainman);
        Chainstate& chainstate = chainman.ActiveChainstate();
        // Nonempty historical witness records make the undo comparison cover
        // both custom state families. Version 2 outputs need no spending key.
        const CScript old_script = GetScriptForDestination(WitnessUnknown{2, std::vector<unsigned char>(32, 0x71)});
        const CScript alternate_script = GetScriptForDestination(WitnessUnknown{2, std::vector<unsigned char>(32, 0x72)});
        std::vector<CBlock> old_blocks;
        for (int i = 0; i < 3; ++i) old_blocks.push_back(CreateAndProcessBlock({}, old_script));
        const CBlockIndex* old_tip = WITH_LOCK(cs_main, return chainstate.m_chain.Tip());
        BOOST_REQUIRE_EQUAL(old_tip->nHeight, SHADOW_REWARD_START_HEIGHT + 2);
        const CBlockIndex* fork = old_tip->GetAncestor(old_tip->nHeight - disconnect_count);
        const CBlockIndex* persisted_parent = old_tip->GetAncestor(old_tip->nHeight - static_cast<int>(stop_after));
        BOOST_REQUIRE(fork != nullptr);
        BOOST_REQUIRE(persisted_parent != nullptr);

        CBlockLocator persisted_locator;
        {
            ShadowIndex index{interfaces::MakeChain(m_node), 1 << 20};
            BOOST_REQUIRE(index.Init());
            BOOST_REQUIRE(index.StartBackgroundSync());
            IndexWaitSynced(index);
            SyncWithValidationInterfaceQueue();
            index.Stop(); // No live notifications or final BaseIndex commit during the failpoint.
            CBlockLocator before;
            BOOST_REQUIRE(ShadowIndexTestAccess::Database(index).Read(uint8_t{'B'}, before));
            BOOST_REQUIRE(!before.IsNull());
            BOOST_REQUIRE(before.vHave.front() == old_tip->GetBlockHash());

            CBlockIndex* invalidated = WITH_LOCK(cs_main, return chainman.m_blockman.LookupBlockIndex(old_blocks[3 - disconnect_count].GetHash()));
            BOOST_REQUIRE(invalidated != nullptr);
            BlockValidationState state;
            BOOST_REQUIRE(chainstate.InvalidateBlock(state, invalidated));
            BOOST_REQUIRE_MESSAGE(state.IsValid(), state.ToString());
            for (int i = 0; i < disconnect_count; ++i) CreateAndProcessBlock({}, alternate_script);
            SyncWithValidationInterfaceQueue();

            size_t committed_batches{0};
            ShadowIndexTestAccess::SetRewindBatchHook(index, [&] {
                if (++committed_batches == stop_after) throw InterruptedShadowRewind{};
            });
            BOOST_CHECK_THROW(ShadowIndexTestAccess::Rewind(index, old_tip, fork), InterruptedShadowRewind);
            BOOST_CHECK_EQUAL(committed_batches, stop_after);
            // The in-memory BaseIndex state has not advanced through Rewind's
            // final Commit. The persisted locator must already match the undo.
            BOOST_CHECK(index.GetSummary().best_block_hash == old_tip->GetBlockHash());
            BOOST_REQUIRE(ShadowIndexTestAccess::Database(index).Read(uint8_t{'B'}, persisted_locator));
            BOOST_REQUIRE(!persisted_locator.IsNull());
            BOOST_CHECK(persisted_locator.vHave == GetLocator(persisted_parent).vHave);
            if (persisted_parent->nHeight >= SHADOW_REWARD_START_HEIGHT) {
                std::pair<uint256, int32_t> custom_tip;
                BOOST_REQUIRE(ShadowIndexTestAccess::Database(index).Read(uint8_t{'T'}, custom_tip));
                BOOST_CHECK(custom_tip.first == persisted_parent->GetBlockHash());
                BOOST_CHECK_EQUAL(custom_tip.second, persisted_parent->nHeight);
            } else {
                BOOST_CHECK(!ShadowIndexTestAccess::Database(index).Exists(uint8_t{'T'}));
            }
            ShadowIndexBlockRecord removed;
            BOOST_CHECK(!index.LookupBlock(old_tip->GetBlockHash(), removed));
        }

        // Recreating the old inconsistent locator must still fail closed,
        // including the missing-custom-tip case at the reward boundary.
        // Recovery succeeds because the atomic batch prevents this mismatch,
        // rather than because CustomInit accepts a corrupt restart point.
        const auto write_locator = [&](const CBlockLocator& locator) {
            CDBWrapper db({.path = gArgs.GetDataDirNet() / "indexes" / "shadow", .cache_bytes = 1 << 20});
            BOOST_REQUIRE(db.Write(uint8_t{'B'}, locator));
        };
        write_locator(GetLocator(old_tip));
        {
            ShadowIndex inconsistent{interfaces::MakeChain(m_node), 1 << 20};
            BOOST_CHECK(!inconsistent.Init());
            inconsistent.Stop();
        }
        write_locator(persisted_locator);

        IndexRows recovered_rows;
        ShadowIndexSupply recovered_supply;
        size_t recovered_transactions{0}, recovered_witness_outputs{0};
        const uint256 active_tip = WITH_LOCK(cs_main, return chainstate.m_chain.Tip()->GetBlockHash());
        {
            ShadowIndex recovered{interfaces::MakeChain(m_node), 1 << 20};
            BOOST_REQUIRE(recovered.Init());
            BOOST_CHECK(recovered.GetSummary().best_block_hash == persisted_parent->GetBlockHash());
            BOOST_REQUIRE(recovered.StartBackgroundSync());
            IndexWaitSynced(recovered);
            SyncWithValidationInterfaceQueue();
            recovered.Stop();
            BOOST_CHECK(recovered.GetSummary().best_block_hash == active_tip);
            BOOST_REQUIRE(recovered.LookupSupply(active_tip, recovered_supply));
            bool complete{false};
            BOOST_REQUIRE(recovered.ForEachTransaction(1000, [](const auto&) { return true; }, recovered_transactions, complete));
            BOOST_CHECK(complete);
            BOOST_REQUIRE(recovered.ForEachQuantumWitnessOutput(1000, [](const auto&) { return true; }, recovered_witness_outputs, complete));
            BOOST_CHECK(complete);
            BOOST_CHECK_GT(recovered_witness_outputs, 0U);
            for (size_t i = old_blocks.size() - disconnect_count; i < old_blocks.size(); ++i) {
                ShadowIndexBlockRecord removed;
                BOOST_CHECK(!recovered.LookupBlock(old_blocks[i].GetHash(), removed));
            }
            recovered_rows = ReadIndexRows(recovered);
        }

        // A fresh index over the resulting active branch must match every key
        // and serialized value, including supply, transactions, witness undo,
        // script rows, block records, custom tip and the full block locator.
        ShadowIndex clean{interfaces::MakeChain(m_node), 1 << 20, /*memory=*/true, /*wipe=*/true};
        BOOST_REQUIRE(clean.Init());
        BOOST_REQUIRE(clean.StartBackgroundSync());
        IndexWaitSynced(clean);
        SyncWithValidationInterfaceQueue();
        clean.Stop();
        BOOST_CHECK(ReadIndexRows(clean) == recovered_rows);
        ShadowIndexSupply clean_supply;
        BOOST_REQUIRE(clean.LookupSupply(active_tip, clean_supply));
        BOOST_CHECK_EQUAL(clean_supply.issued_count, recovered_supply.issued_count);
        BOOST_CHECK_EQUAL(clean_supply.issued_nominal, recovered_supply.issued_nominal);
        BOOST_CHECK_EQUAL(clean_supply.spent_count, recovered_supply.spent_count);
        BOOST_CHECK_EQUAL(clean_supply.spent_nominal, recovered_supply.spent_nominal);
        BOOST_CHECK_EQUAL(clean_supply.spent_effective, recovered_supply.spent_effective);
        BOOST_CHECK_EQUAL(clean_supply.spent_decayed, recovered_supply.spent_decayed);
        size_t clean_transactions{0}, clean_witness_outputs{0};
        bool complete{false};
        BOOST_REQUIRE(clean.ForEachTransaction(1000, [](const auto&) { return true; }, clean_transactions, complete));
        BOOST_CHECK(complete);
        BOOST_CHECK_EQUAL(clean_transactions, recovered_transactions);
        BOOST_REQUIRE(clean.ForEachQuantumWitnessOutput(1000, [](const auto&) { return true; }, clean_witness_outputs, complete));
        BOOST_CHECK(complete);
        BOOST_CHECK_EQUAL(clean_witness_outputs, recovered_witness_outputs);
    }
};

} // namespace

BOOST_AUTO_TEST_SUITE(coinstatsindex_tests)

BOOST_FIXTURE_TEST_CASE(shadowindex_queued_stale_connect_reconciles, ShadowIndexQueuedTestingSetup)
{
    CheckQueuedReorg(/*replacement=*/true);
}

BOOST_FIXTURE_TEST_CASE(shadowindex_queued_disconnect_only_reconciles, ShadowIndexQueuedTestingSetup)
{
    CheckQueuedReorg(/*replacement=*/false);
}

BOOST_FIXTURE_TEST_CASE(shadowindex_reorg_after_snapshot_reconciles, ShadowIndexStaleTestingSetup)
{
    CheckReorg(/*after_snapshot=*/true, /*background=*/false, /*replacement=*/true);
}

BOOST_FIXTURE_TEST_CASE(shadowindex_background_stale_selection_reconciles, ShadowIndexStaleTestingSetup)
{
    CheckReorg(/*after_snapshot=*/false, /*background=*/true, /*replacement=*/true);
}

BOOST_FIXTURE_TEST_CASE(shadowindex_background_disconnect_only_reconciles, ShadowIndexStaleTestingSetup)
{
    CheckReorg(/*after_snapshot=*/false, /*background=*/true, /*replacement=*/false);
}

BOOST_FIXTURE_TEST_CASE(shadowindex_active_corruption_remains_error, BoundedShadowIndexTestingSetup)
{
    Chainstate& chainstate = Assert(m_node.chainman)->ActiveChainstate();
    ShadowIndex index{interfaces::MakeChain(m_node), 1 << 20};
    ScopedIndexStop stop_index{index};
    BOOST_REQUIRE(index.Init());
    BOOST_REQUIRE(index.StartBackgroundSync());
    IndexWaitSynced(index);
    SyncWithValidationInterfaceQueue();
    stop_index.Stop();
    const IndexRows before = ReadIndexRows(index);
    const CScript script = GetScriptForDestination(WitnessUnknown{2, std::vector<unsigned char>(32, 0x63)});
    const CBlock block = CreateAndProcessBlock({}, script);
    const CBlockIndex* tip = WITH_LOCK(cs_main, return chainstate.m_chain.Tip());
    BOOST_REQUIRE(tip->GetBlockHash() == block.GetHash());
    bool append_error{false};
    {
        LOCK(cs_main);
        CHashWriter writer;
        writer << std::string("Quantum Quasar Shadow Pool Undo") << tip->nHeight << tip->GetBlockHash();
        const COutPoint undo_outpoint{writer.GetHash(), 0};
        Coin original;
        BOOST_REQUIRE(chainstate.CoinsTip().GetCoin(undo_outpoint, original));
        Coin corrupt{original};
        ++corrupt.nTime;
        BOOST_REQUIRE(chainstate.CoinsTip().SpendCoin(undo_outpoint));
        chainstate.CoinsTip().AddCoin(undo_outpoint, std::move(corrupt), true);
        append_error = ShadowIndexTestAccess::AppendReturnsError(index, block, tip);
        chainstate.CoinsTip().SpendCoin(undo_outpoint);
        chainstate.CoinsTip().AddCoin(undo_outpoint, std::move(original), true);
    }
    BOOST_CHECK(append_error);
    BOOST_CHECK(ReadIndexRows(index) == before);
    BOOST_CHECK_EQUAL(index.GetSummary().best_block_height, SHADOW_REWARD_START_HEIGHT - 1);
}

BOOST_FIXTURE_TEST_CASE(shadowindex_interrupted_single_block_rewind_recovers, ShadowIndexRewindTestingSetup)
{
    CheckInterruptedRewind(/*disconnect_count=*/1, /*stop_after=*/1);
}

BOOST_FIXTURE_TEST_CASE(shadowindex_interrupted_multi_block_rewind_recovers, ShadowIndexRewindTestingSetup)
{
    CheckInterruptedRewind(/*disconnect_count=*/3, /*stop_after=*/1);
}

BOOST_FIXTURE_TEST_CASE(shadowindex_interrupted_reward_boundary_rewind_recovers, ShadowIndexRewindTestingSetup)
{
    CheckInterruptedRewind(/*disconnect_count=*/3, /*stop_after=*/3);
}

BOOST_FIXTURE_TEST_CASE(auxiliary_claim_index_schema_mismatch_wipes_and_rebuilds, TestChain100Setup)
{
    static constexpr uint8_t SCHEMA_KEY{'V'};
    static constexpr uint32_t PRERELEASE_COINSTATS_SCHEMA{2};
    // Schema 9 predates QQP4 version/input provenance. It cannot safely be
    // relabeled as any later schema, so it must be rebuilt from the chain.
    static constexpr uint32_t PRE_QQP4_SHADOW_SCHEMA{9};
    const std::string sentinel{"prerelease-claim-allocation"};

    const auto build_index = [](BaseIndex& index) {
        BOOST_REQUIRE(index.Init());
        BOOST_REQUIRE(index.StartBackgroundSync());
        IndexWaitSynced(index);
        BOOST_CHECK(index.BlockUntilSyncedToCurrentChain());
        index.Stop();
    };

    const fs::path coinstats_path = gArgs.GetDataDirNet() / "indexes" / "coinstats" / "db";
    uint32_t current_coinstats_schema{0};
    {
        CoinStatsIndex index{interfaces::MakeChain(m_node), 1 << 20};
        build_index(index);
    }
    {
        CDBWrapper db({.path = coinstats_path, .cache_bytes = 1 << 20});
        BOOST_REQUIRE(db.Read(SCHEMA_KEY, current_coinstats_schema));
        BOOST_REQUIRE_GT(current_coinstats_schema,
                         PRERELEASE_COINSTATS_SCHEMA);
        BOOST_REQUIRE_LT(current_coinstats_schema,
                         std::numeric_limits<uint32_t>::max());
        BOOST_REQUIRE(db.Write(SCHEMA_KEY, PRERELEASE_COINSTATS_SCHEMA));
        BOOST_REQUIRE(db.Write(sentinel, true));
    }
    {
        CoinStatsIndex index{interfaces::MakeChain(m_node), 1 << 20};
        build_index(index);
    }
    {
        CDBWrapper db({.path = coinstats_path, .cache_bytes = 1 << 20});
        uint32_t schema{0};
        BOOST_REQUIRE(db.Read(SCHEMA_KEY, schema));
        BOOST_CHECK_EQUAL(schema, current_coinstats_schema);
        BOOST_CHECK(!db.Exists(sentinel));
    }

    // A partially populated, unversioned index must be discarded rather than
    // relabeled as current. Its persisted MuHash provenance is unknowable.
    {
        CDBWrapper db({.path = coinstats_path, .cache_bytes = 1 << 20});
        BOOST_REQUIRE(db.Erase(SCHEMA_KEY));
        BOOST_REQUIRE(db.Write(sentinel, true));
    }
    {
        CoinStatsIndex index{interfaces::MakeChain(m_node), 1 << 20};
        build_index(index);
    }
    {
        CDBWrapper db({.path = coinstats_path, .cache_bytes = 1 << 20});
        uint32_t schema{0};
        BOOST_REQUIRE(db.Read(SCHEMA_KEY, schema));
        BOOST_CHECK_EQUAL(schema, current_coinstats_schema);
        BOOST_CHECK(!db.Exists(sentinel));
    }

    const fs::path shadow_path = gArgs.GetDataDirNet() / "indexes" / "shadow";
    uint32_t current_shadow_schema{0};
    {
        ShadowIndex index{interfaces::MakeChain(m_node), 1 << 20};
        build_index(index);
    }
    {
        CDBWrapper db({.path = shadow_path, .cache_bytes = 1 << 20});
        BOOST_REQUIRE(db.Read(SCHEMA_KEY, current_shadow_schema));
        BOOST_REQUIRE_GT(current_shadow_schema, PRE_QQP4_SHADOW_SCHEMA);
        BOOST_REQUIRE_LT(current_shadow_schema,
                         std::numeric_limits<uint32_t>::max());
        BOOST_REQUIRE(db.Write(SCHEMA_KEY, PRE_QQP4_SHADOW_SCHEMA));
        BOOST_REQUIRE(db.Write(sentinel, true));
    }
    {
        ShadowIndex index{interfaces::MakeChain(m_node), 1 << 20};
        build_index(index);
    }
    {
        CDBWrapper db({.path = shadow_path, .cache_bytes = 1 << 20});
        uint32_t schema{0};
        BOOST_REQUIRE(db.Read(SCHEMA_KEY, schema));
        BOOST_CHECK_EQUAL(schema, current_shadow_schema);
        BOOST_CHECK(!db.Exists(sentinel));
    }

    // An unversioned but populated database must not be relabeled as current.
    // Its records have no authenticated claim-allocation provenance.
    {
        CDBWrapper db({.path = shadow_path, .cache_bytes = 1 << 20});
        BOOST_REQUIRE(db.Erase(SCHEMA_KEY));
        BOOST_REQUIRE(db.Write(sentinel, true));
    }
    {
        ShadowIndex index{interfaces::MakeChain(m_node), 1 << 20};
        build_index(index);
    }
    {
        CDBWrapper db({.path = shadow_path, .cache_bytes = 1 << 20});
        uint32_t schema{0};
        BOOST_REQUIRE(db.Read(SCHEMA_KEY, schema));
        BOOST_CHECK_EQUAL(schema, current_shadow_schema);
        BOOST_CHECK(!db.Exists(sentinel));
    }

    // A newer schema may contain semantics this binary does not understand.
    // Downgrades fail closed instead of deleting that database.
    {
        CDBWrapper db({.path = coinstats_path, .cache_bytes = 1 << 20});
        BOOST_REQUIRE(db.Write(SCHEMA_KEY, current_coinstats_schema + 1));
        BOOST_REQUIRE(db.Write(sentinel, true));
    }
    BOOST_CHECK_THROW((CoinStatsIndex{interfaces::MakeChain(m_node), 1 << 20}), std::runtime_error);
    {
        CDBWrapper db({.path = coinstats_path, .cache_bytes = 1 << 20});
        uint32_t schema{0};
        bool sentinel_present{false};
        BOOST_REQUIRE(db.Read(SCHEMA_KEY, schema));
        BOOST_CHECK_EQUAL(schema, current_coinstats_schema + 1);
        BOOST_REQUIRE(db.Read(sentinel, sentinel_present));
        BOOST_CHECK(sentinel_present);
    }
    {
        CDBWrapper db({.path = shadow_path, .cache_bytes = 1 << 20});
        BOOST_REQUIRE(db.Write(SCHEMA_KEY, current_shadow_schema + 1));
        BOOST_REQUIRE(db.Write(sentinel, true));
    }
    BOOST_CHECK_THROW((ShadowIndex{interfaces::MakeChain(m_node), 1 << 20}), std::runtime_error);
    {
        CDBWrapper db({.path = shadow_path, .cache_bytes = 1 << 20});
        uint32_t schema{0};
        bool sentinel_present{false};
        BOOST_REQUIRE(db.Read(SCHEMA_KEY, schema));
        BOOST_CHECK_EQUAL(schema, current_shadow_schema + 1);
        BOOST_REQUIRE(db.Read(sentinel, sentinel_present));
        BOOST_CHECK(sentinel_present);
    }
}

BOOST_FIXTURE_TEST_CASE(shadowindex_bounded_claim_state_survives_max_weight_reorg_and_rebuild,
                        BoundedShadowIndexTestingSetup)
{
    static constexpr int64_t MAX_OPERATION_MILLISECONDS{120000};
    static constexpr size_t MAX_PERSISTED_BLOCK_RECORD_BYTES{4096};
    ChainstateManager& chainman = *Assert(m_node.chainman);
    Chainstate& chainstate = chainman.ActiveChainstate();
    const CScript script_pub_key{
        CScript{} << ToByteVector(coinbaseKey.GetPubKey()) << OP_CHECKSIG};

    ShadowIndex index{interfaces::MakeChain(m_node), 1 << 20, true};
    BOOST_REQUIRE(index.Init());
    BOOST_REQUIRE(index.StartBackgroundSync());
    IndexWaitSynced(index);

    CBlock stress_block = CreateBlock({}, script_pub_key, chainstate);
    CMutableTransaction coinbase{*stress_block.vtx.at(0)};
    const size_t base_output_count = coinbase.vout.size();
    const valtype malformed_payload{'Q', 'Q', 'S', 'P', 'R', 'O', 'O', 'F', 0};
    const CTxOut malformed_output{
        0, CScript{} << OP_RETURN << malformed_payload};
    const size_t output_weight =
        GetSerializeSize(TX_NO_WITNESS(malformed_output)) *
        WITNESS_SCALE_FACTOR;
    BOOST_REQUIRE_GT(output_weight, 0U);
    const size_t available_weight =
        MAX_BLOCK_WEIGHT - GetBlockWeight(stress_block);
    const size_t initial_output_count = available_weight / output_weight;
    coinbase.vout.reserve(coinbase.vout.size() + initial_output_count);
    for (size_t i = 0; i < initial_output_count; ++i) {
        coinbase.vout.push_back(malformed_output);
    }
    stress_block.vtx[0] = MakeTransactionRef(coinbase);
    stress_block.hashMerkleRoot = BlockMerkleRoot(stress_block);
    while (GetBlockWeight(stress_block) > MAX_BLOCK_WEIGHT) {
        coinbase.vout.pop_back();
        stress_block.vtx[0] = MakeTransactionRef(coinbase);
        stress_block.hashMerkleRoot = BlockMerkleRoot(stress_block);
    }
    while (GetBlockWeight(stress_block) + output_weight <= MAX_BLOCK_WEIGHT) {
        coinbase.vout.push_back(malformed_output);
        stress_block.vtx[0] = MakeTransactionRef(coinbase);
        stress_block.hashMerkleRoot = BlockMerkleRoot(stress_block);
    }
    const uint32_t expected_notes =
        static_cast<uint32_t>(coinbase.vout.size() - base_output_count);
    BOOST_REQUIRE_GT(expected_notes, MAX_SHADOW_POW_EVALS_PER_BLOCK);
    BOOST_CHECK_LE(MAX_BLOCK_WEIGHT - GetBlockWeight(stress_block),
                   output_weight);
    stress_block.nNonce = 0;
    while (!CheckProofOfWork(stress_block.GetPoWHash(), stress_block.nBits,
                             chainman.GetConsensus())) {
        ++stress_block.nNonce;
    }
    const uint256 stress_hash = stress_block.GetHash();

    const auto require_within_limit = [&](const char* operation,
                                          const auto& callable) {
        const auto start = std::chrono::steady_clock::now();
        callable();
        const int64_t elapsed_milliseconds =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - start)
                .count();
        BOOST_TEST_CONTEXT(operation) {
            BOOST_CHECK_LT(elapsed_milliseconds,
                           MAX_OPERATION_MILLISECONDS);
        }
    };
    const auto wait_for_index = [&] {
        SyncWithValidationInterfaceQueue();
        IndexWaitSynced(index);
    };

    require_within_limit("maximum-weight connect and live index append", [&] {
        bool new_block{false};
        BOOST_REQUIRE(chainman.ProcessNewBlock(
            std::make_shared<const CBlock>(stress_block), true, true,
            &new_block));
        BOOST_REQUIRE(new_block);
        wait_for_index();
    });

    ShadowIndexBlockRecord first_record;
    BOOST_REQUIRE(index.LookupBlock(stress_hash, first_record));
    BOOST_CHECK(first_record.pow_claims.active);
    BOOST_CHECK_EQUAL(first_record.pow_claims.observed_count, expected_notes);
    BOOST_CHECK_EQUAL(first_record.pow_claims.evaluated_count, 0U);
    BOOST_CHECK_EQUAL(first_record.pow_claims.record_count, 0U);
    BOOST_CHECK_EQUAL(first_record.pow_claims.invalid_location_count,
                      expected_notes);
    BOOST_CHECK_EQUAL(first_record.pow_claims.rejected_count, expected_notes);
    BOOST_CHECK(!first_record.pow_claims.accounting_commitment.IsNull());
    BOOST_CHECK_EQUAL(first_record.observed_pow_claim_txids.size(), 1U);
    BOOST_CHECK_LE(GetSerializeSize(first_record),
                   MAX_PERSISTED_BLOCK_RECORD_BYTES);
    std::vector<ShadowIndexPowClaimRecord> claims;
    std::optional<size_t> next;
    BOOST_REQUIRE(index.LookupPowClaims(stress_hash, 0,
                                       MAX_SHADOW_POW_EVALS_PER_BLOCK,
                                       claims, next));
    BOOST_CHECK(claims.empty());
    BOOST_CHECK(!next.has_value());
    BOOST_CHECK(!index.LookupPowClaims(stress_hash, 0,
                                      MAX_SHADOW_POW_EVALS_PER_BLOCK + 1,
                                      claims, next));

    CBlockIndex* stress_index{nullptr};
    {
        LOCK(cs_main);
        stress_index = chainman.m_blockman.LookupBlockIndex(stress_hash);
    }
    BOOST_REQUIRE(stress_index != nullptr);
    require_within_limit("maximum-weight disconnect and index undo", [&] {
        BlockValidationState state;
        BOOST_REQUIRE(chainstate.InvalidateBlock(state, stress_index));
        BOOST_REQUIRE_MESSAGE(state.IsValid(), state.ToString());
        wait_for_index();
    });
    ShadowIndexBlockRecord disconnected_record;
    BOOST_CHECK(!index.LookupBlock(stress_hash, disconnected_record));

    CBlock alternate_block;
    require_within_limit("alternate-chain connect", [&] {
        alternate_block = CreateAndProcessBlock({}, script_pub_key);
        wait_for_index();
    });
    const uint256 alternate_hash = alternate_block.GetHash();
    ShadowIndexBlockRecord alternate_record;
    BOOST_REQUIRE(index.LookupBlock(alternate_hash, alternate_record));
    BOOST_CHECK_EQUAL(alternate_record.pow_claims.observed_count, 0U);
    BOOST_CHECK(!alternate_record.pow_claims.accounting_commitment.IsNull());

    require_within_limit("reorg back to maximum-weight block", [&] {
        CBlockIndex* alternate_index{nullptr};
        {
            LOCK(cs_main);
            alternate_index =
                chainman.m_blockman.LookupBlockIndex(alternate_hash);
        }
        BOOST_REQUIRE(alternate_index != nullptr);
        BlockValidationState state;
        BOOST_REQUIRE(chainstate.InvalidateBlock(state, alternate_index));
        BOOST_REQUIRE_MESSAGE(state.IsValid(), state.ToString());
        {
            LOCK(cs_main);
            chainstate.ResetBlockFailureFlags(stress_index);
        }
        BlockValidationState activate_state;
        BOOST_REQUIRE(chainstate.ActivateBestChain(activate_state));
        BOOST_REQUIRE_MESSAGE(activate_state.IsValid(),
                              activate_state.ToString());
        wait_for_index();
    });
    BOOST_CHECK_EQUAL(
        WITH_LOCK(cs_main, return chainstate.m_chain.Tip()->GetBlockHash()),
        stress_hash);
    ShadowIndexBlockRecord reconnected_record;
    BOOST_REQUIRE(index.LookupBlock(stress_hash, reconnected_record));
    BOOST_CHECK_EQUAL(reconnected_record.pow_claims.accounting_commitment,
                      first_record.pow_claims.accounting_commitment);
    BOOST_CHECK_EQUAL(reconnected_record.pow_claims.observed_count,
                      expected_notes);

    SyncWithValidationInterfaceQueue();
    index.Stop();
    require_within_limit("clean shadowindex rebuild over maximum-weight block", [&] {
        ShadowIndex rebuilt{interfaces::MakeChain(m_node), 1 << 20,
                            /*memory=*/true, /*wipe=*/true};
        BOOST_REQUIRE(rebuilt.Init());
        BOOST_REQUIRE(rebuilt.StartBackgroundSync());
        IndexWaitSynced(rebuilt);
        ShadowIndexBlockRecord rebuilt_record;
        BOOST_REQUIRE(rebuilt.LookupBlock(stress_hash, rebuilt_record));
        BOOST_CHECK_EQUAL(rebuilt_record.pow_claims.accounting_commitment,
                          first_record.pow_claims.accounting_commitment);
        BOOST_CHECK_EQUAL(rebuilt_record.pow_claims.observed_count,
                          expected_notes);
        BOOST_CHECK_EQUAL(rebuilt_record.pow_claims.record_count, 0U);
        BOOST_CHECK_LE(GetSerializeSize(rebuilt_record),
                       MAX_PERSISTED_BLOCK_RECORD_BYTES);
        rebuilt.Stop();
    });
}

BOOST_FIXTURE_TEST_CASE(shadow_replay_preserves_pre_whitelist_snapshot_stats, TestChain100Setup)
{
    Chainstate& chainstate = Assert(m_node.chainman)->ActiveChainstate();
    chainstate.ForceFlushStateToDisk();
    const auto before = WITH_LOCK(cs_main, return kernel::ComputeUTXOStats(
        kernel::CoinStatsHashType::HASH_SERIALIZED,
        &chainstate.CoinsDB(),
        chainstate.m_blockman));
    BOOST_REQUIRE(before);

    BOOST_REQUIRE(chainstate.ReplayShadowBlocks() == Chainstate::ReplayResult::SUCCESS);

    const auto after = WITH_LOCK(cs_main, return kernel::ComputeUTXOStats(
        kernel::CoinStatsHashType::HASH_SERIALIZED,
        &chainstate.CoinsDB(),
        chainstate.m_blockman));
    BOOST_REQUIRE(after);
    BOOST_CHECK_EQUAL(after->hashSerialized, before->hashSerialized);
    BOOST_CHECK_EQUAL(after->coins_count, before->coins_count);
    BOOST_CHECK_EQUAL(after->nTransactionOutputs, before->nTransactionOutputs);

    {
        LOCK(cs_main);
        CCoinsViewCache view(&chainstate.CoinsDB());
        BOOST_CHECK(!HasShadowReplayState(view));
    }
}

BOOST_FIXTURE_TEST_CASE(shadow_replay_rejects_malformed_reserved_pre_whitelist_marker, TestChain100Setup)
{
    Chainstate& chainstate = Assert(m_node.chainman)->ActiveChainstate();
    chainstate.ForceFlushStateToDisk();
    const COutPoint replay_outpoint = ShadowReplayStateOutpointForTesting();

    {
        LOCK(cs_main);
        const CBlockIndex* tip = chainstate.m_chain.Tip();
        BOOST_REQUIRE(tip);
        Coin malformed;
        malformed.out.nValue = 1;
        malformed.out.scriptPubKey = CScript{} << OP_FALSE << OP_RETURN
            << std::vector<unsigned char>{'Q', 'Q', 'R', 'E', 'P', 'L', 'A', 'Y'}
            << std::vector<unsigned char>(32, 0);
        malformed.fCoinBase = true;
        malformed.fCoinStake = false;
        malformed.nHeight = tip->nHeight;
        malformed.nTime = tip->GetBlockTime();

        CCoinsViewCache cache(&chainstate.CoinsDB());
        cache.SetBestBlock(chainstate.CoinsDB().GetBestBlock());
        cache.AddCoin(replay_outpoint, std::move(malformed), true);
        BOOST_REQUIRE(cache.Flush());
    }

    BOOST_CHECK(chainstate.ReplayShadowBlocks() ==
                Chainstate::ReplayResult::CHAINSTATE_REBUILD_REQUIRED);

    {
        LOCK(cs_main);
        CCoinsViewCache cache(&chainstate.CoinsDB());
        Coin persisted;
        BOOST_REQUIRE(cache.GetCoin(replay_outpoint, persisted));
        BOOST_CHECK_EQUAL(persisted.out.nValue, 1);
    }
}

BOOST_FIXTURE_TEST_CASE(coinstatsindex_initial_sync, TestChain100Setup)
{
    CoinStatsIndex coin_stats_index{interfaces::MakeChain(m_node), 1 << 20, true};
    BOOST_REQUIRE(coin_stats_index.Init());

    const CBlockIndex* block_index;
    {
        LOCK(cs_main);
        block_index = m_node.chainman->ActiveChain().Tip();
    }

    // CoinStatsIndex should not be found before it is started.
    BOOST_CHECK(!coin_stats_index.LookUpStats(*block_index));

    // BlockUntilSyncedToCurrentChain should return false before CoinStatsIndex
    // is started.
    BOOST_CHECK(!coin_stats_index.BlockUntilSyncedToCurrentChain());

    BOOST_REQUIRE(coin_stats_index.StartBackgroundSync());

    IndexWaitSynced(coin_stats_index);

    // Check that CoinStatsIndex works for genesis block.
    const CBlockIndex* genesis_block_index;
    {
        LOCK(cs_main);
        genesis_block_index = m_node.chainman->ActiveChain().Genesis();
    }
    BOOST_CHECK(coin_stats_index.LookUpStats(*genesis_block_index));

    // Check that CoinStatsIndex updates with new blocks.
    BOOST_CHECK(coin_stats_index.LookUpStats(*block_index));

    const CScript script_pub_key{CScript() << ToByteVector(coinbaseKey.GetPubKey()) << OP_CHECKSIG};
    std::vector<CMutableTransaction> noTxns;
    CreateAndProcessBlock(noTxns, script_pub_key);

    // Let the CoinStatsIndex to catch up again.
    BOOST_CHECK(coin_stats_index.BlockUntilSyncedToCurrentChain());

    const CBlockIndex* new_block_index;
    {
        LOCK(cs_main);
        new_block_index = m_node.chainman->ActiveChain().Tip();
    }
    BOOST_CHECK(coin_stats_index.LookUpStats(*new_block_index));

    BOOST_CHECK(block_index != new_block_index);

    // It is not safe to stop and destroy the index until it finishes handling
    // the last BlockConnected notification. The BlockUntilSyncedToCurrentChain()
    // call above is sufficient to ensure this, but the
    // SyncWithValidationInterfaceQueue() call below is also needed to ensure
    // TSAN always sees the test thread waiting for the notification thread, and
    // avoid potential false positive reports.
    SyncWithValidationInterfaceQueue();

    // Shutdown sequence (c.f. Shutdown() in init.cpp)
    coin_stats_index.Stop();
}

// Test shutdown between BlockConnected and ChainStateFlushed notifications,
// make sure index is not corrupted and is able to reload.
BOOST_FIXTURE_TEST_CASE(coinstatsindex_unclean_shutdown, TestChain100Setup)
{
    Chainstate& chainstate = Assert(m_node.chainman)->ActiveChainstate();
    const CChainParams& params = Params();
    {
        CoinStatsIndex index{interfaces::MakeChain(m_node), 1 << 20};
        BOOST_REQUIRE(index.Init());
        BOOST_REQUIRE(index.StartBackgroundSync());
        IndexWaitSynced(index);
        std::shared_ptr<const CBlock> new_block;
        CBlockIndex* new_block_index = nullptr;
        {
            const CScript script_pub_key{CScript() << ToByteVector(coinbaseKey.GetPubKey()) << OP_CHECKSIG};
            const CBlock block = this->CreateBlock({}, script_pub_key, chainstate);

            new_block = std::make_shared<CBlock>(block);

            LOCK(cs_main);
            BlockValidationState state;
            BOOST_CHECK(CheckBlock(block, state, params.GetConsensus(), chainstate));
            BOOST_CHECK(m_node.chainman->AcceptBlock(new_block, state, &new_block_index, true, nullptr, nullptr, true));
            CCoinsViewCache view(&chainstate.CoinsTip());
            BOOST_CHECK(chainstate.ConnectBlock(block, state, new_block_index, view));
        }
        // Send block connected notification, then stop the index without
        // sending a chainstate flushed notification. Prior to #24138, this
        // would cause the index to be corrupted and fail to reload.
        ValidationInterfaceTest::BlockConnected(ChainstateRole::NORMAL, index, new_block, new_block_index);
        index.Stop();
    }

    {
        CoinStatsIndex index{interfaces::MakeChain(m_node), 1 << 20};
        BOOST_REQUIRE(index.Init());
        // Make sure the index can be loaded.
        BOOST_REQUIRE(index.StartBackgroundSync());
        index.Stop();
    }
}

BOOST_AUTO_TEST_SUITE_END()
