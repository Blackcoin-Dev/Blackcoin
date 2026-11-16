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
#include <wallet/coinselection.h>
#include <wallet/receive.h>
#include <wallet/transaction.h>
#include <wallet/wallet.h>

#include <array>
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
    bool memo_cleared{false};   //!< a verified memo entry disagreed with the chainstate and the memo was dropped
    uint64_t pending{0};        //!< two-phase scans: outputs handed to the chainstate phase
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

/** Chain facts a GUI balance scan captures under cs_main before it reads the
 * wallet without it. */
struct LifecycleScanTip {
    uint256 hash;
    int height{0};
    int evaluation_height{0};
    int64_t evaluation_mtp{0};
    //! Whether demurrage applies at the evaluation height (the attestation of
    //! each output's script is then needed to classify it).
    bool demurrage_active{false};
};

/** Capture the active tip. Returns nullopt without a tip or when the wallet
 * and the active chain tip differ. */
std::optional<LifecycleScanTip> CaptureLifecycleScanTip(const CWallet& wallet)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

/** An output whose classification needs the chainstate. */
struct LifecyclePendingOutput {
    uint256 txid;
    uint32_t n{0};
    bool wallet_immature{false};
    bool mine_spendable{false};
    bool watchonly{false};
    //! The memoized facts are usable; only the demurrage attestation is missing.
    bool memo_hit{false};
};

/** What the wallet-only part of a two-phase lifecycle balance scan produced:
 * the balance and summary of every output it could classify alone, and the
 * outputs left for the chainstate part. */
struct LifecycleBulkPass {
    LifecycleScanTip tip;
    //! CWallet::GetBalanceScanMarker() when the wallet was read.
    uint64_t marker{0};
    Balance balance;
    WalletLifecycleSummary summary;
    std::vector<LifecyclePendingOutput> pending;
    //! Distinct scriptPubKeys of the pending memo hits (demurrage only).
    std::set<CScript> attestation_scripts;
    int min_depth{0};
    bool avoid_reuse{false};
    //! Bookkeeping of the wallet-only part (outputs, memo hits).
    WalletLifecycleScanStats stats;
};

/** Number of outputs the wallet-only part visits between two calls of its
 * abort callback. */
static constexpr uint64_t LIFECYCLE_BULK_ABORT_INTERVAL{1024};

/** Part one of the two-phase GUI balance scan: everything that needs no
 * chainstate, under cs_wallet only (never cs_main). The same numbers as
 * GetLifecycleAdjustedBalance once ResolveLifecycleBulkPass has resolved the
 * pending outputs. Returns false (error set) when the wallet tip is not
 * tip.hash, on an arithmetic error, or when should_abort (called every
 * LIFECYCLE_BULK_ABORT_INTERVAL outputs) returns true. */
bool ScanLifecycleWalletSide(const CWallet& wallet, const LifecycleScanTip& tip,
                             int min_depth, bool avoid_reuse,
                             LifecycleBulkPass& pass, std::string& error,
                             const std::function<bool()>& should_abort = {})
    EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);

/** Part two: resolve the pending outputs against the chainstate under cs_main
 * and cs_wallet, and produce the balance. Fails closed (false, error set)
 * unless the active tip and the wallet tip are still pass.tip.hash and the
 * wallet change marker is unchanged, and when a verified memo entry
 * disagreed with the chainstate. The time limit is tested before every
 * pending output; options.max_database_reads is the deterministic knob.
 * budget_exhausted is set in options.stats when a limit stopped the pass
 * (memo entries written so far are kept). options.use_memo is implied. */
bool ResolveLifecycleBulkPass(const CWallet& wallet, LifecycleBulkPass& pass,
                              std::chrono::steady_clock::time_point deadline,
                              Balance& balance, WalletLifecycleSummary& summary,
                              std::string& error,
                              const WalletLifecycleOptions& options = {})
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

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
