// Copyright (c) 2011-2022 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/transactiontablemodel.h>

#include <unordered_map>

#include <qt/addresstablemodel.h>
#include <qt/bitcoinunits.h>
#include <qt/clientmodel.h>
#include <qt/guiconstants.h>
#include <qt/guiutil.h>
#include <qt/optionsmodel.h>
#include <qt/platformstyle.h>
#include <qt/transactiondesc.h>
#include <qt/transactionrecord.h>
#include <qt/walletmodel.h>

#include <core_io.h>
#include <interfaces/handler.h>
#include <key_io.h>
#include <sync.h>
#include <tinyformat.h>
#include <uint256.h>
#include <util/strencodings.h>

#include <algorithm>
#include <cctype>
#include <deque>
#include <iterator>
#include <map>
#include <optional>
#include <set>

#include <stdexcept>
#include <QElapsedTimer>
#include <QColor>
#include <QDateTime>
#include <QDebug>
#include <QIcon>
#include <QLatin1Char>
#include <QLatin1String>
#include <QList>
#include <QPointer>
#include <QTimer>


// Amount column is right-aligned it contains numbers
static int column_alignments[] = {
        Qt::AlignLeft|Qt::AlignVCenter, /*status=*/
        Qt::AlignLeft|Qt::AlignVCenter, /*watchonly=*/
        Qt::AlignLeft|Qt::AlignVCenter, /*date=*/
        Qt::AlignLeft|Qt::AlignVCenter, /*type=*/
        Qt::AlignLeft|Qt::AlignVCenter, /*address=*/
        Qt::AlignRight|Qt::AlignVCenter /* amount */
    };

// Comparison operator for sort/binary search of model tx list
struct TxLessThan
{
    bool operator()(const TransactionRecord &a, const TransactionRecord &b) const
    {
        return a.hash < b.hash;
    }
    bool operator()(const TransactionRecord &a, const uint256 &b) const
    {
        return a.hash < b;
    }
    bool operator()(const uint256 &a, const TransactionRecord &b) const
    {
        return a < b.hash;
    }
};

// queue notifications to show a non freezing progress dialog e.g. for rescan
struct TransactionNotification
{
    uint256 hash;
    ChangeType status;
    bool suppress_incoming{false};
    bool initial_history_boundary{false};
};

// Private implementation
class TransactionTablePriv : public std::enable_shared_from_this<TransactionTablePriv>
{
public:
    explicit TransactionTablePriv(TransactionTableModel *_parent) :
        parent(_parent)
    {
    }

    TransactionTableModel *parent;

    //! Local cache of wallet sorted by transaction hash
    QList<TransactionRecord> cachedWallet;
    //! Identity -> record. Qt 5's QList stores a large or non-movable element out of line, so the pointers stay valid
    //! while other rows come and go; only erasing a record invalidates its own entry. A QList that stores elements
    //! inline (Qt 6) would leave these pointers dangling on any insert or erase, so refuse to build then.
    static_assert(QT_VERSION < QT_VERSION_CHECK(6, 0, 0), "m_by_id relies on Qt 5 QList node storage");
    static_assert(QTypeInfo<TransactionRecord>::isLarge ? true : QTypeInfo<TransactionRecord>::isStatic != 0,
                  "m_by_id relies on QList storing TransactionRecord out of line");
    std::unordered_map<uint64_t, TransactionRecord*> m_by_id;
    void Register(TransactionRecord& record) { m_by_id[record.presentation_id] = &record; }
    TransactionRecord* FindById(uint64_t id) const { const auto found = m_by_id.find(id); return found == m_by_id.end() ? nullptr : found->second; }
    uint64_t m_next_row_id{1};
    void AssignIdentity(TransactionRecord& row)
    {
        // Unsigned wrap latches zero. No subsequent row can reuse an ID.
        if (m_next_row_id == 0) throw std::overflow_error("GUI transaction row identity exhausted");
        row.presentation_id = m_next_row_id++;
    }
    std::deque<TransactionRecord> m_initial_history;
    void PublishInitialHistory();
    void FinishInitialHistory(bool deferred);

    // Wallet changes and scan progress can arrive on different core threads.
    // Never hold this queue lock while reading wallet state or emitting model signals.
    Mutex m_notification_mutex;
    bool m_loaded GUARDED_BY(m_notification_mutex){false};
    bool m_scanning GUARDED_BY(m_notification_mutex){false};
    bool m_initial_boundary_pending GUARDED_BY(m_notification_mutex){false};
    bool m_notifications_stopped GUARDED_BY(m_notification_mutex){false};
    bool m_drain_scheduled GUARDED_BY(m_notification_mutex){false};
    std::vector<TransactionNotification> m_scanned_notifications GUARDED_BY(m_notification_mutex);
    std::deque<TransactionNotification> m_pending_updates GUARDED_BY(m_notification_mutex);

    void NotifyTransactionChanged(const uint256& hash, ChangeType status);
    void NotifyScanProgress(int progress);
    void StopNotifications();
    void DispatchScannedNotifications() EXCLUSIVE_LOCKS_REQUIRED(m_notification_mutex);
    void SchedulePendingUpdates() EXCLUSIVE_LOCKS_REQUIRED(m_notification_mutex);
    void PostDrain();
    void DrainPendingUpdates();

    //! Decoding an address (base58 or bech32 checksum) dominates a label lookup; decoding is a pure function of
    //! the string, so remembering it needs no invalidation. Bounded so a huge history cannot grow it without limit.
    std::unordered_map<std::string, CTxDestination> m_decoded;
    const CTxDestination& Destination(const std::string& address)
    {
        const auto found = m_decoded.find(address);
        if (found != m_decoded.end()) return found->second;
        if (m_decoded.size() >= 500000) m_decoded.clear();
        return m_decoded.emplace(address, DecodeDestination(address)).first->second;
    }
    QString LabelForAddress(const TransactionRecord& record);
    void ForgetLabelRow(const TransactionRecord& record);
    void NotifyChangedLabelRows();
    void DrainChangedLabelRows();
    std::optional<CTxDestination> m_notifying_label;
    std::optional<uint256> m_notified_label_hash;
    bool m_label_notify_scheduled{false};
    void InvalidateAddressLabel(const QString& address);
    void ScheduleLabelRefresh();
    void RefreshLabels();

    // Display labels belong to the transaction table, independent of which
    // address types the address-book view is showing.
    struct DisplayLabel {
        std::optional<QString> value;
        std::set<uint256> transactions;
    };
    std::map<CTxDestination, DisplayLabel> m_labels;
    std::set<CTxDestination> m_pending_labels;
    bool m_label_refresh_scheduled{false};
    std::set<CTxDestination> m_changed_labels;

    //! Insert one transaction's records at a hash-ordered position with fresh identities.
    void InsertGroup(int lowerIndex, QList<TransactionRecord> toInsert)
    {
        if (toInsert.isEmpty()) return; /* only if something to insert */
        for (auto& record : toInsert) AssignIdentity(record);
        parent->beginInsertRows(QModelIndex(), lowerIndex, lowerIndex+toInsert.size()-1);
        int insert_idx = lowerIndex;
        for (const TransactionRecord &rec : toInsert)
        {
            cachedWallet.insert(insert_idx, rec);
            Register(cachedWallet[insert_idx]);
            insert_idx += 1;
        }
        parent->endInsertRows();
    }

    /* Update our model of the wallet incrementally, to synchronize our model of the wallet
       with that of the core.

       Call with transaction that was added, removed or changed.
     */
    void updateWallet(const uint256& hash, ChangeType status, const interfaces::WalletTx& wtx)
    {
        const bool showTransaction = TransactionRecord::showTransaction(wtx);

        qDebug() << "TransactionTablePriv::updateWallet: " + QString::fromStdString(hash.ToString()) + " " + QString::number(status);

        // Find bounds of this transaction in model
        QList<TransactionRecord>::iterator lower = std::lower_bound(
            cachedWallet.begin(), cachedWallet.end(), hash, TxLessThan());
        QList<TransactionRecord>::iterator upper = std::upper_bound(
            cachedWallet.begin(), cachedWallet.end(), hash, TxLessThan());
        int lowerIndex = (lower - cachedWallet.begin());
        int upperIndex = (upper - cachedWallet.begin());
        bool inModel = (lower != upper);

        if(status == CT_UPDATED)
        {
            if(showTransaction && !inModel)
                status = CT_NEW; /* Not in model, but want to show, treat as new */
            if(!showTransaction && inModel)
                status = CT_DELETED; /* In model, but want to hide, treat as deleted */
        }

        qDebug() << "    inModel=" + QString::number(inModel) +
                    " Index=" + QString::number(lowerIndex) + "-" + QString::number(upperIndex) +
                    " showTransaction=" + QString::number(showTransaction) + " derivedStatus=" + QString::number(status);

        switch(status)
        {
        case CT_NEW:
            if(inModel)
            {
                qWarning() << "TransactionTablePriv::updateWallet: Warning: Got CT_NEW, but transaction is already in model";
                break;
            }
            if(showTransaction && wtx.tx)
            {
                // Added -- insert at the right position
                InsertGroup(lowerIndex, TransactionRecord::decomposeTransaction(wtx));
            }
            break;
        case CT_DELETED:
            if(!inModel)
            {
                qWarning() << "TransactionTablePriv::updateWallet: Warning: Got CT_DELETED, but transaction is not in model";
                break;
            }
            // Removed -- remove entire transaction from table
            parent->beginRemoveRows(QModelIndex(), lowerIndex, upperIndex-1);
            for (auto entry = lower; entry != upper; ++entry) {
                ForgetLabelRow(*entry);
                m_by_id.erase(entry->presentation_id);
            }
            cachedWallet.erase(lower, upper);
            parent->endRemoveRows();
            break;
        case CT_UPDATED:
            // Miscellaneous updates -- nothing to do, status update will take care of this, and is only computed for
            // visible transactions.
            for (int i = lowerIndex; i < upperIndex; i++) {
                TransactionRecord *rec = &cachedWallet[i];
                rec->status.needsUpdate = true;
            }
            break;
        }
    }

    int size()
    {
        return cachedWallet.size();
    }

    //! If a status update is needed (blocks came in since last check), try to update the status of this
    //! transaction from the wallet. Otherwise, simply re-use the cached status.
    static void RefreshStatus(interfaces::Wallet& wallet, const uint256& cur_block_hash, TransactionRecord* rec)
    {
        interfaces::WalletTxStatus wtx;
        int numBlocks;
        int64_t block_time;
        if (!cur_block_hash.IsNull() && rec->statusUpdateNeeded(cur_block_hash) && wallet.tryGetTxStatus(rec->hash, wtx, numBlocks, block_time)) {
            rec->updateStatus(wtx, cur_block_hash, numBlocks, block_time);
        }
    }

    TransactionRecord* index(interfaces::Wallet& wallet, const uint256& cur_block_hash, const int idx)
    {
        if (idx >= 0 && idx < cachedWallet.size()) {
            TransactionRecord *rec = &cachedWallet[idx];
            RefreshStatus(wallet, cur_block_hash, rec);
            return rec;
        }
        return nullptr;
    }

    QString describe(interfaces::Node& node, interfaces::Wallet& wallet, TransactionRecord* rec, BitcoinUnit unit)
    {
        return TransactionDesc::toHTML(node, wallet, rec, unit);
    }

    QString getTxHex(interfaces::Wallet& wallet, TransactionRecord *rec)
    {
        auto tx = wallet.getTx(rec->hash);
        if (tx) {
            std::string strHex = EncodeHexTx(*tx);
            return QString::fromStdString(strHex);
        }
        return QString();
    }
};

TransactionTableModel::TransactionTableModel(const PlatformStyle* _platformStyle, WalletModel* parent, bool defer_history):
        QAbstractTableModel(parent),
        walletModel(parent),
        priv(std::make_shared<TransactionTablePriv>(this)),
        platformStyle(_platformStyle)
{
    subscribeToCoreSignals();

    columns << QString() << QString() << tr("Date") << tr("Type") << tr("Label") << BitcoinUnits::getAmountColumnTitle(walletModel->getOptionsModel()->getDisplayUnit());
    if (!defer_history) {
        auto transactions = walletModel->wallet().getWalletTxs();
        std::sort(transactions.begin(), transactions.end());
        for (const auto& tx : transactions) {
            if (TransactionRecord::showTransaction(tx)) {
                auto rows = TransactionRecord::decomposeTransaction(tx);
                for (auto& row : rows) priv->AssignIdentity(row);
                for (const auto& row : rows) {
                    priv->cachedWallet.append(row);
                    priv->Register(priv->cachedWallet.last());
                }
            }
        }
        m_history_loaded = true;
        priv->FinishInitialHistory(/*deferred=*/false);
    }

    connect(walletModel->getOptionsModel(), &OptionsModel::displayUnitChanged, this, &TransactionTableModel::updateDisplayUnit);
}

void TransactionTableModel::setInitialHistory(std::deque<TransactionRecord> history)
{
    assert(priv->cachedWallet.empty() && priv->m_initial_history.empty());
    priv->m_initial_history = std::move(history);
    priv->cachedWallet.reserve(priv->m_initial_history.size());
    priv->PublishInitialHistory();
}

void TransactionTablePriv::PublishInitialHistory()
{
    constexpr int MAX_ROWS_PER_TURN{256};
    const QPointer<TransactionTableModel> model{parent};
    const int count = std::min<size_t>(MAX_ROWS_PER_TURN, m_initial_history.size());
    if (count > 0) {
        const int first = cachedWallet.size();
        for (int i = 0; i < count; ++i) AssignIdentity(m_initial_history[i]);
        model->fProcessingQueuedTransactions = true;
        model->beginInsertRows({}, first, first + count - 1);
        for (int i = 0; i < count; ++i) {
            cachedWallet.append(m_initial_history.front());
            Register(cachedWallet.last());
            m_initial_history.pop_front();
        }
        model->endInsertRows();
        if (!model) return;
        model->fProcessingQueuedTransactions = false;
    }
    if (m_initial_history.empty()) {
        FinishInitialHistory(/*deferred=*/true);
    } else {
        const bool invoked = QMetaObject::invokeMethod(parent, [state = shared_from_this()] {
            state->PublishInitialHistory();
        }, Qt::QueuedConnection);
        assert(invoked);
    }
}

void TransactionTablePriv::FinishInitialHistory(bool deferred)
{
    LOCK(m_notification_mutex);
    m_loaded = true;
    m_initial_boundary_pending = deferred;
    DispatchScannedNotifications();
}

void TransactionTableModel::insertRecords(QList<TransactionRecord> records)
{
    for (int first = 0; first < records.size();) {
        int last = first + 1;
        while (last < records.size() && records[last].hash == records[first].hash) ++last;
        const int lower = std::lower_bound(priv->cachedWallet.cbegin(), priv->cachedWallet.cend(), records[first].hash, TxLessThan()) - priv->cachedWallet.cbegin();
        priv->InsertGroup(lower, records.mid(first, last - first));
        first = last;
    }
}

void TransactionTableModel::mutateRecords(const std::function<void(TransactionRecord&)>& mutate)
{
    for (auto& record : priv->cachedWallet) mutate(record);
    updateConfirmations();
}

void TransactionTableModel::reportHistoryLoadFailure()
{
    m_history_load_failed = true;
    Q_EMIT historyLoadFailed();
}

TransactionTableModel::~TransactionTableModel()
{
    priv->StopNotifications();
    unsubscribeFromCoreSignals();
}

/** Updates the column title to "Amount (DisplayUnit)" and emits headerDataChanged() signal for table headers to react. */
void TransactionTableModel::updateAmountColumnTitle()
{
    columns[Amount] = BitcoinUnits::getAmountColumnTitle(walletModel->getOptionsModel()->getDisplayUnit());
    Q_EMIT headerDataChanged(Qt::Horizontal,Amount,Amount);
}

void TransactionTableModel::updateConfirmations()
{
    if (priv->cachedWallet.empty()) return;
    Q_EMIT dataChanged(index(0, 0), index(priv->cachedWallet.size() - 1, columns.size() - 1),
        {Qt::DisplayRole, Qt::EditRole, Qt::DecorationRole, Qt::ForegroundRole,
         Qt::ToolTipRole, StatusRole, ConfirmedRole, RawDecorationRole});
}

int TransactionTableModel::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid()) {
        return 0;
    }
    return priv->size();
}

int TransactionTableModel::columnCount(const QModelIndex &parent) const
{
    if (parent.isValid()) {
        return 0;
    }
    return columns.length();
}

QString TransactionTableModel::formatTxStatus(const TransactionRecord *wtx) const
{
    QString status;

    switch(wtx->status.status)
    {
    case TransactionStatus::Unconfirmed:
        status = tr("Unconfirmed");
        break;
    case TransactionStatus::Abandoned:
        status = tr("Abandoned");
        break;
    case TransactionStatus::Confirming:
        status = tr("Confirming (%1 of %2 recommended confirmations)").arg(wtx->status.depth).arg(TransactionRecord::RecommendedNumConfirmations);
        break;
    case TransactionStatus::Confirmed:
        status = tr("Confirmed (%1 confirmations)").arg(wtx->status.depth);
        break;
    case TransactionStatus::Conflicted:
        status = tr("Conflicted");
        break;
    case TransactionStatus::Immature:
        status = tr("Immature (%1 confirmations, will be available after %2)").arg(wtx->status.depth).arg(wtx->status.depth + wtx->status.matures_in);
        break;
    case TransactionStatus::NotAccepted:
        status = tr("Generated but not accepted");
        break;
    }

    return status;
}

QString TransactionTableModel::formatTxDate(const TransactionRecord *wtx) const
{
    if(wtx->time)
    {
        return GUIUtil::dateTimeStr(wtx->time);
    }
    return QString();
}

namespace {
QString ShortClaimDestination(const QString& address)
{
    if (address.size() <= 28) return address;
    return address.left(12) + QStringLiteral("...") + address.right(10);
}

bool IsQuantumClaimControlLabel(const std::string& address)
{
    return address == "PoW Claim" || address == "PoS Claim" || address == "PoS Signal" ||
           address == "Quantum PoW Claim" || address == "Quantum PoS Claim" ||
           address == "Gold Rush PoW claim" || address == "Gold Rush signal" ||
           address == "goldrush-pow" || address == "pos-goldrush-test";
}

QString QuantumClaimControlType(const std::string& address)
{
    if (address.find("PoW") != std::string::npos || address == "goldrush-pow") return QObject::tr("PoW Claim");
    if (address.find("Signal") != std::string::npos || address.find("signal") != std::string::npos || address == "pos-goldrush-test") return QObject::tr("PoS Claim");
    if (address.find("PoS") != std::string::npos) return QObject::tr("PoS Claim");
    return QObject::tr("Quantum Claim");
}
} // namespace

/* Look up address in address book, if found return label (address)
   otherwise just return (address)
 */
QString TransactionTableModel::lookupAddress(const TransactionRecord& record, bool tooltip) const
{
    QString label = priv->LabelForAddress(record);
    QString description;
    if(!label.isEmpty())
    {
        description += label;
    }
    if(label.isEmpty() || tooltip)
    {
        description += QString(" (") + QString::fromStdString(record.address) + QString(")");
    }
    return description;
}

QString TransactionTableModel::formatGoldRushClaimType(const TransactionRecord *wtx, const QString& claim_type) const
{
    if (wtx->address.empty()) return claim_type;

    const QString address = QString::fromStdString(wtx->address);
    return claim_type + tr(" -> ") + ShortClaimDestination(address);
}

QString TransactionTableModel::formatGoldRushToAddress(const TransactionRecord *wtx, bool tooltip) const
{
    const QString reward_type = wtx->type == TransactionRecord::GoldRushPowClaim ?
        tr("PoW - Quantum Claim") :
        tr("PoS - Quantum Stake");
    if (wtx->address.empty()) return reward_type;

    const QString address = QString::fromStdString(wtx->address);
    return reward_type + tr(" -> ") + (tooltip ? address : ShortClaimDestination(address));
}

QString TransactionTableModel::formatTxType(const TransactionRecord *wtx) const
{
    switch(wtx->type)
    {
    case TransactionRecord::RecvWithAddress:
        return tr("Received with");
    case TransactionRecord::RecvFromOther:
        return tr("Received from");
    case TransactionRecord::SendToAddress:
    case TransactionRecord::SendToOther:
        return tr("Sent to");
    case TransactionRecord::Generated:
        return tr("Mined");
    case TransactionRecord::Staked:
        return tr("Staked");
    case TransactionRecord::GoldRushPosStake:
        return formatGoldRushClaimType(wtx, tr("PoS - Quantum Stake"));
    case TransactionRecord::GoldRushPowClaim:
        return formatGoldRushClaimType(wtx, tr("PoW - Quantum Claim"));
    case TransactionRecord::Other:
        if (IsQuantumClaimControlLabel(wtx->address)) return QuantumClaimControlType(wtx->address);
        return tr("Other");
    default:
        return QString();
    }
}

QVariant TransactionTableModel::txAddressDecoration(const TransactionRecord *wtx) const
{
    switch(wtx->type)
    {
    case TransactionRecord::Generated:
        return QIcon(":/icons/tx_mined");
    case TransactionRecord::Staked:
	    return QIcon(":/icons/tx_staked");
    case TransactionRecord::GoldRushPosStake:
        return QIcon(":/icons/tx_staked");
    case TransactionRecord::GoldRushPowClaim:
        return QIcon(":/icons/tx_mined");
    case TransactionRecord::RecvWithAddress:
    case TransactionRecord::RecvFromOther:
        return QIcon(":/icons/tx_input");
    case TransactionRecord::SendToAddress:
    case TransactionRecord::SendToOther:
        return QIcon(":/icons/tx_output");
    default:
        return QIcon(":/icons/tx_inout");
    }
}

QString TransactionTableModel::formatTxToAddress(const TransactionRecord *wtx, bool tooltip) const
{
    QString watchAddress;
    if (tooltip && wtx->involvesWatchAddress) {
        // Mark transactions involving watch-only addresses by adding " (watch-only)"
        watchAddress = QLatin1String(" (") + tr("watch-only") + QLatin1Char(')');
    }

    switch(wtx->type)
    {
    case TransactionRecord::RecvFromOther:
        return QString::fromStdString(wtx->address) + watchAddress;
    case TransactionRecord::RecvWithAddress:
    case TransactionRecord::SendToAddress:
    case TransactionRecord::Generated:
    case TransactionRecord::Staked:
        return lookupAddress(*wtx, tooltip) + watchAddress;
    case TransactionRecord::GoldRushPosStake:
    case TransactionRecord::GoldRushPowClaim:
        return formatGoldRushToAddress(wtx, tooltip) + watchAddress;
    case TransactionRecord::SendToOther:
        return QString::fromStdString(wtx->address) + watchAddress;
    default:
        if (IsQuantumClaimControlLabel(wtx->address)) {
            return tr("Legacy-chain control transaction") + watchAddress;
        }
        if (!wtx->address.empty()) {
            return QString::fromStdString(wtx->address) + watchAddress;
        }
        return tr("(n/a)") + watchAddress;
    }
}

QVariant TransactionTableModel::addressColor(const TransactionRecord *wtx) const
{
    // Show addresses without label in a less visible color
    switch(wtx->type)
    {
    case TransactionRecord::RecvWithAddress:
    case TransactionRecord::SendToAddress:
    case TransactionRecord::Generated:
    case TransactionRecord::Staked:
        {
        QString label = priv->LabelForAddress(*wtx);
        if(label.isEmpty())
            return COLOR_BAREADDRESS;
        } break;
    default:
        break;
    }
    return QVariant();
}

QString TransactionTableModel::formatTxAmount(const TransactionRecord *wtx, bool showUnconfirmed, BitcoinUnits::SeparatorStyle separators) const
{
    QString str = BitcoinUnits::format(walletModel->getOptionsModel()->getDisplayUnit(), wtx->credit + wtx->debit, false, separators);
    if(showUnconfirmed)
    {
        if(!wtx->status.countsForBalance)
        {
            str = QString("[") + str + QString("]");
        }
    }
    return QString(str);
}

QVariant TransactionTableModel::txStatusDecoration(const TransactionRecord *wtx) const
{
    switch(wtx->status.status)
    {
    case TransactionStatus::Unconfirmed:
        return QIcon(":/icons/transaction_0");
    case TransactionStatus::Abandoned:
        return QIcon(":/icons/transaction_abandoned");
    case TransactionStatus::Confirming:
        switch(wtx->status.depth)
        {
        case 1: return QIcon(":/icons/transaction_1");
        case 2: return QIcon(":/icons/transaction_2");
        case 3: return QIcon(":/icons/transaction_3");
        case 4: return QIcon(":/icons/transaction_4");
        default: return QIcon(":/icons/transaction_5");
        };
    case TransactionStatus::Confirmed:
        return QIcon(":/icons/transaction_confirmed");
    case TransactionStatus::Conflicted:
        return QIcon(":/icons/transaction_conflicted");
    case TransactionStatus::Immature: {
        int total = wtx->status.depth + wtx->status.matures_in;
        int part = (wtx->status.depth * 4 / total) + 1;
        return QIcon(QString(":/icons/transaction_%1").arg(part));
        }
    case TransactionStatus::NotAccepted:
        return QIcon(":/icons/transaction_0");
    default:
        return COLOR_BLACK;
    }
}

QVariant TransactionTableModel::txWatchonlyDecoration(const TransactionRecord *wtx) const
{
    if (wtx->involvesWatchAddress)
        return QIcon(":/icons/eye");
    else
        return QVariant();
}

QString TransactionTableModel::formatTooltip(const TransactionRecord *rec) const
{
    QString tooltip = formatTxStatus(rec) + QString("\n") + formatTxType(rec);
    if(rec->type==TransactionRecord::RecvFromOther || rec->type==TransactionRecord::SendToOther ||
       rec->type==TransactionRecord::SendToAddress || rec->type==TransactionRecord::RecvWithAddress)
    {
        tooltip += QString(" ") + formatTxToAddress(rec, true);
    }
    return tooltip;
}

QVariant TransactionTableModel::data(const QModelIndex &index, int role) const
{
    if(!index.isValid())
        return QVariant();
    return dataFor(static_cast<TransactionRecord*>(index.internalPointer()), index.column(), role);
}

QVariant TransactionTableModel::dataFor(TransactionRecord* rec, int column_index, int role) const
{

    const auto column = static_cast<ColumnIndex>(column_index);
    switch (role) {
    case RawDecorationRole:
        switch (column) {
        case Status:
            return txStatusDecoration(rec);
        case Watchonly:
            return txWatchonlyDecoration(rec);
        case Date: return {};
        case Type: return {};
        case ToAddress:
            return txAddressDecoration(rec);
        case Amount: return {};
        } // no default case, so the compiler can warn about missing cases
        assert(false);
    case Qt::DecorationRole:
    {
        QIcon icon = qvariant_cast<QIcon>(dataFor(rec, column_index, RawDecorationRole));
        return platformStyle->TextColorIcon(icon);
    }
    case Qt::DisplayRole:
        switch (column) {
        case Status: return {};
        case Watchonly: return {};
        case Date:
            return formatTxDate(rec);
        case Type:
            return formatTxType(rec);
        case ToAddress:
            return formatTxToAddress(rec, false);
        case Amount:
            return formatTxAmount(rec, true, BitcoinUnits::SeparatorStyle::ALWAYS);
        } // no default case, so the compiler can warn about missing cases
        assert(false);
    case Qt::EditRole:
        // Edit role is used for sorting, so return the unformatted values
        switch (column) {
        case Status:
            return QString::fromStdString(rec->status.sortKey);
        case Date:
            return QString::fromStdString(strprintf("%020s-%s", rec->time, rec->status.sortKey));
        case Type:
            return formatTxType(rec);
        case Watchonly:
            return (rec->involvesWatchAddress ? 1 : 0);
        case ToAddress:
            return formatTxToAddress(rec, true);
        case Amount:
            return qint64(rec->credit + rec->debit);
        } // no default case, so the compiler can warn about missing cases
        assert(false);
    case Qt::ToolTipRole:
        return formatTooltip(rec);
    case Qt::TextAlignmentRole:
        return column_alignments[column_index];
    case Qt::ForegroundRole:
        // Use the "danger" color for abandoned transactions
        if(rec->status.status == TransactionStatus::Abandoned)
        {
            return COLOR_TX_STATUS_DANGER;
        }
        // Non-confirmed (but not immature) as transactions are grey
        if(!rec->status.countsForBalance && rec->status.status != TransactionStatus::Immature)
        {
            return COLOR_UNCONFIRMED;
        }
        if(column_index == Amount && (rec->credit+rec->debit) < 0)
        {
            return COLOR_NEGATIVE;
        }
        if(column_index == ToAddress)
        {
            return addressColor(rec);
        }
        break;
    case TypeRole:
        return rec->type;
    case DateRole:
        return QDateTime::fromSecsSinceEpoch(rec->time);
    case WatchonlyRole:
        return rec->involvesWatchAddress;
    case WatchonlyDecorationRole:
        return txWatchonlyDecoration(rec);
    case LongDescriptionRole:
        return priv->describe(walletModel->node(), walletModel->wallet(), rec, walletModel->getOptionsModel()->getDisplayUnit());
    case AddressRole:
        return QString::fromStdString(rec->address);
    case LabelRole:
    case ExportLabelRole:
        if (rec->type == TransactionRecord::GoldRushPosStake || rec->type == TransactionRecord::GoldRushPowClaim) {
            return formatGoldRushToAddress(rec, false);
        }
        if (role == ExportLabelRole) {
            return walletModel->getAddressTableModel()->labelForAddress(QString::fromStdString(rec->address));
        }
        return priv->LabelForAddress(*rec);
    case AmountRole:
        return qint64(rec->credit + rec->debit);
    case TxHashRole:
        return rec->getTxHash();
    case TxHexRole:
        return priv->getTxHex(walletModel->wallet(), rec);
    case TxPlainTextRole:
        {
            QString details;
            QDateTime date = QDateTime::fromSecsSinceEpoch(rec->time);
            QString txLabel = walletModel->getAddressTableModel()->labelForAddress(QString::fromStdString(rec->address));

            details.append(date.toString("M/d/yy HH:mm"));
            details.append(" ");
            details.append(formatTxStatus(rec));
            details.append(". ");
            if(!formatTxType(rec).isEmpty()) {
                details.append(formatTxType(rec));
                details.append(" ");
            }
            if(rec->type == TransactionRecord::GoldRushPosStake || rec->type == TransactionRecord::GoldRushPowClaim) {
                details.append(formatGoldRushToAddress(rec, true));
                details.append(" ");
            } else if(IsQuantumClaimControlLabel(rec->address)) {
                details.append(formatTxToAddress(rec, true));
                details.append(" ");
            } else if(!rec->address.empty()) {
                if(txLabel.isEmpty())
                    details.append(tr("(no label)") + " ");
                else {
                    details.append("(");
                    details.append(txLabel);
                    details.append(") ");
                }
                details.append(QString::fromStdString(rec->address));
                details.append(" ");
            }
            details.append(formatTxAmount(rec, false, BitcoinUnits::SeparatorStyle::NEVER));
            return details;
        }
    case ConfirmedRole:
        return rec->status.status == TransactionStatus::Status::Confirming || rec->status.status == TransactionStatus::Status::Confirmed;
    case FormattedAmountRole:
        // Used for copy/export, so don't include separators
        return formatTxAmount(rec, false, BitcoinUnits::SeparatorStyle::NEVER);
    case StatusRole:
        return rec->status.status;
    }
    return QVariant();
}

QVariant TransactionTableModel::headerData(int section, Qt::Orientation orientation, int role) const
{
    if(orientation == Qt::Horizontal)
    {
        if(role == Qt::DisplayRole)
        {
            return columns[section];
        }
        else if (role == Qt::TextAlignmentRole)
        {
            return column_alignments[section];
        } else if (role == Qt::ToolTipRole)
        {
            switch(section)
            {
            case Status:
                return tr("Transaction status. Hover over this field to show number of confirmations.");
            case Date:
                return tr("Date and time that the transaction was received.");
            case Type:
                return tr("Type of transaction.");
            case Watchonly:
                return tr("Whether or not a watch-only address is involved in this transaction.");
            case ToAddress:
                return tr("User-defined intent/purpose of the transaction.");
            case Amount:
                return tr("Amount removed from or added to balance.");
            }
        }
    }
    return QVariant();
}

QModelIndex TransactionTableModel::index(int row, int column, const QModelIndex &parent) const
{
    Q_UNUSED(parent);
    TransactionRecord* data = priv->index(walletModel->wallet(), walletModel->getLastBlockProcessed(), row);
    if(data)
    {
        return createIndex(row, column, data);
    }
    return QModelIndex();
}

void TransactionTableModel::updateDisplayUnit()
{
    // emit dataChanged to update Amount column with the current unit
    updateAmountColumnTitle();
    if (priv->size() == 0) return;
    Q_EMIT dataChanged(index(0, Amount), index(priv->size()-1, Amount));
}

QString TransactionTablePriv::LabelForAddress(const TransactionRecord& record)
{
    const CTxDestination dest = Destination(record.address);
    if (!IsValidDestination(dest)) return {};
    auto& entry = m_labels[dest];
    entry.transactions.insert(record.hash);
    if (entry.value) return *entry.value;
    if (m_pending_labels.count(dest)) return {};

    const auto label = parent->walletModel->wallet().tryGetAddressLabel(dest);
    if (label) {
        entry.value = QString::fromStdString(*label);
        return *entry.value;
    }

    m_pending_labels.insert(dest);
    ScheduleLabelRefresh();
    return {};
}

void TransactionTablePriv::ForgetLabelRow(const TransactionRecord& record)
{
    const CTxDestination dest = Destination(record.address);
    const auto entry = m_labels.find(dest);
    if (entry == m_labels.end()) return;
    entry->second.transactions.erase(record.hash);
    if (!entry->second.transactions.empty()) return;
    m_pending_labels.erase(dest);
    m_changed_labels.erase(dest);
    m_labels.erase(entry);
}

void TransactionTableModel::invalidateAddressLabel(const QString& address)
{
    priv->InvalidateAddressLabel(address);
}

void TransactionTablePriv::InvalidateAddressLabel(const QString& address)
{
    const CTxDestination dest = DecodeDestination(address.toStdString());
    if (!m_labels.count(dest)) return;
    // The wallet can deliver notifications from different threads. Read its
    // current label rather than installing a potentially older event payload.
    m_pending_labels.insert(dest);
    ScheduleLabelRefresh();
}

void TransactionTablePriv::ScheduleLabelRefresh()
{
    if (m_label_refresh_scheduled) return;
    m_label_refresh_scheduled = true;
    QTimer::singleShot(0, parent, [state = shared_from_this()] { state->RefreshLabels(); });
}

void TransactionTablePriv::RefreshLabels()
{
    constexpr int MAX_LABELS_PER_TURN{32};
    for (int processed = 0; processed < MAX_LABELS_PER_TURN && !m_pending_labels.empty(); ++processed) {
        const auto next = m_pending_labels.begin();
        const auto label = parent->walletModel->wallet().tryGetAddressLabel(*next);
        if (!label) {
            QTimer::singleShot(25, parent, [state = shared_from_this()] { state->RefreshLabels(); });
            return;
        }
        auto& cached = m_labels.at(*next).value;
        const QString current = QString::fromStdString(*label);
        if (cached.value_or(QString{}) != current) {
            m_changed_labels.insert(*next);
        }
        cached = current;
        m_pending_labels.erase(next);
    }
    m_label_refresh_scheduled = false;
    if (!m_pending_labels.empty()) {
        ScheduleLabelRefresh();
        return;
    }
    NotifyChangedLabelRows();
}

void TransactionTablePriv::NotifyChangedLabelRows()
{
    if (m_label_notify_scheduled || m_changed_labels.empty()) return;
    m_label_notify_scheduled = true;
    QTimer::singleShot(0, parent, [state = shared_from_this()] { state->DrainChangedLabelRows(); });
}

void TransactionTablePriv::DrainChangedLabelRows()
{
    QElapsedTimer elapsed;
    elapsed.start();
    for (int work = 0; work < 32 && elapsed.elapsed() < 4; ++work) {
        if (!m_notifying_label) {
            if (m_changed_labels.empty()) { m_label_notify_scheduled = false; return; }
            m_notifying_label = *m_changed_labels.begin();
            m_changed_labels.erase(m_changed_labels.begin());
            m_notified_label_hash.reset();
        }
        const auto label = m_labels.find(*m_notifying_label);
        if (label == m_labels.end()) { m_notifying_label.reset(); continue; }
        const auto& hashes = label->second.transactions;
        const auto hash = m_notified_label_hash ? hashes.upper_bound(*m_notified_label_hash) : hashes.begin();
        if (hash == hashes.end()) { m_notifying_label.reset(); continue; }
        m_notified_label_hash = *hash;
        const auto [first, last] = std::equal_range(cachedWallet.cbegin(), cachedWallet.cend(), *hash, TxLessThan());
        std::vector<QPersistentModelIndex> rows;
        for (auto entry = first; entry != last; ++entry) {
            if (DecodeDestination(entry->address) == *m_notifying_label) rows.emplace_back(parent->index(std::distance(cachedWallet.cbegin(), entry), 0));
        }
        const QPointer<TransactionTableModel> model{parent};
        for (const auto& row : rows) {
            if (!row.isValid()) continue;
            Q_EMIT model->dataChanged(row, model->index(row.row(), TransactionTableModel::ToAddress),
                {Qt::DisplayRole, Qt::EditRole, Qt::ForegroundRole, Qt::ToolTipRole, TransactionTableModel::LabelRole});
            if (!model) return;
        }
    }
    QTimer::singleShot(0, parent, [state = shared_from_this()] { state->DrainChangedLabelRows(); });
}

void TransactionTablePriv::PostDrain()
{
    const bool invoked = QMetaObject::invokeMethod(parent, [state = shared_from_this()] {
        state->DrainPendingUpdates();
    }, Qt::QueuedConnection);
    assert(invoked);
}

void TransactionTablePriv::DrainPendingUpdates()
{
    constexpr int MAX_UPDATES_PER_TURN{32};
    constexpr int WALLET_RETRY_MS{25};
    QElapsedTimer elapsed;
    elapsed.start();
    for (int processed = 0; processed < MAX_UPDATES_PER_TURN && elapsed.elapsed() < 4; ++processed) {
        TransactionNotification notification;
        {
            LOCK(m_notification_mutex);
            if (m_notifications_stopped) return;
            if (m_pending_updates.empty()) {
                m_drain_scheduled = false;
                return;
            }
            notification = m_pending_updates.front();
        }

        if (notification.initial_history_boundary) {
            {
                LOCK(m_notification_mutex);
                m_pending_updates.pop_front();
            }
            const QPointer<TransactionTableModel> model{parent};
            model->m_history_loaded = true;
            Q_EMIT model->historyLoaded();
            if (!model) return;
            continue;
        }

        interfaces::WalletTx tx;
        if (notification.status != CT_DELETED &&
            !parent->walletModel->wallet().tryGetWalletTx(notification.hash, tx)) {
            // Keep the head in place so later updates and deletes cannot overtake it.
            QTimer::singleShot(WALLET_RETRY_MS, parent, [state = shared_from_this()] {
                state->DrainPendingUpdates();
            });
            return;
        }
        {
            LOCK(m_notification_mutex);
            m_pending_updates.pop_front();
        }

        const QPointer<TransactionTableModel> model{parent};
        model->fProcessingQueuedTransactions = notification.suppress_incoming;
        updateWallet(notification.hash, notification.status, tx);
        if (!model) return;
        model->fProcessingQueuedTransactions = false;
    }

    LOCK(m_notification_mutex);
    m_drain_scheduled = false;
    SchedulePendingUpdates();
}

void TransactionTablePriv::SchedulePendingUpdates()
{
    if (m_drain_scheduled || m_pending_updates.empty()) return;
    m_drain_scheduled = true;
    PostDrain();
}

void TransactionTablePriv::NotifyTransactionChanged(const uint256& hash, ChangeType status)
{
    LOCK(m_notification_mutex);
    if (m_notifications_stopped) return;
    const TransactionNotification notification{hash, status};
    if (!m_loaded || m_scanning) {
        m_scanned_notifications.push_back(notification);
        return;
    }
    m_pending_updates.push_back(notification);
    SchedulePendingUpdates();
}

void TransactionTablePriv::NotifyScanProgress(int progress)
{
    LOCK(m_notification_mutex);
    if (m_notifications_stopped) return;
    m_scanning = progress < 100;
    DispatchScannedNotifications();
}

void TransactionTablePriv::DispatchScannedNotifications()
{
    if (!m_loaded || m_scanning) return;
    for (size_t i = 0; i < m_scanned_notifications.size(); ++i) {
        auto notification = m_scanned_notifications[i];
        // Preserve the scan policy of allowing balloons for only the last 10 notifications.
        notification.suppress_incoming = m_scanned_notifications.size() - i > 10;
        m_pending_updates.push_back(notification);
    }
    m_scanned_notifications.clear();
    if (m_initial_boundary_pending) {
        m_pending_updates.push_back({{}, CT_UPDATED, false, true});
        m_initial_boundary_pending = false;
    }
    SchedulePendingUpdates();
}

void TransactionTablePriv::StopNotifications()
{
    LOCK(m_notification_mutex);
    m_notifications_stopped = true;
}

void TransactionTableModel::subscribeToCoreSignals()
{
    m_handler_transaction_changed = walletModel->wallet().handleTransactionChanged(
        [state = priv](const uint256& hash, ChangeType status) { state->NotifyTransactionChanged(hash, status); });
    m_handler_show_progress = walletModel->wallet().handleShowProgress(
        [state = priv](const std::string&, int progress) { state->NotifyScanProgress(progress); });
}

void TransactionTableModel::unsubscribeFromCoreSignals()
{
    // Disconnect signals from wallet
    m_handler_transaction_changed->disconnect();
    m_handler_show_progress->disconnect();
}

QModelIndexList TransactionTableModel::indexesForTransaction(const uint256& hash) const
{
    QModelIndexList result;
    const auto [first, last] = std::equal_range(priv->cachedWallet.cbegin(), priv->cachedWallet.cend(), hash, TxLessThan());
    for (auto entry = first; entry != last; ++entry) result.append(index(std::distance(priv->cachedWallet.cbegin(), entry), 0));
    return result;
}

TransactionRowIdentity TransactionTableModel::transactionIdentity(int row) const
{
    if (row < 0 || row >= priv->cachedWallet.size()) return {};
    const auto& record = priv->cachedWallet[row];
    return {record.hash, record.presentation_id};
}

int TransactionTableModel::transactionRow(const TransactionRowIdentity& identity) const
{
    if (identity.id == 0) return -1;
    const auto& records = priv->cachedWallet;
    const auto [first, last] = std::equal_range(records.cbegin(), records.cend(), identity.hash, TxLessThan());
    // Each hash's rows are allocated together in presentation order. Status and
    // label changes leave IDs/order intact; delete/reinsert obtains fresh IDs.
    const auto found = std::lower_bound(first, last, identity.id,
        [](const TransactionRecord& row, uint64_t id) { return row.presentation_id < id; });
    return found != last && found->presentation_id == identity.id ? std::distance(records.cbegin(), found) : -1;
}

bool TransactionTableModel::transactionScanRow(int row, int column, TransactionScanRow& out) const
{
    if (row < 0 || row >= priv->cachedWallet.size()) return false;
    TransactionRecord* rec = &priv->cachedWallet[row];
    // Unless asked, the cached status is used as is: refreshing it needs the wallet lock, which a scan of the
    // whole history must not take once per row. Rows that are displayed refresh their status in transactionData().
    // A row whose status is final (confirmed, nothing flagged it) cannot change its sort key, so only rows that have
    // never been refreshed, are flagged, or are still maturing or confirming take the wallet lock.
    if (out.refresh_status && (rec->status.sortKey.empty() || rec->status.needsUpdate || rec->status.status != TransactionStatus::Confirmed)) {
        TransactionTablePriv::RefreshStatus(walletModel->wallet(), walletModel->getLastBlockProcessed(), rec);
    }
    out.identity = {rec->hash, rec->presentation_id};
    out.status = rec->status.status;
    out.type = rec->type;
    out.watchonly = rec->involvesWatchAddress;
    out.time = rec->time;
    out.amount = qint64(rec->credit + rec->debit);
    switch (column) {
    case Status: out.key = TransactionScanRow::Key::TEXT; out.text = QString::fromStdString(rec->status.sortKey); break;
    case Watchonly: out.key = TransactionScanRow::Key::NUMBER; out.number = rec->involvesWatchAddress ? 1 : 0; break;
    case Date: out.key = TransactionScanRow::Key::DATE; out.number = rec->time; out.text = QString::fromStdString(rec->status.sortKey); break;
    case Type: out.key = TransactionScanRow::Key::TEXT; out.text = formatTxType(rec); break;
    case ToAddress: out.key = TransactionScanRow::Key::TEXT; out.text = formatTxToAddress(rec, true); break;
    case Amount: out.key = TransactionScanRow::Key::NUMBER; out.number = out.amount; break;
    default: return false;
    }
    return true;
}

bool TransactionTableModel::transactionMatchesText(int row, const QString& needle, bool& supported) const
{
    supported = true;
    if (row < 0 || row >= priv->cachedWallet.size()) return false;
    TransactionRecord* rec = &priv->cachedWallet[row];
    bool ascii = true;
    for (const QChar c : needle) ascii = ascii && c.unicode() < 128;
    if (ascii) {
        // ASCII needles compare byte-wise; the address and the hash text are ASCII.
        const std::string lowered = needle.toLower().toStdString();
        const auto contains = [&lowered](const std::string& text) {
            return std::search(text.begin(), text.end(), lowered.begin(), lowered.end(),
                [](char a, char b) { return ToLower(a) == b; }) != text.end();
        };
        if (contains(rec->address) || contains(rec->hash.ToString())) return true;
    } else {
        if (QString::fromStdString(rec->address).contains(needle, Qt::CaseInsensitive) ||
            rec->getTxHash().contains(needle, Qt::CaseInsensitive)) return true;
    }
    return dataFor(rec, 0, LabelRole).toString().contains(needle, Qt::CaseInsensitive);
}

bool TransactionTableModel::transactionData(const TransactionRowIdentity& identity, int column, int role, QVariant& out) const
{
    if (identity.id == 0) return false;
    const auto found = priv->FindById(identity.id);
    if (!found || found->hash != identity.hash) return false;
    if (role < 0) { out = QVariant(); return true; }
    TransactionTablePriv::RefreshStatus(walletModel->wallet(), walletModel->getLastBlockProcessed(), found);
    out = dataFor(found, column, role);
    return true;
}
