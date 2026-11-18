// Copyright (c) 2026 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_COIN_FACTS_H
#define BITCOIN_WALLET_COIN_FACTS_H

#include <coins.h>
#include <kernel/cs_main.h>
#include <primitives/transaction.h>
#include <sync.h>
#include <uint256.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <vector>

class CBlockIndex;

namespace wallet {

/**
 * Chainstate facts of wallet outputs for display and polling: how to know
 * them without the coins database, and how to read the rest of them from it
 * in an order a spinning disk can serve.
 *
 * Nothing here is an authority for spending. Coin selection, staking kernels
 * and claim creation read the coins view themselves.
 */

/** Reads through to the chainstate cache without adding to it. A scratch
 * CCoinsViewCache on top of this keeps whatever a display pass reads for the
 * length of one slice; the chainstate cache itself does not grow. */
class CoinsViewPeek final : public CCoinsView
{
    const CCoinsViewCache& m_source;

public:
    explicit CoinsViewPeek(const CCoinsViewCache& source) : m_source(source) {}
    bool GetCoin(const COutPoint& outpoint, Coin& coin) const override { return m_source.PeekCoin(outpoint, coin); }
    bool HaveCoin(const COutPoint& outpoint) const override
    {
        Coin coin;
        return m_source.PeekCoin(outpoint, coin);
    }
    uint256 GetBestBlock() const override { return m_source.GetBestBlock(); }
};

/** Number of items that do not read the chainstate between two clock reads of
 * a cs_main slice. */
inline constexpr uint64_t CHAIN_CLOCK_INTERVAL{16};

/** What the wallet knows about a confirmed transaction, enough to say what
 * coin each of its outputs became when its block was connected. */
struct ConfirmedTxFacts {
    int32_t version{0};
    uint32_t time{0};
    bool coinbase{false};
    bool coinstake{false};
    uint256 block_hash;
    int block_height{-1};
};

/**
 * The coin that connecting the block made of one output of a confirmed
 * transaction, without reading the coins database: the output itself, the
 * height of the block, the transaction's coinbase and coinstake shape and its
 * coin time (the transaction's own time below version 2, the time of the
 * block from version 2 on). This is exactly what AddCoins() stored and what
 * DisconnectBlock() requires to find again.
 *
 * Returns nullopt, and the caller reads the coins database instead, when
 *  - the transaction is coinbase shaped: a coinbase output, and the synthetic
 *    Gold Rush payout the wallet keeps as a coinbase shaped transaction, need
 *    their provenance records from the chainstate;
 *  - the output is unspendable (it never entered the UTXO set);
 *  - the block is not the block of the active chain at that height (the
 *    transaction was reorganized out, or the wallet has not caught up).
 *
 * What is not established here is that the coin is still unspent. No block
 * connect or disconnect path removes or rewrites the coin of a transaction
 * output other than a transaction input that spends it, and the wallet marks
 * such an input when it processes the block; the caller only asks for outputs
 * the wallet holds unspent at the tip it has processed.
 */
std::optional<Coin> DeriveConfirmedCoin(const CTxOut& txout, const ConfirmedTxFacts& tx, const CBlockIndex* tip)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main);

/** The coin time AddCoins() gives the outputs of a transaction of this
 * version and time in a block of this time (see GetCoinTime()). */
uint32_t ConfirmedCoinTime(int32_t tx_version, uint32_t tx_time, uint32_t block_time);

/** Whether the coins database key of `a` sorts before that of `b`. The key is
 * the byte 'C', the 32 bytes of the txid and VARINT(n), compared bytewise. */
bool ChainstateKeyLess(const COutPoint& a, const COutPoint& b);

/** The coins database key of an outpoint, for tests of the order. */
std::vector<unsigned char> ChainstateKeyBytes(const COutPoint& outpoint);

enum class OrderedSliceResult {
    MORE,      //!< the slice ended on its limit; call again
    DONE,      //!< every item was visited at one tip
    RESTARTED, //!< the tip moved since the first item was visited: the cursor is back at the start
    STOPPED,   //!< the visitor asked to stop; the cursor stays on that item
};

/**
 * Visits a set of outpoints in the order of their coins database keys, in
 * slices of cs_main, all at one chain tip.
 *
 * A wallet hands out its outputs in the order of a hash table, which for the
 * coins database is a random order: every read lands on another block of the
 * table files. Sorted by key the reads walk each file forward once, which is
 * what a spinning disk and the block cache can serve.
 *
 * Every slice names the tip it runs at. A slice that finds another tip than
 * the one the pass started at puts the cursor back to the start and says so;
 * the caller drops what it has gathered.
 */
class OrderedChainCursor
{
public:
    /** Start over with `count` items; `outpoint_at(i)` names item i. */
    template <typename OutpointAt>
    void Reset(size_t count, OutpointAt&& outpoint_at)
    {
        m_order.resize(count);
        for (size_t i = 0; i < count; ++i) m_order[i] = static_cast<uint32_t>(i);
        std::sort(m_order.begin(), m_order.end(), [&](uint32_t a, uint32_t b) {
            return ChainstateKeyLess(outpoint_at(a), outpoint_at(b));
        });
        m_cursor = 0;
        m_started = false;
    }
    void Clear()
    {
        m_order.clear();
        m_cursor = 0;
        m_started = false;
    }
    size_t Size() const { return m_order.size(); }
    size_t Position() const { return m_cursor; }
    bool Done() const { return m_cursor >= m_order.size(); }
    uint64_t Restarts() const { return m_restarts; }
    /** The item numbers in visiting order. */
    const std::vector<uint32_t>& Order() const { return m_order; }

    /**
     * Run one slice. `visit(item, view)` resolves one item against `view`, a
     * scratch cache over the peek path of `coins_tip`, and returns whether it
     * read the chainstate (true), did not (false), or must stop (nullopt).
     * `meter` is a SliceMeter: it is asked before every item and told after.
     */
    template <typename Meter, typename Visit>
    OrderedSliceResult RunSlice(const CCoinsViewCache& coins_tip, const uint256& tip_hash, Meter& meter, Visit&& visit)
        EXCLUSIVE_LOCKS_REQUIRED(::cs_main)
    {
        AssertLockHeld(::cs_main);
        if (m_started && tip_hash != m_tip_hash) {
            m_cursor = 0;
            m_started = false;
            ++m_restarts;
            return OrderedSliceResult::RESTARTED;
        }
        m_tip_hash = tip_hash;
        m_started = true;
        CoinsViewPeek peek{coins_tip};
        CCoinsViewCache view{&peek};
        while (m_cursor < m_order.size()) {
            if (meter.Expired()) return OrderedSliceResult::MORE;
            const std::optional<bool> read_chainstate = visit(m_order[m_cursor], view);
            if (!read_chainstate) return OrderedSliceResult::STOPPED;
            ++m_cursor;
            if (*read_chainstate) {
                meter.TickChainItem();
            } else {
                meter.Tick(CHAIN_CLOCK_INTERVAL);
            }
        }
        return OrderedSliceResult::DONE;
    }

private:
    std::vector<uint32_t> m_order;
    size_t m_cursor{0};
    bool m_started{false};
    uint256 m_tip_hash;
    uint64_t m_restarts{0};
};

/**
 * Reads the coins of a set of outpoints through OrderedChainCursor. The
 * result of every outpoint is the unspent coin the active chainstate holds
 * for it at the tip the read finished at, or nullopt.
 */
class OrderedCoinReader
{
public:
    explicit OrderedCoinReader(std::vector<COutPoint> outpoints);

    /** One slice of cs_main. DONE when Coins() is complete for `tip_hash`. */
    template <typename Meter>
    OrderedSliceResult RunSlice(const CCoinsViewCache& coins_tip, const uint256& tip_hash, Meter& meter)
        EXCLUSIVE_LOCKS_REQUIRED(::cs_main)
    {
        const OrderedSliceResult result = m_cursor.RunSlice(coins_tip, tip_hash, meter,
            [&](uint32_t item, const CCoinsViewCache& view) -> std::optional<bool> {
                Coin coin;
                if (view.GetCoin(m_outpoints[item], coin) && !coin.IsSpent()) {
                    m_coins[item] = std::move(coin);
                } else {
                    m_coins[item].reset();
                }
                if (m_on_read) m_on_read(m_outpoints[item]);
                return true;
            });
        if (result == OrderedSliceResult::RESTARTED) {
            for (std::optional<Coin>& coin : m_coins) coin.reset();
        }
        if (result == OrderedSliceResult::DONE) m_tip_hash = tip_hash;
        return result;
    }

    const std::vector<COutPoint>& Outpoints() const { return m_outpoints; }
    /** By the position the outpoint had in the constructor's argument. */
    const std::vector<std::optional<Coin>>& Coins() const { return m_coins; }
    const uint256& TipHash() const { return m_tip_hash; }
    uint64_t Restarts() const { return m_cursor.Restarts(); }
    bool Done() const { return m_cursor.Done(); }
    //! Test only: called with every outpoint as it is read.
    void SetOnReadForTest(std::function<void(const COutPoint&)> on_read) { m_on_read = std::move(on_read); }

private:
    std::vector<COutPoint> m_outpoints;
    std::vector<std::optional<Coin>> m_coins;
    OrderedChainCursor m_cursor;
    uint256 m_tip_hash;
    std::function<void(const COutPoint&)> m_on_read;
};

/**
 * A coins view that holds only what was read for it. A coin it knows (or
 * knows to be absent) is answered from memory. A coin it does not know is
 * answered as absent and noted as missing: whoever asked got a provisional
 * answer and must ask again once the missing coins have been read.
 */
class PlannedCoinsView final : public CCoinsView
{
public:
    bool GetCoin(const COutPoint& outpoint, Coin& coin) const override
    {
        const auto it = m_known.find(outpoint);
        if (it == m_known.end()) {
            ++m_unknown_requests;
            m_missing.insert(outpoint);
            return false;
        }
        if (!it->second) return false;
        coin = *it->second;
        return true;
    }
    bool HaveCoin(const COutPoint& outpoint) const override
    {
        Coin coin;
        return GetCoin(outpoint, coin);
    }
    uint256 GetBestBlock() const override { return m_best_block; }
    void SetBestBlock(const uint256& hash) { m_best_block = hash; }

    /** Grows with every request for a coin that is not known. */
    uint64_t UnknownRequests() const { return m_unknown_requests; }
    /** The coins asked for and not known, each once; forgets the list. */
    std::vector<COutPoint> TakeMissing()
    {
        std::vector<COutPoint> missing{m_missing.begin(), m_missing.end()};
        m_missing.clear();
        return missing;
    }
    void Learn(const COutPoint& outpoint, std::optional<Coin> coin) { m_known[outpoint] = std::move(coin); }
    size_t Known() const { return m_known.size(); }
    void Clear()
    {
        m_known.clear();
        m_missing.clear();
    }

private:
    std::map<COutPoint, std::optional<Coin>> m_known;
    mutable std::set<COutPoint> m_missing;
    mutable uint64_t m_unknown_requests{0};
    uint256 m_best_block;
};

/**
 * Resolves a set of items against the chainstate so that the coins database
 * is read in ascending key order, whatever the items need from it.
 *
 * What an item needs is not known in advance: the coin of an output, then,
 * if that coin is coinbase, the records of a Gold Rush payout under derived
 * keys, the demurrage attestation of its script. So the work goes in rounds.
 * A round computes every unresolved item against a PlannedCoinsView, which
 * holds what has been read so far and notes what it was asked for and does
 * not have; an item whose computation asked for nothing unknown is resolved
 * and committed. Then everything that was missing is sorted by database key
 * and read in one ascending sweep through the peek path, and the next round
 * computes the items that are left. The first sweep is the coins of all
 * outputs, the second every record derived from them, and only an item whose
 * records name further records (an authenticated payout) takes more sweeps.
 *
 * Both the rounds and the sweeps run in slices of cs_main under a SliceMeter
 * and resume where the previous slice stopped. The sort happens without a
 * lock (PrepareUnlocked). With `restart_on_tip_move` a slice that finds
 * another tip than the plan started at forgets everything and says so.
 */
class ChainReadPlan
{
public:
    /** Start over with items 0..count-1 unresolved and nothing read. */
    void Reset(size_t count)
    {
        m_unresolved.resize(count);
        for (size_t i = 0; i < count; ++i) m_unresolved[i] = static_cast<uint32_t>(i);
        m_next_unresolved.clear();
        m_view.Clear();
        m_wave.clear();
        m_eval_cursor = 0;
        m_read_cursor = 0;
        m_reading = false;
        m_wave_sorted = false;
        m_started = false;
        m_count = count;
        m_committed = 0;
        m_active = true;
    }
    bool Active() const { return m_active; }
    size_t Count() const { return m_count; }
    /** Items not resolved yet. */
    size_t Unresolved() const { return m_count - m_committed; }
    /** Keys of the sweep in progress that are still to be read. */
    size_t ReadsWaiting() const { return m_reading ? m_wave.size() - m_read_cursor : 0; }
    uint64_t Restarts() const { return m_restarts; }
    /** Sweeps started so far. */
    uint32_t Sweeps() const { return m_sweeps; }
    uint64_t KeysRead() const { return m_keys_read; }
    //! Test only: called with every key as it is read from the chainstate.
    void SetOnReadForTest(std::function<void(const COutPoint&)> on_read) { m_on_read = std::move(on_read); }

    /** What can be done without a lock: sort the keys of the next sweep. */
    void PrepareUnlocked()
    {
        if (m_reading && !m_wave_sorted) {
            std::sort(m_wave.begin(), m_wave.end(), ChainstateKeyLess);
            m_wave_sorted = true;
        }
    }

    /**
     * One slice. `compute(item, view)` computes an item against the planned
     * view and has no effect outside its return value; `commit(item, value)`
     * is called with that value when the computation asked for no coin the
     * view does not know, and returns false to stop (STOPPED).
     */
    template <typename Meter, typename Compute, typename Commit>
    OrderedSliceResult RunSlice(const CCoinsViewCache& coins_tip, const uint256& tip_hash, bool restart_on_tip_move,
                                Meter& meter, Compute&& compute, Commit&& commit)
        EXCLUSIVE_LOCKS_REQUIRED(::cs_main)
    {
        AssertLockHeld(::cs_main);
        if (m_started && restart_on_tip_move && tip_hash != m_tip_hash) {
            Reset(m_count);
            ++m_restarts;
            return OrderedSliceResult::RESTARTED;
        }
        m_tip_hash = tip_hash;
        m_started = true;
        m_view.SetBestBlock(tip_hash);
        for (;;) {
            if (m_reading) {
                // Sorted by the caller between two slices, without the lock.
                if (!m_wave_sorted) return OrderedSliceResult::MORE;
                const CoinsViewPeek peek{coins_tip};
                while (m_read_cursor < m_wave.size()) {
                    if (meter.Expired()) return OrderedSliceResult::MORE;
                    const COutPoint& key = m_wave[m_read_cursor];
                    Coin coin;
                    if (peek.GetCoin(key, coin) && !coin.IsSpent()) {
                        m_view.Learn(key, std::move(coin));
                    } else {
                        m_view.Learn(key, std::nullopt);
                    }
                    ++m_keys_read;
                    if (m_on_read) m_on_read(key);
                    ++m_read_cursor;
                    meter.TickChainItem();
                }
                m_wave.clear();
                m_read_cursor = 0;
                m_reading = false;
            }
            {
                // Hits are copied into this scratch cache for the slice only.
                CCoinsViewCache scratch{&m_view};
                const CCoinsViewCache& view{scratch};
                while (m_eval_cursor < m_unresolved.size()) {
                    if (meter.Expired()) return OrderedSliceResult::MORE;
                    const uint32_t item = m_unresolved[m_eval_cursor];
                    const uint64_t unknown_before = m_view.UnknownRequests();
                    auto value = compute(item, view);
                    if (m_view.UnknownRequests() == unknown_before) {
                        if (!commit(item, std::move(value))) return OrderedSliceResult::STOPPED;
                        ++m_committed;
                    } else {
                        m_next_unresolved.push_back(item);
                    }
                    ++m_eval_cursor;
                    meter.Tick();
                }
            }
            m_unresolved.swap(m_next_unresolved);
            m_next_unresolved.clear();
            m_eval_cursor = 0;
            m_wave = m_view.TakeMissing();
            if (m_wave.empty()) {
                // Nothing was missing, so nothing is unresolved.
                m_unresolved.clear();
                return OrderedSliceResult::DONE;
            }
            m_reading = true;
            m_wave_sorted = false;
            ++m_sweeps;
            // The sweep starts with the next slice, after the sort.
            return OrderedSliceResult::MORE;
        }
    }

private:
    PlannedCoinsView m_view;
    std::vector<uint32_t> m_unresolved;
    std::vector<uint32_t> m_next_unresolved;
    std::vector<COutPoint> m_wave;
    size_t m_eval_cursor{0};
    size_t m_read_cursor{0};
    size_t m_count{0};
    size_t m_committed{0};
    bool m_reading{false};
    bool m_wave_sorted{false};
    bool m_started{false};
    bool m_active{false};
    uint256 m_tip_hash;
    uint64_t m_restarts{0};
    uint64_t m_keys_read{0};
    uint32_t m_sweeps{0};
    std::function<void(const COutPoint&)> m_on_read;
};

} // namespace wallet

#endif // BITCOIN_WALLET_COIN_FACTS_H
