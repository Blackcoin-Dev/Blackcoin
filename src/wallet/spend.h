// Copyright (c) 2021-2022 Blackcoin Core Developers
// Copyright (c) 2021-2022 Blackcoin More Developers
// Copyright (c) 2021-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_SPEND_H
#define BITCOIN_WALLET_SPEND_H

#include <consensus/amount.h>
#include <consensus/demurrage.h>
#include <policy/fees.h> // for FeeCalculation
#include <shadow.h>
#include <util/result.h>
#include <wallet/coin_facts.h>
#include <wallet/coinselection.h>
#include <wallet/receive.h>
#include <wallet/transaction.h>
#include <wallet/wallet.h>

#include <array>
#include <algorithm>
#include <chrono>
#include <functional>
#include <map>
#include <optional>
#include <set>
#include <vector>

namespace wallet {
struct Balance;
struct WalletLifecycleAmounts {
    static constexpr size_t CATEGORY_COUNT{static_cast<size_t>(ValueLifecycleCategory::COUNT)};
    std::array<uint64_t, CATEGORY_COUNT> outputs{};
    std::array<CAmount, CATEGORY_COUNT> nominal{};
    std::array<CAmount, CATEGORY_COUNT> effective{};
    std::array<CAmount, CATEGORY_COUNT> burned{};
    CAmount ordinary_available{0};
    CAmount spendable_legacy{0};
    CAmount spendable_quantum{0};
};

struct WalletLifecycleSummary {
    int evaluation_height{0};
    int64_t evaluation_mtp{0};
    WalletLifecycleAmounts mine;
    WalletLifecycleAmounts watchonly;
};

/** One deep memoized output in this many is re-read from the database on
 * every memo-enabled scan (selected by outpoint hash, index and tip height). */
static constexpr uint64_t LIFECYCLE_MEMO_VERIFY_MODULUS{1024};

/** Counters filled by a lifecycle scan, for logging and tests. */
struct WalletLifecycleScanStats {
    uint64_t outputs{0};        //!< outputs classified
    uint64_t database_reads{0}; //!< outputs whose chainstate facts were read from the coins view
    uint64_t memo_hits{0};      //!< outputs served from the wallet's lifecycle memo
    bool budget_exhausted{false}; //!< the scan stopped because its budget ran out
    uint64_t memo_mismatches{0}; //!< verified memo entries that disagreed with the chainstate (each one was dropped)
    uint64_t pending{0};        //!< sliced passes: outputs handed to the chainstate slices
    uint64_t derived{0};        //!< outputs whose chainstate facts were derived from the wallet transaction and the active chain, without a database read
};

/** Latest demurrage attestation per scriptPubKey, resolved at most once per
 * scan. Filled lazily by GetWalletOutputLifecycle when supplied. */
using LifecycleAttestationMap = std::map<CScript, std::optional<Consensus::DemurrageAttestationState>>;

/** Optional behaviour of the lifecycle accounting. The defaults reproduce the
 * un-memoized behaviour exactly. */
struct WalletLifecycleOptions {
    /** Serve chainstate facts of deep confirmed outputs from the wallet's
     * in-memory memo (GUI display path only). */
    bool use_memo{false};
    /** Memo-enabled scans only: stop (returning false with stats->budget_exhausted
     * set) once this much time has passed, checked every 16 database reads. 0 =
     * unlimited. Memo entries stored so far are kept. */
    std::chrono::milliseconds budget{0};
    /** Memo-enabled scans only: stop after this many database reads (0 =
     * unlimited). Deterministic knob for tests. */
    uint64_t max_database_reads{0};
    WalletLifecycleScanStats* stats{nullptr};
    /** Memo-enabled scans only: when set, the demurrage attestation of a
     * script is read from (and stored in) this map instead of being read from
     * the coins view once per output. */
    LifecycleAttestationMap* attestations{nullptr};
};

/** Whether the wallet transaction view and active UTXO view describe the
 * same chain tip. Lifecycle accounting must not combine the wallet state from
 * one tip with coins from another. */
bool WalletLifecycleViewIsSynchronized(const CWallet& wallet)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

/** Classify one wallet output against the candidate next block using the
 * active-chain coin and authenticated Gold Rush provenance. */
bool GetWalletOutputLifecycle(const CWallet& wallet, const COutPoint& outpoint,
                              const CTxOut& txout,
                              ValueLifecycleClassification& classification,
                              std::string& error,
                              const WalletLifecycleOptions& options = {})
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

/** Return the ordinary-spendable wallet balance and a mutually exclusive
 * lifecycle inventory. Locked synthetic, contract, Final, and fully decayed
 * outputs never enter the trusted available balance. */
bool GetLifecycleAdjustedBalance(const CWallet& wallet, int min_depth,
                                 bool avoid_reuse, Balance& balance,
                                 WalletLifecycleSummary& summary,
                                 std::string& error,
                                 const WalletLifecycleOptions& options = {})
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

/** Chain facts a display balance pass captures under cs_main before it reads
 * the wallet without it. */
struct LifecycleScanTip {
    uint256 hash;
    int height{0};
    int evaluation_height{0};
    int64_t evaluation_mtp{0};
    //! Whether demurrage applies at the evaluation height (the attestation of
    //! each output's script is then needed to classify it).
    bool demurrage_active{false};
};

/**
 * The sliced display balance engine.
 *
 * The balance the GUI shows is computed by a background worker in slices.
 * Every slice takes exactly one of cs_main and cs_wallet (never both), with a
 * try-lock, for a bounded time. Three resumable pieces of state exist per
 * wallet:
 *
 *  - LifecycleMemoJournal: chainstate facts read under cs_main that still
 *    have to be written to the wallet's lifecycle memo under cs_wallet. Each
 *    entry is validated against the wallet when it is applied, so entries
 *    survive any restart.
 *  - LifecycleWarmup: fills the memo of a wallet that has many deep outputs
 *    without a memo entry (after a start). A cursor over mapWallet; it does
 *    not depend on the tip or on the wallet change marker, so nothing it has
 *    done is ever discarded.
 *  - LifecyclePass: one consistent computation of the balance for a tip T and
 *    a wallet change marker m. It walks the wallet (cs_wallet slices), reads
 *    whatever needs the chainstate (cs_main slices) and restarts, keeping the
 *    journal, when T or m moves. Its result is exact for (T, m): every wallet
 *    slice saw marker m and the wallet at T, every chainstate slice saw the
 *    active tip T.
 */

/** Limits of one slice. A budget of zero means no time limit. */
struct LifecycleSliceLimits {
    std::chrono::milliseconds wallet_budget{20};
    std::chrono::milliseconds main_budget{25};
    //! Deterministic knob for tests: end a slice after this many items
    //! (transactions and outputs walked, outputs resolved, entries stored).
    uint64_t max_items{0};
    //! Clock, injectable for tests. Empty = std::chrono::steady_clock::now.
    std::function<std::chrono::steady_clock::time_point()> now;
    //! Test only: called for every item of a slice before the meter looks at
    //! the clock, so that an injected clock can charge each item what it costs.
    std::function<void()> on_item;
    //! Number of items between two clock reads: every item. What a wallet
    //! record or one of its outputs costs depends on memory the slice cannot
    //! see (cached amounts that were invalidated, pages the system has
    //! compressed or paged out), so a count of items says nothing about the
    //! time that has passed; 64 such items took more than a second on a
    //! machine short of memory. A clock read costs tens of nanoseconds.
    static constexpr uint64_t CLOCK_INTERVAL{1};

    static LifecycleSliceLimits Unlimited()
    {
        LifecycleSliceLimits limits;
        limits.wallet_budget = std::chrono::milliseconds{0};
        limits.main_budget = std::chrono::milliseconds{0};
        return limits;
    }
};

/**
 * Counts the items of a slice and says when the slice must end. Items that
 * read the chainstate (TickChainItem) read the clock every time and end the
 * slice early when the budget left cannot pay for the costliest such item
 * seen so far, because one item can make up to three uncached chainstate
 * reads; but only once at least MIN_ITEMS_BEFORE_EARLY_END items were done in
 * this slice (or the budget is already used up). Slices are spaced by the
 * worker's forced interval, so a slice that stopped after one item whenever an
 * item cost more than half the budget would make warm-up many times slower.
 * Items that do not read the chainstate (Tick) read the clock every time too
 * and end the slice when the budget is used up; a caller may pass a larger
 * `clock_interval` for items that only read what the slice itself has built.
 * A slice always finishes the item it is on (a wallet slice: the mapWallet
 * bucket it is in, which is one record as a rule), so it stays within its
 * budget plus the cost of that item (a chainstate slice: of at most
 * MIN_ITEMS_BEFORE_EARLY_END - 1 more items), and always makes progress.
 */
class SliceMeter
{
public:
    static constexpr uint64_t MIN_ITEMS_BEFORE_EARLY_END{4};

    //! The meter keeps its own copy of the limits: it may be built from a
    //! temporary and outlive it.
    SliceMeter(const LifecycleSliceLimits& limits, std::chrono::milliseconds budget)
        : m_limits(limits), m_timed(budget.count() > 0), m_start(Now()), m_deadline(m_start + budget), m_last_read(m_start) {}

    std::chrono::steady_clock::time_point Now() const
    {
        return m_limits.now ? m_limits.now() : std::chrono::steady_clock::now();
    }
    /** Count one item that did not read the chainstate. True when the slice must end; it stays true. */
    bool Tick(uint64_t clock_interval = LifecycleSliceLimits::CLOCK_INTERVAL)
    {
        ++m_items;
        if (m_limits.on_item) m_limits.on_item();
        if (m_expired) return true;
        if (m_limits.max_items > 0 && m_items >= m_limits.max_items) {
            m_expired = true;
        } else if (m_timed && m_items % clock_interval == 0) {
            m_last_read = Now();
            if (m_last_read >= m_deadline) m_expired = true;
        }
        return m_expired;
    }
    /** Count one item that read the chainstate. */
    bool TickChainItem()
    {
        ++m_items;
        if (m_limits.on_item) m_limits.on_item();
        if (m_expired) return true;
        if (m_limits.max_items > 0 && m_items >= m_limits.max_items) {
            m_expired = true;
        } else if (m_timed) {
            const auto now = Now();
            m_max_chain_item = std::max(m_max_chain_item,
                                        std::chrono::duration_cast<std::chrono::microseconds>(now - m_last_read));
            m_last_read = now;
            if (now >= m_deadline ||
                (m_items >= MIN_ITEMS_BEFORE_EARLY_END && now + m_max_chain_item > m_deadline)) {
                m_expired = true;
            }
        }
        return m_expired;
    }
    bool Expired() const { return m_expired; }
    /** Costliest chainstate item seen, for carrying over to the next slice of the same pass. */
    std::chrono::microseconds MaxChainItem() const { return m_max_chain_item; }
    /** Start from half the previous slice's costliest item: a single outlier then stops mattering after a few slices. */
    void SeedMaxChainItem(std::chrono::microseconds previous) { m_max_chain_item = std::max(m_max_chain_item, previous / 2); }
    std::chrono::microseconds Held() const
    {
        return std::chrono::duration_cast<std::chrono::microseconds>(Now() - m_start);
    }

private:
    const LifecycleSliceLimits m_limits;
    const bool m_timed;
    const std::chrono::steady_clock::time_point m_start;
    const std::chrono::steady_clock::time_point m_deadline;
    std::chrono::steady_clock::time_point m_last_read;
    std::chrono::microseconds m_max_chain_item{0};
    uint64_t m_items{0};
    bool m_expired{false};
};

/** Demurrage attestations by script, valid for one tip only. Kept across the
 * slices and the restarts of the passes of a wallet for as long as the tip
 * holds, so that a wallet with many scripts converges. */
struct LifecycleAttestationCache {
    uint256 tip_hash;
    LifecycleAttestationMap map;
    void ResetFor(const uint256& tip)
    {
        if (tip_hash == tip) return;
        tip_hash = tip;
        map.clear();
    }
};

/** Memo changes waiting for a cs_wallet slice. */
struct LifecycleMemoJournal {
    struct Entry {
        COutPoint outpoint;
        //! What the wallet said about the transaction when the facts were
        //! requested; the entry is applied only if the wallet still says so.
        uint256 confirmed_block_hash;
        int confirmed_block_height{0};
        uint64_t txout_digest{0};
        WalletOutputLifecycleMemo memo;
        //! Drop the memo entry of the outpoint instead of writing one.
        bool erase{false};
    };
    std::vector<Entry> entries;
    size_t cursor{0};
    uint64_t stored{0};  //!< entries written since the journal was created
    uint64_t dropped{0}; //!< entries the wallet no longer agreed with
    uint64_t erased{0};  //!< memo entries removed after a disagreement with the chainstate
    uint64_t mismatches{0}; //!< verified entries that disagreed with the chainstate
    //! Drop the whole memo at the next wallet slice (repeated disagreements).
    bool clear_all{false};
    size_t Waiting() const { return entries.size() - cursor; }
};

enum class LifecycleSliceResult {
    MORE,         //!< the slice ended on its limit; call again
    DONE,         //!< the pass has a result / the warm-up has nothing left to do
    UP_TO_DATE,   //!< pass only: the wallet is at LifecyclePass::known, nothing was computed
    LOCK_BUSY,    //!< the lock the slice needs was not free; nothing was done
    NOT_SYNCED,   //!< pass only: the wallet has not processed the active tip (pass reset)
    TIP_MOVED,    //!< pass only: the active tip moved (pass reset, journal kept)
    WALLET_MOVED, //!< pass only: the wallet changed (pass reset, journal kept)
    NEED_WARMUP,  //!< pass only: too many deep outputs without a memo entry (pass reset)
    FAILED,       //!< pass only: an error (pass reset); see LifecycleSliceReport::error
};

struct LifecycleSliceReport {
    LifecycleSliceResult result{LifecycleSliceResult::MORE};
    bool held_main{false};
    bool held_wallet{false};
    //! How long the lock was held, by LifecycleSliceLimits::now.
    std::chrono::microseconds held{0};
    std::string error;
};

/** An output of a pass whose classification needs the chainstate. A copy of
 * everything the chainstate slice needs, so that it runs without cs_wallet. */
struct LifecyclePassOutput {
    COutPoint outpoint;
    CTxOut txout;
    bool wallet_immature{false};
    bool mine_spendable{false};
    bool watchonly{false};
    bool tx_coinbase{false};
    bool tx_coinstake{false};
    //! The memoized facts are usable; only the demurrage attestation is missing.
    bool memo_hit{false};
    //! The memo entry is in the verify slice: compare it with the chainstate.
    bool verify{false};
    //! Deep enough for the memo (the facts read are journaled).
    bool memo_eligible{false};
    //! Unconfirmed and in the mempool: classified as a candidate next-block coin.
    bool in_mempool{false};
    int64_t tx_time{0};
    WalletOutputLifecycleMemo memo;
    //! The confirming block the wallet names (memo-eligible or derivable outputs).
    uint256 confirmed_block_hash;
    int confirmed_block_height{0};
    uint64_t txout_digest{0};
    //! A confirmed transaction that is not coinbase shaped: the chainstate
    //! slice derives the coin (DeriveConfirmedCoin) instead of reading it.
    bool derivable{false};
    int32_t tx_version{0};
    uint32_t tx_ntime{0};
};

struct LifecyclePass {
    enum class Stage { TIP, WALK, CHAIN, STORE, CONFIRM, DONE };
    Stage stage{Stage::TIP};

    // Options; they survive a reset.
    int min_depth{0};
    bool avoid_reuse{true};
    //! When nonzero, the walk gives up (NEED_WARMUP) as soon as more than this
    //! many memo-eligible outputs have no memo entry.
    uint64_t warmup_threshold{0};
    //! The tip and marker of the result the caller already has. A pass that
    //! finds the wallet there returns UP_TO_DATE instead of walking it.
    std::optional<std::pair<uint256, uint64_t>> known;
    //! Test only: treat demurrage as active whatever the chain parameters say.
    bool force_demurrage{false};

    // State of the pass in progress.
    LifecycleScanTip tip;
    uint64_t marker{0};
    bool marker_set{false};
    bool have_watch_only{false};
    size_t bucket{0};
    size_t bucket_count{0};
    std::set<uint256> trusted_parents;
    Balance balance;
    WalletLifecycleSummary summary;
    std::vector<LifecyclePassOutput> pending;
    //! Resolves `pending` against the chainstate: every coin in one ascending
    //! sweep of the coins database, then every derived record in another.
    ChainReadPlan chain_plan;
    //! Outputs of `pending` resolved so far.
    size_t chain_cursor{0};
    WalletLifecycleScanStats stats;
    uint64_t memo_misses{0};     //!< memo-eligible outputs without a usable entry
    uint64_t memo_mismatches{0}; //!< verified entries that disagreed with the chainstate
    uint32_t slices{0};
    //! Costliest chainstate item of the latest slice; half of it seeds the next slice's meter.
    std::chrono::microseconds max_chain_item{0};

    /** Forget the pass in progress, keep the options. */
    void Reset()
    {
        LifecyclePass fresh;
        fresh.min_depth = min_depth;
        fresh.avoid_reuse = avoid_reuse;
        fresh.warmup_threshold = warmup_threshold;
        fresh.known = known;
        fresh.force_demurrage = force_demurrage;
        fresh.max_chain_item = max_chain_item;
        *this = std::move(fresh);
    }
};

/** Run one slice of a pass. Takes cs_main or cs_wallet itself (try-lock) and
 * never both. On DONE, pass.balance, pass.summary, pass.tip, pass.marker and
 * pass.have_watch_only are the result; the caller resets the pass before it
 * starts the next one. Any other terminal result resets the pass here. May
 * throw what the wallet accounting throws (an amount out of range); the pass
 * is reset first. */
LifecycleSliceReport RunLifecyclePassSlice(const CWallet& wallet, LifecyclePass& pass,
                                           LifecycleMemoJournal& journal,
                                           LifecycleAttestationCache& attestations,
                                           const LifecycleSliceLimits& limits = {})
    EXCLUSIVE_LOCKS_REQUIRED(!::cs_main, !wallet.cs_wallet);

/** Run a pass to its end on the calling thread, slice after slice, restarting
 * as often as `max_restarts` allows. For tests and for callers that are
 * allowed to wait. Returns the last report (DONE on success). */
LifecycleSliceReport RunLifecyclePassToEnd(const CWallet& wallet, LifecyclePass& pass,
                                           LifecycleMemoJournal& journal,
                                           LifecycleAttestationCache& attestations,
                                           const LifecycleSliceLimits& limits = LifecycleSliceLimits::Unlimited(),
                                           int max_restarts = 0)
    EXCLUSIVE_LOCKS_REQUIRED(!::cs_main, !wallet.cs_wallet);

/** One deep wallet output waiting for its chainstate facts. */
struct LifecycleWarmupItem {
    COutPoint outpoint;
    CTxOut txout;
    uint256 confirmed_block_hash;
    int confirmed_block_height{0};
    uint64_t txout_digest{0};
    //! See LifecyclePassOutput::derivable.
    bool derivable{false};
    bool tx_coinstake{false};
    int32_t tx_version{0};
    uint32_t tx_ntime{0};
};

/** Resumable memo warm-up: COLLECT (cs_wallet) lists every deep output
 * without a memo entry, in as many slices as the walk of mapWallet takes;
 * FETCH (cs_main) resolves all of them through one ChainReadPlan, so that the
 * coins database is read in ascending key order across the whole wallet and
 * not once per batch; STORE (cs_wallet) applies the journal. A tip move does
 * not discard what was read: the facts of an output this deep do not depend
 * on the tip, and every journal entry is checked against the wallet when it
 * is applied. (A warm-up that started over at every block would never end
 * on a disk that needs longer than a block interval for it.) */
struct LifecycleWarmup {
    enum class Stage { COLLECT, FETCH, STORE, DONE };
    Stage stage{Stage::COLLECT};
    size_t bucket{0};
    size_t bucket_count{0};
    bool walk_finished{false};
    //! Costliest chainstate item of the latest slice; half of it seeds the next slice's meter.
    std::chrono::microseconds max_chain_item{0};
    std::vector<LifecycleWarmupItem> items;
    ChainReadPlan fetch_plan;
    uint64_t collected{0}; //!< outputs listed so far
    uint64_t fetched{0};   //!< outputs whose facts were read or derived
    uint64_t derived{0};   //!< of those, outputs whose facts needed no database read
    uint64_t skipped{0};   //!< outputs the chainstate could not describe (left to the pass)
    uint64_t rewinds{0};   //!< times the cursor went back to the start (mapWallet was rehashed)
    uint32_t slices{0};

    //! Outputs listed and not yet stored, plus the share of mapWallet walked.
    size_t Waiting(const LifecycleMemoJournal& journal) const
    {
        const size_t resolved = fetch_plan.Active() ? fetch_plan.Count() - fetch_plan.Unresolved() : 0;
        return (items.size() - std::min(items.size(), resolved)) + journal.Waiting();
    }
    int WalkedPercent() const
    {
        if (walk_finished || stage == Stage::DONE) return 100;
        return bucket_count == 0 ? 0 : static_cast<int>(bucket * 100 / bucket_count);
    }
};

/** Run one slice of the warm-up. Never both locks. MORE, DONE or LOCK_BUSY. */
LifecycleSliceReport RunLifecycleWarmupSlice(const CWallet& wallet, LifecycleWarmup& warmup,
                                             LifecycleMemoJournal& journal,
                                             const LifecycleSliceLimits& limits = {})
    EXCLUSIVE_LOCKS_REQUIRED(!::cs_main, !wallet.cs_wallet);

/** Whether this wallet can satisfy a legacy input with a scriptSig-committed
 * ECDSA/ForkID signature, giving the transaction a txid that cannot be shared
 * with the legacy fork. Native and wrapped witness-only scripts return false. */
bool IsWalletTxidCommittedMigrationAnchor(const CWallet& wallet, const CScript& script_pub_key);
/** Whether an output belongs to the optional coin-control source family. */
bool MatchesCoinControlInputFamily(
    const CScript& script_pub_key, const CCoinControl& coin_control);
bool IsWalletProtectedLineageInput(const CWallet& wallet, const COutPoint& outpoint,
                                   const Coin& coin, const Consensus::Params& consensus,
                                   int64_t spend_time, int spend_height);
/** True only for an authenticated synthetic payout that is consensus-mature
 * in the candidate next block, even when its coinbase-shaped wallet
 * transaction reports one display block remaining. */
bool IsNextBlockMatureGoldRushPayout(const CWallet& wallet, const COutPoint& outpoint,
                                     int spend_height, int64_t spend_time);

/** Get the marginal bytes if spending the specified output from this transaction.
 * Use CoinControl to determine whether to expect signature grinding when calculating the size of the input spend. */
int CalculateMaximumSignedInputSize(const CTxOut& txout, const CWallet* pwallet, const CCoinControl* coin_control);
int CalculateMaximumSignedInputSize(const CTxOut& txout, const COutPoint outpoint, const SigningProvider* pwallet, bool can_grind_r, const CCoinControl* coin_control);
struct TxSize {
    int64_t vsize{-1};
    int64_t weight{-1};
};

/** Calculate the size of the transaction using CoinControl to determine
 * whether to expect signature grinding when calculating the size of the input spend. */
TxSize CalculateMaximumSignedTxSize(const CTransaction& tx, const CWallet* wallet, const std::vector<CTxOut>& txouts, const CCoinControl* coin_control = nullptr);
TxSize CalculateMaximumSignedTxSize(const CTransaction& tx, const CWallet* wallet, const CCoinControl* coin_control = nullptr) EXCLUSIVE_LOCKS_REQUIRED(wallet->cs_wallet);

/**
 * COutputs available for spending, stored by OutputType.
 * This struct is really just a wrapper around OutputType vectors with a convenient
 * method for concatenating and returning all COutputs as one vector.
 *
 * Size(), Clear(), Erase(), Shuffle(), and Add() methods are implemented to
 * allow easy interaction with the struct.
 */
struct CoinsResult {
    std::map<OutputType, std::vector<COutput>> coins;
    //! True when CoinFilterParams::interrupt stopped the walk; the result is partial.
    bool interrupted{false};

    /** Concatenate and return all COutputs as one vector */
    std::vector<COutput> All() const;

    /** The following methods are provided so that CoinsResult can mimic a vector,
     * i.e., methods can work with individual OutputType vectors or on the entire object */
    size_t Size() const;
    /** Return how many different output types this struct stores */
    size_t TypesCount() const { return coins.size(); }
    void Clear();
    void Erase(const std::unordered_set<COutPoint, SaltedOutpointHasher>& coins_to_remove);
    void Shuffle(FastRandomContext& rng_fast);
    void Add(OutputType type, const COutput& out);

    CAmount GetTotalAmount() { return total_amount; }
    std::optional<CAmount> GetEffectiveTotalAmount() {return total_effective_amount; }

private:
    /** Sum of all available coins raw value */
    CAmount total_amount{0};
    /** Sum of all available coins effective value (each output value minus fees required to spend it) */
    std::optional<CAmount> total_effective_amount{0};
};

struct CoinFilterParams {
    // Outputs below the minimum amount will not get selected
    CAmount min_amount{1};
    // Outputs above the maximum amount will not get selected
    CAmount max_amount{MAX_MONEY};
    // Return outputs until the minimum sum amount is covered
    CAmount min_sum_amount{MAX_MONEY};
    // Maximum number of outputs that can be returned
    uint64_t max_count{0};
    // By default, return only spendable outputs
    bool only_spendable{true};
    // By default, do not include immature coinbase outputs
    bool include_immature_coinbase{false};
    // By default, skip locked UTXOs
    bool skip_locked{true};
    // Ordinary wallet funding must not consume Gold Rush rewards while v16
    // spends are locked. The phase-aware filter stops excluding them at G+1.
    bool include_generated_quantum_inputs{false};
    // Bonded and still-unbonding tiered quantum outputs require the guided
    // unbond/withdraw paths. Ordinary sends and staking skip them by default.
    bool include_locked_quantum_stake_outputs{false};
    // Fully decayed demurrage outputs are consensus-locked. Listing views opt in
    // so users can diagnose them, but ordinary funding skips them.
    bool include_demurrage_locked_outputs{false};
    // Optional cooperative cancellation for long read-only listings. Checked
    // every INTERRUPT_CHECK_INTERVAL transaction/output visits; when true
    // the walk stops early and CoinsResult::interrupted is set. Funding paths
    // leave it empty.
    std::function<bool()> interrupt;
    static constexpr size_t INTERRUPT_CHECK_INTERVAL{64};
};

/**
 * Populate the CoinsResult struct with vectors of available COutputs, organized by OutputType.
 */
CoinsResult AvailableCoins(const CWallet& wallet,
                           const CCoinControl* coinControl = nullptr,
                           std::optional<CFeeRate> feerate = std::nullopt,
                           const CoinFilterParams& params = {}) EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

/**
 * Wrapper function for AvailableCoins which skips the `feerate` and `CoinFilterParams::only_spendable` parameters. Use this function
 * to list all available coins (e.g. listunspent RPC) while not intending to fund a transaction.
 */
CoinsResult AvailableCoinsListUnspent(const CWallet& wallet, const CCoinControl* coinControl = nullptr, CoinFilterParams params = {}) EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

/**
 * Find non-change parent output.
 */
const CTxOut& FindNonChangeParentOutput(const CWallet& wallet, const COutPoint& outpoint) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);

/**
 * Return list of available coins and locked coins grouped by non-change output address.
 */
std::map<CTxDestination, std::vector<COutput>> ListCoins(const CWallet& wallet)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

/**
 * Interruptible ListCoins. Returns std::nullopt if interrupt() returned true
 * before the walk finished; otherwise the same result as ListCoins(wallet).
 */
std::optional<std::map<CTxDestination, std::vector<COutput>>> ListCoins(const CWallet& wallet, const std::function<bool()>& interrupt)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

struct SelectionFilter {
    CoinEligibilityFilter filter;
    bool allow_mixed_output_types{true};
};

/**
* Group coins by the provided filters.
*/
FilteredOutputGroups GroupOutputs(const CWallet& wallet,
                          const CoinsResult& coins,
                          const CoinSelectionParams& coin_sel_params,
                          const std::vector<SelectionFilter>& filters);

/**
 * Attempt to find a valid input set that preserves privacy by not mixing OutputTypes.
 * `ChooseSelectionResult()` will be called on each OutputType individually and the best
 * the solution (according to the waste metric) will be chosen. If a valid input cannot be found from any
 * single OutputType, fallback to running `ChooseSelectionResult()` over all available coins.
 *
 * param@[in]  chain                     The chain interface to get information on unconfirmed UTXOs bump fees
 * param@[in]  nTargetValue              The target value
 * param@[in]  groups                    The grouped outputs mapped by coin eligibility filters
 * param@[in]  coin_selection_params     Parameters for the coin selection
 * param@[in]  allow_mixed_output_types  Relax restriction that SelectionResults must be of the same OutputType
 * returns                               If successful, a SelectionResult containing the input set
 *                                       If failed, returns (1) an empty error message if the target was not reached (general "Insufficient funds")
 *                                                  or (2) an specific error message if there was something particularly wrong (e.g. a selection
 *                                                  result that surpassed the tx max weight size).
 */
util::Result<SelectionResult> AttemptSelection(interfaces::Chain& chain, const CAmount& nTargetValue, OutputGroupTypeMap& groups,
                        const CoinSelectionParams& coin_selection_params, bool allow_mixed_output_types);

/**
 * Attempt to find a valid input set that meets the provided eligibility filter and target.
 * Multiple coin selection algorithms will be run and the input set that produces the least waste
 * (according to the waste metric) will be chosen.
 *
 * param@[in]  chain                     The chain interface to get information on unconfirmed UTXOs bump fees
 * param@[in]  nTargetValue              The target value
 * param@[in]  groups                    The struct containing the outputs grouped by script and divided by (1) positive only outputs and (2) all outputs (positive + negative).
 * param@[in]  coin_selection_params     Parameters for the coin selection
 * returns                               If successful, a SelectionResult containing the input set
 *                                       If failed, returns (1) an empty error message if the target was not reached (general "Insufficient funds")
 *                                                  or (2) an specific error message if there was something particularly wrong (e.g. a selection
 *                                                  result that surpassed the tx max weight size).
 */
util::Result<SelectionResult> ChooseSelectionResult(interfaces::Chain& chain, const CAmount& nTargetValue, Groups& groups, const CoinSelectionParams& coin_selection_params);

// User manually selected inputs that must be part of the transaction
struct PreSelectedInputs
{
    std::set<std::shared_ptr<COutput>> coins;
    // If subtract fee from outputs is disabled, the 'total_amount'
    // will be the sum of each output effective value
    // instead of the sum of the outputs amount
    CAmount total_amount{0};

    void Insert(const COutput& output, bool subtract_fee_outputs)
    {
        if (subtract_fee_outputs) {
            total_amount += output.txout.nValue;
        } else {
            total_amount += output.GetEffectiveValue();
        }
        coins.insert(std::make_shared<COutput>(output));
    }
};

/**
 * Fetch and validate coin control selected inputs.
 * Coins could be internal (from the wallet) or external.
*/
util::Result<PreSelectedInputs> FetchSelectedInputs(const CWallet& wallet, const CCoinControl& coin_control,
                                                    const CoinSelectionParams& coin_selection_params) EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

/**
 * Select a set of coins such that nTargetValue is met; never select unconfirmed coins if they are not ours
 * param@[in]   wallet                 The wallet which provides data necessary to spend the selected coins
 * param@[in]   available_coins        The struct of coins, organized by OutputType, available for selection prior to filtering
 * param@[in]   nTargetValue           The target value
 * param@[in]   coin_selection_params  Parameters for this coin selection such as feerates, whether to avoid partial spends,
 *                                     and whether to subtract the fee from the outputs.
 * returns                             If successful, a SelectionResult containing the selected coins
 *                                     If failed, returns (1) an empty error message if the target was not reached (general "Insufficient funds")
 *                                                or (2) an specific error message if there was something particularly wrong (e.g. a selection
 *                                                result that surpassed the tx max weight size).
 */
util::Result<SelectionResult> AutomaticCoinSelection(const CWallet& wallet, CoinsResult& available_coins, const CAmount& nTargetValue,
                 const CoinSelectionParams& coin_selection_params) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);

/**
 * Select all coins from coin_control, and if coin_control 'm_allow_other_inputs=true', call 'AutomaticCoinSelection' to
 * select a set of coins such that nTargetValue - pre_set_inputs.total_amount is met.
 */
util::Result<SelectionResult> SelectCoins(const CWallet& wallet, CoinsResult& available_coins, const PreSelectedInputs& pre_set_inputs,
                                          const CAmount& nTargetValue, const CCoinControl& coin_control,
                                          const CoinSelectionParams& coin_selection_params) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);

struct CreatedTransactionResult
{
    CTransactionRef tx;
    CAmount fee;
    int change_pos;
    //! Non-HD ML-DSA key durably created while preparing this transaction,
    //! even when coin selection ultimately did not materialize change.
    std::optional<CTxDestination> created_quantum_change;

    CreatedTransactionResult(
        CTransactionRef _tx,
        CAmount _fee,
        int _change_pos,
        std::optional<CTxDestination> _created_quantum_change = std::nullopt)
        : tx(_tx), fee(_fee), change_pos(_change_pos), created_quantum_change(std::move(_created_quantum_change)) {}
};

/**
 * Create a new transaction paying the recipients with a set of coins
 * selected by SelectCoins(); Also create the change output, when needed
 * @note passing change_pos as -1 will result in setting a random position
 */
util::Result<CreatedTransactionResult> CreateTransaction(CWallet& wallet, const std::vector<CRecipient>& vecSend, int change_pos, const CCoinControl& coin_control, bool sign = true);

/**
 * Create a transaction rebuilding spendable coins into equal-value UTXOs
 * paying dest, to maximize PoS yield under continuous minting. Resets the
 * accumulated coinage of the spent coins. When from_address is given, only
 * coins currently held by that address are split; otherwise all trusted
 * spendable coins are used. The transaction is not committed to the wallet.
 */
util::Result<CreatedTransactionResult> CreateUTXOOptimizationTransaction(CWallet& wallet, const CTxDestination& dest, CAmount utxo_amount, const std::optional<CTxDestination>& from_address);

/**
 * Insert additional inputs into the transaction by
 * calling CreateTransaction();
 */
bool FundTransaction(
    CWallet& wallet,
    CMutableTransaction& tx,
    CAmount& nFeeRet,
    int& nChangePosInOut,
    bilingual_str& error,
    bool lockUnspents,
    const std::set<int>& setSubtractFeeFromOutputs,
    CCoinControl,
    std::optional<CTxDestination>* created_quantum_change = nullptr);
} // namespace wallet

#endif // BITCOIN_WALLET_SPEND_H
