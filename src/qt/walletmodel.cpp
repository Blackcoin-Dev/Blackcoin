// Copyright (c) 2011-2022 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#if defined(HAVE_CONFIG_H)
#include <config/bitcoin-config.h>
#endif

#include <qt/walletmodel.h>

#include <qt/addresstablemodel.h>
#include <qt/clientmodel.h>
#include <qt/guiconstants.h>
#include <qt/guiutil.h>
#include <qt/optionsmodel.h>
#include <qt/paymentserver.h>
#include <qt/recentrequeststablemodel.h>
#include <qt/sendcoinsdialog.h>
#include <qt/transactionrecord.h>
#include <qt/transactiontablemodel.h>

#include <common/args.h> // for GetBoolArg
#include <common/settings.h>
#include <interfaces/handler.h>
#include <interfaces/node.h>
#include <key_io.h>
#include <node/interface_ui.h>
#include <psbt.h>
#include <util/translation.h>
#include <univalue.h>
#include <wallet/coincontrol.h>
#include <wallet/wallet.h> // for CRecipient

#include <algorithm>
#include <exception>
#include <functional>
#include <stdint.h>
#include <utility>

#include <QDebug>
#include <QMessageBox>
#include <QPointer>
#include <QSet>
#include <QTimer>
#include <QFile>

using wallet::CCoinControl;
using wallet::CRecipient;
using wallet::DEFAULT_DISABLE_WALLET;

static constexpr int POLL_SYNC_SKIP{30};
//! Refresh interval for a wallet model that is not the one shown (L15).
static constexpr std::chrono::seconds BACKGROUND_POLL_INTERVAL{60};

class WalletWorker : public QObject
{
    Q_OBJECT
};

#include <qt/walletmodel.moc>

WalletModel::WalletModel(std::unique_ptr<interfaces::Wallet> wallet, ClientModel& client_model, const PlatformStyle* platformStyle, QObject* parent, bool defer_history) :
    QObject(parent),
    m_wallet(std::move(wallet)),
    m_client_model(nullptr),
    m_node(client_model.node()),
    optionsModel(client_model.getOptionsModel()),
    timer(new QTimer(this)),
    nWeight(0),
    updateStakeWeight(true),
    m_deferred_history(defer_history),
    worker(nullptr),
    m_address_capability_retry(new QTimer(this))
{
    // Establish the GUI-thread cache before any view is attached. Later
    // keystore notifications update it in updateStatus(). Timer-driven views
    // read this cache instead of entering cs_wallet themselves.
    cachedEncryptionStatus.store(getEncryptionStatus(), std::memory_order_release);
    fHaveWatchOnly = m_wallet->haveWatchOnly();
    addressTableModel = new AddressTableModel(this);
    transactionTableModel = new TransactionTableModel(platformStyle, this, defer_history);
    recentRequestsTableModel = new RecentRequestsTableModel(this);

    // Start thread
    worker = new WalletWorker;
    worker->moveToThread(&(t));
    // WalletWorker has thread affinity and deliberately has no QObject parent.
    // join() deletes it after the worker thread has fully exited. It must not
    // be retired through QThread::finished: that destroys the worker on the
    // exiting thread while QThread::isRunning() can still be true, so join()
    // could dereference a freed worker.
    t.start();

    m_address_capability_retry->setSingleShot(true);
    connect(m_address_capability_retry, &QTimer::timeout, this, &WalletModel::requestAddressCapability);

    setClientModel(&client_model);
    subscribeToCoreSignals();
}

WalletModel::~WalletModel()
{
    unsubscribeFromCoreSignals();

    join();
}

void WalletModel::startPollBalance()
{
    if (m_joined || timer->isActive()) return;
    m_balance_poll_started = true;
    connect(timer, &QTimer::timeout, this, &WalletModel::pollBalanceChanged, Qt::UniqueConnection);
    timer->start(MODEL_UPDATE_DELAY);
    pollBalanceChanged();
    requestInitialHistory();
}

void WalletModel::setBalancePollForeground(bool foreground)
{
    if (m_poll_foreground == foreground) return;
    m_poll_foreground = foreground;
    // Showing a wallet refreshes it now instead of waiting for the next tick.
    if (foreground && m_balance_poll_started) pollBalanceChanged();
}

void WalletModel::requestInitialHistory()
{
    if (!m_deferred_history || m_history_request_pending || m_joined) return;
    m_history_request_pending = true;
    m_history_yield.store(false, std::memory_order_release);
    const bool invoked = QMetaObject::invokeMethod(worker, [this] {
        std::vector<interfaces::WalletTx> transactions;
        std::deque<TransactionRecord> history;
        bool ready{false};
        bool failed{false};
        struct YieldHistory {};
        const auto interrupted = [this] {
            return m_history_cancel.load(std::memory_order_acquire) ||
                   m_history_yield.load(std::memory_order_acquire);
        };
        try {
            ready = !interrupted() && m_wallet->tryGetWalletTxs(transactions, interrupted);
            if (ready) {
                size_t comparisons{0};
                std::sort(transactions.begin(), transactions.end(), [&](const auto& a, const auto& b) {
                    if (comparisons++ % 1024 == 0 && interrupted()) throw YieldHistory{};
                    return a < b;
                });
                for (const auto& tx : transactions) {
                    if (interrupted()) throw YieldHistory{};
                    if (!TransactionRecord::showTransaction(tx)) continue;
                    for (auto& row : TransactionRecord::decomposeTransaction(tx)) {
                        history.push_back(std::move(row));
                    }
                }
            }
        } catch (const YieldHistory&) {
            ready = false;
            history.clear();
        } catch (const std::exception& error) {
            qWarning() << "Initial wallet history snapshot failed:" << error.what();
            failed = true;
        }
        QMetaObject::invokeMethod(this, [this, history = std::move(history), ready, failed]() mutable {
            m_history_request_pending = false;
            if (m_joined) return;
            if (failed) {
                m_deferred_history = false;
                transactionTableModel->reportHistoryLoadFailure();
            } else if (ready) {
                m_deferred_history = false;
                transactionTableModel->setInitialHistory(std::move(history));
            } else {
                QTimer::singleShot(25, this, &WalletModel::requestInitialHistory);
            }
        }, Qt::QueuedConnection);
    }, Qt::QueuedConnection);
    assert(invoked);
}

void WalletModel::setClientModel(ClientModel* client_model)
{
    if (m_client_model == client_model) return;
    disconnect(m_balance_tip_connection);
    m_client_model = client_model;
    ++m_balance_context_generation;
    invalidateBalanceSnapshot();
    if (!m_client_model) {
        timer->stop();
        return;
    }
    m_balance_tip_connection = connect(m_client_model, &ClientModel::numBlocksChanged, this,
        [this](int, const QDateTime&, double, SyncType type, SynchronizationState) {
            if (type == SyncType::BLOCK_SYNC) invalidateBalanceSnapshot();
        });
    if (m_balance_poll_started) startPollBalance();
}

void WalletModel::updateStatus()
{
    if (m_joined) return;
    interfaces::WalletEncryptionStatus status;
    if (!m_wallet->tryGetEncryptionStatus(status)) {
        // Keystore notifications can race with QQSIGNAL signing. Never wait
        // for cs_wallet on the Qt thread; coalesce retries until the signer
        // releases it instead.
        if (!m_status_update_retry_scheduled) {
            m_status_update_retry_scheduled = true;
            QTimer::singleShot(50, this, [this] {
                m_status_update_retry_scheduled = false;
                updateStatus();
            });
        }
        return;
    }

    const EncryptionStatus newEncryptionStatus = !status.encrypted
        ? (status.private_keys_disabled ? NoKeys : Unencrypted)
        : (status.locked ? Locked : Unlocked);

    if (cachedEncryptionStatus.load(std::memory_order_acquire) != newEncryptionStatus) {
        cachedEncryptionStatus.store(newEncryptionStatus, std::memory_order_release);
        Q_EMIT encryptionStatusChanged();
    }
}

void WalletModel::pollBalanceChanged()
{
    if (m_joined || !worker || !m_client_model) return;
    if (m_balance_poll_ticks < POLL_SYNC_SKIP) ++m_balance_poll_ticks;
    if (m_balance_poll_in_flight) {
        m_balance_poll_pending = true;
        return;
    }
    // A model that is not shown keeps its last snapshot and refreshes slowly.
    // The first snapshot and an active send-balance request are never gated.
    if (!m_poll_foreground && m_applied_balance_generation != 0 && !m_requested_send_family &&
        std::chrono::steady_clock::now() - m_last_balance_result < BACKGROUND_POLL_INTERVAL) {
        return;
    }

    m_balance_poll_in_flight = true;
    const uint64_t generation = m_balance_generation;
    const uint64_t context_generation = m_balance_context_generation;
    const auto family = m_requested_send_family;
    const uint64_t send_generation = m_send_request_generation;
    const bool send_current = !family || (m_cached_send_family == family &&
        m_cached_send_tip == m_cached_last_update_tip && m_cached_send_generation == generation);
    const std::optional<uint256> unchanged_tip = generation == m_applied_balance_generation && send_current
        ? std::optional<uint256>{m_cached_last_update_tip} : std::nullopt;
    const bool sync_poll_due = m_applied_balance_generation == 0 || m_balance_poll_ticks >= POLL_SYNC_SKIP;
    const bool invoked = QMetaObject::invokeMethod(worker, [this, generation, context_generation, family, send_generation, unchanged_tip, sync_poll_due] {
        interfaces::WalletDisplayBalances snapshot;
        bool ready{false};
        bool syncing{false};
        int height{-1};
        bool failed{false};
        try {
            if (!m_node.shutdownRequested()) {
                if (m_node.tryGetSyncInfo(height, syncing) && (!syncing || sync_poll_due)) {
                    ready = m_wallet->tryGetDisplayBalances(snapshot, unchanged_tip, family);
                }
                checkStakeWeightChanged();
            }
        } catch (...) {
            ready = false;
            failed = true;
        }
        QMetaObject::invokeMethod(this, [this, generation, context_generation, family, send_generation, snapshot, ready, syncing, failed, unchanged_tip] {
            m_balance_poll_in_flight = false;
            const bool pending = std::exchange(m_balance_poll_pending, false);
            if (m_joined || !m_client_model) return;
            if (context_generation == m_balance_context_generation) {
                if (failed && !m_balance_failure_reported) {
                    qWarning("Wallet display snapshot failed");
                    m_balance_failure_reported = true;
                } else if (ready) {
                    m_balance_failure_reported = false;
                }
            }
            // Accept the last coherent display even if a newer dirty event
            // arrived while it was collected. Keep that newer generation
            // pending. A different client attachment cannot publish here.
            if (ready && context_generation == m_balance_context_generation) {
                m_balance_poll_ticks = 0;
                const bool tip_changed = snapshot.block_hash != m_cached_last_update_tip;
                const bool wallet_changed = generation != m_applied_balance_generation;
                m_applied_balance_generation = generation;
                m_last_balance_result = std::chrono::steady_clock::now();
                m_cached_last_update_tip = snapshot.block_hash;
                const bool send_current = family && family == m_requested_send_family && send_generation == m_send_request_generation;
                const bool send_changed = send_current &&
                    (m_cached_send_family != family || m_cached_send_balance != snapshot.send_family_balance);
                if (send_current) {
                    m_cached_send_family = family;
                    m_cached_send_balance = snapshot.send_family_balance;
                    m_cached_send_tip = snapshot.block_hash;
                    m_cached_send_generation = generation;
                }
                const QPointer<WalletModel> model{this};
                const bool balance_changed = checkBalanceChanged(snapshot.balances);
                if (!model || m_joined || context_generation != m_balance_context_generation) return;
                if ((tip_changed || wallet_changed) && transactionTableModel) {
                    transactionTableModel->updateConfirmations();
                    if (!model || m_joined || context_generation != m_balance_context_generation) return;
                }
                if (!syncing && (tip_changed || balance_changed)) updateStakeWeight = true;
                if (send_changed) {
                    Q_EMIT sendBalanceChanged();
                    if (!model || m_joined || context_generation != m_balance_context_generation) return;
                }
            }
            if (pending) {
                pollBalanceChanged();
            } else if (!ready && !unchanged_tip && !timer->isActive() &&
                       !m_balance_retry_scheduled && !m_node.shutdownRequested()) {
                // Manual requests on a stopped timer still get a bounded,
                // context-owned retry when a snapshot could not be taken.
                m_balance_retry_scheduled = true;
                QTimer::singleShot(MODEL_UPDATE_DELAY, this, [this] {
                    m_balance_retry_scheduled = false;
                    pollBalanceChanged();
                });
            }
        }, Qt::QueuedConnection);
    }, Qt::QueuedConnection);
    if (!invoked) m_balance_poll_in_flight = false;
}

void WalletModel::invalidateBalanceSnapshot()
{
    ++m_balance_generation;
    if (m_balance_poll_in_flight) m_balance_poll_pending = true;
}

void WalletModel::setSendBalanceFamily(std::optional<interfaces::WalletDisplayCoinFamily> family)
{
    if (m_requested_send_family == family) return;
    m_requested_send_family = family;
    ++m_send_request_generation;
    if (family) {
        m_cached_send_generation = 0;
        pollBalanceChanged();
    }
}

std::optional<CAmount> WalletModel::getCachedSendBalance(interfaces::WalletDisplayCoinFamily family) const
{
    if (m_cached_send_family != family) return std::nullopt;
    return m_cached_send_balance;
}

void WalletModel::refreshSendBalance()
{
    if (!m_requested_send_family) return;
    ++m_send_request_generation;
    invalidateBalanceSnapshot();
    pollBalanceChanged();
}

bool WalletModel::checkBalanceChanged(const interfaces::WalletBalances& new_balances)
{
    if (new_balances.balanceChanged(m_cached_balances)) {
        m_cached_balances = new_balances;
        Q_EMIT balanceChanged(new_balances);
        return true;
    }
    return false;
}

interfaces::WalletBalances WalletModel::getCachedBalance() const
{
    return m_cached_balances;
}

std::shared_ptr<std::atomic<bool>> WalletModel::requestAccountSnapshot(
    std::function<void(std::shared_ptr<const AccountSnapshot>)> callback)
{
    if (m_joined || !worker) return {};
    if (m_account_snapshot_cancel) m_account_snapshot_cancel->store(true, std::memory_order_release);
    auto cancel = std::make_shared<std::atomic<bool>>(false);
    m_account_snapshot_cancel = cancel;
    const auto generation = m_balance_generation;

    const bool invoked = QMetaObject::invokeMethod(worker, [this, cancel, generation, callback = std::move(callback)] {
        auto snapshot = std::make_shared<AccountSnapshot>();
        const auto checkpoint = [&] {
            snapshot->cancelled = cancel->load(std::memory_order_acquire) || m_node.shutdownRequested();
            return snapshot->cancelled;
        };
        const auto unavailable = [&](bool available) {
            if (!available) snapshot->stale = true;
            return !available;
        };
        const auto collect = [&] {
            if (checkpoint()) return;
            uint256 tip;
            if (!m_wallet->tryGetBalances(snapshot->balances, tip)) {
                snapshot->stale = true;
                return;
            }
            if (checkpoint()) return;
            snapshot->migration = m_wallet->getMigrationStatus();
            if (unavailable(snapshot->migration.available) || checkpoint()) return;
            snapshot->demurrage = m_wallet->getDemurrageInfo();
            if (unavailable(snapshot->demurrage.available) || checkpoint()) return;
            bool available{false};
            snapshot->rgb_assets = m_wallet->listRGBAssets(/*include_spent=*/false, &available).size();
            if (unavailable(available) || checkpoint()) return;
            snapshot->eutxo_states = m_wallet->listEUTXOStates(/*include_spent=*/true, &available).size();
            if (unavailable(available) || checkpoint()) return;
            // Poll cancellation inside the coin walk so wallet switches and
            // shutdown do not wait for a full listing of a large wallet.
            auto coins = m_wallet->tryListCoins(checkpoint);
            if (checkpoint()) return;
            if (!coins) { snapshot->stale = true; return; }
            snapshot->coins = std::move(*coins);
            std::vector<interfaces::WalletAddress> addresses;
            const bool addresses_available = m_wallet->tryGetAddresses(addresses, checkpoint);
            if (checkpoint() || unavailable(addresses_available)) return;
            for (const auto& address : addresses) {
                if (checkpoint()) return;
                snapshot->labels.emplace(address.dest, address.name);
            }
            if (checkpoint()) return;
            snapshot->quantum_addresses = m_wallet->listQuantumAddresses(&available);
            if (unavailable(available) || checkpoint()) return;
            for (const auto& info : snapshot->quantum_addresses) {
                if (!info.tiered) continue;
                snapshot->stake_outputs.emplace(info.address, m_wallet->listQuantumStakeOutputs(info.address, &available));
                if (unavailable(available) || checkpoint()) return;
            }
            snapshot->coldstake_delegations = m_wallet->listQuantumColdStakeDelegations(&available);
            if (unavailable(available) || checkpoint()) return;
            std::vector<std::string> coldstake_addresses;
            coldstake_addresses.reserve(snapshot->coldstake_delegations.size());
            for (const auto& info : snapshot->coldstake_delegations) coldstake_addresses.push_back(info.address);
            snapshot->coldstake_balances = m_wallet->getQuantumColdStakeBalances(coldstake_addresses);
            const bool coldstake_available = std::all_of(snapshot->coldstake_balances.begin(), snapshot->coldstake_balances.end(),
                [](const auto& entry) { return entry.second.available; });
            if (unavailable(coldstake_available) || checkpoint()) return;
            uint256 end_tip;
            snapshot->stale = !m_node.tryGetBestBlockHash(end_tip) || end_tip != tip;
        };
        try {
            collect();
        } catch (const std::exception& e) {
            snapshot->error = e.what();
        } catch (...) {
            snapshot->error = "Unknown wallet read error";
        }

        QMetaObject::invokeMethod(this, [this, cancel, generation, snapshot, callback] {
            if (m_joined || m_account_snapshot_cancel != cancel) return;
            m_account_snapshot_cancel.reset();
            snapshot->cancelled |= cancel->load(std::memory_order_acquire);
            snapshot->stale |= generation != m_balance_generation;
            callback(snapshot);
        }, Qt::QueuedConnection);
    }, Qt::QueuedConnection);
    assert(invoked);
    return cancel;
}

void WalletModel::requestStakingMiningSnapshot(const StakingMiningSnapshotRequest& request)
{
    // Only the GUI thread owns request/coalescing state. The cancellation flag
    // is the sole object shared with WalletWorker and is checked between every
    // wallet walk so teardown and wallet switches never wait in the view.
    cancelStakingMiningSnapshot();
    if (m_joined || !worker) return;
    m_completed_staking_snapshot.reset();
    m_staking_snapshot_request_id = request.request_id;
    const auto cancel = std::make_shared<std::atomic<bool>>(false);
    m_staking_snapshot_cancel = cancel;

    const bool invoked = QMetaObject::invokeMethod(worker, [this, request, cancel] {
        assert(QThread::currentThread() == worker->thread());
        auto snapshot = std::make_shared<StakingMiningSnapshot>();
        snapshot->request = request;

        const auto publish = [this, snapshot] {
            QMetaObject::invokeMethod(this, [this, snapshot] {
                if (m_staking_snapshot_request_id == snapshot->request.request_id) {
                    m_completed_staking_snapshot = snapshot;
                    m_staking_snapshot_cancel.reset();
                }
                Q_EMIT stakingMiningSnapshotReady(snapshot->request.request_id, snapshot->request.generation);
            }, Qt::QueuedConnection);
        };
        const auto checkpoint = [this, cancel, snapshot] {
            if (cancel->load(std::memory_order_acquire) || m_node.shutdownRequested()) {
                snapshot->cancelled = true;
                return true;
            }
            return false;
        };

        if (checkpoint()) {
            publish();
            return;
        }

        try {
            uint256 start_tip;
            if (!m_node.tryGetBestBlockHash(start_tip)) {
                snapshot->stale_tip = true;
                publish();
                return;
            }
            snapshot->start_tip = start_tip.GetHex();
            if (!request.expected_tip.empty() && snapshot->start_tip != request.expected_tip) {
                snapshot->stale_tip = true;
                publish();
                return;
            }

            // These collections use try-locks. An unavailable read is not an
            // authoritative empty wallet. Probe before the blocking detail
            // calls so contention returns promptly to the page's bounded retry.
            bool available{false};
            const auto unavailable = [&](const char* stage) {
                if (available) return false;
                snapshot->transient_unavailable = true;
                snapshot->unavailable_stage = stage;
                publish();
                return true;
            };
            snapshot->coldstake_delegations = m_wallet->listQuantumColdStakeDelegations(&available);
            if (unavailable("coldstake_delegations")) return;
            if (checkpoint()) { publish(); return; }
            snapshot->quantum_addresses = m_wallet->listQuantumAddresses(&available);
            if (unavailable("quantum_addresses")) return;
            if (checkpoint()) { publish(); return; }
            snapshot->rgb_assets = m_wallet->listRGBAssets(/*include_spent=*/false, &available);
            if (unavailable("rgb_assets")) return;
            if (checkpoint()) { publish(); return; }
            snapshot->eutxo_states = m_wallet->listEUTXOStates(/*include_spent=*/true, &available);
            if (unavailable("eutxo_states")) return;
            if (checkpoint()) { publish(); return; }

            snapshot->selfstake_query_address = request.selfstake_address;
            if (snapshot->selfstake_query_address.empty()) {
                const auto selfstake = std::find_if(snapshot->quantum_addresses.begin(), snapshot->quantum_addresses.end(), [](const interfaces::WalletQuantumAddressInfo& info) {
                    return info.tiered && info.label == "quantum-stake";
                });
                if (selfstake != snapshot->quantum_addresses.end()) snapshot->selfstake_query_address = selfstake->address;
            }
            if (!snapshot->selfstake_query_address.empty()) {
                snapshot->selfstake_queried = true;
                snapshot->selfstake_outputs = m_wallet->listQuantumStakeOutputs(snapshot->selfstake_query_address, &available);
                if (unavailable("selfstake_outputs")) return;
                if (checkpoint()) { publish(); return; }
            }

            m_wallet->refreshPowMiningStakeReserve();
            if (checkpoint()) { publish(); return; }
            snapshot->pow = m_wallet->getPowMiningInfo();
            if (checkpoint()) { publish(); return; }
            snapshot->migration = m_wallet->getMigrationStatus();
            if (checkpoint()) { publish(); return; }
            snapshot->demurrage = m_wallet->getDemurrageInfo();
            if (checkpoint()) { publish(); return; }
            if (snapshot->selfstake_queried) {
                snapshot->selfstake_bond = m_wallet->getQuantumStakeAddressBondInfo(snapshot->selfstake_query_address);
                if (checkpoint()) { publish(); return; }
            }
            snapshot->operator_query_address = request.operator_address;
            if (!snapshot->operator_query_address.empty()) {
                snapshot->operator_queried = true;
                snapshot->operator_bond = m_wallet->getQuantumOperatorBondInfo(snapshot->operator_query_address);
                if (checkpoint()) { publish(); return; }
            }

            std::vector<std::string> coldstake_addresses;
            coldstake_addresses.reserve(snapshot->coldstake_delegations.size() + 1);
            for (const auto& info : snapshot->coldstake_delegations) {
                coldstake_addresses.push_back(info.address);
            }
            snapshot->selected_coldstake_query_address = request.coldstake_address;
            if (!snapshot->selected_coldstake_query_address.empty()) {
                coldstake_addresses.push_back(snapshot->selected_coldstake_query_address);
            }
            const auto coldstake_balances = m_wallet->getQuantumColdStakeBalances(coldstake_addresses);
            if (checkpoint()) { publish(); return; }
            snapshot->coldstake_balances.reserve(snapshot->coldstake_delegations.size());
            for (const auto& info : snapshot->coldstake_delegations) {
                snapshot->coldstake_balances.push_back({info.address, coldstake_balances.at(info.address)});
            }
            if (!snapshot->selected_coldstake_query_address.empty()) {
                snapshot->selected_coldstake_queried = true;
                snapshot->selected_coldstake_balance = coldstake_balances.at(snapshot->selected_coldstake_query_address);
            }

            snapshot->pool = m_wallet->getQuantumPoolInfo();
            if (checkpoint()) { publish(); return; }
            // getPowMiningInfo() deliberately uses try-locks so callers never
            // stall a GUI thread. A transient miss is not an authoritative
            // empty payout or eligibility state. The intervening detail reads
            // have crossed the same wallet/chain locks, so resample once and
            // reject the whole snapshot if it is still incomplete.
            if (!snapshot->pow.payout_address_available ||
                !snapshot->pow.wallet_goldrush_status_available) {
                snapshot->pow = m_wallet->getPowMiningInfo();
                if (checkpoint()) { publish(); return; }
                if (!snapshot->pow.payout_address_available ||
                    !snapshot->pow.wallet_goldrush_status_available) {
                    snapshot->error =
                        "Wallet mining details are temporarily unavailable; retry the refresh";
                    publish();
                    return;
                }
            }
            uint256 end_tip;
            if (!m_node.tryGetBestBlockHash(end_tip)) {
                snapshot->stale_tip = true;
                publish();
                return;
            }
            snapshot->end_tip = end_tip.GetHex();
            snapshot->stale_tip = snapshot->start_tip != snapshot->end_tip ||
                (!request.expected_tip.empty() && snapshot->end_tip != request.expected_tip);
        } catch (const std::exception& e) {
            snapshot->error = e.what();
        } catch (...) {
            snapshot->error = "Unknown error while building staking and mining details";
        }

        publish();
    }, Qt::QueuedConnection);
    assert(invoked);
}

void WalletModel::cancelStakingMiningSnapshot(uint64_t request_id)
{
    if (m_staking_snapshot_cancel &&
        (request_id == 0 || request_id == m_staking_snapshot_request_id)) {
        m_staking_snapshot_cancel->store(true, std::memory_order_release);
    }
}

std::shared_ptr<const WalletModel::StakingMiningSnapshot> WalletModel::takeStakingMiningSnapshot(uint64_t request_id)
{
    if (!m_completed_staking_snapshot ||
        m_completed_staking_snapshot->request.request_id != request_id) {
        return {};
    }
    return std::exchange(m_completed_staking_snapshot, {});
}

uint64_t WalletModel::requestPowMiningControl(PowMiningControlRequest request)
{
    Q_ASSERT(QThread::currentThread() == thread());
    if (m_account_snapshot_cancel) m_account_snapshot_cancel->store(true, std::memory_order_release);
    m_history_yield.store(true, std::memory_order_release);
    cancelStakingMiningSnapshot();
    if (++m_pow_mining_control_sequence == 0) ++m_pow_mining_control_sequence;
    request.request_id = m_pow_mining_control_sequence;
    request.wallet_name = m_wallet->getWalletName();
    const auto cancel = std::make_shared<std::atomic<bool>>(false);
    m_pow_mining_control_cancels.emplace(request.request_id, cancel);
    if (m_joined || !worker || !t.isRunning()) {
        cancel->store(true, std::memory_order_release);
        auto result = std::make_shared<PowMiningControlResult>();
        result->request = request;
        result->cancelled = true;
        result->error = "Wallet worker is stopping; mining control was not started";
        QMetaObject::invokeMethod(this, [this, result] {
            m_pow_mining_control_cancels.erase(result->request.request_id);
            m_completed_pow_mining_controls.emplace(result->request.request_id, result);
            Q_EMIT powMiningControlReady(result->request.request_id, result->request.generation);
        }, Qt::QueuedConnection);
        return request.request_id;
    }
    const bool invoked = QMetaObject::invokeMethod(worker, [this, request, cancel] {
        auto result = std::make_shared<PowMiningControlResult>();
        result->request = request;
        const auto cancelled = [this, request, cancel] {
            return cancel->load(std::memory_order_acquire) ||
                (request.view_current && !request.view_current->load(std::memory_order_acquire)) ||
                m_node.shutdownRequested();
        };
        try {
            if (cancelled()) {
                result->cancelled = true;
            } else if (request.threads < 1 || request.threads > 256 ||
                       request.cpu_percent < 1 || request.cpu_percent > 100) {
                result->error = "Invalid miner resource preferences";
            } else {
                result->core_entered = true;
                result->success = m_wallet->setPowMining(
                    request.enabled, request.threads, request.cpu_percent,
                    result->error, request.allow_new_payout_key,
                    &result->created_payout_key, cancelled);
                // A completed mutation remains a completed mutation when its
                // originating view disappears. Cancellation never rolls back
                // a durable payout key or a committed worker replacement.
                result->cancelled = !result->success && cancelled();
                if (result->success && request.lock_wallet) {
                    result->success = m_wallet->lock();
                    if (!result->success) result->error = "Unable to lock the wallet after stopping mining";
                }
                if (result->success && !request.lock_wallet) {
                    const bool save_threads = !m_node.isSettingIgnored("powminingthreads");
                    const bool save_cpu = !m_node.isSettingIgnored("powminingcpu");
                    if (save_threads || save_cpu) {
                        // Write the pair together, independently of startup
                        // consent. Node's void update API cannot report disk
                        // failure, so use the checked settings writer here.
                        gArgs.LockSettings([&](common::Settings& settings) {
                            if (save_threads) settings.rw_settings["powminingthreads"] = request.threads;
                            if (save_cpu) settings.rw_settings["powminingcpu"] = request.cpu_percent;
                        });
                        result->preferences_saved = gArgs.WriteSettingsFile();
                        if (!result->preferences_saved) result->error = "Mining control succeeded, but resource preferences could not be saved";
                    } else {
                        result->preferences_saved = true;
                    }
                }
            }
        } catch (const std::exception& e) {
            result->error = e.what();
        } catch (...) {
            result->error = "Unknown error while configuring Gold Rush PoW mining";
        }
        if (result->created_payout_key) {
            std::lock_guard<std::mutex> lock{m_pow_payout_warning_mutex};
            m_pending_pow_payout_warnings.emplace(request.request_id, request.wallet_name);
        }
        result->info = m_wallet->getPowMiningInfo();
        QMetaObject::invokeMethod(this, [this, result] {
            QPointer<WalletModel> still_alive{this};
            publishPendingPowPayoutWarnings();
            if (!still_alive) return;
            m_pow_mining_control_cancels.erase(result->request.request_id);
            if (!result->request.view_current || result->request.view_current->load(std::memory_order_acquire)) {
                m_completed_pow_mining_controls.emplace(result->request.request_id, result);
                // Completed reads are retained until consumed, with a fixed
                // ceiling for clients which disappear without taking them.
                while (m_completed_pow_mining_controls.size() > 32) m_completed_pow_mining_controls.erase(m_completed_pow_mining_controls.begin());
                Q_EMIT powMiningControlReady(result->request.request_id, result->request.generation);
                if (!still_alive) return;
            }
            updateStatus();
        }, Qt::QueuedConnection);
    }, Qt::QueuedConnection);
    assert(invoked);
    return request.request_id;
}

void WalletModel::publishPendingPowPayoutWarnings()
{
    Q_ASSERT(QThread::currentThread() == thread());
    std::map<uint64_t, std::string> pending;
    {
        std::lock_guard<std::mutex> lock{m_pow_payout_warning_mutex};
        pending.swap(m_pending_pow_payout_warnings);
    }
    QPointer<WalletModel> still_alive{this};
    for (const auto& warning : pending) {
        Q_EMIT powPayoutKeyCreated(QString::fromStdString(warning.second));
        if (!still_alive) return;
    }
}

void WalletModel::cancelPowMiningControl(uint64_t request_id)
{
    const auto it = m_pow_mining_control_cancels.find(request_id);
    if (it != m_pow_mining_control_cancels.end()) it->second->store(true, std::memory_order_release);
    m_completed_pow_mining_controls.erase(request_id);
}

std::shared_ptr<const WalletModel::PowMiningControlResult> WalletModel::takePowMiningControlResult(uint64_t request_id)
{
    const auto it = m_completed_pow_mining_controls.find(request_id);
    if (it == m_completed_pow_mining_controls.end()) return {};
    auto result = it->second;
    m_completed_pow_mining_controls.erase(it);
    return result;
}

uint64_t WalletModel::requestPowClaimRecoveryPolicy(PowClaimRecoveryPolicyRequest request)
{
    Q_ASSERT(QThread::currentThread() == thread());
    if (m_account_snapshot_cancel) m_account_snapshot_cancel->store(true, std::memory_order_release);
    m_history_yield.store(true, std::memory_order_release);
    cancelStakingMiningSnapshot();
    // Policy reads and durable updates share WalletWorker with other wallet
    // walks. The Qt event thread only owns request/result bookkeeping. Issue
    // correlation lives here (rather than in a view) so recreated or parallel
    // pages can never collide or cancel one another's request.
    if (++m_pow_claim_recovery_policy_request_sequence == 0) {
        ++m_pow_claim_recovery_policy_request_sequence;
    }
    request.request_id = m_pow_claim_recovery_policy_request_sequence;
    request.wallet_name = m_wallet->getWalletName();
    const auto cancel = std::make_shared<std::atomic<bool>>(false);
    m_pow_claim_recovery_policy_cancels.emplace(request.request_id, cancel);

    if (m_joined || !worker || !t.isRunning()) {
        cancel->store(true, std::memory_order_release);
        auto result = std::make_shared<PowClaimRecoveryPolicyResult>();
        result->request = request;
        result->cancelled = true;
        result->error =
            "Wallet worker is stopping; the PoW claim recovery policy request was not started";
        const bool queued = QMetaObject::invokeMethod(
            this, [this, result] {
                const uint64_t request_id = result->request.request_id;
                m_completed_pow_claim_recovery_policy_results[request_id] =
                    result;
                m_pow_claim_recovery_policy_cancels.erase(request_id);
                QPointer<WalletModel> still_alive{this};
                Q_EMIT powClaimRecoveryPolicyReady(
                    request_id, result->request.generation);
                if (!still_alive) return;
                m_completed_pow_claim_recovery_policy_results.erase(
                    request_id);
            },
            Qt::QueuedConnection);
        assert(queued);
        return request.request_id;
    }

    const bool invoked = QMetaObject::invokeMethod(worker, [this, request, cancel] {
        assert(QThread::currentThread() == worker->thread());
        auto result = std::make_shared<PowClaimRecoveryPolicyResult>();
        result->request = request;

        const auto publish = [this, result] {
            QMetaObject::invokeMethod(this, [this, result] {
                const uint64_t request_id = result->request.request_id;
                m_completed_pow_claim_recovery_policy_results[request_id] = result;
                m_pow_claim_recovery_policy_cancels.erase(request_id);
                QPointer<WalletModel> still_alive{this};
                Q_EMIT powClaimRecoveryPolicyReady(
                    request_id, result->request.generation);
                if (!still_alive) return;
                // Connected GUI-thread slots consume their result
                // synchronously. Drop an unclaimed result after notification
                // (for example, when its originating view was destroyed).
                m_completed_pow_claim_recovery_policy_results.erase(request_id);
            }, Qt::QueuedConnection);
        };
        const auto checkpoint = [this, cancel, result] {
            if (cancel->load(std::memory_order_acquire) || m_node.shutdownRequested()) {
                result->cancelled = true;
                return true;
            }
            return false;
        };

        if (checkpoint()) {
            publish();
            return;
        }

        try {
            if (request.wallet_name != m_wallet->getWalletName()) {
                result->error = "Wallet identity changed before the PoW claim recovery policy request";
                publish();
                return;
            }
            if (request.operation == PowClaimRecoveryPolicyRequest::Operation::SET_POLICY) {
                // Cancellation is meaningful only before entering the durable
                // Core write. Once entered, the result may be discarded but
                // the committed operator choice is never represented as
                // cancelled or rolled back by the GUI.
                if (checkpoint()) {
                    publish();
                    return;
                }
                result->mutation_attempted = true;
                result->mutation =
                    m_wallet->setPowClaimRecoveryPolicyDetailed(request.policy);
                result->authoritative_state_checked = true;
                result->success = result->mutation.success;
                if (!result->success) result->error = result->mutation.detail;
                result->policy_available =
                    result->mutation.authoritative_state_available;
                if (result->policy_available) {
                    result->policy =
                        result->mutation.authoritative_policy;
                }
            } else {
                result->mutation =
                    m_wallet->getPowClaimRecoveryPolicyState();
                result->authoritative_state_checked = true;
                result->success = result->mutation.success;
                if (!result->success) result->error = result->mutation.detail;
                result->policy_available =
                    result->mutation.authoritative_state_available;
                if (result->policy_available) {
                    result->policy =
                        result->mutation.authoritative_policy;
                }
            }
        } catch (const std::exception& e) {
            result->success = false;
            result->error = e.what();
        } catch (...) {
            result->success = false;
            result->error = "Unknown error while reading or updating the PoW claim recovery policy";
        }

        publish();
    }, Qt::QueuedConnection);
    assert(invoked);
    return request.request_id;
}

void WalletModel::cancelPowClaimRecoveryPolicy(uint64_t request_id)
{
    const auto it = m_pow_claim_recovery_policy_cancels.find(request_id);
    if (it != m_pow_claim_recovery_policy_cancels.end()) {
        it->second->store(true, std::memory_order_release);
    }
}

std::shared_ptr<const WalletModel::PowClaimRecoveryPolicyResult>
WalletModel::takePowClaimRecoveryPolicyResult(uint64_t request_id)
{
    const auto it = m_completed_pow_claim_recovery_policy_results.find(request_id);
    if (it == m_completed_pow_claim_recovery_policy_results.end()) {
        return {};
    }
    const auto result = it->second;
    m_completed_pow_claim_recovery_policy_results.erase(it);
    return result;
}

uint64_t WalletModel::requestPowClaimRecoveryOperation(
    PowClaimRecoveryOperationRequest request)
{
    Q_ASSERT(QThread::currentThread() == thread());
    if (m_account_snapshot_cancel) m_account_snapshot_cancel->store(true, std::memory_order_release);
    m_history_yield.store(true, std::memory_order_release);
    cancelStakingMiningSnapshot();
    if (++m_pow_claim_recovery_operation_request_sequence == 0) {
        ++m_pow_claim_recovery_operation_request_sequence;
    }
    const uint64_t request_id = m_pow_claim_recovery_operation_request_sequence;
    request.request_id = request_id;
    request.wallet_name = m_wallet->getWalletName();

    const auto control =
        std::make_shared<PowClaimRecoveryOperationControl>();
    m_pow_claim_recovery_operation_controls.emplace(request_id, control);

    const bool mutating =
        request.operation == PowClaimRecoveryOperationRequest::Operation::EXECUTE ||
        request.operation == PowClaimRecoveryOperationRequest::Operation::ADOPT;
    const auto reject_queued = [this, &request, control](std::string error,
                                                bool cancelled,
                                                bool busy) {
        auto result = std::make_shared<PowClaimRecoveryOperationResult>();
        result->request = request;
        result->cancelled = cancelled;
        result->busy_rejected = busy;
        result->error = std::move(error);
        control->stage.store(PowClaimRecoveryOperationStage::FINISHED, std::memory_order_release);
        const bool invoked = QMetaObject::invokeMethod(
            this, [this, result] {
                publishPowClaimRecoveryOperationResult(result);
            }, Qt::QueuedConnection);
        assert(invoked);
    };
    if (m_joined || !worker || !t.isRunning()) {
        control->cancel_requested.store(true, std::memory_order_release);
        control->stage.store(
            PowClaimRecoveryOperationStage::CANCELLED_BEFORE_CORE,
            std::memory_order_release);
        reject_queued(
            "Wallet worker is stopping; the PoW claim recovery operation was not started",
            true, false);
        return request_id;
    }
    if (mutating && m_pow_claim_recovery_mutation_in_flight != 0) {
        reject_queued(
            "Another mutating PoW claim recovery or adoption operation is already in progress",
            false, true);
        return request_id;
    }
    if (mutating) {
        m_pow_claim_recovery_mutation_in_flight = request_id;
    }
    if (mutating) {
        // Defer the synchronous unlock prompt until after this method returns
        // its request id. The view can then cancel by id even if a wallet
        // switch/unload occurs inside the prompt's nested event loop.
        const bool invoked = QMetaObject::invokeMethod(
            this, [this, request = std::move(request), control]() mutable {
                if (control->cancel_requested.load(std::memory_order_acquire) ||
                    m_node.shutdownRequested() ||
                    (request.view_current &&
                     !request.view_current->load(std::memory_order_acquire))) {
                    control->cancel_requested.store(
                        true, std::memory_order_release);
                    control->stage.store(
                        PowClaimRecoveryOperationStage::CANCELLED_BEFORE_CORE,
                        std::memory_order_release);
                    auto result =
                        std::make_shared<PowClaimRecoveryOperationResult>();
                    result->request = std::move(request);
                    result->cancelled = true;
                    result->error =
                        "The PoW claim recovery operation was cancelled before entering Core";
                    publishPowClaimRecoveryOperationResult(result);
                    return;
                }

                // This is deliberately after the view's exact-plan
                // confirmation. The context lives through the Core call and
                // restores the prior lock/scope before publishing the result.
                const bool restore_staking_only =
                    getWalletUnlockStakingOnly();
                const bool initially_locked =
                    getEncryptionStatus() == Locked;
                request.staking_only_escalation =
                    !initially_locked && restore_staking_only;
                bool prompt_required = initially_locked;
                if (request.staking_only_escalation) {
                    // Register teardown restoration before changing either
                    // the cryptographic lock or the staking-only marker. A
                    // synchronous unlock handler is allowed to unload and
                    // destroy this WalletModel; join() can then restore the
                    // scope even though no UnlockContext was created yet.
                    m_pow_claim_recovery_restore_staking_only.emplace(
                        request.request_id, true);
                    if (!setWalletLocked(true) ||
                        getEncryptionStatus() != Locked) {
                        request.unlock_granted = false;
                        request.unlock_error =
                            "Could not safely leave the wallet's staking-only unlock scope; no recovery operation was started";
                        dispatchPowClaimRecoveryOperation(
                            std::move(request), control);
                        return;
                    }
                    prompt_required = true;
                }
                // Mode::Unlock initializes from this flag. Clear it while
                // locked so the prompt asks for a full signing unlock.
                if (restore_staking_only && prompt_required) {
                    setWalletUnlockStakingOnly(false);
                }

                QPointer<WalletModel> still_alive{this};
                if (prompt_required) Q_EMIT requireUnlock();
                if (!still_alive) return;

                const bool unlocked_after_prompt =
                    getEncryptionStatus() != Locked;
                request.unlock_granted = unlocked_after_prompt &&
                    !getWalletUnlockStakingOnly();
                if (request.unlock_granted) {
                    m_pow_claim_recovery_operation_unlocks.emplace(
                        request.request_id,
                        std::make_unique<UnlockContext>(
                            this, true, initially_locked));
                    m_pow_claim_recovery_restore_staking_only.emplace(
                        request.request_id, restore_staking_only);
                } else if (restore_staking_only) {
                    // A cancelled escalation cannot recreate the prior
                    // staking-only unlock without retaining a passphrase.
                    // Restore the scope marker and report whether the wallet
                    // necessarily remains locked. If the user explicitly
                    // chose staking-only in the prompt, that prior state is
                    // already restored and remains unlocked.
                    request.staking_only_escalation_left_locked =
                        request.staking_only_escalation &&
                        getEncryptionStatus() == Locked;
                    setWalletUnlockStakingOnly(true);
                }
                if (control->cancel_requested.load(std::memory_order_acquire) ||
                    (request.view_current &&
                     !request.view_current->load(std::memory_order_acquire))) {
                    control->cancel_requested.store(
                        true, std::memory_order_release);
                    // This request has not been dispatched yet, so Core
                    // cannot have crossed the entry boundary. Cancellation
                    // may already have won its CAS inside requireUnlock()'s
                    // nested event loop, before the UnlockContext below was
                    // created. Store the terminal pre-Core state and restore
                    // unconditionally so that newly acquired signing scope
                    // is not retained until worker publication.
                    control->stage.store(
                        PowClaimRecoveryOperationStage::CANCELLED_BEFORE_CORE,
                        std::memory_order_release);
                    restorePowClaimRecoveryUnlock(request.request_id);
                    auto result =
                        std::make_shared<PowClaimRecoveryOperationResult>();
                    result->request = std::move(request);
                    result->cancelled = true;
                    result->error =
                        "The PoW claim recovery operation was cancelled after unlock and before entering Core";
                    publishPowClaimRecoveryOperationResult(result);
                    return;
                }
                dispatchPowClaimRecoveryOperation(
                    std::move(request), control);
            },
            Qt::QueuedConnection);
        assert(invoked);
    } else {
        dispatchPowClaimRecoveryOperation(std::move(request), control);
    }
    return request_id;
}

void WalletModel::dispatchPowClaimRecoveryOperation(
    PowClaimRecoveryOperationRequest request,
    const std::shared_ptr<PowClaimRecoveryOperationControl>& control)
{
    Q_ASSERT(QThread::currentThread() == thread());
    if (!worker || !t.isRunning()) {
        auto result = std::make_shared<PowClaimRecoveryOperationResult>();
        result->request = std::move(request);
        result->cancelled = true;
        result->error =
            "Wallet worker stopped before the PoW claim recovery operation entered Core";
        control->stage.store(PowClaimRecoveryOperationStage::FINISHED, std::memory_order_release);
        const bool invoked = QMetaObject::invokeMethod(
            this, [this, result] {
                publishPowClaimRecoveryOperationResult(result);
            }, Qt::QueuedConnection);
        assert(invoked);
        return;
    }
    const bool invoked = QMetaObject::invokeMethod(worker, [this, request, control] {
        assert(QThread::currentThread() == worker->thread());
        auto result = std::make_shared<PowClaimRecoveryOperationResult>();
        result->request = request;

        const auto publish = [this, result, control] {
            // Retain the model through publication, including a produced
            // pre-Core cancellation and the worker-finished/GUI-queued gap.
            control->stage.store(PowClaimRecoveryOperationStage::FINISHED, std::memory_order_release);
            QMetaObject::invokeMethod(
                this, [this, result] {
                    publishPowClaimRecoveryOperationResult(result);
                }, Qt::QueuedConnection);
        };
        const auto cancelled_before_core = [&] {
            if (control->cancel_requested.load(std::memory_order_acquire) ||
                m_node.shutdownRequested()) {
                PowClaimRecoveryOperationStage expected =
                    PowClaimRecoveryOperationStage::QUEUED;
                control->stage.compare_exchange_strong(
                    expected,
                    PowClaimRecoveryOperationStage::CANCELLED_BEFORE_CORE,
                    std::memory_order_acq_rel);
                result->cancelled = true;
                return true;
            }
            return false;
        };

        if (cancelled_before_core()) {
            publish();
            return;
        }
        if (request.wallet_name != m_wallet->getWalletName()) {
            result->error = "Wallet identity changed before the PoW claim recovery operation";
            publish();
            return;
        }
        if (!request.unlock_granted) {
            if (!request.unlock_error.empty()) {
                result->error = request.unlock_error;
            } else if (request.staking_only_escalation_left_locked) {
                result->error =
                    "Normal wallet unlock was cancelled or unavailable. The wallet was locked to leave staking-only mode and remains locked; unlock it for staking again when ready";
            } else if (request.staking_only_escalation) {
                result->error =
                    "Normal wallet unlock was cancelled or unavailable. The prior staking-only unlock scope was restored; no recovery operation entered Core";
            } else {
                result->error =
                    "Normal wallet unlock was cancelled or unavailable";
            }
            publish();
            return;
        }
        if (cancelled_before_core()) {
            publish();
            return;
        }

        // Atomically cross the cancellation boundary. A GUI-thread cancel
        // that wins this race may restore its temporary unlock immediately;
        // once this compare/exchange succeeds, only publication/join may
        // restore it because Core may need signing authority.
        PowClaimRecoveryOperationStage expected =
            PowClaimRecoveryOperationStage::QUEUED;
        if (!control->stage.compare_exchange_strong(
                expected, PowClaimRecoveryOperationStage::CORE_ENTERED,
                std::memory_order_acq_rel)) {
            result->cancelled = true;
            publish();
            return;
        }
        result->core_entered = true;
        try {
            switch (request.operation) {
            case PowClaimRecoveryOperationRequest::Operation::REVIEW:
                result->review =
                    m_wallet->getPowClaimRecoveryReview(request.recovery);
                result->error = result->review.error;
                result->success = result->review.consistent &&
                    result->error.empty();
                break;
            case PowClaimRecoveryOperationRequest::Operation::EXECUTE:
                result->execution =
                    m_wallet->resolvePowClaims(request.recovery);
                result->error = result->execution.error;
                result->success = result->execution.success;
                break;
            case PowClaimRecoveryOperationRequest::Operation::ADOPT:
                result->adoption =
                    m_wallet->adoptPowClaimRecoveryComponentDetailed(
                    request.adoption_selector,
                    request.adoption_tip,
                    request.adoption_component_fingerprint);
                result->adopted = result->adoption.adopted;
                result->error = result->adoption.detail;
                result->success = result->adoption.success;
                break;
            }
        } catch (const std::exception& e) {
            result->error = e.what();
        } catch (...) {
            result->error = "Unknown error during the PoW claim recovery operation";
        }
        result->cancel_requested_after_core =
            control->cancel_requested.load(std::memory_order_acquire);
        control->stage.store(
            PowClaimRecoveryOperationStage::FINISHED,
            std::memory_order_release);
        publish();
    }, Qt::QueuedConnection);
    assert(invoked);
}

void WalletModel::publishPowClaimRecoveryOperationResult(
    const std::shared_ptr<PowClaimRecoveryOperationResult>& result)
{
    Q_ASSERT(QThread::currentThread() == thread());
    const uint64_t request_id = result->request.request_id;
    const auto pending = m_pow_claim_recovery_operation_controls.find(request_id);
    if (pending != m_pow_claim_recovery_operation_controls.end()) {
        pending->second->stage.store(PowClaimRecoveryOperationStage::FINISHED, std::memory_order_release);
    }
    if (m_joined && !tryRestorePowClaimRecoveryUnlock(request_id)) {
        QTimer::singleShot(25, this, [this, result] { publishPowClaimRecoveryOperationResult(result); });
        return;
    }
    const auto control_it =
        m_pow_claim_recovery_operation_controls.find(request_id);
    const bool cancel_requested_now =
        control_it != m_pow_claim_recovery_operation_controls.end() &&
        control_it->second->cancel_requested.load(std::memory_order_acquire);
    const bool originating_view_current =
        !result->request.view_current ||
        result->request.view_current->load(std::memory_order_acquire);
    // The worker's post-Core sample is not the publication boundary. A
    // dialog close or wallet switch can happen after that sample but before
    // this GUI-thread callback. Re-evaluate both tokens here so a durable
    // mutating outcome is never silently discarded with its old view.
    result->cancel_requested_after_core =
        result->cancel_requested_after_core ||
        (result->core_entered &&
         (cancel_requested_now || !originating_view_current));
    m_completed_pow_claim_recovery_operation_results[request_id] = result;
    // Keep FINISHED through both signals: their handlers may spin an event
    // loop which runs shutdownReady again before publication has returned.

    // Restore the exact pre-request unlock state before making the result
    // observable. For an initially staking-only-unlocked wallet the context
    // deliberately does not relock; the marker is restored after its generic
    // normal-unlock cleanup. Locked and normally unlocked wallets retain
    // their original state as well.
    restorePowClaimRecoveryUnlock(request_id);
    if (m_pow_claim_recovery_mutation_in_flight == request_id) {
        m_pow_claim_recovery_mutation_in_flight = 0;
    }

    if (result->cancel_requested_after_core &&
        result->request.operation !=
            PowClaimRecoveryOperationRequest::Operation::REVIEW) {
        QPointer<WalletModel> still_alive{this};
        QString body;
        if (result->request.operation ==
            PowClaimRecoveryOperationRequest::Operation::EXECUTE) {
            if (result->execution.durable_state_ambiguous) {
                body = tr("The recovery dialog closed after Core began. The durable database outcome is indeterminate: exact recovery bytes or relay authority may already exist. Reload the wallet and inspect the recovery screen before another action.");
            } else if (result->success) {
                body = tr("The recovery dialog closed after Core began, but Core completed the exact plan: %1 signed and persisted; %2 newly granted relay authority; %3 broadcast; %4 relay(s) deferred. Review the wallet's recovery screen before another action.")
                           .arg(result->execution.signed_and_persisted)
                           .arg(result->execution.relay_authority_granted)
                           .arg(result->execution.broadcast)
                           .arg(result->execution.relay_deferred);
            } else {
                body = tr("The recovery dialog closed after Core began. Core returned: %1%2")
                           .arg(QString::fromStdString(result->error))
                           .arg(result->execution.durable_state_changed ||
                                        result->execution.relay_authority_granted != 0
                                    ? tr(" Durable wallet state changed; reload and inspect the recovery screen before another action.")
                                    : QString());
            }
        } else if (result->adoption.durable_state_ambiguous) {
            body = tr("The adoption dialog closed after Core began. The durable adoption outcome is indeterminate; provenance may already have been stored. Reload the wallet and inspect its recovery records before another action.");
        } else if (result->success) {
            body = result->adoption.durable_state_changed
                ? tr("The adoption dialog closed after Core began, but Core durably adopted the exact reviewed component. Refresh the recovery screen before another action.")
                : tr("The adoption dialog closed after Core began. Core reports the exact reviewed component already authenticated. Refresh the recovery screen before another action.");
        } else {
            body = tr("The adoption dialog closed after Core began. Core returned: %1%2")
                       .arg(QString::fromStdString(result->error))
                       .arg(result->adoption.durable_state_changed
                                ? tr(" Durable wallet state changed; reload and inspect its recovery records before another action.")
                                : QString());
        }
        Q_EMIT message(
            tr("Gold Rush claim recovery"), body,
            result->success ? CClientUIInterface::MSG_INFORMATION
                            : CClientUIInterface::MSG_ERROR);
        if (!still_alive) return;
    }
    QPointer<WalletModel> still_alive{this};
    Q_EMIT powClaimRecoveryOperationReady(
        request_id, result->request.generation);
    if (!still_alive) return;
    m_pow_claim_recovery_operation_controls.erase(request_id);
    m_completed_pow_claim_recovery_operation_results.erase(request_id);
}

void WalletModel::cancelPowClaimRecoveryOperation(uint64_t request_id)
{
    Q_ASSERT(QThread::currentThread() == thread());
    const auto it = m_pow_claim_recovery_operation_controls.find(request_id);
    if (it != m_pow_claim_recovery_operation_controls.end()) {
        const auto& control = it->second;
        control->cancel_requested.store(true, std::memory_order_release);
        PowClaimRecoveryOperationStage expected =
            PowClaimRecoveryOperationStage::QUEUED;
        if (control->stage.compare_exchange_strong(
                expected,
                PowClaimRecoveryOperationStage::CANCELLED_BEFORE_CORE,
                std::memory_order_acq_rel)) {
            // The worker can no longer enter Core. Restore any temporary
            // normal signing scope synchronously on the GUI thread rather
            // than holding it until this request reaches the worker queue.
            restorePowClaimRecoveryUnlock(request_id);
        }
    }
}

void WalletModel::restorePowClaimRecoveryUnlock(uint64_t request_id)
{
    Q_ASSERT(QThread::currentThread() == thread());
    if (m_joined) {
        // Keep the cleanup obligation until a later shutdown poll can obtain
        // both locks. A queued completion must not reintroduce a GUI wait.
        tryRestorePowClaimRecoveryUnlock(request_id);
        return;
    }
    m_pow_claim_recovery_operation_unlocks.erase(request_id);
    const auto restore_it =
        m_pow_claim_recovery_restore_staking_only.find(request_id);
    if (restore_it != m_pow_claim_recovery_restore_staking_only.end()) {
        if (restore_it->second) setWalletUnlockStakingOnly(true);
        m_pow_claim_recovery_restore_staking_only.erase(restore_it);
    }
}

bool WalletModel::tryRestorePowClaimRecoveryUnlock(uint64_t request_id)
{
    Q_ASSERT(QThread::currentThread() == thread());
    const auto unlock = m_pow_claim_recovery_operation_unlocks.find(request_id);
    if (unlock != m_pow_claim_recovery_operation_unlocks.end()) {
        if (!unlock->second->tryRestore()) return false;
        m_pow_claim_recovery_operation_unlocks.erase(unlock);
    }
    const auto scope = m_pow_claim_recovery_restore_staking_only.find(request_id);
    if (scope != m_pow_claim_recovery_restore_staking_only.end()) {
        if (!m_wallet->tryRestoreGuiUnlockState(false, scope->second)) return false;
        m_pow_claim_recovery_restore_staking_only.erase(scope);
    }
    return true;
}

std::shared_ptr<const WalletModel::PowClaimRecoveryOperationResult>
WalletModel::takePowClaimRecoveryOperationResult(uint64_t request_id)
{
    const auto it = m_completed_pow_claim_recovery_operation_results.find(request_id);
    if (it == m_completed_pow_claim_recovery_operation_results.end()) {
        return {};
    }
    const auto result = it->second;
    m_completed_pow_claim_recovery_operation_results.erase(it);
    return result;
}

void WalletModel::updateTransaction()
{
    // Balance and number of transactions might have changed
    invalidateBalanceSnapshot();
}

void WalletModel::updateAddressBook(const QString &address, const QString &label,
        bool isMine, wallet::AddressPurpose purpose, int status)
{
    invalidateBalanceSnapshot();
    transactionTableModel->invalidateAddressLabel(address);
    if(addressTableModel)
        addressTableModel->updateEntry(address, label, isMine, purpose, status);
}

void WalletModel::updateWatchOnlyFlag(bool fHaveWatchonly)
{
    fHaveWatchOnly = fHaveWatchonly;
    Q_EMIT notifyWatchonlyChanged(fHaveWatchonly);
}

bool WalletModel::validateAddress(const QString& address) const
{
    return IsValidDestinationString(address.toStdString());
}

WalletModel::SendCoinsReturn WalletModel::prepareTransaction(WalletModelTransaction &transaction, const CCoinControl& coinControl)
{
    CAmount total = 0;
    bool fSubtractFeeFromAmount = false;
    QList<SendCoinsRecipient> recipients = transaction.getRecipients();
    std::vector<CRecipient> vecSend;

    if(recipients.empty())
    {
        return OK;
    }

    QSet<QString> setAddress; // Used to detect duplicates
    int nAddresses = 0;

    // Pre-check input data for validity
    for (const SendCoinsRecipient &rcp : recipients)
    {
        if (rcp.fSubtractFeeFromAmount)
            fSubtractFeeFromAmount = true;
        {   // User-entered bitcoin address / amount:
            if(!validateAddress(rcp.address))
            {
                return InvalidAddress;
            }
            if(rcp.amount <= 0)
            {
                return InvalidAmount;
            }
            setAddress.insert(rcp.address);
            ++nAddresses;

            CRecipient recipient{DecodeDestination(rcp.address.toStdString()), rcp.amount, rcp.fSubtractFeeFromAmount};
            vecSend.push_back(recipient);

            total += rcp.amount;
        }
    }
    if (setAddress.size() != nAddresses)
    {
        return DuplicateAddress;
    }

    // If no coin was manually selected, use the cached balance
    // Future: can merge this call with 'createTransaction'.
    CAmount nBalance = getAvailableBalance(&coinControl);

    if(total > nBalance)
    {
        return AmountExceedsBalance;
    }

    try {
        CAmount nFeeRequired = 0;
        int nChangePosRet = -1;

        auto& newTx = transaction.getWtx();
        const auto& res = m_wallet->createTransaction(vecSend, coinControl, /*sign=*/!wallet().privateKeysDisabled(), nChangePosRet, nFeeRequired);
        newTx = res ? *res : nullptr;
        transaction.setTransactionFee(nFeeRequired);
        if (fSubtractFeeFromAmount && newTx)
            transaction.reassignAmounts(nChangePosRet);

        if(!newTx)
        {
            if(!fSubtractFeeFromAmount && (total + nFeeRequired) > nBalance)
            {
                return SendCoinsReturn(AmountWithFeeExceedsBalance);
            }
            Q_EMIT message(tr("Send Coins"), QString::fromStdString(util::ErrorString(res).translated),
                CClientUIInterface::MSG_ERROR);
            return TransactionCreationFailed;
        }

        // Reject absurdly high fee. (This can never happen because the
        // wallet never creates transactions with fee greater than
        // m_default_max_tx_fee. This merely a belt-and-suspenders check).
        if (nFeeRequired > m_wallet->getDefaultMaxTxFee()) {
            return AbsurdFee;
        }
    } catch (const std::runtime_error& err) {
        // Something unexpected happened, instruct user to report this bug.
        Q_EMIT message(tr("Send Coins"), QString::fromStdString(err.what()),
                       CClientUIInterface::MSG_ERROR);
        return TransactionCreationFailed;
    }

    return SendCoinsReturn(OK);
}

void WalletModel::sendCoins(WalletModelTransaction& transaction)
{
    QByteArray transaction_array; /* store serialized transaction */

    {
        std::vector<std::pair<std::string, std::string>> vOrderForm;
        for (const SendCoinsRecipient &rcp : transaction.getRecipients())
        {
            if (!rcp.message.isEmpty()) // Message from normal bitcoin:URI (bitcoin:123...?message=example)
                vOrderForm.emplace_back("Message", rcp.message.toStdString());
        }

        auto& newTx = transaction.getWtx();
        wallet().commitTransaction(newTx, /*value_map=*/{}, std::move(vOrderForm));

        DataStream ssTx;
        ssTx << TX_WITH_WITNESS(*newTx);
        transaction_array.append((const char*)ssTx.data(), ssTx.size());
    }

    // Add addresses / update labels that we've sent to the address book,
    // and emit coinsSent signal for each recipient
    for (const SendCoinsRecipient &rcp : transaction.getRecipients())
    {
        {
            std::string strAddress = rcp.address.toStdString();
            CTxDestination dest = DecodeDestination(strAddress);
            std::string strLabel = rcp.label.toStdString();
            {
                // Check if we have a new address or an updated label
                std::string name;
                const bool has_address = m_wallet->getAddress(dest, &name, /*is_mine=*/nullptr, /*purpose=*/nullptr);
                const bool needs_update = !has_address || name != strLabel;
                if (needs_update && !m_wallet->setAddressBook(
                        dest, strLabel,
                        has_address ? std::optional<wallet::AddressPurpose>{} : wallet::AddressPurpose::SEND)) {
                    qWarning("Could not commit recipient address-book label; reload the wallet before retrying");
                }
            }
        }
        Q_EMIT coinsSent(this, rcp, transaction_array);
    }

    // Commit and funding checks above stay authoritative. Refresh display asynchronously.
    invalidateBalanceSnapshot();
    pollBalanceChanged();
}

OptionsModel* WalletModel::getOptionsModel() const
{
    return optionsModel;
}

AddressTableModel* WalletModel::getAddressTableModel() const
{
    return addressTableModel;
}

TransactionTableModel* WalletModel::getTransactionTableModel() const
{
    return transactionTableModel;
}

RecentRequestsTableModel* WalletModel::getRecentRequestsTableModel() const
{
    return recentRequestsTableModel;
}

WalletModel::EncryptionStatus WalletModel::getEncryptionStatus() const
{
    if(!m_wallet->isCrypted())
    {
        // A previous bug allowed for watchonly wallets to be encrypted (encryption keys set, but nothing is actually encrypted).
        // To avoid misrepresenting the encryption status of such wallets, we only return NoKeys for watchonly wallets that are unencrypted.
        if (m_wallet->privateKeysDisabled()) {
            return NoKeys;
        }
        return Unencrypted;
    }
    else if(m_wallet->isLocked())
    {
        return Locked;
    }
    else
    {
        return Unlocked;
    }
}

bool WalletModel::setWalletEncrypted(const SecureString& passphrase)
{
    return m_wallet->encryptWallet(passphrase);
}

bool WalletModel::setWalletLocked(bool locked, const SecureString &passPhrase,
                                  std::optional<bool> staking_only)
{
    if(locked)
    {
        // Lock
        return m_wallet->lock();
    }
    else
    {
        // Unlock
        return m_wallet->unlock(passPhrase, staking_only);
    }
}

bool WalletModel::changePassphrase(const SecureString &oldPass, const SecureString &newPass)
{
    m_wallet->lock(); // Make sure wallet is locked before attempting pass change
    return m_wallet->changeWalletPassphrase(oldPass, newPass);
}

// Handlers for core signals
static void NotifyUnload(WalletModel* walletModel)
{
    qDebug() << "NotifyUnload";
    bool invoked = QMetaObject::invokeMethod(walletModel, "unload");
    assert(invoked);
}

static void NotifyKeyStoreStatusChanged(WalletModel *walletmodel)
{
    qDebug() << "NotifyKeyStoreStatusChanged";
    bool invoked = QMetaObject::invokeMethod(walletmodel, "updateStatus", Qt::QueuedConnection);
    assert(invoked);
}

static void NotifyAddressBookChanged(WalletModel *walletmodel,
        const CTxDestination &address, const std::string &label, bool isMine,
        wallet::AddressPurpose purpose, ChangeType status)
{
    QString strAddress = QString::fromStdString(EncodeDestination(address));
    QString strLabel = QString::fromStdString(label);

    qDebug() << "NotifyAddressBookChanged: " + strAddress + " " + strLabel + " isMine=" + QString::number(isMine) + " purpose=" + QString::number(static_cast<uint8_t>(purpose)) + " status=" + QString::number(status);
    bool invoked = QMetaObject::invokeMethod(walletmodel, "updateAddressBook",
                              Q_ARG(QString, strAddress),
                              Q_ARG(QString, strLabel),
                              Q_ARG(bool, isMine),
                              Q_ARG(wallet::AddressPurpose, purpose),
                              Q_ARG(int, status));
    assert(invoked);
}

static void NotifyTransactionChanged(WalletModel *walletmodel, const uint256 &hash, ChangeType status)
{
    Q_UNUSED(hash);
    Q_UNUSED(status);
    walletmodel->queueTransactionChanged();
}

void WalletModel::queueTransactionChanged()
{
    if (m_transaction_notification_queued.exchange(true, std::memory_order_acq_rel)) return;
    const bool invoked = QMetaObject::invokeMethod(this, [this] {
        // Rearm before sampling so a concurrent mutation always has a later
        // notification. A burst before rearming needs only this dirty update.
        m_transaction_notification_queued.store(false, std::memory_order_release);
        if (!m_joined) updateTransaction();
    }, Qt::QueuedConnection);
    assert(invoked);
}

static void ShowProgress(WalletModel *walletmodel, const std::string &title, int nProgress)
{
    // emits signal "showProgress"
    bool invoked = QMetaObject::invokeMethod(walletmodel, "showProgress", Qt::QueuedConnection,
                              Q_ARG(QString, QString::fromStdString(title)),
                              Q_ARG(int, nProgress));
    assert(invoked);
}

static void NotifyWatchonlyChanged(WalletModel *walletmodel, bool fHaveWatchonly)
{
    bool invoked = QMetaObject::invokeMethod(walletmodel, "updateWatchOnlyFlag", Qt::QueuedConnection,
                              Q_ARG(bool, fHaveWatchonly));
    assert(invoked);
}

void WalletModel::setAddressCapabilityConsumer(const QObject* consumer, bool active)
{
    if (active && !m_joined) {
        if (!m_address_capability_consumers.insert(consumer).second) return;
        m_address_capability_observed.store(true, std::memory_order_release);
        // Refresh on reentry even if a notification was suppressed while hidden.
        m_address_capability_dirty.store(true, std::memory_order_release);
        requestAddressCapability();
    } else {
        m_address_capability_consumers.erase(consumer);
        if (!m_address_capability_consumers.empty()) return;
        m_address_capability_observed.store(false, std::memory_order_release);
        m_address_capability_dirty.store(true, std::memory_order_release);
        m_address_capability_retry->stop();
        if (m_address_capability_cancel) m_address_capability_cancel->store(true, std::memory_order_release);
    }
}

void WalletModel::queueAddressCapabilityChanged()
{
    m_address_capability_dirty.store(true, std::memory_order_release);
    if (!m_address_capability_observed.load(std::memory_order_acquire) ||
        m_address_capability_notification_queued.exchange(true, std::memory_order_acq_rel)) return;
    const bool invoked = QMetaObject::invokeMethod(this, [this] {
        m_address_capability_notification_queued.store(false, std::memory_order_release);
        requestAddressCapability();
    }, Qt::QueuedConnection);
    assert(invoked);
}

void WalletModel::requestAddressCapability()
{
    if (m_joined || m_address_capability_consumers.empty() || m_address_capability_in_flight ||
        m_address_capability_retry->isActive() || !m_address_capability_dirty.exchange(false, std::memory_order_acq_rel)) return;
    m_address_capability_in_flight = true;
    const auto cancel = std::make_shared<std::atomic<bool>>(false);
    m_address_capability_cancel = cancel;
    const bool invoked = QMetaObject::invokeMethod(worker, [this, cancel] {
        bool capable{false};
        const bool ready = !cancel->load(std::memory_order_acquire) && m_wallet->tryCanGetAddresses(capable);
        QMetaObject::invokeMethod(this, [this, cancel, ready, capable] {
            m_address_capability_in_flight = false;
            if (m_joined) return;
            // A successful read is an advisory point-in-time value. Do not
            // starve initial publication during notification-heavy sync, and
            // never clear a concurrent dirty notification here. Hide/rebind
            // cancellation still prevents publication into a later epoch.
            if (!cancel->load(std::memory_order_acquire) && ready &&
                m_address_capability_cancel == cancel && !m_address_capability_consumers.empty()) {
                if (m_address_capability != capable) {
                    m_address_capability = capable;
                    Q_EMIT canGetAddressesChanged();
                }
            } else {
                m_address_capability_dirty.store(true, std::memory_order_release);
            }
            if (!m_address_capability_consumers.empty() && m_address_capability_dirty.load(std::memory_order_acquire)) {
                m_address_capability_retry->start(MODEL_UPDATE_DELAY);
            }
        }, Qt::QueuedConnection);
    }, Qt::QueuedConnection);
    assert(invoked);
}

static void NotifyCanGetAddressesChanged(WalletModel* walletmodel)
{
    walletmodel->queueAddressCapabilityChanged();
}

void WalletModel::subscribeToCoreSignals()
{
    // Connect signals to wallet
    m_handler_unload = m_wallet->handleUnload(std::bind(&NotifyUnload, this));
    m_handler_status_changed = m_wallet->handleStatusChanged(std::bind(&NotifyKeyStoreStatusChanged, this));
    m_handler_address_book_changed = m_wallet->handleAddressBookChanged(std::bind(NotifyAddressBookChanged, this, std::placeholders::_1, std::placeholders::_2, std::placeholders::_3, std::placeholders::_4, std::placeholders::_5));
    m_handler_transaction_changed = m_wallet->handleTransactionChanged(std::bind(NotifyTransactionChanged, this, std::placeholders::_1, std::placeholders::_2));
    m_handler_show_progress = m_wallet->handleShowProgress(std::bind(ShowProgress, this, std::placeholders::_1, std::placeholders::_2));
    m_handler_watch_only_changed = m_wallet->handleWatchOnlyChanged(std::bind(NotifyWatchonlyChanged, this, std::placeholders::_1));
    m_handler_can_get_addrs_changed = m_wallet->handleCanGetAddressesChanged(std::bind(NotifyCanGetAddressesChanged, this));
}

void WalletModel::unsubscribeFromCoreSignals()
{
    // Disconnect signals from wallet
    m_handler_unload->disconnect();
    m_handler_status_changed->disconnect();
    m_handler_address_book_changed->disconnect();
    m_handler_transaction_changed->disconnect();
    m_handler_show_progress->disconnect();
    m_handler_watch_only_changed->disconnect();
    m_handler_can_get_addrs_changed->disconnect();
}

// WalletModel::UnlockContext implementation
WalletModel::UnlockContext WalletModel::requestUnlock()
{
    const bool initially_locked = getEncryptionStatus() == Locked;
    const bool initially_staking_only = getWalletUnlockStakingOnly();
    bool prompt_required = initially_locked;

    if (!initially_locked && initially_staking_only) {
        // Revoke the installed staking-only key before preparing a normal
        // unlock. Clearing the marker first would transiently grant ordinary
        // transaction and PoW signing authority without a passphrase prompt.
        if (!setWalletLocked(true) || getEncryptionStatus() != Locked) {
            return UnlockContext(this, /*valid=*/false, /*relock=*/false);
        }
        prompt_required = true;
    }

    if (prompt_required && getWalletUnlockStakingOnly()) {
        // Mode::Unlock has no visible scope selector. Stage the normal scope
        // only while the wallet is locked so a successful prompt installs the
        // key and requested authority atomically.
        setWalletUnlockStakingOnly(false);
    }

    if (prompt_required) {
        // Request UI to unlock wallet
        Q_EMIT requireUnlock();
    }

    // A generic signing request requires normal authority. An unexpected
    // staking-only unlock is not enough and must not be expanded after the
    // prompt by merely clearing the scope marker.
    const bool valid = getEncryptionStatus() != Locked &&
                       !getWalletUnlockStakingOnly();
    if (!valid) {
        if (getEncryptionStatus() == Unlocked) setWalletLocked(true);
        if (initially_staking_only) setWalletUnlockStakingOnly(true);
        return UnlockContext(this, /*valid=*/false, /*relock=*/false);
    }

    return UnlockContext(
        this, /*valid=*/true, /*relock=*/initially_locked,
        initially_staking_only ? std::optional<bool>{true} : std::nullopt);
}

WalletModel::UnlockContext::UnlockContext(
    WalletModel *_wallet, bool _valid, bool _relock,
    std::optional<bool> restore_staking_only):
        wallet(_wallet),
        valid(_valid),
        relock(_relock),
        restoreStakingOnly(restore_staking_only)
{}

bool WalletModel::UnlockContext::tryRestore()
{
    if (restored) return true;
    if (!wallet->wallet().tryRestoreGuiUnlockState(valid && relock, restoreStakingOnly.value_or(false))) return false;
    restored = true;
    return true;
}

WalletModel::UnlockContext::~UnlockContext()
{
    if (restored) return;
    if(valid && relock)
    {
        wallet->setWalletLocked(true);
    }

    if (restoreStakingOnly) {
        wallet->setWalletUnlockStakingOnly(*restoreStakingOnly);
        wallet->updateStatus();
    }
}

bool WalletModel::displayAddress(std::string sAddress) const
{
    CTxDestination dest = DecodeDestination(sAddress);
    bool res = false;
    try {
        res = m_wallet->displayAddress(dest);
    } catch (const std::runtime_error& e) {
        QMessageBox::critical(nullptr, tr("Can't display address"), e.what());
    }
    return res;
}

bool WalletModel::isWalletEnabled()
{
   return !gArgs.GetBoolArg("-disablewallet", DEFAULT_DISABLE_WALLET);
}

QString WalletModel::getWalletName() const
{
    return QString::fromStdString(m_wallet->getWalletName());
}

QString WalletModel::getDisplayName() const
{
    const QString name = getWalletName();
    return name.isEmpty() ? "["+tr("default wallet")+"]" : name;
}

bool WalletModel::isMultiwallet() const
{
    return m_node.walletLoader().getWallets().size() > 1;
}

void WalletModel::refresh(bool pk_hash_only)
{
    addressTableModel = new AddressTableModel(this, pk_hash_only);
}

uint256 WalletModel::getLastBlockProcessed() const
{
    return m_client_model ? m_client_model->getBestBlockHash() : uint256{};
}

CAmount WalletModel::getAvailableBalance(const CCoinControl* control)
{
    // No selected coins and no source-family filter: return the cached aggregate balance.
    // If the Send page selected "Legacy" or "Quantum" funds, ask the wallet for the
    // family-filtered spendable balance even when inputs have not been hand-picked.
    if (!control || (!control->HasSelected() && !control->m_input_family)) {
        const interfaces::WalletBalances& balances = getCachedBalance();
        CAmount available_balance = balances.balance;
        // if wallet private keys are disabled, this is a watch-only wallet
        // so, let's include the watch-only balance.
        if (balances.have_watch_only && m_wallet->privateKeysDisabled()) {
            available_balance += balances.watch_only_balance;
        }
        return available_balance;
    }
    // Fetch balance from the wallet, taking into account the selected coins
    return wallet().getAvailableBalance(*control);
}

uint64_t WalletModel::getStakeWeight()
{
    return nWeight.load(std::memory_order_relaxed);
}

bool WalletModel::getWalletUnlockStakingOnly()
{
    return m_wallet->getWalletUnlockStakingOnly();
}

void WalletModel::setWalletUnlockStakingOnly(bool unlock)
{
    m_wallet->setWalletUnlockStakingOnly(unlock);
}

void WalletModel::checkStakeWeightChanged()
{
    uint64_t weight{0};
    if (updateStakeWeight && m_wallet->tryGetStakeWeight(weight)) {
        nWeight.store(weight, std::memory_order_relaxed);
        updateStakeWeight = false;
    }
}

void WalletModel::beginShutdown()
{
    if (m_joined) return;
    m_joined = true;
    m_address_capability_observed.store(false, std::memory_order_release);
    m_address_capability_consumers.clear();
    m_address_capability_retry->stop();
    if (m_address_capability_cancel) m_address_capability_cancel->store(true, std::memory_order_release);
    m_history_cancel.store(true, std::memory_order_release);

    // Stop timer
    if (timer)
        timer->stop();

    if (m_account_snapshot_cancel) m_account_snapshot_cancel->store(true, std::memory_order_release);
    m_history_yield.store(true, std::memory_order_release);
    cancelStakingMiningSnapshot();
    for (const auto& entry : m_pow_mining_control_cancels) {
        entry.second->store(true, std::memory_order_release);
    }
    for (const auto& entry : m_pow_claim_recovery_policy_cancels) {
        entry.second->store(true, std::memory_order_release);
    }
    // Mutating recovery/adoption work can hold a temporary full wallet
    // unlock. Mark every queued or running request cancelled before stopping
    // the worker so no pre-Core request can survive wallet-model shutdown.
    for (const auto& entry : m_pow_claim_recovery_operation_controls) {
        entry.second->cancel_requested.store(true, std::memory_order_release);
        PowClaimRecoveryOperationStage expected =
            PowClaimRecoveryOperationStage::QUEUED;
        if (entry.second->stage.compare_exchange_strong(
                expected,
                PowClaimRecoveryOperationStage::CANCELLED_BEFORE_CORE,
                std::memory_order_acq_rel)) {
            restorePowClaimRecoveryUnlock(entry.first);
        }
    }

    t.quit();
}

bool WalletModel::shutdownReady()
{
    // In-Core requests retain their unlock until the owned worker has exited.
    if (!t.wait(0)) return false;
    while (!m_pow_claim_recovery_operation_unlocks.empty()) {
        if (!tryRestorePowClaimRecoveryUnlock(m_pow_claim_recovery_operation_unlocks.begin()->first)) return false;
    }
    while (!m_pow_claim_recovery_restore_staking_only.empty()) {
        if (!tryRestorePowClaimRecoveryUnlock(m_pow_claim_recovery_restore_staking_only.begin()->first)) return false;
    }
    for (const auto& entry : m_pow_claim_recovery_operation_controls) {
        if (entry.second->stage.load(std::memory_order_acquire) == PowClaimRecoveryOperationStage::FINISHED) return false;
    }
    return true;
}

void WalletModel::join()
{
    beginShutdown();
    // Destructors retain a safe blocking fallback; the application drains on
    // its event loop and reaches this point only after shutdownReady().
    // The worker stays alive until this function deletes it, so it is safe to
    // disconnect it here even if beginShutdown() already asked the thread to
    // quit and the thread is exiting concurrently.
    if (worker) worker->disconnect(this);
    t.quit();
    t.wait();
    // The thread has exited: no slot can be running on the worker, and a
    // QObject whose thread has finished may be deleted from another thread.
    delete worker;
    worker = nullptr;

    // The queued completion may never run during unload. Critical backup
    // receipts are recorded by the worker and drained before model destruction;
    // WalletController forwards them independently of the deleted WalletView.
    publishPendingPowPayoutWarnings();

    // A worker result normally performs this restoration on the GUI thread.
    // join() may prevent that queued publication from running, so restore all
    // temporary unlock contexts here after any in-Core operation has exited.
    m_pow_claim_recovery_operation_unlocks.clear();
    for (const auto& entry : m_pow_claim_recovery_restore_staking_only) {
        if (entry.second) setWalletUnlockStakingOnly(true);
    }
    m_pow_claim_recovery_restore_staking_only.clear();
    m_pow_claim_recovery_mutation_in_flight = 0;
}
