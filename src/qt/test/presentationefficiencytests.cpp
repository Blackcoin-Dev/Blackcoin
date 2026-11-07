// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/test/presentationefficiencytests.h>

#include <common/args.h>
#include <interfaces/handler.h>
#include <interfaces/node.h>
#include <qt/clientmodel.h>
#include <qt/guiconstants.h>
#include <qt/platformstyle.h>
#include <qt/rpcconsole.h>
#include <test/util/setup_common.h>
#include <univalue.h>

#include <QSignalSpy>
#include <QTest>

#include <utility>

#ifdef ENABLE_WALLET
#include <interfaces/wallet.h>
#include <qt/optionsmodel.h>
#include <qt/overviewpage.h>
#include <qt/recenttransactionproxy.h>
#include <qt/transactionfilterproxy.h>
#include <qt/transactionoverviewwidget.h>
#include <qt/transactionrecord.h>
#include <qt/transactiontablemodel.h>
#include <qt/walletmodel.h>
#include <script/solver.h>
#include <validation.h>
#include <wallet/test/util.h>
#include <wallet/wallet.h>

#include <QAbstractItemModelTester>
#include <QElapsedTimer>
#include <QItemSelectionModel>
#include <QTimer>

#include <algorithm>
#include <vector>
#endif // ENABLE_WALLET

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

#ifdef ENABLE_WALLET
namespace {
class HistoryModel final : public QAbstractTableModel
{
public:
    struct Entry {
        int id;
        int date;
        bool inactive{false};
    };

    explicit HistoryModel(int size)
    {
        m_entries.reserve(size + 10);
        for (int row = 0; row < size; ++row) m_entries.push_back({row, row});
    }

    int rowCount(const QModelIndex& parent = {}) const override { return parent.isValid() ? 0 : m_entries.size(); }
    int columnCount(const QModelIndex& parent = {}) const override { return parent.isValid() ? 0 : 6; }
    QVariant data(const QModelIndex& index, int role) const override
    {
        if (!index.isValid()) return {};
        const Entry& entry = m_entries.at(index.row());
        if (index.column() == TransactionTableModel::Date && role == Qt::EditRole) return entry.date;
        if (role == TransactionTableModel::TxHashRole || role == Qt::DisplayRole) return entry.id;
        if (role == TransactionTableModel::StatusRole) {
            return entry.inactive ? TransactionStatus::Conflicted : TransactionStatus::Confirmed;
        }
        return {};
    }

    void append(Entry entry)
    {
        const int row = rowCount();
        beginInsertRows({}, row, row);
        m_entries.push_back(entry);
        endInsertRows();
    }

    void change(int row, Entry entry, const QVector<int>& roles)
    {
        m_entries.at(row) = entry;
        Q_EMIT dataChanged(index(row, 0), index(row, columnCount() - 1), roles);
    }

    void remove(int row)
    {
        beginRemoveRows({}, row, row);
        m_entries.erase(m_entries.begin() + row);
        endRemoveRows();
    }

    void clear()
    {
        beginResetModel();
        m_entries.clear();
        endResetModel();
    }

private:
    std::vector<Entry> m_entries;
};

void SetRecentSort(TransactionFilterProxy& filter, HistoryModel& history)
{
    filter.setSourceModel(&history);
    filter.setDynamicSortFilter(true);
    filter.setSortRole(Qt::EditRole);
    filter.setShowInactive(false);
    filter.sort(TransactionTableModel::Date, Qt::DescendingOrder);
}
} // namespace

void PresentationEfficiencyTests::recentTransactionProjection()
{
    constexpr int HISTORY_SIZE{20'000};
    constexpr int LIMIT{5};

    // Measure delivery of the next event with the same production sort and
    // view on both paths. The legacy lane reproduces the former hide loop.
    const auto measure = [](bool bounded) {
        HistoryModel history{HISTORY_SIZE};
        TransactionFilterProxy filter;
        SetRecentSort(filter, history);
        RecentTransactionProxy projection{filter, LIMIT};
        TransactionOverviewWidget view;
        view.setModel(bounded ? static_cast<QAbstractItemModel*>(&projection) : &filter);
        view.setModelColumn(TransactionTableModel::ToAddress);
        int hide_calls{0};
        const auto hide_old_rows = [&] {
            for (int row = 0; row < filter.rowCount(); ++row) {
                view.setRowHidden(row, row >= LIMIT);
                ++hide_calls;
            }
        };
        if (!bounded) {
            hide_old_rows();
            QObject::connect(&filter, &QAbstractItemModel::rowsInserted, &view, hide_old_rows);
        }
        view.resize(480, 240);
        view.show();
        QCoreApplication::processEvents();
        hide_calls = 0;
        QElapsedTimer clock;
        clock.start();
        qint64 delivered_ns{-1};
        QTimer::singleShot(0, &view, [&] { delivered_ns = clock.nsecsElapsed(); });
        for (int n = 0; n < 8; ++n) history.append({HISTORY_SIZE + n, -n - 1});
        QCoreApplication::processEvents();
        return std::pair{hide_calls, delivered_ns};
    };
    const auto [old_hide_calls, old_event_ns] = measure(false);
    const auto [new_hide_calls, new_event_ns] = measure(true);
    QCOMPARE(old_hide_calls, 8 * HISTORY_SIZE + 36);
    QCOMPARE(new_hide_calls, 0);
    QVERIFY(old_event_ns >= 0 && new_event_ns >= 0);
    qInfo("Overview 20k rows, eight tail insertions: legacy %d hide calls and %.3f ms to next event, projected %d hide calls and %.3f ms",
          old_hide_calls, old_event_ns / 1e6, new_hide_calls, new_event_ns / 1e6);

    auto history = std::make_unique<HistoryModel>(HISTORY_SIZE);
    auto filter = std::make_unique<TransactionFilterProxy>();
    SetRecentSort(*filter, *history);
    RecentTransactionProxy projection{*filter, LIMIT};
    QAbstractItemModelTester tester{&projection, QAbstractItemModelTester::FailureReportingMode::QtTest};
    QSignalSpy reset{&projection, &QAbstractItemModel::modelReset};
    QSignalSpy changed{&projection, &QAbstractItemModel::dataChanged};
    QItemSelectionModel selected{&projection};
    const auto id = [](const QModelIndex& index) { return index.data(TransactionTableModel::TxHashRole).toInt(); };
    const auto check_mapping = [&] {
        QCOMPARE(projection.rowCount(), std::min(LIMIT, filter->rowCount()));
        for (int row = 0; row < projection.rowCount(); ++row) {
            for (int column = 0; column < projection.columnCount(); ++column) {
                const QModelIndex recent = projection.index(row, column);
                const QModelIndex sorted = filter->index(row, column);
                QCOMPARE(projection.mapToSource(recent), sorted);
                QCOMPARE(projection.mapFromSource(sorted), recent);
                QCOMPARE(id(recent), id(filter->mapToSource(sorted)));
            }
        }
        QVERIFY(!projection.mapFromSource(filter->index(LIMIT, 0)).isValid());
    };
    check_mapping();
    QPersistentModelIndex pinned{projection.index(0, TransactionTableModel::ToAddress)};
    selected.select(pinned, QItemSelectionModel::Select);
    history->append({HISTORY_SIZE, -1});
    history->append({HISTORY_SIZE + 1, HISTORY_SIZE + 100, true});
    QCOMPARE(reset.count(), 0);
    QVERIFY(pinned.isValid());
    QVERIFY(selected.isSelected(pinned));

    history->change(HISTORY_SIZE - 1, {HISTORY_SIZE + 50, HISTORY_SIZE - 1}, {Qt::DisplayRole, TransactionTableModel::TxHashRole});
    QCOMPARE(changed.count(), 1);
    QCOMPARE(id(pinned), HISTORY_SIZE + 50);
    QCOMPARE(reset.count(), 0);

    // Same-date tie ordering is owned by the existing sort proxy.
    history->append({HISTORY_SIZE + 2, HISTORY_SIZE - 1});
    check_mapping();
    history->change(0, {0, HISTORY_SIZE + 200}, {Qt::EditRole});
    check_mapping();
    QCOMPARE(id(projection.index(0, 0)), 0);
    QVERIFY(!pinned.isValid());
    QVERIFY(!selected.hasSelection());
    history->change(0, {0, HISTORY_SIZE + 200, true}, {TransactionTableModel::StatusRole});
    check_mapping();
    QVERIFY(id(projection.index(0, 0)) != 0);

    bool saw_outgoing_mapping{false};
    const auto inspect_reset = QObject::connect(&projection, &QAbstractItemModel::modelAboutToBeReset, &projection, [&] {
        const QModelIndex old_top = projection.index(0, 0);
        const QModelIndex mapped = projection.mapToSource(old_top);
        saw_outgoing_mapping = mapped.isValid() && projection.mapFromSource(mapped) == old_top;
    });
    history->remove(filter->mapToSource(filter->index(0, 0)).row());
    QVERIFY(saw_outgoing_mapping);
    QObject::disconnect(inspect_reset);
    check_mapping();
    history->clear();
    check_mapping();
    history->append({123, 4});
    check_mapping();
    filter.reset();
    QCOMPARE(projection.rowCount(), 0);
    QVERIFY(!projection.index(0, 0).isValid());
}

void PresentationEfficiencyTests::recentTransactionClick()
{
    const auto restore_settings = PreserveApplicationSettings();
    TestingSetup test{ChainType::REGTEST, {"-staking=0", "-powmining=0"}};
    auto* previous = m_node.context();
    auto restore = interfaces::MakeCleanupHandler([&] { m_node.setContext(previous); });
    auto loader = interfaces::MakeWalletLoader(*test.m_node.chain, *Assert(test.m_node.args));
    test.m_node.wallet_loader = loader.get();
    m_node.setContext(&test.m_node);

    auto wallet = std::make_shared<wallet::CWallet>(test.m_node.chain.get(), "overview-click", wallet::CreateMockableWalletDatabase());
    QCOMPARE(wallet->LoadWallet(), wallet::DBErrors::LOAD_OK);
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        const auto* tip = Assert(test.m_node.chainman->ActiveChain().Tip());
        wallet->SetLastBlockProcessed(tip->nHeight, tip->GetBlockHash());
    }
    wallet->SetupLegacyScriptPubKeyMan();
    const auto destination = wallet->GetNewDestination(OutputType::BECH32, "overview");
    QVERIFY(destination);
    for (int i = 0; i < 8; ++i) {
        CMutableTransaction tx;
        tx.vin.emplace_back(COutPoint{uint256{1}, static_cast<uint32_t>(i)});
        tx.vout.emplace_back(COIN, GetScriptForDestination(*destination));
        QVERIFY(wallet->AddToWallet(MakeTransactionRef(std::move(tx)), wallet::TxStateInactive{}));
    }

    const std::unique_ptr<const PlatformStyle> style{PlatformStyle::instantiate("other")};
    OptionsModel options{m_node};
    bilingual_str error;
    QVERIFY(options.Init(error));
    ClientModel client{m_node, &options};
    WalletModel model{interfaces::MakeWallet(*loader->context(), wallet), client, style.get()};
    OverviewPage page{style.get()};
    page.setWalletModel(&model);
    auto* view = page.findChild<TransactionOverviewWidget*>("listTransactions");
    QVERIFY(view);
    QTRY_COMPARE_WITH_TIMEOUT(model.getTransactionTableModel()->rowCount({}), 8, 3000);
    QCOMPARE(view->model()->rowCount(), 5);
    const QModelIndex recent = view->model()->index(1, view->modelColumn());
    const auto txid = recent.data(TransactionTableModel::TxHashRole);
    QVERIFY(!txid.toString().isEmpty());
    QSignalSpy clicked{&page, &OverviewPage::transactionClicked};
    Q_EMIT view->clicked(recent);
    QCOMPARE(clicked.count(), 1);
    const QModelIndex original = qvariant_cast<QModelIndex>(clicked.takeFirst().at(0));
    QCOMPARE(original.model(), model.getTransactionTableModel());
    QCOMPARE(original.column(), TransactionTableModel::ToAddress);
    QCOMPARE(original.data(TransactionTableModel::TxHashRole), txid);
    page.setWalletModel(nullptr);
    QVERIFY(!view->model());
}
#endif // ENABLE_WALLET

void PresentationEfficiencyTests::peerPollingFollowsVisibility()
{
    const auto restore_settings = PreserveApplicationSettings();
    TestingSetup test{ChainType::REGTEST};
    auto* previous = m_node.context();
    auto restore = interfaces::MakeCleanupHandler([&] { m_node.setContext(previous); });
    m_node.setContext(&test.m_node);

    const std::unique_ptr<const PlatformStyle> style{PlatformStyle::instantiate("other")};
    ClientModel model{m_node, nullptr};
    RPCConsole console{m_node, style.get(), nullptr};
    auto detach = interfaces::MakeCleanupHandler([&] { console.setClientModel(nullptr); });
    QSignalSpy refreshed{model.getPeerTableModel(), &QAbstractItemModel::dataChanged};
    console.setClientModel(&model);
    QTest::qWait(2 * MODEL_UPDATE_DELAY.count());
    QCOMPARE(refreshed.count(), 0);
    console.setTabFocus(RPCConsole::TabTypes::CONSOLE);
    console.show();
    QTest::qWait(2 * MODEL_UPDATE_DELAY.count());
    QCOMPARE(refreshed.count(), 0);
    console.setTabFocus(RPCConsole::TabTypes::PEERS);
    QCOMPARE(refreshed.count(), 1);
    QTRY_VERIFY_WITH_TIMEOUT(refreshed.count() >= 2, 1000);
    console.setTabFocus(RPCConsole::TabTypes::GRAPH);
    const int stopped_count = refreshed.count();
    QTest::qWait(2 * MODEL_UPDATE_DELAY.count());
    QCOMPARE(refreshed.count(), stopped_count);
    console.setTabFocus(RPCConsole::TabTypes::PEERS);
    QCOMPARE(refreshed.count(), stopped_count + 1);
    console.hide();
    QTest::qWait(2 * MODEL_UPDATE_DELAY.count());
    QCOMPARE(refreshed.count(), stopped_count + 1);
    console.show();
    QCOMPARE(refreshed.count(), stopped_count + 2);
    console.setClientModel(nullptr);
    QTest::qWait(2 * MODEL_UPDATE_DELAY.count());
    QCOMPARE(refreshed.count(), stopped_count + 2);
    qInfo("Peer stats refreshes while hidden, on Console/Graph, or detached: 0. Peers entry, reentry and show refreshed immediately.");
}
