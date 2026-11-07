// Copyright (c) 2011-2021 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/transactionfilterproxy.h>

#include <qt/transactiontablemodel.h>
#include <qt/transactionrecord.h>

#include <algorithm>
#include <cstdlib>
#include <optional>

TransactionFilterProxy::TransactionFilterProxy(QObject* parent)
    : QSortFilterProxyModel(parent),
      m_search_string(),
      typeFilter(ALL_TYPES)
{
}

std::unique_ptr<TransactionFilterProxy> TransactionFilterProxy::makeExportModel() const
{
    auto result = std::make_unique<TransactionFilterProxy>();
    result->dateFrom = dateFrom;
    result->dateTo = dateTo;
    result->m_search_string = m_search_string;
    result->typeFilter = typeFilter;
    result->watchOnlyFilter = watchOnlyFilter;
    result->minAmount = minAmount;
    result->showInactive = showInactive;
    result->m_export_model = true;
    result->setDynamicSortFilter(false);
    result->setSortCaseSensitivity(sortCaseSensitivity());
    result->setSortLocaleAware(isSortLocaleAware());
    result->setSortRole(sortRole());
    result->setSourceModel(sourceModel());
    result->sort(sortColumn(), sortOrder());
    return result;
}

QString TransactionFilterProxy::labelForFilter(const QModelIndex& source_index) const
{
    if (!m_export_model) {
        return source_index.data(TransactionTableModel::LabelRole).toString();
    }

    // The detached proxy is used synchronously without dispatching model
    // updates. Keep the label used for filtering for the corresponding CSV row.
    const int row = source_index.row();
    const auto cached = m_export_labels.constFind(row);
    if (cached != m_export_labels.cend()) return cached.value();
    const QString label = source_index.data(TransactionTableModel::ExportLabelRole).toString();
    m_export_labels.insert(row, label);
    return label;
}

QVariant TransactionFilterProxy::data(const QModelIndex& index, int role) const
{
    if (m_export_model && index.isValid() && role == TransactionTableModel::ExportLabelRole) {
        return labelForFilter(mapToSource(index));
    }
    return QSortFilterProxyModel::data(index, role);
}

bool TransactionFilterProxy::filterAcceptsRow(int sourceRow, const QModelIndex &sourceParent) const
{
    QModelIndex index = sourceModel()->index(sourceRow, 0, sourceParent);

    int status = index.data(TransactionTableModel::StatusRole).toInt();
    if (!showInactive && status == TransactionStatus::Conflicted)
        return false;

    int type = index.data(TransactionTableModel::TypeRole).toInt();
    if (!(TYPE(type) & typeFilter))
        return false;

    bool involvesWatchAddress = index.data(TransactionTableModel::WatchonlyRole).toBool();
    if (involvesWatchAddress && watchOnlyFilter == WatchOnlyFilter_No)
        return false;
    if (!involvesWatchAddress && watchOnlyFilter == WatchOnlyFilter_Yes)
        return false;

    QDateTime datetime = index.data(TransactionTableModel::DateRole).toDateTime();
    if (dateFrom && datetime < *dateFrom) return false;
    if (dateTo && datetime > *dateTo) return false;

    if (!m_search_string.isEmpty() &&
        !index.data(TransactionTableModel::AddressRole).toString().contains(m_search_string, Qt::CaseInsensitive) &&
        !index.data(TransactionTableModel::TxHashRole).toString().contains(m_search_string, Qt::CaseInsensitive) &&
        !labelForFilter(index).contains(m_search_string, Qt::CaseInsensitive)) {
        return false;
    }

    qint64 amount = llabs(index.data(TransactionTableModel::AmountRole).toLongLong());
    if (amount < minAmount)
        return false;

    return true;
}

void TransactionFilterProxy::setDateRange(const std::optional<QDateTime>& from, const std::optional<QDateTime>& to)
{
    dateFrom = from;
    dateTo = to;
    invalidateFilter();
}

void TransactionFilterProxy::setSearchString(const QString &search_string)
{
    if (m_search_string == search_string) return;
    m_search_string = search_string;
    invalidateFilter();
}

void TransactionFilterProxy::setTypeFilter(quint32 modes)
{
    this->typeFilter = modes;
    invalidateFilter();
}

void TransactionFilterProxy::setMinAmount(const CAmount& minimum)
{
    this->minAmount = minimum;
    invalidateFilter();
}

void TransactionFilterProxy::setWatchOnlyFilter(WatchOnlyFilter filter)
{
    this->watchOnlyFilter = filter;
    invalidateFilter();
}

void TransactionFilterProxy::setShowInactive(bool _showInactive)
{
    this->showInactive = _showInactive;
    invalidateFilter();
}
