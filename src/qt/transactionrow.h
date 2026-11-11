// Copyright (c) 2026 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.
#ifndef BITCOIN_QT_TRANSACTIONROW_H
#define BITCOIN_QT_TRANSACTIONROW_H
#include <uint256.h>
#include <QString>
#include <QVariant>
#include <cstdint>
#include <string>

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

/** What the history projection needs from one source row, read without
 * constructing QVariants or touching the wallet. Sort keys are typed so the
 * projection can order rows with integer and string compares. */
struct TransactionScanRow {
    enum class Key { NUMBER, TEXT, DATE };
    //! In: bring the cached status up to date first (needs the wallet lock; the scan only asks for it when the
    //! filter depends on the status of rows that could appear).
    bool refresh_status{false};
    TransactionRowIdentity identity;
    int status{0};
    int type{0};
    bool watchonly{false};
    qint64 time{0};
    qint64 amount{0};        //!< signed net amount, as AmountRole
    Key key{Key::NUMBER};
    qint64 number{0};        //!< NUMBER: the key; DATE: seconds, ordered before `text`
    QString text;            //!< TEXT: the key; DATE: status tie-break (ASCII)
};

/** Flat transaction sources expose identity without status/label RPC work.
 * Lookup must be bounded by ordered lookup, never a linear scan or edit replay.
 * The optional fast entry points default to "unsupported"; a source that
 * implements them must return exactly what data() would for the same row. */
class TransactionRowSource {
public:
    virtual ~TransactionRowSource() = default;
    virtual TransactionRowIdentity transactionIdentity(int row) const = 0;
    virtual int transactionRow(const TransactionRowIdentity& identity) const = 0;
    /** Fill `out` for `row` with the sort key of `column`. False if unsupported. */
    virtual bool transactionScanRow(int row, int column, TransactionScanRow& out) const { Q_UNUSED(row) Q_UNUSED(column) Q_UNUSED(out) return false; }
    /** The case-insensitive search the filter applies to address, hash and label. */
    virtual bool transactionMatchesText(int row, const QString& needle, bool& supported) const { Q_UNUSED(row) Q_UNUSED(needle) supported = false; return false; }
    /** Display data by identity without resolving a source row. False if unsupported or the row is gone. */
    virtual bool transactionData(const TransactionRowIdentity& identity, int column, int role, QVariant& out) const { Q_UNUSED(identity) Q_UNUSED(column) Q_UNUSED(role) Q_UNUSED(out) return false; }
};
#endif // BITCOIN_QT_TRANSACTIONROW_H
