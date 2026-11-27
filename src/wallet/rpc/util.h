// Copyright (c) 2017-2022 The Bitcoin Core developers
// Copyright (c) 2017-2022 Blackcoin Core Developers
// Copyright (c) 2017-2022 Blackcoin More Developers
// Copyright (c) 2017-2022 Quantum Quasar Developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_RPC_UTIL_H
#define BITCOIN_WALLET_RPC_UTIL_H

#include <rpc/util.h>
#include <script/script.h>
#include <wallet/wallet.h>

#include <any>
#include <memory>
#include <string>
#include <vector>

class JSONRPCRequest;
class UniValue;
struct bilingual_str;

namespace wallet {
class LegacyScriptPubKeyMan;
enum class DatabaseStatus;
struct PolledBalance;
struct WalletContext;

extern const std::string HELP_REQUIRING_PASSPHRASE;

static const RPCResult RESULT_LAST_PROCESSED_BLOCK { RPCResult::Type::OBJ, "lastprocessedblock", "hash and height of the block this information was generated on",{
    {RPCResult::Type::STR_HEX, "hash", "hash of the block this information was generated on"},
    {RPCResult::Type::NUM, "height", "height of the block this information was generated on"}}
};

//! The `exact` argument of the RPCs that report the wallet balance.
extern const std::string HELP_BALANCE_EXACT_ARG;
//! What those RPCs say about the balance they report.
static const RPCResult RESULT_BALANCE_EXACT{RPCResult::Type::BOOL, "balance_exact", "true when the balances are those of the wallet as it is now; false when they are the last calculated balances and the wallet or the chain has moved on since (a new calculation is under way)"};
static const RPCResult RESULT_BALANCE_HEIGHT{RPCResult::Type::NUM, "balance_height", "height of the block the balances were calculated for, -1 when no balance has been calculated yet"};
static const RPCResult RESULT_BALANCE_BLOCKHASH{RPCResult::Type::STR_HEX, "balance_blockhash", /*optional=*/true, "hash of the block the balances were calculated for (absent when no balance has been calculated yet)"};
static const RPCResult RESULT_BALANCE_STATE{RPCResult::Type::STR, "balance_state", "\"exact\", \"current-unverified\" (calculated for the wallet's last processed block, the wallet changed since), \"behind(N)\" (calculated N blocks before the wallet's last processed block), \"none\" (nothing calculated yet: the balances are reported as 0) or \"failed\""};

/**
 * Figures out what wallet, if any, to use for a JSONRPCRequest.
 *
 * @param[in] request JSONRPCRequest that wishes to access a wallet
 * @return nullptr if no wallet should be used, or a pointer to the CWallet
 */
std::shared_ptr<CWallet> GetWalletForJSONRPCRequest(const JSONRPCRequest& request);
bool GetWalletNameFromJSONRPCRequest(const JSONRPCRequest& request, std::string& wallet_name);

void EnsureWalletIsUnlocked(const CWallet&);
WalletContext& EnsureWalletContext(const std::any& context);
LegacyScriptPubKeyMan& EnsureLegacyScriptPubKeyMan(CWallet& wallet, bool also_create = false);
const LegacyScriptPubKeyMan& EnsureConstLegacyScriptPubKeyMan(const CWallet& wallet);

bool GetAvoidReuseFlag(const CWallet& wallet, const UniValue& param);
bool ParseIncludeWatchonly(const UniValue& include_watchonly, const CWallet& wallet);
std::string LabelFromValue(const UniValue& value);
//! Fetch parent descriptors of this scriptPubKey.
void PushParentDescriptors(const CWallet& wallet, const CScript& script_pubkey, UniValue& entry);

void HandleWalletError(const std::shared_ptr<CWallet> wallet, DatabaseStatus& status, bilingual_str& error);
int64_t ParseISO8601DateTime(const std::string& str);
void AppendLastProcessedBlock(UniValue& entry, const CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);
//! The funds a closed Gold Rush claim keeps reserved, what holds them and the
//! command that releases them.
UniValue ClosedClaimReservationToJSON(const ShadowPowClosedClaimReservation& reservation);
std::vector<RPCResult> ClosedClaimReservationResults();
//! Adds "closed_claim_reserved" only while an amount is held, so wallets that
//! never had a claim see no change in these results.
void AppendClosedClaimReservation(UniValue& entry, const CWallet& wallet) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);
//! Whether a balance RPC waits for an exact balance: the caller's `exact`
//! argument, or -walletrpcexactbalance when it is not given.
bool WantExactBalance(const UniValue& param);
//! balance_exact, balance_height, balance_blockhash and balance_state.
void AppendPolledBalanceState(UniValue& entry, const CWallet& wallet, const PolledBalance& polled) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet);
} //  namespace wallet

#endif // BITCOIN_WALLET_RPC_UTIL_H
