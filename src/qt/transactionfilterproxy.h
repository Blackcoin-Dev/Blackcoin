// Copyright (c) 2011-2021 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_TRANSACTIONFILTERPROXY_H
#define BITCOIN_QT_TRANSACTIONFILTERPROXY_H

#include <consensus/amount.h>
#include <qt/transactionrow.h>

#include <QAbstractProxyModel>
#include <QDateTime>
#include <QPersistentModelIndex>
#include <QPointer>
#include <QTimer>
#include <cstdint>
#include <vector>
#include <deque>
#include <algorithm>
#include <map>
#include <QHash>
#include <QSortFilterProxyModel>

#include <memory>
#include <optional>

/** Filter the transaction list according to pre-specified rules. */
class TransactionFilterProxy : public QSortFilterProxyModel
{
    Q_OBJECT

public:
    explicit TransactionFilterProxy(QObject *parent = nullptr);

    /** Type filter bit field (all types) */
    static const quint32 ALL_TYPES = 0xFFFFFFFF;

    static quint32 TYPE(int type) { return 1<<type; }

    enum WatchOnlyFilter
    {
        WatchOnlyFilter_All,
        WatchOnlyFilter_Yes,
        WatchOnlyFilter_No
    };

    /** Filter transactions between date range. Use std::nullopt for open range. */
    void setDateRange(const std::optional<QDateTime>& from, const std::optional<QDateTime>& to);
    void setSearchString(const QString &);
    /**
      @note Type filter takes a bit field created with TYPE() or ALL_TYPES
     */
    void setTypeFilter(quint32 modes);
    void setMinAmount(const CAmount& minimum);
    void setWatchOnlyFilter(WatchOnlyFilter filter);

    /** Snapshot the current filters for synchronous CSV writing, with authoritative labels. */
    std::unique_ptr<TransactionFilterProxy> makeExportModel() const;
    QVariant data(const QModelIndex& index, int role) const override;

    /** Shared predicate; the display projection evaluates this in bounded slices. */
    bool matchesIndex(const QModelIndex& index) const;
    /** The same predicate over typed scan facts; the text search asks the source. */
    bool matchesScan(const TransactionScanRow& scan, const TransactionRowSource& source, int row, bool ignore_status = false) const;
    bool showsInactive() const { return showInactive; }

    /** Set whether to show conflicted transactions. */
    void setShowInactive(bool showInactive);

protected:
    bool filterAcceptsRow(int source_row, const QModelIndex & source_parent) const override;

private:
    QString labelForFilter(const QModelIndex& source_index) const;

    bool m_export_model{false};
    mutable QHash<int, QString> m_export_labels;
    std::optional<QDateTime> dateFrom;
    std::optional<QDateTime> dateTo;
    QString m_search_string;
    quint32 typeFilter;
    WatchOnlyFilter watchOnlyFilter{WatchOnlyFilter_All};
    CAmount minAmount{0};
    bool showInactive{true};
};

/** Identity -> row map for the projection: open addressing over parallel arrays, so building one for a few
 * hundred thousand rows is a few milliseconds and tearing it down frees two blocks, not one node per row. */
class RowIdIndex
{
public:
    RowIdIndex() = default;
    RowIdIndex(RowIdIndex&& other) noexcept { swap(other); }
    RowIdIndex& operator=(RowIdIndex&& other) noexcept { if (this != &other) { clear(); swap(other); } return *this; }
    void clear() { m_keys.clear(); m_values.clear(); m_keys.shrink_to_fit(); m_values.shrink_to_fit(); m_size = 0; m_mask = 0; }
    bool empty() const { return m_size == 0; }
    size_t size() const { return m_size; }
    void reserve(size_t rows)
    {
        size_t capacity = 16;
        while (capacity < rows * 2) capacity <<= 1;
        if (capacity <= m_keys.size()) return;
        std::vector<uint64_t> keys(capacity, 0);
        std::vector<int> values(capacity, -1);
        const size_t mask = capacity - 1;
        for (size_t i = 0; i < m_keys.size(); ++i) {
            if (!m_keys[i]) continue;
            size_t slot = hash(m_keys[i]) & mask;
            while (keys[slot]) slot = (slot + 1) & mask;
            keys[slot] = m_keys[i]; values[slot] = m_values[i];
        }
        m_keys.swap(keys); m_values.swap(values); m_mask = mask;
    }
    /** False if the identity is already present. */
    bool insert(uint64_t id, int row)
    {
        if ((m_size + 1) * 2 > m_keys.size()) reserve(std::max<size_t>(16, (m_size + 1) * 2));
        size_t slot = hash(id) & m_mask;
        while (m_keys[slot]) {
            if (m_keys[slot] == id) return false;
            slot = (slot + 1) & m_mask;
        }
        m_keys[slot] = id; m_values[slot] = row; ++m_size;
        return true;
    }
    int find(uint64_t id) const
    {
        if (m_keys.empty() || id == 0) return -1;
        size_t slot = hash(id) & m_mask;
        while (m_keys[slot]) {
            if (m_keys[slot] == id) return m_values[slot];
            slot = (slot + 1) & m_mask;
        }
        return -1;
    }
    bool contains(uint64_t id) const { return find(id) >= 0; }
    void swap(RowIdIndex& other) { m_keys.swap(other.m_keys); m_values.swap(other.m_values); std::swap(m_size, other.m_size); std::swap(m_mask, other.m_mask); }
private:
    // Identities are small sequential numbers, so shifting and mixing the high bits in is enough; no multiplication,
    // which would wrap and be flagged by the unsigned-integer-overflow sanitizer.
    static size_t hash(uint64_t id) { return static_cast<size_t>(id ^ (id >> 17) ^ (id >> 34)); }
    std::vector<uint64_t> m_keys;
    std::vector<int> m_values;
    size_t m_size{0};
    size_t m_mask{0};
};

/** Cancellable GUI projection. Filtering and stable sorting never drain the event
 * queue recursively. The synchronous proxy above remains the CSV oracle.
 * A finite limit uses a bounded top-K scan instead of sorting the full history.
 */
class TransactionPresentationProxy : public QAbstractProxyModel
{
    Q_OBJECT
public:
    explicit TransactionPresentationProxy(QObject* parent = nullptr, int limit = -1);
    enum class DiagnosticChange { SOURCE_BINDING, SOURCE_RESET, SOURCE_DESTROYED, SOURCE_ROWS, SOURCE_DATA, FILTER, SORT, ACTIVATION, SOURCE_LAYOUT };
    Q_ENUM(DiagnosticChange)
    void setSourceModel(QAbstractItemModel* source) override;
    void setActive(bool active);
    bool isReady() const { return m_ready && !m_restart; }
    /** Work counters for tests and diagnostics; they do not influence behaviour. */
    struct Stats {
        uint64_t rebuilds{0};       //!< complete scans started
        uint64_t restarts{0};       //!< scans abandoned and started over by a newer change
        uint64_t slices{0};
        uint64_t rows_scanned{0};
        int64_t max_slice_ns{0};
        int64_t persistent_indexes{0}; //!< most persistent indexes remapped by one layout change
        int64_t max_layout_ns[3]{}; //!< longest about-to-change signal, persistent-index remap, layout-changed signal
        int64_t max_op_ns[9]{};     //!< longest single operation per phase (SCAN, SORT, MAP, ..., RETIRE)
    };
    const Stats& stats() const { return m_stats; }
    void resetStats() { m_stats = {}; }
    bool isActive() const { return m_active; }
    void sort(int column, Qt::SortOrder order = Qt::AscendingOrder) override;
    QModelIndex mapToSource(const QModelIndex& index) const override;
    QModelIndex mapFromSource(const QModelIndex& index) const override;
    QModelIndex index(int row, int column, const QModelIndex& parent = {}) const override;
    QModelIndex parent(const QModelIndex&) const override { return {}; }
    int rowCount(const QModelIndex& parent = {}) const override;
    int columnCount(const QModelIndex& parent = {}) const override;
    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;
    Qt::ItemFlags flags(const QModelIndex& index) const override;
    void setDateRange(const std::optional<QDateTime>& from, const std::optional<QDateTime>& to);
    void setSearchString(const QString& value);
    void setTypeFilter(quint32 value);
    void setMinAmount(const CAmount& value);
    void setWatchOnlyFilter(TransactionFilterProxy::WatchOnlyFilter value);
    void setShowInactive(bool value);
    void setSortRole(int role);
    void setSortCaseSensitivity(Qt::CaseSensitivity value);
    std::unique_ptr<TransactionFilterProxy> makeExportModel() const;
Q_SIGNALS:
    void projectionReady();
    void projectionStarted();
    /** Observer-only invalidation. Internal RETIRE continuation keeps this epoch. */
    void diagnosticInvalidated(DiagnosticChange reason, bool ready = false);
    /** Work count is useful to deterministic scheduling tests, not a timing claim. */
    void sliceCompleted(int operations);
private:
    using Rows = std::vector<TransactionRowIdentity>;
    using Reverse = RowIdIndex;
    struct Entry { TransactionRowIdentity source; QVariant key; qint64 number{0}; QString text; };
    TransactionFilterProxy m_filter;
    TransactionRowSource* m_locator{nullptr};
    QPointer<QAbstractItemModel> m_bound_source;
    QTimer m_timer;
    std::vector<QMetaObject::Connection> m_connections;
    std::vector<Entry> m_entries;
    std::vector<size_t> m_order, m_merge;
    //! Fast mode: the source supplies typed scan rows, so the scan, sort and publication plan work in chunks.
    bool m_fast{false};
    TransactionScanRow::Key m_fast_key{TransactionScanRow::Key::NUMBER};
    int m_chunk{1};
    bool m_presort{false};
    Stats m_stats;
    // A projection that was complete when the page was hidden is kept, and restored on reactivation when neither the
    // source (rows or key data) nor the filter/sort changed in between. Dormant connections only count changes.
    uint64_t m_config_epoch{0}, m_source_version{0};
    Rows m_stash_rows;
    Reverse m_stash_reverse;
    bool m_stash_valid{false};
    bool m_keep_projection{false};
    uint64_t m_stash_config{0}, m_stash_version{0};
    QPointer<QAbstractItemModel> m_stash_source;
    std::vector<QMetaObject::Connection> m_dormant;
    void watchDormant();
    bool restoreStash();
    void discardStash();
    bool dependencyChange(const QVector<int>& roles) const;
    Rows m_rows, m_next_rows;
    Reverse m_reverse, m_next_reverse;
    std::deque<Rows> m_retired_rows;
    std::deque<Reverse> m_retired_maps;
    std::vector<int> m_survivors, m_removed, m_added, m_reordered, m_old_to_reordered;
    std::vector<int> m_interim, m_next_to_interim;
    int m_visible_rows{0};
    int m_limit;
    int m_column{2};
    Qt::SortOrder m_sort_order{Qt::DescendingOrder};
    int m_cursor{0};
    size_t m_width{1}, m_left{0}, m_a{0}, m_b{0}, m_mid{0}, m_end{0}, m_plan_cursor{0};
    enum class Phase { SCAN, SORT, MAP, OLD_PLAN, ADD_PLAN, REORDER_PLAN, INTERIM_PLAN, PUBLISH, RETIRE };
    enum class Display { FINAL, REORDERED, INTERIM };
    Phase m_phase{Phase::SCAN};
    Display m_display{Display::FINAL};
    bool m_active{true}, m_ready{false}, m_restart{false}, m_work{false}, m_abort{false};
    void attach();
    void setSourceModelFor(QAbstractItemModel* source, DiagnosticChange reason);
    void requestRebuild();
    void requestRebuildFor(DiagnosticChange reason);
    void continueRebuild();
    void clearProjection(DiagnosticChange reason = DiagnosticChange::SOURCE_RESET);
    void runSlice();
    void publish();
    void changeLayout(Display display);
    TransactionRowIdentity identityAt(int row) const;
    QModelIndex mapIdentity(const TransactionRowIdentity& identity, int column) const;
    bool less(const Entry& left, const Entry& right) const;

};

#endif // BITCOIN_QT_TRANSACTIONFILTERPROXY_H
