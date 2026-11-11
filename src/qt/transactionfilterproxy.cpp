// Copyright (c) 2011-2021 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/transactionfilterproxy.h>

#include <qt/transactiontablemodel.h>
#include <qt/transactionrecord.h>

#include <QElapsedTimer>
#include <algorithm>
#include <cstdlib>
#include <limits>
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
        [this](const QModelIndex&, const QModelIndex&, const QVector<int>& roles) { if (dependencyChange(roles)) ++m_source_version; }));
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
    m_visible_rows = static_cast<int>(m_rows.size());
    m_display = Display::FINAL;
    m_ready = true;
    m_stash_valid = false;
    m_stash_source.clear();
    endResetModel();
    Q_EMIT projectionReady();
    return true;
}

bool TransactionPresentationProxy::dependencyChange(const QVector<int>& roles) const
{
    const bool key_roles = roles.empty() || roles.contains(TransactionTableModel::TypeRole) ||
        roles.contains(TransactionTableModel::DateRole) || roles.contains(TransactionTableModel::WatchonlyRole) ||
        roles.contains(TransactionTableModel::AddressRole) || roles.contains(TransactionTableModel::TxHashRole) ||
        roles.contains(TransactionTableModel::LabelRole) || roles.contains(TransactionTableModel::AmountRole);
    const bool status_roles = roles.contains(Qt::EditRole) || roles.contains(TransactionTableModel::StatusRole);
    // The Status column and a status-dependent filter follow confirmations. The Date column uses the status only to
    // order rows of the same second, which a confirmation refresh alone does not re-sort until the next rebuild.
    // Other sources report EditRole for any key change.
    return key_roles || (status_roles && (!m_fast || !m_filter.showsInactive() || m_column == TransactionTableModel::Status));
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
        [this](const QModelIndex&, int first, int) {
            Q_EMIT diagnosticInvalidated(DiagnosticChange::SOURCE_ROWS);
            // A top-five scan can consume newly appended initial-history rows.
            if (m_limit >= 0 && m_work && !m_abort && m_phase == Phase::SCAN && first >= m_cursor) return;
            continueRebuild();
        }));
    m_connections.push_back(connect(source, &QAbstractItemModel::rowsAboutToBeRemoved, this, [this] {
        Q_EMIT diagnosticInvalidated(DiagnosticChange::SOURCE_ROWS);
        m_ready = false;
        Q_EMIT projectionStarted();
    }));
    m_connections.push_back(connect(source, &QAbstractItemModel::rowsRemoved, this, [this] { requestRebuildFor(DiagnosticChange::SOURCE_ROWS); }));
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
    const auto& reverse = m_display == Display::INTERIM ? m_next_reverse : m_reverse;
    int row = reverse.find(identity.id);
    if (row < 0) return {};
    if (m_display == Display::REORDERED) row = m_old_to_reordered[row];
    if (m_display == Display::INTERIM) row = m_next_to_interim[row];
    return row >= 0 && row < m_visible_rows && identityAt(row) == identity ? index(row, column) : QModelIndex{};
}

void TransactionPresentationProxy::changeLayout(Display display)
{
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
    if (!m_removed.empty()) {
        changeLayout(Display::REORDERED);
        beginRemoveRows({}, m_survivors.size(), m_visible_rows - 1);
        m_visible_rows = m_survivors.size();
        endRemoveRows();
    }
    if (!m_added.empty()) {
        beginInsertRows({}, m_visible_rows, m_next_rows.size() - 1);
        m_display = Display::INTERIM;
        m_visible_rows = m_next_rows.size();
        endInsertRows();
    }
    changeLayout(Display::FINAL);
    m_ready = !m_restart;
    if (m_ready) Q_EMIT projectionReady();
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
