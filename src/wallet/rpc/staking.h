// Copyright (c) 2014-2023 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_RPC_STAKING_H
#define BITCOIN_WALLET_RPC_STAKING_H

#include <span.h>

#include <consensus/params.h>

class CRPCCommand;
class UniValue;

namespace wallet {
class CWallet;
Span<const CRPCCommand> GetStakingRPCCommands();
/** Adds the quantum return fields of legacy staking (all optional additions) to
 *  a getstakinginfo or getmigrationstatus object; nothing when no height
 *  schedule exists. */
void AddLegacyStakeReturnStatus(UniValue& obj, const CWallet& wallet, const Consensus::Params& consensus, int64_t next_height);
} // namespace wallet

#endif // BITCOIN_WALLET_RPC_STAKING_H
