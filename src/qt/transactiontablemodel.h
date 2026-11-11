// Copyright (c) 2011-2020 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_TRANSACTIONTABLEMODEL_H
#define BITCOIN_QT_TRANSACTIONTABLEMODEL_H

#include <qt/bitcoinunits.h>
#include <qt/transactionrow.h>
#include <uint256.h>

#include <QAbstractTableModel>
#include <QStringList>

#include <deque>
#include <memory>

namespace interfaces {
class Handler;
}

class PlatformStyle;
class TransactionRecord;
class TransactionTablePriv;
class WalletModel;

/** UI model for the transaction table of a wallet.
 */
class TransactionTableModel : public QAbstractTableModel, public TransactionRowSource
{
    Q_OBJECT

public:
    explicit TransactionTableModel(const PlatformStyle* platformStyle, WalletModel* parent, bool defer_history);
    ~TransactionTableModel();

    enum ColumnIndex {
        Status = 0,
        Watchonly = 1,
        Date = 2,
        Type = 3,
        ToAddress = 4,
        Amount = 5
    };

    /** Roles to get specific information from a transaction row.
        These are independent of column.
    */
    enum RoleIndex {
        /** Type of transaction */
        TypeRole = Qt::UserRole,
        /** Date and time this transaction was created */
        DateRole,
        /** Watch-only boolean */
        WatchonlyRole,
        /** Watch-only icon */
        WatchonlyDecorationRole,
        /** Long description (HTML format) */
        LongDescriptionRole,
        /** Address of transaction */
        AddressRole,
        /** Label of address related to transaction */
        LabelRole,
        /** Net amount of transaction */
        AmountRole,
        /** Transaction hash */
        TxHashRole,
        /** Transaction data, hex-encoded */
        TxHexRole,
        /** Whole transaction as plain text */
        TxPlainTextRole,
        /** Is transaction confirmed? */
        ConfirmedRole,
        /** Formatted amount, without brackets when unconfirmed */
        FormattedAmountRole,
        /** Transaction status (TransactionRecord::Status) */
        StatusRole,
        /** Unprocessed icon */
        RawDecorationRole,
        /** Current wallet label for explicit copy/export operations. */
        ExportLabelRole,
    };

    int rowCount(const QModelIndex &parent) const override;
    int columnCount(const QModelIndex &parent) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role) const override;
    QModelIndex index(int row, int column, const QModelIndex & parent = QModelIndex()) const override;
    bool processingQueuedTransactions() const { return fProcessingQueuedTransactions; }
    void invalidateAddressLabel(const QString& address);
    bool isHistoryLoaded() const { return m_history_loaded; }
    bool historyLoadHasFailed() const { return m_history_load_failed; }
    void setInitialHistory(std::deque<TransactionRecord> history);
    void reportHistoryLoadFailure();
    QModelIndexList indexesForTransaction(const uint256& hash) const;
    TransactionRowIdentity transactionIdentity(int row) const override;
    int transactionRow(const TransactionRowIdentity& identity) const override;


private:
    WalletModel *walletModel;
    std::unique_ptr<interfaces::Handler> m_handler_transaction_changed;
    std::unique_ptr<interfaces::Handler> m_handler_show_progress;
    QStringList columns;
    std::shared_ptr<TransactionTablePriv> priv;
    bool fProcessingQueuedTransactions{false};
    bool m_history_loaded{false};
    bool m_history_load_failed{false};
    const PlatformStyle *platformStyle;

    void subscribeToCoreSignals();
    void unsubscribeFromCoreSignals();

    QString lookupAddress(const TransactionRecord& record, bool tooltip) const;
    QVariant addressColor(const TransactionRecord *wtx) const;
    QString formatTxStatus(const TransactionRecord *wtx) const;
    QString formatTxDate(const TransactionRecord *wtx) const;
    QString formatTxType(const TransactionRecord *wtx) const;
    QString formatGoldRushClaimType(const TransactionRecord *wtx, const QString& claim_type) const;
    QString formatGoldRushToAddress(const TransactionRecord *wtx, bool tooltip) const;
    QString formatTxToAddress(const TransactionRecord *wtx, bool tooltip) const;
    QString formatTxAmount(const TransactionRecord *wtx, bool showUnconfirmed=true, BitcoinUnits::SeparatorStyle separators=BitcoinUnits::SeparatorStyle::STANDARD) const;
    QString formatTooltip(const TransactionRecord *rec) const;
    QVariant txStatusDecoration(const TransactionRecord *wtx) const;
    QVariant txWatchonlyDecoration(const TransactionRecord *wtx) const;
    QVariant txAddressDecoration(const TransactionRecord *wtx) const;

Q_SIGNALS:
    void historyLoaded();
    void historyLoadFailed();

public Q_SLOTS:
    void updateConfirmations();
    void updateDisplayUnit();
    /** Updates the column title to "Amount (DisplayUnit)" and emits headerDataChanged() signal for table headers to react. */
    void updateAmountColumnTitle();

    friend class TransactionTablePriv;
};

#endif // BITCOIN_QT_TRANSACTIONTABLEMODEL_H
