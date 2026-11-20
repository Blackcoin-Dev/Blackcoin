// Copyright (c) 2011-2022 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_PEERTABLEMODEL_H
#define BITCOIN_QT_PEERTABLEMODEL_H

#include <net_processing.h> // For CNodeStateStats
#include <net.h>

#include <QAbstractTableModel>
#include <QList>
#include <QModelIndex>
#include <QStringList>
#include <QVariant>
#include <QPointer>

#include <atomic>
#include <functional>
#include <memory>
#include <utility>

class PeerTablePriv;

namespace interfaces {
class Node;
}

QT_BEGIN_NAMESPACE
class QTimer;
class QThread;
QT_END_NAMESPACE

struct CNodeCombinedStats {
    CNodeStats nodeStats;
    CNodeStateStats nodeStateStats;
    bool fNodeStateStatsAvailable;
};
Q_DECLARE_METATYPE(CNodeCombinedStats*)
using PeerStatsSnapshot = std::shared_ptr<const QList<CNodeCombinedStats>>;
using PeerSnapshotCollector = std::function<PeerStatsSnapshot()>;
Q_DECLARE_METATYPE(PeerStatsSnapshot)

/** Runs only on the existing ClientModel worker; never owns a GUI model pointer. */
class PeerTableWorker final : public QObject
{
    Q_OBJECT
public:
    PeerTableWorker(PeerSnapshotCollector collect, std::shared_ptr<std::atomic<quint64>> active_generation)
        : m_collect(std::move(collect)), m_active_generation(std::move(active_generation)) {}
    void collect(quint64 generation);
Q_SIGNALS:
    void snapshotReady(quint64 generation, PeerStatsSnapshot snapshot);
private:
    friend class UiWorkerTests;
    PeerSnapshotCollector m_collect;
    std::shared_ptr<std::atomic<quint64>> m_active_generation;
};

/**
   Qt model providing information about connected peers, similar to the
   "getpeerinfo" RPC call. Used by the rpc console UI.
 */
class PeerTableModel : public QAbstractTableModel
{
    Q_OBJECT

public:
    explicit PeerTableModel(interfaces::Node& node, QThread* worker_thread, QObject* parent);
    ~PeerTableModel();
    void startAutoRefresh();
    void stopAutoRefresh();
    void beginShutdown();

    enum ColumnIndex {
        NetNodeId = 0,
        Age,
        Address,
        Direction,
        ConnectionType,
        Network,
        Ping,
        Sent,
        Received,
        Subversion
    };

    enum {
        //! Current row pointer, for immediate GUI-thread use only; never retain it.
        StatsRole = Qt::UserRole,
    };

    /** @name Methods overridden from QAbstractTableModel
        @{*/
    int rowCount(const QModelIndex& parent = QModelIndex()) const override;
    int columnCount(const QModelIndex& parent = QModelIndex()) const override;
    QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override;
    QModelIndex index(int row, int column, const QModelIndex& parent = QModelIndex()) const override;
    Qt::ItemFlags flags(const QModelIndex &index) const override;
    /*@}*/

public Q_SLOTS:
    void refresh();

Q_SIGNALS:
    //! A current visible refresh finished; false means the Node snapshot was unavailable.
    void refreshCompleted(bool available);

private:
    friend class UiWorkerTests;
    PeerTableModel(PeerSnapshotCollector collector, QThread* worker_thread, QObject* parent);
    void snapshotReady(quint64 generation, PeerStatsSnapshot snapshot);
    void publishSnapshot(const QList<CNodeCombinedStats>& peers);
    //! Internal peer data structure.
    QList<CNodeCombinedStats> m_peers_data{};
    std::shared_ptr<std::atomic<quint64>> m_active_generation{std::make_shared<std::atomic<quint64>>(0)};
    QPointer<PeerTableWorker> m_worker;
    quint64 m_generation{0};
    bool m_active{false};
    bool m_stopping{false};
    bool m_in_flight{false};
    bool m_refresh_pending{false};
    const QStringList columns{
        /*: Title of Peers Table column which contains a
            unique number used to identify a connection. */
        tr("Peer"),
        /*: Title of Peers Table column which indicates the duration (length of time)
            since the peer connection started. */
        tr("Age"),
        /*: Title of Peers Table column which contains the
            IP/Onion/I2P address of the connected peer. */
        tr("Address"),
        /*: Title of Peers Table column which indicates the direction
            the peer connection was initiated from. */
        tr("Direction"),
        /*: Title of Peers Table column which describes the type of
            peer connection. The "type" describes why the connection exists. */
        tr("Type"),
        /*: Title of Peers Table column which states the network the peer
            connected through. */
        tr("Network"),
        /*: Title of Peers Table column which indicates the current latency
            of the connection with the peer. */
        tr("Ping"),
        /*: Title of Peers Table column which indicates the total amount of
            network information we have sent to the peer. */
        tr("Sent"),
        /*: Title of Peers Table column which indicates the total amount of
            network information we have received from the peer. */
        tr("Received"),
        /*: Title of Peers Table column which contains the peer's
            User Agent string. */
        tr("User Agent")};
    QTimer* timer{nullptr};
};

#endif // BITCOIN_QT_PEERTABLEMODEL_H
