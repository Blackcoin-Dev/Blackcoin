// Copyright (c) 2011-2022 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/clientmodel.h>

#include <qt/bantablemodel.h>
#include <qt/guiconstants.h>
#include <qt/guiutil.h>
#include <qt/peertablemodel.h>
#include <qt/peertablesortproxy.h>

#include <clientversion.h>
#include <common/args.h>
#include <common/system.h>
#include <interfaces/handler.h>
#include <interfaces/node.h>
#include <net.h>
#include <netbase.h>
#include <util/threadnames.h>
#include <util/time.h>
#include <validation.h>

#include <stdint.h>
#include <cmath>
#include <limits>

#include <QDebug>
#include <QMetaObject>
#include <QThread>
#include <QTimer>

static SteadyClock::time_point g_last_header_tip_update_notification{};
static SteadyClock::time_point g_last_block_tip_update_notification{};

ClientModel::ClientModel(interfaces::Node& node, OptionsModel *_optionsModel, QObject *parent) :
    QObject(parent),
    m_node(node),
    optionsModel(_optionsModel),
    m_thread(new QThread(this))
{
    cachedBestHeaderHeight = -1;
    cachedBestHeaderTime = -1;

    peerTableModel = new PeerTableModel(m_node, m_thread, this);
    m_peer_table_sort_proxy = new PeerTableSortProxy(this);
    m_peer_table_sort_proxy->setSourceModel(peerTableModel);

    banTableModel = new BanTableModel(m_node, this);

    QTimer* timer = new QTimer;
    timer->setInterval(MODEL_UPDATE_DELAY);
    connect(timer, &QTimer::timeout, [this] {
        if (m_stopping.load(std::memory_order_acquire)) return;
        sampleConnectionCounts();
        // no locking required at this point
        // the following calls will acquire the required lock
        Q_EMIT mempoolSizeChanged(m_node.getMempoolSize(), m_node.getMempoolDynamicUsage());
        Q_EMIT bytesChanged(m_node.getTotalBytesRecv(), m_node.getTotalBytesSent());
        if (m_kernel_sample_requested.exchange(false, std::memory_order_acq_rel)) {
            const uint64_t generation = WITH_LOCK(m_cached_tip_mutex, return m_header_generation);
            uint256 header_hash, current_header;
            double estimate{0};
            const bool complete = m_node.tryGetPoSKernelPS(header_hash, estimate, current_header);
            LOCK(m_cached_tip_mutex);
            // Header notifications carry no hash. A notification during this
            // query invalidates it, including same-height reorgs. Never hold
            // the cache mutex across the Node call's cs_main try-lock.
            if (generation == m_header_generation) {
                m_verified_header_hash = current_header;
                if (complete) {
                    m_kernel_sample_hash = header_hash;
                    m_kernel_sample = std::isfinite(estimate) && estimate > 0 ? std::optional<double>{estimate} : std::nullopt;
                }
            } else {
                m_verified_header_hash.SetNull();
            }
        }
    });
    connect(m_thread, &QThread::finished, timer, &QObject::deleteLater);
    connect(m_thread, &QThread::started, [timer] { timer->start(); });
    // move timer to thread so that polling doesn't disturb main event loop
    timer->moveToThread(m_thread);
    // Subscribe before starting the initial asynchronous connection sample.
    subscribeToCoreSignals();
    m_thread->start();
    QTimer::singleShot(0, timer, []() {
        util::ThreadRename("qt-clientmodl");
    });
}

std::optional<double> ClientModel::cachedPoSKernelPS()
{
    m_kernel_sample_requested.store(true, std::memory_order_release);
    LOCK(m_cached_tip_mutex);
    if (m_verified_header_hash.IsNull() || m_verified_header_hash != m_kernel_sample_hash) return std::nullopt;
    return m_kernel_sample;
}

void ClientModel::beginShutdown()
{
    m_stopping.store(true, std::memory_order_release);
    peerTableModel->beginShutdown();
    m_thread->quit();
}

bool ClientModel::shutdownReady()
{
    return m_thread->wait(0);
}

ClientModel::~ClientModel()
{
    beginShutdown();
    unsubscribeFromCoreSignals();
    m_thread->wait();
}

ClientModel::ConnectionCounts ClientModel::getConnectionCounts() const
{
    LOCK(m_connection_cache_mutex);
    return m_connection_counts;
}

int ClientModel::getNumConnections(unsigned int flags) const
{
    const auto counts = getConnectionCounts();
    if (flags == CONNECTIONS_IN) return counts.inbound;
    if (flags == CONNECTIONS_OUT) return counts.outbound;
    if (flags == CONNECTIONS_ALL) return counts.total;
    return 0;
}

void ClientModel::sampleConnectionCounts()
{
    Q_ASSERT(QThread::currentThread() == m_thread);
    const uint64_t generation = WITH_LOCK(m_connection_cache_mutex, return m_connection_generation);
    // The old API has separate count reads. A bounded observation rejects
    // detected churn; it is not an atomic peer-topology snapshot. Never hold
    // the cache mutex across Core networking locks, and never spin on churn.
    const auto before = m_node.getNodeCount(ConnectionDirection::Both);
    const auto inbound = m_node.getNodeCount(ConnectionDirection::In);
    const auto outbound = m_node.getNodeCount(ConnectionDirection::Out);
    const auto after = m_node.getNodeCount(ConnectionDirection::Both);
    publishConnectionCounts(generation, before, inbound, outbound, after);
}

void ClientModel::publishConnectionCounts(uint64_t generation, size_t before, size_t inbound, size_t outbound, size_t after)
{
    const auto maximum = size_t{std::numeric_limits<int>::max()};
    const bool coherent = before == after && after <= maximum &&
        inbound <= after && outbound <= after && inbound + outbound == after;
    const ConnectionCounts sampled{after <= maximum ? int(after) : -1,
        coherent ? int(inbound) : -1, coherent ? int(outbound) : -1};
    bool changed{false};
    {
        LOCK(m_connection_cache_mutex);
        if (m_stopping.load(std::memory_order_acquire) || generation != m_connection_generation) return;
        changed = sampled.total != m_connection_counts.total || sampled.inbound != m_connection_counts.inbound || sampled.outbound != m_connection_counts.outbound;
        m_connection_counts = sampled;
    }
    if (changed) Q_EMIT numConnectionsChanged(sampled.total);
}

int ClientModel::getHeaderTipHeight() const
{
    if (cachedBestHeaderHeight == -1) {
        // make sure we initially populate the cache via a cs_main lock
        // otherwise we need to wait for a tip update
        int height;
        int64_t blockTime;
        if (m_node.getHeaderTip(height, blockTime)) {
            cachedBestHeaderHeight = height;
            cachedBestHeaderTime = blockTime;
        }
    }
    return cachedBestHeaderHeight;
}

int64_t ClientModel::getHeaderTipTime() const
{
    if (cachedBestHeaderTime == -1) {
        int height;
        int64_t blockTime;
        if (m_node.getHeaderTip(height, blockTime)) {
            cachedBestHeaderHeight = height;
            cachedBestHeaderTime = blockTime;
        }
    }
    return cachedBestHeaderTime;
}

int ClientModel::getNumBlocks() const
{
    if (m_cached_num_blocks == -1) {
        m_cached_num_blocks = m_node.getNumBlocks();
    }
    return m_cached_num_blocks;
}

uint256 ClientModel::getBestBlockHash()
{
    uint256 tip{WITH_LOCK(m_cached_tip_mutex, return m_cached_tip_blocks)};

    if (!tip.IsNull()) {
        return tip;
    }

    // Lock order must be: first `cs_main`, then `m_cached_tip_mutex`.
    // The following will lock `cs_main` (and release it), so we must not
    // own `m_cached_tip_mutex` here.
    tip = m_node.getBestBlockHash();

    LOCK(m_cached_tip_mutex);
    // We checked that `m_cached_tip_blocks` is not null above, but then we
    // released the mutex `m_cached_tip_mutex`, so it could have changed in the
    // meantime. Thus, check again.
    if (m_cached_tip_blocks.IsNull()) {
        m_cached_tip_blocks = tip;
    }
    return m_cached_tip_blocks;
}

BlockSource ClientModel::getBlockSource() const
{
    if (m_node.isLoadingBlocks()) return BlockSource::DISK;
    const int connections = getNumConnections();
    if (connections < 0) return BlockSource::UNKNOWN;
    return connections > 0 ? BlockSource::NETWORK : BlockSource::NONE;
}

QString ClientModel::getStatusBarWarnings() const
{
    return QString::fromStdString(m_node.getWarnings().translated);
}

OptionsModel *ClientModel::getOptionsModel()
{
    return optionsModel;
}

PeerTableModel *ClientModel::getPeerTableModel()
{
    return peerTableModel;
}

PeerTableSortProxy* ClientModel::peerTableSortProxy()
{
    return m_peer_table_sort_proxy;
}

BanTableModel *ClientModel::getBanTableModel()
{
    return banTableModel;
}

QString ClientModel::formatFullVersion() const
{
    return QString::fromStdString(FormatFullVersion());
}

QString ClientModel::formatSubVersion() const
{
    return QString::fromStdString(strSubVersion);
}

bool ClientModel::isReleaseVersion() const
{
    return CLIENT_VERSION_IS_RELEASE;
}

QString ClientModel::formatClientStartupTime() const
{
    return QDateTime::fromSecsSinceEpoch(GetStartupTime()).toString();
}

QString ClientModel::dataDir() const
{
    return GUIUtil::PathToQString(gArgs.GetDataDirNet());
}

QString ClientModel::blocksDir() const
{
    return GUIUtil::PathToQString(gArgs.GetBlocksDirPath());
}

void ClientModel::TipChanged(SynchronizationState sync_state, interfaces::BlockTip tip, double verification_progress, SyncType synctype)
{
    if (synctype == SyncType::HEADER_SYNC) {
        // cache best headers time and height to reduce future cs_main locks
        cachedBestHeaderHeight = tip.block_height;
        cachedBestHeaderTime = tip.block_time;
        WITH_LOCK(m_cached_tip_mutex, ++m_header_generation; m_verified_header_hash.SetNull(););
    } else if (synctype == SyncType::BLOCK_SYNC) {
        m_cached_num_blocks = tip.block_height;
        WITH_LOCK(m_cached_tip_mutex, m_cached_tip_blocks = tip.block_hash;);
    }

    // Throttle GUI notifications about (a) blocks during initial sync, and (b) both blocks and headers during reindex.
    const bool throttle = (sync_state != SynchronizationState::POST_INIT && synctype == SyncType::BLOCK_SYNC) || sync_state == SynchronizationState::INIT_REINDEX;
    const auto now{throttle ? SteadyClock::now() : SteadyClock::time_point{}};
    auto& nLastUpdateNotification = synctype != SyncType::BLOCK_SYNC ? g_last_header_tip_update_notification : g_last_block_tip_update_notification;
    if (throttle && now < nLastUpdateNotification + MODEL_UPDATE_DELAY) {
        return;
    }

    Q_EMIT numBlocksChanged(tip.block_height, QDateTime::fromSecsSinceEpoch(tip.block_time), verification_progress, synctype, sync_state);
    nLastUpdateNotification = now;
}

void ClientModel::subscribeToCoreSignals()
{
    m_handler_show_progress = m_node.handleShowProgress(
        [this](const std::string& title, int progress, [[maybe_unused]] bool resume_possible) {
            Q_EMIT showProgress(QString::fromStdString(title), progress);
        });
    m_handler_notify_num_connections_changed = m_node.handleNotifyNumConnectionsChanged(
        [this](int new_num_connections) {
            {
                LOCK(m_connection_cache_mutex);
                if (m_stopping.load(std::memory_order_acquire)) return;
                ++m_connection_generation;
                m_connection_counts = {new_num_connections, -1, -1};
            }
            Q_EMIT numConnectionsChanged(new_num_connections);
        });
    m_handler_notify_network_active_changed = m_node.handleNotifyNetworkActiveChanged(
        [this](bool network_active) {
            Q_EMIT networkActiveChanged(network_active);
        });
    m_handler_notify_alert_changed = m_node.handleNotifyAlertChanged(
        [this]() {
            qDebug() << "ClientModel: NotifyAlertChanged";
            Q_EMIT alertsChanged(getStatusBarWarnings());
        });
    m_handler_banned_list_changed = m_node.handleBannedListChanged(
        [this]() {
            qDebug() << "ClienModel: Requesting update for peer banlist";
            QMetaObject::invokeMethod(banTableModel, [this] { banTableModel->refresh(); });
        });
    m_handler_notify_block_tip = m_node.handleNotifyBlockTip(
        [this](SynchronizationState sync_state, interfaces::BlockTip tip, double verification_progress) {
            TipChanged(sync_state, tip, verification_progress, SyncType::BLOCK_SYNC);
        });
    m_handler_notify_header_tip = m_node.handleNotifyHeaderTip(
        [this](SynchronizationState sync_state, interfaces::BlockTip tip, bool presync) {
            TipChanged(sync_state, tip, /*verification_progress=*/0.0, presync ? SyncType::HEADER_PRESYNC : SyncType::HEADER_SYNC);
        });
}

void ClientModel::unsubscribeFromCoreSignals()
{
    m_handler_show_progress->disconnect();
    m_handler_notify_num_connections_changed->disconnect();
    m_handler_notify_network_active_changed->disconnect();
    m_handler_notify_alert_changed->disconnect();
    m_handler_banned_list_changed->disconnect();
    m_handler_notify_block_tip->disconnect();
    m_handler_notify_header_tip->disconnect();
}

bool ClientModel::getProxyInfo(std::string& ip_port) const
{
    Proxy ipv4, ipv6;
    if (m_node.getProxy((Network) 1, ipv4) && m_node.getProxy((Network) 2, ipv6)) {
      ip_port = ipv4.proxy.ToStringAddrPort();
      return true;
    }
    return false;
}
