// Copyright (c) 2011-2022 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_WALLETMODEL_H
#define BITCOIN_QT_WALLETMODEL_H

#if defined(HAVE_CONFIG_H)
#include <config/bitcoin-config.h>
#endif

#include <key.h>

#include <qt/walletmodeltransaction.h>

#include <interfaces/wallet.h>
#include <support/allocators/secure.h>

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include <QObject>
#include <QThread>

enum class OutputType;

class AddressTableModel;
class ClientModel;
class OptionsModel;
class PlatformStyle;
class RecentRequestsTableModel;
class SendCoinsRecipient;
class TransactionTableModel;
class WalletModelTransaction;
class WalletWorker;

class CKeyID;
class COutPoint;
class CPubKey;
class uint256;

namespace interfaces {
class Node;
} // namespace interfaces
namespace wallet {
class CCoinControl;
} // namespace wallet

QT_BEGIN_NAMESPACE
class QTimer;
QT_END_NAMESPACE

/** Interface to the Blackcoin wallet from Qt view code. */
class WalletModel : public QObject
{
    Q_OBJECT

public:
    explicit WalletModel(std::unique_ptr<interfaces::Wallet> wallet, ClientModel& client_model, const PlatformStyle *platformStyle, QObject *parent = nullptr);
    ~WalletModel();

    enum StatusCode // Returned by sendCoins
    {
        OK,
        InvalidAmount,
        InvalidAddress,
        AmountExceedsBalance,
        AmountWithFeeExceedsBalance,
        DuplicateAddress,
        TransactionCreationFailed, // Error returned when wallet is still locked
        AbsurdFee
    };

    enum EncryptionStatus
    {
        NoKeys,       // wallet->IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS)
        Unencrypted,  // !wallet->IsCrypted()
        Locked,       // wallet->IsCrypted() && wallet->IsLocked()
        Unlocked      // wallet->IsCrypted() && !wallet->IsLocked()
    };

    /**
     * Inputs captured on the GUI thread before building the expensive
     * Staking & Mining detail snapshot on WalletWorker's managed thread.
     */
    struct StakingMiningSnapshotRequest
    {
        uint64_t request_id{0};
        uint64_t generation{0};
        std::string expected_tip;
        std::string selfstake_address;
        std::string operator_address;
        std::string coldstake_address;
    };

    struct StakingMiningColdStakeBalance
    {
        std::string address;
        interfaces::WalletQuantumColdStakeBalanceInfo balance;
    };

    /** Immutable worker result. Views must reject mismatched generations/tips. */
    struct StakingMiningSnapshot
    {
        StakingMiningSnapshotRequest request;
        bool cancelled{false};
        bool stale_tip{false};
        std::string error;
        std::string start_tip;
        std::string end_tip;

        interfaces::WalletPowMiningInfo pow;
        interfaces::WalletMigrationStatus migration;
        interfaces::WalletDemurrageInfo demurrage;
        std::vector<interfaces::WalletRGBAssetInfo> rgb_assets;
        std::vector<interfaces::WalletEUTXOStateInfo> eutxo_states;
        std::vector<interfaces::WalletQuantumAddressInfo> quantum_addresses;
        std::vector<interfaces::WalletQuantumColdStakeInfo> coldstake_delegations;
        std::vector<interfaces::WalletQuantumStakeOutputInfo> selfstake_outputs;
        interfaces::WalletQuantumOperatorBondInfo selfstake_bond;
        interfaces::WalletQuantumOperatorBondInfo operator_bond;
        std::vector<StakingMiningColdStakeBalance> coldstake_balances;
        interfaces::WalletQuantumColdStakeBalanceInfo selected_coldstake_balance;
        interfaces::WalletQuantumPoolInfo pool;
        bool selfstake_queried{false};
        bool operator_queried{false};
        bool selected_coldstake_queried{false};
        std::string selfstake_query_address;
        std::string operator_query_address;
        std::string selected_coldstake_query_address;
    };

    /** One wallet-scoped recovery-policy read or durable update. */
    struct PowClaimRecoveryPolicyRequest
    {
        enum class Operation : uint8_t {
            INFO,
            SET_POLICY,
        };

        uint64_t request_id{0};
        uint64_t generation{0};
        std::string wallet_name;
        Operation operation{Operation::INFO};
        interfaces::WalletPowClaimRecoveryPolicy policy;
    };

    /** Immutable WalletWorker result; views reject old wallet generations. */
    struct PowClaimRecoveryPolicyResult
    {
        PowClaimRecoveryPolicyRequest request;
        bool cancelled{false};
        bool success{false};
        bool policy_available{false};
        bool authoritative_state_checked{false};
        bool mutation_attempted{false};
        std::string error;
        interfaces::WalletPowClaimRecoveryPolicy policy;
        interfaces::WalletPowClaimRecoveryPolicyMutationResult mutation;
    };

    /** One user-initiated claim-component review, execution, or adoption. */
    struct PowClaimRecoveryOperationRequest
    {
        enum class Operation : uint8_t {
            REVIEW,
            EXECUTE,
            ADOPT,
        };

        uint64_t request_id{0};
        uint64_t generation{0};
        std::string wallet_name;
        Operation operation{Operation::REVIEW};
        interfaces::WalletPowClaimRecoveryRequest recovery;
        std::string adoption_selector;
        std::string adoption_tip;
        std::string adoption_component_fingerprint;
        //! View-owned identity token. A wallet switch/dialog close flips it
        //! even if that happens inside the synchronous unlock prompt before
        //! the caller receives this request's id.
        std::shared_ptr<std::atomic<bool>> view_current;
        bool unlock_granted{true};
        bool staking_only_escalation{false};
        bool staking_only_escalation_left_locked{false};
        std::string unlock_error;
    };

    /** Immutable worker result. `cancelled` is set only before Core entry. */
    struct PowClaimRecoveryOperationResult
    {
        PowClaimRecoveryOperationRequest request;
        bool cancelled{false};
        bool core_entered{false};
        bool cancel_requested_after_core{false};
        bool busy_rejected{false};
        bool success{false};
        bool adopted{false};
        std::string error;
        interfaces::WalletPowClaimRecoveryReview review;
        interfaces::WalletPowClaimRecoveryExecution execution;
        interfaces::WalletPowClaimRecoveryAdoptionResult adoption;
    };

    OptionsModel* getOptionsModel() const;
    AddressTableModel* getAddressTableModel() const;
    TransactionTableModel* getTransactionTableModel() const;
    RecentRequestsTableModel* getRecentRequestsTableModel() const;

    EncryptionStatus getEncryptionStatus() const;
    /**
     * Return the last encryption state published to the GUI thread.
     *
     * Unlike getEncryptionStatus(), this never enters cs_wallet. Views that
     * refresh on a timer must use the cached value so a staking/signing pass
     * cannot park the Qt event loop while it owns the wallet mutex.
     */
    EncryptionStatus getCachedEncryptionStatus() const { return cachedEncryptionStatus.load(std::memory_order_acquire); }

    // Check address for validity
    bool validateAddress(const QString& address) const;

    // Return status record for SendCoins, contains error id + information
    struct SendCoinsReturn
    {
        SendCoinsReturn(StatusCode _status = OK, QString _reasonCommitFailed = "")
            : status(_status),
              reasonCommitFailed(_reasonCommitFailed)
        {
        }
        StatusCode status;
        QString reasonCommitFailed;
    };

    // prepare transaction for getting txfee before sending coins
    SendCoinsReturn prepareTransaction(WalletModelTransaction &transaction, const wallet::CCoinControl& coinControl);

    // Send coins to a list of recipients
    void sendCoins(WalletModelTransaction& transaction);

    // Wallet encryption
    bool setWalletEncrypted(const SecureString& passphrase);
    // Passphrase only needed when unlocking
    bool setWalletLocked(bool locked, const SecureString &passPhrase=SecureString(),
                         std::optional<bool> staking_only = std::nullopt);
    bool changePassphrase(const SecureString &oldPass, const SecureString &newPass);
    bool getWalletUnlockStakingOnly();
    void setWalletUnlockStakingOnly(bool unlock);

    // RAII object for unlocking wallet, returned by requestUnlock()
    class UnlockContext
    {
    public:
        UnlockContext(
            WalletModel *wallet, bool valid, bool relock,
            std::optional<bool> restore_staking_only = std::nullopt);
        ~UnlockContext();

        bool isValid() const { return valid; }

        // Disable unused copy/move constructors/assignments explicitly.
        UnlockContext(const UnlockContext&) = delete;
        UnlockContext(UnlockContext&&) = delete;
        UnlockContext& operator=(const UnlockContext&) = delete;
        UnlockContext& operator=(UnlockContext&&) = delete;

    private:
        WalletModel *wallet;
        const bool valid;
        const bool relock;
        const std::optional<bool> restoreStakingOnly;
    };

    UnlockContext requestUnlock();

    bool displayAddress(std::string sAddress) const;

    static bool isWalletEnabled();

    interfaces::Node& node() const { return m_node; }
    interfaces::Wallet& wallet() const { return *m_wallet; }
    ClientModel& clientModel() const { return *m_client_model; }
    void setClientModel(ClientModel* client_model);

    QString getWalletName() const;
    QString getDisplayName() const;

    bool isMultiwallet() const;

    uint64_t getStakeWeight();

    void refresh(bool pk_hash_only = false);

    uint256 getLastBlockProcessed() const;

    // Retrieve the cached wallet balance
    interfaces::WalletBalances getCachedBalance() const;

    /** Queue one full-detail snapshot on the existing wallet worker thread. */
    void requestStakingMiningSnapshot(const StakingMiningSnapshotRequest& request);
    /** Cooperatively cancel the current snapshot without waiting for teardown. */
    void cancelStakingMiningSnapshot(uint64_t request_id = 0);
    /** Take the completed immutable result after stakingMiningSnapshotReady. */
    std::shared_ptr<const StakingMiningSnapshot> takeStakingMiningSnapshot(uint64_t request_id);

    /**
     * Queue a policy request and return its WalletModel-issued correlation id.
     *
     * IDs are unique for this WalletModel. Requests from independent views do
     * not cancel or overwrite one another.
     */
    uint64_t requestPowClaimRecoveryPolicy(PowClaimRecoveryPolicyRequest request);
    /** Cooperatively cancel an obsolete policy request before Core entry. */
    void cancelPowClaimRecoveryPolicy(uint64_t request_id);
    /** Take one completed immutable policy result. */
    std::shared_ptr<const PowClaimRecoveryPolicyResult> takePowClaimRecoveryPolicyResult(uint64_t request_id);

    /** Queue a user-initiated recovery operation on WalletWorker. Mutating
     * operations request a temporary normal wallet unlock only after the
     * view has captured explicit consent. */
    uint64_t requestPowClaimRecoveryOperation(PowClaimRecoveryOperationRequest request);
    /** Cooperatively cancel only while the request has not entered Core. */
    void cancelPowClaimRecoveryOperation(uint64_t request_id);
    /** Take one authoritative operation result. */
    std::shared_ptr<const PowClaimRecoveryOperationResult> takePowClaimRecoveryOperationResult(uint64_t request_id);

    // If coin control has selected outputs, searches the total amount inside the wallet.
    // Otherwise, uses the wallet's cached available balance.
    CAmount getAvailableBalance(const wallet::CCoinControl* control);

    void join();

private:
    std::unique_ptr<interfaces::Wallet> m_wallet;
    std::unique_ptr<interfaces::Handler> m_handler_unload;
    std::unique_ptr<interfaces::Handler> m_handler_status_changed;
    std::unique_ptr<interfaces::Handler> m_handler_address_book_changed;
    std::unique_ptr<interfaces::Handler> m_handler_transaction_changed;
    std::unique_ptr<interfaces::Handler> m_handler_show_progress;
    std::unique_ptr<interfaces::Handler> m_handler_watch_only_changed;
    std::unique_ptr<interfaces::Handler> m_handler_can_get_addrs_changed;
    ClientModel* m_client_model;
    interfaces::Node& m_node;

    bool fHaveWatchOnly;
    //! Set from GUI-thread notification handlers, read and cleared from the
    //! worker-thread balance poll.
    std::atomic<bool> fForceCheckBalanceChanged{false};

    // Wallet has an options model for wallet-specific options
    // (transaction fee, for example)
    OptionsModel *optionsModel;

    AddressTableModel* addressTableModel{nullptr};
    TransactionTableModel* transactionTableModel{nullptr};
    RecentRequestsTableModel* recentRequestsTableModel{nullptr};

    // Cache some values to be able to detect changes
    interfaces::WalletBalances m_cached_balances;
    std::atomic<EncryptionStatus> cachedEncryptionStatus{Unencrypted};
    bool m_status_update_retry_scheduled{false};
    QTimer* timer;

    // Block hash denoting when the last balance update was done.
    uint256 m_cached_last_update_tip{};

    int pollNum = 0;
    std::atomic<uint64_t> nWeight;
    std::atomic<bool> updateStakeWeight;

    QThread t;
    WalletWorker *worker;
    std::shared_ptr<std::atomic<bool>> m_staking_snapshot_cancel;
    uint64_t m_staking_snapshot_request_id{0};
    std::shared_ptr<const StakingMiningSnapshot> m_completed_staking_snapshot;
    uint64_t m_pow_claim_recovery_policy_request_sequence{0};
    std::map<uint64_t, std::shared_ptr<std::atomic<bool>>> m_pow_claim_recovery_policy_cancels;
    std::map<uint64_t, std::shared_ptr<const PowClaimRecoveryPolicyResult>> m_completed_pow_claim_recovery_policy_results;
    enum class PowClaimRecoveryOperationStage : uint8_t {
        QUEUED,
        CANCELLED_BEFORE_CORE,
        CORE_ENTERED,
        FINISHED,
    };
    struct PowClaimRecoveryOperationControl {
        std::atomic<bool> cancel_requested{false};
        std::atomic<PowClaimRecoveryOperationStage> stage{
            PowClaimRecoveryOperationStage::QUEUED};
    };
    uint64_t m_pow_claim_recovery_operation_request_sequence{0};
    std::map<uint64_t, std::shared_ptr<PowClaimRecoveryOperationControl>> m_pow_claim_recovery_operation_controls;
    std::map<uint64_t, std::shared_ptr<const PowClaimRecoveryOperationResult>> m_completed_pow_claim_recovery_operation_results;
    std::map<uint64_t, std::unique_ptr<UnlockContext>> m_pow_claim_recovery_operation_unlocks;
    std::map<uint64_t, bool> m_pow_claim_recovery_restore_staking_only;
    uint64_t m_pow_claim_recovery_mutation_in_flight{0};
    bool m_joined{false};

    void subscribeToCoreSignals();
    void unsubscribeFromCoreSignals();
    bool checkBalanceChanged(const interfaces::WalletBalances& new_balances);
    void dispatchPowClaimRecoveryOperation(
        PowClaimRecoveryOperationRequest request,
        const std::shared_ptr<PowClaimRecoveryOperationControl>& control);
    void restorePowClaimRecoveryUnlock(uint64_t request_id);
    void publishPowClaimRecoveryOperationResult(
        const std::shared_ptr<PowClaimRecoveryOperationResult>& result);

Q_SIGNALS:
    // Signal that balance in wallet changed
    void balanceChanged(const interfaces::WalletBalances& balances);

    // Encryption status of wallet changed
    void encryptionStatusChanged();

    // Staking donation percentage changed
    void qqDevelopmentDonationChanged(unsigned int percentage);

    // Signal emitted when wallet needs to be unlocked
    // It is valid behaviour for listeners to keep the wallet locked after this signal;
    // this means that the unlocking failed or was cancelled.
    void requireUnlock();

    // Fired when a message should be reported to the user
    void message(const QString &title, const QString &message, unsigned int style);

    // Coins sent: from wallet, to recipient, in (serialized) transaction:
    void coinsSent(WalletModel* wallet, SendCoinsRecipient recipient, QByteArray transaction);

    // Show progress dialog e.g. for rescan
    void showProgress(const QString &title, int nProgress);

    // Watch-only address added
    void notifyWatchonlyChanged(bool fHaveWatchonly);

    // Signal that wallet is about to be removed
    void unload();

    // Notify that there are now keys in the keypool
    void canGetAddressesChanged();

    void timerTimeout();

    /** Emitted on the GUI thread after a worker request completes or cancels. */
    void stakingMiningSnapshotReady(quint64 request_id, quint64 generation);
    /** Emitted on the GUI thread after a wallet recovery-policy request. */
    void powClaimRecoveryPolicyReady(quint64 request_id, quint64 generation);
    /** Emitted after a recovery review/execution/adoption operation. */
    void powClaimRecoveryOperationReady(quint64 request_id, quint64 generation);

public Q_SLOTS:
    /* Starts a timer to periodically update the balance */
    void startPollBalance();

    /* Wallet status might have changed */
    void updateStatus();
    /* New transaction, or transaction changed status */
    void updateTransaction();
    /* New, updated or removed address book entry */
    void updateAddressBook(const QString &address, const QString &label, bool isMine, wallet::AddressPurpose purpose, int status);
    /* Watch-only added */
    void updateWatchOnlyFlag(bool fHaveWatchonly);
    /* Current, immature or unconfirmed balance might have changed - emit 'balanceChanged' if so */
    void pollBalanceChanged();
    /* Update stake weight when changed */
    void checkStakeWeightChanged();
};

#endif // BITCOIN_QT_WALLETMODEL_H
