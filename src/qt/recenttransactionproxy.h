// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_RECENTTRANSACTIONPROXY_H
#define BITCOIN_QT_RECENTTRANSACTIONPROXY_H

#include <QAbstractProxyModel>
#include <QVector>

/** Project the first few rows of an already sorted, filtered flat model. */
class RecentTransactionProxy final : public QAbstractProxyModel
{
public:
    RecentTransactionProxy(QAbstractItemModel& source, int limit);

    QModelIndex index(int row, int column, const QModelIndex& parent = {}) const override;
    QModelIndex parent(const QModelIndex&) const override { return {}; }
    int rowCount(const QModelIndex& parent = {}) const override;
    int columnCount(const QModelIndex& parent = {}) const override;
    QModelIndex mapFromSource(const QModelIndex& index) const override;
    QModelIndex mapToSource(const QModelIndex& index) const override;

private:
    using QAbstractProxyModel::setSourceModel;
    void synchronize();
    void resetFromSource();
    void beginSourceReset();
    void endSourceReset();

    const int m_limit;
    QVector<QPersistentModelIndex> m_rows;
    bool m_resetting{false};
};

#endif // BITCOIN_QT_RECENTTRANSACTIONPROXY_H
