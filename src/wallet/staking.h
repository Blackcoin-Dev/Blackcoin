// Copyright (c) 2014-2023 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

// Staking start/stop algos by Qtum
// Copyright (c) 2016-2023 The Qtum developers

#ifndef BITCOIN_WALLET_STAKING_H
#define BITCOIN_WALLET_STAKING_H

#include <pos.h>
#include <wallet/spend.h>
#include <wallet/wallet.h>

#include <atomic>
#include <chrono>
#include <map>
#include <set>

namespace wallet {
struct BoundedLegacyStakeCandidate
{
    COutPoint outpoint;
    CAmount value{0};
};

struct BoundedLegacyStakeSource
{
    COutPoint outpoint;
    const CWalletTx* wallet_tx{nullptr};
};

struct BoundedLegacyStakeCandidates
{
    std::vector<BoundedLegacyStakeCandidate> candidates;
    bool capacity_exceeded{false};
};

/* Start staking */
void StartStake(CWallet& wallet);

/* Stop staking */
void StopStake(CWallet& wallet);

uint64_t GetStakeWeight(const CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);
void AvailableCoinsForStaking(const CWallet& wallet,
                           std::vector<std::pair<const CWalletTx*, unsigned int> >& vCoins,
                           const CCoinControl* coinControl = nullptr,
                           const CoinFilterParams& params = {}) EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);
/** The pre-index-narrowing scan (full live index, original predicate order).
 * Only for tests and benchmarks proving AvailableCoinsForStaking selects the same set. */
void AvailableCoinsForStakingReference(const CWallet& wallet,
                           std::vector<std::pair<const CWalletTx*, unsigned int> >& vCoins,
                           const CCoinControl* coinControl = nullptr,
                           const CoinFilterParams& params = {}) EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);
/** Evaluate the same authoritative per-output staking predicate for legacy
 * candidates at an already captured Gold Rush chain tuple. The phase
 * precondition is checked by the implementation before walking the bounded
 * wallet index, and no chain view is consulted by the legacy predicate. */
BoundedLegacyStakeCandidates GetBoundedLegacyStakeCandidates(
    const CWallet& wallet,
    const std::vector<BoundedLegacyStakeSource>& sources,
    const std::set<COutPoint>& protected_rgb_seals,
    int active_height, int64_t median_time_past,
    const CCoinControl* coin_control = nullptr,
    const CoinFilterParams& params = {})
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
    LOCKS_EXCLUDED(::cs_main);
bool SelectCoinsForStaking(const CWallet& wallet, CAmount& nTargetValue, std::set<std::pair<const CWalletTx *, unsigned int> > &setCoinsRet, CAmount& nValueRet)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

/**
 * What one tip's staking slots share. The staker searches every slot of a tip
 * over the same wallet and the same chain, so the selected candidates and the
 * per-output kernel inputs (the creating block's time, the value, the script)
 * are computed once per (tip, wallet generation) and reused; a slot then costs
 * one kernel hash per candidate and no coins-view fetch.
 *
 * Validity key: the tip hash (it fixes the height, the median time past, every
 * phase rule, the coin set and every depth), the live-unspent index generation,
 * the wallet's balance scan marker (every mapWallet, spend-map, key, script and
 * flag change), the coin-lock generation, the lock and staking-only unlock
 * state, and the set of RGB-protected seals. A cache older than
 * STAKE_SLOT_CACHE_MAX_AGE is rebuilt regardless, as a bound on any wallet
 * change that does not advance one of the counters.
 *
 * The cache only ever decides "no kernel here". A kernel it reports is
 * confirmed through the uncached CheckKernel and through a fresh uncached
 * candidate selection before it is used (see CheckStakeSlotKernel).
 */
struct StakeSlotCache
{
    uint256 tip_hash;
    uint64_t live_generation{0};
    uint64_t balance_marker{0};
    uint64_t coin_lock_generation{0};
    bool wallet_locked{false};
    bool staking_only{false};
    std::set<COutPoint> protected_rgb_seals;
    std::chrono::steady_clock::time_point built_at;
    //! Output of SelectCoinsForStaking (nTargetValue = MAX_MONEY), same order.
    std::set<std::pair<const CWalletTx*, unsigned int>> coins;
    CAmount value_in{0};
    //! Kernel inputs per candidate; empty when the phase needs the coin view
    //! per call (demurrage) or caching is off. CheckKernel falls back to the
    //! uncached path for an outpoint that is not in it.
    std::map<COutPoint, CStakeCache> kernels;
};

struct StakeSlotCacheStats
{
    uint64_t hits{0};       //! slots served from the cache
    uint64_t rebuilds{0};   //! cache built (cold, tip change, generation change, age)
    uint64_t rejections{0}; //! cached kernel refused by the uncached confirmation
};

struct StakeSlotCacheState
{
    std::shared_ptr<StakeSlotCache> cache;
    StakeSlotCacheStats stats;
};

//! Longest a cache is served without a rebuild.
static constexpr std::chrono::seconds STAKE_SLOT_CACHE_MAX_AGE{120};

//! Test hook and operator escape: false makes every slot select and check
//! exactly as before the cache existed. Default true.
extern std::atomic<bool> g_stake_slot_cache_enabled;

/** The selection and kernel inputs for the slot at `tip`; served from the
 * wallet's cache when it is valid, otherwise built (and kept, unless caching is
 * off). Never returns null. */
std::shared_ptr<const StakeSlotCache> AcquireStakeSlotCache(const CWallet& wallet, CBlockIndex* tip)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);
/** Drop the wallet's cache (the next slot rebuilds it). */
void DropStakeSlotCache(const CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);

enum class StakeSlotKernel {
    NONE,           //! no kernel for this output at this time
    FOUND,          //! a kernel, confirmed without the cache
    CACHE_REJECTED, //! the cache said kernel, the uncached path disagreed: cache dropped
};
StakeSlotKernel CheckStakeSlotKernel(const CWallet& wallet, const StakeSlotCache& slot, CBlockIndex* tip,
                                     unsigned int nBits, uint32_t nTime, const COutPoint& prevout)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

struct StakeKernelHit
{
    COutPoint prevout;
    uint32_t time{0};
};
/** Every candidate and time CreateCoinStake would test for a kernel, in its
 * order, with the same checks. Used by tests to compare the cached search with
 * the uncached one; stops at the first CACHE_REJECTED (reported through
 * `rejected`). */
std::vector<StakeKernelHit> ScanStakeKernels(const CWallet& wallet, unsigned int nBits, uint32_t nTime,
                                             int64_t nSearchInterval, bool use_cache, bool* rejected = nullptr)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);
bool CreateCoinStake(CWallet& wallet, unsigned int nBits, int64_t nSearchInterval,
                     CMutableTransaction& tx, CAmount& nFees,
                     CTxDestination destination,
                     const std::vector<CTransactionRef>& selected_txs = {},
                     std::optional<COutPoint> forced_kernel = std::nullopt);

struct DemurrageAttestationTxResult
{
    CTransactionRef tx;
    std::vector<unsigned char> public_key;
    std::vector<unsigned char> witness_program;
    COutPoint replay_anchor;
    COutPoint target_outpoint;
    int attestation_vout{-1};
    CAmount fee{0};
};

struct QuantumColdStakeRedelegationOptions
{
    bool dry_run{true};
    //! Required for a broadcast redelegation because it creates a new
    //! non-HD ML-DSA owner key. Dry runs never create wallet metadata.
    bool allow_new_quantum_key{false};
    bool enforce_pool_cap{true};
    bool require_verified_operator{true};
    std::optional<CFeeRate> fee_rate;
    std::string label{"redelegated-coldstake"};
};

struct QuantumColdStakeRedelegationResult
{
    bool dry_run{true};
    CTxDestination source_dest;
    CTxDestination target_dest;
    bool target_wallet_backed{false};
    CAmount input_amount{0};
    CAmount output_amount{0};
    CAmount fee{0};
    int vsize{0};
    bool operator_commitment_verified{false};
    CAmount post_total_coldstake{0};
    CAmount post_operator_value{0};
    int64_t post_share_bps{0};
    bool would_exceed_cap{false};
    bool cap_enforced{true};
    bool cap_filter_unlocked{false};
    CTransactionRef tx;
};

/** Fixed cap on exact chainstate marker reads in latency-sensitive wallet paths. */
static constexpr size_t MAX_WALLET_SHADOW_SOLVE_REFERENCES{256};

/**
 * Per-attempt work budgets for automatic QQSIGNAL fee-input discovery.
 * The cursor stored in CWallet resumes after the last inspected output, so a
 * large historical wallet is covered over bounded retries without a stop-the-
 * world AvailableCoins pass.
 */
static constexpr size_t MAX_AUTO_SHADOW_SIGNAL_WALLET_TX_SCAN{4096};
static constexpr size_t MAX_AUTO_SHADOW_SIGNAL_WALLET_OUTPUT_SCAN{65536};

/**
 * Return the newest confirmed wallet-owned coinstake solve per canonical
 * script. The wallet scan is in-memory; callers validate at most the fixed cap
 * above through HasRecentShadowSolverActivity while holding cs_main.
 */
std::vector<WalletShadowSolveReference> GetWalletShadowSolveReferences(
    const CWallet& wallet, int tip_height) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);

bool CreateDemurrageAttestationTransaction(
    CWallet& wallet,
    const std::vector<unsigned char>& witness_program,
    const CCoinControl& coin_control,
    bool sign,
    DemurrageAttestationTxResult& result,
    bilingual_str& error);

bool CreateQuantumColdStakeRedelegationTransaction(
    CWallet& wallet,
    const CTxDestination& source_dest,
    const std::vector<unsigned char>& target_staking_pubkey,
    const QuantumColdStakeRedelegationOptions& options,
    QuantumColdStakeRedelegationResult& result,
    bilingual_str& error);

int MaybeAutoDemurrageAttest(CWallet& wallet);
int MaybeAutoShadowSignal(CWallet& wallet);
int MaybeAutoRedelegateQuantumColdStake(CWallet& wallet);

} // namespace wallet

#endif // BITCOIN_WALLET_STAKING_H
