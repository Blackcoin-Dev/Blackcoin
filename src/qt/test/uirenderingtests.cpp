// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.
#include <qt/test/uirenderingtests.h>
#include <qt/accountpage.h>
#include <qt/transactionfilterproxy.h>
#include <qt/transactionrecord.h>
#include <qt/transactiontablemodel.h>
#include <qt/walletmodel.h>
#include <qt/visibilitycontroller.h>
#include <qt/uiperf.h>
#include <QTemporaryDir>
#include <QApplication>
#include <QDebug>
#include <QElapsedTimer>
#include <QEventLoop>
#include <script/solver.h>
#include <QAbstractItemModelTester>
#include <QItemSelectionModel>
#include <QLineEdit>
#include <QPointer>
#include <QSignalSpy>
#include <QStringList>
#include <QTest>
#include <QTimer>
#include <QTreeWidget>
#include <QWindow>
#include <algorithm>
#include <vector>
#include <map>
#include <functional>

namespace {
class RenderHistory final : public QAbstractTableModel, public TransactionRowSource
{
public:
    struct Row { int id; int64_t time; bool conflicted{false}; QString label; uint64_t serial{0}; };
    std::vector<Row> rows;
    mutable int sort_reads{0};
    uint64_t next_serial{1};
    std::map<uint64_t, int> locations;
    void locateRows() { locations.clear(); for (int i = 0; i < static_cast<int>(rows.size()); ++i) locations.emplace(rows[i].serial, i); }
    TransactionRowIdentity transactionIdentity(int row) const override
    {
        return row >= 0 && row < rowCount() ? TransactionRowIdentity{uint256{1}, rows[row].serial} : TransactionRowIdentity{};
    }
    int transactionRow(const TransactionRowIdentity& identity) const override
    {
        const auto found = locations.find(identity.id);
        return identity.hash == uint256{1} && found != locations.end() ? found->second : -1;
    }
    explicit RenderHistory(int count)
    {
        for (int i = 0; i < count; ++i) rows.push_back({i, (i % 97) - 3, i % 13 == 0, QString::number(i % 17), next_serial++});
        locateRows();
    }
    int rowCount(const QModelIndex& parent = {}) const override { return parent.isValid() ? 0 : rows.size(); }
    int columnCount(const QModelIndex& parent = {}) const override { return parent.isValid() ? 0 : 6; }
    QVariant data(const QModelIndex& index, int role) const override
    {
        if (!index.isValid()) return {};
        const auto& row = rows.at(index.row());
        if (role == Qt::EditRole) {
            ++sort_reads;
            if (index.column() == TransactionTableModel::Amount) return qlonglong(row.id - 100);
            // Negative and zero timestamps plus exact ties exercise the legacy
            // lexical Date key, without inventing a new numeric ordering.
            return QStringLiteral("%1-%2").arg(row.time, 20, 10, QLatin1Char('0')).arg(row.id % 7);
        }
        if (role == Qt::DisplayRole || role == TransactionTableModel::TxHashRole) return QString::number(row.id);
        if (role == TransactionTableModel::StatusRole) return row.conflicted ? TransactionStatus::Conflicted : TransactionStatus::Confirmed;
        if (role == TransactionTableModel::TypeRole) return row.id % 4;
        if (role == TransactionTableModel::WatchonlyRole) return row.id % 3 == 0;
        if (role == TransactionTableModel::DateRole) return QDateTime::fromSecsSinceEpoch(row.time);
        if (role == TransactionTableModel::LabelRole || role == TransactionTableModel::ExportLabelRole) return row.label;
        if (role == TransactionTableModel::AddressRole) return QStringLiteral("address-%1").arg(row.id);
        if (role == TransactionTableModel::AmountRole) return qlonglong(row.id - 100);
        return {};
    }
    void append(Row row)
    {
        const int next = rows.size();
        row.serial = next_serial++;
        beginInsertRows({}, next, next); rows.push_back(std::move(row)); locations.emplace(rows.back().serial, next); endInsertRows();
    }
    void resetRows() { beginResetModel(); endResetModel(); }
    void remove(int row) { beginRemoveRows({}, row, row); rows.erase(rows.begin() + row); locateRows(); endRemoveRows(); }
    void move(int from, int to)
    {
        beginMoveRows({}, from, from, {}, to > from ? to + 1 : to);
        Row row = std::move(rows[from]);
        rows.erase(rows.begin() + from); rows.insert(rows.begin() + to, std::move(row));
        locateRows(); endMoveRows();
    }
    void change(int row, int64_t time, QString label)
    {
        rows[row].time = time; rows[row].label = std::move(label);
        Q_EMIT dataChanged(index(row, 0), index(row, 5), {Qt::EditRole, TransactionTableModel::LabelRole});
    }
};

// qWait polling can sleep between the model's deliberately small queued slices.
// Drive the normal dispatcher with the same deadline, without polling sleeps.
bool WaitForProjection(TransactionPresentationProxy& display, int timeout_ms)
{
    if (display.isReady()) return true;
    QEventLoop loop;
    QTimer deadline;
    deadline.setSingleShot(true);
    deadline.setTimerType(Qt::PreciseTimer);
    QObject::connect(&display, &TransactionPresentationProxy::projectionReady, &loop, &QEventLoop::quit);
    QObject::connect(&deadline, &QTimer::timeout, &loop, &QEventLoop::quit);
    QElapsedTimer elapsed;
    elapsed.start();
    deadline.start(timeout_ms);
    loop.exec();
    const auto duration = elapsed.elapsed();
    qInfo("Projection readiness: ready=%d elapsed=%lldms deadline=%dms",
        display.isReady(), static_cast<long long>(duration), timeout_ms);
    return display.isReady() && duration <= timeout_ms;
}

class VisibilityEventTrace final : public QObject
{
public:
    std::function<void(QObject*, QEvent*)> observe;
protected:
    bool eventFilter(QObject* object, QEvent* event) override
    {
        if (event->type() == QEvent::Show || event->type() == QEvent::Hide || event->type() == QEvent::WindowStateChange) {
            observe(object, event);
        }
        return false;
    }
};

// QWidget state changes synchronously when requested. Wait for the platform's
// spontaneous QWindow acknowledgement before requesting the opposite state.
// Cocoa can finish minimizing after an immediate restore request was ignored.
bool SetMinimizedAndWaitForPlatform(QWidget& window, bool minimized, int timeout_ms)
{
    const auto request_state = [&] {
        window.setWindowState(minimized ? window.windowState() | Qt::WindowMinimized
                                        : window.windowState() & ~Qt::WindowStates(Qt::WindowMinimized));
    };
    // Headless and other backends retain their existing functional state checks.
    // Only Cocoa exercises the native acknowledgement contract in this fixture.
    if (QGuiApplication::platformName() != QStringLiteral("cocoa")) {
        request_state();
        qInfo("Native Cocoa acknowledgement required=0; functional widget state only");
        return window.isMinimized() == minimized;
    }
    QWindow* const native = window.windowHandle();
    if (!native) return false;
    QEventLoop loop;
    QTimer deadline;
    deadline.setSingleShot(true);
    deadline.setTimerType(Qt::PreciseTimer);
    QObject::connect(&deadline, &QTimer::timeout, &loop, &QEventLoop::quit);
    bool acknowledged{false};
    int native_events{0};
    VisibilityEventTrace events;
    events.observe = [&](QObject* object, QEvent* event) {
        if (object != native || event->type() != QEvent::WindowStateChange || !event->spontaneous()) return;
        ++native_events;
        if ((native->windowState() == Qt::WindowMinimized) == minimized) {
            acknowledged = true;
            loop.quit();
        }
    };
    native->installEventFilter(&events);
    QElapsedTimer elapsed;
    elapsed.start();
    deadline.start(timeout_ms);
    request_state();
    if (!acknowledged) loop.exec();
    const auto duration = elapsed.elapsed();
    native->removeEventFilter(&events);
    const bool native_matches = (native->windowState() == Qt::WindowMinimized) == minimized;
    qInfo("Native window state: cocoa_ack_required=1 requested_minimized=%d acknowledged=%d events=%d native_matches=%d widget_minimized=%d elapsed=%lldms deadline=%dms",
        minimized, acknowledged, native_events, native_matches, window.isMinimized(), static_cast<long long>(duration), timeout_ms);
    return acknowledged && native_matches && window.isMinimized() == minimized && duration <= timeout_ms;
}

void CompareRows(QAbstractItemModel& actual, QAbstractItemModel& expected, int count = -1)
{
    if (count < 0) count = expected.rowCount();
    QCOMPARE(actual.rowCount(), count);
    for (int row = 0; row < count; ++row) QCOMPARE(actual.index(row, 0).data(TransactionTableModel::TxHashRole), expected.index(row, 0).data(TransactionTableModel::TxHashRole));
}
}

void UiRenderingTests::slicedSortMatchesOracle_data()
{
    QTest::addColumn<int>("count");
    QTest::newRow("10k") << 10'000;
    QTest::newRow("50k") << 50'000;
    QTest::newRow("200k") << 200'000;
}

void UiRenderingTests::slicedSortMatchesOracle()
{
    QFETCH(int, count);
    RenderHistory history(count);
    TransactionPresentationProxy display;
    QAbstractItemModelTester tester(&display, QAbstractItemModelTester::FailureReportingMode::QtTest);
    int slices{0};
    bool heartbeat{false};
    QObject::connect(&display, &TransactionPresentationProxy::sliceCompleted, &display, [&](int work) {
        QVERIFY(work > 0 && work <= 128);
        if (history.sort_reads > 0 && ++slices == 1) QTimer::singleShot(0, &display, [&] { heartbeat = true; QVERIFY(!display.isReady()); });
    });
    display.setSourceModel(&history);
    display.sort(TransactionTableModel::Date, Qt::DescendingOrder);
    QCOMPARE(history.sort_reads, 0);
    QVERIFY(WaitForProjection(display, 60000));
    QVERIFY(heartbeat);
    QVERIFY(slices > count / 128);
    QVERIFY(history.sort_reads >= count);
    TransactionFilterProxy oracle;
    oracle.setSortRole(Qt::EditRole);
    oracle.setSourceModel(&history);
    oracle.sort(TransactionTableModel::Date, Qt::DescendingOrder);
    CompareRows(display, oracle);
    display.setSearchString(QStringLiteral("address-123"));
    oracle.setSearchString(QStringLiteral("address-123"));
    QVERIFY(WaitForProjection(display, 60000));
    CompareRows(display, oracle);
    display.setSearchString({}); oracle.setSearchString({});
    display.setShowInactive(false); oracle.setShowInactive(false);
    display.setTypeFilter(TransactionFilterProxy::TYPE(1) | TransactionFilterProxy::TYPE(3));
    oracle.setTypeFilter(TransactionFilterProxy::TYPE(1) | TransactionFilterProxy::TYPE(3));
    display.setWatchOnlyFilter(TransactionFilterProxy::WatchOnlyFilter_No);
    oracle.setWatchOnlyFilter(TransactionFilterProxy::WatchOnlyFilter_No);
    display.setMinAmount(50); oracle.setMinAmount(50);
    const auto start = QDateTime::fromSecsSinceEpoch(0);
    const auto end = QDateTime::fromSecsSinceEpoch(50);
    display.setDateRange(start, end); oracle.setDateRange(start, end);
    display.sort(TransactionTableModel::Amount, Qt::AscendingOrder);
    oracle.sort(TransactionTableModel::Amount, Qt::AscendingOrder);
    QVERIFY(WaitForProjection(display, 60000));
    CompareRows(display, oracle);
}

void UiRenderingTests::updatesAndSelectionDuringProjection()
{
    RenderHistory history(10000);
    TransactionFilterProxy oracle;
    oracle.setSortRole(Qt::EditRole); oracle.setSourceModel(&history); oracle.sort(TransactionTableModel::Date, Qt::DescendingOrder);
    TransactionPresentationProxy display;
    QAbstractItemModelTester tester(&display, QAbstractItemModelTester::FailureReportingMode::QtTest);
    display.setSourceModel(&history);
    bool changed{false};
    QObject::connect(&display, &TransactionPresentationProxy::sliceCompleted, &display, [&](int) {
        if (changed || history.sort_reads == 0) return;
        changed = true;
        history.append({20000, 900, false, QStringLiteral("late")});
        history.change(5, 800, QStringLiteral("changed"));
        history.remove(7);
    });
    QVERIFY(WaitForProjection(display, 30000));
    CompareRows(display, oracle);
    const QPersistentModelIndex source = history.index(50, 0);
    QPersistentModelIndex pinned = display.mapFromSource(source);
    const auto identity = pinned.data(TransactionTableModel::TxHashRole);
    QItemSelectionModel selection(&display);
    selection.select(pinned, QItemSelectionModel::Select | QItemSelectionModel::Rows);
    history.change(50, 5000, QStringLiteral("moved"));
    history.change(57, 5000, QStringLiteral("same-key"));
    QVERIFY(WaitForProjection(display, 30000));
    CompareRows(display, oracle);
    QVERIFY(pinned.isValid());
    QCOMPARE(pinned.data(TransactionTableModel::TxHashRole), identity);
    QVERIFY(selection.isSelected(pinned));
    history.remove(0);
    history.move(2, 9000);
    history.move(6000, 3);
    QVERIFY(WaitForProjection(display, 30000));
    CompareRows(display, oracle);
    QCOMPARE(pinned.data(TransactionTableModel::TxHashRole), identity);
    QVERIFY(selection.isSelected(pinned));
}

void UiRenderingTests::hiddenDetachAndReentry()
{
    RenderHistory first(10000), second(500);
    TransactionPresentationProxy display;
    display.setSourceModel(&first);
    bool hidden{false};
    QObject::connect(&display, &TransactionPresentationProxy::sliceCompleted, &display, [&](int) {
        if (!hidden && first.sort_reads > 0) { hidden = true; display.setActive(false); }
    });
    QTRY_VERIFY(hidden);
    QCOMPARE(display.rowCount(), 0);
    const int reads = first.sort_reads;
    first.change(0, 999, QStringLiteral("hidden"));
    first.append({10001, 999, false, {}});
    QTimer heartbeat;
    heartbeat.setSingleShot(true);
    QSignalSpy delivered(&heartbeat, &QTimer::timeout);
    heartbeat.start(0);
    QTRY_COMPARE(delivered.count(), 1);
    QCOMPARE(first.sort_reads, reads);
    display.setSourceModel(&second);
    display.setActive(true);
    QTRY_VERIFY_WITH_TIMEOUT(display.isReady(), 10000);
    QCOMPARE(display.rowCount(), 500);
    QCOMPARE(first.sort_reads, reads);
    display.setSourceModel(nullptr);
    QCOMPARE(display.rowCount(), 0);
}

void UiRenderingTests::recentRowsDuringPartialHistory()
{
    RenderHistory history(10000);
    TransactionPresentationProxy recent(nullptr, 5);
    QAbstractItemModelTester tester(&recent, QAbstractItemModelTester::FailureReportingMode::QtTest);
    bool saw_partial{false};
    QObject::connect(&recent, &TransactionPresentationProxy::sliceCompleted, &recent, [&](int) {
        if (!recent.isReady() && recent.rowCount() > 0) saw_partial = true;
    });
    recent.setShowInactive(false); recent.setSourceModel(&history);
    QTRY_VERIFY_WITH_TIMEOUT(recent.isReady(), 10000);
    QVERIFY(saw_partial);
    TransactionFilterProxy oracle;
    oracle.setShowInactive(false); oracle.setSortRole(Qt::EditRole); oracle.setSourceModel(&history); oracle.sort(TransactionTableModel::Date, Qt::DescendingOrder);
    CompareRows(recent, oracle, 5);
    const QPersistentModelIndex pinned = recent.index(0, 0);
    const auto identity = pinned.data(TransactionTableModel::TxHashRole);
    history.append({10000, -1000, false, {}});
    QTRY_VERIFY_WITH_TIMEOUT(recent.isReady(), 10000);
    QCOMPARE(pinned.data(TransactionTableModel::TxHashRole), identity);
}

void UiRenderingTests::accountLargeGroupCancellationAndFilter()
{
    AccountPage page(nullptr);
    auto snapshot = std::make_shared<WalletModel::AccountSnapshot>();
    const CTxDestination dest = PKHash{uint160{}};
    snapshot->labels[dest] = "joint-label";
    auto& group = snapshot->coins[dest];
    for (int i = 0; i < 10000; ++i) {
        interfaces::WalletTxOut output;
        output.time = 0;
        output.depth_in_main_chain = 10;
        output.txout = CTxOut{COIN, GetScriptForDestination(dest)};
        group.emplace_back(COutPoint{uint256{1}, static_cast<uint32_t>(i)}, output);
    }
    page.m_snapshot = snapshot;
    page.show();
    bool heartbeat{false};
    QTimer::singleShot(0, &page, [&] {
        heartbeat = true;
        QVERIFY(!page.m_snapshot_rendered);
        QVERIFY(page.m_tree->topLevelItemCount() <= 1);
        if (page.m_tree->topLevelItemCount()) QVERIFY(page.m_tree->topLevelItem(0)->childCount() <= 128);
        page.hide();
    });
    QTRY_VERIFY(heartbeat);
    const int partial = page.m_tree->topLevelItemCount() ? page.m_tree->topLevelItem(0)->childCount() : 0;
    QVERIFY(!page.m_render_timer->isActive());
    page.show();
    auto cancelled = std::make_shared<std::atomic<bool>>(false);
    page.m_refresh_cancel = cancelled;
    page.setWindowState(page.windowState() | Qt::WindowMinimized);
    QTRY_VERIFY(!page.m_visibility->active());
    QVERIFY(cancelled->load(std::memory_order_acquire));
    QVERIFY(!page.m_refresh_cancel && !page.m_render_timer->isActive());
    page.setWindowState(page.windowState() & ~Qt::WindowStates(Qt::WindowMinimized));
    QTRY_VERIFY(page.m_visibility->active());
    QTRY_VERIFY_WITH_TIMEOUT(page.m_snapshot_rendered && !page.m_filter_slice_timer->isActive(), 30000);
    QCOMPARE(page.m_tree->topLevelItem(0)->childCount(), 10000);
    QVERIFY(partial < 10000);
    page.m_search->setText(QString::fromStdString(std::get<0>(group.back()).ToString()));
    QTRY_VERIFY_WITH_TIMEOUT(!page.m_filter_timer->isActive() && !page.m_filter_slice_timer->isActive(), 10000);
    QVERIFY(!page.m_tree->topLevelItem(0)->isHidden());
    page.m_search->setText(QStringLiteral("joint-label ") + QString::fromStdString(std::get<0>(group.front()).ToString()));
    QTRY_VERIFY_WITH_TIMEOUT(!page.m_filter_timer->isActive() && !page.m_filter_slice_timer->isActive(), 10000);
    QVERIFY(!page.m_tree->topLevelItem(0)->isHidden());
    page.m_search->setText(QStringLiteral("absent-output"));
    QTRY_VERIFY_WITH_TIMEOUT(!page.m_filter_timer->isActive() && !page.m_filter_slice_timer->isActive(), 10000);
    QVERIFY(page.m_tree->topLevelItem(0)->isHidden());
    page.setPrivacy(true);
    QCOMPARE(page.m_tree->topLevelItemCount(), 0);
    QVERIFY(!page.m_snapshot);
    page.setPrivacy(false);
    page.m_snapshot = snapshot; page.renderSnapshot();
    page.setWalletModel(nullptr);
    QCOMPARE(page.m_tree->topLevelItemCount(), 0);
    QVERIFY(!page.m_snapshot && !page.m_render_state);
    QVERIFY(!page.m_render_timer->isActive());
}

void UiRenderingTests::atomicPublicationAndIdentity()
{
    RenderHistory history(1000);
    TransactionPresentationProxy display;
    QAbstractItemModelTester tester(&display, QAbstractItemModelTester::FailureReportingMode::QtTest);
    int insertions{0}, removals{0}, layouts{0};
    QPersistentModelIndex tracked;
    QVariant tracked_value;
    QItemSelectionModel selection(&display);
    const auto check = [&](bool pending_removals) {
        if (tracked.isValid()) {
            QCOMPARE(tracked.data(), tracked_value);
            QVERIFY(selection.isSelected(tracked));
        }
        for (int row = 0; row < display.rowCount(); ++row) {
            const auto proxy = display.index(row, 0);
            const auto source = display.mapToSource(proxy);
            if (!source.isValid() && pending_removals) { QVERIFY(!display.isReady()); continue; }
            QVERIFY(source.isValid());
            QCOMPARE(display.mapFromSource(source), proxy);
            QCOMPARE(proxy.data(Qt::DisplayRole), source.data(Qt::DisplayRole));
        }
    };
    connect(&display, &QAbstractItemModel::rowsInserted, &display, [&](const QModelIndex&, int first, int last) {
        ++insertions;
        QCOMPARE(display.rowCount(), last + 1);
        for (int row = first; row <= last; ++row) {
            QVERIFY(display.mapToSource(display.index(row, 0)).isValid());
            QVERIFY(display.index(row, 0).data().isValid());
        }
        check(false);
    });
    connect(&display, &QAbstractItemModel::rowsRemoved, &display, [&](const QModelIndex&, int first, int) {
        ++removals; QCOMPARE(display.rowCount(), first); check(false);
    });
    connect(&display, &QAbstractItemModel::layoutChanged, &display, [&] { ++layouts; check(true); });
    display.setSourceModel(&history);
    QTRY_VERIFY(display.isReady());
    const auto erased_identity = history.transactionIdentity(0);
    const QPersistentModelIndex survivor = display.mapFromSource(history.index(10, 0));
    const auto survivor_value = survivor.data();
    tracked = survivor; tracked_value = survivor_value;
    selection.select(tracked, QItemSelectionModel::Select | QItemSelectionModel::Rows);
    history.remove(0);
    history.append({0, 200, false, QStringLiteral("replacement")});
    QVERIFY(history.transactionIdentity(history.rowCount() - 1).id != erased_identity.id);
    QCOMPARE(history.transactionRow(erased_identity), -1);
    // The surviving row's location stays logarithmic and valid while a new
    // projection is pending. Deleted identities have no invented linear fallback.
    QVERIFY(!display.isReady());
    QCOMPARE(survivor.data(), survivor_value);
    QTRY_VERIFY(display.isReady());
    check(false);
    QVERIFY(survivor.isValid());
    QCOMPARE(survivor.data(), survivor_value);
    display.setSearchString(QStringLiteral("replacement"));
    QTRY_VERIFY(display.isReady());
    QCOMPARE(display.rowCount(), 1);
    check(false);
    QVERIFY(!survivor.isValid());
    QVERIFY(insertions >= 2 && removals >= 2 && layouts >= 3);
}

void UiRenderingTests::explicitVisibilityTransitions()
{
    QWidget window;
    QWidget page(&window);
    RenderHistory first(10000), replacement(500);
    TransactionPresentationProxy display;
    display.setSourceModel(&first);
    bool content_visible{true};
    QStringList trace;
    int dropped{0}, slices{0}, operations{0}, started{0}, ready{0}, activations{0};
    bool tracing{true};
    auto notified_state = QGuiApplication::applicationState();
    QElapsedTimer trace_clock;
    trace_clock.start();
    VisibilityController* controller{nullptr};
    QPointer<QWindow> native_window;
    const auto snapshot = [&](const char* operation) {
        return QStringLiteral("%1ms %2 controller=%3 page=%4 window=%5 minimized=%6 app=%7 notified=%8 content=%9 proxy=%10 ready=%11 rows=%12 reads=%13 slices=%14 work=%15 started=%16 published=%17 activations=%18 native_minimized=%19 exposed=%20")
            .arg(trace_clock.elapsed()).arg(QString::fromLatin1(operation))
            .arg(controller && controller->active()).arg(page.isVisible()).arg(window.isVisible()).arg(window.isMinimized())
            .arg(int(QGuiApplication::applicationState())).arg(int(notified_state)).arg(content_visible)
            .arg(display.isActive()).arg(display.isReady()).arg(display.rowCount()).arg(replacement.sort_reads)
            .arg(slices).arg(operations).arg(started).arg(ready).arg(activations)
            .arg(native_window && native_window->windowState() == Qt::WindowMinimized)
            .arg(native_window && native_window->isExposed());
    };
    const auto record = [&](const char* operation) {
        if (!tracing) return;
        if (trace.size() == 64) { ++dropped; return; }
        trace.push_back(snapshot(operation));
    };
    VisibilityController visibility(page, [&](bool active) {
        ++activations;
        display.setActive(active);
        record(active ? "controller-active" : "controller-suspended");
    }, [&] { return content_visible; });
    controller = &visibility;
    std::vector<QMetaObject::Connection> trace_connections;
    trace_connections.push_back(connect(qGuiApp, &QGuiApplication::applicationStateChanged, &page, [&](Qt::ApplicationState state) {
        notified_state = state;
        record("application-state-notification");
    }));
    trace_connections.push_back(connect(&display, &TransactionPresentationProxy::projectionStarted, &page, [&] { ++started; record("projection-started"); }));
    trace_connections.push_back(connect(&display, &TransactionPresentationProxy::projectionReady, &page, [&] { ++ready; record("projection-ready"); }));
    trace_connections.push_back(connect(&display, &TransactionPresentationProxy::sliceCompleted, &page, [&](int work) {
        ++slices;
        operations += work;
        if ((slices & (slices - 1)) == 0) record("slice-power-of-two");
    }));
    VisibilityEventTrace events;
    events.observe = [&](QObject* object, QEvent* event) {
        const char* surface = object == native_window.data() ? "native-window-event-" : object == &window ? "window-event-" : "page-event-";
        const QByteArray operation = QByteArray(surface) + QByteArray::number(int(event->type())) +
            "-spontaneous-" + QByteArray::number(event->spontaneous());
        record(operation.constData());
    };
    page.installEventFilter(&events);
    window.installEventFilter(&events);
    struct FinishTrace {
        std::function<void()> finish;
        ~FinishTrace() { finish(); }
    };
    record("constructed");
    display.setActive(false); record("explicit-proxy-suspend");
    page.show(); window.show(); visibility.refresh(); record("initial-show");
    native_window = window.windowHandle();
    if (native_window) native_window->installEventFilter(&events);
    // Deliver the same public Qt signal that the platform sends. This proves
    // state-machine/source-read behavior, not native Cocoa event delivery.
    const auto original = QGuiApplication::applicationState();
    struct RestoreState { Qt::ApplicationState state; ~RestoreState() { Q_EMIT qGuiApp->applicationStateChanged(state); } } restore{original};
    FinishTrace finish_trace{[&] {
        for (const auto& entry : trace) qInfo().noquote() << "Restore trace:" << entry;
        qInfo().noquote() << "Restore trace:" << snapshot("final") << "dropped=" << dropped;
        tracing = false;
        for (const auto& connection : trace_connections) disconnect(connection);
        page.removeEventFilter(&events);
        window.removeEventFilter(&events);
        if (native_window) native_window->removeEventFilter(&events);
    }};
    Q_EMIT qGuiApp->applicationStateChanged(Qt::ApplicationActive); record("emit-active");
    QTRY_VERIFY(first.sort_reads > 0); record("initial-work-observed");
    Q_EMIT qGuiApp->applicationStateChanged(Qt::ApplicationHidden); record("emit-hidden");
    QVERIFY(!visibility.active());
    QCOMPARE(display.rowCount(), 0);
    const int paused_reads = first.sort_reads;
    first.change(0, 900, QStringLiteral("hidden"));
    display.setSourceModel(&replacement); record("replacement-bound");
    QTimer event;
    event.setSingleShot(true);
    QSignalSpy delivered(&event, &QTimer::timeout);
    event.start(0); QTRY_COMPARE(delivered.count(), 1); record("hidden-heartbeat");
    QCOMPARE(first.sort_reads, paused_reads);
    QCOMPARE(replacement.sort_reads, 0);
    Q_EMIT qGuiApp->applicationStateChanged(Qt::ApplicationInactive); record("emit-inactive");
    QVERIFY(visibility.active());
    record("before-readiness-check"); QTRY_VERIFY(display.isReady()); record("readiness-observed");
    QCOMPARE(display.rowCount(), 500);
    record("before-minimize");
    QVERIFY(SetMinimizedAndWaitForPlatform(window, true, 5000)); record("native-minimize-acknowledged");
    QVERIFY(!visibility.active()); record("minimized-inactive-observed");
    QCOMPARE(display.rowCount(), 0);
    record("before-restore");
    QVERIFY(SetMinimizedAndWaitForPlatform(window, false, 5000)); record("native-restore-acknowledged");
    QVERIFY(visibility.active()); record("restored-active-observed");
    record("before-readiness-check"); QVERIFY(WaitForProjection(display, 5000)); record("readiness-observed");
    Q_EMIT qGuiApp->applicationStateChanged(Qt::ApplicationSuspended); record("emit-suspended");
    QVERIFY(!visibility.active());
    Q_EMIT qGuiApp->applicationStateChanged(Qt::ApplicationActive); record("emit-active");
    record("before-readiness-check"); QTRY_VERIFY(display.isReady()); record("readiness-observed");
    content_visible = false; visibility.refresh(); record("content-hidden");
    QVERIFY(!display.isActive()); QCOMPARE(display.rowCount(), 0);
    content_visible = true; visibility.refresh(); record("content-visible"); QTRY_VERIFY(display.isReady()); record("content-ready");
    page.hide(); record("page-hidden"); QVERIFY(!visibility.active());
    page.show(); record("page-shown"); QTRY_VERIFY(display.isReady()); record("page-ready");
    display.setSourceModel(nullptr); record("source-detached");
    QCOMPARE(display.rowCount(), 0);
    QVERIFY(VisibilityController::AllowsWork(true, false, Qt::ApplicationInactive, true));
    QVERIFY(!VisibilityController::AllowsWork(true, true, Qt::ApplicationActive, true));
}

void UiRenderingTests::paintProjectionContinuation()
{
#ifdef Q_OS_WIN
    QSKIP("Secure paint output requires POSIX");
#else
    RenderHistory history(256);
    TransactionPresentationProxy display;
    UiPaintTableView table;
    table.setModel(&display);
    table.observeHistoryProjection(&display);
    display.setSourceModel(&history);
    QVERIFY(WaitForProjection(display, 3000));
    display.setActive(false);
    table.resize(800, 400);
    table.show();
    QVERIFY(QTest::qWaitForWindowExposed(&table, 3000));
    QTemporaryDir directory;
    UiPaintProbe probe;
    QString error;
    QVERIFY2(probe.start(directory.filePath(QStringLiteral("continuation.json")), error), qPrintable(error));
    QSignalSpy started(&display, &TransactionPresentationProxy::projectionStarted);
    {
        QKeyEvent event(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
        UiPaintProbe::NotifyScope dispatch(&table, &event);
        table.measurementAction(UiPaintProbe::Action::NAVIGATE);
        display.setActive(true);
    }
    QVERIFY(!probe.records().empty());
    const auto trial = probe.records().size() - 1;
    const auto before = probe.records()[trial];
    QCOMPARE(int(before.outcome), int(UiPaintProbe::Outcome::PENDING));
    QCOMPARE(started.size(), 1);
    QVERIFY(WaitForProjection(display, 3000));
    QCOMPARE(started.size(), 2); // The real queued RETIRE continuation still emits Started.
    QTRY_COMPARE_WITH_TIMEOUT(int(probe.records()[trial].outcome), int(UiPaintProbe::Outcome::PAINTED), 3000);
    const auto& after = probe.records()[trial];
    QCOMPARE(after.generation, before.generation);
    QCOMPARE(after.delivered_ns, before.delivered_ns);
    QCOMPARE(after.semantic_ns, before.semantic_ns);
    QVERIFY(after.input != 0);
    QVERIFY(after.ready_ns > 0 && after.paint_begin_ns >= after.ready_ns);
    QVERIFY(after.paint_end_ns >= after.paint_begin_ns);

    display.setActive(false);
    QWindowStateChangeEvent restored(Qt::WindowMinimized);
    {
        // A simulated restore delivery, followed by actual queued projection
        // and viewport paint. This is not native macOS restore calibration.
        UiPaintProbe::NotifyScope dispatch(&table, &restored);
        display.setActive(true);
    }
    const auto restore_trial = probe.records().size() - 1;
    const auto restore_before = probe.records()[restore_trial];
    QCOMPARE(int(restore_before.action), int(UiPaintProbe::Action::RESTORE));
    QVERIFY(WaitForProjection(display, 3000));
    QTRY_COMPARE_WITH_TIMEOUT(int(probe.records()[restore_trial].outcome), int(UiPaintProbe::Outcome::PAINTED), 3000);
    const auto& restore_after = probe.records()[restore_trial];
    QCOMPARE(restore_after.input, quint64{0});
    QCOMPARE(restore_after.generation, restore_before.generation);
    QCOMPARE(restore_after.delivered_ns, restore_before.delivered_ns);
    const auto ready = restore_after.ready_ns;
    table.measurementReady();
    QCOMPARE(probe.records()[restore_trial].ready_ns, ready);
    QVERIFY2(probe.finish(error), qPrintable(error));
#endif
}

void UiRenderingTests::paintProjectionInvalidation()
{
#ifdef Q_OS_WIN
    QSKIP("Secure paint output requires POSIX");
#else
    RenderHistory first(256);
    auto replacement = std::make_unique<RenderHistory>(256);
    TransactionPresentationProxy display;
    UiPaintTableView table;
    table.setModel(&display);
    table.observeHistoryProjection(&display);
    display.setSourceModel(&first);
    QVERIFY(WaitForProjection(display, 3000));
    table.resize(800, 400);
    table.show();
    QVERIFY(QTest::qWaitForWindowExposed(&table, 3000));
    QTemporaryDir directory;
    UiPaintProbe probe;
    QString error;
    QVERIFY2(probe.start(directory.filePath(QStringLiteral("invalidation.json")), error), qPrintable(error));
    using Reason = UiPaintProbe::EpochReason;
    // Each real source boundary must invalidate before an already-started
    // paint could be credited. No manual generation() calls stand in for it.
    const auto invalidates = [&](const std::function<void()>& change, Reason reason) {
        {
            QKeyEvent event(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
            UiPaintProbe::NotifyScope dispatch(&table, &event);
            table.measurementAction(UiPaintProbe::Action::ROW);
        }
        const auto trial = probe.records().size() - 1;
        const auto generation = probe.records()[trial].generation;
        const auto token = probe.beforePaint(table.viewport(), QRegion(table.viewport()->rect()));
        if (!token.covered) return false;
        change();
        probe.afterPaint(table.viewport(), token);
        const auto& record = probe.records()[trial];
        return record.outcome == UiPaintProbe::Outcome::GENERATION_CHANGED && record.paint_end_ns == 0 &&
            record.cancel_previous_generation == generation && record.cancel_new_generation > generation && record.epoch_reason == reason;
    };
    QVERIFY(invalidates([&] { display.setSourceModel(replacement.get()); }, Reason::SOURCE_BINDING));
    QVERIFY(WaitForProjection(display, 3000));
    QVERIFY(invalidates([&] { replacement->resetRows(); }, Reason::SOURCE_RESET));
    QVERIFY(WaitForProjection(display, 3000));
    QVERIFY(invalidates([&] { replacement->remove(0); }, Reason::SOURCE_ROWS));
    QVERIFY(WaitForProjection(display, 3000));
    QVERIFY(invalidates([&] { display.setSearchString(QString{}); }, Reason::FILTER));
    QVERIFY(WaitForProjection(display, 3000));
    QVERIFY(invalidates([&] { display.sort(TransactionTableModel::Date, Qt::AscendingOrder); }, Reason::SORT));
    QVERIFY(WaitForProjection(display, 3000));
    {
        QKeyEvent event(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
        UiPaintProbe::NotifyScope dispatch(&table, &event);
        table.measurementAction(UiPaintProbe::Action::SORT, true);
        display.sort(TransactionTableModel::Date, Qt::DescendingOrder);
        // Even in the same dispatch, a genuine source mutation is not a filter
        // continuation. Exercise dataChanged while queued work is in flight.
        replacement->change(0, 999, QStringLiteral("changed"));
    }
    QCOMPARE(int(probe.records().back().outcome), int(UiPaintProbe::Outcome::GENERATION_CHANGED));
    QCOMPARE(int(probe.records().back().epoch_reason), int(Reason::SOURCE_DATA));
    QVERIFY(WaitForProjection(display, 3000));
    {
        QKeyEvent event(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
        UiPaintProbe::NotifyScope dispatch(&table, &event);
        table.measurementAction(UiPaintProbe::Action::ROW);
    }
    const auto hidden_trial = probe.records().size() - 1;
    const auto hidden_token = probe.beforePaint(table.viewport(), QRegion(table.viewport()->rect()));
    QVERIFY(hidden_token.covered);
    table.hide();
    probe.afterPaint(table.viewport(), hidden_token);
    QCOMPARE(int(probe.records()[hidden_trial].outcome), int(UiPaintProbe::Outcome::HIDDEN));
    QCOMPARE(probe.records()[hidden_trial].paint_end_ns, qint64{0});
    table.show();
    QVERIFY(QTest::qWaitForWindowExposed(&table, 3000));
    QVERIFY(invalidates([&] { replacement.reset(); }, Reason::SOURCE_DESTROYED));
    {
        QKeyEvent event(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
        UiPaintProbe::NotifyScope dispatch(&table, &event);
        table.measurementAction(UiPaintProbe::Action::ROW);
    }
    const auto rebound_trial = probe.records().size() - 1;
    table.setModel(nullptr); // Same observer boundary used by wallet rebind.
    QCOMPARE(int(probe.records()[rebound_trial].outcome), int(UiPaintProbe::Outcome::REBOUND));
    QVERIFY2(probe.finish(error), qPrintable(error));
#endif
}

void UiRenderingTests::paintProjectionDeadline()
{
#ifdef Q_OS_WIN
    QSKIP("Secure paint output requires POSIX");
#else
    RenderHistory history(256);
    TransactionPresentationProxy display;
    UiPaintTableView table;
    table.setModel(&display);
    table.observeHistoryProjection(&display);
    display.setSourceModel(&history);
    QVERIFY(WaitForProjection(display, 3000));
    display.setActive(false);
    table.resize(800, 400);
    table.show();
    QVERIFY(QTest::qWaitForWindowExposed(&table, 3000));
    QTemporaryDir directory;
    UiPaintProbe probe(32, 20000000); // Test-only 20 ms deadline; product remains five seconds.
    QString error;
    QVERIFY2(probe.start(directory.filePath(QStringLiteral("deadline.json")), error), qPrintable(error));
    {
        QKeyEvent event(QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier);
        UiPaintProbe::NotifyScope dispatch(&table, &event);
        table.measurementAction(UiPaintProbe::Action::NAVIGATE);
        display.setActive(true);
    }
    const auto trial = probe.records().size() - 1;
    const auto delivered = probe.records()[trial].delivered_ns;
    QThread::msleep(30); // Internal continuation must not restart this elapsed deadline.
    QVERIFY(WaitForProjection(display, 3000));
    QTRY_COMPARE_WITH_TIMEOUT(int(probe.records()[trial].outcome), int(UiPaintProbe::Outcome::TIMEOUT), 1000);
    QCOMPARE(probe.records()[trial].delivered_ns, delivered);
    QCOMPARE(probe.records()[trial].paint_end_ns, qint64{0});
    QVERIFY2(probe.finish(error), qPrintable(error));
#endif
}
