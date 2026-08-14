// Copyright (c) 2014-2023 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <addresstype.h>
#include <chain.h>
#include <coins.h>
#include <common/args.h>
#include <consensus/demurrage.h>
#include <consensus/tx_verify.h>
#include <core_io.h>
#include <crypto/mldsa.h>
#include <policy/feerate.h>
#include <policy/policy.h>
#include <rpc/blockchain.h>
#include <rpc/server.h>
#include <rpc/server_util.h>
#include <rpc/util.h>
#include <shadow.h>
#include <timedata.h>
#include <util/moneystr.h>
#include <validation.h>
#include <wallet/coincontrol.h>
#include <wallet/fees.h>
#include <wallet/quantum_stake_ops.h>
#include <wallet/rpc/util.h>
#include <wallet/rpc/staking.h>
#include <wallet/shadow_pow_claim_recovery.h>
#include <wallet/spend.h>
#include <wallet/staking.h>
#include <wallet/redelegation.h>
#include <wallet/wallet.h>
#include <node/context.h>
#include <node/miner.h>
#include <node/quantum_pool.h>
#include <key_io.h> // For EncodeDestination
#include <pow.h> // For GetNextTargetRequired
#include <script/solver.h>
#include <util/strencodings.h>
#include <warnings.h>

#include <univalue.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <limits>
#include <map>
#include <optional>
#include <set>
#include <vector>

using node::BlockAssembler;

namespace wallet {

namespace {

struct StakingRpcChainSnapshot
{
    std::atomic<int> height{-1};
    std::atomic<uint64_t> network_weight{0};
    std::atomic<double> difficulty{0.0};
};

StakingRpcChainSnapshot g_staking_rpc_chain_snapshot;

} // namespace

static CFeeRate FeeRateFromSatVbValue(const UniValue& value)
{
    return CFeeRate{AmountFromValue(value, /*decimals=*/3)};
}

static bool ShadowPowClaimRelayMustWaitForNextTip(
    const std::string& error)
{
    return error.find("txn-mempool-conflict") != std::string::npos ||
           error.find("shadow-proof-mempool-limit") != std::string::npos ||
           error.find("txn-already-in-mempool") != std::string::npos ||
           error.find("txn-already-known") != std::string::npos ||
           error.find("wallet-broadcast-in-flight") != std::string::npos;
}

static bool ShadowPowClaimRelayRequiresFreshGate(const std::string& error)
{
    return error == "recovery-wallet-generation-changed" ||
           error == "recovery-database-outcome-ambiguous" ||
           error == "recovery-candidate-state-changed" ||
           error == "recovery-normal-wallet-unlock-ended" ||
           error == "recovery-automatic-authority-changed" ||
           error == "recovery-pow-miner-disabled" ||
           error == "recovery-pow-miner-authority-changed" ||
           error == "shadow-proof-relay-ttl-expired";
}

static constexpr size_t MAX_SHADOW_POW_RPC_RELAY_ATTEMPTS{256};

static std::string DurableQuantumKeyFailureMessage(
    const CTxDestination& created_destination,
    const std::string& action,
    const std::string& failure)
{
    return strprintf(
        "%s failed after creating durable non-HD ML-DSA key %s. The key remains in this wallet even though no successful action was reported. Back up the wallet now; an older backup cannot recover it. Original error: %s",
        action,
        EncodeDestination(created_destination),
        failure);
}

[[noreturn]] static void ThrowQuantumActionError(
    int code,
    const std::string& action,
    const std::string& failure,
    const std::optional<CTxDestination>& created_destination = std::nullopt)
{
    throw JSONRPCError(
        code,
        created_destination
            ? DurableQuantumKeyFailureMessage(*created_destination, action, failure)
            : failure);
}

static void CommitWalletTransactionOrThrow(
    CWallet& wallet,
    const CTransactionRef& tx,
    mapValue_t map_value,
    const std::string& action,
    const std::optional<CTxDestination>& created_destination = std::nullopt,
    const std::optional<ShadowPowClaimCommitAuthority>&
        shadow_pow_authority = std::nullopt)
{
    std::string broadcast_error;
    bool committed{false};
    try {
        committed = wallet.CommitTransaction(
            tx, std::move(map_value), {}, &broadcast_error,
            /*commit_status=*/nullptr, shadow_pow_authority);
    } catch (const std::exception& e) {
        if (created_destination) {
            ThrowQuantumActionError(
                RPC_WALLET_ERROR,
                action,
                strprintf("transaction broadcast raised an exception: %s", e.what()),
                created_destination);
        }
        if (!TransactionHasShadowProof(*tx)) throw;
        const bool added_to_wallet = WITH_LOCK(wallet.cs_wallet, return wallet.GetWalletTx(tx->GetHash()) != nullptr);
        if (added_to_wallet) {
            wallet.QuarantineShadowPowClaim(tx->GetHash());
            wallet.WalletLogPrintf("Quarantined %s transaction %s after broadcast exception; its input remains reserved\n",
                                   action, tx->GetHash().ToString());
        }
        throw JSONRPCError(RPC_WALLET_ERROR,
                           strprintf("%s transaction broadcast raised an exception: %s", action, e.what()));
    } catch (...) {
        if (created_destination) {
            ThrowQuantumActionError(
                RPC_WALLET_ERROR,
                action,
                "transaction broadcast raised an unknown exception",
                created_destination);
        }
        if (TransactionHasShadowProof(*tx)) {
            const bool added_to_wallet = WITH_LOCK(wallet.cs_wallet, return wallet.GetWalletTx(tx->GetHash()) != nullptr);
            if (added_to_wallet) {
                wallet.QuarantineShadowPowClaim(tx->GetHash());
                wallet.WalletLogPrintf("Quarantined %s transaction %s after unknown broadcast exception; its input remains reserved\n",
                                       action, tx->GetHash().ToString());
            }
        }
        throw;
    }
    if (!committed) {
        const std::string reason = broadcast_error.empty() ? "transaction was not accepted into the mempool" : broadcast_error;
        const bool added_to_wallet = WITH_LOCK(wallet.cs_wallet, return wallet.GetWalletTx(tx->GetHash()) != nullptr);
        if (added_to_wallet && TransactionHasShadowProof(*tx)) {
            wallet.QuarantineShadowPowClaim(tx->GetHash());
            wallet.WalletLogPrintf("Quarantined %s transaction %s after broadcast failure; its input remains reserved\n",
                                   action, tx->GetHash().ToString());
        } else if (added_to_wallet && !wallet.AbandonTransaction(tx->GetHash())) {
            wallet.WalletLogPrintf("%s transaction could not be abandoned after broadcast failure: txid=%s\n", action, tx->GetHash().ToString());
        }
        ThrowQuantumActionError(
            RPC_WALLET_ERROR,
            action,
            strprintf("transaction was created but could not be broadcast: %s", reason),
            created_destination);
    }
}

static bool HasUnconfirmedWalletShadowSignal(const CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    for (const uint256& txid : wallet.GetPendingShadowSignalTxids()) {
        const auto it = wallet.mapWallet.find(txid);
        if (it == wallet.mapWallet.end()) continue;
        const CWalletTx& wtx = it->second;
        const auto comment = wtx.mapValue.find("comment");
        if (comment == wtx.mapValue.end() ||
            (comment->second != "PoS Claim" && comment->second != "Quantum PoS Claim")) {
            continue;
        }
        if (wtx.isUnconfirmed()) return true;
    }
    return false;
}

struct WalletQQSignalStatus
{
    bool active{false};
    std::string status{"none"};
    uint256 txid;
    int signal_height{0};
    int expiry_height{0};
    int confirmations{0};
    std::string source{"unknown"};
    CScript target;
    CScript payout_script;
    uint32_t solve_height{0};
    uint256 solve_hash;
    int64_t wallet_order{-1};
    int64_t received_time{0};
};

struct WalletQQSignalReport
{
    WalletQQSignalStatus current;
    std::vector<WalletQQSignalStatus> history;
};

static WalletQQSignalReport GetWalletQQSignalStatusLocked(
    const CWallet& wallet,
    const std::map<CScript, ShadowActiveSignalInfo>& active_signals,
    int tip_height)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet)
{
    WalletQQSignalReport report;
    int selected_rank{-1};
    const CBlockIndex* tip = wallet.chain().chainman().ActiveChain().Tip();
    const Consensus::Params& consensus = Params().GetConsensus();
    const auto signal_is_expired = [&](const ShadowSignalInfo& signal) {
        if (!tip) return false;
        if (!IsShadowGoldRushRewardActive(
                consensus, tip->GetMedianTimePast(), tip->nHeight + 1)) {
            return true;
        }
        if (signal.solve_height == 0 ||
            signal.solve_height > static_cast<uint32_t>(tip->nHeight) ||
            tip->nHeight - static_cast<int>(signal.solve_height) >
                SHADOW_SOLVER_ACTIVITY_WINDOW) {
            return true;
        }
        const CBlockIndex* solved =
            wallet.chain().chainman().ActiveChain()[signal.solve_height];
        return solved && solved->GetBlockHash() == signal.solve_hash &&
            tip->GetBlockTime() - solved->GetBlockTime() >
                SHADOW_SOLVER_ACTIVITY_SECONDS;
    };

    for (const auto& [txid, wtx] : wallet.mapWallet) {
        const auto comment = wtx.mapValue.find("comment");
        ShadowSignalInfo signal;
        if (!DecodeShadowSignal(*wtx.tx, signal)) continue;
        const bool wallet_authored =
            (comment != wtx.mapValue.end() &&
             (comment->second == "PoS Claim" ||
              comment->second == "Quantum PoS Claim")) ||
            wallet.GetDebit(*wtx.tx, ISMINE_SPENDABLE) > 0;
        if (!wallet_authored) continue;

        WalletQQSignalStatus candidate;
        candidate.txid = txid;
        candidate.target = CanonicalizeLegacyStakeScript(signal.target);
        candidate.payout_script = signal.payout_script;
        candidate.solve_height = signal.solve_height;
        candidate.solve_hash = signal.solve_hash;
        candidate.wallet_order = wtx.nOrderPos;
        candidate.received_time = wtx.nTimeReceived;
        const auto source = wtx.mapValue.find("qq_shadow_signal_source");
        if (source != wtx.mapValue.end() &&
            (source->second == "manual" || source->second == "automatic")) {
            candidate.source = source->second;
        }

        int rank{100};
        if (const auto* confirmed = wtx.state<TxStateConfirmed>()) {
            candidate.signal_height = confirmed->confirmed_block_height;
            candidate.expiry_height = confirmed->confirmed_block_height +
                SHADOW_SOLVER_ACTIVITY_WINDOW;
            candidate.confirmations = std::max(
                0, tip_height - confirmed->confirmed_block_height + 1);
            const auto active = active_signals.find(candidate.target);
            candidate.active = active != active_signals.end() &&
                active->second.signal_height ==
                    static_cast<uint32_t>(confirmed->confirmed_block_height) &&
                active->second.payout_script == candidate.payout_script;
            if (candidate.active) {
                candidate.status = "confirmed";
                rank = 600;
            } else if (tip_height > candidate.expiry_height) {
                candidate.status = "expired";
                rank = 200;
            } else if (active != active_signals.end() &&
                       (active->second.signal_height >
                            static_cast<uint32_t>(confirmed->confirmed_block_height) ||
                        active->second.payout_script != candidate.payout_script)) {
                candidate.status = "superseded";
                rank = 300;
            } else {
                // The transaction is confirmed as an ordinary transaction,
                // but authenticated active-signal state does not establish
                // current membership. Keep `active=false` rather than
                // inferring wallet participation from global counters.
                candidate.status = "confirmed";
                rank = 250;
            }
        } else if (wtx.InMempool()) {
            candidate.status = "mempool";
            rank = 500;
        } else {
            const auto reorg_height = wtx.mapValue.find(
                "qq_shadow_signal_reorg_height");
            const auto reorg_hash = wtx.mapValue.find(
                "qq_shadow_signal_reorg_hash");
            int parsed_height{0};
            uint256 parsed_reorg_hash;
            if (reorg_height != wtx.mapValue.end() &&
                reorg_hash != wtx.mapValue.end() &&
                ParseInt32(reorg_height->second, &parsed_height) &&
                parsed_height > 0 &&
                parsed_height <=
                    std::numeric_limits<int>::max() -
                        SHADOW_SOLVER_ACTIVITY_WINDOW &&
                reorg_hash->second.size() == uint256::size() * 2 &&
                IsHex(reorg_hash->second) &&
                !(parsed_reorg_hash = uint256S(reorg_hash->second)).IsNull() &&
                (parsed_height > tip_height ||
                 !wallet.chain().chainman().ActiveChain()[parsed_height] ||
                 wallet.chain().chainman().ActiveChain()[parsed_height]
                         ->GetBlockHash() != parsed_reorg_hash)) {
                candidate.status = "reorg_removed";
                candidate.signal_height = parsed_height;
                candidate.expiry_height = parsed_height +
                    SHADOW_SOLVER_ACTIVITY_WINDOW;
                rank = 400;
            } else if (wtx.isConflicted()) {
                candidate.status = "superseded";
                rank = 300;
            } else if (signal_is_expired(signal)) {
                candidate.status = "expired";
                rank = 200;
            }
        }

        const bool candidate_has_order = candidate.wallet_order >= 0;
        const bool selected_has_order = report.current.wallet_order >= 0;
        const bool candidate_is_newer =
            candidate_has_order != selected_has_order
                ? candidate_has_order
                : candidate_has_order
                    ? candidate.wallet_order > report.current.wallet_order ||
                          (candidate.wallet_order == report.current.wallet_order &&
                           (candidate.received_time > report.current.received_time ||
                            (candidate.received_time == report.current.received_time &&
                             report.current.txid < candidate.txid)))
                    : candidate.received_time > report.current.received_time ||
                          (candidate.received_time == report.current.received_time &&
                           report.current.txid < candidate.txid);
        if (rank > selected_rank ||
            (rank == selected_rank && candidate_is_newer)) {
            report.current = candidate;
            selected_rank = rank;
        }
        report.history.push_back(std::move(candidate));
    }
    std::sort(report.history.begin(), report.history.end(),
              [](const WalletQQSignalStatus& left,
                 const WalletQQSignalStatus& right) {
                  const bool left_has_order = left.wallet_order >= 0;
                  const bool right_has_order = right.wallet_order >= 0;
                  if (left_has_order != right_has_order) {
                      return left_has_order;
                  }
                  if (left_has_order &&
                      left.wallet_order != right.wallet_order) {
                      return left.wallet_order > right.wallet_order;
                  }
                  if (left.received_time != right.received_time) {
                      return left.received_time > right.received_time;
                  }
                  return right.txid < left.txid;
              });
    return report;
}

static UniValue WalletQQSignalEntryToJSON(
    const WalletQQSignalStatus& status)
{
    UniValue result(UniValue::VOBJ);
    result.pushKV("active", status.active);
    result.pushKV("status", status.status);
    result.pushKV("txid", status.txid.IsNull() ? "" : status.txid.GetHex());
    result.pushKV("signal_height", status.signal_height);
    result.pushKV("activation_height", status.signal_height);
    result.pushKV("expiry_height", status.expiry_height);
    result.pushKV("confirmations", status.confirmations);
    result.pushKV("source", status.source);
    result.pushKV("target_script", HexStr(status.target));
    result.pushKV("payout_script", HexStr(status.payout_script));
    result.pushKV("solve_height", status.solve_height);
    result.pushKV("solve_hash",
                  status.solve_hash.IsNull() ? "" : status.solve_hash.GetHex());
    return result;
}

static UniValue WalletQQSignalStatusToJSON(
    const WalletQQSignalReport& report)
{
    UniValue result = WalletQQSignalEntryToJSON(report.current);
    UniValue history(UniValue::VARR);
    for (const WalletQQSignalStatus& entry : report.history) {
        history.push_back(WalletQQSignalEntryToJSON(entry));
    }
    result.pushKV("history", std::move(history));
    return result;
}

static UniValue QuantumOperatorBondInfoToJSON(const interfaces::WalletQuantumOperatorBondInfo& info)
{
    UniValue obj(UniValue::VOBJ);
    obj.pushKV("available", info.available);
    obj.pushKV("valid_address", info.valid_operator_address);
    obj.pushKV("current_height", info.current_height);
    obj.pushKV("bonded_amount", ValueFromAmount(info.bonded_amount));
    obj.pushKV("bonded_outputs", info.bonded_outputs);
    obj.pushKV("unbonding_amount", ValueFromAmount(info.unbonding_amount));
    obj.pushKV("unbonding_outputs", info.unbonding_outputs);
    obj.pushKV("withdrawable_amount", ValueFromAmount(info.withdrawable_amount));
    obj.pushKV("withdrawable_outputs", info.withdrawable_outputs);
    obj.pushKV("next_unlock_height", info.next_unlock_height);
    return obj;
}

static UniValue QuantumStakeOutputsToJSON(const std::vector<interfaces::WalletQuantumStakeOutputInfo>& outputs)
{
    UniValue arr(UniValue::VARR);
    for (const auto& output : outputs) {
        UniValue obj(UniValue::VOBJ);
        obj.pushKV("txid", output.txid);
        obj.pushKV("vout", output.vout);
        obj.pushKV("address", output.address);
        obj.pushKV("amount", ValueFromAmount(output.amount));
        obj.pushKV("depth", output.depth);
        obj.pushKV("state", output.state);
        obj.pushKV("unlock_height", output.unlock_height);
        obj.pushKV("spendable", output.spendable);
        arr.push_back(std::move(obj));
    }
    return arr;
}

static UniValue QuantumPoolOperatorToJSON(const node::QuantumPoolShare& share)
{
    UniValue obj(UniValue::VOBJ);
    obj.pushKV("staking_pubkey_hash", share.operator_share.staker_pubkey_hash.GetHex());
    if (!share.operator_share.staker_pubkey.empty()) {
        obj.pushKV("staking_pubkey", HexStr(share.operator_share.staker_pubkey));
    }
    obj.pushKV("verified_value", ValueFromAmount(share.operator_share.verified_value));
    obj.pushKV("share_bps", node::QuantumPoolShareBps(share.operator_share.verified_value, share.total_coldstake));
    obj.pushKV("verified_claims", share.operator_share.verified_claims);
    obj.pushKV("invalid_claims", share.operator_share.invalid_claims);
    obj.pushKV("operator_commitment_verified", share.operator_share.operator_commitment_verified);
    obj.pushKV("over_cap", node::WouldQuantumPoolExceedCap(share.total_coldstake, share.operator_share.verified_value, 0));
    return obj;
}

struct RpcLocalOperatorBondCandidate
{
    std::vector<unsigned char> staking_pubkey;
    COutPoint outpoint;
};

static std::vector<RpcLocalOperatorBondCandidate> FindRpcWalletOperatorBondCandidates(const CWallet& wallet)
{
    static constexpr uint16_t OPERATOR_COMMITMENT_BLOCKS = 40500;

    struct OperatorAddress
    {
        std::string address;
        std::vector<unsigned char> staking_pubkey;
    };

    std::vector<OperatorAddress> operator_addresses;
    {
        LOCK2(::cs_main, wallet.cs_wallet);
        const auto infos = wallet.ListQuantumKeyInfos();
        operator_addresses.reserve(infos.size());
        for (const QuantumKeyInfo& info : infos) {
            if (info.public_key.size() != ML_DSA::PUBLICKEY_BYTES) continue;
            const CScript script = GetScriptForDestination(info.destination);
            const auto tier = GetQuantumStakeTierProgram(script);
            if (!tier || !tier->tiered || tier->cold_stake ||
                tier->unbonding_blocks != OPERATOR_COMMITMENT_BLOCKS) {
                continue;
            }
            operator_addresses.push_back({EncodeDestination(info.destination), info.public_key});
        }
    }

    std::vector<RpcLocalOperatorBondCandidate> candidates;
    for (const OperatorAddress& operator_address : operator_addresses) {
        const std::vector<interfaces::WalletQuantumStakeOutputInfo> outputs =
            ListTieredStakeOutputs(wallet, operator_address.address, /*require_operator_lock=*/true);
        for (const interfaces::WalletQuantumStakeOutputInfo& output : outputs) {
            if (output.state != "bonded" || output.amount <= 0) continue;
            candidates.push_back({
                operator_address.staking_pubkey,
                COutPoint{uint256S(output.txid), output.vout}});
        }
    }
    return candidates;
}

static std::map<uint256, std::vector<node::QuantumPoolClaim>> FindRpcWalletQuantumPoolClaims(const CWallet& wallet)
{
    std::map<uint256, std::vector<node::QuantumPoolClaim>> claims_by_operator;

    LOCK2(::cs_main, wallet.cs_wallet);
    CoinFilterParams filter;
    filter.only_spendable = false;
    filter.skip_locked = false;
    filter.include_immature_coinbase = false;
    const std::vector<COutput> coins = AvailableCoinsListUnspent(wallet, nullptr, filter).All();

    for (const COutput& out : coins) {
        if (out.txout.nValue <= 0) continue;

        int witness_version{0};
        std::vector<unsigned char> witness_program;
        if (!out.txout.scriptPubKey.IsWitnessProgram(witness_version, witness_program) ||
            !IsQuantumColdStakeWitnessProgram(witness_version, witness_program)) {
            continue;
        }

        const auto info = wallet.GetQuantumColdStakeDelegationInfo(witness_program);
        if (!info) continue;

        node::QuantumPoolClaim claim;
        claim.outpoint = out.outpoint;
        claim.staker_pubkey_hash = info->staker_pubkey_hash;
        claim.owner_pubkey_hash = info->owner_pubkey_hash;

        if (const auto tier = GetQuantumStakeTierProgram(out.txout.scriptPubKey); tier && tier->tiered && tier->cold_stake) {
            claim.tiered = true;
            claim.state = tier->state;
            claim.unbonding_blocks = tier->unbonding_blocks;
            claim.unlock_height = tier->unlock_height;
        }

        claims_by_operator[claim.staker_pubkey_hash].push_back(std::move(claim));
    }

    return claims_by_operator;
}

static UniValue QuantumColdStakeBalanceToJSON(const interfaces::WalletQuantumColdStakeBalanceInfo& info)
{
    UniValue obj(UniValue::VOBJ);
    obj.pushKV("available", info.available);
    obj.pushKV("valid_delegation_address", info.valid_delegation_address);
    obj.pushKV("current_height", info.current_height);
    obj.pushKV("amount", ValueFromAmount(info.amount));
    obj.pushKV("outputs", info.outputs);
    obj.pushKV("confirmed_amount", ValueFromAmount(info.confirmed_amount));
    obj.pushKV("confirmed_outputs", info.confirmed_outputs);
    obj.pushKV("unconfirmed_amount", ValueFromAmount(info.unconfirmed_amount));
    obj.pushKV("unconfirmed_outputs", info.unconfirmed_outputs);
    obj.pushKV("spendable_amount", ValueFromAmount(info.spendable_amount));
    obj.pushKV("spendable_outputs", info.spendable_outputs);
    return obj;
}

static UniValue QuantumStakeTxToJSON(const interfaces::WalletQuantumOperatorBondTx& tx)
{
    UniValue obj(UniValue::VOBJ);
    if (!tx.txid.empty()) obj.pushKV("txid", tx.txid);
    obj.pushKV("address", tx.address);
    obj.pushKV("amount", ValueFromAmount(tx.amount));
    obj.pushKV("fee", ValueFromAmount(tx.fee));
    obj.pushKV("unlock_height", tx.unlock_height);
    obj.pushKV("started_unbonding", tx.started_unbonding);
    obj.pushKV("completed_withdrawal", tx.completed_withdrawal);
    obj.pushKV("created_goldrush_migration", tx.created_migration);
    obj.pushKV("completed_delegation", tx.completed_delegation);
    if (!tx.migration_txid.empty()) obj.pushKV("migration_txid", tx.migration_txid);
    if (!tx.migration_address.empty()) obj.pushKV("migration_address", tx.migration_address);
    if (tx.migration_amount > 0) obj.pushKV("migration_amount", ValueFromAmount(tx.migration_amount));
    if (tx.migration_fee > 0) obj.pushKV("migration_fee", ValueFromAmount(tx.migration_fee));
    if (!tx.warning.empty()) obj.pushKV("warning", tx.warning);
    return obj;
}

static COutPoint OutPointFromRPCOptions(const UniValue& options)
{
    if (!options.isObject()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "outpoint must be an object with txid and vout");
    }
    const UniValue& txid_v = options.find_value("txid");
    const UniValue& vout_v = options.find_value("vout");
    if (!txid_v.isStr() || !vout_v.isNum()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "outpoint must include string txid and numeric vout");
    }
    const int vout = vout_v.getInt<int>();
    if (vout < 0) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "vout must be non-negative");
    }
    return COutPoint{ParseHashV(txid_v, "txid"), static_cast<uint32_t>(vout)};
}

static bool ParseWithdrawAllOption(const UniValue& options)
{
    if (options.isNull()) return false;
    if (!options.isObject()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "options must be an object");
    }
    return options.exists("all") && options["all"].get_bool();
}

static bool RequireNewQuantumKeyConsent(const UniValue& options, const std::string& rpc_name)
{
    if (!options.isNull() && !options.isObject()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "options must be an object");
    }
    const bool allowed = options.isObject() && options.exists("allow_new_quantum_key") &&
                         options["allow_new_quantum_key"].get_bool();
    if (!allowed) {
        throw JSONRPCError(
            RPC_INVALID_PARAMETER,
            strprintf("%s creates a new non-HD ML-DSA key that an older wallet backup cannot recover. Retry the same command with options={\"allow_new_quantum_key\":true} only after authorizing key creation, then back up the wallet immediately. No key, transaction, or wallet metadata was created.", rpc_name));
    }
    return true;
}

static UniValue RetiredStakingDonationInfoToJSON()
{
    UniValue obj(UniValue::VOBJ);
    obj.pushKV("retired", true);
    obj.pushKV("enabled", false);
    obj.pushKV("percentage", 0);
    obj.pushKV("target_address", "");
    obj.pushKV("note", "Legacy development-fund staking payments are permanently disabled. This interface cannot authorize the separate Quantum Quasar development donation facility.");
    return obj;
}

static UniValue QQDevelopmentDonationInfoToJSON(const CWallet& wallet)
{
    LOCK(wallet.cs_wallet);
    const QQDevelopmentDonationConsent consent =
        wallet.GetQQDevelopmentDonationConsent();
    const std::string current_network = Params().GetChainTypeString();
    const std::string current_recipient =
        Params().GetQQDevelopmentDonationAddress();
    const bool database_ambiguous =
        wallet.IsQQDevelopmentDonationDatabaseAmbiguous();
    const bool consent_matches_current =
        consent.choice_recorded == 1 &&
        consent.network == current_network &&
        consent.recipient == current_recipient;
    const unsigned int effective_percentage =
        wallet.GetQQDevelopmentDonationPercentage();

    UniValue obj(UniValue::VOBJ);
    obj.pushKV("enabled", effective_percentage > 0);
    obj.pushKV("percentage", effective_percentage);
    obj.pushKV("stored_percentage", consent.percentage);
    obj.pushKV("choice_recorded", consent.choice_recorded == 1);
    obj.pushKV("network", current_network);
    obj.pushKV("recipient", current_recipient);
    obj.pushKV("consent_network", consent.network);
    obj.pushKV("consent_recipient", consent.recipient);
    obj.pushKV("consent_matches_current", consent_matches_current);
    obj.pushKV("reauthorization_required",
               consent.HasDonationAuthority() && !consent_matches_current);
    obj.pushKV("database_outcome_ambiguous", database_ambiguous);
    obj.pushKV("minimum_percentage", MIN_QQ_DEVELOPMENT_DONATION_PERCENTAGE);
    obj.pushKV("maximum_percentage", MAX_QQ_DEVELOPMENT_DONATION_PERCENTAGE);
    obj.pushKV("default_percentage", DEFAULT_QQ_DEVELOPMENT_DONATION_PERCENTAGE);
    obj.pushKV("note", "This optional wallet policy is not a consensus tax. A nonzero choice is effective only for the exact network and direct quantum recipient shown here.");
    return obj;
}

static std::vector<RPCResult> QuantumOperatorBondInfoResult()
{
    return {
        {RPCResult::Type::BOOL, "available", "false if wallet state could not be locked"},
        {RPCResult::Type::BOOL, "valid_address", "true if the address is a wallet-backed staking/operator address"},
        {RPCResult::Type::NUM, "current_height", "Wallet chain height"},
        {RPCResult::Type::STR_AMOUNT, "bonded_amount", "Currently bonded amount"},
        {RPCResult::Type::NUM, "bonded_outputs", "Number of bonded outputs"},
        {RPCResult::Type::STR_AMOUNT, "unbonding_amount", "Amount in the unbonding state"},
        {RPCResult::Type::NUM, "unbonding_outputs", "Number of unbonding outputs"},
        {RPCResult::Type::STR_AMOUNT, "withdrawable_amount", "Amount matured enough to withdraw"},
        {RPCResult::Type::NUM, "withdrawable_outputs", "Number of withdrawable outputs"},
        {RPCResult::Type::NUM, "next_unlock_height", "Next unbonding output unlock height, or 0"},
    };
}

static std::vector<RPCResult> QuantumStakeTxResult()
{
    return {
        {RPCResult::Type::STR_HEX, "txid", /*optional=*/true, "Broadcast transaction id, when a transaction was completed"},
        {RPCResult::Type::STR, "address", "Destination or staking address"},
        {RPCResult::Type::STR_AMOUNT, "amount", "Transaction amount"},
        {RPCResult::Type::STR_AMOUNT, "fee", "Transaction fee"},
        {RPCResult::Type::NUM, "unlock_height", "Unlock height for newly unbonding funds, or 0"},
        {RPCResult::Type::BOOL, "started_unbonding", "true if the transaction started an unbonding period"},
        {RPCResult::Type::BOOL, "completed_withdrawal", "true if the transaction withdrew matured funds"},
        {RPCResult::Type::BOOL, "created_goldrush_migration", "deprecated compatibility field; mature Gold Rush rewards do not require a preliminary move"},
        {RPCResult::Type::BOOL, "completed_delegation", "true if the requested delegation/funding transaction completed"},
        {RPCResult::Type::STR_HEX, "migration_txid", /*optional=*/true, "deprecated optional Gold Rush consolidation transaction id"},
        {RPCResult::Type::STR, "migration_address", /*optional=*/true, "Fresh quantum migration address"},
        {RPCResult::Type::STR_AMOUNT, "migration_amount", /*optional=*/true, "Amount moved by deprecated optional Gold Rush consolidation"},
        {RPCResult::Type::STR_AMOUNT, "migration_fee", /*optional=*/true, "Fee paid by deprecated optional Gold Rush consolidation"},
        {RPCResult::Type::STR, "warning", /*optional=*/true, "Follow-up warning"},
    };
}

static UniValue ThrowOrReturnQuantumStakeTx(util::Result<interfaces::WalletQuantumOperatorBondTx>&& result)
{
    if (!result) {
        throw JSONRPCError(RPC_WALLET_ERROR, util::ErrorString(result).original);
    }
    return QuantumStakeTxToJSON(*result);
}

static RPCHelpMan getstakinginfo()
{
    return RPCHelpMan{"getstakinginfo",
                "\nReturns an object containing staking-related information.",
                {},
                RPCResult{
                    RPCResult::Type::OBJ, "", "",
                    {
                        {RPCResult::Type::BOOL, "enabled", "'true' if staking is enabled"},
                        {RPCResult::Type::BOOL, "staking", "'true' if wallet is currently staking"},
                        {RPCResult::Type::STR, "staking_state", "Stable worker state: disabled, starting, locked, syncing, searching, no_eligible_coins, error, or stopped."},
                        {RPCResult::Type::STR, "staking_reason", "Typed worker-state explanation suitable for monitoring."},
                        {RPCResult::Type::BOOL, "worker_running", "Whether the wallet's PoS worker thread is running."},
                        {RPCResult::Type::BOOL, "eligible", "Whether the published coherent snapshot has positive eligible stake weight."},
                        {RPCResult::Type::BOOL, "staking_snapshot_current", "Whether the published staking snapshot is for the current active-chain tip."},
                        {RPCResult::Type::NUM, "staking_snapshot_sequence", "Monotonic per-wallet telemetry publication sequence."},
                        {RPCResult::Type::NUM, "active_blocks", "Current active-chain height, which may be ahead of the last complete staking snapshot during a normal tip refresh."},
                        {RPCResult::Type::BOOL, "autostart_staking", "Effective process-wide consent to start staking for every eligible loaded wallet."},
                        {RPCResult::Type::STR, "autostart_staking_source", "Source of the effective state: autostartstaking, legacy_staking, or default_off."},
                        {RPCResult::Type::BOOL, "automatic_qqsignal", "Whether process-wide optional fee-paying Gold Rush PoS QQSIGNAL automation is enabled for eligible loaded wallets."},
                        {RPCResult::Type::BOOL, "automatic_demurrage_attestation", "Whether process-wide optional fee-paying wallet demurrage-attestation automation is enabled for eligible loaded wallets."},
                        {RPCResult::Type::BOOL, "automatic_redelegation", "Whether process-wide optional fee-paying quantum cold-stake redelegation automation is enabled for eligible loaded wallets."},
                        {RPCResult::Type::BOOL, "allow_automatic_quantum_key_creation", "Whether process-wide background automation may create new non-HD ML-DSA keys in loaded wallets."},
                        {RPCResult::Type::BOOL, "consensus_demurrage_automatic", "Always true: mandatory consensus demurrage/burn is independent of optional wallet attestations."},
                        {RPCResult::Type::NUM, "blocks", "Current active-chain height"},
                        {RPCResult::Type::NUM, "currentblockweight", /*optional=*/true, "Weight of the last assembled block template"},
                        {RPCResult::Type::NUM, "currentblocktx", /*optional=*/true, "Transaction count of the last assembled block template"},
                        {RPCResult::Type::NUM, "pooledtx", "The size of the mempool"},
                        {RPCResult::Type::NUM, "difficulty", "The current difficulty"},
                        {RPCResult::Type::NUM, "search-interval", "The staker search interval"},
                        {RPCResult::Type::NUM, "weight", "The staker weight"},
                        {RPCResult::Type::BOOL, "weight_cached", "Whether weight is from a completed staking-wallet scan"},
                        {RPCResult::Type::NUM, "weight_cache_height", "Active-chain height of the completed weight scan, or -1 when unavailable"},
                        {RPCResult::Type::NUM, "netstakeweight", "Network stake weight"},
                        {RPCResult::Type::NUM, "expectedtime", "Expected time to earn reward"},
                        {RPCResult::Type::BOOL, "chainstate_cached", "Whether chain statistics were served from the last non-blocking snapshot"},
                        {RPCResult::Type::STR, "chain", "Current chain name"},
                        {RPCResult::Type::STR, "warnings", "Current network and wallet warnings"},
                    }
                },
                RPCExamples{
                    HelpExampleCli("getstakinginfo", "")
            + HelpExampleRpc("getstakinginfo", "")
                },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    ScopedDisallowShadowSolverActivityFullScan no_full_solver_scan;

    const StakingTelemetrySnapshot staking_snapshot =
        pwallet->GetStakingTelemetrySnapshot();
    const bool staking_snapshot_available = staking_snapshot.sequence > 0 &&
        staking_snapshot.tip_height >= 0;
    const int weight_cache_height = staking_snapshot_available
        ? staking_snapshot.weight_cache_height
        : pwallet->m_cached_stake_weight_height.load(
              std::memory_order_acquire);
    const bool weight_cached = weight_cache_height >= 0;
    const uint64_t nWeight = staking_snapshot_available
        ? staking_snapshot.weight
        : weight_cached
            ? pwallet->m_cached_stake_weight.load(std::memory_order_relaxed)
            : 0;
    const uint64_t lastCoinStakeSearchInterval = staking_snapshot.enabled
        ? static_cast<uint64_t>(std::max<int64_t>(
              0, staking_snapshot.search_interval))
        : 0;

    const CTxMemPool& mempool = pwallet->chain().mempool();
    ChainstateManager& chainman = pwallet->chain().chainman();
    int active_blocks = g_staking_rpc_chain_snapshot.height.load(
        std::memory_order_acquire);
    if (active_blocks < 0 && staking_snapshot_available) {
        active_blocks = staking_snapshot.tip_height;
    }
    uint256 active_tip;
    int blocks = staking_snapshot_available
        ? staking_snapshot.tip_height
        : active_blocks;
    uint64_t nNetworkWeight = g_staking_rpc_chain_snapshot.network_weight.load(std::memory_order_relaxed);
    double difficulty = g_staking_rpc_chain_snapshot.difficulty.load(std::memory_order_relaxed);
    bool chainstate_cached{true};
    std::optional<int64_t> current_block_weight;
    std::optional<int64_t> current_block_txs;
    {
        TRY_LOCK(::cs_main, main_lock);
        if (main_lock) {
            chainstate_cached = false;
            active_blocks = chainman.ActiveChain().Height();
            if (const CBlockIndex* tip = chainman.ActiveChain().Tip()) {
                active_tip = tip->GetBlockHash();
            }
            if (!staking_snapshot_available) blocks = active_blocks;
            nNetworkWeight = static_cast<uint64_t>(1.1429 * GetPoSKernelPS(chainman));
            if (chainman.m_best_header) {
                difficulty = GetDifficulty(GetLastBlockIndex(chainman.m_best_header, true));
            }
            if (BlockAssembler::m_last_block_weight) current_block_weight = *BlockAssembler::m_last_block_weight;
            if (BlockAssembler::m_last_block_num_txs) current_block_txs = *BlockAssembler::m_last_block_num_txs;
            g_staking_rpc_chain_snapshot.network_weight.store(nNetworkWeight, std::memory_order_relaxed);
            g_staking_rpc_chain_snapshot.difficulty.store(difficulty, std::memory_order_relaxed);
            g_staking_rpc_chain_snapshot.height.store(active_blocks, std::memory_order_release);
        }
    }
    if (active_blocks < 0 || blocks < 0) {
        TRY_LOCK(pwallet->cs_wallet, wallet_lock);
        const std::optional<int> wallet_height = wallet_lock
            ? pwallet->GetLastBlockHeightIfSet()
            : std::nullopt;
        const int fallback_height = wallet_height.value_or(0);
        if (active_blocks < 0) active_blocks = fallback_height;
        if (blocks < 0) blocks = fallback_height;
    }

    UniValue obj(UniValue::VOBJ);

    const bool staking = staking_snapshot.enabled &&
        staking_snapshot.worker_running && staking_snapshot.eligible &&
        staking_snapshot.state == StakingTelemetryState::SEARCHING;
    const bool staking_snapshot_current = staking_snapshot_available &&
        staking_snapshot.tip_height == active_blocks &&
        (active_tip.IsNull() || staking_snapshot.tip == active_tip);

    const Consensus::Params& consensusParams = Params().GetConsensus();
    int64_t nTargetSpacing = consensusParams.nTargetSpacing;
    uint64_t nExpectedTime = staking ? 1.0455 * nTargetSpacing * nNetworkWeight / nWeight : 0;

    obj.pushKV("enabled", staking_snapshot.enabled);
    obj.pushKV("staking", staking);
    obj.pushKV("staking_state", std::string(
        StakingTelemetryStateName(staking_snapshot.state)));
    obj.pushKV("staking_reason", staking_snapshot.reason);
    obj.pushKV("worker_running", staking_snapshot.worker_running);
    obj.pushKV("eligible", staking_snapshot.eligible);
    obj.pushKV("staking_snapshot_current", staking_snapshot_current);
    obj.pushKV("staking_snapshot_sequence", staking_snapshot.sequence);
    obj.pushKV("autostart_staking", IsStakingAutostartEnabled());
    obj.pushKV("autostart_staking_source", gArgs.IsArgSet("-autostartstaking")
        ? "autostartstaking"
        : gArgs.IsArgSet("-staking") ? "legacy_staking" : "default_off");
    obj.pushKV("automatic_qqsignal", gArgs.GetBoolArg("-qqautoshadowsignal", DEFAULT_AUTO_SHADOW_SIGNAL));
    obj.pushKV("automatic_demurrage_attestation", gArgs.GetBoolArg("-qqautodemurrageattest", DEFAULT_AUTO_DEMURRAGE_ATTEST));
    obj.pushKV("automatic_redelegation", gArgs.GetBoolArg("-qqautoredelegate", DEFAULT_AUTO_REDELEGATE));
    obj.pushKV("allow_automatic_quantum_key_creation", gArgs.GetBoolArg("-qqallowautokeycreation", DEFAULT_ALLOW_AUTO_QUANTUM_KEY_CREATION));
    obj.pushKV("consensus_demurrage_automatic", true);

    obj.pushKV("blocks", blocks);
    obj.pushKV("active_blocks", active_blocks);
    if (current_block_weight) obj.pushKV("currentblockweight", *current_block_weight);
    if (current_block_txs) obj.pushKV("currentblocktx", *current_block_txs);
    obj.pushKV("pooledtx", (uint64_t)mempool.size());

    obj.pushKV("difficulty", difficulty);

    obj.pushKV("search-interval", (int)lastCoinStakeSearchInterval);
    obj.pushKV("weight", (uint64_t)nWeight);
    obj.pushKV("weight_cached", weight_cached);
    obj.pushKV("weight_cache_height", weight_cache_height);
    obj.pushKV("netstakeweight", (uint64_t)nNetworkWeight);
    obj.pushKV("expectedtime", nExpectedTime);
    obj.pushKV("chainstate_cached", chainstate_cached);

    obj.pushKV("chain", chainman.GetParams().GetChainTypeString());
    obj.pushKV("warnings", GetWarnings(false).original);
    return obj;
},
    };
}

static RPCHelpMan staking()
{
    return RPCHelpMan{"staking",
            "Gets or sets the current staking configuration.\n"
            "When called without an argument, returns the current status of staking.\n"
            "When called with an argument, enables or disables staking.\n"
            "This changes the current loaded-wallet staking state only. Use -autostartstaking=1 for process-wide persistent consent to start staking for every eligible wallet loaded by this process. An explicitly configured legacy -staking=1 remains upgrade-compatible autostart consent unless -autostartstaking is set separately; an implicit default does not.\n"
            "Automatic QQSIGNAL is independently opt-in with -qqautoshadowsignal=1. Configure -qqpospayoutaddress with an existing backed-up wallet-owned ordinary direct quantum address, or separately consent to non-HD key creation with -qqallowautokeycreation=1.\n"
            "Optional wallet demurrage attestations are independently opt-in with -qqautodemurrageattest=1. Mandatory consensus demurrage and burn are automatic after Final activation and cannot be disabled here.\n",
            {
                {"generate", RPCArg::Type::BOOL, RPCArg::Optional::OMITTED, "To enable or disable staking."},

            },
            RPCResult{
                RPCResult::Type::OBJ, "", "",
                {
                    {RPCResult::Type::BOOL, "staking", "if staking is active or not. false: inactive, true: active"},
                }
            },
            RPCExamples{
                HelpExampleCli("staking", "true")
                + HelpExampleRpc("staking", "true")
            },
            [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    std::string error = "";
    if (request.params.size() > 0)
    {
        if (request.params[0].get_bool() && node::CanStake())
        {
            if (pwallet->IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)) {
                error = "The wallet can't contain any private keys";
            } else if (pwallet->IsWalletFlagSet(WALLET_FLAG_BLANK_WALLET)) {
                error = "The wallet is blank";
            }
            if (!pwallet->m_enabled_staking)
                StartStake(*pwallet);
        }
        else {
            StopStake(*pwallet);
        }
    }

    UniValue result(UniValue::VOBJ);
    result.pushKV("staking", pwallet->m_enabled_staking.load());
    if (!error.empty()) {
        result.pushKV("error", error);
    }
    return result;
},
    };
}

static RPCHelpMan reservebalance()
{
    return RPCHelpMan{"reservebalance",
            "\nSet reserve amount not participating in network protection."
            "\nIf no parameters provided current setting is printed.\n",
            {
                {"reserve", RPCArg::Type::BOOL, RPCArg::Optional::OMITTED,"is true or false to turn balance reserve on or off."},
                {"amount", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "is a real and rounded to cent."},
            },
            RPCResult{
                RPCResult::Type::OBJ, "", "",
                {
                    {RPCResult::Type::BOOL, "reserve", "Balance reserve on or off"},
                    {RPCResult::Type::STR_AMOUNT, "amount", "Amount reserve rounded to cent"}
                }
            },
             RPCExamples{
            "\nSet reserve balance to 100\n"
            + HelpExampleCli("reservebalance", "true 100") +
            "\nSet reserve balance to 0\n"
            + HelpExampleCli("reservebalance", "false") +
            "\nGet reserve balance\n"
            + HelpExampleCli("reservebalance", "")			},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    LOCK(pwallet->cs_wallet);
    if (request.params.size() > 0)
    {
        bool fReserve = request.params[0].get_bool();
        if (fReserve)
        {
            if (request.params.size() == 1)
                throw std::runtime_error("must provide amount to reserve balance.\n");
            int64_t nAmount = AmountFromValue(request.params[1]);
            nAmount = (nAmount / CENT) * CENT;  // round to cent
            if (nAmount < 0)
                throw std::runtime_error("amount cannot be negative.\n");
            pwallet->m_reserve_balance = nAmount;
        }
        else
        {
            if (request.params.size() > 1)
                throw std::runtime_error("cannot specify amount to turn off reserve.\n");
            pwallet->m_reserve_balance = 0;
        }
    }

    UniValue result(UniValue::VOBJ);
    result.pushKV("reserve", (pwallet->m_reserve_balance > 0));
    result.pushKV("amount", ValueFromAmount(pwallet->m_reserve_balance));
    return result;
},
    };
}

static RPCHelpMan getstakingdonationinfo()
{
    return RPCHelpMan{"getstakingdonationinfo",
        "\nReturns the permanently retired legacy staking-donation state.\n",
        {},
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "retired", "Always true"},
            {RPCResult::Type::BOOL, "enabled", "Always false"},
            {RPCResult::Type::NUM, "percentage", "Always zero"},
            {RPCResult::Type::STR, "target_address", "Always empty"},
            {RPCResult::Type::STR, "note", "Operational note"},
        }},
        RPCExamples{HelpExampleCli("getstakingdonationinfo", "")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    return RetiredStakingDonationInfoToJSON();
},
    };
}

static RPCHelpMan setstakingdonation()
{
    return RPCHelpMan{"setstakingdonation",
        "\nRetired compatibility command. Only 0 is accepted; nonzero legacy payments cannot be re-enabled.\n",
        {
            {"percentage", RPCArg::Type::NUM, RPCArg::Optional::NO, "Must be 0."},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "retired", "Always true"},
            {RPCResult::Type::BOOL, "enabled", "Always false"},
            {RPCResult::Type::NUM, "percentage", "Always zero"},
            {RPCResult::Type::STR, "target_address", "Always empty"},
            {RPCResult::Type::STR, "note", "Operational note"},
        }},
        RPCExamples{
            HelpExampleCli("setstakingdonation", "0")
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    int64_t percentage_signed{0};
    if (!ParseInt64(request.params[0].getValStr(), &percentage_signed)) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "percentage must be an integer");
    }
    if (percentage_signed != 0) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "legacy development-fund payments are retired and cannot be enabled; use setqqdevelopmentdonation with fresh recipient-bound consent");
    }
    return RetiredStakingDonationInfoToJSON();
},
    };
}

static RPCHelpMan getqqdevelopmentdonationinfo()
{
    return RPCHelpMan{"getqqdevelopmentdonationinfo",
        "\nReturns fresh wallet-scoped Quantum Quasar development-donation consent and its effective state.\n",
        {},
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "enabled", "true only when exact current consent is effective"},
            {RPCResult::Type::NUM, "percentage", "Effective percentage, or zero when fail-closed"},
            {RPCResult::Type::NUM, "stored_percentage", "Percentage in the persisted choice"},
            {RPCResult::Type::BOOL, "choice_recorded", "Whether this wallet has a fresh recorded choice"},
            {RPCResult::Type::STR, "network", "Current network"},
            {RPCResult::Type::STR, "recipient", "Current approved direct quantum recipient"},
            {RPCResult::Type::STR, "consent_network", "Network bound in persisted consent"},
            {RPCResult::Type::STR, "consent_recipient", "Recipient bound in persisted consent"},
            {RPCResult::Type::BOOL, "consent_matches_current", "Whether persisted network and recipient match this build"},
            {RPCResult::Type::BOOL, "reauthorization_required", "Whether a previously enabled choice is stale"},
            {RPCResult::Type::BOOL, "database_outcome_ambiguous", "Whether donation is latched off pending reload"},
            {RPCResult::Type::NUM, "minimum_percentage", "Minimum percentage"},
            {RPCResult::Type::NUM, "maximum_percentage", "Maximum percentage"},
            {RPCResult::Type::NUM, "default_percentage", "Default percentage"},
            {RPCResult::Type::STR, "note", "Operational note"},
        }},
        RPCExamples{HelpExampleCli("getqqdevelopmentdonationinfo", "")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    return QQDevelopmentDonationInfoToJSON(*pwallet);
},
    };
}

static RPCHelpMan setqqdevelopmentdonation()
{
    return RPCHelpMan{"setqqdevelopmentdonation",
        "\nDurably records a fresh wallet-scoped choice bound to the exact current network, recipient, and percentage. Use 0 with the same recipient to opt out.\n",
        {
            {"percentage", RPCArg::Type::NUM, RPCArg::Optional::NO, "Percentage from 0 to 95."},
            {"recipient", RPCArg::Type::STR, RPCArg::Optional::NO, "Exact recipient returned by getqqdevelopmentdonationinfo."},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "enabled", "Effective donation state"},
            {RPCResult::Type::NUM, "percentage", "Effective percentage"},
            {RPCResult::Type::NUM, "stored_percentage", "Percentage in the persisted choice"},
            {RPCResult::Type::BOOL, "choice_recorded", "Whether this wallet has a fresh recorded choice"},
            {RPCResult::Type::STR, "network", "Current network"},
            {RPCResult::Type::STR, "recipient", "Approved direct quantum recipient"},
            {RPCResult::Type::STR, "consent_network", "Network bound in persisted consent"},
            {RPCResult::Type::STR, "consent_recipient", "Recipient bound in persisted consent"},
            {RPCResult::Type::BOOL, "consent_matches_current", "Whether the new consent matches this build"},
            {RPCResult::Type::BOOL, "reauthorization_required", "Whether a previously enabled choice is stale"},
            {RPCResult::Type::BOOL, "database_outcome_ambiguous", "Whether donation is latched off pending reload"},
            {RPCResult::Type::NUM, "minimum_percentage", "Minimum percentage"},
            {RPCResult::Type::NUM, "maximum_percentage", "Maximum percentage"},
            {RPCResult::Type::NUM, "default_percentage", "Default percentage"},
            {RPCResult::Type::STR, "note", "Operational note"},
        }},
        RPCExamples{
            HelpExampleCli("setqqdevelopmentdonation", "5 \"quantum_recipient_from_getqqdevelopmentdonationinfo\"") +
            HelpExampleCli("setqqdevelopmentdonation", "0 \"quantum_recipient_from_getqqdevelopmentdonationinfo\"")
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    int64_t percentage{0};
    if (!ParseInt64(request.params[0].getValStr(), &percentage)) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "percentage must be an integer");
    }
    if (percentage < MIN_QQ_DEVELOPMENT_DONATION_PERCENTAGE ||
        percentage > MAX_QQ_DEVELOPMENT_DONATION_PERCENTAGE) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf(
            "percentage must be between %u and %u",
            MIN_QQ_DEVELOPMENT_DONATION_PERCENTAGE,
            MAX_QQ_DEVELOPMENT_DONATION_PERCENTAGE));
    }
    bilingual_str error;
    if (!pwallet->SetQQDevelopmentDonationConsent(
            static_cast<unsigned int>(percentage),
            request.params[1].get_str(), error)) {
        throw JSONRPCError(RPC_WALLET_ERROR, error.original);
    }
    return QQDevelopmentDonationInfoToJSON(*pwallet);
},
    };
}

static RPCHelpMan getquantumstakeaddressinfo()
{
    return RPCHelpMan{"getquantumstakeaddressinfo",
        "\nReturns wallet-owned bonded quantum staking balance state for a staking address.\n",
        {
            {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet-backed bonded quantum staking address."},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", QuantumOperatorBondInfoResult()},
        RPCExamples{HelpExampleCli("getquantumstakeaddressinfo", "\"quantum_stake_address\"")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    return QuantumOperatorBondInfoToJSON(MakeWalletTieredStakeBondInfo(*pwallet, request.params[0].get_str(), /*require_operator_lock=*/false));
},
    };
}

static RPCHelpMan listquantumstakeoutputs()
{
    return RPCHelpMan{"listquantumstakeoutputs",
        "\nLists wallet-owned bonded, unbonding, and withdrawable quantum staking outputs for a staking address.\n",
        {
            {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet-backed bonded quantum staking address."},
        },
        RPCResult{RPCResult::Type::ARR, "", "", {
            {RPCResult::Type::OBJ, "", "", {
                {RPCResult::Type::STR_HEX, "txid", "Funding or unbonding transaction id"},
                {RPCResult::Type::NUM, "vout", "Output index"},
                {RPCResult::Type::STR, "address", "Staking address"},
                {RPCResult::Type::STR_AMOUNT, "amount", "Output amount"},
                {RPCResult::Type::NUM, "depth", "Confirmation depth"},
                {RPCResult::Type::STR, "state", "bonded, unbonding, or withdrawable"},
                {RPCResult::Type::NUM, "unlock_height", "Unlock height for unbonding outputs"},
                {RPCResult::Type::BOOL, "spendable", "true if wallet can currently spend this output"},
            }},
        }},
        RPCExamples{HelpExampleCli("listquantumstakeoutputs", "\"quantum_stake_address\"")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    return QuantumStakeOutputsToJSON(ListTieredStakeOutputs(*pwallet, request.params[0].get_str(), /*require_operator_lock=*/false));
},
    };
}

static RPCHelpMan fundquantumstakeaddress()
{
    return RPCHelpMan{"fundquantumstakeaddress",
        "\nFunds a wallet-backed bonded quantum staking address from direct quantum wallet coins.\n"
        "Transaction construction creates a new non-HD ML-DSA change key that is not seed-recoverable; back up the wallet after this command succeeds.\n" + HELP_REQUIRING_PASSPHRASE,
        {
            {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet-backed bonded quantum staking address."},
            {"amount", RPCArg::Type::AMOUNT, RPCArg::Optional::NO, "Amount to bond."},
            {"options", RPCArg::Type::OBJ, RPCArg::Default{UniValue::VOBJ}, "Key-creation authorization.", {
                {"allow_new_quantum_key", RPCArg::Type::BOOL, RPCArg::Default{false}, "Explicitly authorize one new non-HD ML-DSA change key. Back up the wallet whenever the result or an error reports the created address; the durable key can remain after a later failure."},
            }},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", QuantumStakeTxResult()},
        RPCExamples{HelpExampleCli("fundquantumstakeaddress", "\"quantum_stake_address\" 10000 '{\"allow_new_quantum_key\":true}'")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    const UniValue options = request.params[2].isNull() ? UniValue(UniValue::VOBJ) : request.params[2].get_obj();
    const bool allow_new_quantum_key = RequireNewQuantumKeyConsent(options, "fundquantumstakeaddress");
    pwallet->BlockUntilSyncedToCurrentChain();

    return ThrowOrReturnQuantumStakeTx(FundTieredStakeAddress(
        *pwallet,
        request.params[0].get_str(),
        AmountFromValue(request.params[1]),
        /*require_operator_lock=*/false,
        "Blackcoin quantum staking address funding",
        allow_new_quantum_key));
},
    };
}

static RPCHelpMan withdrawquantumstakeaddress()
{
    return RPCHelpMan{"withdrawquantumstakeaddress",
        "\nStarts unbonding or withdraws matured quantum staking funds for a staking address.\n"
        "Both paths create a new non-HD ML-DSA key (change for unbonding or the withdrawal destination) that is not seed-recoverable; back up the wallet after this command succeeds.\n" + HELP_REQUIRING_PASSPHRASE,
        {
            {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet-backed bonded quantum staking address."},
            {"outpoint", RPCArg::Type::OBJ, RPCArg::Optional::OMITTED, "Optional single staking output to withdraw/unbond.", {
                {"txid", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Transaction id."},
                {"vout", RPCArg::Type::NUM, RPCArg::Optional::NO, "Output index."},
            }},
            {"options", RPCArg::Type::OBJ, RPCArg::Default{UniValue::VOBJ}, "Withdrawal options.", {
                {"all", RPCArg::Type::BOOL, RPCArg::Default{false}, "Permit acting on every spendable staking output for this address when no outpoint is specified."},
                {"allow_new_quantum_key", RPCArg::Type::BOOL, RPCArg::Default{false}, "Explicitly authorize one new non-HD ML-DSA change or withdrawal key. Back up the wallet whenever the result or an error reports the created address; the durable key can remain after a later failure."},
            }},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", QuantumStakeTxResult()},
        RPCExamples{
            HelpExampleCli("withdrawquantumstakeaddress", "\"quantum_stake_address\"")
          + HelpExampleCli("withdrawquantumstakeaddress", "\"quantum_stake_address\" '{\"txid\":\"<txid>\",\"vout\":0}'")
          + HelpExampleCli("withdrawquantumstakeaddress", "\"quantum_stake_address\" null '{\"all\":true,\"allow_new_quantum_key\":true}'")
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    pwallet->BlockUntilSyncedToCurrentChain();

    std::optional<COutPoint> outpoint;
    if (request.params.size() > 1 && !request.params[1].isNull()) outpoint = OutPointFromRPCOptions(request.params[1]);
    const UniValue options = request.params.size() > 2 ? request.params[2] : UniValue(UniValue::VNULL);
    const bool allow_all_outputs = ParseWithdrawAllOption(options);
    const bool allow_new_quantum_key = RequireNewQuantumKeyConsent(options, "withdrawquantumstakeaddress");
    return ThrowOrReturnQuantumStakeTx(WithdrawTieredStakeAddress(
        *pwallet,
        request.params[0].get_str(),
        /*require_operator_lock=*/false,
        "quantum-stake-unbonding",
        "quantum-stake-withdrawal",
        "Blackcoin quantum staking address unbond",
        "Blackcoin quantum staking address withdrawal",
        outpoint,
        allow_all_outputs,
        allow_new_quantum_key));
},
    };
}

static RPCHelpMan getquantumoperatorbondinfo()
{
    return RPCHelpMan{"getquantumoperatorbondinfo",
        "\nReturns wallet-owned operator bond state for a fixed 30-day cold-stake operator address.\n",
        {
            {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet-backed fixed 30-day cold-stake operator address."},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", QuantumOperatorBondInfoResult()},
        RPCExamples{HelpExampleCli("getquantumoperatorbondinfo", "\"operator_address\"")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    return QuantumOperatorBondInfoToJSON(MakeWalletOperatorBondInfo(*pwallet, request.params[0].get_str()));
},
    };
}

static RPCHelpMan getwalletquantumpoolinfo()
{
    return RPCHelpMan{"getwalletquantumpoolinfo",
        "\nReturn wallet-aware Quantum Cold-Stake pool share information.\n"
        "\nUnlike node-level getquantumpoolinfo, this wallet RPC first scans this loaded wallet\n"
        "for locally-owned operator bonds and cold-stake delegation claims, verifies them\n"
        "against active chainstate, and publishes the verified local data into the node's\n"
        "non-consensus discovery registry before reporting pool shares.\n",
        {},
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "available", "Whether chainstate was available."},
            {RPCResult::Type::STR_AMOUNT, "total_coldstake", "Total live cold-stake UTXO value in chainstate."},
            {RPCResult::Type::NUM, "cap_bps", "Wallet/policy cap in basis points."},
            {RPCResult::Type::NUM, "local_operator_bond_candidates", "Wallet-owned bonded node outputs scanned."},
            {RPCResult::Type::NUM, "local_operator_bonds_verified", "Wallet-owned bonded node outputs verified on chain."},
            {RPCResult::Type::NUM, "local_claim_groups", "Wallet-owned delegation claim groups published by staker hash."},
            {RPCResult::Type::NUM, "operator_count", "Operators reported after local publish/verify."},
            {RPCResult::Type::ARR, "operators", "Operator share entries.", {
                {RPCResult::Type::OBJ, "", "", {
                    {RPCResult::Type::STR_HEX, "staking_pubkey_hash", "SHA256(staking_pubkey)."},
                    {RPCResult::Type::STR_HEX, "staking_pubkey", /*optional=*/true, "Operator/staker ML-DSA public key."},
                    {RPCResult::Type::STR_AMOUNT, "verified_value", "Verified live value claimed by this operator."},
                    {RPCResult::Type::NUM, "share_bps", "Verified share of cold-staked value in basis points."},
                    {RPCResult::Type::NUM, "verified_claims", "Number of accepted claim UTXOs."},
                    {RPCResult::Type::NUM, "invalid_claims", "Number of rejected claim UTXOs."},
                    {RPCResult::Type::BOOL, "operator_commitment_verified", "Whether this operator has a live 40,500-block bonded self-stake proof."},
                    {RPCResult::Type::BOOL, "over_cap", "Whether the verified current share is over the wallet/policy cap."},
                }},
            }},
        }},
        RPCExamples{HelpExampleCli("getwalletquantumpoolinfo", "")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    if (!pwallet->HaveChain()) {
        UniValue unavailable(UniValue::VOBJ);
        unavailable.pushKV("available", false);
        unavailable.pushKV("total_coldstake", ValueFromAmount(0));
        unavailable.pushKV("cap_bps", node::QUANTUM_POOL_CAP_BPS);
        unavailable.pushKV("local_operator_bond_candidates", 0);
        unavailable.pushKV("local_operator_bonds_verified", 0);
        unavailable.pushKV("local_claim_groups", 0);
        unavailable.pushKV("operator_count", 0);
        unavailable.pushKV("operators", UniValue(UniValue::VARR));
        return unavailable;
    }

    const std::vector<RpcLocalOperatorBondCandidate> local_operator_bonds =
        FindRpcWalletOperatorBondCandidates(*pwallet);
    const std::map<uint256, std::vector<node::QuantumPoolClaim>> local_claims =
        FindRpcWalletQuantumPoolClaims(*pwallet);

    LOCK(cs_main);
    ChainstateManager& chainman = pwallet->chain().chainman();
    const CCoinsViewCache& view = chainman.ActiveChainstate().CoinsTip();
    const CAmount total = node::ComputeQuantumColdStakeTotal(view);

    for (const auto& [staker_hash, claims] : local_claims) {
        node::UpsertQuantumPoolClaims(staker_hash, claims);
    }

    int verified_local_bonds{0};
    for (const RpcLocalOperatorBondCandidate& candidate : local_operator_bonds) {
        if (!node::VerifyQuantumPoolOperatorCommitment(view, candidate.staking_pubkey, candidate.outpoint)) {
            continue;
        }
        ++verified_local_bonds;
        const uint256 staker_hash = node::QuantumPoolHashPubKey(candidate.staking_pubkey);
        node::UpsertQuantumPoolOperator(
            staker_hash,
            candidate.staking_pubkey,
            node::GetQuantumPoolClaims(staker_hash),
            /*operator_commitment_verified=*/true,
            candidate.outpoint);
    }

    UniValue entries(UniValue::VARR);
    for (const uint256& staker_hash : node::ListQuantumPoolOperators()) {
        const node::QuantumPoolShare share = node::ComputeQuantumPoolShare(view, staker_hash, node::GetQuantumPoolClaims(staker_hash));
        entries.push_back(QuantumPoolOperatorToJSON(share));
    }

    UniValue obj(UniValue::VOBJ);
    obj.pushKV("available", true);
    obj.pushKV("total_coldstake", ValueFromAmount(total));
    obj.pushKV("cap_bps", node::QUANTUM_POOL_CAP_BPS);
    obj.pushKV("local_operator_bond_candidates", static_cast<int>(local_operator_bonds.size()));
    obj.pushKV("local_operator_bonds_verified", verified_local_bonds);
    obj.pushKV("local_claim_groups", static_cast<int>(local_claims.size()));
    obj.pushKV("operator_count", entries.size());
    obj.pushKV("operators", std::move(entries));
    return obj;
},
    };
}

static RPCHelpMan fundquantumoperatorbond()
{
    return RPCHelpMan{"fundquantumoperatorbond",
        "\nFunds a fixed 30-day cold-stake operator bond from wallet coins eligible for quantum staking.\n"
        "Transaction construction creates a new non-HD ML-DSA change key that is not seed-recoverable; back up the wallet after this command succeeds.\n" + HELP_REQUIRING_PASSPHRASE,
        {
            {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet-backed fixed 30-day cold-stake operator address."},
            {"amount", RPCArg::Type::AMOUNT, RPCArg::Optional::NO, "Amount to bond."},
            {"options", RPCArg::Type::OBJ, RPCArg::Default{UniValue::VOBJ}, "Key-creation authorization.", {
                {"allow_new_quantum_key", RPCArg::Type::BOOL, RPCArg::Default{false}, "Explicitly authorize one new non-HD ML-DSA change key. Back up the wallet whenever the result or an error reports the created address; the durable key can remain after a later failure."},
            }},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", QuantumStakeTxResult()},
        RPCExamples{HelpExampleCli("fundquantumoperatorbond", "\"operator_address\" 10000 '{\"allow_new_quantum_key\":true}'")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    const UniValue options = request.params[2].isNull() ? UniValue(UniValue::VOBJ) : request.params[2].get_obj();
    const bool allow_new_quantum_key = RequireNewQuantumKeyConsent(options, "fundquantumoperatorbond");
    pwallet->BlockUntilSyncedToCurrentChain();

    return ThrowOrReturnQuantumStakeTx(FundTieredStakeAddress(
        *pwallet,
        request.params[0].get_str(),
        AmountFromValue(request.params[1]),
        /*require_operator_lock=*/true,
        "Blackcoin cold-stake operator bond",
        allow_new_quantum_key));
},
    };
}

static RPCHelpMan withdrawquantumoperatorbond()
{
    return RPCHelpMan{"withdrawquantumoperatorbond",
        "\nStarts unbonding or withdraws matured cold-stake operator bond funds.\n"
        "Both paths create a new non-HD ML-DSA key (change for unbonding or the withdrawal destination) that is not seed-recoverable; back up the wallet after this command succeeds.\n" + HELP_REQUIRING_PASSPHRASE,
        {
            {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet-backed fixed 30-day cold-stake operator address."},
            {"outpoint", RPCArg::Type::OBJ, RPCArg::Optional::OMITTED, "Optional single operator bond output to withdraw/unbond.", {
                {"txid", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Transaction id."},
                {"vout", RPCArg::Type::NUM, RPCArg::Optional::NO, "Output index."},
            }},
            {"options", RPCArg::Type::OBJ, RPCArg::Default{UniValue::VOBJ}, "Withdrawal options.", {
                {"all", RPCArg::Type::BOOL, RPCArg::Default{false}, "Permit acting on every spendable operator bond output for this address when no outpoint is specified."},
                {"allow_new_quantum_key", RPCArg::Type::BOOL, RPCArg::Default{false}, "Explicitly authorize one new non-HD ML-DSA change or withdrawal key. Back up the wallet whenever the result or an error reports the created address; the durable key can remain after a later failure."},
            }},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", QuantumStakeTxResult()},
        RPCExamples{
            HelpExampleCli("withdrawquantumoperatorbond", "\"operator_address\"")
          + HelpExampleCli("withdrawquantumoperatorbond", "\"operator_address\" '{\"txid\":\"<txid>\",\"vout\":0}'")
          + HelpExampleCli("withdrawquantumoperatorbond", "\"operator_address\" null '{\"all\":true,\"allow_new_quantum_key\":true}'")
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    pwallet->BlockUntilSyncedToCurrentChain();

    std::optional<COutPoint> outpoint;
    if (request.params.size() > 1 && !request.params[1].isNull()) outpoint = OutPointFromRPCOptions(request.params[1]);
    const UniValue options = request.params.size() > 2 ? request.params[2] : UniValue(UniValue::VNULL);
    const bool allow_all_outputs = ParseWithdrawAllOption(options);
    const bool allow_new_quantum_key = RequireNewQuantumKeyConsent(options, "withdrawquantumoperatorbond");
    return ThrowOrReturnQuantumStakeTx(WithdrawTieredStakeAddress(
        *pwallet,
        request.params[0].get_str(),
        /*require_operator_lock=*/true,
        "coldstake-operator-unbonding",
        "coldstake-operator-withdrawal",
        "Blackcoin cold-stake operator unbond",
        "Blackcoin cold-stake operator withdrawal",
        outpoint,
        allow_all_outputs,
        allow_new_quantum_key));
},
    };
}

static RPCHelpMan getquantumcoldstakebalance()
{
    return RPCHelpMan{"getquantumcoldstakebalance",
        "\nReturns wallet-owned balance state for a quantum cold-stake delegation address.\n",
        {
            {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet-backed quantum cold-stake delegation address."},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "available", "false if wallet state could not be locked"},
            {RPCResult::Type::BOOL, "valid_delegation_address", "true if this is a wallet-backed cold-stake delegation address"},
            {RPCResult::Type::NUM, "current_height", "Wallet chain height"},
            {RPCResult::Type::STR_AMOUNT, "amount", "Total delegated amount"},
            {RPCResult::Type::NUM, "outputs", "Total delegation outputs"},
            {RPCResult::Type::STR_AMOUNT, "confirmed_amount", "Confirmed delegated amount"},
            {RPCResult::Type::NUM, "confirmed_outputs", "Confirmed delegation outputs"},
            {RPCResult::Type::STR_AMOUNT, "unconfirmed_amount", "Unconfirmed delegated amount"},
            {RPCResult::Type::NUM, "unconfirmed_outputs", "Unconfirmed delegation outputs"},
            {RPCResult::Type::STR_AMOUNT, "spendable_amount", "Currently spendable delegated amount"},
            {RPCResult::Type::NUM, "spendable_outputs", "Currently spendable delegation outputs"},
        }},
        RPCExamples{HelpExampleCli("getquantumcoldstakebalance", "\"coldstake_delegation_address\"")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    return QuantumColdStakeBalanceToJSON(MakeWalletColdStakeBalanceInfo(*pwallet, request.params[0].get_str()));
},
    };
}

static RPCHelpMan fundquantumcoldstakeaddress()
{
    return RPCHelpMan{"fundquantumcoldstakeaddress",
        "\nFunds a quantum cold-stake delegation address from direct quantum funds.\n"
        "Mature Gold Rush payouts are ordinary direct quantum funds after Gold Rush; no preliminary move or remigration is required.\n"
        "Transaction construction creates a new non-HD ML-DSA change key that is not seed-recoverable; back up the wallet after this command succeeds.\n"
        "The options.allow_goldrush_migration field is retained for compatibility and has no effect.\n" +
        HELP_REQUIRING_PASSPHRASE,
        {
            {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet-backed quantum cold-stake delegation address."},
            {"amount", RPCArg::Type::AMOUNT, RPCArg::Optional::NO, "Amount to delegate."},
            {"options", RPCArg::Type::OBJ, RPCArg::Default{UniValue::VOBJ}, "Delegation funding options.", {
                {"allow_goldrush_migration", RPCArg::Type::BOOL, RPCArg::Default{true}, "Deprecated compatibility field; ignored."},
                {"allow_new_quantum_key", RPCArg::Type::BOOL, RPCArg::Default{false}, "Explicitly authorize one new non-HD ML-DSA change key. Back up the wallet whenever the result or an error reports the created address; the durable key can remain after a later failure."},
            }},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", QuantumStakeTxResult()},
        RPCExamples{
            HelpExampleCli("fundquantumcoldstakeaddress", "\"coldstake_delegation_address\" 1000 '{\"allow_new_quantum_key\":true}'")
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    pwallet->BlockUntilSyncedToCurrentChain();

    const UniValue options = request.params[2].isNull() ? UniValue(UniValue::VOBJ) : request.params[2].get_obj();
    const bool allow_goldrush_migration = !options.exists("allow_goldrush_migration") || options["allow_goldrush_migration"].get_bool();
    const bool allow_new_quantum_key = RequireNewQuantumKeyConsent(options, "fundquantumcoldstakeaddress");

    return ThrowOrReturnQuantumStakeTx(FundColdStakeDelegationAddress(
        *pwallet,
        request.params[0].get_str(),
        AmountFromValue(request.params[1]),
        allow_goldrush_migration,
        allow_new_quantum_key));
},
    };
}

static RPCHelpMan withdrawquantumcoldstakeaddress()
{
    return RPCHelpMan{"withdrawquantumcoldstakeaddress",
        "\nStarts unbonding or withdraws matured funds from a quantum cold-stake delegation address.\n"
        "Both paths create a new non-HD ML-DSA key (change for unbonding or the withdrawal destination) that is not seed-recoverable; back up the wallet after this command succeeds.\n" + HELP_REQUIRING_PASSPHRASE,
        {
            {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet-backed quantum cold-stake delegation address."},
            {"outpoint", RPCArg::Type::OBJ, RPCArg::Optional::OMITTED, "Optional single delegation output to withdraw/unbond.", {
                {"txid", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Transaction id."},
                {"vout", RPCArg::Type::NUM, RPCArg::Optional::NO, "Output index."},
            }},
            {"options", RPCArg::Type::OBJ, RPCArg::Default{UniValue::VOBJ}, "Withdrawal options.", {
                {"all", RPCArg::Type::BOOL, RPCArg::Default{false}, "Permit acting on every spendable delegation output for this address when no outpoint is specified."},
                {"allow_new_quantum_key", RPCArg::Type::BOOL, RPCArg::Default{false}, "Explicitly authorize one new non-HD ML-DSA change or withdrawal key. Back up the wallet whenever the result or an error reports the created address; the durable key can remain after a later failure."},
            }},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", QuantumStakeTxResult()},
        RPCExamples{
            HelpExampleCli("withdrawquantumcoldstakeaddress", "\"coldstake_delegation_address\"")
          + HelpExampleCli("withdrawquantumcoldstakeaddress", "\"coldstake_delegation_address\" '{\"txid\":\"<txid>\",\"vout\":0}'")
          + HelpExampleCli("withdrawquantumcoldstakeaddress", "\"coldstake_delegation_address\" null '{\"all\":true,\"allow_new_quantum_key\":true}'")
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    pwallet->BlockUntilSyncedToCurrentChain();

    std::optional<COutPoint> outpoint;
    if (request.params.size() > 1 && !request.params[1].isNull()) outpoint = OutPointFromRPCOptions(request.params[1]);
    const UniValue options = request.params.size() > 2 ? request.params[2] : UniValue(UniValue::VNULL);
    const bool allow_all_outputs = ParseWithdrawAllOption(options);
    const bool allow_new_quantum_key = RequireNewQuantumKeyConsent(options, "withdrawquantumcoldstakeaddress");
    return ThrowOrReturnQuantumStakeTx(WithdrawColdStakeDelegationAddress(*pwallet, request.params[0].get_str(), outpoint, allow_all_outputs, allow_new_quantum_key));
},
    };
}

static RPCHelpMan sendshadowsignal()
{
    return RPCHelpMan{"sendshadowsignal",
                "\nBroadcast a Blackcoin Gold Rush activity signal for a whitelisted address that solved a block in the last 14 days.\n"
                "The transaction spends one wallet UTXO from the signaling address, pays change back to the same address, and attaches the QQSIGNAL payload.\n"
                "The signal links the whitelisted legacy address to the required quantum migration payout address.\n"
                "Consensus counts this signal only if the referenced solve has a deterministic solver marker and the signal is mined inside the 14-day activity window.\n" +
                HELP_REQUIRING_PASSPHRASE,
                {
                    {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet address whose aggregate snapshot balance qualified for the shadow whitelist."},
                    {"solve_height", RPCArg::Type::NUM, RPCArg::Optional::NO, "Height of a block solved by this address within the last 14 days."},
                    {"solve_hash", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Hash of the solved block at solve_height."},
                    {"quantum_address", RPCArg::Type::STR, RPCArg::Optional::NO, "Quantum migration address that should receive this address's Gold Rush shadow-ledger credit."},
                    {"fee_rate", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Optional fee rate in " + CURRENCY_ATOM + "/vB. Must not be below the wallet minimum fee rate."},
                },
                RPCResult{
                    RPCResult::Type::OBJ, "", "",
                    {
                        {RPCResult::Type::STR_HEX, "txid", "The broadcast signal transaction id."},
                        {RPCResult::Type::STR_HEX, "hex", "The signed signal transaction hex."},
                        {RPCResult::Type::STR_AMOUNT, "fee", "The fee paid by the signal transaction."},
                        {RPCResult::Type::STR_AMOUNT, "change", "The amount paid back to the signaling address."},
                        {RPCResult::Type::NUM, "vsize", "Estimated virtual transaction size used for fee calculation."},
                        {RPCResult::Type::STR, "address", "The signaling address."},
                        {RPCResult::Type::STR, "quantum_address", "The linked quantum migration payout address."},
                        {RPCResult::Type::NUM, "solve_height", "The referenced solved block height."},
                        {RPCResult::Type::STR_HEX, "solve_hash", "The referenced solved block hash."},
                    }
                },
                RPCExamples{
                    HelpExampleCli("sendshadowsignal", "\"" + EXAMPLE_ADDRESS[0] + "\" 5921234 \"0000000000000000000000000000000000000000000000000000000000000001\" \"quantum_address\"")
            + HelpExampleCli("-named sendshadowsignal", "address=\"" + EXAMPLE_ADDRESS[0] + "\" solve_height=5921234 solve_hash=\"0000000000000000000000000000000000000000000000000000000000000001\" quantum_address=\"quantum_address\" fee_rate=1")
                },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    ScopedDisallowShadowSolverActivityFullScan no_full_solver_scan;

    pwallet->BlockUntilSyncedToCurrentChain();
    EnsureWalletIsUnlocked(*pwallet);
    if (pwallet->IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Error: Private keys are disabled for this wallet");
    }
    if (pwallet->m_wallet_unlock_staking_only) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Error: Wallet unlocked for staking only, unable to create signal transaction");
    }

    const std::string address = request.params[0].get_str();
    const CTxDestination dest = DecodeDestination(address);
    if (!IsValidDestination(dest)) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Invalid Blackcoin address");
    }
    const CScript target = GetScriptForDestination(dest);
    if (target.empty() || target.IsUnspendable()) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Address does not resolve to a signalable script");
    }

    const int64_t solve_height_signed = request.params[1].getInt<int64_t>();
    if (solve_height_signed <= 0 || solve_height_signed > std::numeric_limits<uint32_t>::max()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "solve_height out of range");
    }
    const uint32_t solve_height = static_cast<uint32_t>(solve_height_signed);
    const uint256 solve_hash = ParseHashV(request.params[2], "solve_hash");
    CScript quantum_payout_script;
    const std::string quantum_address = request.params[3].get_str();
    const CTxDestination quantum_dest = DecodeDestination(quantum_address);
    if (!IsValidDestination(quantum_dest) || !IsQuantumMigrationDestination(quantum_dest)) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "quantum_address must be a Blackcoin migration address");
    }
    quantum_payout_script = GetScriptForDestination(quantum_dest);
    if (!IsDirectQuantumMigrationScript(quantum_payout_script)) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "quantum_address must be an ordinary quantum receive address, not a bonded staking or cold-stake address");
    }

    {
        ChainstateManager& chainman = pwallet->chain().chainman();
        LOCK(cs_main);
        const CChain& active_chain = chainman.ActiveChain();
        const CBlockIndex* tip = active_chain.Tip();
        if (!tip) {
            throw JSONRPCError(RPC_CLIENT_NOT_CONNECTED, "No active chain tip");
        }
        const Consensus::Params& consensus = Params().GetConsensus();
        if (!IsShadowGoldRushRewardActive(consensus, tip->GetMedianTimePast(), tip->nHeight + 1)) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "Shadow signaling is only active during the Gold Rush epoch");
        }
        if (solve_height > static_cast<uint32_t>(tip->nHeight)) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "solve_height is above the active chain tip");
        }
        const CBlockIndex* solved = active_chain[solve_height];
        if (!solved || solved->GetBlockHash() != solve_hash) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "solve_hash does not match the active-chain block at solve_height");
        }
        if (tip->nHeight - static_cast<int>(solve_height) > SHADOW_SOLVER_ACTIVITY_WINDOW) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "referenced solve is outside the 14-day height window");
        }
        if (tip->GetBlockTime() - solved->GetBlockTime() > SHADOW_SOLVER_ACTIVITY_SECONDS) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "referenced solve is outside the 14-day time window");
        }
        if (tip->nHeight >= SHADOW_REWARD_START_HEIGHT) {
            if (!IsWhitelisted(chainman.ActiveChainstate().CoinsTip(), target)) {
                throw JSONRPCError(RPC_INVALID_PARAMETER, "address is not in the deterministic Gold Rush whitelist");
            }
            if (!HasRecentShadowSolverActivity(chainman.ActiveChainstate().CoinsTip(), tip, target, solve_height, solve_hash)) {
                throw JSONRPCError(RPC_INVALID_PARAMETER, "referenced solve is not an active Gold Rush solver marker for this address");
            }
            if (GetActiveShadowSignalPayouts(chainman.ActiveChainstate().CoinsTip(), tip).count(target)) {
                throw JSONRPCError(RPC_INVALID_PARAMETER, "address already has an active Gold Rush PoS signal");
            }
        }
    }

    std::vector<unsigned char> signal;
    const bool built_signal = BuildShadowSignalData(target, quantum_payout_script, solve_height, solve_hash, signal);
    if (!built_signal) {
        throw JSONRPCError(RPC_INTERNAL_ERROR, "Failed to build shadow signal payload");
    }

    CCoinControl coin_control;
    coin_control.destChange = dest;
    coin_control.m_allow_other_inputs = false;
    coin_control.m_avoid_address_reuse = false;
    if (!request.params[4].isNull()) {
        coin_control.m_feerate = FeeRateFromSatVbValue(request.params[4]);
        coin_control.fOverrideFeeRate = true;
    }

    {
        LOCK(pwallet->cs_wallet);
        if (HasUnconfirmedWalletShadowSignal(*pwallet)) {
            throw JSONRPCError(RPC_WALLET_ERROR, "wallet already has an unconfirmed Gold Rush PoS signal; wait for it to confirm before creating another");
        }
    }

    CMutableTransaction signal_tx;
    CAmount fee{0};
    CAmount change{0};
    int64_t vsize{-1};
    {
        LOCK2(::cs_main, pwallet->cs_wallet);
        const int64_t current_time = GetAdjustedTimeSeconds();
        const CFeeRate fee_rate = GetMinimumFeeRate(*pwallet, coin_control, current_time);
        if (coin_control.m_feerate && fee_rate > *coin_control.m_feerate) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("Fee rate (%s) is lower than the minimum fee rate setting (%s)", coin_control.m_feerate->ToString(FeeEstimateMode::SAT_VB), fee_rate.ToString(FeeEstimateMode::SAT_VB)));
        }
        for (const COutput& output : AvailableCoins(*pwallet, &coin_control).All()) {
            if (CanonicalizeLegacyStakeScript(output.txout.scriptPubKey) != target) continue;

            CMutableTransaction candidate;
            candidate.nVersion = CTransaction::CURRENT_VERSION;
            candidate.nTime = current_time;
            static constexpr uint32_t MAX_SEQUENCE_NONFINAL = 0xfffffffe;
            candidate.vin.emplace_back(output.outpoint, CScript(), MAX_SEQUENCE_NONFINAL);
            candidate.vout.emplace_back(output.txout.nValue, target);
            candidate.vout.emplace_back(0, CScript() << OP_RETURN << signal);

            const TxSize tx_size = CalculateMaximumSignedTxSize(CTransaction(candidate), pwallet.get(), &coin_control);
            if (tx_size.vsize <= 0) continue;
            const CAmount candidate_fee = std::max(GetMinFee(static_cast<size_t>(tx_size.vsize), static_cast<uint32_t>(current_time)), fee_rate.GetFee(static_cast<uint32_t>(tx_size.vsize)));
            const CAmount candidate_change = output.txout.nValue - candidate_fee;
            CTxOut change_out(candidate_change, target);
            if (!MoneyRange(candidate_change) || candidate_change <= 0 || IsDust(change_out, pwallet->chain().relayDustFee())) continue;
            if (candidate_fee > pwallet->m_default_max_tx_fee) {
                throw JSONRPCError(RPC_WALLET_ERROR, strprintf("Fee exceeds wallet max transaction fee (%s)", FormatMoney(pwallet->m_default_max_tx_fee)));
            }
            candidate.vout[0].nValue = candidate_change;
            std::map<int, bilingual_str> input_errors;
            if (!pwallet->SignTransaction(candidate, input_errors)) {
                if (!input_errors.empty()) {
                    throw JSONRPCError(RPC_WALLET_ERROR, strprintf("Signing signal transaction failed: %s", input_errors.begin()->second.original));
                }
                throw JSONRPCError(RPC_WALLET_ERROR, "Signing signal transaction failed");
            }

            signal_tx = std::move(candidate);
            fee = candidate_fee;
            change = candidate_change;
            vsize = tx_size.vsize;
            break;
        }
    }

    if (signal_tx.vin.empty()) {
        throw JSONRPCError(RPC_WALLET_INSUFFICIENT_FUNDS, "No spendable non-dust UTXO found for the signaling address");
    }

    CTransactionRef tx = MakeTransactionRef(std::move(signal_tx));
    const std::string hex = EncodeHexTx(*tx);
    mapValue_t map_value;
    map_value["comment"] = "PoS Claim";
    map_value["qq_shadow_signal_source"] = "manual";
    CommitWalletTransactionOrThrow(*pwallet, tx, std::move(map_value), "PoS Claim");

    UniValue result(UniValue::VOBJ);
    result.pushKV("txid", tx->GetHash().GetHex());
    result.pushKV("hex", hex);
    result.pushKV("fee", ValueFromAmount(fee));
    result.pushKV("change", ValueFromAmount(change));
    result.pushKV("vsize", vsize);
    result.pushKV("address", address);
    result.pushKV("quantum_address", quantum_address);
    result.pushKV("solve_height", solve_height);
    result.pushKV("solve_hash", solve_hash.GetHex());
    return result;
},
    };
}

static RPCHelpMan sendshadowpowclaim()
{
    return RPCHelpMan{"sendshadowpowclaim",
                "\nGrind or submit an Argon2id Blackcoin shadow PoW proof and broadcast the claim transaction.\n"
                "The transaction spends one wallet UTXO from the target legacy address, pays change back to the same address, and attaches the QQSPROOF payload.\n"
                "PoW claims are NOT whitelist-gated. A valid mined claim credits the upgraded shadow ledger to quantum_address without changing the legacy block subsidy.\n"
                "If proof is omitted, grinding is memory-hard (Argon2id, ~1 MiB per try) and synchronous; tune max_tries accordingly.\n"
                "If proof is supplied, it must be the hex QQSPROOF payload for the current tip, target address, and quantum payout address.\n"
                "The active proof format is reported by getshadowpowwork. QQP2/QQP3 do not bind an exact fee input; QQP4 does so only after its separately scheduled activation. Never reuse one externally supplied proof for multiple claim transactions.\n"
                "Only valid during the Gold Rush reward window. An unconfirmed wallet-authored QQSPROOF absent from the local mempool remains quarantined because a peer may still confirm it. The typed, active-tip-pinned gate validates each wallet-owned same-anchor family. Within one family a live member blocks a competing sibling; across independent safe families Core relays eligible absent bytes first, then refreshes one family. If every safe retained family is snapshot-deferred, Core reserves each family anchor and may create one claim from a proven-independent confirmed coin. Audit-only incoming proofs do not gain mining authority; any wallet-owned unsafe component still fails closed.\n"
                "When retained bytes are selected for relay, address and quantum_address must match that authenticated family. With multiple retained relayable families, getpowmininginfo.mining_gate_relay_txid identifies the one deterministic next relay; a request naming another family fails without a side effect until earlier work is serviced. max_tries and fee_rate are not applied because no transaction is created or repriced, and an external proof is rejected because it cannot replace the retained transaction's committed proof. Success means local mempool acceptance plus a relay attempt; it does not prove peer receipt or confirmation.\n" +
                HELP_REQUIRING_PASSPHRASE,
                {
                    {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet legacy address that owns the UTXO authenticating this PoW claim. It does not need to be whitelisted."},
                    {"quantum_address", RPCArg::Type::STR, RPCArg::Optional::NO, "Quantum migration address that should receive this address's Gold Rush PoW shadow-ledger credit."},
                    {"max_tries", RPCArg::Type::NUM, RPCArg::Default{1000000}, "Maximum Argon2id nonces to grind before giving up. Ignored when proof is supplied."},
                    {"fee_rate", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Optional fee rate in " + CURRENCY_ATOM + "/vB."},
                    {"proof", RPCArg::Type::STR_HEX, RPCArg::Optional::OMITTED, "Optional externally mined QQSPROOF payload hex from getshadowpowwork parameters."},
                },
                RPCResults{
                    RPCResult{"when a new claim transaction is created", RPCResult::Type::OBJ, "", "", {
                        {RPCResult::Type::STR_HEX, "txid", "The broadcast claim transaction id."},
                        {RPCResult::Type::STR, "outcome", "Always created_new_claim."},
                        {RPCResult::Type::BOOL, "relayed_existing", "False when this call created a new claim transaction."},
                        {RPCResult::Type::BOOL, "created_new_claim", "True when this call created a new claim transaction."},
                        {RPCResult::Type::STR_HEX, "hex", "The signed claim transaction hex."},
                        {RPCResult::Type::STR_HEX, "proof", "The QQSPROOF payload committed by the transaction."},
                        {RPCResult::Type::STR, "proof_mode", "Always pow for a wallet-created fee-paying QQSPROOF claim."},
                        {RPCResult::Type::NUM, "proof_mode_byte", "Canonical PoW mode byte (0)."},
                        {RPCResult::Type::BOOL, "external_proof", "Whether the proof was supplied by the caller instead of ground by this RPC."},
                        {RPCResult::Type::STR_AMOUNT, "fee", "The fee paid by the claim transaction."},
                        {RPCResult::Type::STR_AMOUNT, "change", "The amount paid back to the target address."},
                        {RPCResult::Type::NUM, "vsize", "Estimated virtual transaction size."},
                        {RPCResult::Type::STR, "address", "The target legacy address."},
                        {RPCResult::Type::STR, "quantum_address", "The linked quantum migration payout address."},
                    }},
                    RPCResult{"when exact retained claim bytes are relayed", RPCResult::Type::OBJ, "", "", {
                        {RPCResult::Type::STR_HEX, "txid", "The exact retained claim transaction id accepted into the local mempool and submitted to the relay path."},
                        {RPCResult::Type::STR, "outcome", "Always relayed_existing."},
                        {RPCResult::Type::BOOL, "relayed_existing", "True when this call relayed existing wallet bytes."},
                        {RPCResult::Type::BOOL, "created_new_claim", "False because no new transaction or fee was created."},
                    }},
                },
                RPCExamples{
                    HelpExampleCli("sendshadowpowclaim", "\"" + EXAMPLE_ADDRESS[0] + "\" \"quantum_address\"")
            + HelpExampleCli("-named sendshadowpowclaim", "address=\"" + EXAMPLE_ADDRESS[0] + "\" quantum_address=\"quantum_address\" max_tries=2000000 fee_rate=1")
            + HelpExampleCli("-named sendshadowpowclaim", "address=\"" + EXAMPLE_ADDRESS[0] + "\" quantum_address=\"quantum_address\" proof=\"51515350524f4f46...\" fee_rate=1")
                },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    pwallet->BlockUntilSyncedToCurrentChain();
    EnsureWalletIsUnlocked(*pwallet);
    if (pwallet->IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Error: Private keys are disabled for this wallet");
    }
    if (pwallet->m_wallet_unlock_staking_only) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Error: Wallet unlocked for staking only, unable to create claim transaction");
    }
    const uint64_t expected_wallet_authority_generation = WITH_LOCK(
        pwallet->cs_wallet,
        if (!pwallet->HasNormalPowMiningWalletAuthorityLocked()) {
            throw JSONRPCError(
                RPC_WALLET_UNLOCK_NEEDED,
                "Error: Wallet requires a normal unlock to create a claim transaction");
        }
        return pwallet->m_pow_wallet_authority_generation.load(
            std::memory_order_acquire));
    if (!pwallet->chain().isReadyToBroadcast()) {
        throw JSONRPCError(RPC_CLIENT_IN_INITIAL_DOWNLOAD,
                           "Gold Rush PoW claims are paused while the node is reindexing, importing blocks, or in initial block download");
    }
    const std::string address = request.params[0].get_str();
    const CTxDestination dest = DecodeDestination(address);
    if (!IsValidDestination(dest)) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Invalid Blackcoin address");
    }
    const CScript target = GetScriptForDestination(dest);
    if (target.empty() || target.IsUnspendable() || IsQuantumMigrationScript(target) || IsQuantumColdStakeScript(target) || IsEUTXOScript(target)) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "address must be a spendable legacy script (not a quantum/EUTXO script)");
    }

    const std::string quantum_address = request.params[1].get_str();
    const CTxDestination quantum_dest = DecodeDestination(quantum_address);
    if (!IsValidDestination(quantum_dest) || !IsQuantumMigrationDestination(quantum_dest)) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "quantum_address must be a Blackcoin migration address");
    }
    const CScript quantum_payout_script = GetScriptForDestination(quantum_dest);
    if (!IsDirectQuantumMigrationScript(quantum_payout_script)) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "quantum_address must be an ordinary quantum receive address, not a bonded staking or cold-stake address");
    }

    std::optional<std::vector<unsigned char>> supplied_proof;
    if (!request.params[4].isNull()) {
        std::vector<unsigned char> parsed_proof = ParseHexV(request.params[4], "proof");
        const std::vector<unsigned char>& prefix = GetShadowPrefix();
        if (parsed_proof.size() <= prefix.size() ||
            parsed_proof.size() > MAX_SCRIPT_ELEMENT_SIZE ||
            !std::equal(prefix.begin(), prefix.end(), parsed_proof.begin())) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "proof must be a hex-encoded QQSPROOF payload");
        }
        supplied_proof = std::move(parsed_proof);
    }

    uint64_t max_tries = 1000000;
    if (!request.params[2].isNull()) {
        const int64_t mt = request.params[2].getInt<int64_t>();
        if (mt <= 0) {
            if (!supplied_proof) throw JSONRPCError(RPC_INVALID_PARAMETER, "max_tries must be positive");
        } else {
            max_tries = static_cast<uint64_t>(mt);
        }
    }

    CCoinControl coin_control;
    coin_control.destChange = dest;
    coin_control.m_allow_other_inputs = false;
    coin_control.m_avoid_address_reuse = false;
    coin_control.m_min_depth = 1;
    if (!request.params[3].isNull()) {
        coin_control.m_feerate = FeeRateFromSatVbValue(request.params[3]);
        coin_control.fOverrideFeeRate = true;
    }

    // Reserve the wallet's complete claim/recovery submit path for both
    // retained-byte relay and any subsequent new claim. A retained relay is
    // permitted only for the caller-selected target/payout family; proof is
    // deliberately rejected because it cannot change already-signed bytes.
    ShadowPowClaimSubmissionGuard submission_guard(*pwallet);
    if (!submission_guard) {
        throw JSONRPCError(RPC_WALLET_ERROR,
                           "Another Gold Rush PoW claim submission is already in progress for this wallet");
    }

    ShadowPowClaimMiningGate initial_gate =
        pwallet->GetShadowPowClaimMiningGate();
    std::set<uint256> relay_attempts;
    size_t relay_iterations{0};
    while (initial_gate.ShouldRelayExisting()) {
        if (++relay_iterations > MAX_SHADOW_POW_RPC_RELAY_ATTEMPTS) {
            throw JSONRPCError(
                RPC_VERIFY_REJECTED,
                "Existing Gold Rush PoW relay selection did not converge within the bounded per-call snapshot limit; no new fee transaction was created");
        }
        const ShadowPowClaimMiningGate current_gate =
            pwallet->GetShadowPowClaimMiningGate();
        if (!ShadowPowClaimRelayIntentMatches(
                initial_gate, current_gate) ||
            current_gate.relay_expiry_time <= 0 ||
            GetTime() >= current_gate.relay_expiry_time) {
            initial_gate = current_gate;
            continue;
        }
        if (!relay_attempts.insert(current_gate.relay_txid).second) {
            throw JSONRPCError(
                RPC_VERIFY_REJECTED,
                "Existing Gold Rush PoW relay selection did not converge within the bounded per-call attempt limit; no new fee transaction was created");
        }
        const ShadowPowClaimMiningGate relay_gate = current_gate;
        if (relay_gate.target != target ||
            relay_gate.payout_script != quantum_payout_script) {
            throw JSONRPCError(
                RPC_INVALID_PARAMETER,
                "The selected retained Gold Rush PoW claim family does not match address and quantum_address; no historical bytes were relayed");
        }
        if (supplied_proof) {
            throw JSONRPCError(
                RPC_INVALID_PARAMETER,
                "proof cannot be applied to an existing signed Gold Rush PoW claim; omit proof to relay the matching retained family");
        }
        std::string relay_error;
        bool relayed{false};
        ShadowPowClaimRecoveryBroadcastGuard broadcast_guard;
        broadcast_guard.expected_wallet_generation =
            relay_gate.wallet_generation;
        broadcast_guard.expected_wallet_tip = relay_gate.active_tip;
        broadcast_guard.expected_candidate_state_fingerprint =
            relay_gate.candidate_state_fingerprint;
        broadcast_guard.require_normal_unlock = true;
        try {
            relayed = pwallet->SubmitTxMemoryPoolAndRelay(
                relay_gate.relay_txid, relay_error, /*relay=*/true,
                &broadcast_guard,
                /*max_tx_fee_override=*/CENT);
        } catch (const std::exception& exception) {
            throw JSONRPCError(
                RPC_WALLET_ERROR,
                strprintf("Existing Gold Rush PoW claim relay encountered a local exception; no sibling was authorized: %s",
                          exception.what()));
        } catch (...) {
            throw JSONRPCError(
                RPC_WALLET_ERROR,
                "Existing Gold Rush PoW claim relay encountered an unknown local exception; no sibling was authorized");
        }
        if (relayed) {
            UniValue result(UniValue::VOBJ);
            result.pushKV("txid", relay_gate.relay_txid.GetHex());
            result.pushKV("outcome", "relayed_existing");
            result.pushKV("relayed_existing", true);
            result.pushKV("created_new_claim", false);
            return result;
        }
        if (ShadowPowClaimRelayRequiresFreshGate(relay_error)) {
            initial_gate = pwallet->GetShadowPowClaimMiningGate();
            continue;
        }
        const bool wait_for_snapshot_change = relay_error.empty() ||
            ShadowPowClaimRelayMustWaitForNextTip(relay_error);
        ShadowPowClaimMiningGate recorded_reselection;
        const bool recorded = !wait_for_snapshot_change &&
            pwallet->RecordShadowPowClaimRelayPolicyRejection(
                relay_gate, &recorded_reselection);
        initial_gate = recorded
            ? recorded_reselection
            : pwallet->DeferShadowPowClaimFamilyForSnapshot(
                  relay_gate);
        if (initial_gate.ShouldRelayExisting()) {
            continue;
        }
        if (initial_gate.MayCreateClaim()) {
            break;
        }
        if (wait_for_snapshot_change) {
            throw JSONRPCError(
                RPC_WALLET_ERROR,
                strprintf("Existing Gold Rush PoW claim family %s must wait for a wallet or tip state change; no independent relay or refresh work remains: %s",
                          relay_gate.relay_txid.GetHex(),
                          relay_error.empty() ? "local relay unavailable"
                                              : relay_error));
        }
        if (!recorded) {
            throw JSONRPCError(
                RPC_VERIFY_REJECTED,
                "Relay failure was not a reproducible deterministic mempool-policy rejection and no independent relay or refresh work remains; no new fee transaction was authorized");
        }
        throw JSONRPCError(
            RPC_VERIFY_REJECTED,
            "Every bounded historical relay candidate was rejected and the typed gate did not authorize a same-anchor refresh");
    }
    if (!initial_gate.MayCreateClaim()) {
        switch (initial_gate.action) {
        case ShadowPowClaimMiningGateAction::WAIT_FOR_LIVE:
            throw JSONRPCError(
                RPC_WALLET_ERROR,
                "Gold Rush PoW claim creation is waiting for an existing live claim family member; no competing fee transaction was created");
        case ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP:
            throw JSONRPCError(
                RPC_WALLET_ERROR,
                "Gold Rush PoW claim creation is waiting for a wallet or active-tip state change; no fee transaction was created");
        case ShadowPowClaimMiningGateAction::RELAY_EXISTING:
            throw JSONRPCError(
                RPC_VERIFY_REJECTED,
                "Gold Rush PoW claim creation still has bounded historical relay work; no sibling fee transaction was authorized");
        case ShadowPowClaimMiningGateAction::UNSAFE:
            throw JSONRPCError(
                RPC_WALLET_ERROR,
                "Gold Rush PoW claim creation is blocked by an incoherent, ambiguous, or unsafe wallet-owned claim component");
        case ShadowPowClaimMiningGateAction::CREATE_NEW_ANCHOR:
        case ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR:
            break;
        }
        throw JSONRPCError(
            RPC_WALLET_ERROR,
            "Gold Rush PoW claim creation is not authorized by the current typed mining-gate snapshot");
    }

    ShadowPowClaimInput selected_input;
    {
        LOCK2(::cs_main, pwallet->cs_wallet);
        ShadowPowClaimMiningGate mining_gate =
            pwallet->GetShadowPowClaimMiningGateLocked();
        if (!mining_gate.MayCreateClaim()) {
            throw JSONRPCError(RPC_WALLET_ERROR,
                "Gold Rush PoW claim creation is paused because the typed mining gate is unsafe, incoherent, or at capacity");
        }
        const CFeeRate fee_rate = GetMinimumFeeRate(*pwallet, coin_control, GetAdjustedTimeSeconds());
        if (coin_control.m_feerate && fee_rate > *coin_control.m_feerate) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("Fee rate (%s) is lower than the minimum fee rate setting (%s)", coin_control.m_feerate->ToString(FeeEstimateMode::SAT_VB), fee_rate.ToString(FeeEstimateMode::SAT_VB)));
        }
        bilingual_str selection_error;
        const ShadowPowClaimInputSelectionResult selection_result = pwallet->SelectShadowPowClaimInput(
            std::optional<CScript>{target},
            quantum_payout_script,
            supplied_proof ? &*supplied_proof : nullptr,
            coin_control,
            selected_input,
            selection_error,
            &mining_gate);
        if (selection_result == ShadowPowClaimInputSelectionResult::FEE_EXCEEDS_MAX) {
            throw JSONRPCError(RPC_WALLET_ERROR, selection_error.original);
        }
        if (selection_result != ShadowPowClaimInputSelectionResult::SELECTED) {
            if (mining_gate.MayRefreshSameAnchor()) {
                throw JSONRPCError(
                    RPC_WALLET_ERROR,
                    selection_error.original.empty()
                        ? "The selected retained Gold Rush PoW claim family is not currently serviceable"
                        : selection_error.original);
            }
            throw JSONRPCError(RPC_WALLET_INSUFFICIENT_FUNDS, "No spendable non-dust UTXO found for the target address");
        }
    }
    pwallet->MaybeDelayShadowPowClaimSubmissionForTest(selected_input.outpoint);

    ShadowPowWork pow_work;
    {
        ChainstateManager& chainman = pwallet->chain().chainman();
        LOCK(cs_main);
        const CBlockIndex* tip = chainman.ActiveChain().Tip();
        if (!tip) {
            throw JSONRPCError(RPC_CLIENT_NOT_CONNECTED, "No active chain tip");
        }
        const Consensus::Params& consensus = Params().GetConsensus();
        if (!IsShadowGoldRushRewardActive(consensus, tip->GetMedianTimePast(), tip->nHeight + 1)) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "Shadow PoW claims are only active during the Gold Rush epoch");
        }
        const CCoinsViewCache& view = chainman.ActiveChainstate().CoinsTip();
        pow_work = PrepareShadowPowWork(
            selected_input.target, selected_input.quantum_payout_script,
            selected_input.outpoint, tip, view);
        if (!pow_work.valid) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "Failed to prepare shadow PoW work (outside the reward window or invalid payout script/input)");
        }
    }
    if (supplied_proof) {
        const ShadowProofPayloadMode mode = ClassifyShadowProofPayload(
            *supplied_proof, pow_work.input_bound);
        if (mode == ShadowProofPayloadMode::POS) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "proof encodes PoS mode; fee-paying QQSPROOF claims require PoW mode byte 0");
        }
        if (mode == ShadowProofPayloadMode::UNKNOWN) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "proof encodes an unknown mode; fee-paying QQSPROOF claims require PoW mode byte 0");
        }
        if (!ValidateShadowPowProofForWork(pow_work, *supplied_proof)) {
            throw JSONRPCError(
                RPC_INVALID_PARAMETER,
                pow_work.input_bound
                    ? "proof does not match the current tip, exact fee input, target address, quantum payout address, and PoW channel"
                    : "proof does not match the current tip, target address, quantum payout address, and PoW channel");
        }
    }

    std::vector<unsigned char> proof;
    if (supplied_proof) {
        proof = *supplied_proof;
    } else if (!GrindShadowPowWork(pow_work, /*start_nonce=*/0, /*nonce_step=*/1, max_tries, proof)) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "Failed to grind a valid shadow PoW proof (max_tries exhausted)");
    }

    {
        ChainstateManager& chainman = pwallet->chain().chainman();
        LOCK(cs_main);
        const CBlockIndex* tip = chainman.ActiveChain().Tip();
        const Consensus::Params& consensus = Params().GetConsensus();
        if (!tip || tip->GetBlockHash() != pow_work.prev_hash ||
            !IsShadowGoldRushRewardActive(consensus, tip->GetMedianTimePast(), tip->nHeight + 1)) {
            throw JSONRPCError(RPC_VERIFY_REJECTED, "Active chain tip changed while grinding; retry the PoW claim");
        }
    }

    CMutableTransaction claim_tx;
    CAmount fee{0};
    CAmount change{0};
    int64_t vsize{-1};
    {
        LOCK2(::cs_main, pwallet->cs_wallet);
        if (pwallet->m_pow_wallet_authority_generation.load(
                std::memory_order_acquire) !=
                expected_wallet_authority_generation ||
            !pwallet->HasNormalPowMiningWalletAuthorityLocked()) {
            throw JSONRPCError(
                RPC_WALLET_UNLOCK_NEEDED,
                "Wallet signing authority changed while grinding; retry after a normal unlock");
        }
        const ShadowPowClaimMiningGate mining_gate =
            pwallet->GetShadowPowClaimMiningGateLocked();
        if (!mining_gate.MayCreateClaim() ||
            selected_input.same_anchor_refresh !=
                mining_gate.MayRefreshSameAnchor()) {
            throw JSONRPCError(
                RPC_VERIFY_REJECTED,
                "Wallet claim action changed while grinding; retry the PoW claim");
        }
        const int64_t current_time = GetAdjustedTimeSeconds();
        const CFeeRate fee_rate = GetMinimumFeeRate(*pwallet, coin_control, current_time);
        if (coin_control.m_feerate && fee_rate > *coin_control.m_feerate) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("Fee rate (%s) is lower than the minimum fee rate setting (%s)", coin_control.m_feerate->ToString(FeeEstimateMode::SAT_VB), fee_rate.ToString(FeeEstimateMode::SAT_VB)));
        }
        std::map<COutPoint, Coin> coins;
        const auto build_candidate = [&](const COutPoint& outpoint,
                                         const CTxOut& output,
                                         const Coin& input_coin) {
            CMutableTransaction candidate;
            candidate.nVersion = CTransaction::CURRENT_VERSION;
            candidate.nTime = current_time;
            static constexpr uint32_t SEQUENCE_REPLACEABLE = 0xfffffffd;
            candidate.vin.emplace_back(
                outpoint, CScript(), SEQUENCE_REPLACEABLE);
            candidate.vout.emplace_back(output.nValue, selected_input.target);
            candidate.vout.emplace_back(0, CScript() << OP_RETURN << proof);

            const TxSize tx_size = CalculateMaximumSignedTxSize(CTransaction(candidate), pwallet.get(), &coin_control);
            if (tx_size.vsize <= 0) return false;
            const CAmount candidate_fee = std::max(GetMinFee(static_cast<size_t>(tx_size.vsize), static_cast<uint32_t>(current_time)), fee_rate.GetFee(static_cast<uint32_t>(tx_size.vsize)));
            const CAmount candidate_change = output.nValue - candidate_fee;
            CTxOut change_out(candidate_change, selected_input.target);
            if (!MoneyRange(candidate_change) || candidate_change <= 0 ||
                IsDust(change_out, pwallet->chain().relayDustFee())) {
                return false;
            }
            if (candidate_fee > pwallet->m_default_max_tx_fee) {
                throw JSONRPCError(RPC_WALLET_ERROR, strprintf("Fee exceeds wallet max transaction fee (%s)", FormatMoney(pwallet->m_default_max_tx_fee)));
            }
            if (candidate_fee > CENT) {
                throw JSONRPCError(RPC_WALLET_ERROR,
                                   "Gold Rush PoW claim fee exceeds the maximum reimbursable fee of 0.01 BLK");
            }

            candidate.vout[0].nValue = candidate_change;
            coins.emplace(outpoint, input_coin);
            claim_tx = std::move(candidate);
            fee = candidate_fee;
            change = candidate_change;
            vsize = tx_size.vsize;
            return true;
        };

        if (selected_input.same_anchor_refresh) {
            Coin anchor_coin;
            bilingual_str refresh_error;
            if (!pwallet->GetShadowPowClaimRefreshCoinLocked(
                    selected_input, mining_gate, anchor_coin,
                    refresh_error) ||
                !build_candidate(selected_input.outpoint, anchor_coin.out,
                                 anchor_coin)) {
                throw JSONRPCError(
                    RPC_VERIFY_REJECTED,
                    refresh_error.original.empty()
                        ? "The same-anchor Gold Rush PoW refresh became unavailable while grinding"
                        : refresh_error.original);
            }
        } else {
            if (!mining_gate.MayCreateNewAnchorClaim() ||
                std::binary_search(
                    mining_gate.reserved_family_anchors.begin(),
                    mining_gate.reserved_family_anchors.end(),
                    selected_input.outpoint)) {
                throw JSONRPCError(
                    RPC_VERIFY_REJECTED,
                    "The current wallet action no longer permits the selected Gold Rush PoW fee anchor");
            }
            for (const COutput& output :
                 AvailableCoins(*pwallet, &coin_control).All()) {
                if (output.outpoint != selected_input.outpoint) continue;
                if (output.depth <= 0) continue;
                if (CanonicalizeLegacyStakeScript(
                        output.txout.scriptPubKey) != selected_input.target) {
                    continue;
                }
                if (ComputeShadowPowClaimLineageFamilyFingerprint(
                        output.outpoint, output.txout.nValue,
                        output.txout.scriptPubKey) !=
                    selected_input.lineage_family_fingerprint) {
                    continue;
                }
                Coin input_coin;
                if (!pwallet->chain().chainman().ActiveChainstate()
                         .CoinsTip()
                         .GetCoin(output.outpoint, input_coin) ||
                    input_coin.IsSpent()) {
                    continue;
                }
                if (build_candidate(
                        output.outpoint, output.txout, input_coin)) {
                    break;
                }
            }
        }

        if (!claim_tx.vin.empty()) {
            std::map<int, bilingual_str> input_errors;
            if (!pwallet->SignTransaction(
                    claim_tx, coins, SIGHASH_DEFAULT, input_errors)) {
                if (!input_errors.empty()) {
                    throw JSONRPCError(RPC_WALLET_ERROR, strprintf("Signing claim transaction failed: %s", input_errors.begin()->second.original));
                }
                throw JSONRPCError(RPC_WALLET_ERROR, "Signing claim transaction failed");
            }
        }
    }

    if (claim_tx.vin.empty()) {
        throw JSONRPCError(RPC_VERIFY_REJECTED,
                           strprintf("Selected Gold Rush PoW claim input %s changed while grinding; retry the PoW claim",
                                     selected_input.outpoint.ToString()));
    }

    CTransactionRef tx = MakeTransactionRef(std::move(claim_tx));
    const std::string hex = EncodeHexTx(*tx);
    pwallet->MaybeDelayShadowPowClaimCommitForTest(
        selected_input.outpoint);
    {
        ChainstateManager& chainman = pwallet->chain().chainman();
        LOCK(cs_main);
        const CBlockIndex* tip = chainman.ActiveChain().Tip();
        if (!tip || tip->GetBlockHash() != pow_work.prev_hash ||
            tip->nHeight + 1 != pow_work.height) {
            throw JSONRPCError(RPC_VERIFY_REJECTED, "Active chain tip changed before the PoW claim could be committed; retry on the new tip");
        }
        ShadowPowClaimMiningGate final_mining_gate;
        {
            LOCK(pwallet->cs_wallet);
            final_mining_gate =
                pwallet->GetShadowPowClaimMiningGateLocked();
            Coin selected_coin;
            bilingual_str refresh_error;
            const bool gate_matches = selected_input.same_anchor_refresh
                ? pwallet->GetShadowPowClaimRefreshCoinLocked(
                      selected_input, final_mining_gate, selected_coin,
                      refresh_error)
                : final_mining_gate.MayCreateNewAnchorClaim() &&
                      !std::binary_search(
                          final_mining_gate.reserved_family_anchors.begin(),
                          final_mining_gate.reserved_family_anchors.end(),
                          selected_input.outpoint) &&
                      chainman.ActiveChainstate().CoinsTip().GetCoin(
                          selected_input.outpoint, selected_coin) &&
                      !selected_coin.IsSpent() &&
                      ComputeShadowPowClaimLineageFamilyFingerprint(
                          selected_input.outpoint,
                          selected_coin.out.nValue,
                          selected_coin.out.scriptPubKey) ==
                          selected_input.lineage_family_fingerprint;
            if (!gate_matches) {
                throw JSONRPCError(RPC_VERIFY_REJECTED,
                    "Wallet mining-gate state or selected confirmed input changed before commit; retry the PoW claim");
            }
        }
        const MempoolAcceptResult accept = chainman.ProcessTransaction(tx, /*test_accept=*/true);
        if (accept.m_result_type != MempoolAcceptResult::ResultType::VALID) {
            throw JSONRPCError(RPC_VERIFY_REJECTED, strprintf("Shadow PoW claim rejected: %s", accept.m_state.ToString()));
        }
        // Keep the final tip check atomic with wallet persistence and relay.
        // cs_main is recursive on this codebase, so the commit validation path
        // may re-enter it without reopening the stale-tip race.
        mapValue_t map_value;
        map_value["comment"] = "PoW Claim";
        map_value[SHADOW_POW_CLAIM_AUTHORED_KEY] = "1";
        map_value[SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY] =
            strprintf("%d", pow_work.height);
        map_value[SHADOW_POW_CLAIM_CREATED_TIP_KEY] =
            pow_work.prev_hash.GetHex();
        map_value[SHADOW_POW_CLAIM_LINEAGE_SCHEMA_KEY] =
            SHADOW_POW_CLAIM_LINEAGE_SCHEMA_VERSION;
        map_value[SHADOW_POW_CLAIM_LINEAGE_FAMILY_KEY] =
            selected_input.lineage_family_fingerprint.GetHex();
        map_value[SHADOW_POW_CLAIM_LINEAGE_ROOT_KEY] =
            (selected_input.same_anchor_refresh
                 ? selected_input.lineage_root_txid
                 : tx->GetHash().ToUint256())
                .GetHex();
        map_value[SHADOW_POW_CLAIM_LINEAGE_ORDINAL_KEY] =
            strprintf("%u", selected_input.same_anchor_refresh
                               ? selected_input.lineage_ordinal
                               : uint32_t{0});
        if (selected_input.same_anchor_refresh) {
            map_value[SHADOW_POW_CLAIM_LINEAGE_PARENT_KEY] =
                selected_input.lineage_parent_txid.GetHex();
        }
        CommitWalletTransactionOrThrow(
            *pwallet, tx, std::move(map_value), "PoW Claim",
            /*created_destination=*/std::nullopt,
            ShadowPowClaimCommitAuthority{
                expected_wallet_authority_generation,
                /*require_pow_mining_enabled=*/false,
                selected_input.coin_lock_generation,
                selected_input.outpoint,
                final_mining_gate.wallet_generation,
                final_mining_gate.candidate_state_fingerprint});
    }

    UniValue result(UniValue::VOBJ);
    result.pushKV("txid", tx->GetHash().GetHex());
    result.pushKV("outcome", "created_new_claim");
    result.pushKV("relayed_existing", false);
    result.pushKV("created_new_claim", true);
    result.pushKV("hex", hex);
    result.pushKV("proof", HexStr(proof));
    result.pushKV("proof_mode", "pow");
    result.pushKV("proof_mode_byte", 0);
    result.pushKV("external_proof", supplied_proof.has_value());
    result.pushKV("fee", ValueFromAmount(fee));
    result.pushKV("change", ValueFromAmount(change));
    result.pushKV("vsize", vsize);
    result.pushKV("address", address);
    result.pushKV("quantum_address", quantum_address);
    return result;
},
    };
}

static const char* ShadowPowRecoveryStateName(ShadowPowClaimRecoveryState state)
{
    switch (state) {
    case ShadowPowClaimRecoveryState::LIVE: return "live";
    case ShadowPowClaimRecoveryState::TRANSIENT: return "transient";
    case ShadowPowClaimRecoveryState::INDETERMINATE: return "indeterminate";
    case ShadowPowClaimRecoveryState::CURRENT_BRANCH_INELIGIBLE: return "current_branch_ineligible";
    case ShadowPowClaimRecoveryState::TERMINAL_ON_PINNED_TIP: return "terminal_on_pinned_tip";
    case ShadowPowClaimRecoveryState::RETIRED_ON_ACTIVE_BRANCH: return "retired_on_active_branch";
    case ShadowPowClaimRecoveryState::RESOLUTION_PENDING: return "resolution_pending";
    case ShadowPowClaimRecoveryState::RESOLVED_ON_ACTIVE_CHAIN: return "resolved_on_active_chain";
    }
    return "unknown";
}

static const char* ShadowPowMiningGateActionName(
    ShadowPowClaimMiningGateAction action)
{
    switch (action) {
    case ShadowPowClaimMiningGateAction::CREATE_NEW_ANCHOR:
        return "create_new_anchor";
    case ShadowPowClaimMiningGateAction::WAIT_FOR_LIVE:
        return "wait_for_live";
    case ShadowPowClaimMiningGateAction::WAIT_FOR_NEXT_TIP:
        return "wait_for_next_tip";
    case ShadowPowClaimMiningGateAction::RELAY_EXISTING:
        return "relay_existing";
    case ShadowPowClaimMiningGateAction::REFRESH_SAME_ANCHOR:
        return "refresh_same_anchor";
    case ShadowPowClaimMiningGateAction::UNSAFE:
        return "unsafe";
    }
    return "unsafe";
}

static const char* ShadowPowRecoveryProvenanceName(ShadowPowClaimRecoveryProvenance provenance)
{
    switch (provenance) {
    case ShadowPowClaimRecoveryProvenance::EXPLICIT_AUTHORED: return "explicit_authored";
    case ShadowPowClaimRecoveryProvenance::EXPLICIT_ADOPTED: return "explicit_adopted";
    case ShadowPowClaimRecoveryProvenance::LEGACY_WALLET_AUTHORED: return "legacy_wallet_authored";
    case ShadowPowClaimRecoveryProvenance::UNKNOWN: return "unknown";
    }
    return "unknown";
}

static const char* ShadowPowRecoveryNodeKindName(ShadowPowClaimRecoveryNodeKind kind)
{
    switch (kind) {
    case ShadowPowClaimRecoveryNodeKind::CLAIM: return "claim";
    case ShadowPowClaimRecoveryNodeKind::MANAGED_RESOLUTION: return "managed_resolution";
    case ShadowPowClaimRecoveryNodeKind::LEGACY_RESOLUTION: return "legacy_resolution";
    case ShadowPowClaimRecoveryNodeKind::ORDINARY: return "ordinary";
    }
    return "unknown";
}

static const char* ShadowPowRecoveryActionStatusName(ShadowPowClaimRecoveryActionStatus status)
{
    switch (status) {
    case ShadowPowClaimRecoveryActionStatus::READY: return "ready";
    case ShadowPowClaimRecoveryActionStatus::REUSE_MANAGED: return "reuse_managed";
    case ShadowPowClaimRecoveryActionStatus::REUSE_LEGACY: return "reuse_legacy";
    case ShadowPowClaimRecoveryActionStatus::SIGNED_AND_PERSISTED: return "signed_and_persisted";
    case ShadowPowClaimRecoveryActionStatus::BROADCAST: return "broadcast";
    case ShadowPowClaimRecoveryActionStatus::ALREADY_IN_MEMPOOL: return "already_in_mempool";
    case ShadowPowClaimRecoveryActionStatus::RELAY_DEFERRED: return "relay_deferred";
    case ShadowPowClaimRecoveryActionStatus::REFUSED: return "refused";
    case ShadowPowClaimRecoveryActionStatus::FAILED: return "failed";
    }
    return "unknown";
}

static const char* ShadowPowMempoolDispositionName(ShadowPowClaimMempoolDisposition disposition)
{
    switch (disposition) {
    case ShadowPowClaimMempoolDisposition::ELIGIBLE: return "eligible";
    case ShadowPowClaimMempoolDisposition::INACTIVE: return "inactive";
    case ShadowPowClaimMempoolDisposition::HEIGHT_BEFORE_WINDOW: return "height_before_window";
    case ShadowPowClaimMempoolDisposition::HEIGHT_AFTER_WINDOW: return "height_after_window";
    case ShadowPowClaimMempoolDisposition::INVALID_LOCATION: return "invalid_location";
    case ShadowPowClaimMempoolDisposition::MALFORMED: return "malformed";
    case ShadowPowClaimMempoolDisposition::DUPLICATE: return "duplicate";
    case ShadowPowClaimMempoolDisposition::WRONG_MODE: return "wrong_mode";
    case ShadowPowClaimMempoolDisposition::UNKNOWN_MODE: return "unknown_mode";
    case ShadowPowClaimMempoolDisposition::UNSUPPORTED_VERSION: return "unsupported_version";
    case ShadowPowClaimMempoolDisposition::VERSION_NOT_YET_ACTIVE: return "version_not_yet_active";
    case ShadowPowClaimMempoolDisposition::INVALID_PROOF: return "invalid_proof";
    case ShadowPowClaimMempoolDisposition::UNBOUND_PROOF_MAY_REVALIDATE: return "unbound_proof_may_revalidate";
    case ShadowPowClaimMempoolDisposition::ORIGIN_MISMATCH: return "origin_mismatch";
    case ShadowPowClaimMempoolDisposition::ORIGIN_NOT_YET_REACHED: return "origin_not_yet_reached";
    case ShadowPowClaimMempoolDisposition::ORIGIN_EXPIRED: return "origin_expired";
    case ShadowPowClaimMempoolDisposition::INPUT_MISMATCH: return "input_mismatch";
    case ShadowPowClaimMempoolDisposition::ALREADY_ACCOUNTED: return "already_accounted";
    case ShadowPowClaimMempoolDisposition::CAPACITY_LIMIT: return "capacity_limit";
    case ShadowPowClaimMempoolDisposition::EVALUATION_LIMIT: return "evaluation_limit";
    case ShadowPowClaimMempoolDisposition::LOCAL_STATE_ERROR: return "local_state_error";
    }
    return "unknown";
}

static UniValue ShadowPowTxidsToJSON(const std::vector<uint256>& txids)
{
    UniValue result(UniValue::VARR);
    for (const uint256& txid : txids) result.push_back(txid.GetHex());
    return result;
}

static UniValue ShadowPowRecoveryActionToJSON(const ShadowPowClaimRecoveryAction& action,
                                               bool include_hex,
                                               bool suppress_transaction = false)
{
    UniValue result(UniValue::VOBJ);
    UniValue anchor(UniValue::VOBJ);
    anchor.pushKV("txid", action.anchor.hash.GetHex());
    anchor.pushKV("vout", action.anchor.n);
    result.pushKV("anchor", std::move(anchor));
    result.pushKV("generation_fingerprint", action.generation_fingerprint.GetHex());
    result.pushKV("component_fingerprint", action.component_fingerprint.GetHex());
    result.pushKV("classification", ShadowPowRecoveryStateName(action.component_state));
    result.pushKV("status", ShadowPowRecoveryActionStatusName(action.status));
    result.pushKV("claim_txids", ShadowPowTxidsToJSON(action.claim_txids));
    result.pushKV("descendant_claims", static_cast<uint64_t>(action.descendant_claims));
    result.pushKV("fee", ValueFromAmount(action.fee));
    result.pushKV("persisted", action.persisted);
    result.pushKV("relay_authorized", action.relay_authorized);
    result.pushKV("relay_revoked", action.relay_revoked);
    result.pushKV("in_mempool", action.in_mempool);
    result.pushKV("frontier_may_advance", action.frontier_may_advance);
    result.pushKV("conflicts_with_revalidating_unbound_proof",
                  action.conflicts_with_revalidating_unbound_proof);
    result.pushKV("reason_code", action.reason_code);
    result.pushKV("reason", action.detail);
    if (action.transaction && !suppress_transaction) {
        if (action.status == ShadowPowClaimRecoveryActionStatus::READY) {
            result.pushKV("unsigned_template_hash", action.transaction->GetHash().GetHex());
        } else {
            result.pushKV("resolution_txid", action.transaction->GetHash().GetHex());
        }
        result.pushKV("vsize", action.vsize);
        if (action.transaction->vout.size() == 1) {
            result.pushKV("input_amount", ValueFromAmount(action.transaction->vout.front().nValue + action.fee));
            result.pushKV("output_amount", ValueFromAmount(action.transaction->vout.front().nValue));
        }
        if (include_hex &&
            action.status != ShadowPowClaimRecoveryActionStatus::READY) {
            result.pushKV("hex", EncodeHexTx(*action.transaction));
        }
    }
    return result;
}

static bool ShadowPowRecoveryPlanHasRevalidatingUnboundProof(
    const ShadowPowClaimRecoveryPlan& plan)
{
    const auto has_risk = [](const ShadowPowClaimRecoveryAction& action) {
        return action.conflicts_with_revalidating_unbound_proof;
    };
    return std::any_of(plan.actions.begin(), plan.actions.end(), has_risk) ||
           std::any_of(plan.refused.begin(), plan.refused.end(), has_risk);
}

static UniValue ShadowPowRecoveryPlanToJSON(const ShadowPowClaimRecoveryPlan& plan,
                                             ShadowPowClaimRecoveryMode mode)
{
    UniValue result(UniValue::VOBJ);
    const char* action = mode == ShadowPowClaimRecoveryMode::PREVIEW
        ? "preview"
        : mode == ShadowPowClaimRecoveryMode::SIGN_ONLY
            ? "sign_only"
            : "commit_and_broadcast";
    result.pushKV("action", action);
    const bool plan_reusable =
        mode == ShadowPowClaimRecoveryMode::PREVIEW &&
        plan.complete && plan.wallet_tip_matches && !plan.plan_id.IsNull();
    if (plan_reusable) result.pushKV("plan_id", plan.plan_id.GetHex());
    result.pushKV("plan_reusable", plan_reusable);
    result.pushKV("active_tip", plan.active_tip.GetHex());
    result.pushKV("active_height", plan.active_height);
    result.pushKV("wallet_generation", plan.wallet_generation);
    result.pushKV("wallet_tip_matches", plan.wallet_tip_matches);
    result.pushKV("complete", plan.complete);
    result.pushKV("one_call_finality", false);
    result.pushKV("frontier_may_advance", true);
    result.pushKV("contains_revalidating_unbound_proof",
                  ShadowPowRecoveryPlanHasRevalidatingUnboundProof(plan));
    result.pushKV("max_fee_per_resolution", ValueFromAmount(plan.max_fee_per_resolution));
    result.pushKV("aggregate_batch_fee_cap", ValueFromAmount(plan.aggregate_batch_fee_cap));
    if (plan.fee_rate_atoms_per_k) {
        result.pushKV("fee_rate_atoms_per_k", *plan.fee_rate_atoms_per_k);
    }
    result.pushKV("total_fee", ValueFromAmount(plan.total_fee));
    result.pushKV("actionable_components", static_cast<uint64_t>(plan.actions.size()));
    result.pushKV("refused_components", static_cast<uint64_t>(plan.refused.size()));
    UniValue actions(UniValue::VARR);
    for (const auto& item : plan.actions) {
        actions.push_back(ShadowPowRecoveryActionToJSON(
            item, mode != ShadowPowClaimRecoveryMode::PREVIEW));
    }
    result.pushKV("actions", std::move(actions));
    UniValue refused(UniValue::VARR);
    for (const auto& item : plan.refused) {
        refused.push_back(ShadowPowRecoveryActionToJSON(item, false));
    }
    result.pushKV("refused", std::move(refused));
    return result;
}

static UniValue ShadowPowRecoveryResultToJSON(
    const ShadowPowClaimRecoveryResult& execution,
    ShadowPowClaimRecoveryMode mode,
    const ShadowPowClaimRecoveryPlan* current_plan = nullptr)
{
    UniValue result(UniValue::VOBJ);
    if (mode == ShadowPowClaimRecoveryMode::PREVIEW &&
        !execution.durable_state_ambiguous) {
        result = ShadowPowRecoveryPlanToJSON(execution.plan, mode);
    } else if (mode == ShadowPowClaimRecoveryMode::PREVIEW) {
        result.pushKV("action", "preview");
        result.pushKV("plan_reusable", false);
        result.pushKV("actions", UniValue(UniValue::VARR));
        result.pushKV("refused", UniValue(UniValue::VARR));
    } else {
        result.pushKV("action", mode == ShadowPowClaimRecoveryMode::SIGN_ONLY
            ? "sign_only" : "commit_and_broadcast");
        const bool plan_consumed = !execution.plan.plan_id.IsNull();
        if (plan_consumed) {
            result.pushKV("acknowledged_plan_id", execution.plan.plan_id.GetHex());
            result.pushKV("acknowledged_active_tip", execution.plan.active_tip.GetHex());
            result.pushKV("acknowledged_active_height", execution.plan.active_height);
            result.pushKV("acknowledged_wallet_generation", execution.plan.wallet_generation);
            result.pushKV("acknowledged_total_fee", ValueFromAmount(execution.plan.total_fee));
        }
        result.pushKV("plan_consumed", plan_consumed);
        result.pushKV("plan_reusable", false);
        result.pushKV("contains_revalidating_unbound_proof",
                      ShadowPowRecoveryPlanHasRevalidatingUnboundProof(
                          execution.plan));

        UniValue actions(UniValue::VARR);
        for (const auto& item : execution.plan.actions) {
            actions.push_back(ShadowPowRecoveryActionToJSON(
                item, /*include_hex=*/true,
                /*suppress_transaction=*/execution.durable_state_ambiguous));
        }
        result.pushKV("actions", std::move(actions));
        UniValue refused(UniValue::VARR);
        for (const auto& item : execution.plan.refused) {
            refused.push_back(ShadowPowRecoveryActionToJSON(item, false));
        }
        result.pushKV("refused", std::move(refused));
        if (current_plan) {
            result.pushKV("current_plan", ShadowPowRecoveryPlanToJSON(
                *current_plan, ShadowPowClaimRecoveryMode::PREVIEW));
        }
    }
    result.pushKV("success", execution.success);
    result.pushKV("stale_plan", execution.stale_plan);
    result.pushKV("signed_and_persisted", static_cast<uint64_t>(execution.signed_and_persisted));
    result.pushKV("durable_state_changed", execution.durable_state_changed);
    result.pushKV("durable_state_ambiguous", execution.durable_state_ambiguous);
    result.pushKV("relay_authority_granted", static_cast<uint64_t>(execution.relay_authority_granted));
    result.pushKV("broadcast", static_cast<uint64_t>(execution.broadcast));
    result.pushKV("already_in_mempool", static_cast<uint64_t>(execution.already_in_mempool));
    result.pushKV("relay_deferred", static_cast<uint64_t>(execution.relay_deferred));
    result.pushKV("error", execution.error);
    if (mode == ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST) {
        result.pushKV("relay_complete", execution.success && execution.relay_deferred == 0);
    }
    if (!execution.success && execution.durable_state_ambiguous) {
        result.pushKV("next_step", "The durable database outcome is ambiguous. Stop recovery activity and reload the wallet. Reload may reveal exact persisted or relay-authorized bytes; inspect the refreshed current plan and wallet records before retrying because authorized bytes may relay later.");
    } else if (mode != ShadowPowClaimRecoveryMode::PREVIEW &&
               !execution.success && execution.durable_state_changed) {
        result.pushKV("next_step", "Durable wallet state changed before this operation stopped. Inspect every action, relay_authority_granted, error, and current_plan. Exact authorized bytes may be retried by the scheduler; do not assume an RPC failure rolled them back.");
    } else if (mode == ShadowPowClaimRecoveryMode::PREVIEW) {
        result.pushKV("next_step", !execution.plan.complete ||
                                      !execution.plan.wallet_tip_matches
            ? "No reusable plan is available because the wallet and active-chain snapshot is incomplete or mismatched. Synchronize or reload, then preview again."
            : execution.plan.actions.empty()
            ? "No current safe action is available. Review refused components and retry only after their stated gate changes."
            : "Review every action and fee, then repeat with this exact expected_plan_id and explicit acknowledgement. Any mutation or tip change consumes the plan.");
    } else if (mode == ShadowPowClaimRecoveryMode::SIGN_ONLY) {
        result.pushKV("next_step", "Exact signed bytes are persisted without new relay authority. Run preview again to obtain a fresh plan before commit_and_broadcast.");
    } else if (execution.relay_deferred != 0) {
        result.pushKV("next_step", "Commit authority is durable, but some exact transactions were deliberately deferred after the first new relay. The scheduler will retry them; re-preview before any further manual execution.");
    } else {
        result.pushKV("next_step", "Monitor mempool and confirmation state. A later original-claim confirmation can advance the component frontier and require a new preview.");
    }
    const bool revalidation_risk =
        ShadowPowRecoveryPlanHasRevalidatingUnboundProof(execution.plan);
    result.pushKV("warning", revalidation_risk
        ? "This plan deliberately conflicts with an unbound claim proof that is invalid on the pinned tip but may become valid on a descendant. Exact-plan fee/conflict acknowledgement or bounded automatic standing consent is required. A recovery is an on-chain conflict, not abandonment; confirmation is not guaranteed, and only a confirmed resolution pays its displayed base-chain fee. Re-preview after any tip or wallet change. Recovery never enables mining."
        : "A recovery is an on-chain conflict, not abandonment. Confirmation is not guaranteed, and only a confirmed resolution pays its displayed base-chain fee. A later original-claim confirmation may advance the component frontier and require a new plan. A commit pass relays at most one newly submitted transaction before deferring the rest for a fresh pinned scheduler pass. Recovery never enables mining.");
    return result;
}

static std::vector<RPCResult> ShadowPowRecoveryExecutionResults()
{
    return {
        {RPCResult::Type::STR, "action", "preview, sign_only, or commit_and_broadcast."},
        {RPCResult::Type::STR_HEX, "plan_id", /*optional=*/true, "Reusable exact plan identifier returned only by preview."},
        {RPCResult::Type::STR_HEX, "active_tip", /*optional=*/true, "Preview tip to which plan_id is bound."},
        {RPCResult::Type::NUM, "active_height", /*optional=*/true, "Preview height to which plan_id is bound."},
        {RPCResult::Type::NUM, "wallet_generation", /*optional=*/true, "Preview wallet generation protected by plan_id."},
        {RPCResult::Type::BOOL, "wallet_tip_matches", /*optional=*/true, "Whether wallet processing matched the preview tip."},
        {RPCResult::Type::BOOL, "complete", /*optional=*/true, "Whether the preview snapshot was coherent."},
        {RPCResult::Type::BOOL, "one_call_finality", /*optional=*/true, "Always false; a later original-claim confirmation can advance the component frontier."},
        {RPCResult::Type::BOOL, "frontier_may_advance", /*optional=*/true, "Whether a later component generation may require another plan."},
        {RPCResult::Type::BOOL, "contains_revalidating_unbound_proof", /*optional=*/true, "Whether a selected action conflicts with an unbound proof that is invalid now but may become valid on a descendant."},
        {RPCResult::Type::STR_AMOUNT, "max_fee_per_resolution", /*optional=*/true, "Per-resolution fee cap used by the preview."},
        {RPCResult::Type::STR_AMOUNT, "aggregate_batch_fee_cap", /*optional=*/true, "Aggregate fee cap used by the preview."},
        {RPCResult::Type::NUM, "fee_rate_atoms_per_k", /*optional=*/true, "Explicit fee rate in atoms per 1000 virtual bytes, when supplied."},
        {RPCResult::Type::STR_AMOUNT, "total_fee", /*optional=*/true, "Aggregate preview fee if every planned resolution confirms."},
        {RPCResult::Type::NUM, "actionable_components", /*optional=*/true, "Preview components with a current canonical action."},
        {RPCResult::Type::NUM, "refused_components", /*optional=*/true, "Preview components refused closed by a safety gate."},
        {RPCResult::Type::STR_HEX, "acknowledged_plan_id", /*optional=*/true, "Exact pre-execution plan accepted and consumed by a mutating call."},
        {RPCResult::Type::STR_HEX, "acknowledged_active_tip", /*optional=*/true, "Tip bound to the consumed plan."},
        {RPCResult::Type::NUM, "acknowledged_active_height", /*optional=*/true, "Height bound to the consumed plan."},
        {RPCResult::Type::NUM, "acknowledged_wallet_generation", /*optional=*/true, "Wallet generation bound to the consumed plan."},
        {RPCResult::Type::STR_AMOUNT, "acknowledged_total_fee", /*optional=*/true, "Aggregate fee accepted by the consumed plan."},
        {RPCResult::Type::BOOL, "plan_consumed", /*optional=*/true, "True for a mutating call; acknowledged_plan_id must not be reused."},
        {RPCResult::Type::ARR, "actions", "Preview actions or per-action mutation outcomes.", {{RPCResult::Type::ELISION, "", ""}}},
        {RPCResult::Type::ARR, "refused", "Fail-closed actions with machine reason_code fields.", {{RPCResult::Type::ELISION, "", ""}}},
        {RPCResult::Type::OBJ, "current_plan", /*optional=*/true, "Fresh read-only preview after a mutating call. Its nested plan_id is present and usable only when nested plan_reusable=true.", {{RPCResult::Type::ELISION, "", ""}}},
        {RPCResult::Type::BOOL, "success", "Whether required persistence and authorization completed. This does not mean every authorized transaction was relayed; inspect relay_deferred and relay_complete."},
        {RPCResult::Type::BOOL, "stale_plan", "Whether exact-plan stale-state protection rejected the request."},
        {RPCResult::Type::NUM, "signed_and_persisted", "New exact transactions signed and durably persisted."},
        {RPCResult::Type::BOOL, "durable_state_changed", "Whether this invocation definitely persisted new exact bytes or granted durable relay authority, including when a later step failed."},
        {RPCResult::Type::BOOL, "durable_state_ambiguous", "Whether database commit or rollback had an indeterminate outcome. Reload may reveal exact persisted or relay-authorized bytes."},
        {RPCResult::Type::NUM, "relay_authority_granted", "Existing or newly persisted exact transactions granted durable scheduler/relay authority by this invocation."},
        {RPCResult::Type::NUM, "broadcast", "Exact transactions broadcast during this pass."},
        {RPCResult::Type::NUM, "already_in_mempool", "Exact transactions already present in the mempool."},
        {RPCResult::Type::NUM, "relay_deferred", "Commit-authorized exact transactions deferred to a later scheduler pass."},
        {RPCResult::Type::STR, "error", "Structured execution-level error detail, empty on success."},
        {RPCResult::Type::BOOL, "plan_reusable", "True only for a read-only preview; mutating calls require a fresh preview before another manual execution."},
        {RPCResult::Type::BOOL, "relay_complete", /*optional=*/true, "For commit_and_broadcast, whether no commit-authorized relay was deferred."},
        {RPCResult::Type::STR, "next_step", "Required review, re-preview, retry, or monitoring action."},
        {RPCResult::Type::STR, "warning", "Conflict, fee, confirmation, and frontier warning."},
    };
}

static UniValue ShadowPowRecoveryNodeToJSON(const ShadowPowClaimRecoveryNode& node)
{
    UniValue result(UniValue::VOBJ);
    result.pushKV("txid", node.txid.GetHex());
    result.pushKV("kind", ShadowPowRecoveryNodeKindName(node.kind));
    result.pushKV("provenance", ShadowPowRecoveryProvenanceName(node.provenance));
    result.pushKV("disposition", ShadowPowMempoolDispositionName(node.disposition));
    result.pushKV("proof_may_revalidate_on_descendant",
                  node.proof_may_revalidate_on_descendant);
    result.pushKV("active_chain_confirmed", node.active_chain_confirmed);
    result.pushKV("in_mempool", node.in_mempool);
    result.pushKV("quarantined", node.quarantined);
    result.pushKV("expected_shape", node.expected_shape);
    result.pushKV("wallet_authored", node.wallet_authored);
    result.pushKV("wallet_from_me", node.wallet_from_me);
    result.pushKV("authored_metadata_valid", node.authored_metadata_valid);
    result.pushKV("authored_tip_active_branch_bound",
                  node.authored_tip_active_branch_bound);
    result.pushKV("claim_descriptor_valid", node.claim_descriptor_valid);
    result.pushKV("proof_evaluation_skipped_resolved_anchor",
                  node.proof_evaluation_skipped_resolved_anchor);
    result.pushKV("proof_version",
                  static_cast<uint64_t>(node.proof_version));
    result.pushKV("proof_mode",
                  node.proof_mode == ShadowProofPayloadMode::POW
                      ? "pow"
                      : node.proof_mode == ShadowProofPayloadMode::POS
                          ? "pos"
                          : node.proof_mode ==
                                    ShadowProofPayloadMode::UNKNOWN
                              ? "unknown"
                              : "malformed");
    result.pushKV("proof_origin_bound", node.proof_origin_bound);
    result.pushKV("proof_origin_height", node.proof_origin_height);
    result.pushKV("proof_origin_previous_block_hash",
                  node.proof_origin_previous_block_hash.GetHex());
    result.pushKV("proof_input_bound", node.proof_input_bound);
    result.pushKV("exact_authored_carrier_shape",
                  node.exact_authored_carrier_shape);
    result.pushKV("relay_ttl_expired", node.relay_ttl_expired);
    result.pushKV("relay_expiry_time", node.relay_expiry_time);
    result.pushKV("lineage_metadata_present",
                  node.lineage_metadata_present);
    result.pushKV("lineage_metadata_valid", node.lineage_metadata_valid);
    result.pushKV("lineage_family_fingerprint",
                  node.lineage_family_fingerprint.GetHex());
    result.pushKV("lineage_root_txid", node.lineage_root_txid.GetHex());
    result.pushKV("lineage_parent_txid",
                  node.lineage_parent_txid.GetHex());
    result.pushKV("lineage_ordinal", node.lineage_ordinal);
    result.pushKV("abandoned", node.abandoned);
    result.pushKV("expired_locally_retired", node.expired_locally_retired);
    result.pushKV("stale_depth", node.stale_depth);
    result.pushKV("stale_depth_known", node.stale_depth_known);
    result.pushKV("resolution_metadata_valid", node.resolution_metadata_valid);
    result.pushKV("resolution_relay_authorized", node.resolution_relay_authorized);
    result.pushKV("resolution_relay_revoked", node.resolution_relay_revoked);
    return result;
}

static UniValue ShadowPowRecoveryComponentToJSON(const ShadowPowClaimRecoveryComponent& component)
{
    UniValue result(UniValue::VOBJ);
    UniValue anchor(UniValue::VOBJ);
    anchor.pushKV("txid", component.anchor.hash.GetHex());
    anchor.pushKV("vout", component.anchor.n);
    anchor.pushKV("amount", ValueFromAmount(component.anchor_amount));
    anchor.pushKV("scriptPubKey", HexStr(component.anchor_script));
    result.pushKV("anchor", std::move(anchor));
    result.pushKV("generation_fingerprint", component.generation_fingerprint.GetHex());
    result.pushKV("component_fingerprint", component.fingerprint.GetHex());
    result.pushKV("classification", ShadowPowRecoveryStateName(component.state));
    result.pushKV("claim_txids", ShadowPowTxidsToJSON(component.claim_txids));
    result.pushKV("root_claim_txids", ShadowPowTxidsToJSON(component.root_claim_txids));
    result.pushKV("resolution_txids", ShadowPowTxidsToJSON(component.resolution_txids));
    result.pushKV("ordinary_or_mixed_txids", ShadowPowTxidsToJSON(component.ordinary_or_mixed_txids));
    result.pushKV("descendant_claims", static_cast<uint64_t>(component.descendant_claims));
    result.pushKV("minimum_stale_depth", component.minimum_stale_depth);
    result.pushKV("stale_depth_known", component.stale_depth_known);
    result.pushKV("anchor_authenticated", component.anchor_authenticated);
    result.pushKV("anchor_unspent", component.anchor_unspent);
    result.pushKV("anchor_user_locked", component.anchor_user_locked);
    result.pushKV("all_claims_quarantined", component.all_claims_quarantined);
    result.pushKV("all_claims_explicitly_provenanced", component.all_claims_explicitly_provenanced);
    result.pushKV("all_claims_zero_payment_retirable",
                  component.all_claims_zero_payment_retirable);
    result.pushKV("all_claims_expired_locally_retired",
                  component.all_claims_expired_locally_retired);
    result.pushKV("has_revalidating_unbound_proof",
                  component.has_revalidating_unbound_proof);
    result.pushKV("adoption_graph_safe", component.adoption_graph_safe);
    UniValue nodes(UniValue::VARR);
    for (const auto& node : component.nodes) nodes.push_back(ShadowPowRecoveryNodeToJSON(node));
    result.pushKV("nodes", std::move(nodes));
    return result;
}

static void EnsureShadowPowRecoveryChainReady(CWallet& wallet)
{
    wallet.BlockUntilSyncedToCurrentChain();
    if (!wallet.chain().isReadyToBroadcast()) {
        throw JSONRPCError(RPC_CLIENT_IN_INITIAL_DOWNLOAD,
                           "Gold Rush PoW claim recovery is unavailable while the node is reindexing, importing blocks, or in initial block download");
    }
}

static int ShadowPowRecoveryRefusalCode(const ShadowPowClaimRecoveryAction& refusal)
{
    if (refusal.reason_code == "selector-not-found") return RPC_INVALID_ADDRESS_OR_KEY;
    if (refusal.reason_code == "fee-consumes-anchor" ||
        refusal.reason_code == "resolution-output-dust") {
        return RPC_WALLET_INSUFFICIENT_FUNDS;
    }
    if (refusal.reason_code == "invalid-fee-limits" ||
        refusal.reason_code == "fee-rate-below-minimum" ||
        refusal.reason_code == "batch-fee-cap-exceeded" ||
        refusal.reason_code == "fee-rate-cannot-modify-signed" ||
        refusal.reason_code == "anchor-not-authenticated" ||
        refusal.reason_code == "anchor-spent" ||
        refusal.reason_code == "component-no-claims" ||
        refusal.reason_code == "claim-confirmed" ||
        refusal.reason_code == "claim-live" ||
        refusal.reason_code == "claim-not-quarantined" ||
        refusal.reason_code == "claim-malformed" ||
        refusal.reason_code == "claim-not-terminal") {
        return RPC_INVALID_PARAMETER;
    }
    return RPC_WALLET_ERROR;
}

[[noreturn]] static void ThrowShadowPowRecoveryFailure(const ShadowPowClaimRecoveryResult& result)
{
    if (result.stale_plan || !result.plan.complete || !result.plan.wallet_tip_matches) {
        throw JSONRPCError(RPC_VERIFY_REJECTED,
                           result.error.empty() ? "Gold Rush PoW recovery plan is stale" : result.error);
    }
    if (!result.plan.refused.empty()) {
        const auto& refusal = result.plan.refused.front();
        throw JSONRPCError(ShadowPowRecoveryRefusalCode(refusal),
                           refusal.reason_code + ": " + refusal.detail);
    }
    throw JSONRPCError(RPC_WALLET_ERROR,
                       result.error.empty() ? "Gold Rush PoW recovery failed" : result.error);
}

[[noreturn]] static void ThrowCreateShadowPowClaimResolutionFailure(
    const ShadowPowClaimRecoveryResult& result)
{
    // Preserve the established one-claim RPC diagnostic while deriving the
    // decision exclusively from the shared typed component classifier.
    if (!result.plan.refused.empty() &&
        result.plan.refused.front().reason_code == "ordinary-conflict") {
        throw JSONRPCError(
            RPC_WALLET_ERROR,
            "Gold Rush PoW claim has an unresolved wallet descendant; resolve or abandon the descendant before preparing a conflict that would invalidate it");
    }
    ThrowShadowPowRecoveryFailure(result);
}

static ShadowPowClaimRecoveryRequest ManualShadowPowRecoveryRequest(CWallet& wallet,
                                                                    const std::vector<uint256>& selectors)
{
    ShadowPowClaimRecoveryRequest request;
    request.origin = ShadowPowClaimRecoveryOrigin::MANUAL;
    request.selectors = selectors;
    request.max_fee_per_resolution = wallet.m_default_max_tx_fee;
    request.aggregate_batch_fee_cap = wallet.m_default_max_tx_fee;
    return request;
}

static ShadowPowClaimRecoveryPlan CurrentShadowPowRecoveryPlan(
    CWallet& wallet, ShadowPowClaimRecoveryRequest request)
{
    request.mode = ShadowPowClaimRecoveryMode::PREVIEW;
    request.execution_authority = ShadowPowClaimRecoveryExecutionAuthority::NONE;
    request.acknowledge_fee_and_conflict_risk = false;
    request.expected_plan_id.reset();
    // A persisted exact transaction cannot be repriced. The refreshed plan
    // reports its actual signed fee instead of carrying a consumed request's
    // fee-rate override into a guaranteed refusal.
    request.fee_rate.reset();
    return wallet.PlanShadowPowClaimRecovery(request);
}

static void ValidateCreateShadowPowClaimResolutionSelector(
    CWallet& wallet, const uint256& claim_txid)
{
    LOCK2(::cs_main, wallet.cs_wallet);
    const CWalletTx* claim = wallet.GetWalletTx(claim_txid);
    if (!claim) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY,
                           "Gold Rush PoW claim not found in this wallet");
    }
    if (!claim->tx || !TransactionHasShadowProof(*claim->tx)) {
        throw JSONRPCError(RPC_INVALID_PARAMETER,
                           "claim_txid is not a Gold Rush PoW QQSPROOF transaction");
    }
    if (wallet.GetTxDepthInMainChain(*claim) != 0 ||
        !claim->isUnconfirmed()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER,
                           "Gold Rush PoW claim is already resolved on chain");
    }
}

static RPCHelpMan createshadowpowclaimresolution()
{
    return RPCHelpMan{
        "createshadowpowclaimresolution",
        "\nPreview or sign, but never broadcast, one canonical Gold Rush PoW claim-component resolution. Any claim txid in the component maps to the same current confirmed anchor. Newly signed bytes are durably retained as a non-relayable draft until commitshadowpowclaimresolution, an explicit sendrawtransaction, or a bulk commit authorizes those exact bytes. A reused managed resolution may already have durable relay authority or a local revocation tombstone, both of which are reported explicitly. A tombstone can be cleared only by a fresh exact-plan commit.\n",
        {
            {"claim_txid", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Wallet-known QQSPROOF transaction id."},
            {"dry_run", RPCArg::Type::BOOL, RPCArg::Default{true}, "Return a side-effect-free exact plan when true."},
            {"acknowledge_fee_and_conflict_risk", RPCArg::Type::BOOL, RPCArg::Default{false}, "Required when dry_run=false; signing never broadcasts."},
            {"fee_rate", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Optional fee rate in " + CURRENCY_ATOM + "/vB."},
            {"expected_plan_id", RPCArg::Type::STR_HEX, RPCArg::Optional::OMITTED, "Exact plan_id returned by a prior dry_run=true preview. Required when dry_run=false."},
        },
        RPCResult{RPCResult::Type::OBJ, "", "Compatibility fields plus the exact component plan.", {
            {RPCResult::Type::BOOL, "dry_run", "Whether this was a preview."},
            {RPCResult::Type::BOOL, "broadcast", "Always false."},
            {RPCResult::Type::BOOL, "reused_legacy_resolution", "Whether a legacy signed cleanup was reused."},
            {RPCResult::Type::BOOL, "reused_managed_resolution", "Whether exact managed bytes were reused."},
            {RPCResult::Type::STR_HEX, "claim_txid", "Caller-provided selector."},
            {RPCResult::Type::STR_HEX, "claim_input_txid", "Canonical confirmed anchor transaction."},
            {RPCResult::Type::NUM, "claim_input_vout", "Canonical confirmed anchor output."},
            {RPCResult::Type::STR_AMOUNT, "input_amount", "Anchor value."},
            {RPCResult::Type::STR_AMOUNT, "fee", "Fee paid only if this resolution confirms."},
            {RPCResult::Type::STR_AMOUNT, "output_amount", "Value returned to the exact anchor script."},
            {RPCResult::Type::NUM, "vsize", "Current transaction virtual size."},
            {RPCResult::Type::STR_HEX, "hex", /*optional=*/true, "Exact signed bytes when dry_run=false."},
            {RPCResult::Type::STR_HEX, "txid", /*optional=*/true, "Exact signed transaction id when dry_run=false."},
            {RPCResult::Type::STR_HEX, "plan_id", /*optional=*/true, "Reusable exact plan identifier returned only when dry_run=true."},
            {RPCResult::Type::STR_HEX, "acknowledged_plan_id", /*optional=*/true, "Exact preview plan accepted and consumed by dry_run=false."},
            {RPCResult::Type::BOOL, "plan_consumed", "Whether the returned acknowledged plan was consumed by signing."},
            {RPCResult::Type::BOOL, "plan_reusable", "True only for a side-effect-free preview."},
            {RPCResult::Type::STR_HEX, "active_tip", "Active tip to which this plan is bound."},
            {RPCResult::Type::NUM, "wallet_generation", "Wallet database generation protected by the plan."},
            {RPCResult::Type::STR_HEX, "generation_fingerprint", "Stable confirmed-anchor generation identifier."},
            {RPCResult::Type::STR_HEX, "component_fingerprint", "Tip-pinned complete component fingerprint."},
            {RPCResult::Type::STR, "classification", "Shared typed component classification."},
            {RPCResult::Type::ARR, "claim_txids", "All claim transactions in the selected component.", {{RPCResult::Type::STR_HEX, "", "Claim transaction id."}}},
            {RPCResult::Type::NUM, "descendant_claims", "Claim descendants reconciled as one component."},
            {RPCResult::Type::BOOL, "persisted", "Whether exact signed bytes already have a durable wallet record."},
            {RPCResult::Type::BOOL, "success", "Whether signing and durable persistence completed."},
            {RPCResult::Type::STR, "error", "Execution-level error detail, empty on success."},
            {RPCResult::Type::BOOL, "durable_state_changed", "Whether this invocation durably persisted new exact bytes."},
            {RPCResult::Type::BOOL, "durable_state_ambiguous", "Whether database commit or rollback had an indeterminate outcome. Reload may reveal the exact bytes."},
            {RPCResult::Type::NUM, "relay_authority_granted", "Always zero here; this RPC never grants relay authority."},
            {RPCResult::Type::BOOL, "relay_authorized", "Whether these exact managed bytes already have durable relay authority. This RPC never grants it."},
            {RPCResult::Type::BOOL, "relay_revoked", "Whether these exact managed bytes carry a durable local relay-revocation tombstone."},
            {RPCResult::Type::BOOL, "conflicts_with_revalidating_unbound_proof", "Whether this resolution deliberately conflicts with an unbound proof that is invalid on the pinned tip but may become valid on a descendant."},
            {RPCResult::Type::OBJ, "current_plan", /*optional=*/true, "Fresh read-only commit preview keyed by the exact signed resolution txid. Pass its plan_id to commitshadowpowclaimresolution only when nested plan_reusable=true.", {{RPCResult::Type::ELISION, "", ""}}},
            {RPCResult::Type::STR, "next_step", "Next explicit action."},
            {RPCResult::Type::STR, "warning", "Conflict, fee, and confirmation warning."},
        }},
        RPCExamples{
            HelpExampleCli("createshadowpowclaimresolution", "\"claim_txid\"") +
            HelpExampleCli("createshadowpowclaimresolution", "\"claim_txid\" false true null \"expected_plan_id\"") +
            HelpExampleCli("-named createshadowpowclaimresolution", "claim_txid=\"claim_txid\" dry_run=false acknowledge_fee_and_conflict_risk=true fee_rate=1 expected_plan_id=\"expected_plan_id\"")
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    EnsureShadowPowRecoveryChainReady(*pwallet);
    if (pwallet->IsShadowPowClaimRecoveryDatabaseAmbiguous()) {
        throw JSONRPCError(
            RPC_WALLET_ERROR,
            "Recovery database outcome is ambiguous. Reload the wallet and inspect its recovery records before previewing or signing another resolution");
    }

    const uint256 claim_txid = ParseHashV(request.params[0], "claim_txid");
    ValidateCreateShadowPowClaimResolutionSelector(*pwallet, claim_txid);
    const bool dry_run = request.params[1].isNull() || request.params[1].get_bool();
    const bool acknowledged = !request.params[2].isNull() && request.params[2].get_bool();
    if (!dry_run && !acknowledged) {
        throw JSONRPCError(RPC_INVALID_PARAMETER,
                           "acknowledge_fee_and_conflict_risk=true is required to sign a claim-resolution transaction; preview first with dry_run=true");
    }
    std::optional<uint256> expected_plan_id;
    if (!request.params[4].isNull()) {
        expected_plan_id = ParseHashV(request.params[4], "expected_plan_id");
    }
    if (dry_run && (acknowledged || expected_plan_id)) {
        throw JSONRPCError(
            RPC_INVALID_PARAMETER,
            "dry_run=true is side-effect-free and does not accept acknowledgement or expected_plan_id");
    }
    if (!dry_run && !expected_plan_id) {
        throw JSONRPCError(
            RPC_INVALID_PARAMETER,
            "expected_plan_id from a prior dry_run=true preview is required to sign a claim-resolution transaction");
    }

    ShadowPowClaimRecoveryRequest preview = ManualShadowPowRecoveryRequest(*pwallet, {claim_txid});
    preview.mode = ShadowPowClaimRecoveryMode::PREVIEW;
    if (!request.params[3].isNull()) preview.fee_rate = FeeRateFromSatVbValue(request.params[3]);
    ShadowPowClaimRecoveryResult execution = pwallet->ResolveShadowPowClaims(preview);
    if (!execution.success || execution.plan.actions.size() != 1) {
        ThrowCreateShadowPowClaimResolutionFailure(execution);
    }

    std::optional<ShadowPowClaimRecoveryPlan> current_plan;
    if (!dry_run) {
        EnsureWalletIsUnlocked(*pwallet);
        ShadowPowClaimRecoveryRequest sign = preview;
        sign.mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
        sign.execution_authority = ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
        sign.acknowledge_fee_and_conflict_risk = true;
        sign.expected_plan_id = expected_plan_id;
        execution = pwallet->ResolveShadowPowClaims(sign);
        if ((!execution.success && !execution.durable_state_changed &&
             !execution.durable_state_ambiguous) ||
            execution.plan.actions.size() != 1) {
            ThrowCreateShadowPowClaimResolutionFailure(execution);
        }
        if (!execution.durable_state_ambiguous &&
            execution.plan.actions.size() == 1 &&
            execution.plan.actions.front().transaction) {
            ShadowPowClaimRecoveryRequest commit_preview =
                ManualShadowPowRecoveryRequest(
                    *pwallet,
                    {execution.plan.actions.front().transaction->GetHash()});
            current_plan = CurrentShadowPowRecoveryPlan(
                *pwallet, std::move(commit_preview));
        }
    }

    const ShadowPowClaimRecoveryAction& action = execution.plan.actions.front();
    if (!action.transaction || action.transaction->vout.size() != 1) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Recovery resolver returned no complete single-output transaction");
    }
    const bool reused_legacy = action.status == ShadowPowClaimRecoveryActionStatus::REUSE_LEGACY;
    const bool reused_managed = action.status == ShadowPowClaimRecoveryActionStatus::REUSE_MANAGED;
    const CAmount output_amount = action.transaction->vout.front().nValue;

    UniValue result(UniValue::VOBJ);
    result.pushKV("dry_run", dry_run);
    result.pushKV("broadcast", false);
    result.pushKV("reused_legacy_resolution", reused_legacy);
    result.pushKV("reused_managed_resolution", reused_managed);
    result.pushKV("claim_txid", claim_txid.GetHex());
    result.pushKV("claim_input_txid", action.anchor.hash.GetHex());
    result.pushKV("claim_input_vout", action.anchor.n);
    result.pushKV("input_amount", ValueFromAmount(output_amount + action.fee));
    result.pushKV("fee", ValueFromAmount(action.fee));
    result.pushKV("output_amount", ValueFromAmount(output_amount));
    result.pushKV("vsize", action.vsize);
    if (dry_run) {
        result.pushKV("plan_id", execution.plan.plan_id.GetHex());
    } else {
        result.pushKV("acknowledged_plan_id", execution.plan.plan_id.GetHex());
    }
    result.pushKV("plan_consumed", !dry_run);
    result.pushKV("plan_reusable", dry_run);
    result.pushKV("active_tip", execution.plan.active_tip.GetHex());
    result.pushKV("wallet_generation", execution.plan.wallet_generation);
    result.pushKV("generation_fingerprint", action.generation_fingerprint.GetHex());
    result.pushKV("component_fingerprint", action.component_fingerprint.GetHex());
    result.pushKV("classification", ShadowPowRecoveryStateName(action.component_state));
    result.pushKV("claim_txids", ShadowPowTxidsToJSON(action.claim_txids));
    result.pushKV("descendant_claims", static_cast<uint64_t>(action.descendant_claims));
    result.pushKV("persisted", action.persisted);
    result.pushKV("success", execution.success);
    result.pushKV("error", execution.error);
    result.pushKV("durable_state_changed", execution.durable_state_changed);
    result.pushKV("durable_state_ambiguous", execution.durable_state_ambiguous);
    result.pushKV("relay_authority_granted", static_cast<uint64_t>(execution.relay_authority_granted));
    result.pushKV("relay_authorized", action.relay_authorized);
    result.pushKV("relay_revoked", action.relay_revoked);
    result.pushKV("conflicts_with_revalidating_unbound_proof",
                  action.conflicts_with_revalidating_unbound_proof);
    if (current_plan) {
        result.pushKV("current_plan", ShadowPowRecoveryPlanToJSON(
            *current_plan, ShadowPowClaimRecoveryMode::PREVIEW));
    }
    if (!dry_run && !execution.durable_state_ambiguous) {
        result.pushKV("hex", EncodeHexTx(*action.transaction));
        result.pushKV("txid", action.transaction->GetHash().GetHex());
    }
    if (!dry_run) {
        const bool reusable_commit_plan = current_plan &&
            current_plan->complete && current_plan->wallet_tip_matches &&
            !current_plan->plan_id.IsNull() &&
            current_plan->actions.size() == 1;
        result.pushKV("next_step", execution.durable_state_ambiguous
            ? "The durable database outcome is ambiguous. Stop recovery activity and reload the wallet. Reload may reveal these exact bytes; inspect wallet records before retrying and do not assume the operation rolled back."
            : action.relay_authorized
            ? "These exact bytes already have durable relay authority; monitor mempool and confirmation state while the scheduler safely retries them."
            : action.relay_revoked
            ? "Local relay authority is durably revoked. Obtain a fresh current recovery plan and explicitly commit it while normally unlocked only if these exact bytes should be reauthorized."
            : reusable_commit_plan
            ? "Review the exact fee and warning, then call commitshadowpowclaimresolution with this txid, explicit acknowledgement, and current_plan.plan_id. sendrawtransaction remains compatible."
            : "The signed bytes are retained without relay authority, but no reusable commit plan is available on the current snapshot. Call commitshadowpowclaimresolution with this txid and no acknowledgement to obtain a fresh side-effect-free plan before authorizing relay.");
    } else {
        result.pushKV("next_step", "Repeat with dry_run=false and acknowledge_fee_and_conflict_risk=true to sign and durably store exact non-broadcast bytes.");
    }
    result.pushKV(
        "warning",
        action.conflicts_with_revalidating_unbound_proof
            ? "This resolution deliberately conflicts with an unbound proof that is invalid on the pinned tip but may become valid on a descendant. Exact-plan fee/conflict acknowledgement is required. This is an on-chain conflict, not abandonment; confirmation is not guaranteed, and recovery never enables mining."
            : "This is an on-chain conflict, not abandonment. Confirmation is not guaranteed. The input remains reserved until the original claim or resolution confirms, and recovery never enables mining.");
    return result;
},
    };
}

static RPCHelpMan commitshadowpowclaimresolution()
{
    return RPCHelpMan{
        "commitshadowpowclaimresolution",
        "\nPreview, or explicitly authorize and broadcast, one exact previously signed claim-component resolution. With acknowledgement omitted or false, this is side-effect-free and returns the resolution-selector plan needed for a later commit. A managed resolution receives durable exact-byte retry authority across restart. A legacy resolution may be relayed by an explicit commit but does not gain managed scheduler authority. This RPC never authorizes another transaction or enables mining.\n",
        {
            {"resolution_txid", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Persisted managed or legacy resolution transaction id."},
            {"acknowledge_fee_and_conflict_risk", RPCArg::Type::BOOL, RPCArg::Default{false}, "False returns a side-effect-free commit preview. True authorizes relay and requires expected_plan_id."},
            {"expected_plan_id", RPCArg::Type::STR_HEX, RPCArg::Optional::OMITTED, "Exact plan_id returned by this RPC's side-effect-free preview or as current_plan after signing. Required only when acknowledgement is true."},
        },
        RPCResult{RPCResult::Type::OBJ, "", "Execution result.", ShadowPowRecoveryExecutionResults()},
        RPCExamples{
            HelpExampleCli("commitshadowpowclaimresolution", "\"resolution_txid\"") +
            HelpExampleCli("commitshadowpowclaimresolution", "\"resolution_txid\" true \"expected_plan_id\"")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    EnsureShadowPowRecoveryChainReady(*pwallet);
    const bool acknowledged =
        !request.params[1].isNull() && request.params[1].get_bool();
    const bool has_expected_plan = !request.params[2].isNull();
    if (!acknowledged && has_expected_plan) {
        throw JSONRPCError(RPC_INVALID_PARAMETER,
                           "expected_plan_id is accepted only with acknowledge_fee_and_conflict_risk=true");
    }
    if (acknowledged && !has_expected_plan) {
        throw JSONRPCError(RPC_INVALID_PARAMETER,
                           "expected_plan_id from a side-effect-free commit preview is required to authorize relay");
    }
    if (pwallet->IsShadowPowClaimRecoveryDatabaseAmbiguous()) {
        ShadowPowClaimRecoveryResult ambiguous;
        ambiguous.durable_state_ambiguous = true;
        ambiguous.error = "Recovery database outcome is ambiguous. Reload the wallet; exact persisted or relay-authorized bytes may appear after reload";
        return ShadowPowRecoveryResultToJSON(
            ambiguous,
            acknowledged
                ? ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST
                : ShadowPowClaimRecoveryMode::PREVIEW);
    }
    const uint256 resolution_txid = ParseHashV(request.params[0], "resolution_txid");
    bool selector_known{false};
    bool selector_is_resolution{false};
    const ShadowPowClaimRecoveryInventory inventory =
        pwallet->GetShadowPowClaimRecoveryInventory();
    for (const auto& component : inventory.components) {
        for (const auto& node : component.nodes) {
            if (node.txid != resolution_txid) continue;
            selector_known = true;
            selector_is_resolution =
                node.kind == ShadowPowClaimRecoveryNodeKind::MANAGED_RESOLUTION ||
                node.kind == ShadowPowClaimRecoveryNodeKind::LEGACY_RESOLUTION;
        }
    }
    if (!selector_known) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY,
                           "Claim-resolution transaction not found in this wallet's current recovery inventory");
    }
    if (!selector_is_resolution) {
        throw JSONRPCError(RPC_INVALID_PARAMETER,
                           "resolution_txid must identify exact, previously signed claim-resolution bytes; use createshadowpowclaimresolution first");
    }
    ShadowPowClaimRecoveryRequest preview = ManualShadowPowRecoveryRequest(*pwallet, {resolution_txid});
    preview.mode = ShadowPowClaimRecoveryMode::PREVIEW;
    ShadowPowClaimRecoveryResult execution = pwallet->ResolveShadowPowClaims(preview);
    if (execution.durable_state_ambiguous) {
        return ShadowPowRecoveryResultToJSON(
            execution,
            acknowledged
                ? ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST
                : ShadowPowClaimRecoveryMode::PREVIEW);
    }
    if (!execution.success || execution.plan.actions.size() != 1) {
        ThrowShadowPowRecoveryFailure(execution);
    }
    if (!acknowledged) {
        return ShadowPowRecoveryResultToJSON(
            execution, ShadowPowClaimRecoveryMode::PREVIEW);
    }
    EnsureWalletIsUnlocked(*pwallet);
    ShadowPowClaimRecoveryRequest commit = preview;
    commit.mode = ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST;
    commit.execution_authority = ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
    commit.acknowledge_fee_and_conflict_risk = true;
    commit.expected_plan_id =
        ParseHashV(request.params[2], "expected_plan_id");
    execution = pwallet->ResolveShadowPowClaims(commit);
    if (!execution.success && !execution.durable_state_changed &&
        !execution.durable_state_ambiguous) {
        ThrowShadowPowRecoveryFailure(execution);
    }
    const std::optional<ShadowPowClaimRecoveryPlan> current_plan =
        execution.durable_state_ambiguous
            ? std::nullopt
            : std::optional<ShadowPowClaimRecoveryPlan>{
                  CurrentShadowPowRecoveryPlan(*pwallet, commit)};
    return ShadowPowRecoveryResultToJSON(
        execution, commit.mode,
        current_plan ? &*current_plan : nullptr);
},
    };
}

static UniValue ShadowPowClaimResolutionRevocationToJSON(
    const ShadowPowClaimResolutionRevocationResult& revocation)
{
    UniValue result(UniValue::VOBJ);
    result.pushKV("status", std::string(
        ShadowPowClaimResolutionRevocationStatusName(revocation.status)));
    result.pushKV("success", revocation.success);
    result.pushKV("resolution_txid", revocation.resolution_txid.GetHex());
    if (!revocation.anchor.IsNull()) {
        UniValue anchor(UniValue::VOBJ);
        anchor.pushKV("txid", revocation.anchor.hash.GetHex());
        anchor.pushKV("vout", revocation.anchor.n);
        result.pushKV("anchor", std::move(anchor));
        result.pushKV("generation_fingerprint",
                      revocation.generation_fingerprint.GetHex());
    }
    result.pushKV("acknowledged_signed_bytes_may_exist_elsewhere", true);
    if (revocation.relay_authority_was_active) {
        result.pushKV("relay_authority_was_active",
                      *revocation.relay_authority_was_active);
    }
    if (revocation.relay_authority_revoked) {
        result.pushKV("relay_authority_revoked",
                      *revocation.relay_authority_revoked);
    }
    if (revocation.locally_cancelled) {
        result.pushKV("locally_cancelled", *revocation.locally_cancelled);
    }
    if (revocation.durable_state_changed) {
        result.pushKV("durable_state_changed",
                      *revocation.durable_state_changed);
    }
    result.pushKV("durable_state_ambiguous",
                  revocation.durable_state_ambiguous);
    if (revocation.in_mempool) {
        result.pushKV("in_mempool", *revocation.in_mempool);
    }
    if (revocation.broadcast_in_flight) {
        result.pushKV("broadcast_in_flight", *revocation.broadcast_in_flight);
    }
    if (revocation.may_still_confirm) {
        result.pushKV("may_still_confirm", *revocation.may_still_confirm);
    }
    if (revocation.anchor_reserved) {
        result.pushKV("anchor_reserved", *revocation.anchor_reserved);
    }
    if (revocation.normal_coin_selection_enabled) {
        result.pushKV("normal_coin_selection_enabled",
                      *revocation.normal_coin_selection_enabled);
    }
    if (revocation.mining_gate_available) {
        result.pushKV("mining_gate_action", ShadowPowMiningGateActionName(
            revocation.mining_gate_action));
    }
    result.pushKV("detail", revocation.detail);
    if (revocation.durable_state_ambiguous) {
        result.pushKV("next_step", "Stop recovery activity and reload the wallet. Inspect the exact managed record after reload before relying on either the prior relay authority or the requested tombstone.");
    } else if (revocation.broadcast_in_flight.value_or(false)) {
        result.pushKV("next_step", "Wait for the in-flight local broadcast verdict, then call revokeshadowpowclaimresolution again. This failed attempt changed no durable authority.");
    } else if (revocation.success) {
        result.pushKV("next_step", "Local automatic retry is cancelled. The transaction and anchor remain reserved. To reauthorize these exact bytes, obtain a fresh recovery preview and explicitly commit its exact plan while normally unlocked.");
    } else {
        result.pushKV("next_step", "No revocation was committed. Correct the reported wallet state, then inspect and retry without assuming relay authority changed.");
    }
    std::string warning = "Revocation affects only this wallet's future relay authority. Any copies already disclosed to this node's mempool, peers, miners, logs, or backups cannot be recalled and may still confirm.";
    if (revocation.anchor_reserved.value_or(false)) {
        warning += " The shared anchor remains unavailable to normal coin selection until active-chain confirmation resolves the conflict.";
    } else if (revocation.anchor_reserved.has_value()) {
        warning += " The wallet did not authenticate the shared anchor as reserved, so no local cancellation was committed.";
    } else {
        warning += " Anchor reservation and normal-coin-selection state are unknown until the wallet is reloaded and the managed record is authenticated.";
    }
    result.pushKV("warning", std::move(warning));
    return result;
}

static RPCHelpMan revokeshadowpowclaimresolution()
{
    return RPCHelpMan{
        "revokeshadowpowclaimresolution",
        "\nDurably cancel this wallet's future scheduler/relay authority for one exact managed Gold Rush PoW claim resolution. This restriction-only operation does not require wallet unlock, abandon or delete the signed transaction, remove it from the mempool, recall peer copies, release its anchor, or enable mining. A fresh exact-plan commit is required to clear the durable tombstone.\n",
        {
            {"resolution_txid", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Exact wallet-managed resolution transaction id."},
            {"acknowledge_signed_bytes_may_exist_elsewhere", RPCArg::Type::BOOL, RPCArg::Optional::NO, "Must be true; local revocation cannot recall already disclosed or relayed bytes and cannot prevent their confirmation."},
        },
        RPCResult{RPCResult::Type::OBJ, "", "Durable local-cancellation receipt.", {
            {RPCResult::Type::STR, "status", "success, already_revoked, broadcast_in_flight, database_failure, or database_outcome_ambiguous."},
            {RPCResult::Type::BOOL, "success", "Whether the durable tombstone is authoritatively active."},
            {RPCResult::Type::STR_HEX, "resolution_txid", "Exact managed transaction."},
            {RPCResult::Type::OBJ, "anchor", /*optional=*/true, "Still-reserved confirmed anchor.", {
                {RPCResult::Type::STR_HEX, "txid", "Anchor transaction id."},
                {RPCResult::Type::NUM, "vout", "Anchor output index."},
            }},
            {RPCResult::Type::STR_HEX, "generation_fingerprint", /*optional=*/true, "Authenticated anchor-generation identity."},
            {RPCResult::Type::BOOL, "acknowledged_signed_bytes_may_exist_elsewhere", "Always true for a processed request."},
            {RPCResult::Type::BOOL, "relay_authority_was_active", /*optional=*/true, "Whether durable retry authority was active before this call; omitted when prior database ambiguity prevents authentication."},
            {RPCResult::Type::BOOL, "relay_authority_revoked", /*optional=*/true, "Whether the durable relay-revocation tombstone is active; omitted when the requested commit outcome is ambiguous."},
            {RPCResult::Type::BOOL, "locally_cancelled", /*optional=*/true, "Whether this wallet authoritatively refuses scheduler and generic wallet relay promotion for the exact bytes; omitted when durable outcome is unknown."},
            {RPCResult::Type::BOOL, "durable_state_changed", /*optional=*/true, "Whether this invocation newly committed the tombstone; omitted when commit outcome is ambiguous."},
            {RPCResult::Type::BOOL, "durable_state_ambiguous", "Whether the database commit outcome is unknown and requires reload."},
            {RPCResult::Type::BOOL, "in_mempool", /*optional=*/true, "Whether the exact bytes were already in this node's mempool at the revocation snapshot; omitted when the record could not be authenticated."},
            {RPCResult::Type::BOOL, "broadcast_in_flight", /*optional=*/true, "Whether an already-reserved local broadcast prevented revocation; omitted when the record could not be authenticated."},
            {RPCResult::Type::BOOL, "may_still_confirm", /*optional=*/true, "Always true after authentication: local cancellation cannot undo an existing confirmation or recall copies that may confirm."},
            {RPCResult::Type::BOOL, "anchor_reserved", /*optional=*/true, "Whether the shared anchor remains wallet-reserved; omitted when the record could not be authenticated."},
            {RPCResult::Type::BOOL, "normal_coin_selection_enabled", /*optional=*/true, "Always false on successful revocation; omitted when the record could not be authenticated."},
            {RPCResult::Type::STR, "mining_gate_action", /*optional=*/true, "Post-attempt typed mining-gate action when a wallet/chain snapshot was available."},
            {RPCResult::Type::STR, "detail", "Machine outcome detail."},
            {RPCResult::Type::STR, "next_step", "Required reload, retry, monitoring, or fresh-plan action."},
            {RPCResult::Type::STR, "warning", "Irrevocable-copy and anchor-reservation warning."},
        }},
        RPCExamples{
            HelpExampleCli("revokeshadowpowclaimresolution", "\"resolution_txid\" true")
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    if (!request.params[1].get_bool()) {
        throw JSONRPCError(
            RPC_INVALID_PARAMETER,
            "acknowledge_signed_bytes_may_exist_elsewhere=true is required; local revocation cannot recall signed bytes already held by this node, peers, miners, logs, or backups");
    }
    const uint256 resolution_txid = ParseHashV(
        request.params[0], "resolution_txid");
    const ShadowPowClaimResolutionRevocationResult revocation =
        pwallet->RevokeManagedShadowPowResolutionRelayAuthority(
            resolution_txid);
    if (revocation.status ==
        ShadowPowClaimResolutionRevocationStatus::NOT_FOUND) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, revocation.detail);
    }
    if (revocation.status ==
            ShadowPowClaimResolutionRevocationStatus::NOT_MANAGED ||
        revocation.status ==
            ShadowPowClaimResolutionRevocationStatus::INVALID_METADATA ||
        revocation.status ==
            ShadowPowClaimResolutionRevocationStatus::ANCHOR_NOT_RESERVED) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, revocation.detail);
    }
    return ShadowPowClaimResolutionRevocationToJSON(revocation);
},
    };
}

static RPCHelpMan resolveallshadowpowclaims()
{
    return RPCHelpMan{
        "resolveallshadowpowclaims",
        "\nPreview or execute one current resolution per independent confirmed claim anchor. A later original-claim confirmation can advance a frontier, so one call never promises finality. Non-preview actions require the exact plan_id returned by preview plus explicit fee/conflict acknowledgement.\n",
        {
            {"options", RPCArg::Type::OBJ_NAMED_PARAMS, RPCArg::Optional::OMITTED, "Manual batch recovery controls.", {
                {"action", RPCArg::Type::STR, RPCArg::Default{"preview"}, "preview, sign_only, or commit_and_broadcast."},
                {"expected_plan_id", RPCArg::Type::STR_HEX, RPCArg::Optional::OMITTED, "Required exact preview plan for mutations."},
                {"acknowledge_fee_and_conflict_risk", RPCArg::Type::BOOL, RPCArg::Default{false}, "Required for mutations."},
                {"fee_rate", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Optional fee rate in " + CURRENCY_ATOM + "/vB."},
                {"max_fee_per_resolution", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Optional absolute per-resolution cap."},
                {"max_total_fee", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Optional aggregate batch cap."},
            }},
        },
        RPCResult{RPCResult::Type::OBJ, "", "Pinned plan and execution result.", ShadowPowRecoveryExecutionResults()},
        RPCExamples{
            HelpExampleCli("resolveallshadowpowclaims", "") +
            HelpExampleCli("resolveallshadowpowclaims", "'{\"action\":\"commit_and_broadcast\",\"expected_plan_id\":\"plan_id\",\"acknowledge_fee_and_conflict_risk\":true}'")
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    EnsureShadowPowRecoveryChainReady(*pwallet);
    const UniValue options = request.params[0].isNull()
        ? UniValue(UniValue::VOBJ) : request.params[0].get_obj();
    const std::string action = options.exists("action")
        ? ToLower(options["action"].get_str()) : "preview";

    ShadowPowClaimRecoveryMode mode;
    if (action == "preview") mode = ShadowPowClaimRecoveryMode::PREVIEW;
    else if (action == "sign_only") mode = ShadowPowClaimRecoveryMode::SIGN_ONLY;
    else if (action == "commit_and_broadcast") mode = ShadowPowClaimRecoveryMode::COMMIT_AND_BROADCAST;
    else throw JSONRPCError(RPC_INVALID_PARAMETER,
                            "action must be preview, sign_only, or commit_and_broadcast");

    ShadowPowClaimRecoveryRequest recovery = ManualShadowPowRecoveryRequest(*pwallet, {});
    recovery.mode = mode;
    if (options.exists("fee_rate")) recovery.fee_rate = FeeRateFromSatVbValue(options["fee_rate"]);
    if (options.exists("max_fee_per_resolution")) {
        recovery.max_fee_per_resolution = AmountFromValue(options["max_fee_per_resolution"]);
    }
    if (options.exists("max_total_fee")) {
        recovery.aggregate_batch_fee_cap = AmountFromValue(options["max_total_fee"]);
    }
    if (recovery.max_fee_per_resolution <= 0 ||
        recovery.aggregate_batch_fee_cap < recovery.max_fee_per_resolution) {
        throw JSONRPCError(RPC_INVALID_PARAMETER,
                           "max_fee_per_resolution must be positive and max_total_fee must cover at least one resolution");
    }

    if (mode != ShadowPowClaimRecoveryMode::PREVIEW) {
        const bool acknowledged = options.exists("acknowledge_fee_and_conflict_risk") &&
                                  options["acknowledge_fee_and_conflict_risk"].get_bool();
        if (!acknowledged || !options.exists("expected_plan_id")) {
            throw JSONRPCError(RPC_INVALID_PARAMETER,
                               "non-preview recovery requires expected_plan_id and acknowledge_fee_and_conflict_risk=true");
        }
        recovery.acknowledge_fee_and_conflict_risk = true;
        recovery.execution_authority = ShadowPowClaimRecoveryExecutionAuthority::EXPLICIT_MANUAL;
        recovery.expected_plan_id = ParseHashV(options["expected_plan_id"], "expected_plan_id");
        EnsureWalletIsUnlocked(*pwallet);
    }
    ShadowPowClaimRecoveryResult execution = pwallet->ResolveShadowPowClaims(recovery);
    if (execution.stale_plan && !execution.durable_state_changed &&
        !execution.durable_state_ambiguous) {
        ThrowShadowPowRecoveryFailure(execution);
    }
    if (mode != ShadowPowClaimRecoveryMode::PREVIEW &&
        !execution.success && !execution.durable_state_changed &&
        !execution.durable_state_ambiguous &&
        execution.plan.refused.empty()) {
        ThrowShadowPowRecoveryFailure(execution);
    }
    if (mode == ShadowPowClaimRecoveryMode::PREVIEW) {
        return ShadowPowRecoveryResultToJSON(execution, mode);
    }
    const std::optional<ShadowPowClaimRecoveryPlan> current_plan =
        execution.durable_state_ambiguous
            ? std::nullopt
            : std::optional<ShadowPowClaimRecoveryPlan>{
                  CurrentShadowPowRecoveryPlan(*pwallet, recovery)};
    return ShadowPowRecoveryResultToJSON(
        execution, mode,
        current_plan ? &*current_plan : nullptr);
},
    };
}

static UniValue ShadowPowClaimRecoveryAdoptionToJSON(
    const ShadowPowClaimRecoveryAdoptionResult& adoption);

static RPCHelpMan adoptshadowpowclaimcomponent()
{
    return RPCHelpMan{
        "adoptshadowpowclaimcomponent",
        "\nExplicitly authenticate a reviewed historical claim-only component for future recovery. Adoption is wallet-scoped, exact-tip/fingerprint bound, atomic, and does not sign, broadcast, or enable mining.\n",
        {
            {"claim_txid", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Any claim transaction in the reviewed component."},
            {"expected_tip", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Exact active tip shown during review."},
            {"expected_component_fingerprint", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Exact dynamic component fingerprint shown during review."},
            {"acknowledge_provenance_and_conflict_risk", RPCArg::Type::BOOL, RPCArg::Optional::NO, "Must be true."},
        },
        RPCResult{RPCResult::Type::OBJ, "", "Adoption result.", {
            {RPCResult::Type::STR, "status", "Stable typed adoption status."},
            {RPCResult::Type::STR, "reason_code", "Stable machine-readable status alias."},
            {RPCResult::Type::BOOL, "success", "Whether adoption succeeded or the component was already explicit."},
            {RPCResult::Type::BOOL, "adopted", "Whether the complete component was durably adopted."},
            {RPCResult::Type::BOOL, "durable_state_changed", "Whether complete adoption definitely committed."},
            {RPCResult::Type::BOOL, "durable_state_ambiguous", "Whether commit or rollback had an indeterminate outcome."},
            {RPCResult::Type::STR_HEX, "active_tip", /*optional=*/true, "Current active tip."},
            {RPCResult::Type::STR_HEX, "generation_fingerprint", /*optional=*/true, "Stable anchor generation."},
            {RPCResult::Type::STR_HEX, "reviewed_component_fingerprint", /*optional=*/true, "Caller-reviewed pre-adoption component fingerprint."},
            {RPCResult::Type::STR_HEX, "component_fingerprint", /*optional=*/true, "Compatibility alias for the post-adoption component fingerprint."},
            {RPCResult::Type::STR_HEX, "post_adoption_component_fingerprint", /*optional=*/true, "Atomic post-adoption component fingerprint."},
            {RPCResult::Type::ARR, "claim_txids", "Claims adopted.", {{RPCResult::Type::STR_HEX, "", "Claim transaction id."}}},
            {RPCResult::Type::NUM, "adopted_claims", "Number of claims adopted."},
            {RPCResult::Type::BOOL, "automatic_eligible_after_adoption", "Whether all claim provenance is now explicit; all other safety gates still apply."},
            {RPCResult::Type::BOOL, "component_has_revalidating_unbound_proof", "Whether this component contains an unbound proof that is invalid on the reviewed tip but may become valid on a descendant."},
            {RPCResult::Type::STR, "component_refusal_code", /*optional=*/true, "Shared graph refusal code when status is unsafe_graph."},
            {RPCResult::Type::STR, "detail", "Human-readable typed outcome detail."},
            {RPCResult::Type::STR, "next_step", "Required follow-up action."},
        }},
        RPCExamples{HelpExampleCli("adoptshadowpowclaimcomponent", "\"claim_txid\" \"tip\" \"component_fingerprint\" true")},
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    EnsureShadowPowRecoveryChainReady(*pwallet);
    if (!request.params[3].get_bool()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER,
                           "acknowledge_provenance_and_conflict_risk=true is required to adopt historical claims");
    }
    const uint256 selector = ParseHashV(request.params[0], "claim_txid");
    const uint256 expected_tip = ParseHashV(request.params[1], "expected_tip");
    const uint256 expected_fingerprint = ParseHashV(request.params[2], "expected_component_fingerprint");
    return ShadowPowClaimRecoveryAdoptionToJSON(
        pwallet->AdoptShadowPowClaimRecoveryComponent(
            selector, expected_tip, expected_fingerprint));
},
    };
}

static RPCHelpMan getgoldrushinfo()
{
    return RPCHelpMan{"getgoldrushinfo",
                "\nReturns Blackcoin Gold Rush shadow jackpot and wallet qualification status.\n",
                {},
                RPCResult{
                    RPCResult::Type::OBJ, "", "",
                    {
                        {RPCResult::Type::BOOL, "active", "Whether the Gold Rush shadow reward phase is active by median-time-past."},
                        {RPCResult::Type::NUM, "height", "Current chain height."},
                        {RPCResult::Type::NUM_TIME, "mediantime", "Current tip median-time-past."},
                        {RPCResult::Type::STR_AMOUNT, "pos_jackpot", "Accrued PoS-side jackpot awaiting the next qualified solver/signaler payout."},
                        {RPCResult::Type::STR_AMOUNT, "pow_jackpot", "Estimated PoW-side payout awaiting the next valid memory-hard PoW claim."},
                        {RPCResult::Type::NUM, "pos_amount", "Accrued PoS-side jackpot in satoshis."},
                        {RPCResult::Type::NUM, "pow_amount", "Estimated PoW-side payout awaiting the next valid memory-hard PoW claim in satoshis."},
                        {RPCResult::Type::STR_AMOUNT, "pow_pool_jackpot", "PoW-side jackpot currently accrued in the pool before the next block reward is added."},
                        {RPCResult::Type::NUM, "pow_pool_amount", "PoW-side jackpot currently accrued in the pool before the next block reward is added, in satoshis."},
                        {RPCResult::Type::NUM, "claimed_amount", "Total Gold Rush amount already materialized to wallet-spendable quantum payout coins in satoshis."},
                        {RPCResult::Type::NUM, "recent_solver_participants", "Bounded authenticated active-signal count used as the participant proxy. Global recent-solver enumeration is intentionally not performed by this wallet RPC."},
                        {RPCResult::Type::NUM, "active_signalers", "Whitelisted recent solvers that have an unexpired QQSIGNAL marker and can receive the next qualified PoS split."},
                        {RPCResult::Type::NUM, "recent_count", "Recent solver/claim accounting count from the consensus pool."},
                        {RPCResult::Type::STR_AMOUNT, "estimated_pos_payout_per_recent_solver", "Deprecated bounded estimate using active signalers; identical to estimated_pos_payout_per_active_signaler."},
                        {RPCResult::Type::STR_AMOUNT, "next_pos_payout_pool", "PoS-side jackpot plus the next block's PoS-side Gold Rush reward, if the next height is inside the reward window."},
                        {RPCResult::Type::NUM, "next_pos_payout_amount", "PoS-side jackpot plus the next block's PoS-side Gold Rush reward in satoshis."},
                        {RPCResult::Type::STR_AMOUNT, "estimated_pos_payout_per_active_signaler", "Estimated next qualified PoS payout per active signaler."},
                        {RPCResult::Type::NUM, "pow_target_bits", "Current next-block Shadow PoW leading-zero target bits."},
                        {RPCResult::Type::NUM, "pos_claim_count", "Number of accepted PoS-side Shadow payouts recorded in pool state."},
                        {RPCResult::Type::NUM, "pow_claim_count", "Number of accepted PoW-side Shadow claims recorded in pool state."},
                        {RPCResult::Type::NUM, "pos_count", "Alias for pos_claim_count."},
                        {RPCResult::Type::NUM, "pow_count", "Alias for pow_claim_count."},
                        {RPCResult::Type::NUM, "last_pos_height", "Most recent accepted PoS-side Shadow payout height, or 0 if none."},
                        {RPCResult::Type::NUM, "last_pow_height", "Most recent accepted PoW-side Shadow claim height, or 0 if none."},
                        {RPCResult::Type::NUM, "competing_claim_rule_activation_height", "First block using canonical order-independent competing-claim allocation."},
                        {RPCResult::Type::BOOL, "competing_claim_rule_active", "Whether the active tip uses canonical competing-claim allocation."},
                        {RPCResult::Type::BOOL, "competing_claim_rule_active_next_block", "Whether the next block uses canonical competing-claim allocation."},
                        {RPCResult::Type::NUM, "blocks_until_competing_claim_rule", "Blocks from the active tip through the activation block; zero once active."},
                        {RPCResult::Type::BOOL, "qqp4_activation_disabled", "Whether the separate QQP4 exact-input fork is disabled by consensus schedule; readiness signalling cannot enable it."},
                        {RPCResult::Type::NUM, "qqp4_activation_height", "Separately scheduled QQP4 activation height, or 0 when disabled."},
                        {RPCResult::Type::BOOL, "qqp4_active", "Whether the active tip uses QQP4 exact-input proof rules."},
                        {RPCResult::Type::BOOL, "qqp4_active_next_block", "Whether the next block requires QQP4 exact-input proof rules."},
                        {RPCResult::Type::BOOL, "wallet_recent_solve_qualified", "Whether this wallet has at least one known whitelisted script with a recent solver marker."},
                        {RPCResult::Type::OBJ, "wallet_qqsignal", "Authenticated QQSIGNAL state for only the selected -rpcwallet; global active-signal counts are never used to infer local membership.",
                        {
                            {RPCResult::Type::BOOL, "active", "Whether this wallet transaction is the authenticated active signal for its target."},
                            {RPCResult::Type::STR, "status", "One of none, mempool, confirmed, expired, superseded, or reorg_removed."},
                            {RPCResult::Type::STR_HEX, "txid", "Wallet signal transaction id, or an empty string when none is available."},
                            {RPCResult::Type::NUM, "signal_height", "Confirmation/activation height, or zero before confirmation."},
                            {RPCResult::Type::NUM, "activation_height", "Alias for signal_height."},
                            {RPCResult::Type::NUM, "expiry_height", "Last height at which this confirmed signal can remain active, or zero before confirmation."},
                            {RPCResult::Type::NUM, "confirmations", "Active-chain confirmations for the selected wallet signal."},
                            {RPCResult::Type::STR, "source", "manual, automatic, or unknown for records created before provenance was persisted."},
                            {RPCResult::Type::STR_HEX, "target_script", "Legacy signaling script from the wallet transaction."},
                            {RPCResult::Type::STR_HEX, "payout_script", "Quantum payout script linked by the wallet transaction."},
                            {RPCResult::Type::NUM, "solve_height", "Solver height referenced by the QQSIGNAL payload."},
                            {RPCResult::Type::STR_HEX, "solve_hash", "Solver block hash referenced by the QQSIGNAL payload."},
                            {RPCResult::Type::ARR, "history", "Wallet-authored QQSIGNAL records with the same lifecycle fields; superseded, expired, and reorg-removed records remain auditable.",
                            {
                                {RPCResult::Type::OBJ, "", "One wallet-authored signal record.",
                                {
                                    {RPCResult::Type::BOOL, "active", "Whether this exact record is the authenticated active signal."},
                                    {RPCResult::Type::STR, "status", "Lifecycle state for this exact record."},
                                    {RPCResult::Type::STR_HEX, "txid", "Signal transaction id."},
                                    {RPCResult::Type::NUM, "signal_height", "Confirmation/activation height, or zero."},
                                    {RPCResult::Type::NUM, "activation_height", "Alias for signal_height."},
                                    {RPCResult::Type::NUM, "expiry_height", "Last active height, or zero."},
                                    {RPCResult::Type::NUM, "confirmations", "Active-chain confirmations."},
                                    {RPCResult::Type::STR, "source", "manual, automatic, or unknown."},
                                    {RPCResult::Type::STR_HEX, "target_script", "Legacy target script."},
                                    {RPCResult::Type::STR_HEX, "payout_script", "Quantum payout script."},
                                    {RPCResult::Type::NUM, "solve_height", "Referenced solver height."},
                                    {RPCResult::Type::STR_HEX, "solve_hash", "Referenced solver hash."},
                                }},
                            }},
                        }},
                        {RPCResult::Type::ARR, "wallet_scripts", "Bounded wallet-known scripts relevant to Gold Rush signaling; transaction construction performs the final spendability check.",
                        {
                            {RPCResult::Type::OBJ, "", "",
                            {
                                {RPCResult::Type::STR_HEX, "scriptPubKey", "Wallet output script."},
                                {RPCResult::Type::STR, "address", "Address if the script has a standard destination."},
                                {RPCResult::Type::BOOL, "whitelisted", "Whether this script is in the deterministic snapshot whitelist."},
                                {RPCResult::Type::BOOL, "recent_solver", "Whether this script has solved a block within the current 14-day activity window."},
                                {RPCResult::Type::NUM, "last_solve_height", "Most recent qualifying solve height, or 0 if none."},
                                {RPCResult::Type::NUM_TIME, "last_solve_time", "Most recent qualifying solve time, or 0 if none."},
                                {RPCResult::Type::NUM, "blocks_until_expiry", "Blocks remaining before the recent-solver marker expires by height."},
                                {RPCResult::Type::NUM, "seconds_until_expiry", "Seconds remaining before the recent-solver marker expires by time."},
                            }},
                        }},
                    }
                },
                RPCExamples{
                    HelpExampleCli("getgoldrushinfo", "")
            + HelpExampleRpc("getgoldrushinfo", "")
                },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;
    ScopedDisallowShadowSolverActivityFullScan no_full_solver_scan;

    pwallet->BlockUntilSyncedToCurrentChain();

    std::set<CScript> wallet_scripts;
    std::vector<WalletShadowSolveReference> wallet_solves;
    {
        LOCK2(::cs_main, pwallet->cs_wallet);
        const std::vector<CScript> known_scripts =
            pwallet->GetOwnedLegacyShadowScripts(MAX_WALLET_SHADOW_SOLVE_REFERENCES);
        wallet_scripts.insert(known_scripts.begin(), known_scripts.end());
        const CBlockIndex* tip = pwallet->chain().chainman().ActiveChain().Tip();
        if (tip) wallet_solves = GetWalletShadowSolveReferences(*pwallet, tip->nHeight);
        for (const WalletShadowSolveReference& solve : wallet_solves) wallet_scripts.insert(solve.target);
    }

    UniValue wallet_entries(UniValue::VARR);
    ShadowGoldRushInfo shadow_info;
    std::map<CScript, ShadowSolverActivity> recent_solvers;
    int tip_height{-1};
    int64_t tip_time{0};
    int64_t mtp{0};
    bool active{false};
    bool wallet_recent_solve_qualified{false};
    uint64_t active_signalers{0};
    int competing_claim_rule_activation_height{std::numeric_limits<int>::max()};
    bool competing_claim_rule_active{false};
    bool competing_claim_rule_active_next_block{false};
    bool qqp4_activation_disabled{true};
    int qqp4_activation_height{0};
    bool qqp4_active{false};
    bool qqp4_active_next_block{false};
    UniValue wallet_qqsignal(UniValue::VOBJ);
    {
        ChainstateManager& chainman = pwallet->chain().chainman();
        LOCK(cs_main);
        Chainstate& active_chainstate = chainman.ActiveChainstate();
        const CBlockIndex* tip = active_chainstate.m_chain.Tip();
        if (!tip) {
            throw JSONRPCError(RPC_CLIENT_NOT_CONNECTED, "No active chain tip");
        }

        const Consensus::Params& consensus = Params().GetConsensus();
        tip_height = tip->nHeight;
        tip_time = tip->GetBlockTime();
        mtp = tip->GetMedianTimePast();
        active = IsShadowGoldRushRewardActive(consensus, mtp, tip->nHeight + 1);
        competing_claim_rule_activation_height =
            consensus.nShadowCompetingClaimsActivationHeight;
        competing_claim_rule_active =
            consensus.IsShadowCompetingClaimsActive(tip->nHeight);
        competing_claim_rule_active_next_block =
            consensus.IsShadowCompetingClaimsActive(tip->nHeight + 1);
        qqp4_activation_disabled =
            consensus.nShadowQQP4ActivationHeight ==
            std::numeric_limits<int>::max();
        qqp4_activation_height = qqp4_activation_disabled
            ? 0 : consensus.nShadowQQP4ActivationHeight;
        qqp4_active = consensus.IsShadowQQP4Active(tip->nHeight);
        qqp4_active_next_block =
            consensus.IsShadowQQP4Active(tip->nHeight + 1);
        shadow_info = GetShadowGoldRushInfo(active_chainstate.CoinsTip(), tip);
        const std::map<CScript, ShadowActiveSignalInfo> active_signal_details =
            GetActiveShadowSignalDetails(active_chainstate.CoinsTip(), tip);
        active_signalers = active_signal_details.size();
        {
            LOCK(pwallet->cs_wallet);
            wallet_qqsignal = WalletQQSignalStatusToJSON(
                GetWalletQQSignalStatusLocked(
                    *pwallet, active_signal_details, tip_height));
        }

        for (const WalletShadowSolveReference& solve : wallet_solves) {
            if (!wallet_scripts.count(solve.target) || !IsWhitelisted(active_chainstate.CoinsTip(), solve.target)) continue;
            const CBlockIndex* solved = active_chainstate.m_chain[solve.solve_height];
            if (!solved || solved->GetBlockHash() != solve.solve_hash ||
                !HasRecentShadowSolverActivity(active_chainstate.CoinsTip(), tip, solve.target, solve.solve_height, solve.solve_hash)) {
                continue;
            }
            recent_solvers.emplace(solve.target, ShadowSolverActivity{solve.solve_height, solved->GetBlockTime()});
        }

        for (const CScript& script : wallet_scripts) {
            const bool whitelisted = IsWhitelisted(active_chainstate.CoinsTip(), script);
            const auto activity_it = recent_solvers.find(script);
            const bool recent_solver = activity_it != recent_solvers.end();
            if (whitelisted && recent_solver) wallet_recent_solve_qualified = true;

            CTxDestination dest;
            const bool has_dest = ExtractDestination(script, dest);
            const int last_solve_height = recent_solver ? static_cast<int>(activity_it->second.height) : 0;
            const int64_t last_solve_time = recent_solver ? activity_it->second.time : 0;
            const int blocks_until_expiry = recent_solver ? std::max(0, SHADOW_SOLVER_ACTIVITY_WINDOW - (tip_height - last_solve_height)) : 0;
            const int64_t seconds_until_expiry = recent_solver ? std::max<int64_t>(0, SHADOW_SOLVER_ACTIVITY_SECONDS - (tip_time - last_solve_time)) : 0;

            UniValue entry(UniValue::VOBJ);
            entry.pushKV("scriptPubKey", HexStr(script));
            entry.pushKV("address", has_dest ? EncodeDestination(dest) : "");
            entry.pushKV("whitelisted", whitelisted);
            entry.pushKV("recent_solver", recent_solver);
            entry.pushKV("last_solve_height", last_solve_height);
            entry.pushKV("last_solve_time", last_solve_time);
            entry.pushKV("blocks_until_expiry", blocks_until_expiry);
            entry.pushKV("seconds_until_expiry", seconds_until_expiry);
            wallet_entries.push_back(std::move(entry));
        }
    }

    const int next_height = tip_height + 1;
    const bool next_reward_height_active = active &&
                                           next_height >= SHADOW_REWARD_START_HEIGHT &&
                                           next_height <= SHADOW_REWARD_END_HEIGHT;
    const CAmount next_reward = next_reward_height_active ? ShadowBaseReward(next_height) : 0;
    const CAmount next_pow_reward = next_reward / 2;
    const CAmount next_pos_reward = next_reward - next_pow_reward;
    const CAmount next_pow_payout = next_reward_height_active ? shadow_info.pow_amount + next_pow_reward : shadow_info.pow_amount;
    const CAmount next_pos_payout_pool = next_reward_height_active ? shadow_info.pos_amount + next_pos_reward : shadow_info.pos_amount;
    // The former participant estimate scanned every UTXO while cs_main was
    // held. Active signals are authenticated bounded state and are also the
    // actual recipients of the next PoS split, so retain the legacy fields as
    // documented aliases without reintroducing a GUI/RPC chainstate stall.
    const uint64_t participants = active_signalers;
    const CAmount estimated_pos_payout = participants > 0 ? next_pos_payout_pool / static_cast<CAmount>(participants) : 0;
    const CAmount estimated_active_pos_payout = active_signalers > 0 ? next_pos_payout_pool / static_cast<CAmount>(active_signalers) : 0;

    UniValue result(UniValue::VOBJ);
    result.pushKV("active", active);
    result.pushKV("height", tip_height);
    result.pushKV("mediantime", mtp);
    result.pushKV("pos_jackpot", ValueFromAmount(shadow_info.pos_amount));
    result.pushKV("pow_jackpot", ValueFromAmount(next_pow_payout));
    result.pushKV("pos_amount", shadow_info.pos_amount);
    result.pushKV("pow_amount", next_pow_payout);
    result.pushKV("pow_pool_jackpot", ValueFromAmount(shadow_info.pow_amount));
    result.pushKV("pow_pool_amount", shadow_info.pow_amount);
    result.pushKV("claimed_amount", shadow_info.claimed_amount);
    result.pushKV("recent_solver_participants", participants);
    result.pushKV("active_signalers", active_signalers);
    result.pushKV("recent_count", shadow_info.recent_count);
    result.pushKV("estimated_pos_payout_per_recent_solver", ValueFromAmount(estimated_pos_payout));
    result.pushKV("next_pos_payout_pool", ValueFromAmount(next_pos_payout_pool));
    result.pushKV("next_pos_payout_amount", next_pos_payout_pool);
    result.pushKV("estimated_pos_payout_per_active_signaler", ValueFromAmount(estimated_active_pos_payout));
    result.pushKV("pow_target_bits", shadow_info.pow_target_bits);
    result.pushKV("pos_claim_count", shadow_info.pos_count);
    result.pushKV("pow_claim_count", shadow_info.pow_count);
    result.pushKV("pos_count", shadow_info.pos_count);
    result.pushKV("pow_count", shadow_info.pow_count);
    result.pushKV("last_pos_height", shadow_info.last_pos_height);
    result.pushKV("last_pow_height", shadow_info.last_pow_height);
    result.pushKV("competing_claim_rule_activation_height",
                  competing_claim_rule_activation_height);
    result.pushKV("competing_claim_rule_active", competing_claim_rule_active);
    result.pushKV("competing_claim_rule_active_next_block",
                  competing_claim_rule_active_next_block);
    result.pushKV("blocks_until_competing_claim_rule",
                  std::max(0, competing_claim_rule_activation_height - tip_height));
    result.pushKV("qqp4_activation_disabled", qqp4_activation_disabled);
    result.pushKV("qqp4_activation_height", qqp4_activation_height);
    result.pushKV("qqp4_active", qqp4_active);
    result.pushKV("qqp4_active_next_block", qqp4_active_next_block);
    result.pushKV("wallet_recent_solve_qualified", wallet_recent_solve_qualified);
    result.pushKV("wallet_qqsignal", std::move(wallet_qqsignal));
    result.pushKV("wallet_scripts", std::move(wallet_entries));
    return result;
},
    };
}

static RPCHelpMan checkkernel()
{
    return RPCHelpMan{"checkkernel",
                "\nCheck if one of given inputs is a kernel input at the moment.\n",
                {
                    {"inputs", RPCArg::Type::ARR, RPCArg::Optional::NO, "The inputs",
                        {
                            {"", RPCArg::Type::OBJ, RPCArg::Optional::OMITTED, "",
                                {
                                    {"txid", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "The transaction id"},
                                    {"vout", RPCArg::Type::NUM, RPCArg::Optional::NO, "The output number"},
                                    {"sequence", RPCArg::Type::NUM, RPCArg::DefaultHint{"depends on the value of the 'locktime' argument"}, "The sequence number"},
                                },
                            },
                        },
                    },
                    {"createblocktemplate", RPCArg::Type::BOOL, RPCArg::Default{false}, "Create block template?"},
                },
                RPCResult{
                    RPCResult::Type::OBJ, "", "",
                    {
                        {RPCResult::Type::BOOL, "found", "?"},
                        {RPCResult::Type::OBJ, "kernel", /*optional=*/true, "",
                            {
                                {RPCResult::Type::STR_HEX, "txid", "The transaction hash in hex"},
                                {RPCResult::Type::NUM, "vout", "?"},
                                {RPCResult::Type::NUM, "time", "?"},
                            }},
                        {RPCResult::Type::STR_HEX, "blocktemplate", /*optional=*/true, "?"},
                        {RPCResult::Type::NUM, "blocktemplatefees", /*optional=*/true, "?"},
                        {RPCResult::Type::STR_HEX, "blocktemplatesignkey", /*optional=*/true, "?"},
                    },
                },
                RPCExamples{
                HelpExampleCli("checkkernel", "\"[{\\\"txid\\\":\\\"myid\\\",\\\"vout\\\":0}]\" \"false\"")
                + HelpExampleCli("checkkernel", "\"[{\\\"txid\\\":\\\"myid\\\",\\\"vout\\\":0}]\" \"true\"")
                },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    const CTxMemPool& mempool = pwallet->chain().mempool();
    ChainstateManager& chainman = pwallet->chain().chainman();
    LOCK(cs_main);
    const CChain& active_chain = chainman.ActiveChain();
    Chainstate& active_chainstate = chainman.ActiveChainstate();

    UniValue inputs = request.params[0].get_array();
    bool fCreateBlockTemplate = request.params.size() > 1 ? request.params[1].get_bool() : false;

    if (!Params().IsTestChain()) {
        if (pwallet->chain().getNodeCount(ConnectionDirection::Both) == 0) {
            throw JSONRPCError(RPC_CLIENT_NOT_CONNECTED, PACKAGE_NAME " is not connected!");
        }

        if (chainman.IsInitialBlockDownload()) {
            throw JSONRPCError(RPC_CLIENT_IN_INITIAL_DOWNLOAD, PACKAGE_NAME " is in initial sync and waiting for blocks...");
        }
    }

    COutPoint kernel;
    CBlockIndex* pindexPrev = active_chain.Tip();
    const std::optional<int64_t> pos_time = GetNextBlockPoSTime(
        active_chainstate, pindexPrev, Params().GetConsensus(),
        GetAdjustedTimeSeconds());

    UniValue result(UniValue::VOBJ);
    // Do not floor an unavailable adjusted time to the prior stake mask. A
    // returned kernel must always correspond to a representable, MTP-valid,
    // future-drift-valid PoS header that the assembler can build.
    if (!pos_time) {
        result.pushKV("found", false);
        return result;
    }

    unsigned int nBits = GetNextTargetRequired(pindexPrev, Params().GetConsensus(), true);
    const int64_t nTime = *pos_time;

    for (unsigned int idx = 0; idx < inputs.size(); idx++) {
        const UniValue& o = inputs[idx].get_obj();

        const UniValue& txid_v = o.find_value("txid");
        if (!txid_v.isStr())
            throw JSONRPCError(RPC_INVALID_PARAMETER, "Invalid parameter, missing txid key");
        string txid = txid_v.get_str();
        if (!IsHex(txid))
            throw JSONRPCError(RPC_INVALID_PARAMETER, "Invalid parameter, expected hex txid");

        const UniValue& vout_v = o.find_value("vout");
        if (!vout_v.isNum())
            throw JSONRPCError(RPC_INVALID_PARAMETER, "Invalid parameter, missing vout key");
        int nOutput = vout_v.getInt<int>();
        if (nOutput < 0)
            throw JSONRPCError(RPC_INVALID_PARAMETER, "Invalid parameter, vout must be positive");

        COutPoint cInput(uint256S(txid), nOutput);
        if (CheckKernel(pindexPrev, nBits, nTime, cInput, active_chainstate.CoinsTip()))
        {
            kernel = cInput;
            break;
        }
    }

    result.pushKV("found", !kernel.IsNull());

    if (kernel.IsNull())
        return result;

    UniValue oKernel(UniValue::VOBJ);
    oKernel.pushKV("txid", kernel.hash.GetHex());
    oKernel.pushKV("vout", (int64_t)kernel.n);
    oKernel.pushKV("time", nTime);
    result.pushKV("kernel", oKernel);

    if (!fCreateBlockTemplate)
        return result;

    if (!pwallet->IsLocked())
        pwallet->TopUpKeyPool();

    if (!pwallet->CanGetAddresses(true)) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Error: This wallet has no available keys");
    }

    // Reserve the payout/change destination before assembling the template.
    // In addition to supplying a real output script for the coinstake, this
    // lets the assembler prove the exact kernel reported above rather than
    // selecting an unrelated wallet kernel at the same timestamp.
    OutputType output_type = pwallet->m_default_change_type ? *pwallet->m_default_change_type : pwallet->m_default_address_type;
    auto op_dest = pwallet->GetNewChangeDestination(output_type);
    if (!op_dest) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Error: Keypool ran out, please call keypoolrefill first");
    }
    std::vector<valtype> vSolutionsTmp;
    CScript scriptPubKeyTmp = GetScriptForDestination(*op_dest);
    Solver(scriptPubKeyTmp, vSolutionsTmp);
    std::unique_ptr<SigningProvider> provider = pwallet->GetSolvingProvider(scriptPubKeyTmp);
    if (!provider) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Error: failed to get signing provider");
    }
    if (vSolutionsTmp.empty()) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Error: failed to resolve template signing key");
    }
    CKeyID ckey = CKeyID(uint160(vSolutionsTmp[0]));
    CPubKey pkey;
    if (!provider->GetPubKey(ckey, pkey)) {
        throw JSONRPCError(RPC_WALLET_ERROR, "Error: failed to get key");
    }

    bool fPoSCancel = false;
    int64_t nFees;
    std::unique_ptr<node::CBlockTemplate> pblocktemplate(
        BlockAssembler{active_chainstate, &mempool}.CreateNewBlock(
            CScript(), pwallet.get(), &fPoSCancel, &nFees, *op_dest, kernel));
    if (!pblocktemplate || fPoSCancel)
        throw JSONRPCError(RPC_INTERNAL_ERROR,
                           "Couldn't create a valid proof-of-stake block template");

    CBlock *pblock = &pblocktemplate->block;
    if (!pblock->IsProofOfStake() || pblock->vtx.size() < 2 ||
        pblock->vtx[1]->vin.empty() ||
        pblock->vtx[1]->vin[0].prevout != kernel ||
        pblock->nTime != nTime) {
        throw JSONRPCError(
            RPC_INTERNAL_ERROR,
            "Couldn't create a valid proof-of-stake block template for the requested kernel");
    }

    CDataStream ss(SER_DISK);
    ss << RPCTxSerParams(*pblock);

    result.pushKV("blocktemplate", HexStr(ss));
    result.pushKV("blocktemplatefees", nFees);
    result.pushKV("blocktemplatesignkey", HexStr(pkey));

    return result;
},
    };
}

static UniValue ShadowPowClaimRecoveryPolicyToJSON(
    const ShadowPowClaimRecoveryPolicy& policy)
{
    UniValue result(UniValue::VOBJ);
    const std::string mode = !policy.choice_recorded
        ? "unset"
        : policy.automatic_enabled ? "automatic" : "pause_and_ask";
    result.pushKV("version", policy.version);
    result.pushKV("mode", mode);
    result.pushKV("choice_recorded", policy.choice_recorded == 1);
    result.pushKV("automatic_enabled", policy.automatic_enabled == 1);
    result.pushKV("automatic_authorized", policy.HasAutomaticAuthority());
    result.pushKV("max_fee_per_resolution", ValueFromAmount(policy.max_fee_per_resolution));
    result.pushKV("aggregate_batch_fee_cap", ValueFromAmount(policy.aggregate_batch_fee_cap));
    result.pushKV("rolling_fee_budget", ValueFromAmount(policy.rolling_fee_budget));
    result.pushKV("rolling_fee_window_seconds", policy.rolling_fee_window_seconds);
    result.pushKV("max_actions_per_window", policy.max_actions_per_window);
    result.pushKV("minimum_stale_blocks", policy.minimum_stale_blocks);
    return result;
}

static UniValue ShadowPowClaimRecoveryPolicyMutationToJSON(
    const ShadowPowClaimRecoveryPolicyMutationResult& mutation)
{
    UniValue result(UniValue::VOBJ);
    const std::string reason_code =
        ShadowPowClaimRecoveryPolicyMutationStatusName(mutation.status);
    result.pushKV("status", reason_code);
    result.pushKV("reason_code", reason_code);
    result.pushKV("success", mutation.success);
    result.pushKV("durable_state_changed", mutation.durable_state_changed);
    result.pushKV("durable_state_ambiguous", mutation.durable_state_ambiguous);
    result.pushKV("authoritative_state_available",
                  mutation.authoritative_state_available);
    if (mutation.authoritative_state_available) {
        result.pushKV("policy", ShadowPowClaimRecoveryPolicyToJSON(
                                    mutation.authoritative_policy));
    }
    result.pushKV("detail", mutation.detail);
    if (mutation.durable_state_ambiguous) {
        result.pushKV(
            "next_step",
            "Stop policy and recovery changes and reload the wallet. Neither the old nor requested policy is authoritative until reload completes.");
    } else if (!mutation.success) {
        result.pushKV(
            "next_step",
            "Correct the reported policy or database error, then retry. The returned policy is authoritative only when authoritative_state_available=true.");
    } else {
        result.pushKV(
            "next_step",
            mutation.authoritative_policy.HasAutomaticAuthority()
                ? "Automatic recovery is authorized within the displayed wallet-scoped limits; mining remains a separate operator choice."
                : "No automatic recovery spend is authorized. Use manual preview and explicit execution when a component becomes eligible.");
    }
    return result;
}

static UniValue ShadowPowClaimRecoveryAdoptionToJSON(
    const ShadowPowClaimRecoveryAdoptionResult& adoption)
{
    UniValue result(UniValue::VOBJ);
    const std::string reason_code =
        ShadowPowClaimRecoveryAdoptionStatusName(adoption.status);
    result.pushKV("status", reason_code);
    result.pushKV("reason_code", reason_code);
    result.pushKV("success", adoption.IsSuccess());
    result.pushKV("adopted", adoption.adopted);
    result.pushKV("durable_state_changed", adoption.durable_state_changed);
    result.pushKV("durable_state_ambiguous", adoption.durable_state_ambiguous);
    if (!adoption.active_tip.IsNull()) {
        result.pushKV("active_tip", adoption.active_tip.GetHex());
    }
    if (!adoption.generation_fingerprint.IsNull()) {
        result.pushKV("generation_fingerprint",
                      adoption.generation_fingerprint.GetHex());
    }
    if (!adoption.reviewed_component_fingerprint.IsNull()) {
        result.pushKV("reviewed_component_fingerprint",
                      adoption.reviewed_component_fingerprint.GetHex());
    }
    if (!adoption.post_adoption_component_fingerprint.IsNull()) {
        // Keep component_fingerprint as a compatibility alias for the exact
        // post-adoption snapshot, while naming its timing explicitly.
        result.pushKV("component_fingerprint",
                      adoption.post_adoption_component_fingerprint.GetHex());
        result.pushKV("post_adoption_component_fingerprint",
                      adoption.post_adoption_component_fingerprint.GetHex());
    }
    result.pushKV("claim_txids", ShadowPowTxidsToJSON(adoption.claim_txids));
    result.pushKV("adopted_claims",
                  static_cast<uint64_t>(adoption.adopted
                      ? adoption.claim_txids.size() : 0));
    result.pushKV("automatic_eligible_after_adoption",
                  adoption.automatic_eligible_after_adoption);
    result.pushKV("component_has_revalidating_unbound_proof",
                  adoption.component_has_revalidating_unbound_proof);
    if (!adoption.component_refusal_code.empty()) {
        result.pushKV("component_refusal_code",
                      adoption.component_refusal_code);
    }
    result.pushKV("detail", adoption.detail);
    if (adoption.durable_state_ambiguous) {
        result.pushKV(
            "next_step",
            "Stop recovery activity and reload the wallet. Adoption may or may not have committed; review the refreshed provenance and component fingerprint before retrying.");
    } else if (adoption.status ==
               ShadowPowClaimRecoveryAdoptionStatus::ALREADY_EXPLICIT) {
        result.pushKV(
            "next_step",
            adoption.component_has_revalidating_unbound_proof
                ? "No mutation was needed. The component contains an unbound proof that may become valid on a descendant; re-preview and explicitly acknowledge that conflict risk before any manual recovery, or configure bounded automatic standing consent."
                : "No mutation was needed. Re-preview the component before any fee-paying recovery action.");
    } else if (adoption.adopted) {
        result.pushKV(
            "next_step",
            adoption.component_has_revalidating_unbound_proof
                ? "The complete reviewed component now has durable explicit provenance, but it contains an unbound proof that may become valid on a descendant. Re-preview and explicitly acknowledge that conflict risk before any manual recovery, or configure bounded automatic standing consent. Adoption itself never enables mining or spends funds."
                : "The complete reviewed component now has durable explicit provenance. Re-preview before any fee-paying recovery action; adoption itself never enables mining or spends funds.");
    } else {
        result.pushKV(
            "next_step",
            "No adoption was committed. Correct the typed refusal, refresh the exact tip and component fingerprint, and review the complete graph before retrying.");
    }
    return result;
}

static std::vector<RPCResult> ShadowPowClaimRecoveryPolicyResults()
{
    return {
        {RPCResult::Type::NUM, "version", "Persisted policy schema version."},
        {RPCResult::Type::STR, "mode", "unset, pause_and_ask, or automatic."},
        {RPCResult::Type::BOOL, "choice_recorded", "Whether this wallet records an explicit operator choice."},
        {RPCResult::Type::BOOL, "automatic_enabled", "Whether this wallet's recorded choice requests automatic recovery."},
        {RPCResult::Type::BOOL, "automatic_authorized", "True only when both the explicit choice and automatic-recovery flag are valid."},
        {RPCResult::Type::STR_AMOUNT, "max_fee_per_resolution", "Maximum fee authorized for one automatic resolution."},
        {RPCResult::Type::STR_AMOUNT, "aggregate_batch_fee_cap", "Maximum aggregate fee authorized for one recovery pass."},
        {RPCResult::Type::STR_AMOUNT, "rolling_fee_budget", "Maximum aggregate recovery fee in the rolling window."},
        {RPCResult::Type::NUM_TIME, "rolling_fee_window_seconds", "Length of the rolling fee and action window."},
        {RPCResult::Type::NUM, "max_actions_per_window", "Maximum automatic resolutions in the rolling window."},
        {RPCResult::Type::NUM, "minimum_stale_blocks", "Minimum current-branch staleness before a conflict-resolvable claim component may be recovered automatically, including a disclosed unbound-proof descendant-revalidation risk."},
    };
}

static RPCHelpMan getpowclaimrecoveryinfo()
{
    return RPCHelpMan{
        "getpowclaimrecoveryinfo",
        "\nReturn this wallet's persisted Gold Rush PoW claim-recovery consent and current component gate.\n"
        "This RPC never creates, signs, or broadcasts a transaction. Automatic recovery is disabled unless mode is explicitly set to automatic with bounded spending limits; exact-plan manual recovery remains separately authorized per request. Set verbose=true to inspect the complete typed component graph and provenance.\n",
        {
            {"verbose", RPCArg::Type::BOOL, RPCArg::Default{false}, "Include complete component, node, provenance, and refusal-classification details."},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::OBJ, "policy", /*optional=*/true, "Authoritative wallet-scoped policy. Omitted when the durable database outcome is ambiguous.", ShadowPowClaimRecoveryPolicyResults()},
            {RPCResult::Type::BOOL, "policy_authoritative", "Whether the displayed policy is proven to match a durable wallet record."},
            {RPCResult::Type::STR, "policy_state_status", "Stable typed policy-state status."},
            {RPCResult::Type::STR, "policy_state_detail", "Human-readable policy authority detail."},
            {RPCResult::Type::BOOL, "chain_ready", "Whether the active chain can currently accept recovery broadcasts."},
            {RPCResult::Type::BOOL, "database_outcome_ambiguous", "Whether a prior recovery database commit or rollback had an indeterminate outcome. Reload and inspect before any further recovery action."},
            {RPCResult::Type::STR_HEX, "active_tip", "Active-chain tip to which the inventory is pinned, or all-zero when unavailable."},
            {RPCResult::Type::NUM, "active_height", "Active-chain height used by the classifier, or -1 when unavailable."},
            {RPCResult::Type::STR_HEX, "wallet_processed_tip", "Last active-chain tip processed by this wallet."},
            {RPCResult::Type::NUM, "wallet_processed_height", "Last active-chain height processed by this wallet."},
            {RPCResult::Type::NUM, "wallet_generation", "Wallet database generation used by exact-plan stale-state protection."},
            {RPCResult::Type::BOOL, "wallet_tip_matches", "Whether the wallet-processed tip matches the classified active tip."},
            {RPCResult::Type::NUM, "raw_quarantined_claims", "Wallet-known quarantined claim objects retained for audit and reorg safety."},
            {RPCResult::Type::NUM, "blocking_quarantined_claims", "Legacy actionable-plus-indeterminate compatibility count. Candidate claim creation is controlled by the complete typed mining gate instead."},
            {RPCResult::Type::NUM, "actionable_quarantined_claims", "Claim objects whose confirmed anchor is currently unspent."},
            {RPCResult::Type::NUM, "resolved_on_active_chain_claims", "Historical objects whose confirmed anchor is spent on the active chain."},
            {RPCResult::Type::NUM, "indeterminate_quarantined_claims", "Objects that fail closed because classification is incomplete."},
            {RPCResult::Type::NUM, "components", "Current wallet-known claim components."},
            {RPCResult::Type::NUM, "raw_claim_objects", "All wallet-known unconfirmed claim objects in the typed inventory."},
            {RPCResult::Type::NUM, "live_claim_objects", "Claim objects currently in the local mempool."},
            {RPCResult::Type::NUM, "quarantined_claim_objects", "Claim objects marked quarantined for audit and reorg safety."},
            {RPCResult::Type::NUM, "blocking_components", "Legacy recovery classification count retained for audit compatibility. Candidate claim creation is controlled by the complete typed mining gate."},
            {RPCResult::Type::NUM, "retired_claim_objects", "Deprecated historical count retained for RPC compatibility. Current wallet repair reopens these records and keeps their inputs reserved, so authoritative post-repair state is zero."},
            {RPCResult::Type::NUM, "retired_components", "Deprecated historical component count retained for RPC compatibility. Authoritative post-repair state is zero."},
            {RPCResult::Type::NUM, "resolved_components", "Typed components resolved on the active chain."},
            {RPCResult::Type::NUM, "pending_manual_resolutions", "Persisted unconfirmed manual resolutions."},
            {RPCResult::Type::NUM, "pending_automatic_resolutions", "Persisted unconfirmed automatic resolutions."},
            {RPCResult::Type::NUM, "confirmed_manual_resolutions", "Confirmed manual resolutions reconstructed from wallet records."},
            {RPCResult::Type::NUM, "confirmed_automatic_resolutions", "Confirmed automatic resolutions reconstructed from wallet records."},
            {RPCResult::Type::STR_AMOUNT, "confirmed_resolution_fees", "Fees paid by confirmed managed resolutions."},
            {RPCResult::Type::NUM, "automatic_actions_in_window", "Automatic actions counted in the current rolling policy window."},
            {RPCResult::Type::STR_AMOUNT, "automatic_fee_exposure_in_window", "Confirmed and pending automatic fee exposure in the rolling policy window."},
            {RPCResult::Type::NUM, "reconciled_descendant_claims", "Descendant claim objects reconciled by confirmed resolutions."},
            {RPCResult::Type::NUM, "claims_recycled", "Later claim transactions that spent a confirmed resolution output."},
            {RPCResult::Type::ARR, "component_details", /*optional=*/true, "Complete typed component graph when verbose=true.", {{RPCResult::Type::ELISION, "", ""}}},
            {RPCResult::Type::ARR, "unanchored_claim_txids", /*optional=*/true, "Claim objects that could not be bound to an authenticated confirmed anchor when verbose=true.", {{RPCResult::Type::STR_HEX, "", "Claim transaction id."}}},
        }},
        RPCExamples{
            HelpExampleCli("getpowclaimrecoveryinfo", "") +
            HelpExampleCli("getpowclaimrecoveryinfo", "true") +
            HelpExampleRpc("getpowclaimrecoveryinfo", "true")
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    ShadowPowClaimRecoveryPolicy policy =
        DefaultShadowPowClaimRecoveryPolicy();
    ShadowPowClaimInventory compatibility_inventory;
    ShadowPowClaimRecoveryInventory inventory;
    ShadowPowClaimRecoveryUsage usage;
    ShadowPowClaimRecoveryPolicyMutationResult policy_state;
    bool database_ambiguous{false};
    {
        // One recursive lock snapshot keeps legacy compatibility fields,
        // typed graph details, and durable usage counters on the same tip and
        // wallet generation.
        LOCK2(::cs_main, pwallet->cs_wallet);
        policy_state = pwallet->GetShadowPowClaimRecoveryPolicyState();
        database_ambiguous = policy_state.durable_state_ambiguous;
        if (policy_state.authoritative_state_available) {
            policy = policy_state.authoritative_policy;
        }
        compatibility_inventory = pwallet->GetShadowPowClaimInventoryLocked();
        inventory = pwallet->GetShadowPowClaimRecoveryInventoryLocked();
        usage = pwallet->GetShadowPowClaimRecoveryUsage(
            policy.rolling_fee_window_seconds);
    }
    const bool verbose = !request.params[0].isNull() && request.params[0].get_bool();

    UniValue result(UniValue::VOBJ);
    if (policy_state.authoritative_state_available) {
        result.pushKV("policy", ShadowPowClaimRecoveryPolicyToJSON(policy));
    }
    result.pushKV("policy_authoritative",
                  policy_state.authoritative_state_available);
    result.pushKV("policy_state_status",
                  ShadowPowClaimRecoveryPolicyMutationStatusName(
                      policy_state.status));
    result.pushKV("policy_state_detail", policy_state.detail);
    result.pushKV("chain_ready", pwallet->chain().isReadyToBroadcast());
    result.pushKV("database_outcome_ambiguous", database_ambiguous);
    result.pushKV("active_tip", compatibility_inventory.active_tip.GetHex());
    result.pushKV("active_height", inventory.active_height);
    result.pushKV("wallet_processed_tip", inventory.wallet_processed_tip.GetHex());
    result.pushKV("wallet_processed_height", inventory.wallet_processed_height);
    result.pushKV("wallet_generation", inventory.wallet_generation);
    result.pushKV("wallet_tip_matches", compatibility_inventory.wallet_tip_matches);
    result.pushKV("raw_quarantined_claims", static_cast<uint64_t>(compatibility_inventory.raw_quarantined_claims));
    result.pushKV("blocking_quarantined_claims", static_cast<uint64_t>(compatibility_inventory.BlockingClaims()));
    result.pushKV("actionable_quarantined_claims", static_cast<uint64_t>(compatibility_inventory.actionable_claims));
    result.pushKV("resolved_on_active_chain_claims", static_cast<uint64_t>(compatibility_inventory.resolved_on_active_chain_claims));
    result.pushKV("indeterminate_quarantined_claims", static_cast<uint64_t>(compatibility_inventory.indeterminate_claims));
    result.pushKV("components", static_cast<uint64_t>(compatibility_inventory.components.size()));
    result.pushKV("raw_claim_objects", static_cast<uint64_t>(inventory.raw_claim_objects));
    result.pushKV("live_claim_objects", static_cast<uint64_t>(inventory.live_claim_objects));
    result.pushKV("quarantined_claim_objects", static_cast<uint64_t>(inventory.quarantined_claim_objects));
    result.pushKV("blocking_components", static_cast<uint64_t>(inventory.blocking_components));
    result.pushKV("retired_claim_objects", static_cast<uint64_t>(inventory.retired_claim_objects));
    result.pushKV("retired_components", static_cast<uint64_t>(inventory.retired_components));
    result.pushKV("resolved_components", static_cast<uint64_t>(inventory.resolved_components));
    result.pushKV("pending_manual_resolutions", static_cast<uint64_t>(usage.pending_manual));
    result.pushKV("pending_automatic_resolutions", static_cast<uint64_t>(usage.pending_automatic));
    result.pushKV("confirmed_manual_resolutions", static_cast<uint64_t>(usage.confirmed_manual));
    result.pushKV("confirmed_automatic_resolutions", static_cast<uint64_t>(usage.confirmed_automatic));
    result.pushKV("confirmed_resolution_fees", ValueFromAmount(usage.confirmed_resolution_fees));
    result.pushKV("automatic_actions_in_window", static_cast<uint64_t>(usage.automatic_actions_in_window));
    result.pushKV("automatic_fee_exposure_in_window", ValueFromAmount(usage.automatic_fee_exposure_in_window));
    result.pushKV("reconciled_descendant_claims", static_cast<uint64_t>(usage.reconciled_descendant_claims));
    result.pushKV("claims_recycled", static_cast<uint64_t>(usage.recycled_outputs));
    if (verbose) {
        UniValue components(UniValue::VARR);
        for (const auto& component : inventory.components) {
            components.push_back(ShadowPowRecoveryComponentToJSON(component));
        }
        result.pushKV("component_details", std::move(components));
        result.pushKV("unanchored_claim_txids", ShadowPowTxidsToJSON(inventory.unanchored_claim_txids));
    }
    return result;
},
    };
}

static RPCHelpMan setpowclaimrecovery()
{
    return RPCHelpMan{
        "setpowclaimrecovery",
        "\nPersist this wallet's Gold Rush PoW claim-recovery choice.\n"
        "The built-in miner's normal path for a strict exact wallet-authored QQP2/QQP3/QQP4 family is exact relay or same-anchor continuation; the family is not retired merely because an original policy window expires. Separately, automatic is explicit, default-off standing consent to create fee-paying on-chain conflicts that the component engine finds conflict-resolvable on one pinned active-chain tip, including a disclosed legacy QQP2 proof that is invalid now but may validate on a descendant. Generic retryable and indeterminate states remain refused. All six positive limits are required when enabling it. pause_and_ask keeps conflict recovery manual. unset removes standing consent. This call never starts mining and never creates, signs, or broadcasts a transaction.\n",
        {
            {"mode", RPCArg::Type::STR, RPCArg::Optional::NO, "automatic, pause_and_ask, or unset."},
            {"options", RPCArg::Type::OBJ, RPCArg::Default{UniValue::VOBJ}, "Wallet-scoped spending and staleness limits.", {
                {"max_fee_per_resolution", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Positive maximum fee for one resolution."},
                {"aggregate_batch_fee_cap", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Positive maximum aggregate fee for one recovery pass."},
                {"rolling_fee_budget", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Positive maximum aggregate fee in the rolling window."},
                {"rolling_fee_window_seconds", RPCArg::Type::NUM, RPCArg::Optional::OMITTED, "Rolling fee/action window in seconds."},
                {"max_actions_per_window", RPCArg::Type::NUM, RPCArg::Optional::OMITTED, "Maximum automatic resolutions in the rolling window."},
                {"minimum_stale_blocks", RPCArg::Type::NUM, RPCArg::Optional::OMITTED, "Minimum current-branch age in blocks before automation may act on a conflict-resolvable component."},
            }},
        },
        RPCResult{RPCResult::Type::OBJ, "", "Typed durable policy-mutation result.", {
            {RPCResult::Type::STR, "status", "Stable mutation status."},
            {RPCResult::Type::STR, "reason_code", "Stable machine-readable status alias."},
            {RPCResult::Type::BOOL, "success", "Whether the requested policy was durably committed."},
            {RPCResult::Type::BOOL, "durable_state_changed", "Whether this call definitely committed the requested policy."},
            {RPCResult::Type::BOOL, "durable_state_ambiguous", "Whether commit or rollback had an indeterminate outcome."},
            {RPCResult::Type::BOOL, "authoritative_state_available", "Whether the nested policy is proven authoritative after this call."},
            {RPCResult::Type::OBJ, "policy", /*optional=*/true, "Authoritative policy, omitted after an ambiguous database outcome.", ShadowPowClaimRecoveryPolicyResults()},
            {RPCResult::Type::STR, "detail", "Human-readable outcome detail."},
            {RPCResult::Type::STR, "next_step", "Required follow-up action."},
        }},
        RPCExamples{
            HelpExampleCli("setpowclaimrecovery", "\"pause_and_ask\"") +
            HelpExampleCli("setpowclaimrecovery", "\"automatic\" '{\"max_fee_per_resolution\":0.001,\"aggregate_batch_fee_cap\":0.01,\"rolling_fee_budget\":0.1,\"rolling_fee_window_seconds\":86400,\"max_actions_per_window\":25,\"minimum_stale_blocks\":6}'") +
            HelpExampleRpc("setpowclaimrecovery", "\"unset\"")
        },
        [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    const ShadowPowClaimRecoveryPolicyMutationResult policy_state =
        pwallet->GetShadowPowClaimRecoveryPolicyState();
    if (!policy_state.authoritative_state_available) {
        return ShadowPowClaimRecoveryPolicyMutationToJSON(policy_state);
    }
    ShadowPowClaimRecoveryPolicy policy =
        policy_state.authoritative_policy;
    const std::string mode = ToLower(request.params[0].get_str());
    const UniValue options = request.params[1].isNull()
        ? UniValue(UniValue::VOBJ)
        : request.params[1].get_obj();

    if (mode != "automatic" && mode != "pause_and_ask" && mode != "unset") {
        throw JSONRPCError(RPC_INVALID_PARAMETER,
                           "mode must be automatic, pause_and_ask, or unset");
    }

    static const std::array<const char*, 6> REQUIRED_AUTOMATIC_LIMITS{
        "max_fee_per_resolution",
        "aggregate_batch_fee_cap",
        "rolling_fee_budget",
        "rolling_fee_window_seconds",
        "max_actions_per_window",
        "minimum_stale_blocks",
    };
    if (mode == "automatic") {
        for (const char* key : REQUIRED_AUTOMATIC_LIMITS) {
            if (!options.exists(key)) {
                throw JSONRPCError(
                    RPC_INVALID_PARAMETER,
                    strprintf("automatic recovery requires explicit %s", key));
            }
        }
    }

    if (options.exists("max_fee_per_resolution")) {
        policy.max_fee_per_resolution = AmountFromValue(options["max_fee_per_resolution"]);
    }
    if (options.exists("aggregate_batch_fee_cap")) {
        policy.aggregate_batch_fee_cap = AmountFromValue(options["aggregate_batch_fee_cap"]);
    }
    if (options.exists("rolling_fee_budget")) {
        policy.rolling_fee_budget = AmountFromValue(options["rolling_fee_budget"]);
    }
    const auto read_uint32 = [&](const char* key, uint32_t& output) {
        if (!options.exists(key)) return;
        const int64_t value = options[key].getInt<int64_t>();
        if (value < 0 || value > std::numeric_limits<uint32_t>::max()) {
            throw JSONRPCError(RPC_INVALID_PARAMETER,
                               strprintf("%s is outside the uint32 range", key));
        }
        output = static_cast<uint32_t>(value);
    };
    read_uint32("rolling_fee_window_seconds", policy.rolling_fee_window_seconds);
    read_uint32("max_actions_per_window", policy.max_actions_per_window);
    read_uint32("minimum_stale_blocks", policy.minimum_stale_blocks);

    policy.version = ShadowPowClaimRecoveryPolicy::VERSION;
    policy.choice_recorded = mode == "unset" ? 0 : 1;
    policy.automatic_enabled = mode == "automatic" ? 1 : 0;

    return ShadowPowClaimRecoveryPolicyMutationToJSON(
        pwallet->SetShadowPowClaimRecoveryPolicyDetailed(policy));
},
    };
}

static RPCHelpMan setpowmining()
{
    return RPCHelpMan{"setpowmining",
        "\nStart, stop, or reconfigure the built-in (in-process) Gold Rush Proof-of-Work miner.\n"
        "No external miner is required. Mining only produces claims during the Gold Rush reward window,\n"
        "requires an unlocked wallet with private keys, and credits valid claims to a wallet-owned quantum address in the upgraded shadow ledger.\n"
        "A new-anchor claim reuses -qqpowpayoutaddress or a previously stored wallet payout and creates no key by default. If neither exists, new-anchor mining fails without changing the wallet unless allow_new_payout_key=true gives one-call consent, or startup already supplied -qqallowautokeycreation=1. A safe retained family needs no configured payout to wait, relay, or refresh: Core preserves that family's authenticated payout script and allocates no unrelated key. If explicit key-creation consent is supplied while servicing a retained family, Core binds the future new-anchor payout during this call so the backup warning is returned synchronously. Every newly created payout key is non-HD and requires an immediate wallet backup.\n"
        "Claim submission is not whitelist-gated, but it does require a spendable non-dust legacy UTXO to authenticate the QQSPROOF transaction and pay the minimal network fee.\n",
        {
            {"enabled", RPCArg::Type::BOOL, RPCArg::Optional::NO, "true to start mining, false to stop."},
            {"threads", RPCArg::Type::NUM, RPCArg::Default{1}, "Worker threads (CPU cores) to use, 1..256."},
            {"cpu_percent", RPCArg::Type::NUM, RPCArg::Default{1}, "Per-core CPU duty-cycle target, 1..100."},
            {"allow_new_payout_key", RPCArg::Type::BOOL, RPCArg::Default{false}, "Explicit consent to create one new non-HD ML-DSA payout key if no configured or previously stored payout exists. Back up the wallet immediately if the result reports created_payout_key=true."},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "enabled", "Whether in-process PoW mining is now enabled."},
            {RPCResult::Type::NUM, "threads", "Configured worker threads."},
            {RPCResult::Type::NUM, "cpu_percent", "Configured per-core CPU duty cycle."},
            {RPCResult::Type::STR, "payout_address", "The configured, restored, or newly created wallet-owned payout for future new-anchor claims. It may be empty or differ while a retained family preserves its own authenticated payout."},
            {RPCResult::Type::BOOL, "created_payout_key", "Whether this call created a new non-HD ML-DSA payout key."},
            {RPCResult::Type::STR, "warning", /*optional=*/true, "Backup reminder when a wallet-backed quantum payout key was created."},
        }},
        RPCExamples{
            HelpExampleCli("setpowmining", "true 2 50 false")
          + HelpExampleCli("setpowmining", "true 2 50 true")
          + HelpExampleRpc("setpowmining", "true, 2, 50, false")
        },
    [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    const bool enabled = request.params[0].get_bool();
    const int threads = request.params[1].isNull() ? 1 : request.params[1].getInt<int>();
    const int cpu_percent = request.params[2].isNull() ? 1 : request.params[2].getInt<int>();
    const bool allow_new_payout_key = !request.params[3].isNull() && request.params[3].get_bool();
    bilingual_str error;
    bool created_payout_key{false};
    const bool ok = pwallet->SetPowMining(
        enabled, threads, cpu_percent, error, &created_payout_key,
        allow_new_payout_key);
    if (!ok) {
        throw JSONRPCError(RPC_WALLET_ERROR, error.original);
    }

    UniValue result(UniValue::VOBJ);
    result.pushKV("enabled", pwallet->m_pow_mining_enabled.load());
    result.pushKV("threads", pwallet->m_pow_threads.load());
    result.pushKV("cpu_percent", pwallet->m_pow_cpu_percent.load());
    {
        LOCK(pwallet->cs_wallet);
        result.pushKV("payout_address", pwallet->m_pow_payout_quantum);
    }
    result.pushKV("created_payout_key", created_payout_key);
    if (created_payout_key) {
        result.pushKV("warning", "A new wallet-backed ML-DSA quantum payout address was created for PoW rewards. Back up this wallet before relying on mined rewards.");
    }
    return result;
},
    };
}

static RPCHelpMan getpowmininginfo()
{
    return RPCHelpMan{"getpowmininginfo",
        "\nReturns the status of the built-in Gold Rush Proof-of-Work miner.\n",
        {},
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "enabled", "Whether in-process PoW mining is enabled."},
            {RPCResult::Type::BOOL, "autostart", "Whether process-wide persistent consent was given to start PoW mining for every eligible loaded wallet."},
            {RPCResult::Type::BOOL, "allow_automatic_quantum_key_creation", "Whether process-wide background automation may create new non-HD keys in loaded wallets."},
            {RPCResult::Type::STR, "state", "Bounded worker state: disabled, starting, chain_unavailable, wallet_locked_or_staking_only, no_spendable_legacy_fee_utxo, stake_reserve_protected, epoch_inactive, claim_in_flight, claim_quarantined, ready, hashing, or error."},
            {RPCResult::Type::NUM, "threads", "Worker threads configured."},
            {RPCResult::Type::NUM, "cpu_percent", "Per-core CPU duty-cycle target."},
            {RPCResult::Type::NUM, "hashrate", "Aggregate Argon2id tries per second."},
            {RPCResult::Type::NUM, "current_height", "Active-chain tip used to evaluate Gold Rush state, or -1 if unavailable."},
            {RPCResult::Type::NUM, "shadow_reward_next_height", "Next block height evaluated for a shadow-ledger reward, or 0 if the chain tip is unavailable."},
            {RPCResult::Type::NUM, "shadow_reward_start_height", "First Gold Rush shadow-ledger reward height."},
            {RPCResult::Type::NUM, "shadow_reward_end_height", "Last Gold Rush shadow-ledger reward height."},
            {RPCResult::Type::BOOL, "epoch_active", "Whether the Gold Rush reward window is currently open."},
            {RPCResult::Type::NUM, "blocks_remaining", "Blocks left in the Gold Rush reward window."},
            {RPCResult::Type::STR, "payout_address", "Configured wallet payout for future new-anchor claims (empty until bound). A retained-family refresh instead preserves that selected family's authenticated payout."},
            {RPCResult::Type::STR_AMOUNT, "accrued_jackpot", "PoW jackpot accrued in the pool."},
            {RPCResult::Type::STR_AMOUNT, "next_claim_payout", "Estimated payout for a valid PoW claim in the next block."},
            {RPCResult::Type::NUM, "next_claim_amount", "Estimated payout for a valid PoW claim in the next block, in satoshis."},
            {RPCResult::Type::NUM, "claims_submitted", "Claims submitted by this miner since it started."},
            {RPCResult::Type::NUM, "unresolved_claims", "Unconfirmed wallet QQSPROOF transactions, whether live or quarantined."},
            {RPCResult::Type::NUM, "live_claims", "Unconfirmed wallet QQSPROOF transactions currently in the local mempool."},
            {RPCResult::Type::NUM, "quarantined_claims", "Backward-compatible legacy count (same as blocking_quarantined_claims). It is audit evidence, not the candidate mining predicate; a safe typed family may relay or refresh while this count is nonzero."},
            {RPCResult::Type::NUM, "raw_quarantined_claims", "All wallet-authored unconfirmed QQSPROOF objects absent from the local mempool, including history already resolved on the active chain."},
            {RPCResult::Type::NUM, "blocking_quarantined_claims", "Legacy actionable-plus-indeterminate compatibility count. Candidate claim creation is controlled by the complete typed mining gate instead."},
            {RPCResult::Type::NUM, "actionable_quarantined_claims", "Quarantined objects whose confirmed anchor remains unspent on the active chain."},
            {RPCResult::Type::NUM, "resolved_on_active_chain_claims", "Historical quarantined objects whose confirmed anchor is already spent on the active chain; retained for reorg safety but not miner-gating."},
            {RPCResult::Type::NUM, "indeterminate_quarantined_claims", "Quarantined objects with incomplete ancestry or an incoherent wallet/chain snapshot; these fail closed and gate mining."},
            {RPCResult::Type::NUM, "claim_components", "Wallet-known quarantined claim components in the current snapshot."},
            {RPCResult::Type::STR_HEX, "claim_inventory_tip", "Active tip to which component classification is bound, or all-zero when unavailable."},
            {RPCResult::Type::BOOL, "claim_inventory_wallet_tip_matches", "Whether the wallet-processed tip exactly matched the classified active tip."},
            {RPCResult::Type::BOOL, "mining_gate_coherent", "Whether the typed mining gate is bound to one matching active-chain and wallet tip."},
            {RPCResult::Type::STR, "mining_gate_action", "Fresh inventory action, except that an enabled claim-in-flight worker may report the optional transient wait_for_next_tip from one exact matching cached snapshot: create_new_anchor, wait_for_live, wait_for_next_tip, relay_existing, refresh_same_anchor, or unsafe."},
            {RPCResult::Type::BOOL, "mining_gate_can_submit", "Fresh inventory authorization to create one additional claim without mutating recovery state. It may be true while mining_gate_action reports a bounded wait_for_next_tip worker override, but does not authorize bypassing that wait."},
            {RPCResult::Type::BOOL, "mining_gate_database_ambiguous", "Whether an ambiguous claim-recovery or user coin-lock database outcome forces the gate closed until wallet reload."},
            {RPCResult::Type::NUM, "mining_gate_unresolved_components", "Unresolved mining-relevant wallet claim components in the typed snapshot. Audit-only incoming proof records remain visible in recovery inventory but do not count here."},
            {RPCResult::Type::NUM, "mining_gate_live_claims", "Members currently in the local mempool across every safe authenticated wallet-owned family."},
            {RPCResult::Type::NUM, "mining_gate_eligible_claims", "Members valid for the pinned tip across every safe authenticated wallet-owned family, whether live or absent."},
            {RPCResult::Type::NUM, "mining_gate_family_claims", "Historical members across every safe authenticated wallet-owned same-anchor family."},
            {RPCResult::Type::NUM, "mining_gate_unsafe_claims", "Claim objects in mining-relevant unresolved components that fail the strict same-anchor family rules."},
            {RPCResult::Type::NUM, "mining_gate_unsafe_components", "Mining-relevant unresolved components that fail the strict same-anchor family rules."},
            {RPCResult::Type::ARR, "mining_gate_reserved_family_anchors", "Exact ordered anchors reserved for every safe unresolved family. A create_new_anchor action with a nonempty array may select only a proven-independent confirmed coin outside this set.", {
                {RPCResult::Type::OBJ, "", "", {
                    {RPCResult::Type::STR_HEX, "txid", "Retained family's authenticated anchor transaction."},
                    {RPCResult::Type::NUM, "vout", "Retained family's authenticated anchor output index."},
                }},
            }},
            {RPCResult::Type::STR_HEX, "mining_gate_relay_txid", "Eligible under-TTL relay claim for the reported gate snapshot, or all-zero when no relay is currently actionable, including while that family is deferred until the next tip."},
            {RPCResult::Type::STR_HEX, "mining_gate_lineage_head_txid", "Selected durable same-anchor lineage head for a family action, or all-zero when no family is selected, including an independent new-anchor fallback that preserves families only in mining_gate_reserved_family_anchors."},
            {RPCResult::Type::STR_HEX, "mining_gate_candidate_state_fingerprint", "Cheap in-memory wallet-claim state key used with tip and database generation to invalidate the cached gate."},
            {RPCResult::Type::NUM, "pending_manual_resolutions", "Persisted unconfirmed manual claim resolutions."},
            {RPCResult::Type::NUM, "pending_automatic_resolutions", "Persisted unconfirmed automatic claim resolutions."},
            {RPCResult::Type::NUM, "claims_auto_resolved", "Confirmed automatic claim resolutions."},
            {RPCResult::Type::NUM, "claims_recycled", "Later claim transactions that spent a confirmed resolution output."},
            {RPCResult::Type::STR_AMOUNT, "cumulative_resolution_fees", "Fees paid by all confirmed managed claim resolutions."},
            {RPCResult::Type::BOOL, "claim_recovery_database_outcome_ambiguous", "Whether recovery database state requires wallet reload and inspection before any further recovery action."},
            {RPCResult::Type::NUM, "configured_stake_reserve_coins", "Mature legacy stake coins protected from PoW claims while staking is enabled."},
            {RPCResult::Type::NUM, "mature_stakeable_legacy_coins", "Mature legacy coins eligible for PoS in the coherent selector snapshot."},
            {RPCResult::Type::STR_AMOUNT, "mature_stakeable_legacy_weight", "Total mature legacy PoS weight before PoW selection."},
            {RPCResult::Type::NUM, "reserved_stake_coins", "Mature legacy coins currently excluded from PoW claim selection."},
            {RPCResult::Type::STR_AMOUNT, "reserved_stake_weight", "Legacy PoS weight protected from PoW claim selection."},
            {RPCResult::Type::NUM, "claim_coins_after_stake_reserve", "Confirmed legacy claim inputs left after applying the stake reserve."},
            {RPCResult::Type::BOOL, "last_stake_coin_guard", "Whether the only mature legacy PoS coin is claim-eligible and therefore protected."},
            {RPCResult::Type::BOOL, "stake_reserve_snapshot_available", "Whether the stake-reserve counts match the wallet-processed active tip."},
        }},
        RPCExamples{
            HelpExampleCli("getpowmininginfo", "")
          + HelpExampleRpc("getpowmininginfo", "")
        },
    [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    UniValue obj(UniValue::VOBJ);
    ShadowPowClaimInventory claim_inventory;
    ShadowPowClaimRecoveryInventory recovery_inventory;
    ShadowPowClaimMiningGate mining_gate;
    size_t unresolved_claims{0};
    size_t live_claims{0};
    ShadowPowClaimRecoveryPolicy recovery_policy =
        DefaultShadowPowClaimRecoveryPolicy();
    ShadowPowClaimRecoveryUsage recovery_usage;
    ShadowPowClaimRecoveryPolicyMutationResult recovery_policy_state;
    bool recovery_database_ambiguous{false};
    ShadowPowClaimStakeReserveInfo stake_reserve;
    ShadowPowClaimMiningGateAction mining_gate_telemetry_action{
        ShadowPowClaimMiningGateAction::UNSAFE};
    bool pow_mining_enabled{false};
    interfaces::WalletPowMiningState pow_mining_state{
        interfaces::WalletPowMiningState::DISABLED};
    {
        LOCK2(::cs_main, pwallet->cs_wallet);
        recovery_inventory =
            pwallet->GetShadowPowClaimRecoveryInventoryLocked();
        claim_inventory = BuildShadowPowClaimCompatibilityInventory(
            recovery_inventory);
        mining_gate =
            pwallet->GetShadowPowClaimMiningGateFromInventoryLocked(
                recovery_inventory);
        mining_gate_telemetry_action =
            pwallet->GetShadowPowClaimMiningGateTelemetryActionLocked(
                mining_gate, pow_mining_enabled, pow_mining_state);
        for (const ShadowPowClaimRecoveryComponent& component :
             recovery_inventory.components) {
            for (const ShadowPowClaimRecoveryNode& node : component.nodes) {
                if (node.kind != ShadowPowClaimRecoveryNodeKind::CLAIM ||
                    node.active_chain_confirmed || !node.wallet_authored) {
                    continue;
                }
                ++unresolved_claims;
                if (node.in_mempool) ++live_claims;
            }
        }
        recovery_policy_state =
            pwallet->GetShadowPowClaimRecoveryPolicyState();
        recovery_database_ambiguous =
            recovery_policy_state.durable_state_ambiguous;
        if (recovery_policy_state.authoritative_state_available) {
            recovery_policy =
                recovery_policy_state.authoritative_policy;
        }
        recovery_usage =
            pwallet->GetShadowPowClaimRecoveryUsageFromInventoryLocked(
                recovery_inventory,
                recovery_policy.rolling_fee_window_seconds);
        stake_reserve = pwallet->GetShadowPowClaimStakeReserveInfoLocked();
    }
    obj.pushKV("enabled", pow_mining_enabled);
    obj.pushKV("autostart", gArgs.GetBoolArg("-powmining", false));
    obj.pushKV("allow_automatic_quantum_key_creation", gArgs.GetBoolArg("-qqallowautokeycreation", DEFAULT_ALLOW_AUTO_QUANTUM_KEY_CREATION));
    obj.pushKV("state", std::string(interfaces::WalletPowMiningStateName(pow_mining_state)));
    obj.pushKV("threads", pwallet->m_pow_threads.load());
    obj.pushKV("cpu_percent", pwallet->m_pow_cpu_percent.load());
    obj.pushKV("hashrate", pwallet->m_pow_hashrate.load());
    obj.pushKV("claims_submitted", (int64_t)pwallet->m_pow_claims_submitted.load());
    obj.pushKV("unresolved_claims",
               static_cast<uint64_t>(unresolved_claims));
    obj.pushKV("live_claims", static_cast<uint64_t>(live_claims));
    obj.pushKV("quarantined_claims", static_cast<uint64_t>(claim_inventory.BlockingClaims()));
    obj.pushKV("raw_quarantined_claims", static_cast<uint64_t>(claim_inventory.raw_quarantined_claims));
    obj.pushKV("blocking_quarantined_claims", static_cast<uint64_t>(claim_inventory.BlockingClaims()));
    obj.pushKV("actionable_quarantined_claims", static_cast<uint64_t>(claim_inventory.actionable_claims));
    obj.pushKV("resolved_on_active_chain_claims", static_cast<uint64_t>(claim_inventory.resolved_on_active_chain_claims));
    obj.pushKV("indeterminate_quarantined_claims", static_cast<uint64_t>(claim_inventory.indeterminate_claims));
    obj.pushKV("claim_components", static_cast<uint64_t>(claim_inventory.components.size()));
    obj.pushKV("claim_inventory_tip", claim_inventory.active_tip.GetHex());
    obj.pushKV("claim_inventory_wallet_tip_matches", claim_inventory.wallet_tip_matches);
    obj.pushKV("mining_gate_coherent", mining_gate.coherent);
    obj.pushKV("mining_gate_action",
               ShadowPowMiningGateActionName(
                   mining_gate_telemetry_action));
    obj.pushKV("mining_gate_can_submit", mining_gate.MayCreateClaim());
    obj.pushKV("mining_gate_database_ambiguous",
               mining_gate.recovery_database_ambiguous);
    obj.pushKV("mining_gate_unresolved_components",
               static_cast<uint64_t>(mining_gate.unresolved_components));
    obj.pushKV("mining_gate_live_claims", static_cast<uint64_t>(mining_gate.live_claims));
    obj.pushKV("mining_gate_eligible_claims", static_cast<uint64_t>(mining_gate.eligible_claims));
    obj.pushKV("mining_gate_family_claims", static_cast<uint64_t>(mining_gate.family_claims));
    obj.pushKV("mining_gate_unsafe_claims", static_cast<uint64_t>(mining_gate.unsafe_claims));
    obj.pushKV("mining_gate_unsafe_components", static_cast<uint64_t>(mining_gate.unsafe_components));
    UniValue reserved_family_anchors(UniValue::VARR);
    for (const COutPoint& anchor : mining_gate.reserved_family_anchors) {
        UniValue reserved_anchor(UniValue::VOBJ);
        reserved_anchor.pushKV("txid", anchor.hash.GetHex());
        reserved_anchor.pushKV("vout", static_cast<uint64_t>(anchor.n));
        reserved_family_anchors.push_back(std::move(reserved_anchor));
    }
    obj.pushKV("mining_gate_reserved_family_anchors",
               std::move(reserved_family_anchors));
    obj.pushKV("mining_gate_relay_txid", mining_gate.relay_txid.GetHex());
    obj.pushKV("mining_gate_lineage_head_txid",
               mining_gate.lineage_head_txid.GetHex());
    obj.pushKV("mining_gate_candidate_state_fingerprint",
               mining_gate.candidate_state_fingerprint.GetHex());
    obj.pushKV("pending_manual_resolutions", static_cast<uint64_t>(recovery_usage.pending_manual));
    obj.pushKV("pending_automatic_resolutions", static_cast<uint64_t>(recovery_usage.pending_automatic));
    obj.pushKV("claims_auto_resolved", static_cast<uint64_t>(recovery_usage.confirmed_automatic));
    obj.pushKV("claims_recycled", static_cast<uint64_t>(recovery_usage.recycled_outputs));
    obj.pushKV("cumulative_resolution_fees", ValueFromAmount(recovery_usage.confirmed_resolution_fees));
    obj.pushKV("claim_recovery_database_outcome_ambiguous", recovery_database_ambiguous);
    obj.pushKV("configured_stake_reserve_coins", stake_reserve.configured_reserve_coins);
    obj.pushKV("mature_stakeable_legacy_coins", static_cast<uint64_t>(stake_reserve.mature_stakeable_legacy_coins));
    obj.pushKV("mature_stakeable_legacy_weight", ValueFromAmount(stake_reserve.mature_stakeable_legacy_weight));
    obj.pushKV("reserved_stake_coins", static_cast<uint64_t>(stake_reserve.reserved_stake_coins));
    obj.pushKV("reserved_stake_weight", ValueFromAmount(stake_reserve.reserved_stake_weight));
    obj.pushKV("claim_coins_after_stake_reserve", static_cast<uint64_t>(stake_reserve.claim_coins_after_reserve));
    obj.pushKV("last_stake_coin_guard", stake_reserve.last_stake_coin_guard);
    obj.pushKV("stake_reserve_snapshot_available", stake_reserve.wallet_tip_matches);
    {
        LOCK(pwallet->cs_wallet);
        obj.pushKV("payout_address", pwallet->m_pow_payout_quantum);
    }

    bool epoch_active = false;
    int current_height = -1;
    int next_height = 0;
    int blocks_remaining = 0;
    CAmount accrued = 0;
    CAmount next_claim = 0;
    {
        ChainstateManager& chainman = pwallet->chain().chainman();
        LOCK(cs_main);
        const CBlockIndex* tip = chainman.ActiveChain().Tip();
        if (tip) {
            const Consensus::Params& consensus = Params().GetConsensus();
            current_height = tip->nHeight;
            next_height = tip->nHeight + 1;
            epoch_active = IsShadowGoldRushRewardActive(consensus, tip->GetMedianTimePast(), next_height);
            blocks_remaining = epoch_active ? std::max(0, SHADOW_REWARD_END_HEIGHT - next_height + 1) : 0;
            accrued = GetShadowGoldRushInfo(chainman.ActiveChainstate().CoinsTip(), tip).pow_amount;
            next_claim = epoch_active ? accrued + ShadowBaseReward(next_height) / 2 : accrued;
        }
    }
    obj.pushKV("current_height", current_height);
    obj.pushKV("shadow_reward_next_height", next_height);
    obj.pushKV("shadow_reward_start_height", SHADOW_REWARD_START_HEIGHT);
    obj.pushKV("shadow_reward_end_height", SHADOW_REWARD_END_HEIGHT);
    obj.pushKV("epoch_active", epoch_active);
    obj.pushKV("blocks_remaining", blocks_remaining);
    obj.pushKV("accrued_jackpot", ValueFromAmount(accrued));
    obj.pushKV("next_claim_payout", ValueFromAmount(next_claim));
    obj.pushKV("next_claim_amount", next_claim);
    return obj;
},
    };
}

static RPCHelpMan getquantumredelegationinfo()
{
    return RPCHelpMan{"getquantumredelegationinfo",
        "\nDry-run Quantum Cold-Stake redelegation policy against the local pool registry.\n"
        "This wallet-policy RPC does not create, sign, or broadcast a transaction. It evaluates\n"
        "the zero-win trigger/rate-limit/probation policy and returns verified target candidates.\n"
        "Over-cap candidates are filtered out when any under-cap alternative exists; if no under-cap\n"
        "candidate exists, all otherwise-valid candidates are returned for bootstrap.\n",
        {
            {"current_staking_pubkey", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Current operator/staker ML-DSA-44 public key."},
            {"delegation_amount", RPCArg::Type::AMOUNT, RPCArg::Optional::NO, "Delegation value to redelegate."},
            {"zero_win_blocks", RPCArg::Type::NUM, RPCArg::Optional::NO, "Consecutive blocks without a realized win for this delegation."},
            {"expected_interval_blocks", RPCArg::Type::NUM, RPCArg::Optional::NO, "Wallet-estimated expected blocks between wins for this delegation."},
            {"options", RPCArg::Type::OBJ, RPCArg::Default{UniValue::VOBJ}, "Optional policy state.", {
                {"last_redelegation_height", RPCArg::Type::NUM, RPCArg::Default{0}, "Height of the last redelegation for this delegation."},
                {"last_successful_redelegation_height", RPCArg::Type::NUM, RPCArg::Default{0}, "Height of the last successful redelegation for this delegation."},
                {"target_activation_height", RPCArg::Type::NUM, RPCArg::Default{0}, "Height when the current target became active."},
                {"delegation_id", RPCArg::Type::STR_HEX, RPCArg::Default{uint256::ONE.GetHex()}, "Stable 32-byte id used for deterministic jitter."},
                {"trigger_multiplier", RPCArg::Type::NUM, RPCArg::Default{6}, "Policy override for test/dry-run trigger multiplier."},
                {"max_patience_blocks", RPCArg::Type::NUM, RPCArg::Default{4050}, "Policy override for max zero-win patience."},
                {"min_trigger_blocks", RPCArg::Type::NUM, RPCArg::Default{300}, "Policy override for absolute minimum zero-win trigger."},
                {"rate_limit_blocks", RPCArg::Type::NUM, RPCArg::Default{1350}, "Policy override for redelegation rate limit."},
                {"probation_blocks", RPCArg::Type::NUM, RPCArg::Default{1350}, "Policy override for new-target probation."},
                {"stampede_jitter_blocks", RPCArg::Type::NUM, RPCArg::Default{1350}, "Policy override for deterministic stampede jitter."},
                {"liveness_improvement_blocks", RPCArg::Type::NUM, RPCArg::Default{300}, "Policy override for minimum target win-history improvement."},
                {"top_liveness_candidates", RPCArg::Type::NUM, RPCArg::Default{4}, "Policy override for deterministic spread set size among live candidates."},
            }},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "should_redelegate", "Whether policy recommends redelegation now."},
            {RPCResult::Type::NUM, "current_height", "Active chain height used for the decision."},
            {RPCResult::Type::NUM, "trigger_blocks", "Zero-win blocks required before redelegation is eligible."},
            {RPCResult::Type::NUM, "eligible_height", "Earliest height after rate-limit, probation, and jitter."},
            {RPCResult::Type::BOOL, "rate_limited", "Whether the delegation is rate-limited."},
            {RPCResult::Type::BOOL, "success_rate_limited", "Whether the delegation is rate-limited by the last successful redelegation."},
            {RPCResult::Type::BOOL, "probation", "Whether the current target is still in probation."},
            {RPCResult::Type::NUM, "jitter_blocks", "Deterministic client-side stampede jitter."},
            {RPCResult::Type::ARR, "candidates", "Ranked verified target operators after per-pool cap bootstrap filtering.", {
                {RPCResult::Type::OBJ, "", "", {
                    {RPCResult::Type::STR_HEX, "staking_pubkey_hash", "SHA256(staking_pubkey)."},
                    {RPCResult::Type::STR_HEX, "staking_pubkey", "Operator/staker ML-DSA public key for new QCS address creation."},
                    {RPCResult::Type::STR_AMOUNT, "verified_value", "Verified operator delegated value."},
                    {RPCResult::Type::NUM, "last_win_height", "Most recent observed win height for this operator known to this wallet, if any."},
                    {RPCResult::Type::NUM, "share_bps", "Current verified cold-stake share in basis points."},
                    {RPCResult::Type::BOOL, "would_exceed_cap", "Whether this candidate would exceed the per-pool cap for the proposed amount."},
                }},
            }},
        }},
        RPCExamples{
            HelpExampleCli("getquantumredelegationinfo", "\"<current_staking_pubkey>\" 100 600 100")
          + HelpExampleRpc("getquantumredelegationinfo", "\"<current_staking_pubkey>\", 100, 600, 100")
        },
    [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    const std::vector<unsigned char> current_pubkey = ParseHexV(request.params[0], "current_staking_pubkey");
    if (current_pubkey.size() != ML_DSA::PUBLICKEY_BYTES) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("current_staking_pubkey must be exactly %u bytes", ML_DSA::PUBLICKEY_BYTES));
    }
    const uint256 current_hash = node::QuantumPoolHashPubKey(current_pubkey);
    const CAmount delegation_amount = AmountFromValue(request.params[1]);
    if (delegation_amount <= 0) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "delegation_amount must be positive");
    }
    const int64_t zero_win_blocks = request.params[2].getInt<int64_t>();
    const int64_t expected_interval_blocks = request.params[3].getInt<int64_t>();
    if (zero_win_blocks < 0 || expected_interval_blocks < 0) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "zero_win_blocks and expected_interval_blocks cannot be negative");
    }

    const UniValue options = request.params[4].isNull() ? UniValue(UniValue::VOBJ) : request.params[4].get_obj();
    const int64_t last_redelegation_height = options.exists("last_redelegation_height") ? options["last_redelegation_height"].getInt<int64_t>() : 0;
    const int64_t last_successful_redelegation_height = options.exists("last_successful_redelegation_height") ? options["last_successful_redelegation_height"].getInt<int64_t>() : 0;
    const int64_t target_activation_height = options.exists("target_activation_height") ? options["target_activation_height"].getInt<int64_t>() : 0;
    const uint256 delegation_id = options.exists("delegation_id") ? ParseHashV(options["delegation_id"], "delegation_id") : current_hash;
    QuantumRedelegationPolicy policy;
    if (options.exists("trigger_multiplier")) policy.trigger_multiplier = options["trigger_multiplier"].getInt<int64_t>();
    if (options.exists("max_patience_blocks")) policy.max_patience_blocks = options["max_patience_blocks"].getInt<int64_t>();
    if (options.exists("min_trigger_blocks")) policy.min_trigger_blocks = options["min_trigger_blocks"].getInt<int64_t>();
    if (options.exists("rate_limit_blocks")) policy.rate_limit_blocks = options["rate_limit_blocks"].getInt<int64_t>();
    if (options.exists("probation_blocks")) policy.probation_blocks = options["probation_blocks"].getInt<int64_t>();
    if (options.exists("stampede_jitter_blocks")) policy.stampede_jitter_blocks = options["stampede_jitter_blocks"].getInt<int64_t>();
    if (options.exists("liveness_improvement_blocks")) policy.liveness_improvement_blocks = options["liveness_improvement_blocks"].getInt<int64_t>();
    if (options.exists("top_liveness_candidates")) policy.top_liveness_candidates = options["top_liveness_candidates"].getInt<int64_t>();
    if (policy.trigger_multiplier <= 0 || policy.max_patience_blocks <= 0 || policy.min_trigger_blocks <= 0 ||
        policy.rate_limit_blocks < 0 || policy.probation_blocks < 0 || policy.stampede_jitter_blocks < 0 ||
        policy.liveness_improvement_blocks <= 0 || policy.top_liveness_candidates <= 0) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "redelegation policy values are out of range");
    }

    ChainstateManager& chainman = pwallet->chain().chainman();
    int current_height{0};
    std::vector<QuantumRedelegationCandidate> candidates;
    std::map<uint256, int> operator_last_win_height;
    {
        LOCK(pwallet->cs_wallet);
        for (const QuantumColdStakeDelegationInfo& info : pwallet->ListQuantumColdStakeDelegationInfos()) {
            const auto win = pwallet->m_redelegation_last_win_height.find(info.witness_program);
            if (win == pwallet->m_redelegation_last_win_height.end()) continue;
            auto& height = operator_last_win_height[info.staker_pubkey_hash];
            height = std::max(height, win->second);
        }
    }
    {
        LOCK(cs_main);
        const CBlockIndex* tip = chainman.ActiveChain().Tip();
        current_height = tip ? tip->nHeight : 0;
        const CCoinsViewCache& view = chainman.ActiveChainstate().CoinsTip();
        for (const uint256& staker_hash : node::ListQuantumPoolOperators()) {
            const node::QuantumPoolShare share = node::ComputeQuantumPoolShare(view, staker_hash, node::GetQuantumPoolClaims(staker_hash));
            QuantumRedelegationCandidate candidate;
            candidate.staker_pubkey_hash = staker_hash;
            candidate.staker_pubkey = share.operator_share.staker_pubkey;
            candidate.operator_value = share.operator_share.verified_value;
            candidate.total_coldstake = share.total_coldstake;
            const auto win = operator_last_win_height.find(staker_hash);
            candidate.last_win_height = win == operator_last_win_height.end() ? 0 : win->second;
            candidate.operator_commitment_verified = share.operator_share.operator_commitment_verified;
            candidate.current_operator = staker_hash == current_hash;
            candidates.push_back(std::move(candidate));
        }
    }

    const QuantumRedelegationStatus status = EvaluateQuantumRedelegation(
        zero_win_blocks,
        expected_interval_blocks,
        current_height,
        last_redelegation_height,
        last_successful_redelegation_height,
        target_activation_height,
        delegation_id,
        current_hash,
        policy);
    const auto ranked = RankQuantumRedelegationCandidates(candidates, delegation_amount, policy);

    UniValue candidate_values(UniValue::VARR);
    for (const QuantumRedelegationCandidateScore& score : ranked) {
        UniValue candidate(UniValue::VOBJ);
        candidate.pushKV("staking_pubkey_hash", score.candidate.staker_pubkey_hash.GetHex());
        candidate.pushKV("staking_pubkey", HexStr(score.candidate.staker_pubkey));
        candidate.pushKV("verified_value", ValueFromAmount(score.candidate.operator_value));
        candidate.pushKV("last_win_height", score.last_win_height);
        candidate.pushKV("share_bps", score.share_bps);
        candidate.pushKV("would_exceed_cap", score.would_exceed_cap);
        candidate_values.push_back(std::move(candidate));
    }

    UniValue obj(UniValue::VOBJ);
    obj.pushKV("should_redelegate", status.should_redelegate);
    obj.pushKV("current_height", current_height);
    obj.pushKV("trigger_blocks", status.trigger_blocks);
    obj.pushKV("eligible_height", status.eligible_height);
    obj.pushKV("rate_limited", status.rate_limited);
    obj.pushKV("success_rate_limited", status.success_rate_limited);
    obj.pushKV("probation", status.probation);
    obj.pushKV("jitter_blocks", status.jitter_blocks);
    obj.pushKV("candidates", candidate_values);
    return obj;
},
    };
}

static RPCHelpMan redelegatequantumcoldstake()
{
    return RPCHelpMan{"redelegatequantumcoldstake",
        "\nCreate or broadcast an owner-branch Quantum Cold-Stake redelegation transaction.\n"
        "The wallet spends all selected UTXOs from a wallet-owned source QCS address into a new\n"
        "wallet-backed QCS address for the target staking public key. Consensus is unchanged; this is\n"
        "ordinary owner spending with per-pool cap and redelegation wallet policy checks.\n"
        "dry_run=true creates no wallet metadata. Broadcasting with dry_run=false creates a durable non-HD ML-DSA owner key that is not seed-recoverable; back up the wallet whenever the result or an error reports the created address because the key can remain after a later failure.\n",
        {
            {"source_coldstake_address", RPCArg::Type::STR, RPCArg::Optional::NO, "Wallet-owned source Quantum Cold-Stake address."},
            {"target_staking_pubkey", RPCArg::Type::STR_HEX, RPCArg::Optional::NO, "Target operator/staker ML-DSA-44 public key."},
            {"options", RPCArg::Type::OBJ, RPCArg::Default{UniValue::VOBJ}, "Redelegation options.", {
                {"dry_run", RPCArg::Type::BOOL, RPCArg::Default{true}, "Build and return a read-only, unsigned transaction plan without broadcasting or creating wallet metadata. Set false to create the wallet-backed target QCS address and broadcast."},
                {"allow_new_quantum_key", RPCArg::Type::BOOL, RPCArg::Default{false}, "Required with dry_run=false. Explicitly authorize the new non-HD ML-DSA owner key and back up the wallet whenever the result or an error reports the created address; the durable key can remain after a later failure."},
                {"enforce_pool_cap", RPCArg::Type::BOOL, RPCArg::Default{true}, "Refuse over-cap redelegation only when an under-cap alternative exists; otherwise allow bootstrap and report the over-cap projection."},
                {"require_verified_operator", RPCArg::Type::BOOL, RPCArg::Default{true}, "Refuse if the target operator has no locally verified 30-day Operator-tier commitment."},
                {"fee_rate", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Optional fee rate in " + CURRENCY_ATOM + "/vB."},
                {"label", RPCArg::Type::STR, RPCArg::Default{"redelegated-coldstake"}, "Label for the new QCS address."},
            }},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "dry_run", "Whether the transaction was only planned."},
            {RPCResult::Type::STR, "source_address", "Source QCS address."},
            {RPCResult::Type::STR, "target_address", "Target QCS address. In dry_run this is a planning address and is not written to the wallet."},
            {RPCResult::Type::BOOL, "target_wallet_backed", "Whether this wallet stores the target owner key and QCS metadata."},
            {RPCResult::Type::STR_AMOUNT, "input_amount", "Selected source value."},
            {RPCResult::Type::STR_AMOUNT, "output_amount", "Redelegated output value after fees."},
            {RPCResult::Type::STR_AMOUNT, "fee", "Transaction fee."},
            {RPCResult::Type::NUM, "vsize", "Virtual transaction size."},
            {RPCResult::Type::OBJ, "pool_policy", "Per-pool cap and redelegation local pool policy result.", {
                {RPCResult::Type::BOOL, "operator_commitment_verified", "Whether the target has a verified Operator-tier commitment in the local registry."},
                {RPCResult::Type::STR_AMOUNT, "post_total_coldstake", "Projected total cold-stake UTXO value after the redelegation."},
                {RPCResult::Type::STR_AMOUNT, "post_operator_value", "Projected verified target operator value after the redelegation."},
                {RPCResult::Type::NUM, "post_share_bps", "Projected target operator share in basis points."},
                {RPCResult::Type::BOOL, "would_exceed_cap", "Whether the projected redelegation exceeds the local per-pool cap."},
                {RPCResult::Type::BOOL, "cap_enforced", "Whether over-cap projections are refused."},
                {RPCResult::Type::BOOL, "cap_filter_unlocked", "Whether the over-cap target was allowed because no under-cap alternative exists."},
            }},
            {RPCResult::Type::STR_HEX, "hex", "Transaction hex. Dry-run hex is unsigned planning output and is not intended for broadcast."},
            {RPCResult::Type::STR_HEX, "txid", /*optional=*/true, "Broadcast transaction id."},
            {RPCResult::Type::STR, "warning", /*optional=*/true, "Backup warning when a new owner key was created."},
        }},
        RPCExamples{
            HelpExampleCli("redelegatequantumcoldstake", "\"<source_qcs_address>\" \"<target_staking_pubkey>\" '{\"dry_run\":true}'")
          + HelpExampleCli("redelegatequantumcoldstake", "\"<source_qcs_address>\" \"<target_staking_pubkey>\" '{\"dry_run\":false,\"allow_new_quantum_key\":true}'")
          + HelpExampleRpc("redelegatequantumcoldstake", "\"<source_qcs_address>\", \"<target_staking_pubkey>\", {\"dry_run\":true}")
        },
    [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    const std::string source_address = request.params[0].get_str();
    const CTxDestination source_dest = DecodeDestination(source_address);
    if (!IsValidDestination(source_dest) || !IsQuantumColdStakeDestination(source_dest)) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "source_coldstake_address is not a Quantum Cold-Stake address");
    }

    const std::vector<unsigned char> target_staking_pubkey = ParseHexV(request.params[1], "target_staking_pubkey");
    if (target_staking_pubkey.size() != ML_DSA::PUBLICKEY_BYTES) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("target_staking_pubkey must be exactly %u bytes", ML_DSA::PUBLICKEY_BYTES));
    }

    const UniValue options = request.params[2].isNull() ? UniValue(UniValue::VOBJ) : request.params[2].get_obj();
    QuantumColdStakeRedelegationOptions redelegation_options;
    redelegation_options.dry_run = !options.exists("dry_run") || options["dry_run"].get_bool();
    redelegation_options.allow_new_quantum_key = redelegation_options.dry_run
        ? false
        : RequireNewQuantumKeyConsent(options, "redelegatequantumcoldstake");
    redelegation_options.enforce_pool_cap = !options.exists("enforce_pool_cap") || options["enforce_pool_cap"].get_bool();
    redelegation_options.require_verified_operator = !options.exists("require_verified_operator") || options["require_verified_operator"].get_bool();
    redelegation_options.label = options.exists("label") ? LabelFromValue(options["label"]) : "redelegated-coldstake";
    if (options.exists("fee_rate")) {
        redelegation_options.fee_rate = FeeRateFromSatVbValue(options["fee_rate"]);
    }

    QuantumColdStakeRedelegationResult redelegation;
    bilingual_str error;
    if (!CreateQuantumColdStakeRedelegationTransaction(*pwallet, source_dest, target_staking_pubkey, redelegation_options, redelegation, error)) {
        throw JSONRPCError(RPC_WALLET_ERROR, error.original);
    }

    UniValue pool_policy(UniValue::VOBJ);
    pool_policy.pushKV("operator_commitment_verified", redelegation.operator_commitment_verified);
    pool_policy.pushKV("post_total_coldstake", ValueFromAmount(redelegation.post_total_coldstake));
    pool_policy.pushKV("post_operator_value", ValueFromAmount(redelegation.post_operator_value));
    pool_policy.pushKV("post_share_bps", redelegation.post_share_bps);
    pool_policy.pushKV("would_exceed_cap", redelegation.would_exceed_cap);
    pool_policy.pushKV("cap_enforced", redelegation.cap_enforced);
    pool_policy.pushKV("cap_filter_unlocked", redelegation.cap_filter_unlocked);

    UniValue obj(UniValue::VOBJ);
    obj.pushKV("dry_run", redelegation.dry_run);
    obj.pushKV("source_address", source_address);
    obj.pushKV("target_address", EncodeDestination(redelegation.target_dest));
    obj.pushKV("target_wallet_backed", redelegation.target_wallet_backed);
    obj.pushKV("input_amount", ValueFromAmount(redelegation.input_amount));
    obj.pushKV("output_amount", ValueFromAmount(redelegation.output_amount));
    obj.pushKV("fee", ValueFromAmount(redelegation.fee));
    obj.pushKV("vsize", redelegation.vsize);
    obj.pushKV("pool_policy", pool_policy);
    obj.pushKV("hex", EncodeHexTx(*redelegation.tx));
    if (!redelegation.dry_run) {
        obj.pushKV("txid", redelegation.tx->GetHash().GetHex());
        obj.pushKV("warning", "A new non-HD ML-DSA delegation owner key was created. Back up this wallet now; an older backup cannot recover it.");
    }
    return obj;
},
    };
}

static RPCHelpMan senddemurrageattestation()
{
    return RPCHelpMan{"senddemurrageattestation",
        "\nCreate a fee-paying demurrage liveness attestation for an eligible wallet-backed direct or tiered v16 Blackcoin ML-DSA address.\n"
        "Cold-stake outputs cannot be attested.\n"
        "The attestation output carries no value; it refreshes the key's inactivity clock once mined after -qqdemurrageheight is active.\n",
        {
            {"address", RPCArg::Type::STR, RPCArg::Optional::NO, "Eligible wallet-backed direct or tiered v16 Blackcoin migration address to attest."},
            {"options", RPCArg::Type::OBJ, RPCArg::Default{UniValue::VOBJ}, "Attestation options.",
            {
                {"dry_run", RPCArg::Type::BOOL, RPCArg::Default{false}, "Build and return the transaction without committing it to the wallet."},
                {"fee_rate", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Fee rate in sat/vB."},
            }},
        },
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "dry_run", "Whether the transaction was only planned."},
            {RPCResult::Type::STR, "address", "Attested Blackcoin migration address."},
            {RPCResult::Type::STR_HEX, "witness_program", "Attested witness program / public-key hash."},
            {RPCResult::Type::STR_HEX, "public_key", "Attested ML-DSA public key."},
            {RPCResult::Type::STR_HEX, "replay_anchor", "First input outpoint bound into the ML-DSA attestation signature."},
            {RPCResult::Type::STR_HEX, "target_outpoint", "Live quantum UTXO proving that the attested key is relevant."},
            {RPCResult::Type::NUM, "attestation_vout", "Output index carrying the zero-value demurrage attestation."},
            {RPCResult::Type::STR_AMOUNT, "fee", "Transaction fee."},
            {RPCResult::Type::NUM, "vsize", "Virtual transaction size."},
            {RPCResult::Type::STR_HEX, "hex", "Transaction hex."},
            {RPCResult::Type::STR_HEX, "txid", /*optional=*/true, "Broadcast transaction id."},
        }},
        RPCExamples{
            HelpExampleCli("senddemurrageattestation", "\"<quantum_address>\"")
          + HelpExampleRpc("senddemurrageattestation", "\"<quantum_address>\"")
        },
    [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return NullUniValue;

    std::string error_msg;
    const CTxDestination dest = DecodeDestination(request.params[0].get_str(), error_msg);
    if (!IsValidDestination(dest)) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, error_msg.empty() ? "Invalid address" : error_msg);
    }
    const auto* witness = std::get_if<WitnessUnknown>(&dest);
    if (!witness || !IsQuantumMigrationWitnessProgram(witness->GetWitnessVersion(), witness->GetWitnessProgram())) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Address is not a Blackcoin migration address");
    }

    const UniValue options = request.params[1].isNull() ? UniValue(UniValue::VOBJ) : request.params[1].get_obj();
    const bool dry_run = options.exists("dry_run") && options["dry_run"].get_bool();

    CCoinControl coin_control;
    if (options.exists("fee_rate")) {
        coin_control.m_feerate = FeeRateFromSatVbValue(options["fee_rate"]);
        coin_control.fOverrideFeeRate = true;
    }

    pwallet->BlockUntilSyncedToCurrentChain();

    {
        LOCK(pwallet->cs_wallet);
        EnsureWalletIsUnlocked(*pwallet);
        if (pwallet->m_wallet_unlock_staking_only) {
            throw JSONRPCError(RPC_WALLET_ERROR, "Wallet unlocked for staking only, unable to create demurrage attestation");
        }
    }

    DemurrageAttestationTxResult tx_result;
    bilingual_str error;
    if (!CreateDemurrageAttestationTransaction(*pwallet, witness->GetWitnessProgram(), coin_control, /*sign=*/!dry_run, tx_result, error)) {
        throw JSONRPCError(RPC_WALLET_ERROR, error.original);
    }
    const CTransactionRef& tx = tx_result.tx;

    UniValue obj(UniValue::VOBJ);
    obj.pushKV("dry_run", dry_run);
    obj.pushKV("address", EncodeDestination(dest));
    obj.pushKV("witness_program", HexStr(witness->GetWitnessProgram()));
    obj.pushKV("public_key", HexStr(tx_result.public_key));
    obj.pushKV("replay_anchor", tx_result.replay_anchor.ToString());
    obj.pushKV("target_outpoint", tx_result.target_outpoint.ToString());
    obj.pushKV("attestation_vout", tx_result.attestation_vout);
    obj.pushKV("fee", ValueFromAmount(tx_result.fee));
    obj.pushKV("vsize", (int)GetVirtualTransactionSize(*tx, 0, 0));
    obj.pushKV("hex", EncodeHexTx(*tx));
    if (!dry_run) {
        mapValue_t map_value;
        map_value["comment"] = "Blackcoin demurrage attestation";
        CommitWalletTransactionOrThrow(*pwallet, tx, std::move(map_value), "Blackcoin demurrage attestation");
        obj.pushKV("txid", tx->GetHash().GetHex());
    }
    return obj;
},
    };
}

static RPCHelpMan getdemurragewalletinfo()
{
    return RPCHelpMan{"getdemurragewalletinfo",
        "\nReport demurrage exposure for wallet-owned Blackcoin ML-DSA outputs.\n"
        "Amounts are evaluated for the next block so the result matches wallet funding behavior once -qqdemurrageheight is active.\n",
        {},
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "demurrage_active", "Whether demurrage is active for the evaluation height"},
            {RPCResult::Type::NUM, "tip_height", "Current active-chain tip height"},
            {RPCResult::Type::NUM, "evaluation_height", "Height used for spend/effective-value evaluation"},
            {RPCResult::Type::NUM_TIME, "evaluation_time", "Parent MedianTimePast used for next-block spend/effective-value evaluation"},
            {RPCResult::Type::NUM, "demurrage_activation_height", "Configured demurrage activation height"},
            {RPCResult::Type::NUM, "demurrage_effective_activation_height", "Demurrage activation height after the post-Gold-Rush clamp"},
            {RPCResult::Type::NUM_TIME, "quantum_migration_deadline_time", "Final quantum migration deadline time used by the demurrage post-migration guard"},
            {RPCResult::Type::BOOL, "demurrage_height_guard_satisfied", "Whether evaluation_height is at or above demurrage_effective_activation_height"},
            {RPCResult::Type::BOOL, "demurrage_post_migration_guard_satisfied", "Whether evaluation_time is after quantum_migration_deadline_time"},
            {RPCResult::Type::BOOL, "wallet_staking_enabled", "Whether this wallet has staking enabled"},
            {RPCResult::Type::NUM, "quantum_outputs", "Wallet-owned direct or tiered v16 quantum outputs considered"},
            {RPCResult::Type::NUM, "decaying_outputs", "Outputs whose effective value is below nominal value"},
            {RPCResult::Type::NUM, "locked_outputs", "Outputs at the 24-month demurrage lock point"},
            {RPCResult::Type::NUM, "attestation_due_outputs", "Outputs at or beyond the 3-month auto-attestation policy threshold"},
            {RPCResult::Type::STR_AMOUNT, "nominal_amount", "Nominal value of considered wallet-owned direct or tiered v16 quantum outputs"},
            {RPCResult::Type::STR_AMOUNT, "effective_amount", "Demurrage-adjusted spendable value at evaluation_height"},
            {RPCResult::Type::STR_AMOUNT, "burned_if_spent_amount", "Amount that would be burned if all considered outputs were spent at evaluation_height"},
            {RPCResult::Type::ARR, "outputs", "Per-output demurrage state",
            {
                {RPCResult::Type::OBJ, "", "",
                {
                    {RPCResult::Type::STR_HEX, "txid", "Transaction id"},
                    {RPCResult::Type::NUM, "vout", "Output index"},
                    {RPCResult::Type::STR, "address", "Wallet-backed Blackcoin migration address"},
                    {RPCResult::Type::NUM, "depth", "Wallet confirmation depth"},
                    {RPCResult::Type::NUM, "coin_height", "Consensus coin height used for evaluation"},
                    {RPCResult::Type::BOOL, "chainstate_backed", "Whether the output was found in chainstate/mempool lookup"},
                    {RPCResult::Type::NUM, "latest_attestation_height", /*optional=*/true, "Latest mined liveness attestation height for this key"},
                    {RPCResult::Type::NUM, "attestation_coverage_start_height", /*optional=*/true, "Beginning of the uninterrupted attestation coverage epoch"},
                    {RPCResult::Type::NUM, "inactive_blocks", "Blocks since the effective last-active height"},
                    {RPCResult::Type::NUM, "remaining_ppm", "Remaining value in parts per million"},
                    {RPCResult::Type::STR_AMOUNT, "nominal_amount", "Nominal output value"},
                    {RPCResult::Type::STR_AMOUNT, "effective_amount", "Demurrage-adjusted output value"},
                    {RPCResult::Type::STR_AMOUNT, "burned_if_spent_amount", "Amount burned if this output is spent now"},
                    {RPCResult::Type::BOOL, "locked", "Whether this output has reached the 24-month lock"},
                    {RPCResult::Type::STR, "exemption", "Reason the output is currently whole, or empty when decaying"},
                    {RPCResult::Type::NUM, "blocks_until_decay", "Blocks until decay starts; zero if already decaying"},
                    {RPCResult::Type::NUM, "blocks_until_lock", "Blocks until hard lock; zero if already locked"},
                    {RPCResult::Type::BOOL, "attestation_due", "Whether this output is beyond the 3-month auto-attestation policy threshold"},
                    {RPCResult::Type::STR, "action", "Suggested wallet action"},
                }},
            }},
        }},
        RPCExamples{
            HelpExampleCli("getdemurragewalletinfo", "")
          + HelpExampleRpc("getdemurragewalletinfo", "")
        },
    [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    const std::shared_ptr<const CWallet> pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return UniValue::VNULL;

    pwallet->BlockUntilSyncedToCurrentChain();

    LOCK2(cs_main, pwallet->cs_wallet);

    const Consensus::Params& consensus = Params().GetConsensus();
    const CBlockIndex* tip = pwallet->chain().getTip();
    const int tip_height = tip ? tip->nHeight : -1;
    const int evaluation_height = tip_height >= 0 ? tip_height + 1 : 0;
    const int64_t evaluation_time = tip ? tip->GetMedianTimePast() : 0;
    const bool demurrage_active = consensus.IsDemurrageActive(evaluation_height, evaluation_time);
    const bool wallet_staking_enabled = pwallet->m_enabled_staking.load();

    CoinsResult available = AvailableCoinsListUnspent(*pwallet);
    std::map<COutPoint, Coin> chain_coins;
    std::vector<COutput> quantum_outputs;
    for (const COutput& out : available.All()) {
        if (!IsQuantumMigrationScript(out.txout.scriptPubKey)) continue;
        CTxDestination dest;
        if (!ExtractDestination(out.txout.scriptPubKey, dest) || !pwallet->GetQuantumKeyInfo(dest).has_value()) continue;
        chain_coins.emplace(out.outpoint, Coin{});
        quantum_outputs.push_back(out);
    }
    pwallet->chain().findCoins(chain_coins);

    CAmount nominal_total{0};
    CAmount effective_total{0};
    CAmount burned_total{0};
    int decaying_count{0};
    int locked_count{0};
    int attestation_due_count{0};
    UniValue outputs(UniValue::VARR);

    const CCoinsViewCache& view = pwallet->chain().getCoinsTip();
    for (const COutput& out : quantum_outputs) {
        CTxDestination dest;
        CHECK_NONFATAL(ExtractDestination(out.txout.scriptPubKey, dest));

        const auto coin_it = chain_coins.find(out.outpoint);
        const bool chainstate_backed = coin_it != chain_coins.end() && !coin_it->second.IsSpent();
        if (!chainstate_backed) {
            CHECK_NONFATAL(out.time >= 0 && out.time <= static_cast<int64_t>(std::numeric_limits<uint32_t>::max()));
        }
        Coin coin = chainstate_backed ? coin_it->second : Coin{out.txout, out.depth > 0 ? tip_height - out.depth + 1 : evaluation_height, false, false, static_cast<uint32_t>(out.time)};
        const std::optional<Consensus::DemurrageAttestationState> latest_attestation =
            Consensus::LatestDemurrageAttestationStateForScript(view, out.txout.scriptPubKey);
        const Consensus::DemurrageEvaluation eval = Consensus::EvaluateDemurrage(
            coin, consensus, evaluation_height, evaluation_time,
            latest_attestation ? std::optional<int>{latest_attestation->height} : std::nullopt,
            latest_attestation ? std::optional<int>{static_cast<int>(latest_attestation->coverage_start_height)} : std::nullopt);
        const bool attestation_due = demurrage_active && !eval.locked && eval.inactive_blocks >= consensus.DemurrageAutoAttestBlocks();

        nominal_total += eval.nominal_value;
        effective_total += eval.effective_value;
        burned_total += eval.burned_value;
        if (eval.burned_value > 0) ++decaying_count;
        if (eval.locked) ++locked_count;
        if (attestation_due) ++attestation_due_count;

        UniValue entry(UniValue::VOBJ);
        entry.pushKV("txid", out.outpoint.hash.GetHex());
        entry.pushKV("vout", static_cast<int>(out.outpoint.n));
        entry.pushKV("address", EncodeDestination(dest));
        entry.pushKV("depth", out.depth);
        entry.pushKV("coin_height", static_cast<int>(coin.nHeight));
        entry.pushKV("chainstate_backed", chainstate_backed);
        if (latest_attestation) {
            entry.pushKV("latest_attestation_height", latest_attestation->height);
            entry.pushKV("attestation_coverage_start_height", latest_attestation->coverage_start_height);
        }
        entry.pushKV("inactive_blocks", eval.inactive_blocks);
        entry.pushKV("remaining_ppm", eval.remaining_ppm);
        entry.pushKV("nominal_amount", ValueFromAmount(eval.nominal_value));
        entry.pushKV("effective_amount", ValueFromAmount(eval.effective_value));
        entry.pushKV("burned_if_spent_amount", ValueFromAmount(eval.burned_value));
        entry.pushKV("locked", eval.locked);
        entry.pushKV("exemption", eval.exemption);
        entry.pushKV("blocks_until_decay", std::max(0, consensus.DemurrageGraceBlocks() - eval.inactive_blocks));
        entry.pushKV("blocks_until_lock", std::max(0, consensus.DemurrageZeroBlocks() - eval.inactive_blocks));
        entry.pushKV("attestation_due", attestation_due);
        std::string action;
        if (!demurrage_active) {
            action = "none: demurrage is inactive";
        } else if (eval.locked) {
            action = "locked: this output can no longer be spent";
        } else if (attestation_due && wallet_staking_enabled) {
            action = "attestation due: automatic attempt also requires normal unlock and a safe fee input";
        } else if (attestation_due) {
            action = "senddemurrageattestation recommended";
        } else if (eval.burned_value > 0) {
            action = "full-sweep spend recommended to realize decay in one transaction";
        } else {
            action = "none";
        }
        entry.pushKV("action", action);
        outputs.push_back(std::move(entry));
    }

    UniValue obj(UniValue::VOBJ);
    obj.pushKV("demurrage_active", demurrage_active);
    obj.pushKV("tip_height", tip_height);
    obj.pushKV("evaluation_height", evaluation_height);
    obj.pushKV("evaluation_time", evaluation_time);
    obj.pushKV("demurrage_activation_height", consensus.nDemurrageActivationHeight);
    obj.pushKV("demurrage_effective_activation_height", consensus.EffectiveDemurrageActivationHeight());
    obj.pushKV("quantum_migration_deadline_time", consensus.nQuantumMigrationDeadlineTime);
    obj.pushKV("demurrage_height_guard_satisfied", evaluation_height >= consensus.EffectiveDemurrageActivationHeight());
    obj.pushKV("demurrage_post_migration_guard_satisfied", consensus.IsMigrationEndScheduled() && consensus.MigrationDeadlinePassed(evaluation_time, evaluation_height));
    obj.pushKV("wallet_staking_enabled", wallet_staking_enabled);
    obj.pushKV("quantum_outputs", static_cast<int>(quantum_outputs.size()));
    obj.pushKV("decaying_outputs", decaying_count);
    obj.pushKV("locked_outputs", locked_count);
    obj.pushKV("attestation_due_outputs", attestation_due_count);
    obj.pushKV("nominal_amount", ValueFromAmount(nominal_total));
    obj.pushKV("effective_amount", ValueFromAmount(effective_total));
    obj.pushKV("burned_if_spent_amount", ValueFromAmount(burned_total));
    obj.pushKV("outputs", std::move(outputs));
    return obj;
},
    };
}

static RPCHelpMan sweepdemurragedecay()
{
    return RPCHelpMan{"sweepdemurragedecay",
        "\nSweep wallet-owned direct Blackcoin ML-DSA outputs that are already decaying under demurrage.\n"
        "The transaction consumes the selected decaying UTXOs, realizes the demurrage burn, and pays the remaining effective value\n"
        "minus fees to a wallet-backed quantum address.\n",
        {
            {"options", RPCArg::Type::OBJ_NAMED_PARAMS, RPCArg::Optional::OMITTED, "",
                {
                    {"dry_run", RPCArg::Type::BOOL, RPCArg::Default{false}, "Build and return the transaction without committing it to the wallet or creating wallet metadata. Requires destination_address."},
                    {"source_address", RPCArg::Type::STR, RPCArg::Default{""}, "Sweep only decaying UTXOs paying this wallet-backed quantum address."},
                    {"destination_address", RPCArg::Type::STR, RPCArg::Default{""}, "Wallet-backed quantum address to receive the effective value; omitted generates a fresh address for broadcast mode. Required for dry_run."},
                    {"allow_new_quantum_key", RPCArg::Type::BOOL, RPCArg::Default{false}, "When destination_address is omitted, explicitly authorize one new non-HD ML-DSA destination key. Back up the wallet whenever the result or an error reports the created address; the durable key can remain after a later failure."},
                    {"label", RPCArg::Type::STR, RPCArg::Default{"demurrage-sweep"}, "Label for a freshly generated destination address."},
                    {"fee_rate", RPCArg::Type::AMOUNT, RPCArg::Optional::OMITTED, "Fee rate in sat/vB."},
                    {"include_unsafe", RPCArg::Type::BOOL, RPCArg::Default{false}, "Include unconfirmed or unsafe selected outputs."},
                },
            },
        },
        RPCResult{RPCResult::Type::OBJ, "", "", {
            {RPCResult::Type::BOOL, "dry_run", "Whether the transaction was only planned."},
            {RPCResult::Type::NUM, "evaluation_height", "Height used for demurrage evaluation"},
            {RPCResult::Type::NUM_TIME, "evaluation_time", "Parent MedianTimePast used for next-block demurrage evaluation"},
            {RPCResult::Type::NUM, "selected_inputs", "Number of decaying UTXOs selected"},
            {RPCResult::Type::NUM, "skipped_locked_outputs", "Number of fully locked decayed UTXOs skipped"},
            {RPCResult::Type::STR_AMOUNT, "nominal_amount", "Nominal selected value before demurrage"},
            {RPCResult::Type::STR_AMOUNT, "effective_amount", "Selected value after demurrage"},
            {RPCResult::Type::STR_AMOUNT, "burned_amount", "Demurrage amount realized as burn"},
            {RPCResult::Type::STR_AMOUNT, "skipped_locked_amount", "Nominal value of locked outputs skipped"},
            {RPCResult::Type::STR, "destination", "Quantum address receiving the effective value after fee"},
            {RPCResult::Type::BOOL, "newly_generated", "Whether the destination address was freshly generated"},
            {RPCResult::Type::STR_AMOUNT, "amount", "Value of the new quantum output after fee"},
            {RPCResult::Type::STR_AMOUNT, "fee", "Transaction fee"},
            {RPCResult::Type::NUM, "vsize", "Virtual transaction size"},
            {RPCResult::Type::STR_HEX, "hex", "Transaction hex"},
            {RPCResult::Type::STR_HEX, "txid", /*optional=*/true, "Broadcast transaction id"},
            {RPCResult::Type::STR, "warning", /*optional=*/true, "Backup warning"},
        }},
        RPCExamples{
            HelpExampleCli("sweepdemurragedecay", "'{\"allow_new_quantum_key\":true}'")
          + HelpExampleCli("sweepdemurragedecay", "'{\"dry_run\":true,\"destination_address\":\"<quantum_addr>\"}'")
          + HelpExampleRpc("sweepdemurragedecay", "{\"source_address\":\"<quantum_addr>\"}")
        },
    [&](const RPCHelpMan& self, const JSONRPCRequest& request) -> UniValue
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return UniValue::VNULL;

    const UniValue options = request.params[0].isNull() ? UniValue(UniValue::VOBJ) : request.params[0].get_obj();
    const bool dry_run = options.exists("dry_run") && options["dry_run"].get_bool();
    const bool include_unsafe = options.exists("include_unsafe") && options["include_unsafe"].get_bool();
    const std::string source_address = options.exists("source_address") ? options["source_address"].get_str() : "";
    const std::string destination_address = options.exists("destination_address") ? options["destination_address"].get_str() : "";
    const std::string label = options.exists("label") ? options["label"].get_str() : "demurrage-sweep";
    const std::optional<CFeeRate> requested_fee_rate = options.exists("fee_rate")
        ? std::optional<CFeeRate>{FeeRateFromSatVbValue(options["fee_rate"])}
        : std::nullopt;
    if (dry_run && destination_address.empty()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "dry_run requires destination_address so the estimate does not create wallet metadata");
    }
    if (!dry_run && destination_address.empty() &&
        (!options.exists("allow_new_quantum_key") || !options["allow_new_quantum_key"].get_bool())) {
        throw JSONRPCError(
            RPC_INVALID_PARAMETER,
            "sweepdemurragedecay without destination_address creates a new non-HD ML-DSA key that an older wallet backup cannot recover. Retry with {\"allow_new_quantum_key\":true}, or supply an existing wallet-owned direct quantum destination_address. Back up the wallet after key creation. No key, transaction, or wallet metadata was created.");
    }

    LOCK2(cs_main, pwallet->cs_wallet);
    if (!dry_run) {
        EnsureWalletIsUnlocked(*pwallet);
        if (pwallet->m_wallet_unlock_staking_only) {
            throw JSONRPCError(RPC_WALLET_ERROR, "Wallet unlocked for staking only, unable to sweep demurrage outputs");
        }
        if (pwallet->IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)) {
            throw JSONRPCError(RPC_WALLET_ERROR, "Error: Private keys are disabled for this wallet");
        }
    }

    const Consensus::Params& consensus = Params().GetConsensus();
    const CBlockIndex* tip = pwallet->chain().getTip();
    const int tip_height = tip ? tip->nHeight : -1;
    const int evaluation_height = tip_height >= 0 ? tip_height + 1 : 0;
    const int64_t evaluation_time = tip ? tip->GetMedianTimePast() : 0;
    if (!consensus.IsDemurrageActive(evaluation_height, evaluation_time)) {
        throw JSONRPCError(RPC_WALLET_ERROR, "demurrage is not active for the next block");
    }

    std::optional<CScript> source_script;
    if (!source_address.empty()) {
        std::string error_msg;
        const CTxDestination source_dest = DecodeDestination(source_address, error_msg);
        const auto* witness = std::get_if<WitnessUnknown>(&source_dest);
        if (!IsValidDestination(source_dest) || !witness ||
            !IsQuantumMigrationWitnessProgram(witness->GetWitnessVersion(), witness->GetWitnessProgram())) {
            throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, error_msg.empty() ? "source_address is not a Blackcoin migration address" : error_msg);
        }
        if (!pwallet->GetQuantumKeyInfo(source_dest).has_value()) {
            throw JSONRPCError(RPC_WALLET_ERROR, "source_address is not wallet-backed");
        }
        source_script = GetScriptForDestination(source_dest);
    }

    CTxDestination dest;
    bool newly_generated{false};
    if (!destination_address.empty()) {
        std::string error_msg;
        dest = DecodeDestination(destination_address, error_msg);
        const auto* witness = std::get_if<WitnessUnknown>(&dest);
        if (!IsValidDestination(dest) || !witness ||
            !IsQuantumMigrationWitnessProgram(witness->GetWitnessVersion(), witness->GetWitnessProgram())) {
            throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, error_msg.empty() ? "destination_address is not a Blackcoin migration address" : error_msg);
        }
        if (!pwallet->GetQuantumKeyInfo(dest).has_value()) {
            throw JSONRPCError(RPC_WALLET_ERROR, "destination_address is not wallet-backed");
        }
    } else {
        auto op_dest = pwallet->GetNewQuantumDestination(label);
        if (!op_dest) throw JSONRPCError(RPC_WALLET_ERROR, util::ErrorString(op_dest).original);
        dest = *op_dest;
        newly_generated = true;
    }
    const std::optional<CTxDestination> created_destination = newly_generated
        ? std::optional<CTxDestination>{dest}
        : std::nullopt;
    if (!pwallet->GetQuantumKeyInfo(dest).has_value()) {
        ThrowQuantumActionError(
            RPC_WALLET_ERROR,
            "Demurrage sweep",
            "Refusing to sweep: destination ML-DSA key is not confirmed stored in the wallet",
            created_destination);
    }

    CCoinControl coin_control;
    coin_control.m_allow_other_inputs = false;
    coin_control.m_include_unsafe_inputs = include_unsafe;
    coin_control.destChange = dest;
    if (requested_fee_rate) {
        coin_control.m_feerate = *requested_fee_rate;
        coin_control.fOverrideFeeRate = true;
    }

    CoinFilterParams filter;
    filter.only_spendable = true;
    filter.skip_locked = true;
    filter.include_immature_coinbase = false;

    CoinsResult available = AvailableCoins(*pwallet, &coin_control, std::nullopt, filter);
    std::map<COutPoint, Coin> chain_coins;
    std::vector<COutput> candidates;
    for (const COutput& out : available.All()) {
        if (!IsQuantumMigrationScript(out.txout.scriptPubKey)) continue;
        if (source_script && out.txout.scriptPubKey != *source_script) continue;
        CTxDestination out_dest;
        if (!ExtractDestination(out.txout.scriptPubKey, out_dest) || !pwallet->GetQuantumKeyInfo(out_dest).has_value()) continue;
        chain_coins.emplace(out.outpoint, Coin{});
        candidates.push_back(out);
    }
    pwallet->chain().findCoins(chain_coins);

    CAmount nominal_amount{0};
    CAmount effective_amount{0};
    CAmount burned_amount{0};
    CAmount skipped_locked_amount{0};
    int selected_inputs{0};
    int skipped_locked_outputs{0};
    std::vector<COutPoint> selected_outpoints;
    const CCoinsViewCache& view = pwallet->chain().getCoinsTip();
    for (const COutput& out : candidates) {
        const auto coin_it = chain_coins.find(out.outpoint);
        if (coin_it == chain_coins.end() || coin_it->second.IsSpent()) continue;
        const std::optional<Consensus::DemurrageAttestationState> latest_attestation =
            Consensus::LatestDemurrageAttestationStateForScript(view, out.txout.scriptPubKey);
        const Consensus::DemurrageEvaluation eval = Consensus::EvaluateDemurrage(
            coin_it->second, consensus, evaluation_height, evaluation_time,
            latest_attestation ? std::optional<int>{latest_attestation->height} : std::nullopt,
            latest_attestation ? std::optional<int>{static_cast<int>(latest_attestation->coverage_start_height)} : std::nullopt);
        if (eval.locked) {
            ++skipped_locked_outputs;
            skipped_locked_amount += eval.nominal_value;
            continue;
        }
        if (eval.burned_value <= 0) continue;
        selected_outpoints.push_back(out.outpoint);
        nominal_amount += eval.nominal_value;
        effective_amount += eval.effective_value;
        burned_amount += eval.burned_value;
        ++selected_inputs;
    }
    if (selected_inputs == 0) {
        ThrowQuantumActionError(
            RPC_WALLET_INSUFFICIENT_FUNDS,
            "Demurrage sweep",
            "No spendable wallet-owned quantum outputs are currently decaying",
            created_destination);
    }
    if (effective_amount <= 0) {
        ThrowQuantumActionError(
            RPC_WALLET_INSUFFICIENT_FUNDS,
            "Demurrage sweep",
            "Selected decaying outputs have no spendable effective value",
            created_destination);
    }

    const int64_t current_time = GetAdjustedTimeSeconds();
    const CFeeRate fee_rate = GetMinimumFeeRate(*pwallet, coin_control, current_time);
    if (coin_control.m_feerate && fee_rate > *coin_control.m_feerate) {
        ThrowQuantumActionError(
            RPC_INVALID_PARAMETER,
            "Demurrage sweep",
            strprintf("Fee rate (%s) is lower than the minimum fee rate setting (%s)", coin_control.m_feerate->ToString(FeeEstimateMode::SAT_VB), fee_rate.ToString(FeeEstimateMode::SAT_VB)),
            created_destination);
    }

    CMutableTransaction sweep_tx;
    sweep_tx.nVersion = CTransaction::CURRENT_VERSION;
    sweep_tx.nTime = current_time;
    static constexpr uint32_t MAX_SEQUENCE_NONFINAL = 0xfffffffe;
    for (const COutPoint& outpoint : selected_outpoints) {
        sweep_tx.vin.emplace_back(outpoint, CScript(), MAX_SEQUENCE_NONFINAL);
    }
    sweep_tx.vout.emplace_back(effective_amount, GetScriptForDestination(dest));

    const TxSize tx_size = CalculateMaximumSignedTxSize(CTransaction(sweep_tx), pwallet.get(), &coin_control);
    if (tx_size.vsize <= 0) {
        ThrowQuantumActionError(
            RPC_WALLET_ERROR,
            "Demurrage sweep",
            "Unable to estimate demurrage sweep transaction size",
            created_destination);
    }
    const CAmount fee = std::max(GetMinFee(static_cast<size_t>(tx_size.vsize), static_cast<uint32_t>(current_time)), fee_rate.GetFee(static_cast<uint32_t>(tx_size.vsize)));
    if (fee > pwallet->m_default_max_tx_fee) {
        ThrowQuantumActionError(
            RPC_WALLET_ERROR,
            "Demurrage sweep",
            strprintf("Fee exceeds wallet max transaction fee (%s)", FormatMoney(pwallet->m_default_max_tx_fee)),
            created_destination);
    }
    const CAmount output_amount = effective_amount - fee;
    if (!MoneyRange(output_amount) || output_amount <= 0) {
        ThrowQuantumActionError(
            RPC_WALLET_INSUFFICIENT_FUNDS,
            "Demurrage sweep",
            "Selected decaying outputs cannot pay the sweep fee",
            created_destination);
    }
    sweep_tx.vout[0].nValue = output_amount;

    if (IsDust(sweep_tx.vout[0], pwallet->chain().relayDustFee())) {
        ThrowQuantumActionError(
            RPC_WALLET_INSUFFICIENT_FUNDS,
            "Demurrage sweep",
            "Demurrage sweep would strand the effective value below dust after fees",
            created_destination);
    }
    if (!dry_run) {
        std::map<int, bilingual_str> input_errors;
        if (!pwallet->SignTransaction(sweep_tx, input_errors)) {
            if (!input_errors.empty()) {
                ThrowQuantumActionError(
                    RPC_WALLET_ERROR,
                    "Demurrage sweep",
                    strprintf("Signing demurrage sweep failed: %s", input_errors.begin()->second.original),
                    created_destination);
            }
            ThrowQuantumActionError(
                RPC_WALLET_ERROR,
                "Demurrage sweep",
                "Signing demurrage sweep failed",
                created_destination);
        }
    }
    CTransactionRef tx = MakeTransactionRef(std::move(sweep_tx));
    const int result_vsize = dry_run ? static_cast<int>(tx_size.vsize) : static_cast<int>(GetVirtualTransactionSize(*tx, 0, 0));

    UniValue obj(UniValue::VOBJ);
    obj.pushKV("dry_run", dry_run);
    obj.pushKV("evaluation_height", evaluation_height);
    obj.pushKV("evaluation_time", evaluation_time);
    obj.pushKV("selected_inputs", selected_inputs);
    obj.pushKV("skipped_locked_outputs", skipped_locked_outputs);
    obj.pushKV("nominal_amount", ValueFromAmount(nominal_amount));
    obj.pushKV("effective_amount", ValueFromAmount(effective_amount));
    obj.pushKV("burned_amount", ValueFromAmount(burned_amount));
    obj.pushKV("skipped_locked_amount", ValueFromAmount(skipped_locked_amount));
    obj.pushKV("destination", EncodeDestination(dest));
    obj.pushKV("newly_generated", newly_generated);
    obj.pushKV("amount", ValueFromAmount(tx->vout[0].nValue));
    obj.pushKV("fee", ValueFromAmount(fee));
    obj.pushKV("vsize", result_vsize);
    obj.pushKV("hex", EncodeHexTx(*tx));
    if (!dry_run) {
        mapValue_t map_value;
        map_value["comment"] = "Blackcoin demurrage sweep";
        CommitWalletTransactionOrThrow(*pwallet, tx, std::move(map_value), "Demurrage sweep", created_destination);
        obj.pushKV("txid", tx->GetHash().GetHex());
    }
    if (newly_generated) {
        obj.pushKV("warning", "A new ML-DSA quantum address was created. Back up the wallet before relying on the swept funds.");
    }
    return obj;
},
    };
}

Span<const CRPCCommand> GetStakingRPCCommands()
{
// clang-format off
static const CRPCCommand commands[] =
{ //  category              actor (function)
  //  ------------------    ------------------------
    { "staking",            &getstakinginfo,                 },
    { "staking",            &getstakingdonationinfo,         },
    { "staking",            &setstakingdonation,             },
    { "staking",            &getqqdevelopmentdonationinfo,   },
    { "staking",            &setqqdevelopmentdonation,       },
    { "staking",            &getgoldrushinfo,                },
    { "staking",            &reservebalance,                 },
    { "staking",            &sendshadowsignal,               },
    { "staking",            &sendshadowpowclaim,             },
    { "staking",            &createshadowpowclaimresolution, },
    { "staking",            &commitshadowpowclaimresolution, },
    { "staking",            &revokeshadowpowclaimresolution, },
    { "staking",            &resolveallshadowpowclaims,       },
    { "staking",            &adoptshadowpowclaimcomponent,    },
    { "staking",            &getpowclaimrecoveryinfo,        },
    { "staking",            &setpowclaimrecovery,            },
    { "staking",            &setpowmining,                   },
    { "staking",            &getpowmininginfo,               },
    { "staking",            &getquantumstakeaddressinfo,     },
    { "staking",            &listquantumstakeoutputs,        },
    { "staking",            &fundquantumstakeaddress,        },
    { "staking",            &withdrawquantumstakeaddress,    },
    { "staking",            &getquantumoperatorbondinfo,     },
    { "staking",            &getwalletquantumpoolinfo,       },
    { "staking",            &fundquantumoperatorbond,        },
    { "staking",            &withdrawquantumoperatorbond,    },
    { "staking",            &getquantumcoldstakebalance,     },
    { "staking",            &fundquantumcoldstakeaddress,    },
    { "staking",            &withdrawquantumcoldstakeaddress,},
    { "staking",            &getquantumredelegationinfo,     },
    { "staking",            &redelegatequantumcoldstake,     },
    { "staking",            &senddemurrageattestation,       },
    { "staking",            &getdemurragewalletinfo,         },
    { "staking",            &sweepdemurragedecay,            },
    { "staking",            &staking,                        },
    { "staking",            &checkkernel,                    },
};
// clang-format on
    return commands;
}

} // namespace wallet
