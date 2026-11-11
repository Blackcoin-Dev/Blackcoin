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
    using Reverse = std::map<uint64_t, int>;
    struct Entry { TransactionRowIdentity source; QVariant key; };
    TransactionFilterProxy m_filter;
    TransactionRowSource* m_locator{nullptr};
    QPointer<QAbstractItemModel> m_bound_source;
    QTimer m_timer;
    std::vector<QMetaObject::Connection> m_connections;
    std::vector<Entry> m_entries;
    std::vector<size_t> m_order, m_merge;
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
