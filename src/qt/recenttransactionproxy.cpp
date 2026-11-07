// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/recenttransactionproxy.h>

#include <algorithm>

RecentTransactionProxy::RecentTransactionProxy(QAbstractItemModel& source, int limit)
    : m_limit{limit}
{
    setSourceModel(&source);
    resetFromSource();

    connect(&source, &QAbstractItemModel::rowsInserted, this, &RecentTransactionProxy::synchronize);
    connect(&source, &QAbstractItemModel::rowsMoved, this, &RecentTransactionProxy::synchronize);
    connect(&source, &QAbstractItemModel::layoutChanged, this, &RecentTransactionProxy::synchronize);
    connect(&source, &QAbstractItemModel::rowsAboutToBeRemoved, this, [this](const QModelIndex& parent, int first, int) {
        // Keep the outgoing source indexes available during our about-to
        // signal. A removal strictly below the projection needs no reset.
        if (!parent.isValid() && first < m_rows.size()) beginSourceReset();
    });
    connect(&source, &QAbstractItemModel::rowsRemoved, this, [this] {
        if (m_resetting) endSourceReset();
    });
    connect(&source, &QAbstractItemModel::modelAboutToBeReset, this, &RecentTransactionProxy::beginSourceReset);
    connect(&source, &QAbstractItemModel::modelReset, this, &RecentTransactionProxy::endSourceReset);
    connect(&source, &QAbstractItemModel::dataChanged, this,
            [this](const QModelIndex& first, const QModelIndex& last, const QVector<int>& roles) {
        if (m_resetting || first.parent().isValid() || first.row() >= m_rows.size()) return;
        Q_EMIT dataChanged(index(first.row(), first.column()),
                           index(std::min(last.row(), m_rows.size() - 1), last.column()), roles);
    });
    connect(&source, &QObject::destroyed, this, [this] {
        if (!m_resetting) beginSourceReset();
        m_rows.clear();
        m_resetting = false;
        endResetModel();
    });
}

QModelIndex RecentTransactionProxy::index(int row, int column, const QModelIndex& parent) const
{
    return hasIndex(row, column, parent) ? createIndex(row, column) : QModelIndex{};
}

int RecentTransactionProxy::rowCount(const QModelIndex& parent) const
{
    return parent.isValid() ? 0 : m_rows.size();
}

int RecentTransactionProxy::columnCount(const QModelIndex& parent) const
{
    return !parent.isValid() && sourceModel() ? sourceModel()->columnCount() : 0;
}

QModelIndex RecentTransactionProxy::mapFromSource(const QModelIndex& index) const
{
    if (!index.isValid() || index.model() != sourceModel() || index.parent().isValid()) return {};
    const QModelIndex anchor = index.sibling(index.row(), 0);
    for (int row = 0; row < m_rows.size(); ++row) {
        if (m_rows[row] == anchor) return this->index(row, index.column());
    }
    return {};
}

QModelIndex RecentTransactionProxy::mapToSource(const QModelIndex& index) const
{
    if (!index.isValid() || index.model() != this || index.row() >= m_rows.size()) return {};
    const auto& anchor = m_rows[index.row()];
    return anchor.isValid() ? anchor.sibling(anchor.row(), index.column()) : QModelIndex{};
}

void RecentTransactionProxy::synchronize()
{
    if (m_resetting) return;
    const int count = std::min(m_limit, sourceModel()->rowCount());
    if (count == m_rows.size()) {
        bool same = true;
        for (int row = 0; row < count; ++row) {
            if (m_rows[row] != sourceModel()->index(row, 0)) {
                same = false;
                break;
            }
        }
        if (same) return;
    }

    // A top-row replacement invalidates old view selections and persistent
    // indexes in one bounded reset. Lower-row churn keeps them intact.
    beginSourceReset();
    endSourceReset();
}

void RecentTransactionProxy::resetFromSource()
{
    m_rows.clear();
    if (!sourceModel()) return;
    const int count = std::min(m_limit, sourceModel()->rowCount());
    m_rows.reserve(count);
    for (int row = 0; row < count; ++row) {
        m_rows.append(sourceModel()->index(row, 0));
    }
}

void RecentTransactionProxy::beginSourceReset()
{
    m_resetting = true;
    beginResetModel();
}

void RecentTransactionProxy::endSourceReset()
{
    resetFromSource();
    m_resetting = false;
    endResetModel();
}
