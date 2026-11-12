// Copyright (c) 2011-2021 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/transactionfilterproxy.h>

#include <qt/transactiontablemodel.h>
#include <qt/transactionrecord.h>

#include <QAccessible>
#include <QElapsedTimer>
#include <algorithm>
#include <cstdlib>
#include <limits>
#include <unordered_set>
#include <optional>
#include <stdexcept>

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

    return matchesIndex(index);
}

bool TransactionFilterProxy::matchesIndex(const QModelIndex& index) const
{
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

bool TransactionFilterProxy::matchesScan(const TransactionScanRow& scan, const TransactionRowSource& source, int row, bool ignore_status) const
{
    if (!ignore_status && !showInactive && scan.status == TransactionStatus::Conflicted) return false;
    if (!(TYPE(scan.type) & typeFilter)) return false;
    if (scan.watchonly && watchOnlyFilter == WatchOnlyFilter_No) return false;
    if (!scan.watchonly && watchOnlyFilter == WatchOnlyFilter_Yes) return false;
    if (dateFrom || dateTo) {
        const qint64 ms = scan.time * 1000;
        if (dateFrom && ms < dateFrom->toMSecsSinceEpoch()) return false;
        if (dateTo && ms > dateTo->toMSecsSinceEpoch()) return false;
    }
    if (!m_search_string.isEmpty()) {
        bool supported{false};
        const bool found = source.transactionMatchesText(row, m_search_string, supported);
        if (!supported || !found) return false;
    }
    return llabs(scan.amount) >= minAmount;
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


TransactionPresentationProxy::TransactionPresentationProxy(QObject* parent, int limit)
    : QAbstractProxyModel(parent), m_limit(limit)
{
    Q_ASSERT(limit >= -1 && limit <= 5);
    m_filter.setSortRole(Qt::EditRole);
    m_timer.setSingleShot(true);
    connect(&m_timer, &QTimer::timeout, this, &TransactionPresentationProxy::runSlice);
}

void TransactionPresentationProxy::clearProjection(DiagnosticChange reason)
{
    Q_EMIT diagnosticInvalidated(reason);
    m_timer.stop();
    beginResetModel();
    if (m_keep_projection) {
        discardStash();
        ensureReverse();
        m_stash_rows = std::move(m_rows);
        m_stash_reverse = std::move(m_reverse);
        m_rows.clear();
        m_stash_valid = true;
        m_stash_config = m_config_epoch;
        m_stash_version = m_source_version;
        m_stash_source = m_bound_source;
    } else {
        // Re-activation of the same source may still restore a kept projection; any other change drops it.
        if (reason != DiagnosticChange::ACTIVATION) discardStash();
        if (!m_rows.empty()) m_retired_rows.push_back(std::move(m_rows));
        if (!m_reverse.empty()) m_retired_maps.push_back(std::move(m_reverse));
    }
    m_visible_rows = 0;
    m_display = Display::FINAL;
    m_ready = false;
    m_abort = true;
    m_restart = false;
    m_phase = Phase::RETIRE;
    m_work = true;
    m_timer.start(0);
    endResetModel();
}

void TransactionPresentationProxy::setSourceModel(QAbstractItemModel* source)
{
    setSourceModelFor(source, DiagnosticChange::SOURCE_BINDING);
}

void TransactionPresentationProxy::setSourceModelFor(QAbstractItemModel* source, DiagnosticChange reason)
{
    auto* locator = dynamic_cast<TransactionRowSource*>(source);
    if (source && !locator) throw std::invalid_argument("Transaction projection requires a bounded row locator");
    for (const auto& connection : m_connections) disconnect(connection);
    m_connections.clear();
    for (const auto& connection : m_dormant) disconnect(connection);
    m_dormant.clear();
    if (reason != DiagnosticChange::ACTIVATION) m_fast = false;
    clearProjection(reason);
    m_bound_source = source;
    m_locator = m_active ? locator : nullptr;
    QAbstractProxyModel::setSourceModel(m_active ? source : nullptr);
    if (!m_active) watchDormant();
    attach();
}

void TransactionPresentationProxy::watchDormant()
{
    auto* source = m_bound_source.data();
    if (!source || !m_stash_valid) return;
    const auto bump = [this] { ++m_source_version; };
    m_dormant.push_back(connect(source, &QAbstractItemModel::rowsInserted, this, bump));
    m_dormant.push_back(connect(source, &QAbstractItemModel::rowsRemoved, this, bump));
    m_dormant.push_back(connect(source, &QAbstractItemModel::rowsMoved, this, bump));
    m_dormant.push_back(connect(source, &QAbstractItemModel::layoutChanged, this, bump));
    m_dormant.push_back(connect(source, &QAbstractItemModel::modelReset, this, bump));
    m_dormant.push_back(connect(source, &QObject::destroyed, this, bump));
    m_dormant.push_back(connect(source, &QAbstractItemModel::dataChanged, this,
        [this](const QModelIndex&, const QModelIndex&, const QVector<int>& roles) { if (dependencyChange(roles, /*tie_sensitive=*/false)) ++m_source_version; }));
}

void TransactionPresentationProxy::discardStash()
{
    m_stash_valid = false;
    Rows().swap(m_stash_rows);
    m_stash_reverse.clear();
    m_stash_source.clear();
}

bool TransactionPresentationProxy::restoreStash()
{
    if (!m_stash_valid) return false;
    if (!m_active || m_stash_source != sourceModel() || m_stash_version != m_source_version || m_stash_config != m_config_epoch) {
        discardStash();
        return false;
    }
    beginResetModel();
    m_rows = std::move(m_stash_rows);
    m_reverse = std::move(m_stash_reverse);
    m_reverse_valid = true;
    m_visible_rows = static_cast<int>(m_rows.size());
    m_display = Display::FINAL;
    m_ready = true;
    m_stash_valid = false;
    m_stash_source.clear();
    endResetModel();
    Q_EMIT projectionReady();
    return true;
}

bool TransactionPresentationProxy::dependencyChange(const QVector<int>& roles, bool tie_sensitive) const
{
    const bool key_roles = roles.empty() || roles.contains(TransactionTableModel::TypeRole) ||
        roles.contains(TransactionTableModel::DateRole) || roles.contains(TransactionTableModel::WatchonlyRole) ||
        roles.contains(TransactionTableModel::AddressRole) || roles.contains(TransactionTableModel::TxHashRole) ||
        roles.contains(TransactionTableModel::LabelRole) || roles.contains(TransactionTableModel::AmountRole);
    const bool status_roles = roles.contains(Qt::EditRole) || roles.contains(TransactionTableModel::StatusRole);
    // The Status column and a status-dependent filter follow confirmations. The Date column uses the status to order
    // rows of the same second: a live projection keeps those ties exact (the source now announces only rows whose
    // status can change, so this is a handful of rows), while a dormant one accepts stale ties until it is rebuilt.
    // Other sources report EditRole for any key change.
    return key_roles || (status_roles && (!m_fast || !m_filter.showsInactive() || m_column == TransactionTableModel::Status ||
                                          (tie_sensitive && m_column == TransactionTableModel::Date)));
}

void TransactionPresentationProxy::setActive(bool active)
{
    if (m_active == active) return;
    m_keep_projection = !active && m_limit < 0 && m_fast && m_ready && !m_restart && m_display == Display::FINAL &&
        m_visible_rows == static_cast<int>(m_rows.size());
    m_active = active;
    setSourceModelFor(m_bound_source.data(), DiagnosticChange::ACTIVATION);
    m_keep_projection = false;
}

void TransactionPresentationProxy::attach()
{
    auto* source = sourceModel();
    if (!source) return;
    m_connections.push_back(connect(source, &QAbstractItemModel::rowsInserted, this,
        [this](const QModelIndex&, int first, int last) {
            // A top-five scan can consume newly appended initial-history rows.
            if (m_limit >= 0 && m_work && !m_abort && m_phase == Phase::SCAN && first >= m_cursor) {
                Q_EMIT diagnosticInvalidated(DiagnosticChange::SOURCE_ROWS);
                return;
            }
            if (incrementalReady() || !m_pending_inserts.empty()) {
                Q_EMIT diagnosticInvalidated(DiagnosticChange::SOURCE_ROWS, /*ready=*/true);
                for (int row = first; row <= last; ++row) {
                    const auto identity = m_locator->transactionIdentity(row);
                    if (identity.id != 0) m_pending_inserts.push_back(identity);
                }
                scheduleInsertFlush();
                return;
            }
            Q_EMIT diagnosticInvalidated(DiagnosticChange::SOURCE_ROWS);
            continueRebuild();
        }));
    m_connections.push_back(connect(source, &QAbstractItemModel::rowsAboutToBeRemoved, this, [this](const QModelIndex&, int first, int last) {
        m_removals_captured = captureRemovals(first, last);
        Q_EMIT diagnosticInvalidated(DiagnosticChange::SOURCE_ROWS, m_removals_captured);
        if (m_removals_captured) return;
        m_ready = false;
        Q_EMIT projectionStarted();
    }));
    m_connections.push_back(connect(source, &QAbstractItemModel::rowsRemoved, this, [this] {
        if (m_removals_captured) {
            m_removals_captured = false;
            QElapsedTimer applying;
            applying.start();
            if (applyRemovals()) { ++m_stats.incremental_batches; m_stats.incremental_ns += applying.nsecsElapsed(); return; }
        }
        requestRebuildFor(DiagnosticChange::SOURCE_ROWS);
    }));
    m_connections.push_back(connect(source, &QAbstractItemModel::rowsMoved, this, [this] { requestRebuildFor(DiagnosticChange::SOURCE_ROWS); }));
    m_connections.push_back(connect(source, &QAbstractItemModel::layoutChanged, this, [this] { requestRebuildFor(DiagnosticChange::SOURCE_LAYOUT); }));
    m_connections.push_back(connect(source, &QAbstractItemModel::headerDataChanged, this, &QAbstractItemModel::headerDataChanged));
    m_connections.push_back(connect(source, &QObject::destroyed, this, [this] { m_locator = nullptr; clearProjection(DiagnosticChange::SOURCE_DESTROYED); }));
    m_connections.push_back(connect(source, &QAbstractItemModel::modelAboutToBeReset, this, [this] { clearProjection(); }));
    m_connections.push_back(connect(source, &QAbstractItemModel::modelReset, this, &TransactionPresentationProxy::requestRebuild));
    m_connections.push_back(connect(source, &QAbstractItemModel::dataChanged, this,
        [this](const QModelIndex& first, const QModelIndex& last, const QVector<int>& roles) {
            const bool dependency_changed = dependencyChange(roles);
            Q_EMIT diagnosticInvalidated(DiagnosticChange::SOURCE_DATA, !dependency_changed && isReady());
            if (!first.isValid() || !last.isValid()) return;
            if ((incrementalReady() || !m_pending_updates.empty()) && last.row() - first.row() + 1 <= 512 &&
                m_pending_updates.size() + static_cast<size_t>(last.row() - first.row() + 1) <= 512) {
                if (m_pending_updates.empty()) { m_pending_first_column = first.column(); m_pending_last_column = last.column(); m_pending_roles.clear(); m_pending_dependency = false; }
                m_pending_first_column = std::min(m_pending_first_column, first.column());
                m_pending_last_column = std::max(m_pending_last_column, last.column());
                for (int role : roles) if (!m_pending_roles.contains(role)) m_pending_roles.push_back(role);
                if (roles.empty()) { m_pending_roles.clear(); m_pending_dependency = true; }
                m_pending_dependency = m_pending_dependency || dependency_changed;
                for (int row = first.row(); row <= last.row(); ++row) {
                    const auto identity = m_locator->transactionIdentity(row);
                    if (identity.id != 0) m_pending_updates.push_back(identity);
                }
                scheduleInsertFlush();
                return;
            }
            // Too much at once for an incremental update: whatever is waiting is covered by the rebuild below.
            m_pending_updates.clear();
            if (!m_rows.empty()) Q_EMIT dataChanged(index(0, first.column()), index(rowCount() - 1, last.column()), roles);
            if (!dependency_changed) return;
            if (m_work) { ++m_stats.restarts; m_restart = true; m_ready = false; Q_EMIT projectionStarted(); }
            else continueRebuild();
        }));
    // The source/activation boundary already invalidated the diagnostic epoch.
    if (restoreStash()) return;
    continueRebuild();
}

void TransactionPresentationProxy::requestRebuild()
{
    requestRebuildFor(DiagnosticChange::SOURCE_RESET);
}

void TransactionPresentationProxy::requestRebuildFor(DiagnosticChange reason)
{
    if (reason == DiagnosticChange::FILTER || reason == DiagnosticChange::SORT) ++m_config_epoch;
    Q_EMIT diagnosticInvalidated(reason);
    continueRebuild();
}

void TransactionPresentationProxy::continueRebuild()
{
    if (!m_active || !sourceModel()) return;
    m_ready = false;
    Q_EMIT projectionStarted();
    if (m_work) {
        ++m_stats.restarts;
        m_abort = true;
        m_restart = true;
        m_timer.start(0);
        return;
    }
    ++m_stats.rebuilds;
    m_pending_inserts.clear();
    m_removals_captured = false;
    ensureReverse();
    const auto count = static_cast<size_t>(sourceModel()->rowCount());
    const auto retained = m_limit >= 0 ? static_cast<size_t>(m_limit + 1) : count;
    m_entries.reserve(retained);
    m_order.reserve(retained);
    m_merge.reserve(retained);
    m_next_rows.reserve(retained);
    m_next_to_interim.reserve(retained);
    m_interim.reserve(retained);
    m_added.reserve(retained);
    m_survivors.reserve(m_rows.size());
    m_removed.reserve(m_rows.size());
    m_reordered.reserve(m_rows.size());
    m_old_to_reordered.reserve(m_rows.size());
    m_fast = false;
    m_chunk = 1;
    if (count > 0 && m_locator) {
        TransactionScanRow probe;
        if (m_locator->transactionScanRow(0, m_column, probe)) {
            m_fast = true;
            m_fast_key = probe.key;
            m_chunk = 256;
        }
    }
    m_work = true;
    m_abort = false;
    m_restart = false;
    m_cursor = 0;
    m_width = 1;
    m_left = m_a = m_b = m_mid = m_end = m_plan_cursor = 0;
    m_phase = Phase::SCAN;
    m_timer.start(0);
}

bool TransactionPresentationProxy::less(const Entry& left, const Entry& right) const
{
    if (m_fast) {
        const Entry& x = m_sort_order == Qt::AscendingOrder ? left : right;
        const Entry& y = m_sort_order == Qt::AscendingOrder ? right : left;
        switch (m_fast_key) {
        case TransactionScanRow::Key::NUMBER: return x.number < y.number;
        case TransactionScanRow::Key::DATE: return x.number != y.number ? x.number < y.number : x.text < y.text;
        case TransactionScanRow::Key::TEXT: return x.text < y.text;
        }
    }
    const auto& a = m_sort_order == Qt::AscendingOrder ? left.key : right.key;
    const auto& b = m_sort_order == Qt::AscendingOrder ? right.key : left.key;
    switch (a.userType()) {
    case QMetaType::Int: return a.toInt() < b.toInt();
    case QMetaType::UInt: return a.toUInt() < b.toUInt();
    case QMetaType::LongLong: return a.toLongLong() < b.toLongLong();
    case QMetaType::ULongLong: return a.toULongLong() < b.toULongLong();
    case QMetaType::Double: return a.toDouble() < b.toDouble();
    case QMetaType::QDate: return a.toDate() < b.toDate();
    case QMetaType::QTime: return a.toTime() < b.toTime();
    case QMetaType::QDateTime: return a.toDateTime() < b.toDateTime();
    default: return QString::compare(a.toString(), b.toString(), m_filter.sortCaseSensitivity()) < 0;
    }
}

void TransactionPresentationProxy::runSlice()
{
    if (m_abort) m_phase = Phase::RETIRE;
    if (m_phase != Phase::RETIRE && (!m_active || !sourceModel() || !m_locator)) return;
    constexpr int MAX_OPERATIONS = 128;
    // Fast sources do bounded chunks of work per operation, so only the clock limits a slice.
    const int max_operations = m_fast ? std::numeric_limits<int>::max() : MAX_OPERATIONS;
    const int chunk = m_chunk;
    QElapsedTimer elapsed;
    elapsed.start();
    int operations{0};
    const auto finish_scan = [this] {
        if (m_limit >= 0) {
            for (size_t i = 0; i < m_entries.size(); ++i) m_order.push_back(i);
            m_phase = Phase::MAP;
        } else {
            m_phase = Phase::SORT;
            m_width = 1;
            m_left = m_end = 0;
            m_plan_cursor = 0;
            m_presort = m_fast;
        }
    };
    const auto add_entry = [this](Entry&& entry) {
        if (m_limit >= 0) {
            const auto pos = std::upper_bound(m_entries.begin(), m_entries.end(), entry,
                [this](const auto& a, const auto& b) { return less(a, b); });
            m_entries.insert(pos, std::move(entry));
            if (static_cast<int>(m_entries.size()) > m_limit) m_entries.pop_back();
        } else {
            m_entries.push_back(std::move(entry));
            m_order.push_back(m_order.size());
        }
    };
    int64_t op_started_ns = elapsed.nsecsElapsed();
    Phase op_phase = m_phase;
    const auto note_op = [&] {
        const int64_t now_ns = elapsed.nsecsElapsed();
        auto& longest = m_stats.max_op_ns[static_cast<int>(op_phase)];
        longest = std::max<int64_t>(longest, now_ns - op_started_ns);
        op_started_ns = now_ns;
        op_phase = m_phase;
    };
    while (operations < max_operations && elapsed.elapsed() < 4) {
        ++operations;
        if (operations > 1) note_op();
        if (m_phase == Phase::SCAN) {
            if (m_fast) {
                const int rows = sourceModel()->rowCount();
                const bool fold = m_filter.sortCaseSensitivity() == Qt::CaseInsensitive;
                // Refreshing a status takes the wallet lock: keep such a chunk small so a slice stays near its budget.
                const int scan_chunk = (!m_filter.showsInactive() || m_column == TransactionTableModel::Status || m_column == TransactionTableModel::Date) ? 32 : chunk;
                for (int k = 0; k < scan_chunk && m_cursor < rows; ++k) {
                    const int row = m_cursor++;
                    // A sort key or filter that follows the status needs a fresh status, whether or not the row was ever
                    // displayed. A bounded top-K scan refreshes only the rows that could enter the result; a full scan
                    // asks for every row (the source skips rows whose status can no longer change).
                    const bool status_filter = !m_filter.showsInactive();
                    const bool status_key = m_column == TransactionTableModel::Status || m_column == TransactionTableModel::Date;
                    const auto make_entry = [&](TransactionScanRow& scan) {
                        Entry entry;
                        entry.source = scan.identity;
                        entry.number = scan.number;
                        if (scan.key != TransactionScanRow::Key::NUMBER) entry.text = fold ? scan.text.toCaseFolded() : std::move(scan.text);
                        return entry;
                    };
                    TransactionScanRow scan;
                    scan.refresh_status = (status_filter || status_key) && m_limit < 0;
                    if (!m_locator->transactionScanRow(row, m_column, scan)) continue;
                    ++m_stats.rows_scanned;
                    if ((status_filter || status_key) && m_limit >= 0) {
                        if (!m_filter.matchesScan(scan, *m_locator, row, /*ignore_status=*/true)) continue;
                        Entry tentative = make_entry(scan);
                        // Rows that tie with the boundary on the primary key can be ordered by their fresh status.
                        const bool boundary = !m_entries.empty() && (!less(m_entries.back(), tentative) ||
                            (m_fast_key == TransactionScanRow::Key::DATE && tentative.number == m_entries.back().number));
                        if (static_cast<int>(m_entries.size()) >= m_limit && !boundary && !less(tentative, m_entries.back())) continue;
                        TransactionScanRow fresh;
                        fresh.refresh_status = true;
                        if (!m_locator->transactionScanRow(row, m_column, fresh) || !m_filter.matchesScan(fresh, *m_locator, row)) continue;
                        add_entry(make_entry(fresh));
                        continue;
                    }
                    if (!m_filter.matchesScan(scan, *m_locator, row)) continue;
                    add_entry(make_entry(scan));
                }
                if (m_cursor >= rows) finish_scan();
                continue;
            }
            if (m_cursor < sourceModel()->rowCount()) {
                const auto row = sourceModel()->index(m_cursor++, 0);
                if (!m_filter.matchesIndex(row)) continue;
                Entry entry{m_locator->transactionIdentity(row.row()), row.sibling(row.row(), m_column).data(m_filter.sortRole())};
                add_entry(std::move(entry));
                continue;
            }
            finish_scan();
        } else if (m_phase == Phase::SORT) {
            const size_t size = m_order.size();
            if (m_presort) {
                // Order short runs in place; the merge passes then start from runs, not single rows.
                constexpr size_t RUN = 64;
                for (int k = 0; k < chunk / 16 + 1 && m_plan_cursor < size; ++k) {
                    const size_t last = std::min(m_plan_cursor + RUN, size);
                    std::stable_sort(m_order.begin() + m_plan_cursor, m_order.begin() + last,
                        [this](size_t a, size_t b) { return less(m_entries[a], m_entries[b]); });
                    m_plan_cursor = last;
                }
                if (m_plan_cursor >= size) { m_presort = false; m_plan_cursor = 0; m_width = RUN; m_left = m_end = 0; }
                continue;
            }
            for (int k = 0; k < chunk; ++k) {
                if (m_width >= size) { m_phase = Phase::MAP; break; }
                if (m_left >= size) {
                    m_order.swap(m_merge); m_merge.clear(); m_width *= 2;
                    m_left = m_end = 0;
                    continue;
                }
                if (m_left == m_end) {
                    m_a = m_left; m_mid = m_b = std::min(m_left + m_width, size);
                    m_end = std::min(m_mid + m_width, size);
                }
                if (m_a < m_mid && (m_b == m_end || !less(m_entries[m_order[m_b]], m_entries[m_order[m_a]]))) m_merge.push_back(m_order[m_a++]);
                else m_merge.push_back(m_order[m_b++]);
                if (m_a == m_mid && m_b == m_end) m_left = m_end;
            }
        } else if (m_phase == Phase::MAP) {
            if (m_plan_cursor == 0) m_next_reverse.reserve(m_order.size());
            for (int k = 0; k < chunk; ++k) {
                if (m_plan_cursor >= m_order.size()) { m_plan_cursor = 0; m_phase = Phase::OLD_PLAN; break; }
                const auto key = m_entries[m_order[m_plan_cursor++]].source;
                if (!m_next_reverse.insert(key.id, static_cast<int>(m_next_rows.size()))) throw std::logic_error("Duplicate GUI row identity");
                m_next_rows.push_back(key);
                m_next_to_interim.push_back(-1);
            }
        } else if (m_phase == Phase::OLD_PLAN) {
            for (int k = 0; k < chunk; ++k) {
                if (m_plan_cursor >= m_rows.size()) { m_plan_cursor = 0; m_phase = Phase::ADD_PLAN; break; }
                const int row = m_plan_cursor++;
                (m_next_reverse.contains(m_rows[row].id) ? m_survivors : m_removed).push_back(row);
                m_old_to_reordered.push_back(-1);
            }
        } else if (m_phase == Phase::ADD_PLAN) {
            for (int k = 0; k < chunk; ++k) {
                if (m_plan_cursor >= m_next_rows.size()) { m_plan_cursor = 0; m_phase = Phase::REORDER_PLAN; break; }
                const int row = m_plan_cursor++;
                if (!m_reverse.contains(m_next_rows[row].id)) m_added.push_back(row);
            }
        } else if (m_phase == Phase::REORDER_PLAN) {
            for (int k = 0; k < chunk; ++k) {
                if (m_plan_cursor >= m_rows.size()) { m_plan_cursor = 0; m_phase = Phase::INTERIM_PLAN; break; }
                const int old = m_plan_cursor < m_survivors.size() ? m_survivors[m_plan_cursor] : m_removed[m_plan_cursor - m_survivors.size()];
                m_old_to_reordered[old] = m_plan_cursor++;
                m_reordered.push_back(old);
            }
        } else if (m_phase == Phase::INTERIM_PLAN) {
            for (int k = 0; k < chunk; ++k) {
                if (m_plan_cursor >= m_next_rows.size()) { m_phase = Phase::PUBLISH; break; }
                const int next = m_plan_cursor < m_survivors.size() ? m_next_reverse.find(m_rows[m_survivors[m_plan_cursor]].id) : m_added[m_plan_cursor - m_survivors.size()];
                m_next_to_interim[next] = m_plan_cursor++;
                m_interim.push_back(next);
            }
        } else if (m_phase == Phase::PUBLISH) {
            publish();
            m_phase = Phase::RETIRE;
        } else {
            // Release in bounded pieces: entries own strings, everything else is one block.
            const size_t pieces = m_fast ? 1024 : 1;
            if (!m_entries.empty()) {
                for (size_t k = 0; k < pieces && !m_entries.empty(); ++k) m_entries.pop_back();
            } else if (!m_next_rows.empty()) {
                for (size_t k = 0; k < pieces && !m_next_rows.empty(); ++k) m_next_rows.pop_back();
            } else if (!m_next_reverse.empty()) {
                m_next_reverse.clear();
            } else if (!m_retired_rows.empty()) {
                if (!m_retired_rows.front().empty()) { for (size_t k = 0; k < pieces && !m_retired_rows.front().empty(); ++k) m_retired_rows.front().pop_back(); }
                else m_retired_rows.pop_front();
            } else if (!m_retired_maps.empty()) {
                m_retired_maps.pop_front();
            } else {
                m_order.clear(); m_merge.clear(); m_survivors.clear(); m_removed.clear(); m_added.clear();
                m_reordered.clear(); m_old_to_reordered.clear(); m_interim.clear(); m_next_to_interim.clear();
                m_work = false;
                ++m_stats.slices;
                m_stats.max_slice_ns = std::max<int64_t>(m_stats.max_slice_ns, elapsed.nsecsElapsed());
                Q_EMIT sliceCompleted(std::min(operations, MAX_OPERATIONS));
                if (m_restart && m_active && sourceModel()) continueRebuild();
                return;
            }
        }
    }
    // An initial top-five preview uses the same complete publication plan on a
    // bounded (at most five-row) source slice; continue scanning on the next
    // queued generation. Full history readiness is separate in the page.
    if (m_limit >= 0 && m_phase == Phase::SCAN && !m_abort && m_rows.empty() && !m_entries.empty()) {
        for (const auto& entry : m_entries) {
            m_next_reverse.insert(entry.source.id, static_cast<int>(m_next_rows.size()));
            m_next_rows.push_back(entry.source);
        }
        beginInsertRows({}, 0, m_next_rows.size() - 1);
        m_rows.swap(m_next_rows); m_reverse.swap(m_next_reverse);
        m_reverse_valid = true;
        m_visible_rows = m_rows.size();
        endInsertRows();
        // Entries remain the bounded top-five working set; publication planning
        // starts from these now-valid preview identities when scanning ends.
    }
    note_op();
    ++m_stats.slices;
    m_stats.max_slice_ns = std::max<int64_t>(m_stats.max_slice_ns, elapsed.nsecsElapsed());
    Q_EMIT sliceCompleted(std::min(operations, MAX_OPERATIONS));
    m_timer.start(0);
}

TransactionRowIdentity TransactionPresentationProxy::identityAt(int row) const
{
    if (row < 0 || row >= m_visible_rows) return {};
    if (m_display == Display::REORDERED) return m_rows[m_reordered[row]];
    if (m_display == Display::INTERIM) return m_next_rows[m_interim[row]];
    return row < static_cast<int>(m_rows.size()) ? m_rows[row] : TransactionRowIdentity{};
}

QModelIndex TransactionPresentationProxy::mapIdentity(const TransactionRowIdentity& identity, int column) const
{
    if (m_display == Display::FINAL) ensureReverse();
    const auto& reverse = m_display == Display::INTERIM ? m_next_reverse : m_reverse;
    int row = reverse.find(identity.id);
    if (row < 0) return {};
    if (m_display == Display::REORDERED) row = m_old_to_reordered[row];
    if (m_display == Display::INTERIM) row = m_next_to_interim[row];
    return row >= 0 && row < m_visible_rows && identityAt(row) == identity ? index(row, column) : QModelIndex{};
}

void TransactionPresentationProxy::changeLayout(Display display)
{
    // See insertKeyed: drop an attached accessibility client's per-cell state before it is remapped one by one.
    if (display == Display::FINAL && layoutUpdates()) Q_EMIT structureAboutToChange();
    QElapsedTimer step;
    step.start();
    Q_EMIT layoutAboutToBeChanged();
    m_stats.max_layout_ns[0] = std::max<int64_t>(m_stats.max_layout_ns[0], step.nsecsElapsed());
    step.restart();
    const auto before = persistentIndexList();
    m_stats.persistent_indexes = std::max<int64_t>(m_stats.persistent_indexes, before.size());
    // Persistent indexes come in huge numbers when an accessibility client walks the table (one per cell), so remap
    // per distinct row, not per index: resolve each old row's identity once, and each identity's new row once.
    std::vector<int> slot_of_row(static_cast<size_t>(std::max(m_visible_rows, 0)), -1);
    Rows identities;
    std::vector<int> slots;
    slots.reserve(before.size());
    for (const auto& index : before) {
        const int row = index.row();
        if (row < 0 || row >= static_cast<int>(slot_of_row.size())) { slots.push_back(-1); continue; }
        if (slot_of_row[row] < 0) {
            slot_of_row[row] = static_cast<int>(identities.size());
            identities.push_back(identityAt(row));
        }
        slots.push_back(slot_of_row[row]);
    }
    if (display == Display::FINAL) {
        if (!m_rows.empty()) m_retired_rows.push_back(std::move(m_rows));
        if (!m_reverse.empty()) m_retired_maps.push_back(std::move(m_reverse));
        m_rows.swap(m_next_rows); m_reverse.swap(m_next_reverse);
        m_reverse_valid = true;
        m_visible_rows = static_cast<int>(m_rows.size());
    }
    m_display = display;
    std::vector<int> new_rows(identities.size(), -1);
    for (size_t i = 0; i < identities.size(); ++i) {
        const QModelIndex mapped = mapIdentity(identities[i], 0);
        if (mapped.isValid()) new_rows[i] = mapped.row();
    }
    QModelIndexList after;
    after.reserve(before.size());
    for (int i = 0; i < before.size(); ++i) {
        const int new_row = slots[i] >= 0 ? new_rows[slots[i]] : -1;
        after.append(new_row >= 0 ? index(new_row, before[i].column()) : QModelIndex{});
    }
    changePersistentIndexList(before, after);
    m_stats.max_layout_ns[1] = std::max<int64_t>(m_stats.max_layout_ns[1], step.nsecsElapsed());
    step.restart();
    Q_EMIT layoutChanged();
    m_stats.max_layout_ns[2] = std::max<int64_t>(m_stats.max_layout_ns[2], step.nsecsElapsed());
}

void TransactionPresentationProxy::publish()
{
    // With an accessibility client holding per-cell state, each row insert/remove signal makes Qt visit every cell
    // (seconds at 200,000 rows): announce a changed membership as the single layout change that a reorder already is.
    const bool single_layout_change = (!m_removed.empty() || !m_added.empty()) && m_fast && m_limit < 0 && layoutUpdates();
    if (!single_layout_change && !m_removed.empty()) {
        changeLayout(Display::REORDERED);
        beginRemoveRows({}, m_survivors.size(), m_visible_rows - 1);
        m_visible_rows = m_survivors.size();
        endRemoveRows();
    }
    if (!single_layout_change && !m_added.empty()) {
        beginInsertRows({}, m_visible_rows, m_next_rows.size() - 1);
        m_display = Display::INTERIM;
        m_visible_rows = m_next_rows.size();
        endInsertRows();
    }
    changeLayout(Display::FINAL);
    m_ready = !m_restart;
    if (m_ready) Q_EMIT projectionReady();
}

// ---- Incremental maintenance -------------------------------------------------------------------------------------
//
// The projection is ordered by (sort key, source order), where source order is the table model's own row order: its
// hash, then the GUI identity allocated in presentation order. That total order is what a full rebuild produces, so a
// row can be placed by binary search and the result stays identical to a rebuild.

bool TransactionPresentationProxy::layoutUpdates() const { return m_layout_updates.value_or(QAccessible::isActive()); }

void TransactionPresentationProxy::ensureReverse() const
{
    if (m_reverse_valid) return;
    m_reverse.clear();
    m_reverse.reserve(m_rows.size());
    for (size_t i = 0; i < m_rows.size(); ++i) m_reverse.insert(m_rows[i].id, static_cast<int>(i));
    m_reverse_valid = true;
}

bool TransactionPresentationProxy::incrementalReady() const
{
    return m_active && m_fast && m_locator && sourceModel() && m_ready && !m_restart && !m_abort &&
           m_display == Display::FINAL && m_visible_rows == static_cast<int>(m_rows.size()) &&
           (!m_work || m_phase == Phase::RETIRE);
}

bool TransactionPresentationProxy::keyLess(const KeyedRow& x, const KeyedRow& y) const
{
    switch (m_fast_key) {
    case TransactionScanRow::Key::NUMBER: return x.number < y.number;
    case TransactionScanRow::Key::DATE: return x.number != y.number ? x.number < y.number : x.text < y.text;
    case TransactionScanRow::Key::TEXT: return x.text < y.text;
    }
    return false;
}

bool TransactionPresentationProxy::rowPrecedes(const KeyedRow& a, const KeyedRow& b) const
{
    const bool ascending = m_sort_order == Qt::AscendingOrder;
    const KeyedRow& first = ascending ? a : b;
    const KeyedRow& second = ascending ? b : a;
    if (keyLess(first, second)) return true;
    if (keyLess(second, first)) return false;
    if (a.identity.hash != b.identity.hash) return a.identity.hash < b.identity.hash;
    return a.identity.id < b.identity.id;
}

TransactionPresentationProxy::KeyedRow TransactionPresentationProxy::keyedFrom(const TransactionScanRow& scan) const
{
    KeyedRow row;
    row.identity = scan.identity;
    row.number = scan.number;
    if (scan.key != TransactionScanRow::Key::NUMBER) {
        row.text = m_filter.sortCaseSensitivity() == Qt::CaseInsensitive ? scan.text.toCaseFolded() : scan.text;
    }
    return row;
}

bool TransactionPresentationProxy::existingKey(const TransactionRowIdentity& identity, KeyedRow& out) const
{
    const auto captured = m_removal_lookup.find(identity.id);
    if (captured != m_removal_lookup.end()) {
        out = *captured->second;
        return true;
    }
    TransactionScanRow scan;
    if (!m_locator->transactionScanRowById(identity, m_column, scan)) return false;
    out = keyedFrom(scan);
    return true;
}

//! First position whose row does not precede `item`, among the rows whose positions are not in `skip` (ascending).
//! The returned value counts only rows that are not skipped. ok=false if a probed row can no longer be read from the
//! source (the caller then falls back to a rebuild).
int TransactionPresentationProxy::lowerBoundPosition(const KeyedRow& item, const std::vector<int>& skip, bool& ok) const
{
    int low = 0;
    int high = static_cast<int>(m_rows.size()) - static_cast<int>(skip.size());
    KeyedRow probe;
    while (low < high) {
        const int mid = low + (high - low) / 2;
        const int real = realPosition(mid, skip);
        if (!existingKey(m_rows[static_cast<size_t>(real)], probe)) { ok = false; return 0; }
        if (rowPrecedes(probe, item)) low = mid + 1;
        else high = mid;
    }
    return low;
}

//! The row index of the `virtual_index`-th row that is not in `skip` (ascending positions).
int TransactionPresentationProxy::realPosition(int virtual_index, const std::vector<int>& skip)
{
    int real = virtual_index;
    for (const int skipped : skip) {
        if (skipped <= real) ++real;
        else break;
    }
    return real;
}

int TransactionPresentationProxy::lowerBoundPosition(const KeyedRow& item, int skip, bool& ok) const
{
    return lowerBoundPosition(item, skip >= 0 ? std::vector<int>{skip} : std::vector<int>{}, ok);
}

//! Position of each identity in the projection (-1 if absent), in one pass over the rows.
std::vector<int> TransactionPresentationProxy::positionsOf(const std::vector<TransactionRowIdentity>& identities) const
{
    std::vector<int> result(identities.size(), -1);
    RowIdIndex wanted;
    wanted.reserve(identities.size());
    for (size_t i = 0; i < identities.size(); ++i) wanted.insert(identities[i].id, static_cast<int>(i));
    size_t found = 0;
    for (size_t row = 0; row < m_rows.size() && found < identities.size(); ++row) {
        const int slot = wanted.find(m_rows[row].id);
        if (slot >= 0 && result[static_cast<size_t>(slot)] < 0) { result[static_cast<size_t>(slot)] = static_cast<int>(row); ++found; }
    }
    return result;
}

void TransactionPresentationProxy::scheduleInsertFlush()
{
    if (m_flush_scheduled) return;
    m_flush_scheduled = true;
    // Notifications for one block arrive back to back; applying them together is one shift of the rows, not one each.
    QTimer::singleShot(10, this, [this] { flushInserts(); });
}

//! Insert already ordered or unordered rows; all positions are computed before the first insertion and applied from the
//! back, so each contiguous run is one beginInsertRows/endInsertRows pair.
bool TransactionPresentationProxy::insertKeyed(std::vector<KeyedRow> items)
{
    std::sort(items.begin(), items.end(), [this](const KeyedRow& a, const KeyedRow& b) { return rowPrecedes(a, b); });
    std::vector<int> positions;
    positions.reserve(items.size());
    std::vector<KeyedRow> fresh;
    fresh.reserve(items.size());
    for (auto& item : items) {
        bool ok{true};
        const int position = lowerBoundPosition(item, -1, ok);
        if (!ok) return false;
        if (position < static_cast<int>(m_rows.size()) && m_rows[static_cast<size_t>(position)] == item.identity) continue; // already there
        if (m_limit >= 0 && position >= m_limit) continue;                // cannot enter the top rows
        positions.push_back(position);
        fresh.push_back(std::move(item));
    }
    if (m_limit < 0 && !fresh.empty() && layoutUpdates()) {
        // An accessibility client that has walked the table holds an interface and a persistent index per cell, and Qt
        // revisits every one of them for each row-insert signal (over a second at 50,000 rows). One layout change
        // invalidates them once instead.
        Q_EMIT structureAboutToChange();
        Q_EMIT layoutAboutToBeChanged();
        const auto before = persistentIndexList();
        std::vector<TransactionRowIdentity> merged;
        merged.reserve(m_rows.size() + fresh.size());
        size_t next = 0;
        for (size_t row = 0; row <= m_rows.size(); ++row) {
            while (next < fresh.size() && positions[next] == static_cast<int>(row)) merged.push_back(fresh[next++].identity);
            if (row < m_rows.size()) merged.push_back(m_rows[row]);
        }
        m_rows.swap(merged);
        m_visible_rows = static_cast<int>(m_rows.size());
        m_reverse_valid = false;
        QModelIndexList after;
        after.reserve(before.size());
        for (const auto& old_index : before) {
            const int shift = static_cast<int>(std::upper_bound(positions.begin(), positions.end(), old_index.row()) - positions.begin());
            after.append(index(old_index.row() + shift, old_index.column()));
        }
        changePersistentIndexList(before, after);
        Q_EMIT layoutChanged();
        return true;
    }
    for (size_t end = positions.size(); end > 0;) {
        size_t begin = end - 1;
        while (begin > 0 && positions[begin - 1] == positions[end - 1]) --begin;
        const int at = positions[end - 1];
        const int count = static_cast<int>(end - begin);
        beginInsertRows({}, at, at + count - 1);
        std::vector<TransactionRowIdentity> run;
        run.reserve(static_cast<size_t>(count));
        for (size_t k = begin; k < end; ++k) run.push_back(fresh[k].identity);
        m_rows.insert(m_rows.begin() + at, run.begin(), run.end());
        m_visible_rows = static_cast<int>(m_rows.size());
        m_reverse_valid = false;
        endInsertRows();
        end = begin;
    }
    while (m_limit >= 0 && static_cast<int>(m_rows.size()) > m_limit) {
        const int last = static_cast<int>(m_rows.size()) - 1;
        beginRemoveRows({}, last, last);
        m_rows.pop_back();
        m_visible_rows = static_cast<int>(m_rows.size());
        m_reverse_valid = false;
        endRemoveRows();
    }
    return true;
}

void TransactionPresentationProxy::flushInserts()
{
    m_flush_scheduled = false;
    auto identities = std::move(m_pending_inserts);
    m_pending_inserts.clear();
    auto updated = std::move(m_pending_updates);
    m_pending_updates.clear();
    const bool dependency = m_pending_dependency;
    m_pending_dependency = false;
    if (identities.empty() && updated.empty()) return;
    const size_t threshold = std::max<size_t>(256, m_rows.size() / 50);
    if (!incrementalReady() || (m_limit < 0 && identities.size() > threshold)) { continueRebuild(); return; }
    QElapsedTimer applying;
    applying.start();
    // Rows that changed are repositioned first, among the rows that did not change; only then are new rows placed.
    bool done = true;
    if (!updated.empty()) {
        if (dependency) done = applyUpdates(updated, m_pending_first_column, m_pending_last_column, m_pending_roles);
        else forwardDataChanged(updated, m_pending_first_column, m_pending_last_column, m_pending_roles);
    }
    if (done && !identities.empty()) done = incrementalReady() && flushNewRows(identities);
    if (done) { ++m_stats.incremental_batches; m_stats.incremental_ns += applying.nsecsElapsed(); }
    else continueRebuild();
}

bool TransactionPresentationProxy::flushNewRows(const std::vector<TransactionRowIdentity>& identities)
{
    const bool status_dependent = !m_filter.showsInactive() || m_column == TransactionTableModel::Status || m_column == TransactionTableModel::Date;
    std::vector<KeyedRow> items;
    items.reserve(identities.size());
    for (const auto& identity : identities) {
        const int row = m_locator->transactionRow(identity);
        if (row < 0) continue; // gone again before this batch was applied
        TransactionScanRow scan;
        scan.refresh_status = status_dependent;
        if (!m_locator->transactionScanRow(row, m_column, scan) || !m_filter.matchesScan(scan, *m_locator, row)) continue;
        items.push_back(keyedFrom(scan));
    }
    return insertKeyed(std::move(items));
}

bool TransactionPresentationProxy::captureRemovals(int first, int last)
{
    m_captured_removals.clear();
    if (!incrementalReady() || m_limit >= 0) return false;
    const size_t count = static_cast<size_t>(last - first + 1);
    if (count > std::max<size_t>(256, m_rows.size() / 50)) return false;
    const bool status_dependent = !m_filter.showsInactive() || m_column == TransactionTableModel::Status || m_column == TransactionTableModel::Date;
    for (int row = first; row <= last; ++row) {
        TransactionScanRow scan;
        scan.refresh_status = status_dependent;
        if (!m_locator->transactionScanRow(row, m_column, scan)) { m_captured_removals.clear(); return false; }
        CapturedRemoval captured;
        captured.in_projection = m_filter.matchesScan(scan, *m_locator, row);
        captured.row = keyedFrom(scan);
        m_captured_removals.push_back(std::move(captured));
    }
    return true;
}

bool TransactionPresentationProxy::applyRemovals()
{
    auto captured = std::move(m_captured_removals);
    m_captured_removals.clear();
    if (!incrementalReady()) return false;
    m_removal_lookup.clear();
    for (const auto& removal : captured) m_removal_lookup.emplace(removal.row.identity.id, &removal.row);
    std::vector<int> positions;
    bool ok{true};
    for (const auto& removal : captured) {
        if (!removal.in_projection) continue;
        const int position = lowerBoundPosition(removal.row, -1, ok);
        if (!ok || position >= static_cast<int>(m_rows.size()) || !(m_rows[static_cast<size_t>(position)] == removal.row.identity)) { ok = false; break; }
        positions.push_back(position);
    }
    m_removal_lookup.clear();
    if (!ok) return false;
    std::sort(positions.begin(), positions.end());
    positions.erase(std::unique(positions.begin(), positions.end()), positions.end());
    if (!positions.empty() && layoutUpdates()) {
        // See insertKeyed: one layout change instead of a row-remove signal that walks every accessible cell.
        Q_EMIT structureAboutToChange();
        Q_EMIT layoutAboutToBeChanged();
        const auto before = persistentIndexList();
        std::vector<TransactionRowIdentity> kept;
        kept.reserve(m_rows.size() - positions.size());
        size_t next = 0;
        for (size_t row = 0; row < m_rows.size(); ++row) {
            if (next < positions.size() && positions[next] == static_cast<int>(row)) { ++next; continue; }
            kept.push_back(m_rows[row]);
        }
        m_rows.swap(kept);
        m_visible_rows = static_cast<int>(m_rows.size());
        m_reverse_valid = false;
        QModelIndexList after;
        after.reserve(before.size());
        for (const auto& old_index : before) {
            const auto at = std::lower_bound(positions.begin(), positions.end(), old_index.row());
            const bool removed = at != positions.end() && *at == old_index.row();
            after.append(removed ? QModelIndex{} : index(old_index.row() - static_cast<int>(at - positions.begin()), old_index.column()));
        }
        changePersistentIndexList(before, after);
        Q_EMIT layoutChanged();
        return true;
    }
    for (size_t end = positions.size(); end > 0;) {
        size_t begin = end - 1;
        while (begin > 0 && positions[begin - 1] + 1 == positions[begin]) --begin;
        beginRemoveRows({}, positions[begin], positions[end - 1]);
        m_rows.erase(m_rows.begin() + positions[begin], m_rows.begin() + positions[end - 1] + 1);
        m_visible_rows = static_cast<int>(m_rows.size());
        m_reverse_valid = false;
        endRemoveRows();
        end = begin;
    }
    return true;
}

void TransactionPresentationProxy::forwardDataChanged(const std::vector<TransactionRowIdentity>& identities, int first_column, int last_column, const QVector<int>& roles)
{
    if (m_rows.empty()) return;
    std::vector<int> positions = positionsOf(identities);
    positions.erase(std::remove(positions.begin(), positions.end(), -1), positions.end());
    std::sort(positions.begin(), positions.end());
    emitChangedRows(positions, first_column, last_column, roles);
}

//! Announce changed rows (sorted positions). Every dataChanged is an event for an attached accessibility client, which
//! can answer each one with a round trip to its process; a few scattered rows are announced as one covering range.
void TransactionPresentationProxy::emitChangedRows(const std::vector<int>& positions, int first_column, int last_column, const QVector<int>& roles)
{
    if (positions.empty()) return;
    std::vector<std::pair<int, int>> runs;
    for (size_t i = 0; i < positions.size();) {
        size_t j = i;
        while (j + 1 < positions.size() && positions[j + 1] == positions[j] + 1) ++j;
        runs.emplace_back(positions[i], positions[j]);
        i = j + 1;
    }
    if (runs.size() > 3) runs = {{positions.front(), positions.back()}};
    for (const auto& [first, last] : runs) Q_EMIT dataChanged(index(first, first_column), index(last, last_column), roles);
}

//! Reposition rows whose data changed. Every target position is computed on the sequence that excludes *all* changed
//! rows (they sit at old positions but carry new keys, so they must not be probed), and rows are then placed in their
//! final order, each into the sorted remainder plus the rows already placed. Rows that need no move are not moved.
//! More than 32 moving rows, or a move while an accessibility client is attached (a layout change is cheaper there),
//! falls back to a rebuild.
bool TransactionPresentationProxy::applyUpdates(const std::vector<TransactionRowIdentity>& wanted, int first_column, int last_column, const QVector<int>& roles)
{
    if (wanted.size() > 512) return false;
    struct Change { TransactionRowIdentity identity; KeyedRow keyed; bool matches{false}; int position{-1}; };
    std::vector<Change> changes;
    std::vector<TransactionRowIdentity> identities;
    std::unordered_set<uint64_t> seen;
    const bool status_dependent = !m_filter.showsInactive() || m_column == TransactionTableModel::Status || m_column == TransactionTableModel::Date;
    for (const auto& identity : wanted) {
        if (!seen.insert(identity.id).second) continue;
        const int row = m_locator->transactionRow(identity);
        if (row < 0) continue; // removed again before this batch was applied
        Change change;
        change.identity = identity;
        TransactionScanRow scan;
        scan.refresh_status = status_dependent;
        if (!m_locator->transactionScanRow(row, m_column, scan)) return false;
        change.matches = m_filter.matchesScan(scan, *m_locator, row);
        change.keyed = keyedFrom(scan);
        identities.push_back(identity);
        changes.push_back(std::move(change));
    }
    const std::vector<int> found = positionsOf(identities);
    for (size_t i = 0; i < changes.size(); ++i) changes[i].position = found[i];
    std::vector<size_t> removals, present;
    std::vector<KeyedRow> insertions;
    for (size_t i = 0; i < changes.size(); ++i) {
        if (changes[i].position < 0) { if (changes[i].matches) insertions.push_back(changes[i].keyed); }
        else if (!changes[i].matches) removals.push_back(i);
        else present.push_back(i);
    }
    // Rows that leave or may move: none of them may be probed while placing any of them.
    std::vector<int> skip;
    for (size_t i : removals) skip.push_back(changes[i].position);
    for (size_t i : present) skip.push_back(changes[i].position);
    std::sort(skip.begin(), skip.end());
    // Do the present rows keep their places? They do when each sits where the sorted remainder puts it, and their
    // own order is unchanged.
    std::sort(present.begin(), present.end(), [&](size_t a, size_t b) { return changes[a].position < changes[b].position; });
    bool unmoved = true;
    for (size_t k = 0; k < present.size() && unmoved; ++k) {
        const Change& change = changes[present[k]];
        if (k > 0 && !rowPrecedes(changes[present[k - 1]].keyed, change.keyed)) { unmoved = false; break; }
        bool ok{true};
        const int target = lowerBoundPosition(change.keyed, skip, ok);
        if (!ok) return false;
        const int before = static_cast<int>(std::lower_bound(skip.begin(), skip.end(), change.position) - skip.begin());
        unmoved = target == change.position - before;
    }
    if (!unmoved && (present.size() > 32 || layoutUpdates())) return false;
    // Rows that leave.
    if (!removals.empty()) {
        std::vector<int> rows;
        for (size_t i : removals) rows.push_back(changes[i].position);
        std::sort(rows.begin(), rows.end());
        removeRuns(rows);
    }
    if (!unmoved) {
        // Place the changed rows one by one in their final order. While one is placed, the rows still waiting are skipped.
        std::vector<size_t> order = present;
        std::sort(order.begin(), order.end(), [&](size_t a, size_t b) { return rowPrecedes(changes[a].keyed, changes[b].keyed); });
        std::unordered_set<uint64_t> waiting;
        for (size_t i : order) waiting.insert(changes[i].identity.id);
        for (size_t i : order) {
            std::vector<TransactionRowIdentity> pending;
            for (size_t j : order) if (waiting.count(changes[j].identity.id)) pending.push_back(changes[j].identity);
            const std::vector<int> places = positionsOf(pending);
            std::vector<int> unplaced(places.begin(), places.end());
            if (std::find(unplaced.begin(), unplaced.end(), -1) != unplaced.end()) return false;
            std::sort(unplaced.begin(), unplaced.end());
            const int from = positionsOf({changes[i].identity})[0];
            bool ok{true};
            const int target = lowerBoundPosition(changes[i].keyed, unplaced, ok);
            if (!ok) return false;
            const int anchor = realPosition(target, unplaced);   // the row it goes in front of, or the end
            waiting.erase(changes[i].identity.id);
            if (anchor == from || anchor == from + 1) continue;
            if (!beginMoveRows({}, from, from, {}, anchor)) return false;
            const auto first = m_rows.begin();
            if (anchor > from) std::rotate(first + from, first + from + 1, first + anchor);
            else std::rotate(first + anchor, first + from, first + from + 1);
            m_reverse_valid = false;
            endMoveRows();
        }
    }
    // Their cells changed wherever they ended up.
    if (!present.empty()) {
        std::vector<TransactionRowIdentity> moved;
        for (size_t i : present) moved.push_back(changes[i].identity);
        std::vector<int> rows = positionsOf(moved);
        rows.erase(std::remove(rows.begin(), rows.end(), -1), rows.end());
        std::sort(rows.begin(), rows.end());
        emitChangedRows(rows, first_column, last_column, roles);
    }
    if (!insertions.empty() && !insertKeyed(std::move(insertions))) return false;
    return true;
}

//! Remove the given positions (ascending), one signal per contiguous run, from the back.
void TransactionPresentationProxy::removeRuns(const std::vector<int>& rows)
{
    if (layoutUpdates() && !rows.empty()) {
        Q_EMIT structureAboutToChange();
        Q_EMIT layoutAboutToBeChanged();
        const auto before = persistentIndexList();
        std::vector<TransactionRowIdentity> kept;
        kept.reserve(m_rows.size() - rows.size());
        size_t next = 0;
        for (size_t row = 0; row < m_rows.size(); ++row) {
            if (next < rows.size() && rows[next] == static_cast<int>(row)) { ++next; continue; }
            kept.push_back(m_rows[row]);
        }
        m_rows.swap(kept);
        m_visible_rows = static_cast<int>(m_rows.size());
        m_reverse_valid = false;
        QModelIndexList after;
        after.reserve(before.size());
        for (const auto& old_index : before) {
            const auto at = std::lower_bound(rows.begin(), rows.end(), old_index.row());
            const bool removed = at != rows.end() && *at == old_index.row();
            after.append(removed ? QModelIndex{} : index(old_index.row() - static_cast<int>(at - rows.begin()), old_index.column()));
        }
        changePersistentIndexList(before, after);
        Q_EMIT layoutChanged();
        return;
    }
    for (size_t end = rows.size(); end > 0;) {
        size_t begin = end - 1;
        while (begin > 0 && rows[begin - 1] + 1 == rows[begin]) --begin;
        beginRemoveRows({}, rows[begin], rows[end - 1]);
        m_rows.erase(m_rows.begin() + rows[begin], m_rows.begin() + rows[end - 1] + 1);
        m_visible_rows = static_cast<int>(m_rows.size());
        m_reverse_valid = false;
        endRemoveRows();
        end = begin;
    }
}

void TransactionPresentationProxy::sort(int column, Qt::SortOrder order) { m_column = column; m_sort_order = order; requestRebuildFor(DiagnosticChange::SORT); }
QModelIndex TransactionPresentationProxy::mapToSource(const QModelIndex& i) const
{
    if (!i.isValid() || i.model() != this || !sourceModel() || !m_locator) return {};
    const int row = m_locator->transactionRow(identityAt(i.row()));
    return row >= 0 ? sourceModel()->index(row, i.column()) : QModelIndex{};
}
QModelIndex TransactionPresentationProxy::mapFromSource(const QModelIndex& i) const
{
    return i.isValid() && i.model() == sourceModel() && m_locator ? mapIdentity(m_locator->transactionIdentity(i.row()), i.column()) : QModelIndex{};
}
QModelIndex TransactionPresentationProxy::index(int row, int column, const QModelIndex& parent) const
{
    // Qt keys its table of persistent indexes by the internal id. Indexes that all carry id 0 share one chain, and
    // an accessibility client holding one per cell (1.2 million for 200k rows) made every layout change quadratic.
    return !parent.isValid() && row >= 0 && row < rowCount() && column >= 0 && column < columnCount() ? createIndex(row, column, static_cast<quintptr>(row) + 1) : QModelIndex{};
}
int TransactionPresentationProxy::rowCount(const QModelIndex& parent) const { return parent.isValid() ? 0 : m_visible_rows; }
int TransactionPresentationProxy::columnCount(const QModelIndex& parent) const { return parent.isValid() || !sourceModel() ? 0 : sourceModel()->columnCount(); }
QVariant TransactionPresentationProxy::data(const QModelIndex& i, int role) const
{
    if (i.isValid() && i.model() == this && sourceModel() && m_locator) {
        // Resolve by identity: a hash lookup in the source instead of an ordered search per cell.
        QVariant out;
        if (m_locator->transactionData(identityAt(i.row()), i.column(), role, out)) return out;
    }
    return mapToSource(i).data(role);
}
QVariant TransactionPresentationProxy::headerData(int section, Qt::Orientation orientation, int role) const { return sourceModel() ? sourceModel()->headerData(section, orientation, role) : QVariant{}; }
Qt::ItemFlags TransactionPresentationProxy::flags(const QModelIndex& i) const
{
    if (i.isValid() && i.model() == this && sourceModel() && m_locator) {
        QVariant ignored;
        // A negative role only asks whether the row still exists; a flat table model's flags are fixed.
        if (m_locator->transactionData(identityAt(i.row()), i.column(), -1, ignored))
            return Qt::ItemIsSelectable | Qt::ItemIsEnabled | Qt::ItemNeverHasChildren;
    }
    return mapToSource(i).flags();
}
void TransactionPresentationProxy::setDateRange(const std::optional<QDateTime>& from, const std::optional<QDateTime>& to) { m_filter.setDateRange(from, to); requestRebuildFor(DiagnosticChange::FILTER); }
void TransactionPresentationProxy::setSearchString(const QString& value) { m_filter.setSearchString(value); requestRebuildFor(DiagnosticChange::FILTER); }
void TransactionPresentationProxy::setTypeFilter(quint32 value) { m_filter.setTypeFilter(value); requestRebuildFor(DiagnosticChange::FILTER); }
void TransactionPresentationProxy::setMinAmount(const CAmount& value) { m_filter.setMinAmount(value); requestRebuildFor(DiagnosticChange::FILTER); }
void TransactionPresentationProxy::setWatchOnlyFilter(TransactionFilterProxy::WatchOnlyFilter value) { m_filter.setWatchOnlyFilter(value); requestRebuildFor(DiagnosticChange::FILTER); }
void TransactionPresentationProxy::setShowInactive(bool value) { m_filter.setShowInactive(value); requestRebuildFor(DiagnosticChange::FILTER); }
void TransactionPresentationProxy::setSortRole(int role) { m_filter.setSortRole(role); requestRebuildFor(DiagnosticChange::SORT); }
void TransactionPresentationProxy::setSortCaseSensitivity(Qt::CaseSensitivity value) { m_filter.setSortCaseSensitivity(value); requestRebuildFor(DiagnosticChange::SORT); }
std::unique_ptr<TransactionFilterProxy> TransactionPresentationProxy::makeExportModel() const
{
    auto result = m_filter.makeExportModel(); result->setSourceModel(m_bound_source); result->sort(m_column, m_sort_order); return result;
}
