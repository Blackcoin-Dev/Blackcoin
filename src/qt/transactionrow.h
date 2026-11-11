// Copyright (c) 2026 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.
#ifndef BITCOIN_QT_TRANSACTIONROW_H
#define BITCOIN_QT_TRANSACTIONROW_H
#include <uint256.h>
#include <cstdint>

/** An identity belongs to one live GUI source model, never to serialized data.
 * The ID is nonzero and never reused by that model, including after removal.
 * Hash plus output index is insufficient: a wallet-owned send can produce a
 * debit and a credit row for the same transaction output.
 */
struct TransactionRowIdentity {
    uint256 hash;
    uint64_t id{0};
    bool operator==(const TransactionRowIdentity& other) const { return id == other.id && hash == other.hash; }
};

/** Flat transaction sources expose identity without status/label RPC work.
 * Lookup must be bounded by ordered lookup, never a linear scan or edit replay.
 */
class TransactionRowSource {
public:
    virtual ~TransactionRowSource() = default;
    virtual TransactionRowIdentity transactionIdentity(int row) const = 0;
    virtual int transactionRow(const TransactionRowIdentity& identity) const = 0;
};
#endif
