// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_WALLET_FINAL_STAKE_RESERVE_H
#define BITCOIN_WALLET_FINAL_STAKE_RESERVE_H

#include <primitives/transaction.h>
#include <sync.h>
#include <wallet/wallet.h>

#include <set>

namespace wallet {

/** The outputs automatic spending must not select: the final stake reserve while the guard is active, otherwise
 *  empty. Always computed fresh (a spend never reads a cached reserve). Cheap when the guard is off. ignore_lock_of,
 *  when given, names outputs whose coin lock does not take them out of the scan (see
 *  CoinFilterParams::staking_scan_ignores_lock_of). This declaration sits in a header of its own so that the
 *  spending code can ask the question without including the whole of wallet/staking.h, which includes wallet/spend.h
 *  (the definition is in wallet/staking.cpp). */
std::set<COutPoint> FinalStakeReserveEnforcedOutpoints(const CWallet& wallet, const std::set<COutPoint>* ignore_lock_of = nullptr)
    EXCLUSIVE_LOCKS_REQUIRED(::cs_main, wallet.cs_wallet);

} // namespace wallet

#endif // BITCOIN_WALLET_FINAL_STAKE_RESERVE_H
