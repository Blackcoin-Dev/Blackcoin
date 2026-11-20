// Copyright (c) 2011-2022 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/peertablemodel.h>

#include <qt/guiconstants.h>
#include <qt/guiutil.h>

#include <interfaces/node.h>

#include <utility>
#include <algorithm>

#include <QList>
#include <QTimer>
#include <QThread>

void PeerTableWorker::collect(quint64 generation)
{
    Q_ASSERT(QThread::currentThread() == thread());
    PeerStatsSnapshot snapshot;
    if (m_active_generation->load(std::memory_order_acquire) == generation) {
        const auto collected = m_collect();
        if (collected) {
            // Concurrent inbound/outbound creation can append NodeIds out of
            // order. Normalize on the worker; duplicate identities fail closed.
            auto normalized = std::make_shared<QList<CNodeCombinedStats>>(*collected);
            std::sort(normalized->begin(), normalized->end(), [](const auto& left, const auto& right) {
                return left.nodeStats.nodeid < right.nodeStats.nodeid;
            });
            const auto duplicate = std::adjacent_find(normalized->cbegin(), normalized->cend(), [](const auto& left, const auto& right) {
                return left.nodeStats.nodeid == right.nodeStats.nodeid;
            });
            if (duplicate == normalized->cend()) snapshot = std::move(normalized);
        }
    }
    // Unavailable/duplicate results still retire the request on the GUI thread.
    Q_EMIT snapshotReady(generation, snapshot);
}

PeerTableModel::PeerTableModel(interfaces::Node& node, QThread* worker_thread, QObject* parent)
    : PeerTableModel([&node]() -> PeerStatsSnapshot {
        interfaces::Node::NodesStats stats;
        if (!node.getNodesStats(stats)) return {};
        auto peers = std::make_shared<QList<CNodeCombinedStats>>();
        peers->reserve(stats.size());
        for (auto& row : stats) {
            peers->append({std::move(std::get<0>(row)), std::move(std::get<2>(row)), std::get<1>(row)});
        }
        return peers;
    }, worker_thread, parent)
{
}

PeerTableModel::PeerTableModel(PeerSnapshotCollector collector, QThread* worker_thread, QObject* parent)
    : QAbstractTableModel(parent), m_worker(new PeerTableWorker(std::move(collector), m_active_generation))
{
    qRegisterMetaType<PeerStatsSnapshot>();
    m_worker->moveToThread(worker_thread);
    connect(worker_thread, &QThread::finished, m_worker.data(), &QObject::deleteLater);
    connect(m_worker.data(), &PeerTableWorker::snapshotReady, this, &PeerTableModel::snapshotReady, Qt::QueuedConnection);
    timer = new QTimer(this);
    connect(timer, &QTimer::timeout, this, &PeerTableModel::refresh);
    timer->setInterval(MODEL_UPDATE_DELAY);
    // No hidden constructor-time network lock or snapshot.
}

PeerTableModel::~PeerTableModel()
{
    beginShutdown();
}

void PeerTableModel::startAutoRefresh()
{
    if (m_stopping || m_active) return;
    m_active = true;
    ++m_generation;
    m_active_generation->store(m_generation, std::memory_order_release);
    timer->start();
    refresh();
}

void PeerTableModel::stopAutoRefresh()
{
    timer->stop();
    if (m_active) ++m_generation;
    m_active = false;
    m_active_generation->store(0, std::memory_order_release);
    m_refresh_pending = false;
}

void PeerTableModel::beginShutdown()
{
    m_stopping = true;
    stopAutoRefresh();
}

int PeerTableModel::rowCount(const QModelIndex& parent) const
{
    if (parent.isValid()) {
        return 0;
    }
    return m_peers_data.size();
}

int PeerTableModel::columnCount(const QModelIndex& parent) const
{
    if (parent.isValid()) {
        return 0;
    }
    return columns.length();
}

QVariant PeerTableModel::data(const QModelIndex& index, int role) const
{
    if (!index.isValid() || index.model() != this || index.row() < 0 ||
        index.row() >= m_peers_data.size() || index.column() < 0 || index.column() >= columns.size()) return {};

    // QModelIndex storage must not depend on QList addresses across snapshots.
    auto* rec = const_cast<CNodeCombinedStats*>(&m_peers_data.at(index.row()));

    const auto column = static_cast<ColumnIndex>(index.column());
    if (role == Qt::DisplayRole) {
        switch (column) {
        case NetNodeId:
            return (qint64)rec->nodeStats.nodeid;
        case Age:
            return GUIUtil::FormatPeerAge(rec->nodeStats.m_connected);
        case Address:
            return QString::fromStdString(rec->nodeStats.m_addr_name);
        case Direction:
            return QString(rec->nodeStats.fInbound ?
                               //: An Inbound Connection from a Peer.
                               tr("Inbound") :
                               //: An Outbound Connection to a Peer.
                               tr("Outbound"));
        case ConnectionType:
            return GUIUtil::ConnectionTypeToQString(rec->nodeStats.m_conn_type, /*prepend_direction=*/false);
        case Network:
            return GUIUtil::NetworkToQString(rec->nodeStats.m_network);
        case Ping:
            return GUIUtil::formatPingTime(rec->nodeStats.m_min_ping_time);
        case Sent:
            return GUIUtil::formatBytes(rec->nodeStats.nSendBytes);
        case Received:
            return GUIUtil::formatBytes(rec->nodeStats.nRecvBytes);
        case Subversion:
            return QString::fromStdString(rec->nodeStats.cleanSubVer);
        } // no default case, so the compiler can warn about missing cases
        assert(false);
    } else if (role == Qt::TextAlignmentRole) {
        switch (column) {
        case NetNodeId:
        case Age:
            return QVariant(Qt::AlignRight | Qt::AlignVCenter);
        case Address:
            return {};
        case Direction:
        case ConnectionType:
        case Network:
            return QVariant(Qt::AlignCenter);
        case Ping:
        case Sent:
        case Received:
            return QVariant(Qt::AlignRight | Qt::AlignVCenter);
        case Subversion:
            return {};
        } // no default case, so the compiler can warn about missing cases
        assert(false);
    } else if (role == StatsRole) {
        return QVariant::fromValue(rec);
    }

    return QVariant();
}

QVariant PeerTableModel::headerData(int section, Qt::Orientation orientation, int role) const
{
    if(orientation == Qt::Horizontal)
    {
        if(role == Qt::DisplayRole && section >= 0 && section < columns.size())
        {
            return columns[section];
        }
    }
    return QVariant();
}

Qt::ItemFlags PeerTableModel::flags(const QModelIndex &index) const
{
    if (!index.isValid() || index.model() != this || index.row() < 0 || index.row() >= rowCount() ||
        index.column() < 0 || index.column() >= columnCount()) return Qt::NoItemFlags;

    Qt::ItemFlags retval = Qt::ItemIsSelectable | Qt::ItemIsEnabled;
    return retval;
}

QModelIndex PeerTableModel::index(int row, int column, const QModelIndex& parent) const
{
    if (parent.isValid()) return {};

    if (0 <= row && row < rowCount() && 0 <= column && column < columnCount()) {
        return createIndex(row, column);
    }

    return QModelIndex();
}

void PeerTableModel::refresh()
{
    Q_ASSERT(QThread::currentThread() == thread());
    if (!m_active || m_stopping || !m_worker) return;
    if (m_in_flight) {
        m_refresh_pending = true;
        return;
    }
    m_in_flight = true;
    m_refresh_pending = false;
    PeerTableWorker* worker = m_worker.data();
    const quint64 generation = m_generation;
    const bool queued = QMetaObject::invokeMethod(worker, [worker, generation] { worker->collect(generation); }, Qt::QueuedConnection);
    Q_ASSERT(queued);
    if (!queued) m_in_flight = false;
}

void PeerTableModel::snapshotReady(quint64 generation, PeerStatsSnapshot snapshot)
{
    Q_ASSERT(QThread::currentThread() == thread());
    m_in_flight = false;
    if (m_stopping) return;
    if (m_active && generation == m_generation) {
        QPointer<PeerTableModel> alive{this};
        if (snapshot) publishSnapshot(*snapshot);
        if (!alive) return;
        Q_EMIT refreshCompleted(bool(snapshot));
        if (!alive) return;
    }
    // One coalesced follow-up, including a show after an older hidden request.
    if (m_active && m_refresh_pending) refresh();
}

void PeerTableModel::publishSnapshot(const QList<CNodeCombinedStats>& peers)
{
    // The worker normalizes NodeId order and rejects duplicates. Keep this
    // defensive boundary before changing persistent selection identity.
    for (int i = 1; i < peers.size(); ++i) {
        if (peers.at(i - 1).nodeStats.nodeid >= peers.at(i).nodeStats.nodeid) return;
    }
    int row{0}, next{0};
    while (row < m_peers_data.size() || next < peers.size()) {
        if (next == peers.size() || (row < m_peers_data.size() &&
            m_peers_data.at(row).nodeStats.nodeid < peers.at(next).nodeStats.nodeid)) {
            beginRemoveRows({}, row, row);
            m_peers_data.removeAt(row);
            endRemoveRows();
        } else if (row == m_peers_data.size() ||
                   peers.at(next).nodeStats.nodeid < m_peers_data.at(row).nodeStats.nodeid) {
            beginInsertRows({}, row, row);
            m_peers_data.insert(row, peers.at(next));
            endInsertRows();
            ++row;
            ++next;
        } else {
            m_peers_data[row] = peers.at(next);
            ++row;
            ++next;
        }
    }
    if (!m_peers_data.isEmpty()) Q_EMIT dataChanged(index(0, 0), index(rowCount() - 1, columnCount() - 1));
}
