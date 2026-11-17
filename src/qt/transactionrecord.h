// Copyright (c) 2011-2022 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_TRANSACTIONRECORD_H
#define BITCOIN_QT_TRANSACTIONRECORD_H

#include <consensus/amount.h>
#include <uint256.h>

#include <QList>
#include <QString>

#include <cstdint>
#include <memory>
#include <string>

namespace interfaces {
class Node;
class Wallet;
struct WalletTx;
struct WalletTxStatus;
}

/** The status-dependent sort key of a row, stored as its five fields instead of as the 29 character text
 *  "%010d-%01d-%010u-%03d-%d" (block height, generated flag, time received, output index, type order). A row holds
 *  this for its whole life, so the text (a heap string per row) is built only when something asks for it. An empty
 *  key means the row has never been read from the wallet. */
class TransactionSortKey
{
public:
    TransactionSortKey() = default;
    TransactionSortKey(int block_height, bool generated, unsigned time_received, int idx, int type_order) :
        m_height(block_height), m_received(time_received), m_idx(idx), m_generated(generated), m_type_order(static_cast<int8_t>(type_order)), m_set(true) {}
    //! Accepts the formatted text (the tests assign it); anything else leaves the key empty.
    TransactionSortKey& operator=(const std::string& text);
    bool empty() const { return !m_set; }
    void clear() { *this = TransactionSortKey{}; }
    int blockHeight() const { return m_height; }
    //! The text the key stands for, identical to the former per-row string.
    std::string str() const;
    operator std::string() const { return str(); }
    bool operator==(const TransactionSortKey& other) const
    {
        return m_set == other.m_set && m_height == other.m_height && m_received == other.m_received && m_idx == other.m_idx &&
               m_generated == other.m_generated && m_type_order == other.m_type_order;
    }
    bool operator!=(const TransactionSortKey& other) const { return !(*this == other); }

private:
    int32_t m_height{0};
    uint32_t m_received{0};
    int32_t m_idx{0};
    bool m_generated{false};
    int8_t m_type_order{0};
    bool m_set{false};
};

/** A row's address text. Claim and payout rows of one wallet repeat a handful of addresses over hundreds of
 *  thousands of rows, so equal texts share one allocation (a pool that forgets an address once no row uses it). */
class TransactionAddress
{
public:
    TransactionAddress() = default;
    TransactionAddress(const std::string& text) { assign(text); }
    TransactionAddress(const char* text) { assign(std::string(text)); }
    TransactionAddress& operator=(const std::string& text) { assign(text); return *this; }
    const std::string& str() const;
    operator const std::string&() const { return str(); }
    bool empty() const { return !m_text || m_text->empty(); }
    size_t size() const { return str().size(); }
    bool operator==(const TransactionAddress& other) const { return m_text == other.m_text || str() == other.str(); }
    bool operator!=(const TransactionAddress& other) const { return !(*this == other); }
    bool operator==(const std::string& other) const { return str() == other; }
    bool operator!=(const std::string& other) const { return str() != other; }
    //! Tests: number of distinct address texts currently shared by rows.
    static size_t PoolSize();

private:
    void assign(const std::string& text);
    std::shared_ptr<const std::string> m_text;
};
inline bool operator==(const std::string& a, const TransactionAddress& b) { return b == a; }
inline bool operator!=(const std::string& a, const TransactionAddress& b) { return b != a; }
inline bool operator==(const std::string& a, const TransactionSortKey& b) { return b.str() == a; }
inline bool operator!=(const std::string& a, const TransactionSortKey& b) { return b.str() != a; }
inline bool operator==(const TransactionSortKey& a, const std::string& b) { return a.str() == b; }
inline bool operator!=(const TransactionSortKey& a, const std::string& b) { return a.str() != b; }

/** UI model for transaction status. The transaction status is the part of a transaction that will change over time.
 */
struct TransactionStatus {
    enum Status {
        Confirmed,          /**< Have 6 or more confirmations (normal tx) or fully mature (mined tx) **/
        /// Normal (sent/received) transactions
        Unconfirmed,        /**< Not yet mined into a block **/
        Confirming,         /**< Confirmed, but waiting for the recommended number of confirmations **/
        Conflicted,         /**< Conflicts with other transaction or mempool **/
        Abandoned,          /**< Abandoned from the wallet **/
        /// Generated (mined) transactions
        Immature,           /**< Mined but waiting for maturity */
        NotAccepted         /**< Mined but not accepted */
    };

    /// Transaction counts towards available balance
    bool countsForBalance{false};
    /// Set when the wallet says this row changed; the next status read replaces it
    bool needsUpdate{false};

    /** @name Reported status
       @{*/
    Status status{Unconfirmed};
    int depth{0};
    /**@}*/

    /** @name Generated (mined) transactions
       @{*/
    int matures_in{0};
    /**@}*/

    /// Sorting key based on status
    TransactionSortKey sortKey;

    /** Fingerprint of the chain tip this status was read at (to know whether the cached status is still valid).
     *  The first eight bytes of the block hash: a false match only delays one refresh to the next block. */
    uint64_t m_cur_tip{0};
};

/** UI model for a transaction. A core transaction can be represented by multiple UI transactions if it has
    multiple outputs.
 */
class TransactionRecord
{
public:
    enum Type
    {
        Other,
        Generated,
        SendToAddress,
        SendToOther,
        RecvWithAddress,
        RecvFromOther,
        Staked,
        GoldRushPosStake,
        GoldRushPowClaim
    };

    /** Number of confirmation recommended for accepting a transaction */
    static const int RecommendedNumConfirmations = 10;

    TransactionRecord():
            hash(), time(0), type(Other), debit(0), credit(0), idx(0)
    {
    }

    TransactionRecord(uint256 _hash, qint64 _time):
            hash(_hash), time(_time), type(Other), debit(0),
            credit(0), idx(0)
    {
    }

    TransactionRecord(uint256 _hash, qint64 _time,
                Type _type, const std::string &_address,
                const CAmount& _debit, const CAmount& _credit):
            hash(_hash), time(_time), type(_type), address(_address), debit(_debit), credit(_credit),
            idx(0)
    {
    }

    /** Decompose CWallet transaction to model transaction records.
     */
    static bool showTransaction(const interfaces::WalletTx& wtx);
    static QList<TransactionRecord> decomposeTransaction(const interfaces::WalletTx& wtx);

    /** @name Immutable transaction attributes
      @{*/
    uint256 hash;
    qint64 time;
    Type type;
    TransactionAddress address;
    CAmount debit;
    CAmount credit;
    /**@}*/

    /** Subtransaction index, for sort key */
    int idx;

    /** Assigned on GUI publication; zero while in an unpublished worker snapshot. */
    uint64_t presentation_id{0};

    /** Status: can change with block chain update */
    TransactionStatus status;

    /** Whether the transaction was sent/received with a watch-only address */
    bool involvesWatchAddress{false};

    /** Return the unique identifier for this transaction (part) */
    QString getTxHash() const;

    /** Return the output index of the subtransaction  */
    int getOutputIndex() const;

    /** Update status from core wallet tx.
     */
    void updateStatus(const interfaces::WalletTxStatus& wtx, const uint256& block_hash, int numBlocks, int64_t block_time);

    /** Return whether a status update is needed.
     */
    bool statusUpdateNeeded(const uint256& block_hash) const;
};

#endif // BITCOIN_QT_TRANSACTIONRECORD_H
