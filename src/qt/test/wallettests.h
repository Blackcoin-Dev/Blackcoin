// Copyright (c) 2017-2020 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_TEST_WALLETTESTS_H
#define BITCOIN_QT_TEST_WALLETTESTS_H

#include <QObject>
#include <QTest>

namespace interfaces {
class Node;
} // namespace interfaces

class WalletModel;

class WalletTests : public QObject
{
 public:
    explicit WalletTests(interfaces::Node& node) : m_node(node) {}
    interfaces::Node& m_node;
    static QMetaObject::Connection traceStakingSnapshots(WalletModel& model);

    Q_OBJECT

private Q_SLOTS:
    void walletTests();
    void shutdownPublicationReadyOrdering();
    void stakingSnapshotContention();
    void receiveCapabilityContention_data();
    void receiveCapabilityContention();
    void receiveCapabilityLifecycle();
    void workerOutlivesShutdownRequest();
    void historyScaleBenchmark_data();
    void historyScaleBenchmark();
    void historyInitialLoad();
    void historyIncrementalUpdates_data();
    void historyIncrementalUpdates();
    void historyOrderOracle_data();
    void historyOrderOracle();
    void historyBlockAnnouncementBounded_data();
    void historyBlockAnnouncementBounded();
    void historyConfirmationNotStarved_data();
    void historyConfirmationNotStarved();
};

#endif // BITCOIN_QT_TEST_WALLETTESTS_H
