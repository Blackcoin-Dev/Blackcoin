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
#include <qt/transactiontablemodel.h>

#include <common/args.h> // for GetBoolArg
#include <interfaces/handler.h>
#include <interfaces/node.h>
#include <key_io.h>
#include <node/interface_ui.h>
#include <psbt.h>
#include <util/translation.h>
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

static int pollSyncSkip = 30;

class WalletWorker : public QObject
{
    Q_OBJECT
public:
    WalletModel *walletModel;
    WalletWorker(WalletModel *_walletModel):
        walletModel(_walletModel){}

private Q_SLOTS:
    void updateModel()
    {
        if(walletModel && walletModel->node().shutdownRequested())
            return;

        // Update the model with results of tasks that take more time to be
        // completed. Both walk the wallet, so they run on this worker thread;
        // GUI-side state is applied via queued invocations back to the model.
        walletModel->pollBalanceChanged();
        walletModel->checkStakeWeightChanged();
    }
};

#include <qt/walletmodel.moc>

WalletModel::WalletModel(std::unique_ptr<interfaces::Wallet> wallet, ClientModel& client_model, const PlatformStyle *platformStyle, QObject *parent) :
    QObject(parent),
    m_wallet(std::move(wallet)),
    m_client_model(&client_model),
    m_node(client_model.node()),
    optionsModel(client_model.getOptionsModel()),
    timer(new QTimer(this)),
    nWeight(0),
    updateStakeWeight(true),
    worker(0)
{
    // Establish the GUI-thread cache before any view is attached. Later
    // keystore notifications update it in updateStatus(). Timer-driven views
    // read this cache instead of entering cs_wallet themselves.
    cachedEncryptionStatus.store(getEncryptionStatus(), std::memory_order_release);
    fHaveWatchOnly = m_wallet->haveWatchOnly();
    addressTableModel = new AddressTableModel(this);
    transactionTableModel = new TransactionTableModel(platformStyle, this);
    recentRequestsTableModel = new RecentRequestsTableModel(this);

    // Start thread
    worker = new WalletWorker(this);
    worker->moveToThread(&(t));
    // WalletWorker has thread affinity and deliberately has no QObject parent.
    // Retire it on its own thread when the event loop finishes instead of
    // leaking one worker for every WalletModel lifetime.
    connect(&t, &QThread::finished, worker, &QObject::deleteLater);
    t.start();

    subscribeToCoreSignals();
}

WalletModel::~WalletModel()
{
    unsubscribeFromCoreSignals();

    join();
}

void WalletModel::startPollBalance()
{
    // Update the cached balance right away, so every view can make use of it,
    // so them don't need to waste resources recalculating it. This initial
    // call runs on the GUI thread once, before the worker timer starts.
    pollBalanceChanged();

    // The periodic balance/stake-weight poll walks the wallet, which takes
    // seconds on large wallets, so it runs on the worker thread (see
    // WalletWorker::updateModel); results are marshalled back to this (GUI)
    // thread via queued invocations.
    connect(timer, SIGNAL(timeout()), worker, SLOT(updateModel()));
    timer->start(MODEL_UPDATE_DELAY);
}

void WalletModel::setClientModel(ClientModel* client_model)
{
    m_client_model = client_model;
    if (!m_client_model) timer->stop();
}

void WalletModel::updateStatus()
{
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
    // Get node synchronization information
    int numBlocks = -1;
    bool isSyncing = false;
    pollNum++;
    if (!m_node.tryGetSyncInfo(numBlocks, isSyncing) || (isSyncing && pollNum < pollSyncSkip))
        return;

    // Avoid recomputing wallet balances unless a TransactionChanged or
    // BlockTip notification was received.
    if (!fForceCheckBalanceChanged && m_cached_last_update_tip == getLastBlockProcessed()) return;

    // Try to get balances and return early if locks can't be acquired. This
    // avoids the GUI from getting stuck on periodical polls if the core is
    // holding the locks for a longer time - for example, during a wallet
    // rescan.
    interfaces::WalletBalances new_balances;
    uint256 block_hash;
    if (!m_wallet->tryGetBalances(new_balances, block_hash)) {
        return;
    }
    pollNum = 0;

    bool cachedBlockHashChanged = block_hash != m_cached_last_update_tip;
    if (fForceCheckBalanceChanged || cachedBlockHashChanged) {
        fForceCheckBalanceChanged = false;

        // Balance and number of transactions might have changed
        m_cached_last_update_tip = block_hash;

        // This poll runs on the wallet worker thread, but the balance cache,
        // the balanceChanged listeners, and the transaction table all live on
        // the GUI thread, so apply the results there. The queued call is
        // dropped automatically if this model is destroyed first.
        const bool is_syncing{isSyncing};
        QMetaObject::invokeMethod(this, [this, new_balances, cachedBlockHashChanged, is_syncing] {
            bool balanceChanged = checkBalanceChanged(new_balances);

            if (transactionTableModel)
                transactionTableModel->updateConfirmations();

            // The stake weight is used for the staking icon status
            // Get the stake weight only when not syncing because it is time consuming
            if (!is_syncing && (balanceChanged || cachedBlockHashChanged)) {
                updateStakeWeight = true;
            }
        }, Qt::QueuedConnection);
    }
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

void WalletModel::requestStakingMiningSnapshot(const StakingMiningSnapshotRequest& request)
{
    // Only the GUI thread owns request/coalescing state. The cancellation flag
    // is the sole object shared with WalletWorker and is checked between every
    // wallet walk so teardown and wallet switches never wait in the view.
    cancelStakingMiningSnapshot();
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
            snapshot->start_tip = m_node.getBestBlockHash().GetHex();
            if (!request.expected_tip.empty() && snapshot->start_tip != request.expected_tip) {
                snapshot->stale_tip = true;
                publish();
                return;
            }

            snapshot->pow = m_wallet->getPowMiningInfo();
            if (checkpoint()) { publish(); return; }
            snapshot->migration = m_wallet->getMigrationStatus();
            if (checkpoint()) { publish(); return; }
            snapshot->demurrage = m_wallet->getDemurrageInfo();
            if (checkpoint()) { publish(); return; }
            snapshot->rgb_assets = m_wallet->listRGBAssets(/*include_spent=*/false);
            if (checkpoint()) { publish(); return; }
            snapshot->eutxo_states = m_wallet->listEUTXOStates(/*include_spent=*/true);
            if (checkpoint()) { publish(); return; }
            snapshot->quantum_addresses = m_wallet->listQuantumAddresses();
            if (checkpoint()) { publish(); return; }
            snapshot->coldstake_delegations = m_wallet->listQuantumColdStakeDelegations();
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
                snapshot->selfstake_outputs = m_wallet->listQuantumStakeOutputs(snapshot->selfstake_query_address);
                if (checkpoint()) { publish(); return; }
                snapshot->selfstake_bond = m_wallet->getQuantumStakeAddressBondInfo(snapshot->selfstake_query_address);
                if (checkpoint()) { publish(); return; }
            }
            snapshot->operator_query_address = request.operator_address;
            if (!snapshot->operator_query_address.empty()) {
                snapshot->operator_queried = true;
                snapshot->operator_bond = m_wallet->getQuantumOperatorBondInfo(snapshot->operator_query_address);
                if (checkpoint()) { publish(); return; }
            }

            snapshot->coldstake_balances.reserve(snapshot->coldstake_delegations.size());
            for (const interfaces::WalletQuantumColdStakeInfo& info : snapshot->coldstake_delegations) {
                snapshot->coldstake_balances.push_back({info.address, m_wallet->getQuantumColdStakeBalanceInfo(info.address)});
                if (checkpoint()) { publish(); return; }
            }
            snapshot->selected_coldstake_query_address = request.coldstake_address;
            if (!snapshot->selected_coldstake_query_address.empty()) {
                snapshot->selected_coldstake_queried = true;
                snapshot->selected_coldstake_balance = m_wallet->getQuantumColdStakeBalanceInfo(snapshot->selected_coldstake_query_address);
                if (checkpoint()) { publish(); return; }
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
            snapshot->end_tip = m_node.getBestBlockHash().GetHex();
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

uint64_t WalletModel::requestPowClaimRecoveryPolicy(PowClaimRecoveryPolicyRequest request)
{
    Q_ASSERT(QThread::currentThread() == thread());
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
                result->error = result->mutation.detail;
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
                result->error = result->mutation.detail;
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
    const auto reject_queued = [this, &request](std::string error,
                                                bool cancelled,
                                                bool busy) {
        auto result = std::make_shared<PowClaimRecoveryOperationResult>();
        result->request = request;
        result->cancelled = cancelled;
        result->busy_rejected = busy;
        result->error = std::move(error);
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

        const auto publish = [this, result] {
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
    m_pow_claim_recovery_operation_controls.erase(request_id);

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
    m_pow_claim_recovery_operation_unlocks.erase(request_id);
    const auto restore_it =
        m_pow_claim_recovery_restore_staking_only.find(request_id);
    if (restore_it != m_pow_claim_recovery_restore_staking_only.end()) {
        if (restore_it->second) setWalletUnlockStakingOnly(true);
        m_pow_claim_recovery_restore_staking_only.erase(restore_it);
    }
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
    fForceCheckBalanceChanged = true;
}

void WalletModel::updateAddressBook(const QString &address, const QString &label,
        bool isMine, wallet::AddressPurpose purpose, int status)
{
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

    checkBalanceChanged(m_wallet->getBalances()); // update balance immediately, otherwise there could be a short noticeable delay until pollBalanceChanged hits
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
    bool invoked = QMetaObject::invokeMethod(walletmodel, "updateTransaction", Qt::QueuedConnection);
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

static void NotifyCanGetAddressesChanged(WalletModel* walletmodel)
{
    bool invoked = QMetaObject::invokeMethod(walletmodel, "canGetAddressesChanged");
    assert(invoked);
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

WalletModel::UnlockContext::~UnlockContext()
{
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

void WalletModel::join()
{
    m_joined = true;

    // Stop timer
    if (timer)
        timer->stop();

    cancelStakingMiningSnapshot();
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

    // Quit thread
    if (t.isRunning()) {
        if (worker)
            worker->disconnect(this);
        t.quit();
        t.wait();
        // The finished-to-deleteLater connection destroys the worker in its
        // owning thread before wait() returns. Avoid retaining a dangling
        // pointer when join() is called again during WalletModel destruction.
        worker = nullptr;
    }

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
