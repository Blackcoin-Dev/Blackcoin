// Copyright (c) 2014-2023 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

// Staking start/stop algos by Qtum
// Copyright (c) 2016-2023 The Qtum developers

#ifndef BITCOIN_WALLET_STAKING_H
#define BITCOIN_WALLET_STAKING_H

#include <consensus/demurrage.h>
#include <pos.h>
#include <wallet/spend.h>
#include <wallet/wallet.h>

#include <atomic>
#include <chrono>
#include <functional>
#include <map>
#include <optional>
#include <set>

namespace wallet {
/**
 * Wallet policy only; no block or transaction is judged by it. A legacy
 * coinstake created at height h can be spent from h + maturity, and Final
 * rejects every legacy input, so a legacy-return coinstake with
 * h + maturity > M (M = last Migration block) would lose its principal and
 * reward for good. From the first such height (the "quantum return window")
 * a legacy kernel therefore pays its principal and reward to a quantum output
 * this wallet owns instead; the same rules every released node already runs
 * accept that (the reward split that would fix the return script starts at
 * Final). The margin keeps the last legacy-return coinstake one full block of
 * migration time before M.
 */
static constexpr int LEGACY_STAKE_MIGRATION_MARGIN_BLOCKS = 1;

/** Last height at which this wallet still creates a legacy-return
 *  coinstake, or nullopt when the Migration end height is not known (no
 *  complete height-authoritative schedule). 64-bit arithmetic throughout. */
std::optional<int64_t> LastLegacyStakeHeight(const Consensus::Params& consensus);

/** True when stake_height lies in the quantum return window: a legacy-return
 *  coinstake created there would not be spendable before Final, so a legacy
 *  kernel must pay a quantum output (or not stake). Same condition for
 *  candidate filtering, status weight and the check inside CreateCoinStake. */
bool IsLegacyStakeBarredByMigrationEnd(const Consensus::Params& consensus, int stake_height);

/** Blocks from evaluation_height until an output's value is first reduced by
 *  demurrage, for status display. Before activation the distance to the activation
 *  height is added to the curve's own count.
 *
 *  Two different things set DemurrageEvaluation::exempt and must not be confused. A PERMANENT
 *  exemption belongs to the script (a treasury script, or one demurrage never applies to): there is
 *  no first reduction, so nullopt. It is read from the script, not from the evaluation, because
 *  EvaluateDemurrage reports only "inactive" before activation. A TEMPORARY exemption (grace for a
 *  young output, protection by an attestation) ends: the countdown runs from the evaluation's own
 *  inactive blocks. Also nullopt: a locked output (already past it) and an activation that is not
 *  given by a height. The curve helper itself (Consensus::DemurrageBlocksUntilFirstReduction) is
 *  unchanged. */
std::optional<int64_t> DemurrageFirstReductionCountdown(const Consensus::Params& consensus,
                                                        const CScript& script_pub_key,
                                                        const Consensus::DemurrageEvaluation& eval,
                                                        int evaluation_height, int64_t evaluation_time);

/** Where this wallet stands on the quantum return of legacy stakes. */
struct LegacyStakeQuantumReturn
{
    bool available{false};
    CScript script;
    std::string address; // the persisted address, when it is set and usable
    std::string reason;  // what the user must do, when !available
    //! Whether a reopen-and-sign backup verification (backupwallet) was recorded
    //! after this address's key was created. While false, a wallet backup made
    //! before the key existed cannot recover coins paid to it.
    bool backup_verified{false};
};

/** The independent guard CreateCoinStake runs on a legacy kernel in the quantum return window: empty when the
 *  coinstake is acceptable, else why it is refused. The coinstake must have been built to return to the quantum
 *  address, a ready return address must exist, and apart from the value-0 outputs (the marker and the legacy
 *  block-signing key) it has exactly one output of value, paying exactly that return script. A pure function of
 *  the transaction, so tests can feed it malformed shapes the constructor never makes. */
std::string LegacyReturnWindowCoinstakeProblem(const CMutableTransaction& coinstake, bool returns_to_quantum,
                                               const LegacyStakeQuantumReturn& legacy_return);

/** What to tell the user when a quantum stake return key is not yet in a verified backup. */
std::string QuantumStakeReturnBackupAction();

/** Plain-language notice for status output: the height from which legacy
 *  stakes are paid to a quantum address, which address, whether the wallet is
 *  ready, what to do if not, and that legacy coins that do not stake must be
 *  migrated before Final. Empty when no height-authoritative schedule is
 *  configured or when next_height is already in Final. */
std::string LegacyStakingNotice(const Consensus::Params& consensus, int next_height,
                                const LegacyStakeQuantumReturn& quantum_return);

/** Pure choice among wallet-owned quantum addresses, for the automatic
 *  setting of the return address: the explicitly configured address first (the
 *  caller passes it as configured), then the address labelled as the PoS
 *  quantum stake address, then the oldest ordinary direct quantum receive
 *  address. Candidates must be wallet-backed with a durably stored key. */
struct QuantumReturnCandidate
{
    CTxDestination destination;
    std::string label;
    bool is_change{false};
    int64_t creation_time{0};
};
std::optional<CTxDestination> ChooseLegacyStakeQuantumReturn(const std::vector<QuantumReturnCandidate>& candidates);

/** The persisted quantum stake return address, checked: wallet-owned ordinary
 *  direct quantum address with a durably stored key. Read-only, never creates a
 *  key, so it is safe on the staking path and under a staking-only unlock. */
LegacyStakeQuantumReturn ResolveLegacyStakeQuantumReturn(const CWallet& wallet)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);

/** Persist dest as the quantum stake return address (record "quantumstakereturn";
 *  older versions skip it). The address must pass the same checks as above. */
bool SetQuantumStakeReturn(CWallet& wallet, const CTxDestination& dest, bilingual_str& error);

/** What an automatic preparation of the quantum stake return address did. */
struct QuantumStakeReturnPreparation
{
    enum class Outcome {
        NO_ACTION,       //!< nothing to do or not allowed now (no schedule, locked, staking-only, past the window, already set)
        REUSED_ADDRESS,  //!< an address the wallet already had was chosen and saved
        CREATED_ADDRESS, //!< a new quantum key was created and its address saved
        FAILED,          //!< an attempt was made and did not complete
    };
    Outcome outcome{Outcome::NO_ACTION};
    //! The address saved (REUSED_ADDRESS, CREATED_ADDRESS) or the one already saved (NO_ACTION because it was set).
    std::string address;
    //! A new quantum key was generated and persisted by this call, whatever happened afterwards (a FAILED
    //! preparation can still leave a key behind that needs a backup).
    bool key_created{false};
    //! Why NO_ACTION or FAILED, when known.
    std::string detail;
    bool Saved() const { return outcome == Outcome::REUSED_ADDRESS || outcome == Outcome::CREATED_ADDRESS; }
};

/** Who asks for the preparation. An explicit request (the setquantumstakereturn RPC) is allowed at any time. The
 *  automatic one (the wallet's own maintenance) is held to the phase where it matters: it only acts once Gold Rush
 *  has ended (the next block is above the Gold Rush end height) and only for a wallet that holds legacy coins the
 *  staker could stake, so that a chain still in Gold Rush, or a wallet with nothing to return, sees no new key,
 *  no saved record and no backup prompt appear by themselves. */
enum class QuantumStakeReturnTrigger {
    EXPLICIT,
    AUTOMATIC,
};

/** When the wallet is fully unlocked (or unencrypted), has no valid return
 *  address and a height schedule exists: set one. An existing wallet-owned
 *  quantum address is reused (-qqpospayoutaddress first); a key is created only
 *  when the existing policy allows it (-qqallowautokeycreation). Never creates
 *  a key otherwise. Call outside cs_main and cs_wallet. The result tells reuse,
 *  creation, no action and failure apart. */
QuantumStakeReturnPreparation PrepareQuantumStakeReturn(CWallet& wallet, QuantumStakeReturnTrigger trigger);
/** PrepareQuantumStakeReturn(wallet, AUTOMATIC).Saved(). */
bool MaybeAutoSetQuantumStakeReturn(CWallet& wallet);

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

/** Why the staker does not select an output (the first failing test). */
enum class StakeExclusion {
    NONE,                //! not excluded
    IMMATURE,            //! unconfirmed, or too young to be a kernel at that block
    LOCKED,              //! coin-locked, a locked Gold Rush payout, or locked by demurrage
    BELOW_MINIMUM,       //! under the staking minimum (the wallet's or the scan's)
    SIGNER_UNAVAILABLE,  //! the wallet holds no signing key for it
    OTHER,               //! any other staking rule (phase, kernel type, reuse, protected state)
};
const char* StakeExclusionName(StakeExclusion reason);

/** Called for every candidate the staker's scan evaluates: whether it would be
 *  selected, and if not, why. */
using StakeScanObserver = std::function<void(const COutPoint& outpoint, const CWalletTx& wtx, bool eligible, StakeExclusion reason)>;

/** The staker's own candidate scan (AvailableCoinsForStaking) evaluated for the block
 *  `blocks_ahead` blocks after the next one, with every candidate reported to
 *  `observer`. blocks_ahead 0 is exactly what the staker selects now. */
void AvailableCoinsForStakingAhead(const CWallet& wallet,
                           std::vector<std::pair<const CWalletTx*, unsigned int> >& vCoins,
                           const CCoinControl* coinControl,
                           const CoinFilterParams& params,
                           int blocks_ahead,
                           const StakeScanObserver& observer) EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

struct StakeExclusionTally
{
    int64_t count{0};
    CAmount value{0};
};

/** Quantum stake as the staker sees it for one block.
 *
 * Nominal value is the output's face value, which is what the staker's reserve rule counts; effective
 * value is the kernel principal the coinstake constructor uses (after any scheduled demurrage). The
 * reserve balance is held back from the staker's whole selected set, legacy outputs included, and a
 * kernel is one output, so an output stakes only when its effective principal fits in the balance that
 * is left (candidate_total less the reserve): there is no partial kernel. */
struct StakeHorizonReadiness
{
    int height{0};                  //! the block this describes
    int64_t eligible_outputs{0};    //! quantum outputs the staker selects
    CAmount eligible_nominal{0};    //! their face value
    CAmount eligible_effective{0};  //! the kernel principal they would give (after demurrage)
    CAmount candidate_total{0};     //! face value of everything the staker selects, legacy included (the figure the reserve comes off)
    CAmount allowed_balance{0};     //! candidate_total less the reserve balance, 0 when it does not exceed it: the most one coinstake may use
    int64_t stakeable_outputs{0};   //! eligible outputs whose effective principal fits in allowed_balance
    CAmount stakeable_effective{0}; //! their effective principal
    CAmount largest_kernel{0};      //! the largest single effective principal that fits (0 when none)
    std::map<StakeExclusion, StakeExclusionTally> excluded; //! quantum outputs not selected, by reason
};

/** Operator view of quantum staking readiness for the next block and for the first Final block. */
struct QuantumStakeReadiness
{
    int next_height{0};
    bool final_height_known{false}; //! whether a complete height-authoritative schedule gives the first Final block
    int final_height{0};            //! first Final block (meaningful only when final_height_known)
    int64_t blocks_to_final{0};     //! 0 once Final has started (meaningful only when final_height_known)
    int64_t quantum_outputs{0};     //! quantum outputs the staker's scan considers (selected or not)
    CAmount quantum_total{0};
    StakeHorizonReadiness next_block;
    StakeHorizonReadiness at_final; //! same as next_block once Final has started (only when final_height_known)
    int64_t legacy_outputs{0};      //! legacy outputs still to migrate (spendable now or waiting)
    CAmount legacy_to_migrate{0};
    bool wallet_locked{false};      //! fully locked: no signer, the staker idles
    bool staking_only_unlock{false};
    CAmount reserve_balance{0};
    CAmount min_stake_amount{0};
    LegacyStakeQuantumReturn stake_return;
};
QuantumStakeReadiness AssessQuantumStakeReadiness(const CWallet& wallet)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

/* Start staking */
void StartStake(CWallet& wallet);

/* Stop staking */
void StopStake(CWallet& wallet);

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

/** True when `wtx` is a coinbase or coinstake that is not yet old enough to be a
 * kernel or an input of a block at `spend_height` (the tip height plus one).
 * Consensus accepts it when `spend_height - output height >= nCoinbaseMaturity`,
 * so a block `maturity` above it may already stake it. This is for staking
 * eligibility only: the wallet's balance and ordinary spending keep
 * CWallet::IsTxImmature. */
bool IsStakeSourceImmatureForNextBlock(const CWallet& wallet, const CWalletTx& wtx, int spend_height)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);

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

/** Whether the wallet owns, and can sign for, a live legacy output the staker could stake. */
bool WalletHoldsLegacyStakableCoin(const CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);

//! An attestation that a transaction of this wallet carries and that is neither confirmed nor abandoned.
struct PendingWalletAttestation
{
    uint256 key_hash;
    std::optional<int> previous_height;
    uint32_t previous_time{0};
    uint32_t previous_coverage_start_height{0};
    //! The block, transaction and output of the state the attestation references.
    std::optional<Consensus::DemurrageAttestationSource> previous_source;
    COutPoint target;
    uint256 txid;
    bool in_mempool{false};
    //! Created by the automatic path (its transactions carry the automatic attestation comment); only
    //! those may be abandoned automatically.
    bool automatic{false};
};

/** What the automatic path may do with a pending attestation of the wallet. */
enum class PendingAttestationUse {
    REUSABLE,                //! still usable and can be offered to the network again
    TEMPORARILY_UNAVAILABLE, //! still usable, but cannot be offered now (broadcasting is disabled): keep it
    UNUSABLE,                //! the referenced state, the target or an input is gone: it cannot confirm
};

std::vector<PendingWalletAttestation> PendingWalletDemurrageAttestations(const CWallet& wallet)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);

/** Whether the attestation references exactly this record (height, time, coverage, source block hash,
 *  source transaction and output), or no state at all when there is none. */
bool PendingAttestationReferencesRecord(const PendingWalletAttestation& entry,
                                        const std::optional<Consensus::DemurrageAttestationRecord>& record);

/** The first pending attestation for this key that references exactly the key's current record. */
const PendingWalletAttestation* FindPendingAttestationForState(const std::vector<PendingWalletAttestation>& pending,
                                                               const uint256& key_hash,
                                                               const std::optional<Consensus::DemurrageAttestationRecord>& record);

/** Reusable, temporarily unavailable, or no longer usable. A failed submission is never evidence of the
 *  last: the answer comes from the referenced state, the target and the inputs. */
PendingAttestationUse ClassifyPendingAttestation(const CWallet& wallet, const CCoinsViewCache& view,
                                                 const Consensus::Params& consensus, int evaluation_height,
                                                 int64_t evaluation_time, const PendingWalletAttestation& entry,
                                                 const std::optional<Consensus::DemurrageAttestationRecord>& record)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);
/** What the automatic path decides about one key from all of the wallet's pending attestations for it,
 *  computed once per scan. */
struct KeyPendingDecision {
    //! A usable attestation for the key's current state is already pending (in the mempool, offered again,
    //! or kept because it cannot be offered now): no new one is constructed.
    bool suppress_construction{false};
    //! The key's local attestation state (the marker coin in the chain state) is malformed, which is not the
    //! same as an authenticated absence of a record. Nothing is matched, resubmitted or abandoned: the pending
    //! transactions and their reservations are kept, construction is suppressed, and the caller reports it.
    bool local_state_invalid{false};
    //! The usable entry the log line names (null when none is usable).
    const PendingWalletAttestation* reported{nullptr};
    PendingAttestationUse reported_use{PendingAttestationUse::UNUSABLE};
    //! At most one usable entry that the mempool does not hold, to be offered again.
    std::vector<uint256> to_resubmit;
    //! Automatic entries outside the mempool that can no longer confirm (stale state, gone target or input).
    std::vector<uint256> to_abandon;
};

/** Examines every pending entry for one key (given in the order they are to be considered): any usable
 *  entry whose referenced state is the key's current record, whether or not the mempool holds it,
 *  suppresses construction, and unusable entries never hide a usable one. Unusable automatic entries are
 *  listed for cleanup separately (whether one has an unconfirmed descendant is decided at execution). The key's current record is
 *  read here from the chain state of `key_script`: a malformed local state is told apart from a missing
 *  record (IsDemurrageStateSaneForScript) before anything is matched, and then nothing is changed. */
KeyPendingDecision DecidePendingAttestationsForKey(const CWallet& wallet, const CCoinsViewCache& view,
                                                   const Consensus::Params& consensus, int evaluation_height,
                                                   int64_t evaluation_time, const CScript& key_script,
                                                   const std::vector<const PendingWalletAttestation*>& key_pending)
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);
/** Cleanup stage: abandons the listed automatic pending attestations, except any that has an unconfirmed,
 *  not abandoned descendant anywhere in the wallet (any key, direct or indirect), since abandonment is
 *  recursive. Decided under the wallet lock right before each abandonment. Returns how many were abandoned. */
size_t AbandonStaleAutomaticAttestations(CWallet& wallet, const std::set<uint256>& candidates);
int MaybeAutoShadowSignal(CWallet& wallet);
int MaybeAutoRedelegateQuantumColdStake(CWallet& wallet);

/** Result of comparing a candidate tip with the last tip an automatic scan ran on. */
enum class AutoScanVerdict {
    SCAN,
    SKIP_SAME_TIP,
    SKIP_REORG_BOUND,
};

/** Minimum time between automatic rescans caused by reorganisations. */
inline constexpr std::chrono::seconds AUTO_SCAN_REORG_MIN_INTERVAL{30};

/**
 * Decide whether an automatic scan runs for the tip (height, tip). A tip above
 * the last scanned height always scans, so work follows chain growth. The tip
 * already scanned is skipped. Any other tip (the same height with a different
 * hash, or a lower height) is a reorganisation: it scans only if the last such
 * rescan was at least AUTO_SCAN_REORG_MIN_INTERVAL ago, so a run of short
 * reorganisations cannot cause a rescan storm or repeated fee-paying
 * transactions. A skipped scan is not remembered; the next tip decides afresh.
 * A null last_tip means "scan again". last_reorg_scan is updated when a
 * reorganisation scan is allowed.
 */
AutoScanVerdict DecideAutoScan(int last_height, const uint256& last_tip,
                               int height, const uint256& tip,
                               std::chrono::steady_clock::time_point& last_reorg_scan,
                               std::chrono::steady_clock::time_point now);

} // namespace wallet

#endif // BITCOIN_WALLET_STAKING_H
