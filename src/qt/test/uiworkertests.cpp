// Copyright (c) 2026 The Blackcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.
#include <common/args.h>
#include <univalue.h>
#include <qt/test/uiworkertests.h>
#include <qt/uiperf.h>
#include <qt/clientmodel.h>
#include <qt/platformstyle.h>
#include <qt/rpcconsole.h>
#include <qt/peertablemodel.h>
#include <qt/peertablesortproxy.h>
#include <qt/visibilitycontroller.h>
#include <interfaces/handler.h>
#include <interfaces/node.h>
#include <test/util/setup_common.h>
#include <node/interface_ui.h>
#include <validation.h>
#include <tinyformat.h>
#include <QEventLoop>
#include <QElapsedTimer>
#include <QLineEdit>
#include <QTextEdit>
#include <QJsonDocument>
#include <QTemporaryDir>
#include <QTest>
#include <QThread>
#include <QItemSelectionModel>
#include <QPersistentModelIndex>
#include <QSignalSpy>
#include <QStandardItemModel>
#include <qt/guiconstants.h>
#include <chain.h>
#include <algorithm>
#include <chrono>
#include <future>
#include <mutex>
#include <functional>
#include <stdexcept>

namespace {
std::unique_ptr<interfaces::Handler> PreserveApplicationSettings()
{
    common::Settings settings;
    gArgs.LockSettings([&](const auto& current) { settings = current; });
    return interfaces::MakeCleanupHandler([settings = std::move(settings)]() mutable {
        // TestingSetup leaves the forced datadir pointing at its deleted
        // directory. Subsequent Qt suites still use the application settings.
        gArgs.LockSettings([&](auto& current) { current = std::move(settings); });
        gArgs.ClearPathCache();
    });
}
} // namespace

void UiWorkerTests::accumulatorCalibrationAndOverflow()
{
    UiPerfProbe probe(2);
    probe.record(20000000);
    probe.record(40000000);
    probe.record(40000000); // Rejected, not a zero-duration sample.
    probe.record(60000000);
    QCOMPARE(probe.maxLatenessNs(), qint64{0});
    probe.record(180000000); // 20 ms interval plus 100 ms delay.
    QCOMPARE(probe.maxLatenessNs(), qint64{100000000});
    probe.record(700000000); // plus 500 ms delay.
    QCOMPARE(probe.maxLatenessNs(), qint64{500000000});
    probe.record(2220000000LL); // plus 1500 ms delay.
    QCOMPARE(probe.maxLatenessNs(), qint64{1500000000});
    QCOMPARE(probe.count(), qint64{6});
    QCOMPARE(probe.dropped(), qint64{4});
    QCOMPARE(probe.nonmonotonic(), qint64{1});
}

void UiWorkerTests::eventLoopCalibration()
{
#ifdef Q_OS_WIN
    QSKIP("Secure POSIX trace output is not enabled on Windows");
#else
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    for (const int delay : {0, 100, 500, 1500}) {
        UiPerfProbe probe;
        QString error;
        const QString path = directory.filePath(QString::number(delay) + ".jsonl");
        QVERIFY2(probe.start(path, error), qPrintable(error));
        QTRY_VERIFY_WITH_TIMEOUT(probe.count() >= 3, 3000);
        // Run the known delay in an actual GUI event callback. This calibrates
        // timer lateness, not keyboard dispatch or rendered paint completion.
        bool injected{false};
        QTimer::singleShot(0, &probe, [&] { QThread::msleep(delay); injected = true; });
        QTRY_VERIFY_WITH_TIMEOUT(injected, 5000);
        const auto before = probe.count();
        QTRY_VERIFY_WITH_TIMEOUT(probe.count() > before, 3000);
        if (delay) QVERIFY(probe.maxLatenessNs() >= (delay - 40) * 1000000LL);
        else QVERIFY2(probe.maxLatenessNs() < 100000000, "Nonblocked calibration environment exceeded 100 ms timer lateness");
        QVERIFY2(probe.finish(error), qPrintable(error));
        QFile file(path);
        QVERIFY(file.open(QIODevice::ReadOnly));
        const auto lines = file.readAll().trimmed().split('\n');
        const auto header = QJsonDocument::fromJson(lines.front()).object();
        QCOMPARE(header.value("metric").toString(), QStringLiteral("event_loop_timer_lateness"));
        QVERIFY(!header.value("paint_latency").toBool());
        const auto summary = QJsonDocument::fromJson(lines.back()).object();
        QVERIFY(summary.value("complete").toBool());
        QCOMPARE(summary.value("samples").toInt(), int(probe.count()));
        qint64 last{0};
        for (int i = 1; i + 1 < lines.size(); ++i) {
            const auto sample = QJsonDocument::fromJson(lines[i]).object();
            if (sample.value("kind").toString() != QStringLiteral("sample")) continue;
            const auto elapsed = qint64(sample.value("elapsed_ns").toDouble());
            QVERIFY(elapsed > last);
            last = elapsed;
        }
    }
#endif
}

void UiWorkerTests::outputCreationFailsClosed()
{
#ifdef Q_OS_WIN
    QSKIP("Secure POSIX trace output is not enabled on Windows");
#else
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto existing = directory.filePath("existing");
    QFile file(existing);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QCOMPARE(file.write("preserve"), qint64{8});
    file.close();
    UiPerfProbe probe;
    QString error;
    QVERIFY(!probe.start(existing, error));
    const auto link = directory.filePath("link");
    QVERIFY(QFile::link(existing, link));
    QVERIFY(!probe.start(link, error));
    QVERIFY(!probe.start(QStringLiteral("relative.jsonl"), error));
    QVERIFY(file.open(QIODevice::ReadOnly));
    QCOMPARE(file.readAll(), QByteArray{"preserve"});
    UiPerfProbe accepted;
    const auto fresh = directory.filePath("fresh");
    QVERIFY2(accepted.start(fresh, error), qPrintable(error));
    const auto permissions = QFile::permissions(fresh);
    QVERIFY(permissions.testFlag(QFile::ReadOwner));
    QVERIFY(permissions.testFlag(QFile::WriteOwner));
    QVERIFY(!permissions.testFlag(QFile::ReadGroup));
    QVERIFY(!permissions.testFlag(QFile::ReadOther));
    QVERIFY(accepted.finish(error));
#endif
}

void UiWorkerTests::terminalStallBeforeQuit()
{
#ifdef Q_OS_WIN
    QSKIP("Secure POSIX trace output is not enabled on Windows");
#else
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    UiPerfProbe probe;
    QString error;
    const auto path = directory.filePath("terminal.jsonl");
    QVERIFY2(probe.start(path, error), qPrintable(error));
    QTRY_VERIFY_WITH_TIMEOUT(probe.count() >= 2, 3000);
    // Stall the thread with no event loop running. An inner QEventLoop could
    // dispatch the overdue timer in the same pass that handles quit(), so the
    // delayed timer would recover before finish().
    const qint64 callbacks_before{probe.count()};
    QThread::msleep(500);
    QVERIFY2(probe.finish(error), qPrintable(error));
    QCOMPARE(probe.count(), callbacks_before);
    QFile file(path);
    QVERIFY(file.open(QIODevice::ReadOnly));
    const auto lines = file.readAll().trimmed().split('\n');
    const auto tail = QJsonDocument::fromJson(lines[lines.size() - 2]).object();
    const auto summary = QJsonDocument::fromJson(lines.back()).object();
    QCOMPARE(tail.value("kind").toString(), QStringLiteral("terminal_interval"));
    QVERIFY(!tail.value("timer_callback_delivered").toBool());
    QVERIFY(tail.value("gap_ns").toDouble() >= 490000000);
    QVERIFY(summary.value("terminal_lateness_lower_bound_ns").toDouble() >= 470000000);
    QVERIFY(summary.value("covered_max_lateness_ns").toDouble() >= 470000000);
    QVERIFY(summary.value("terminal_interval_accounted").toBool());
    QCOMPARE(summary.value("elapsed_ns"), tail.value("end_elapsed_ns"));
    QCOMPARE(summary.value("samples").toInt(), int(callbacks_before));
#endif
}

void UiWorkerTests::headerIdentityInvalidatesStakeCache()
{
    const auto restore_settings = PreserveApplicationSettings();
    TestingSetup setup{ChainType::REGTEST};
    auto node = interfaces::MakeNode(setup.m_node);
    std::vector<CBlockIndex> headers(1602);
    std::vector<uint256> hashes(headers.size());
    for (size_t i = 0; i < headers.size(); ++i) {
        hashes[i] = uint256S(strprintf("%064x", i + 1));
        headers[i].phashBlock = &hashes[i];
        headers[i].pprev = i ? &headers[i - 1] : nullptr;
        headers[i].nHeight = i;
        headers[i].nTime = 100000 + i * 64;
        headers[i].nBits = 0x1d00ffff;
        if (i % 20 == 0) headers[i].SetProofOfStake();
    }
    ClientModel model(*node, nullptr);
    auto& chainman = *setup.m_node.chainman;
    CBlockIndex* saved;
    {
        LOCK(::cs_main);
        saved = chainman.m_best_header;
        chainman.m_best_header = &headers[1499];
    }
    auto restore = interfaces::MakeCleanupHandler([&] {
        LOCK(::cs_main);
        chainman.m_best_header = saved;
    });
    const auto notify_header = [&](size_t index) {
        WITH_LOCK(::cs_main, chainman.m_best_header = &headers[index]);
        // The real signal intentionally carries height/time only, no hash.
        uiInterface.NotifyHeaderTip(SynchronizationState::POST_INIT, headers[index].nHeight, headers[index].nTime, false);
    };
    notify_header(1499);
    QVERIFY(!model.cachedPoSKernelPS().has_value());
    QTRY_VERIFY_WITH_TIMEOUT(model.cachedPoSKernelPS().has_value(), 5000);
    notify_header(1500);
    QVERIFY(!model.cachedPoSKernelPS().has_value());
    QTRY_VERIFY_WITH_TIMEOUT(model.cachedPoSKernelPS().has_value(), 5000);
    // Distinct header hash at the same height is also invalidating.
    headers[1601].pprev = &headers[1499];
    headers[1601].nHeight = headers[1500].nHeight;
    notify_header(1601);
    QVERIFY(!model.cachedPoSKernelPS().has_value());
    QTRY_VERIFY_WITH_TIMEOUT(model.cachedPoSKernelPS().has_value(), 5000);
    // A current, complete but zero-work estimate must also remain unavailable.
    notify_header(0);
    for (int attempt = 0; attempt < 8; ++attempt) {
        QVERIFY(!model.cachedPoSKernelPS().has_value());
        QTest::qWait(100);
    }
    model.beginShutdown();
    QTRY_VERIFY_WITH_TIMEOUT(model.shutdownReady(), 3000);
    // Model is destroyed before the synthetic header storage, even on failure.
}

void UiWorkerTests::consoleRejectsAfterShutdown()
{
    const auto restore_settings = PreserveApplicationSettings();
    TestingSetup setup{ChainType::REGTEST};
    auto node = interfaces::MakeNode(setup.m_node);
    const std::unique_ptr<const PlatformStyle> style{PlatformStyle::instantiate("other")};
    ClientModel model(*node, nullptr);
    RPCConsole console(*node, style.get(), nullptr);
    console.setClientModel(&model); // Starts the real owned executor thread.
    auto cleanup = interfaces::MakeCleanupHandler([&] {
        console.beginShutdown();
        console.setClientModel(nullptr); // Safe join even on an early test return.
    });
    auto* input = console.findChild<QLineEdit*>("lineEdit");
    auto* output = console.findChild<QTextEdit*>("messagesWidget");
    QVERIFY(input);
    QVERIFY(output);
    console.beginShutdown();
    QTRY_VERIFY_WITH_TIMEOUT(console.shutdownReady(), 3000);
    const auto before = output->toPlainText();
    // A queued/programmatic slot call must be rejected after executor deletion,
    // including the special stop shortcut that bypasses normal RPC execution.
    for (const auto& command : {QStringLiteral("getblockchaininfo"), QStringLiteral("stop")}) {
        input->setText(command);
        QVERIFY(QMetaObject::invokeMethod(&console, "on_lineEdit_returnPressed", Qt::QueuedConnection));
        bool delivered{false};
        QMetaObject::invokeMethod(&console, [&] { delivered = true; }, Qt::QueuedConnection);
        QTRY_VERIFY_WITH_TIMEOUT(delivered, 3000);
        QCOMPARE(input->text(), command);
        QCOMPARE(output->toPlainText(), before);
        QVERIFY(!node->shutdownRequested());
    }
}


void UiWorkerTests::peerSnapshotsDoNotBlockGui()
{
    const auto restore_settings = PreserveApplicationSettings();
    TestingSetup setup{ChainType::REGTEST, {"-staking=0", "-powmining=0"}};
    auto node = interfaces::MakeNode(setup.m_node);
    ClientModel client(*node, nullptr);
    PeerTableModel& model = *client.getPeerTableModel();
    struct Held {
        std::promise<void> release_first, release_shutdown;
        std::atomic<int> calls{0}, phase{0};
        std::atomic<bool> first_entered{false}, shutdown_entered{false}, expired{false};
    };
    auto held = std::make_shared<Held>();
    const auto first = held->release_first.get_future().share();
    const auto last = held->release_shutdown.get_future().share();
    bool first_released{false}, last_released{false};
    auto cleanup = interfaces::MakeCleanupHandler([&] {
        if (!first_released) held->release_first.set_value();
        if (!last_released) held->release_shutdown.set_value();
        client.beginShutdown();
        client.m_thread->wait(); // Holder deadlines independently bound regressions.
    });
    PeerTableWorker* worker = model.m_worker.data();
    QVERIFY(QMetaObject::invokeMethod(worker, [worker, held, first, last] {
        worker->m_collect = [held, first, last]() -> PeerStatsSnapshot {
            ++held->calls;
            const int phase = held->phase.load();
            if (phase == 0) {
                held->first_entered = true;
                if (first.wait_for(std::chrono::seconds{8}) == std::future_status::timeout) held->expired = true;
            } else if (phase == 2) {
                held->shutdown_entered = true;
                if (last.wait_for(std::chrono::seconds{8}) == std::future_status::timeout) held->expired = true;
            }
            auto peers = std::make_shared<QList<CNodeCombinedStats>>();
            const std::vector<NodeId> ids = phase == 3 ? std::vector<NodeId>{20, 20} : std::vector<NodeId>{20, 10, 30};
            for (NodeId id : ids) {
                CNodeCombinedStats row{};
                row.nodeStats.nodeid = id;
                row.nodeStats.m_addr_name = "synthetic-peer";
                peers->append(row);
            }
            return peers;
        };
    }, Qt::QueuedConnection));
    QWidget page;
    VisibilityController visibility(page, [&](bool active) {
        if (active) model.startAutoRefresh(); else model.stopAutoRefresh();
    });
    QTimer heartbeat;
    int ticks{0};
    connect(&heartbeat, &QTimer::timeout, &page, [&] { ++ticks; });
    heartbeat.start(5);
    page.show();
    visibility.refresh();
    QTRY_VERIFY_WITH_TIMEOUT(held->first_entered.load(), 3000);
    const int before_ticks = ticks;
    for (int i = 0; i < 100; ++i) model.refresh();
    QTRY_VERIFY_WITH_TIMEOUT(ticks >= before_ticks + 5, 1000);
    QCOMPARE(held->calls.load(), 1);
    QVERIFY(!held->expired.load());

    // A count notification is readable during the held networking collector.
    // Stale generation and detected mixed total observations must not win.
    {
        LOCK(client.m_connection_cache_mutex);
        client.m_connection_counts = {};
    }
    QCOMPARE(client.getNumConnections(), -1);
    QCOMPARE(client.getBlockSource(), BlockSource::UNKNOWN);
    uiInterface.NotifyNumConnectionsChanged(5);
    const uint64_t old_generation = WITH_LOCK(client.m_connection_cache_mutex, return client.m_connection_generation);
    QCOMPARE(client.getNumConnections(), 5);
    QCOMPARE(client.getNumConnections(CONNECTIONS_IN), -1);
    QCOMPARE(client.getBlockSource(), BlockSource::NETWORK);
    uiInterface.NotifyNumConnectionsChanged(6);
    client.publishConnectionCounts(old_generation, 5, 2, 3, 5);
    QCOMPARE(client.getNumConnections(), 6);
    const uint64_t generation = WITH_LOCK(client.m_connection_cache_mutex, return client.m_connection_generation);
    client.publishConnectionCounts(generation, 5, 2, 4, 6);
    QCOMPARE(client.getNumConnections(CONNECTIONS_IN), -1);
    client.publishConnectionCounts(generation, 6, 2, 4, 6);
    const auto counts = client.getConnectionCounts();
    QCOMPARE(counts.total, 6);
    QCOMPARE(counts.inbound, 2);
    QCOMPARE(counts.outbound, 4);

    page.hide();
    QVERIFY(!model.m_active);
    held->phase = 1;
    held->release_first.set_value();
    first_released = true;
    QTRY_VERIFY_WITH_TIMEOUT(!model.m_in_flight, 3000);
    QCOMPARE(model.rowCount(), 0); // Late hidden result was discarded.
    QCOMPARE(held->calls.load(), 1); // Pending refresh was cancelled.
    page.show();
    visibility.refresh();
    QTRY_COMPARE_WITH_TIMEOUT(model.rowCount(), 3, 3000);
    QCOMPARE(model.index(0, PeerTableModel::NetNodeId).data().toLongLong(), qlonglong{10});
    QCOMPARE(model.index(1, PeerTableModel::NetNodeId).data().toLongLong(), qlonglong{20});
    QCOMPARE(model.index(2, PeerTableModel::NetNodeId).data().toLongLong(), qlonglong{30});
    // Exercise duplicate rejection through the real queued worker path. A
    // terminal unavailable result must release the singleflight request.
    model.stopAutoRefresh();
    held->phase = 3;
    QSignalSpy unavailable(&model, &PeerTableModel::refreshCompleted);
    model.startAutoRefresh();
    QTRY_VERIFY_WITH_TIMEOUT(!unavailable.isEmpty(), 3000);
    QVERIFY(!unavailable.last().at(0).toBool());
    model.stopAutoRefresh();
    QTRY_VERIFY_WITH_TIMEOUT(!model.m_in_flight, 3000);
    QCOMPARE(model.rowCount(), 3);
    model.startAutoRefresh();
    page.showMinimized();
    visibility.refresh();
    QVERIFY(!model.m_active);
    page.hide();
    held->phase = 2;
    page.showNormal();
    visibility.refresh();
    QTRY_VERIFY_WITH_TIMEOUT(held->shutdown_entered.load(), 3000);
    const int shutdown_ticks = ticks;
    QSignalSpy publications(&model, &QAbstractItemModel::dataChanged);
    QElapsedTimer elapsed;
    elapsed.start();
    client.beginShutdown();
    QVERIFY(elapsed.elapsed() < 250);
    QVERIFY(!held->expired.load());
    QVERIFY(!client.shutdownReady());
    QTRY_VERIFY_WITH_TIMEOUT(ticks >= shutdown_ticks + 5, 1000);
    held->release_shutdown.set_value();
    last_released = true;
    QTRY_VERIFY_WITH_TIMEOUT(client.shutdownReady(), 3000);
    QCoreApplication::processEvents();
    QCOMPARE(publications.count(), 0);
    QVERIFY(!held->expired.load());
    QVERIFY(model.m_worker.isNull());
}

void UiWorkerTests::peerRowsPreserveIdentity()
{
    const auto restore_settings = PreserveApplicationSettings();
    TestingSetup setup{ChainType::REGTEST, {"-staking=0", "-powmining=0"}};
    auto node = interfaces::MakeNode(setup.m_node);
    ClientModel client(*node, nullptr);
    client.beginShutdown();
    QTRY_VERIFY_WITH_TIMEOUT(client.shutdownReady(), 3000);
    PeerTableModel& model = *client.getPeerTableModel();
    const auto rows = [](std::initializer_list<NodeId> ids, const std::string& address) {
        QList<CNodeCombinedStats> peers;
        for (NodeId id : ids) {
            CNodeCombinedStats row{};
            row.nodeStats.nodeid = id;
            row.nodeStats.m_addr_name = address;
            peers.append(row);
        }
        return peers;
    };
    model.publishSnapshot(rows({10, 20, 30}, "old"));
    QPersistentModelIndex retained(model.index(1, PeerTableModel::NetNodeId));
    QPersistentModelIndex removed(model.index(0, PeerTableModel::NetNodeId));
    auto* proxy = client.peerTableSortProxy();
    proxy->sort(PeerTableModel::NetNodeId);
    QPersistentModelIndex proxy_retained(proxy->mapFromSource(retained));
    QItemSelectionModel selection(proxy);
    selection.select(proxy_retained, QItemSelectionModel::Select | QItemSelectionModel::Rows);
    model.publishSnapshot(rows({10, 20, 30}, "new"));
    QCOMPARE(retained.data().toLongLong(), qlonglong{20});
    const auto current = retained.data(PeerTableModel::StatsRole).value<CNodeCombinedStats*>();
    QVERIFY(current);
    QCOMPARE(QString::fromStdString(current->nodeStats.m_addr_name), QStringLiteral("new"));
    model.publishSnapshot(rows({20, 25, 30}, "churn"));
    QVERIFY(!removed.isValid());
    QVERIFY(retained.isValid());
    QCOMPARE(retained.row(), 0);
    QCOMPARE(retained.data().toLongLong(), qlonglong{20});
    QCOMPARE(proxy_retained.data().toLongLong(), qlonglong{20});
    QCOMPARE(selection.selectedRows().size(), 1);
    QCOMPARE(selection.selectedRows().front().data().toLongLong(), qlonglong{20});
    model.publishSnapshot(rows({5, 20, 25, 30}, "insert-before"));
    QCOMPARE(retained.row(), 1);
    QCOMPARE(retained.data().toLongLong(), qlonglong{20});
    QStandardItemModel foreign(1, 1);
    QVERIFY(!model.data(foreign.index(0, 0)).isValid());
    QVERIFY(!model.index(99, 0).isValid());
    QVERIFY(!model.index(0, 0, model.index(0, 0)).isValid());
    model.publishSnapshot({});
    QVERIFY(!retained.isValid());
    QCOMPARE(selection.selectedRows().size(), 0);
}

namespace {
// A normal Qt event loop, with a bounded deadline. Unlike qWait polling this
// continues delivering cooperative zero-timer model work without sleeping it.
bool WaitForPaintCondition(const std::function<bool()>& condition, int timeout_ms)
{
    if (condition()) return true;
    QEventLoop loop;
    QTimer deadline, observe;
    QElapsedTimer elapsed;
    deadline.setSingleShot(true);
    deadline.setTimerType(Qt::PreciseTimer);
    observe.setInterval(5);
    QObject::connect(&deadline, &QTimer::timeout, &loop, &QEventLoop::quit);
    QObject::connect(&observe, &QTimer::timeout, &loop, [&] { if (condition()) loop.quit(); });
    elapsed.start();
    deadline.start(timeout_ms);
    observe.start();
    loop.exec();
    return condition() && elapsed.elapsed() <= timeout_ms;
}
class ConsumeViewportPaint : public QObject
{
    bool eventFilter(QObject*, QEvent* event) override { return event->type() == QEvent::Paint; }
};
} // namespace

void UiWorkerTests::deliveredPaintCalibration()
{
#ifdef Q_OS_WIN
    QSKIP("Secure paint output requires POSIX");
#else
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QMainWindow window;
    auto* scene = UiPaintCalibration::attachToMainWindow(&window);
    window.resize(800, 600);
    window.show();
    QVERIFY(QTest::qWaitForWindowExposed(&window, 3000));
    QVERIFY(!scene->isWindow());
    QCOMPARE(scene->window(), static_cast<QWidget*>(&window));
    auto* dock = window.findChild<QDockWidget*>(QStringLiteral("developerPaintCalibrationDock"));
    QVERIFY(dock);
    QVERIFY(!dock->isFloating());
    QVERIFY(!dock->toggleViewAction()->isEnabled());
    QCOMPARE(dock->features(), QDockWidget::DockWidgetFeatures(QDockWidget::NoDockWidgetFeatures));
    UiPaintProbe probe;
    QString error;
    const auto path = directory.filePath(QStringLiteral("paint.json"));
    QVERIFY2(probe.start(path, error), qPrintable(error));
    for (int index = 0; index < 4; ++index) {
        scene->delays()->setCurrentIndex(index);
        const auto before = probe.records().size();
        // This goes through BitcoinApplication::notify and the actual visible
        // calibration table's original QTableView paintEvent. QTest delivery is
        // synthetic, not a claim about physical hardware input or the GUI exe.
        QTest::mouseClick(scene->runButton(), Qt::LeftButton);
        QVERIFY(probe.records().size() > before);
        const auto trial = probe.records().size() - 1;
        QVERIFY(WaitForPaintCondition([&] { return probe.records()[trial].outcome != UiPaintProbe::Outcome::PENDING; }, 4000));
        const auto& record = probe.records()[trial];
        QCOMPARE(int(record.action), int(UiPaintProbe::Action::CALIBRATION));
        QCOMPARE(int(record.outcome), int(UiPaintProbe::Outcome::PAINTED));
        QVERIFY(record.calibration);
        QVERIFY(record.input != 0);
        QCOMPARE(record.requested_delay_ms, qint64(scene->delays()->currentData().toInt()));
        QVERIFY(record.actual_delay_ns >= record.requested_delay_ms * 1000000LL);
        QVERIFY(record.paint_end_ns >= record.paint_begin_ns);
        QVERIFY(record.paint_begin_ns >= record.ready_ns);
        QVERIFY(record.paint_end_ns - record.delivered_ns >= record.actual_delay_ns);
    }
    QVERIFY(probe.slowNotifyJournal().slow() >= 3); // Existing 100/500/1500 ms callbacks, not an accuracy/overhead claim.
    QVERIFY2(probe.finish(error), qPrintable(error));
    QFile file(path);
    QVERIFY(file.open(QIODevice::ReadOnly));
    const auto document = QJsonDocument::fromJson(file.readAll()).object();
    QCOMPARE(document.value("schema").toString(), QStringLiteral("blackcoin.qt-delivery-paint.v1"));
    QVERIFY(document.value("complete").toBool());
    QVERIFY(document.value("storage_lossless").toBool());
    QVERIFY(!document.value("physical_input_to_display").toBool());
    QCOMPARE(document.value("records").toArray().size(), int(probe.records().size()));
#endif
}

void UiWorkerTests::deliveredPaintRejectsConsumedEvents()
{
#ifdef Q_OS_WIN
    QSKIP("Secure paint output requires POSIX");
#else
    QTemporaryDir directory;
    UiPaintTableView table;
    table.setMeasurementRole(UiPaintProbe::Role::PEERS);
    QStandardItemModel model(3, 1);
    table.setModel(&model);
    table.show();
    QVERIFY(QTest::qWaitForWindowExposed(&table, 3000));
    UiPaintProbe probe(32, 50000000); // Short test deadline, no product budget change.
    QString error;
    QVERIFY2(probe.start(directory.filePath(QStringLiteral("consumed.json")), error), qPrintable(error));
    table.measurementAction(UiPaintProbe::Action::ROW);
    QCOMPARE(int(probe.records().back().outcome), int(UiPaintProbe::Outcome::NO_DELIVERED_INPUT));
    ConsumeViewportPaint filter;
    table.viewport()->installEventFilter(&filter);
    QTest::mouseClick(table.viewport(), Qt::LeftButton, Qt::NoModifier, table.visualRect(model.index(2, 0)).center());
    const auto trial = probe.records().size() - 1;
    QVERIFY(probe.records()[trial].input != 0);
    QVERIFY(WaitForPaintCondition([&] { return probe.records()[trial].outcome != UiPaintProbe::Outcome::PENDING; }, 1500));
    QCOMPARE(int(probe.records()[trial].outcome), int(UiPaintProbe::Outcome::TIMEOUT));
    QCOMPARE(probe.records()[trial].paint_end_ns, qint64{0});
    table.viewport()->removeEventFilter(&filter);
    QVERIFY2(probe.finish(error), qPrintable(error));
#endif
}

void UiWorkerTests::deliveredPaintLifecycleAndBounds()
{
#ifdef Q_OS_WIN
    QSKIP("Secure paint output requires POSIX");
#else
    QTemporaryDir directory;
    UiPaintProbe probe(6);
    QString error;
    QVERIFY2(probe.start(directory.filePath(QStringLiteral("lifecycle.json")), error), qPrintable(error));
    auto table = std::make_unique<UiPaintTableView>();
    table->setMeasurementRole(UiPaintProbe::Role::PEERS);
    QStandardItemModel first(2, 1), replacement(2, 1);
    table->setModel(&first);
    // Deterministic dispatcher-scope logic checks. No claim that these manually
    // scoped events are actual platform input or an exact GUI calibration.
    const auto begin = [&] {
        QKeyEvent event(QEvent::KeyPress, Qt::Key_Down, Qt::NoModifier);
        UiPaintProbe::NotifyScope dispatch(table.get(), &event);
        table->measurementAction(UiPaintProbe::Action::ROW);
    };
    begin();
    begin();
    QCOMPARE(int(probe.records()[0].outcome), int(UiPaintProbe::Outcome::OVERLAPPED));
    table->measurementPending(); // Outside the original input's dispatch.
    QCOMPARE(int(probe.records()[1].outcome), int(UiPaintProbe::Outcome::GENERATION_CHANGED));
    begin();
    table->setModel(&replacement);
    QCOMPARE(int(probe.records()[2].outcome), int(UiPaintProbe::Outcome::REBOUND));
    const auto old_target = probe.records()[2].target;
    begin();
    QVERIFY(probe.records()[3].target != old_target);
    table.reset();
    QCOMPARE(int(probe.records()[3].outcome), int(UiPaintProbe::Outcome::DESTROYED));
    table = std::make_unique<UiPaintTableView>();
    table->setModel(&first);
    begin();
    probe.cancel(table->viewport(), UiPaintProbe::Outcome::HIDDEN);
    QCOMPARE(int(probe.records()[4].outcome), int(UiPaintProbe::Outcome::HIDDEN));
    begin();
    begin();
    QCOMPARE(probe.records().size(), size_t{6});
    QCOMPARE(probe.dropped(), quint64{1});
    QVERIFY2(probe.finish(error), qPrintable(error));
    QFile file(directory.filePath(QStringLiteral("lifecycle.json")));
    QVERIFY(file.open(QIODevice::ReadOnly));
    QVERIFY(!QJsonDocument::fromJson(file.readAll()).object().value("storage_lossless").toBool());
    QVERIFY(UiPaintProbe::current() == nullptr);
#endif
}

void UiWorkerTests::deliveredPaintGenerationAndRestore()
{
#ifdef Q_OS_WIN
    QSKIP("Secure paint output requires POSIX");
#else
    QTemporaryDir directory;
    UiPaintTableView table;
    QStandardItemModel model(2, 1);
    table.setModel(&model);
    table.show();
    QVERIFY(QTest::qWaitForWindowExposed(&table, 3000));
    UiPaintProbe probe;
    QString error;
    QVERIFY2(probe.start(directory.filePath(QStringLiteral("generations.json")), error), qPrintable(error));
    {
        QKeyEvent event(QEvent::KeyPress, Qt::Key_A, Qt::NoModifier);
        event.setTimestamp(123456); // Recorded only, never mixed with QElapsedTimer.
        UiPaintProbe::NotifyScope dispatch(&table, &event);
        table.measurementAction(UiPaintProbe::Action::FILTER_RESULT, true, {}, UiPaintProbe::FilterChannel::SEARCH);
    }
    table.measurementDeferred(true, UiPaintProbe::FilterChannel::SEARCH);
    table.measurementPending();
    table.measurementDeferred(false, UiPaintProbe::FilterChannel::SEARCH);
    QCOMPARE(int(probe.records().back().outcome), int(UiPaintProbe::Outcome::PENDING));
    const auto generation = probe.records().back().generation;
    table.measurementReady();
    QVERIFY(probe.records().back().ready_ns > 0);
    QCOMPARE(probe.records().back().raw_input_timestamp_ms, quint64{123456});
    const auto partial = probe.beforePaint(table.viewport(), QRegion(QRect(0, 0, 1, 1)));
    QVERIFY(!partial.covered);
    probe.afterPaint(table.viewport(), partial);
    QCOMPARE(int(probe.records().back().outcome), int(UiPaintProbe::Outcome::PENDING));
    QCOMPARE(probe.records().back().unconfirmed_paints, quint64{1});
    const auto token = probe.beforePaint(table.viewport(), QRegion(table.viewport()->rect()));
    table.measurementPending(); // Invalidates a paint token before completion.
    probe.afterPaint(table.viewport(), token);
    QCOMPARE(int(probe.records().back().outcome), int(UiPaintProbe::Outcome::GENERATION_CHANGED));
    QCOMPARE(probe.records().back().generation, generation);
    table.measurementReady();
    {
        QKeyEvent event(QEvent::KeyPress, Qt::Key_A, Qt::NoModifier);
        UiPaintProbe::NotifyScope dispatch(&table, &event);
        table.measurementAction(UiPaintProbe::Action::FILTER_RESULT, true, {}, UiPaintProbe::FilterChannel::SEARCH);
    }
    table.measurementDeferred(true, UiPaintProbe::FilterChannel::AMOUNT);
    table.measurementPending();
    table.measurementDeferred(false, UiPaintProbe::FilterChannel::AMOUNT);
    QCOMPARE(int(probe.records().back().outcome), int(UiPaintProbe::Outcome::GENERATION_CHANGED));
    table.measurementReady();
    // Simulated Qt restore-event scope. This validates attribution and nested
    // child-show handling, not macOS native restore scheduling or display.
    QWindowStateChangeEvent restored(Qt::WindowMinimized);
    {
        UiPaintProbe::NotifyScope dispatch(&table, &restored);
        const auto count = probe.records().size();
        QCOMPARE(int(probe.records().back().action), int(UiPaintProbe::Action::RESTORE));
        table.measurementAction(UiPaintProbe::Action::NAVIGATE);
        QCOMPARE(probe.records().size(), count);
        table.measurementPending();
        table.measurementReady();
        QCOMPARE(int(probe.records().back().outcome), int(UiPaintProbe::Outcome::PENDING));
    }
    QCOMPARE(probe.records().back().input, quint64{0});
    QCOMPARE(probe.records().back().event_type, int(QEvent::WindowStateChange));
    QVERIFY2(probe.finish(error), qPrintable(error));
    QCOMPARE(int(probe.records().back().outcome), int(UiPaintProbe::Outcome::SHUTDOWN));
#endif
}

void UiWorkerTests::deliveredPaintFileGuards()
{
#ifdef Q_OS_WIN
    QSKIP("Secure paint output requires POSIX");
#else
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    QString error;
    UiPaintProbe relative;
    QVERIFY(!relative.start(QStringLiteral("relative-paint.json"), error));
    const auto path = directory.filePath(QStringLiteral("exclusive.json"));
    UiPaintProbe first;
    QVERIFY2(first.start(path, error), qPrintable(error));
    UiPaintProbe concurrent;
    QVERIFY(!concurrent.start(directory.filePath(QStringLiteral("other.json")), error));
    QVERIFY(first.finish(error));
    UiPaintProbe existing;
    QVERIFY(!existing.start(path, error));
    const auto link = directory.filePath(QStringLiteral("link.json"));
    QVERIFY(QFile::link(path, link));
    UiPaintProbe symlink;
    QVERIFY(!symlink.start(link, error));
    struct stat metadata{};
    QCOMPARE(::stat(QFile::encodeName(path).constData(), &metadata), 0);
    QCOMPARE(int(metadata.st_mode & 0777), 0600);
    QCOMPARE(metadata.st_uid, ::getuid());
#endif
}

void UiWorkerTests::slowNotifyJournal()
{
    UiSlowNotifyJournal bookkeeping;
    UiSlowNotifyJournal::Record record;
    record.started_ns = 1000;
    record.ended_ns = record.started_ns + UiSlowNotifyJournal::THRESHOLD_NS - 1;
    bookkeeping.complete(record);
    QCOMPARE(bookkeeping.completed(), quint64{1});
    QCOMPARE(bookkeeping.slow(), quint64{0});
    record.ended_ns += 1;
    for (size_t i = 0; i < UiSlowNotifyJournal::CAPACITY + 1; ++i) {
        record.sequence = i + 1;
        bookkeeping.complete(record);
    }
    QCOMPARE(bookkeeping.records().size(), UiSlowNotifyJournal::CAPACITY);
    QCOMPARE(bookkeeping.slow(), quint64(UiSlowNotifyJournal::CAPACITY + 1));
    QCOMPARE(bookkeeping.overflow(), quint64{1});
    // Above is deterministic bookkeeping with constructed timestamps, not
    // thousands of sleeps or performance evidence. One bounded real interval
    // below verifies nested scope parentage and exception unwind accounting.
#ifndef Q_OS_WIN
    QTemporaryDir directory;
    UiPaintProbe probe;
    QString error;
    QVERIFY2(probe.start(directory.filePath(QStringLiteral("notify.json")), error), qPrintable(error));
    QWidget receiver;
    QEvent outer_event(QEvent::User), inner_event(QEvent::User);
    {
        UiPaintProbe::NotifyScope outer(&receiver, &outer_event);
        try {
            UiPaintProbe::NotifyScope inner(&receiver, &inner_event);
            QThread::msleep(110);
            throw std::runtime_error("synthetic notify unwind");
        } catch (const std::runtime_error&) { }
    }
    const auto& records = probe.slowNotifyJournal().records();
    QCOMPARE(records.size(), size_t{2});
    const auto& inner = records[0];
    const auto& outer = records[1];
    QCOMPARE(inner.parent, outer.sequence);
    QCOMPARE(inner.depth, outer.depth + 1);
    QVERIFY(inner.started_ns >= outer.started_ns);
    QVERIFY(inner.ended_ns <= outer.ended_ns);
    QVERIFY(inner.exception);
    QVERIFY(!outer.exception);
    QCOMPARE(int(inner.receiver), int(UiSlowNotifyJournal::Receiver::WIDGET));
    QVERIFY2(probe.finish(error), qPrintable(error));
#endif
}

namespace {
//! Synthetic chain whose tips are published through the real Core signal, so
//! the test exercises ClientModel's handler exactly as the node does.
struct SyntheticTips {
    std::vector<CBlockIndex> index;
    std::vector<uint256> hashes;
    explicit SyntheticTips(size_t count) : index(count), hashes(count)
    {
        for (size_t i = 0; i < count; ++i) {
            hashes[i] = uint256S(strprintf("%064x", i + 1));
            index[i].phashBlock = &hashes[i];
            index[i].pprev = i ? &index[i - 1] : nullptr;
            index[i].nHeight = i;
            index[i].nTime = 1700000000 + i * 64;
            index[i].nChainTx = i + 1;
        }
    }
    void notify(size_t i, SynchronizationState state) { uiInterface.NotifyBlockTip(state, &index[i]); }
};

struct DeliveredTip {
    int height;
    qint64 time;
    SyncType type;
    SynchronizationState state;
};

//! Collects numBlocksChanged. The connection is direct, so the slot runs on the
//! emitting thread (SyncType and SynchronizationState are only registered as
//! Qt metatypes by the application); access is therefore locked.
struct TipCollector : QObject {
    mutable std::mutex mutex;
    std::vector<DeliveredTip> m_tips;
    explicit TipCollector(ClientModel& model)
    {
        connect(&model, &ClientModel::numBlocksChanged, this,
            [this](int height, const QDateTime& date, double, SyncType type, SynchronizationState state) {
                std::lock_guard<std::mutex> lock(mutex);
                m_tips.push_back({height, date.toSecsSinceEpoch(), type, state});
            }, Qt::DirectConnection);
    }
    std::vector<DeliveredTip> tips() const
    {
        std::lock_guard<std::mutex> lock(mutex);
        return m_tips;
    }
    void clear()
    {
        std::lock_guard<std::mutex> lock(mutex);
        m_tips.clear();
    }
    size_t count() const { return tips().size(); }
    int last_height() const
    {
        const auto all = tips();
        return all.empty() ? -1 : all.back().height;
    }
};
} // namespace

void UiWorkerTests::blockTipBurstIsCoalesced()
{
    const auto restore_settings = PreserveApplicationSettings();
    TestingSetup setup{ChainType::REGTEST};
    auto node = interfaces::MakeNode(setup.m_node);
    constexpr size_t BURST{5000};
    SyntheticTips chain(BURST);
    ClientModel model(*node, nullptr);
    TipCollector collector(model);
    auto cleanup = interfaces::MakeCleanupHandler([&] {
        model.beginShutdown();
        model.m_thread->wait();
    });
    // Outside initial block download (a catch-up after sleep) and inside it.
    for (const auto state : {SynchronizationState::POST_INIT, SynchronizationState::INIT_DOWNLOAD}) {
        collector.clear();
        const auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < BURST; ++i) chain.notify(i, state);
        const auto elapsed = std::chrono::steady_clock::now() - start;
        // The cached height is never throttled.
        QCOMPARE(model.getNumBlocks(), int(BURST - 1));
        // The newest tip is always delivered, even though the burst ended
        // between model-timer ticks.
        QTRY_COMPARE_WITH_TIMEOUT(collector.last_height(), int(BURST - 1), 5000);
        QTest::qWait(3 * MODEL_UPDATE_DELAY.count()); // nothing further may arrive
        const auto delivered = collector.tips();
        QCOMPARE(delivered.back().height, int(BURST - 1));
        QCOMPARE(delivered.back().time, qint64(chain.index[BURST - 1].nTime));
        QCOMPARE(int(delivered.back().state), int(state));
        // One leading emit, then at most one per MODEL_UPDATE_DELAY.
        const auto window_ms = std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count();
        // Flush spacing is 4/5 of the delay; +1 absorbs a stalled burst on a loaded host.
        const size_t bound = 2 + size_t(window_ms / 200) + 1;
        QVERIFY2(!delivered.empty() && delivered.size() <= bound,
            qPrintable(QStringLiteral("emitted %1 for %2 notifications in %3 ms (bound %4)")
                .arg(delivered.size()).arg(BURST).arg(window_ms).arg(bound)));
        for (const auto& tip : delivered) QCOMPARE(int(tip.type), int(SyncType::BLOCK_SYNC));
        // Delivered heights never move backwards.
        for (size_t i = 1; i < delivered.size(); ++i) QVERIFY(delivered[i].height > delivered[i - 1].height);
    }
}

void UiWorkerTests::blockTipSingleNotificationIsPrompt()
{
    const auto restore_settings = PreserveApplicationSettings();
    TestingSetup setup{ChainType::REGTEST};
    auto node = interfaces::MakeNode(setup.m_node);
    SyntheticTips chain(8);
    ClientModel model(*node, nullptr);
    TipCollector collector(model);
    auto cleanup = interfaces::MakeCleanupHandler([&] {
        model.beginShutdown();
        model.m_thread->wait();
    });
    // An isolated block is a leading-edge emit: delivered before notify()
    // returns, without waiting for a timer tick.
    chain.notify(3, SynchronizationState::POST_INIT);
    QCOMPARE(collector.count(), size_t{1});
    QCOMPARE(collector.last_height(), 3);
    QCOMPARE(int(collector.tips()[0].type), int(SyncType::BLOCK_SYNC));
    QCOMPARE(int(collector.tips()[0].state), int(SynchronizationState::POST_INIT));
    // After a quiet period the next isolated block is again immediate.
    QTest::qWait(2 * MODEL_UPDATE_DELAY.count());
    chain.notify(4, SynchronizationState::POST_INIT);
    QCOMPARE(collector.count(), size_t{2});
    QCOMPARE(collector.last_height(), 4);
    // A block right behind one that was just shown is held back, then
    // delivered by the timer rather than lost. The hold-back is only asserted
    // when the scheduler did not stall for most of the 200 ms spacing.
    const auto shown = std::chrono::steady_clock::now();
    chain.notify(5, SynchronizationState::POST_INIT);
    const bool quick = std::chrono::steady_clock::now() - shown < std::chrono::milliseconds(50);
    if (quick) QCOMPARE(collector.count(), size_t{2});
    QTRY_COMPARE_WITH_TIMEOUT(collector.last_height(), 5, 10000);
    QCOMPARE(collector.count(), size_t{3});
    QTest::qWait(3 * MODEL_UPDATE_DELAY.count());
    QCOMPARE(collector.count(), size_t{3});
}

void UiWorkerTests::blockTipShutdownDropsPending()
{
    const auto restore_settings = PreserveApplicationSettings();
    TestingSetup setup{ChainType::REGTEST};
    auto node = interfaces::MakeNode(setup.m_node);
    SyntheticTips chain(8);
    ClientModel model(*node, nullptr);
    TipCollector collector(model);
    auto cleanup = interfaces::MakeCleanupHandler([&] {
        model.beginShutdown();
        model.m_thread->wait();
    });
    chain.notify(1, SynchronizationState::POST_INIT); // leading edge
    const auto started = std::chrono::steady_clock::now();
    chain.notify(2, SynchronizationState::POST_INIT); // pending for the timer
    model.beginShutdown();
    const bool quick = std::chrono::steady_clock::now() - started < std::chrono::milliseconds(50);
    QTRY_VERIFY_WITH_TIMEOUT(model.shutdownReady(), 10000);
    // A flush before beginShutdown is only possible if this thread stalled
    // for >= 200 ms; the pending-drop is asserted for the normal case.
    if (quick) {
        QCOMPARE(collector.count(), size_t{1});
        QCOMPARE(collector.last_height(), 1);
    }
    const size_t settled = collector.count();
    const int settled_height = collector.last_height();
    // A tip offered once stopping has begun is cached but never emitted.
    chain.notify(3, SynchronizationState::POST_INIT);
    QCOMPARE(model.getNumBlocks(), 3);
    QTest::qWait(3 * MODEL_UPDATE_DELAY.count());
    QCOMPARE(collector.count(), settled);
    QCOMPARE(collector.last_height(), settled_height);
}
