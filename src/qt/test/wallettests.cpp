// Copyright (c) 2015-2022 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/test/wallettests.h>
#include <qt/test/util.h>

#include <addresstype.h>
#include <crypto/mldsa.h>
#include <wallet/coincontrol.h>
#include <interfaces/chain.h>
#include <interfaces/node.h>
#include <interfaces/wallet.h>
#include <key_io.h>
#include <qt/bitcoinunits.h>
#include <qt/bitcoinamountfield.h>
#include <qt/clientmodel.h>
#include <qt/optionsmodel.h>
#include <qt/overviewpage.h>
#include <qt/platformstyle.h>
#include <qt/quantumguides.h>
#include <qt/qvalidatedlineedit.h>
#include <qt/receivecoinsdialog.h>
#include <qt/receiverequestdialog.h>
#include <qt/recentrequeststablemodel.h>
#include <qt/sendcoinsdialog.h>
#include <qt/sendcoinsentry.h>
#include <qt/stakingminingpage.h>
#include <qt/transactiontablemodel.h>
#include <qt/transactionview.h>
#include <qt/utilitydialog.h>
#include <qt/walletview.h>
#include <qt/walletmodel.h>
#include <script/solver.h>
#include <shadow.h>
#include <test/util/setup_common.h>
#include <util/strencodings.h>
#include <util/string.h>
#include <validation.h>
#include <validationinterface.h>
#include <wallet/test/util.h>
#include <wallet/spend.h>
#include <wallet/wallet.h>

#include <clientversion.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <functional>
#include <future>
#include <map>
#include <memory>
#include <optional>
#include <thread>

#include <QAbstractButton>
#include <QAction>
#include <QApplication>
#include <QCheckBox>
#include <QClipboard>
#include <QComboBox>
#include <QLabel>
#include <QLineEdit>
#include <QObject>
#include <QPushButton>
#include <QScrollArea>
#include <QSpinBox>
#include <QTableView>
#include <QTableWidget>
#include <QTest>
#include <QTimer>
#include <QVBoxLayout>
#include <QTextEdit>
#include <QListView>
#include <QDialogButtonBox>
#include <QDialog>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QSignalSpy>

using wallet::AddWallet;
using wallet::CWallet;
using wallet::CreateMockableWalletDatabase;
using wallet::RemoveWallet;
using wallet::WALLET_FLAG_DESCRIPTORS;
using wallet::WALLET_FLAG_DISABLE_PRIVATE_KEYS;
using wallet::WalletContext;
using wallet::WalletDescriptor;
using wallet::WalletRescanReserver;

namespace
{
class QtRecoveryShadowScheduleGuard
{
public:
    QtRecoveryShadowScheduleGuard(int whitelist_height,
                                  int reward_start_height,
                                  int gold_rush_blocks)
        : m_whitelist_height{SHADOW_WHITELIST_HEIGHT},
          m_reward_start_height{SHADOW_REWARD_START_HEIGHT},
          m_gold_rush_blocks{SHADOW_GOLD_RUSH_BLOCKS}
    {
        SetShadowTestSchedule(whitelist_height, reward_start_height,
                              gold_rush_blocks);
    }

    ~QtRecoveryShadowScheduleGuard()
    {
        SetShadowTestSchedule(m_whitelist_height, m_reward_start_height,
                              m_gold_rush_blocks);
    }

private:
    int m_whitelist_height;
    int m_reward_start_height;
    int m_gold_rush_blocks;
};

CTransactionRef MakeQtRecoveryTestClaim(const COutPoint& input,
                                        CAmount value,
                                        const CScript& wallet_script)
{
    std::vector<unsigned char> proof = GetShadowPrefix();
    proof.insert(proof.end(), {'Q', 'Q', 'P', '2', 0});
    proof.insert(proof.end(), 8, 0);
    proof.push_back(static_cast<unsigned char>(wallet_script.size() & 0xff));
    proof.push_back(
        static_cast<unsigned char>((wallet_script.size() >> 8) & 0xff));
    proof.insert(proof.end(), wallet_script.begin(), wallet_script.end());
    const CScript quantum_payout = GetScriptForDestination(WitnessUnknown{
        QUANTUM_MIGRATION_WITNESS_VERSION,
        std::vector<unsigned char>(QUANTUM_MIGRATION_PROGRAM_SIZE, 0x51)});
    proof.push_back(static_cast<unsigned char>(quantum_payout.size() & 0xff));
    proof.push_back(
        static_cast<unsigned char>((quantum_payout.size() >> 8) & 0xff));
    proof.insert(proof.end(), quantum_payout.begin(), quantum_payout.end());

    CMutableTransaction claim;
    claim.vin.emplace_back(input);
    claim.vout.emplace_back(value, wallet_script);
    claim.vout.emplace_back(0, CScript{} << OP_RETURN << proof);
    return MakeTransactionRef(std::move(claim));
}

QString FormatQtRecoveryAmount(CAmount amount)
{
    return QString::number(static_cast<double>(amount) / COIN, 'f', 8) +
        QStringLiteral(" BLK");
}

//! Press "Yes" or "Cancel" buttons in modal send confirmation dialog.
void ConfirmSend(QString* text = nullptr, QMessageBox::StandardButton confirm_type = QMessageBox::Yes)
{
    QTimer::singleShot(0, [text, confirm_type]() {
        for (QWidget* widget : QApplication::topLevelWidgets()) {
            if (widget->inherits("SendConfirmationDialog")) {
                SendConfirmationDialog* dialog = qobject_cast<SendConfirmationDialog*>(widget);
                if (text) *text = dialog->text();
                QAbstractButton* button = dialog->button(confirm_type);
                button->setEnabled(true);
                button->click();
            }
        }
    });
}

void WaitForModal(const QString& description, std::function<bool()> action)
{
    auto* timer = new QTimer(qApp);
    timer->setInterval(10);
    timer->setSingleShot(false);
    QObject::connect(timer, &QTimer::timeout, timer,
                     [timer, description, action = std::move(action), attempts = 0]() mutable {
        if (action()) {
            timer->stop();
            timer->deleteLater();
            return;
        }
        if (++attempts < 1500) return;

        QTest::qFail(
            QStringLiteral("Timed out waiting for %1").arg(description).toUtf8().constData(),
            __FILE__, __LINE__);
        if (auto* dialog = qobject_cast<QDialog*>(QApplication::activeModalWidget())) {
            dialog->reject();
        }
        timer->stop();
        timer->deleteLater();
    });
    timer->start();
}

//! Press a standard button in a modal message box.
void ConfirmMessageBox(QMessageBox::StandardButton confirm_type,
                       const QString& expected_text = {})
{
    WaitForModal(QStringLiteral("message box"), [confirm_type, expected_text]() {
        for (QWidget* widget : QApplication::topLevelWidgets()) {
            if (auto* dialog = qobject_cast<QMessageBox*>(widget)) {
                if (!expected_text.isEmpty() &&
                    !dialog->text().contains(expected_text)) {
                    QTest::qFail(
                        QStringLiteral("Message box omitted required disclosure: %1; actual: %2")
                            .arg(expected_text, dialog->text())
                            .toUtf8().constData(),
                        __FILE__, __LINE__);
                    dialog->reject();
                    return true;
                }
                if (QAbstractButton* button = dialog->button(confirm_type)) {
                    button->click();
                    return true;
                }
            }
        }
        return false;
    });
}

void AnswerPowClaimRecoveryConsent(bool enable, bool use_escape = false,
                                   const QString& expected_wallet = {})
{
    WaitForModal(QStringLiteral("PoW claim recovery consent dialog"), [enable, use_escape, expected_wallet] {
        for (QWidget* widget : QApplication::allWidgets()) {
            auto* dialog = qobject_cast<QDialog*>(widget);
            if (!dialog || dialog->objectName() !=
                    QLatin1String("powClaimRecoveryConsentDialog") ||
                !dialog->isVisible()) continue;
            auto* cancel = dialog->findChild<QPushButton*>(
                QStringLiteral("powClaimRecoveryConsentCancel"));
            auto* authorize = dialog->findChild<QPushButton*>(
                QStringLiteral("powClaimRecoveryConsentEnable"));
            auto* wallet_identity = dialog->findChild<QLabel*>(
                QStringLiteral("powClaimRecoveryConsentWallet"));
            auto* explanation = dialog->findChild<QLabel*>(
                QStringLiteral("powClaimRecoveryConsentExplanation"));
            if (!cancel || !authorize || !cancel->isDefault()) {
                QTest::qFail("PoW recovery consent dialog is missing its safe default controls",
                             __FILE__, __LINE__);
                dialog->reject();
                return true;
            }
            if (!wallet_identity ||
                (!expected_wallet.isEmpty() &&
                 !wallet_identity->text().contains(expected_wallet))) {
                QTest::qFail("PoW recovery consent is not bound to the expected wallet name",
                             __FILE__, __LINE__);
                dialog->reject();
                return true;
            }
            if (!explanation ||
                !explanation->text().contains(
                    QStringLiteral("waits while a member is live")) ||
                !explanation->text().contains(
                    QStringLiteral("same confirmed anchor")) ||
                !explanation->text().contains(
                    QStringLiteral("ordinary claim fee")) ||
                !explanation->text().contains(
                    QStringLiteral("miner could continue")) ||
                !explanation->text().contains(
                    QStringLiteral("may become eligible again at a later height")) ||
                !explanation->text().contains(
                    QStringLiteral("either the original claim or the conflicting recovery may confirm"))) {
                QTest::qFail(
                    "PoW recovery standing-consent warning omits the legacy QQP2 revalidation conflict",
                    __FILE__, __LINE__);
                dialog->reject();
                return true;
            }
            if (use_escape) {
                QTest::keyClick(dialog, Qt::Key_Escape);
            } else {
                QTest::mouseClick(enable ? authorize : cancel, Qt::LeftButton);
                if (enable && dialog->result() != QDialog::Accepted) {
                    const auto* validation = dialog->findChild<QLabel*>(
                        QStringLiteral("powClaimRecoveryConsentValidation"));
                    QTest::qFail(
                        QStringLiteral("PoW recovery consent was not accepted: %1")
                            .arg(validation ? validation->text() : QStringLiteral("unknown reason"))
                            .toUtf8().constData(),
                        __FILE__, __LINE__);
                    dialog->reject();
                }
            }
            return true;
        }
        return false;
    });
}

void UnloadWalletDuringPowClaimRecoveryConsent(
    StakingMiningPage& page, const QString& expected_wallet)
{
    WaitForModal(QStringLiteral("wallet-bound PoW claim recovery consent dialog"),
                 [&page, expected_wallet] {
        for (QWidget* widget : QApplication::allWidgets()) {
            auto* dialog = qobject_cast<QDialog*>(widget);
            if (!dialog || dialog->objectName() !=
                    QLatin1String("powClaimRecoveryConsentDialog") ||
                !dialog->isVisible()) continue;
            auto* wallet_identity = dialog->findChild<QLabel*>(
                QStringLiteral("powClaimRecoveryConsentWallet"));
            if (!wallet_identity ||
                !wallet_identity->text().contains(expected_wallet)) {
                QTest::qFail("PoW recovery consent displayed the wrong wallet identity",
                             __FILE__, __LINE__);
                dialog->reject();
                return true;
            }
            // The page must close this modal and discard its selected policy
            // before changing wallet identity.
            page.setWalletModel(nullptr);
            return true;
        }
        return false;
    });
}

enum class InitialPowClaimRecoveryChoice : uint8_t {
    AUTOMATIC,
    PAUSE_AND_ASK,
    CANCEL,
};

void AnswerInitialPowClaimRecoveryChoice(InitialPowClaimRecoveryChoice choice)
{
    WaitForModal(QStringLiteral("initial PoW claim recovery choice"), [choice] {
        for (QWidget* widget : QApplication::allWidgets()) {
            auto* dialog = qobject_cast<QDialog*>(widget);
            if (!dialog || dialog->objectName() !=
                    QLatin1String("powClaimRecoveryInitialChoiceDialog") ||
                !dialog->isVisible()) continue;
            auto* automatic = dialog->findChild<QPushButton*>(
                QStringLiteral("powClaimRecoveryInitialAutomatic"));
            auto* pause = dialog->findChild<QPushButton*>(
                QStringLiteral("powClaimRecoveryInitialPause"));
            auto* cancel = dialog->findChild<QPushButton*>(
                QStringLiteral("powClaimRecoveryInitialCancel"));
            auto* explanation = dialog->findChild<QLabel*>(
                QStringLiteral("powClaimRecoveryInitialChoiceExplanation"));
            if (!automatic || !pause || !cancel || !cancel->isDefault()) {
                QTest::qFail("Initial PoW recovery choice is missing an option or safe default",
                             __FILE__, __LINE__);
                dialog->reject();
                return true;
            }
            if (!explanation ||
                !explanation->text().contains(
                    QStringLiteral("waits while a member is live")) ||
                !explanation->text().contains(
                    QStringLiteral("same anchor")) ||
                !explanation->text().contains(
                    QStringLiteral("ordinary claim fee")) ||
                !explanation->text().contains(
                    QStringLiteral("optional fee-paying alternative")) ||
                !explanation->text().contains(
                    QStringLiteral("may become eligible again at a later height")) ||
                !explanation->text().contains(
                    QStringLiteral("either the original claim or the conflicting recovery may confirm"))) {
                QTest::qFail(
                    "Initial PoW recovery choice omits the legacy QQP2 revalidation conflict",
                    __FILE__, __LINE__);
                dialog->reject();
                return true;
            }
            switch (choice) {
            case InitialPowClaimRecoveryChoice::AUTOMATIC:
                QTest::mouseClick(automatic, Qt::LeftButton);
                break;
            case InitialPowClaimRecoveryChoice::PAUSE_AND_ASK:
                QTest::mouseClick(pause, Qt::LeftButton);
                break;
            case InitialPowClaimRecoveryChoice::CANCEL:
                QTest::mouseClick(cancel, Qt::LeftButton);
                break;
            }
            return true;
        }
        return false;
    });
}

//! Send coins to address and return txid.
uint256 SendCoins(CWallet& wallet, SendCoinsDialog& sendCoinsDialog, const CTxDestination& address, CAmount amount,
                  QMessageBox::StandardButton confirm_type = QMessageBox::Yes)
{
    QVBoxLayout* entries = sendCoinsDialog.findChild<QVBoxLayout*>("entries");
    SendCoinsEntry* entry = qobject_cast<SendCoinsEntry*>(entries->itemAt(0)->widget());
    entry->findChild<QValidatedLineEdit*>("payTo")->setText(QString::fromStdString(EncodeDestination(address)));
    entry->findChild<BitcoinAmountField*>("payAmount")->setValue(amount);
    uint256 txid;
    boost::signals2::scoped_connection c(wallet.NotifyTransactionChanged.connect([&txid](const uint256& hash, ChangeType status) {
        if (status == CT_NEW) txid = hash;
    }));
    ConfirmSend(/*text=*/nullptr, confirm_type);
    bool invoked = QMetaObject::invokeMethod(&sendCoinsDialog, "sendButtonClicked", Q_ARG(bool, false));
    assert(invoked);
    return txid;
}

//! Find index of txid in transaction list.
QModelIndex FindTx(const QAbstractItemModel& model, const uint256& txid)
{
    QString hash = QString::fromStdString(txid.ToString());
    int rows = model.rowCount({});
    for (int row = 0; row < rows; ++row) {
        QModelIndex index = model.index(row, 0, {});
        if (model.data(index, TransactionTableModel::TxHashRole) == hash) {
            return index;
        }
    }
    return {};
}

/*
// Blackcoin
//! Invoke bumpfee on txid and check results.
void BumpFee(TransactionView& view, const uint256& txid, bool expectDisabled, std::string expectError, bool cancel)
{
    QTableView* table = view.findChild<QTableView*>("transactionView");
    QModelIndex index = FindTx(*table->selectionModel()->model(), txid);
    QVERIFY2(index.isValid(), "Could not find BumpFee txid");

    // Select row in table, invoke context menu, and make sure bumpfee action is
    // enabled or disabled as expected.
    QAction* action = view.findChild<QAction*>("bumpFeeAction");
    table->selectionModel()->select(index, QItemSelectionModel::ClearAndSelect | QItemSelectionModel::Rows);
    action->setEnabled(expectDisabled);
    table->customContextMenuRequested({});
    QCOMPARE(action->isEnabled(), !expectDisabled);

    action->setEnabled(true);
    QString text;
    if (expectError.empty()) {
        ConfirmSend(&text, cancel ? QMessageBox::Cancel : QMessageBox::Yes);
    } else {
        ConfirmMessage(&text, 0ms);
    }
    action->trigger();
    QVERIFY(text.indexOf(QString::fromStdString(expectError)) != -1);
}
*/

void CompareBalance(WalletModel& walletModel, CAmount expected_balance, QLabel* balance_label_to_check)
{
    BitcoinUnit unit = walletModel.getOptionsModel()->getDisplayUnit();
    QString balanceComparison = BitcoinUnits::formatWithUnit(unit, expected_balance, false, BitcoinUnits::SeparatorStyle::ALWAYS);
    QTRY_COMPARE_WITH_TIMEOUT(balance_label_to_check->text().trimmed(), balanceComparison, 5000);
}

// Verify the 'useAvailableBalance' functionality. With and without manually selected coins.
// Case 1: No coin control selected coins.
// 'useAvailableBalance' should fill the amount edit box with the total available balance
// Case 2: With coin control selected coins.
// 'useAvailableBalance' should fill the amount edit box with the sum of the selected coins values.
void VerifyUseAvailableBalance(SendCoinsDialog& sendCoinsDialog, const WalletModel& walletModel)
{
    // Verify first entry amount and "useAvailableBalance" button
    QVBoxLayout* entries = sendCoinsDialog.findChild<QVBoxLayout*>("entries");
    QVERIFY(entries->count() == 1); // only one entry
    SendCoinsEntry* send_entry = qobject_cast<SendCoinsEntry*>(entries->itemAt(0)->widget());
    QVERIFY(send_entry->getValue().amount == 0);
    // Now click "useAvailableBalance", check updated balance (the entire wallet balance should be set)
    Q_EMIT send_entry->useAvailableBalance(send_entry);
    QVERIFY(send_entry->getValue().amount == walletModel.getCachedBalance().balance);

    // Now manually select two coins and click on "useAvailableBalance". Then check updated balance
    // (only the sum of the selected coins should be set).
    int COINS_TO_SELECT = 2;
    auto coins = walletModel.wallet().listCoins();
    CAmount sum_selected_coins = 0;
    int selected = 0;
    QVERIFY(coins.size() == 1); // context check, coins received only on one destination
    for (const auto& [outpoint, tx_out] : coins.begin()->second) {
        sendCoinsDialog.getCoinControl()->Select(outpoint);
        sum_selected_coins += tx_out.txout.nValue;
        if (++selected == COINS_TO_SELECT) break;
    }
    QVERIFY(selected == COINS_TO_SELECT);

    // Now that we have 2 coins selected, "useAvailableBalance" should update the balance label only with
    // the sum of them.
    Q_EMIT send_entry->useAvailableBalance(send_entry);
    QVERIFY(send_entry->getValue().amount == sum_selected_coins);
}

void SyncUpWallet(const std::shared_ptr<CWallet>& wallet, interfaces::Node& node)
{
    WalletRescanReserver reserver(*wallet);
    reserver.reserve();
    CWallet::ScanResult result = wallet->ScanForWalletTransactions(Params().GetConsensus().hashGenesisBlock, /*start_height=*/0, /*max_height=*/{}, reserver, /*fUpdate=*/true, /*save_progress=*/false);
    QCOMPARE(result.status, CWallet::ScanResult::SUCCESS);
    QCOMPARE(result.last_scanned_block, WITH_LOCK(node.context()->chainman->GetMutex(), return node.context()->chainman->ActiveChain().Tip()->GetBlockHash()));
    QVERIFY(result.last_failed_block.IsNull());
}

void SyncRecoveryReviewWalletTip(const std::shared_ptr<CWallet>& wallet,
                                 interfaces::Node& node)
{
    // Standalone mock wallets are not registered for validation callbacks.
    // Pin them to the fixture tip before requesting a coherent review.
    LOCK2(::cs_main, wallet->cs_wallet);
    const CBlockIndex* tip =
        Assert(node.context()->chainman)->ActiveChain().Tip();
    QVERIFY(tip);
    wallet->SetLastBlockProcessed(tip->nHeight, tip->GetBlockHash());
}

std::shared_ptr<CWallet> SetupLegacyWatchOnlyWallet(interfaces::Node& node, TestChain100Setup& test)
{
    std::shared_ptr<CWallet> wallet = std::make_shared<CWallet>(node.context()->chain.get(), "", CreateMockableWalletDatabase());
    wallet->LoadWallet();
    const uint256 tip_hash = WITH_LOCK(node.context()->chainman->GetMutex(), return node.context()->chainman->ActiveChain().Tip()->GetBlockHash());
    {
        LOCK(wallet->cs_wallet);
        wallet->SetWalletFlag(WALLET_FLAG_DISABLE_PRIVATE_KEYS);
        wallet->SetupLegacyScriptPubKeyMan();
        // Add watched key
        CPubKey pubKey = test.coinbaseKey.GetPubKey();
        bool import_keys = wallet->ImportPubKeys({pubKey.GetID()}, {{pubKey.GetID(), pubKey}} , /*key_origins=*/{}, /*add_keypool=*/false, /*internal=*/false, /*timestamp=*/1);
        assert(import_keys);
        wallet->SetLastBlockProcessed(105, tip_hash);
    }
    SyncUpWallet(wallet, node);
    return wallet;
}

std::shared_ptr<CWallet> SetupDescriptorsWallet(interfaces::Node& node, TestChain100Setup& test)
{
    std::shared_ptr<CWallet> wallet = std::make_shared<CWallet>(node.context()->chain.get(), "", CreateMockableWalletDatabase());
    wallet->LoadWallet();
    const uint256 tip_hash = WITH_LOCK(node.context()->chainman->GetMutex(), return node.context()->chainman->ActiveChain().Tip()->GetBlockHash());
    {
        LOCK(wallet->cs_wallet);
        wallet->SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
        wallet->SetupDescriptorScriptPubKeyMans();

        // Add the coinbase key
        FlatSigningProvider provider;
        std::string error;
        std::unique_ptr<Descriptor> desc = Parse("combo(" + EncodeSecret(test.coinbaseKey) + ")", provider, error, /* require_checksum=*/ false);
        assert(desc);
        WalletDescriptor w_desc(std::move(desc), 0, 0, 1, 1);
        if (!wallet->AddWalletDescriptor(w_desc, provider, "", false)) assert(false);
        CTxDestination dest = GetDestinationForKey(test.coinbaseKey.GetPubKey(), wallet->m_default_address_type);
        wallet->SetAddressBook(dest, "", wallet::AddressPurpose::RECEIVE);
        wallet->SetLastBlockProcessed(105, tip_hash);
    }
    SyncUpWallet(wallet, node);
    wallet->SetBroadcastTransactions(true);
    return wallet;
}

struct MiniGUI {
public:
    SendCoinsDialog sendCoinsDialog;
    TransactionView transactionView;
    OptionsModel optionsModel;
    std::unique_ptr<ClientModel> clientModel;
    std::unique_ptr<WalletModel> walletModel;

    MiniGUI(interfaces::Node& node, const PlatformStyle* platformStyle) : sendCoinsDialog(platformStyle), transactionView(platformStyle), optionsModel(node) {
        bilingual_str error;
        QVERIFY(optionsModel.Init(error));
        clientModel = std::make_unique<ClientModel>(node, &optionsModel);
    }

    void initModelForWallet(interfaces::Node& node, const std::shared_ptr<CWallet>& wallet, const PlatformStyle* platformStyle)
    {
        WalletContext& context = *node.walletLoader().context();
        AddWallet(context, wallet);
        walletModel = std::make_unique<WalletModel>(interfaces::MakeWallet(context, wallet), *clientModel, platformStyle);
        RemoveWallet(context, wallet, /* load_on_start= */ std::nullopt);
        sendCoinsDialog.setModel(walletModel.get());
        transactionView.setModel(walletModel.get());
    }
};

void TestStakingMiningPageControls(MiniGUI& mini_gui, const std::shared_ptr<CWallet>& core_wallet, const PlatformStyle* platformStyle)
{
    WalletModel& walletModel = *mini_gui.walletModel;
    struct PowMiningCleanup {
        WalletModel& wallet_model;
        std::shared_ptr<CWallet> wallet;
        std::vector<COutPoint> locked_coins;
        ~PowMiningCleanup()
        {
            std::string ignored_error;
            wallet_model.wallet().setPowMining(false, 1, 10, ignored_error);
            LOCK(wallet->cs_wallet);
            for (const COutPoint& outpoint : locked_coins) wallet->UnlockCoin(outpoint);
        }
    } cleanup{walletModel, core_wallet};

    std::string error;
    QVERIFY(walletModel.wallet().setPowMining(false, 1, 10, error));
    interfaces::WalletPowClaimRecoveryPolicy unset_recovery_policy;
    QVERIFY(walletModel.wallet().setPowClaimRecoveryPolicy(unset_recovery_policy, error));
    core_wallet->StopStake();
    const auto staking_thread_count = [&] {
        LOCK(core_wallet->m_staking_thread_mutex);
        return core_wallet->threadStakeMinerGroup
            ? core_wallet->threadStakeMinerGroup->size()
            : size_t{0};
    };
    QCOMPARE(staking_thread_count(), size_t{0});

    walletModel.wallet().setEnabledStaking(true);
    QTRY_COMPARE_WITH_TIMEOUT(staking_thread_count(), size_t{1}, 5000);
    QVERIFY(walletModel.wallet().getEnabledStaking());

    walletModel.wallet().setEnabledStaking(false);
    QVERIFY(!walletModel.wallet().getEnabledStaking());
    QCOMPARE(staking_thread_count(), size_t{1});

    walletModel.wallet().setEnabledStaking(true);
    QVERIFY(walletModel.wallet().getEnabledStaking());
    QCOMPARE(staking_thread_count(), size_t{1});
    walletModel.wallet().setEnabledStaking(false);
    std::string donation_error;
    QVERIFY(walletModel.wallet().setQQDevelopmentDonation(
        0, walletModel.wallet().getQQDevelopmentDonationAddress(), donation_error));

    OverviewPage overview_page(platformStyle);
    overview_page.setClientModel(mini_gui.clientModel.get());
    overview_page.setWalletModel(&walletModel);
    QLabel* overview_donations = overview_page.findChild<QLabel*>("labelDonations");
    QVERIFY(overview_donations);

    StakingMiningPage page(platformStyle);
    page.setClientModel(mini_gui.clientModel.get());
    page.setWalletModel(&walletModel);
    page.show();
    qApp->processEvents();

    QCheckBox* staking_enable = page.findChild<QCheckBox*>("stakingEnable");
    QCheckBox* unlock_staking_only = page.findChild<QCheckBox*>("unlockStakingOnly");
    QLabel* staking_status = page.findChild<QLabel*>("stakingStatus");
    QCheckBox* pow_enable = page.findChild<QCheckBox*>("powEnable");
    QCheckBox* pow_unlock_wallet = page.findChild<QCheckBox*>("powUnlockWallet");
    QCheckBox* donation_enable = page.findChild<QCheckBox*>("qqDevelopmentDonationEnable");
    QSpinBox* donation_percent = page.findChild<QSpinBox*>("qqDevelopmentDonationPercent");
    QLabel* donation_status = page.findChild<QLabel*>("qqDevelopmentDonationStatus");
    QSpinBox* pow_cores = page.findChild<QSpinBox*>("powCores");
    QSpinBox* pow_percent = page.findChild<QSpinBox*>("powPercent");
    QLineEdit* pow_payout = page.findChild<QLineEdit*>("powPayout");
    QPushButton* pow_copy = page.findChild<QPushButton*>("powCopy");
    QLabel* pow_status = page.findChild<QLabel*>("powStatus");
    QLabel* pow_warning = page.findChild<QLabel*>("powWarning");
    QLabel* pow_dashboard = page.findChild<QLabel*>("stakingMiningDashboardPow");
    QCheckBox* automation_autostart_staking = page.findChild<QCheckBox*>("automationAutostartStaking");
    QCheckBox* automation_autostart_pow = page.findChild<QCheckBox*>("automationAutostartPow");
    QCheckBox* automation_qqsignal = page.findChild<QCheckBox*>("automationQqSignal");
    QCheckBox* automation_demurrage = page.findChild<QCheckBox*>("automationDemurrageAttest");
    QCheckBox* automation_redelegate = page.findChild<QCheckBox*>("automationRedelegate");
    QCheckBox* automation_new_keys = page.findChild<QCheckBox*>("automationAllowNewKeys");
    QLabel* automation_status = page.findChild<QLabel*>("automationStatus");
    QPushButton* refresh_details = page.findChild<QPushButton*>("stakingMiningRefresh");
    QLabel* refresh_hint = page.findChild<QLabel*>("stakingMiningRefreshHint");
    QLabel* migration_phase = page.findChild<QLabel*>("migrationPhase");
    QLabel* migration_deadline = page.findChild<QLabel*>("migrationDeadline");
    QLabel* migration_legacy_amount = page.findChild<QLabel*>("migrationLegacyAmount");
    QLabel* migration_quantum_amount = page.findChild<QLabel*>("migrationQuantumAmount");
    QLabel* migration_goldrush_amount = page.findChild<QLabel*>("migrationGoldrushAmount");
    QLabel* migration_advice = page.findChild<QLabel*>("migrationAdvice");
    QLabel* quantum_address_count = page.findChild<QLabel*>("quantumAddressCount");
    QLabel* quantum_coldstake_count = page.findChild<QLabel*>("quantumColdstakeCount");
    QLineEdit* quantum_address = page.findChild<QLineEdit*>("quantumAddress");
    QLineEdit* quantum_pubkey = page.findChild<QLineEdit*>("quantumPubkey");
    QPushButton* quantum_new = page.findChild<QPushButton*>("newQuantumAddress");
    QPushButton* quantum_copy = page.findChild<QPushButton*>("quantumCopy");
    QPushButton* quantum_pubkey_copy = page.findChild<QPushButton*>("quantumPubkeyCopy");
    QPushButton* migration_legacy_sweep = page.findChild<QPushButton*>("migrationLegacySweep");
    QPushButton* migration_goldrush_sweep = page.findChild<QPushButton*>("migrationGoldrushSweep");
    QComboBox* selfstake_lock_period = page.findChild<QComboBox*>("selfStakeLockPeriod");
    QComboBox* selfstake_selector = page.findChild<QComboBox*>("selfStakeAddressSelector");
    QLineEdit* selfstake_address = page.findChild<QLineEdit*>("selfStakeAddress");
    QPushButton* selfstake_new = page.findChild<QPushButton*>("newSelfStakeAddress");
    QPushButton* selfstake_copy = page.findChild<QPushButton*>("selfStakeCopy");
    QComboBox* selfstake_output_selector = page.findChild<QComboBox*>("selfStakeOutputSelector");
    BitcoinAmountField* selfstake_fund_amount = page.findChild<BitcoinAmountField*>("selfStakeFundAmount");
    QPushButton* selfstake_fund = page.findChild<QPushButton*>("selfStakeFund");
    QPushButton* selfstake_withdraw = page.findChild<QPushButton*>("selfStakeWithdraw");
    QLabel* selfstake_status = page.findChild<QLabel*>("selfStakeStatus");
    QLineEdit* coldstake_operator_address = page.findChild<QLineEdit*>("coldstakeOperatorAddress");
    QComboBox* coldstake_operator_address_selector = page.findChild<QComboBox*>("coldstakeOperatorAddressSelector");
    QLineEdit* coldstake_operator_pubkey = page.findChild<QLineEdit*>("coldstakeOperatorPubkey");
    QPushButton* coldstake_operator_new = page.findChild<QPushButton*>("newColdstakeOperatorKey");
    QPushButton* coldstake_operator_copy = page.findChild<QPushButton*>("coldstakeOperatorCopy");
    QPushButton* coldstake_operator_use = page.findChild<QPushButton*>("coldstakeOperatorUseForDelegation");
    BitcoinAmountField* coldstake_operator_bond_amount = page.findChild<BitcoinAmountField*>("coldstakeOperatorBondAmount");
    QPushButton* coldstake_operator_fund = page.findChild<QPushButton*>("coldstakeOperatorFund");
    QPushButton* coldstake_operator_withdraw = page.findChild<QPushButton*>("coldstakeOperatorWithdraw");
    QLabel* coldstake_operator_status = page.findChild<QLabel*>("coldstakeOperatorStatus");
    QTableWidget* coldstake_operator_registry = page.findChild<QTableWidget*>("coldstakeOperatorRegistry");
    QPushButton* coldstake_operator_refresh = page.findChild<QPushButton*>("coldstakeOperatorRefresh");
    QPushButton* coldstake_operator_select = page.findChild<QPushButton*>("coldstakeOperatorSelect");
    QLabel* coldstake_operator_registry_status = page.findChild<QLabel*>("coldstakeOperatorRegistryStatus");
    QLabel* coldstake_quantum_available = page.findChild<QLabel*>("coldstakeQuantumAvailable");
    QComboBox* coldstake_lock_period = page.findChild<QComboBox*>("coldstakeLockPeriod");
    QComboBox* coldstake_operator_selector = page.findChild<QComboBox*>("coldstakeOperatorSelector");
    QComboBox* coldstake_delegation_selector = page.findChild<QComboBox*>("coldstakeDelegationSelector");
    QLineEdit* coldstake_address = page.findChild<QLineEdit*>("coldstakeAddress");
    QPushButton* coldstake_new = page.findChild<QPushButton*>("newColdstakeAddress");
    QPushButton* coldstake_copy = page.findChild<QPushButton*>("coldstakeCopy");
    BitcoinAmountField* coldstake_fund_amount = page.findChild<BitcoinAmountField*>("coldstakeFundAmount");
    QPushButton* coldstake_fund = page.findChild<QPushButton*>("coldstakeFund");
    QPushButton* coldstake_withdraw = page.findChild<QPushButton*>("coldstakeWithdraw");
    QLabel* coldstake_status = page.findChild<QLabel*>("coldstakeStatus");

    QVERIFY(staking_enable);
    QVERIFY(unlock_staking_only);
    QVERIFY(staking_status);
    QVERIFY(pow_enable);
    QVERIFY(pow_unlock_wallet);
    QVERIFY(donation_enable);
    QVERIFY(donation_percent);
    QVERIFY(donation_status);
    QVERIFY(pow_cores);
    QVERIFY(pow_percent);
    QVERIFY(pow_payout);
    QVERIFY(pow_copy);
    QVERIFY(pow_status);
    QVERIFY(pow_warning);
    QVERIFY(pow_dashboard);
    QVERIFY(automation_autostart_staking);
    QVERIFY(automation_autostart_pow);
    QVERIFY(automation_qqsignal);
    QVERIFY(automation_demurrage);
    QVERIFY(automation_redelegate);
    QVERIFY(automation_new_keys);
    QVERIFY(automation_status);
    QVERIFY(automation_status->text().contains("optional automation", Qt::CaseInsensitive));
    QVERIFY(!automation_autostart_staking->isChecked());
    QVERIFY(!automation_autostart_pow->isChecked());
    QVERIFY(!automation_qqsignal->isChecked());
    QVERIFY(!automation_demurrage->isChecked());
    QVERIFY(!automation_redelegate->isChecked());
    QVERIFY(!automation_new_keys->isChecked());

    QVERIFY(refresh_details);
    QVERIFY(refresh_hint);
    QVERIFY(migration_phase);
    QVERIFY(migration_deadline);
    QVERIFY(migration_legacy_amount);
    QVERIFY(migration_quantum_amount);
    QVERIFY(migration_goldrush_amount);
    QVERIFY(migration_advice);
    QVERIFY(quantum_address_count);
    QVERIFY(quantum_coldstake_count);
    QVERIFY(quantum_address);
    QVERIFY(quantum_pubkey);
    QVERIFY(quantum_new);
    QVERIFY(quantum_copy);
    QVERIFY(quantum_pubkey_copy);
    QVERIFY(migration_legacy_sweep);
    QVERIFY(migration_goldrush_sweep);
    QVERIFY(selfstake_lock_period);
    QVERIFY(selfstake_selector);
    QVERIFY(selfstake_address);
    QVERIFY(selfstake_new);
    QVERIFY(selfstake_copy);
    QVERIFY(selfstake_output_selector);
    QVERIFY(selfstake_fund_amount);
    QVERIFY(selfstake_fund);
    QVERIFY(selfstake_withdraw);
    QVERIFY(selfstake_status);
    QVERIFY(coldstake_operator_address);
    QVERIFY(coldstake_operator_address_selector);
    QVERIFY(coldstake_operator_pubkey);
    QVERIFY(coldstake_operator_new);
    QVERIFY(coldstake_operator_copy);
    QVERIFY(coldstake_operator_use);
    QVERIFY(coldstake_operator_bond_amount);
    QVERIFY(coldstake_operator_fund);
    QVERIFY(coldstake_operator_withdraw);
    QVERIFY(coldstake_operator_status);
    QVERIFY(coldstake_operator_registry);
    QVERIFY(coldstake_operator_refresh);
    QVERIFY(coldstake_operator_select);
    QVERIFY(coldstake_operator_registry_status);
    QVERIFY(coldstake_quantum_available);
    QVERIFY(coldstake_lock_period);
    QVERIFY(coldstake_operator_selector);
    QVERIFY(coldstake_delegation_selector);
    QVERIFY(coldstake_address);
    QVERIFY(coldstake_new);
    QVERIFY(coldstake_copy);
    QVERIFY(coldstake_fund_amount);
    QVERIFY(coldstake_fund);
    QVERIFY(coldstake_withdraw);
    QVERIFY(coldstake_status);

    refresh_details->click();
    QTRY_VERIFY_WITH_TIMEOUT(refresh_hint->text().contains(QString("Detail panels updated")), 10000);

    // The completed detail snapshot has released the page's update guard.
    // Persistent PoW consent must describe retained locked-wallet intent,
    // rather than the superseded claim that a locked startup discards it.
    QTRY_VERIFY_WITH_TIMEOUT(automation_autostart_pow->isEnabled(), 5000);
    ConfirmMessageBox(
        QMessageBox::No,
        QStringLiteral("keeps the configured worker enabled at zero hashrate and waits for a normal unlock"));
    automation_autostart_pow->click();
    QTRY_VERIFY_WITH_TIMEOUT(!automation_autostart_pow->isChecked(), 3000);

    QCOMPARE(staking_enable->isChecked(), false);
    QCOMPARE(unlock_staking_only->isChecked(), false);
    QVERIFY(!unlock_staking_only->isEnabled());
    QCOMPARE(pow_unlock_wallet->isChecked(), false);
    QVERIFY(!pow_unlock_wallet->isEnabled());
    QCOMPARE(staking_status->text(), QString("Staking is off"));
    QCOMPARE(donation_enable->isChecked(), false);
    QCOMPARE(walletModel.wallet().getQQDevelopmentDonationPercentage(), 0U);
    QVERIFY(donation_status->text().contains(QString("off")));
    QVERIFY(overview_donations->text().contains(QString("0%")));
    QVERIFY(!migration_phase->text().isEmpty());
    QVERIFY(!migration_deadline->text().isEmpty());
    QVERIFY(migration_legacy_amount->text().contains(QString("BLK")));
    QVERIFY(migration_quantum_amount->text().contains(QString("BLK")));
    QVERIFY(migration_goldrush_amount->text().contains(QString("BLK")));
    QVERIFY(!migration_advice->text().isEmpty());
    QCOMPARE(quantum_address_count->text(), QString("0"));
    QCOMPARE(quantum_coldstake_count->text(), QString("0"));
    QVERIFY(coldstake_quantum_available->text().contains(QString("BLK")));
    QVERIFY(!quantum_copy->isEnabled());
    QVERIFY(!quantum_pubkey_copy->isEnabled());
    // The default regtest schedule remains in Gold Rush. Key/address creation
    // is available, but every action that would fund a quantum output must
    // stay disabled until Migration opens.
    QVERIFY(!migration_legacy_sweep->isEnabled());
    QVERIFY(!migration_goldrush_sweep->isEnabled());
    QVERIFY(selfstake_new->isEnabled());
    QVERIFY(!selfstake_selector->isEnabled());
    QVERIFY(!selfstake_copy->isEnabled());
    QVERIFY(!selfstake_output_selector->isEnabled());
    QVERIFY(!selfstake_fund_amount->isEnabled());
    QVERIFY(!selfstake_fund->isEnabled());
    QVERIFY(!selfstake_withdraw->isEnabled());
    QVERIFY(coldstake_operator_new->isEnabled());
    QVERIFY(!coldstake_operator_address_selector->isEnabled());
    QVERIFY(!coldstake_operator_copy->isEnabled());
    QVERIFY(!coldstake_operator_use->isEnabled());
    QVERIFY(!coldstake_operator_bond_amount->isEnabled());
    QVERIFY(!coldstake_operator_fund->isEnabled());
    QVERIFY(!coldstake_operator_withdraw->isEnabled());
    QVERIFY(coldstake_operator_refresh->isEnabled());
    QVERIFY(!coldstake_operator_select->isEnabled());
    QCOMPARE(coldstake_operator_registry->rowCount(), 0);
    QVERIFY(!coldstake_operator_selector->currentData().toString().size());
    QVERIFY(!coldstake_delegation_selector->isEnabled());
    QVERIFY(!coldstake_new->isEnabled());
    QVERIFY(!coldstake_copy->isEnabled());
    QVERIFY(!coldstake_fund_amount->isEnabled());
    QVERIFY(!coldstake_fund->isEnabled());
    QVERIFY(!coldstake_withdraw->isEnabled());

    ConfirmMessageBox(QMessageBox::No);
    quantum_new->click();
    qApp->processEvents();
    QCOMPARE(quantum_address_count->text(), QString("0"));

    ConfirmMessageBox(QMessageBox::Yes);
    quantum_new->click();
    QTRY_COMPARE_WITH_TIMEOUT(quantum_address_count->text(), QString("1"), 10000);
    const CTxDestination gui_quantum_dest = DecodeDestination(quantum_address->text().toStdString());
    QVERIFY(IsValidDestination(gui_quantum_dest));
    QVERIFY(IsQuantumMigrationDestination(gui_quantum_dest));
    QVERIFY(IsHex(quantum_pubkey->text().toStdString()));
    QCOMPARE(quantum_pubkey->text().size(), int{ML_DSA::PUBLICKEY_BYTES * 2});
    QCOMPARE(quantum_address_count->text(), QString("1"));
    QVERIFY(quantum_copy->isEnabled());
    QVERIFY(quantum_pubkey_copy->isEnabled());

    quantum_copy->click();
    QCOMPARE(QApplication::clipboard()->text(), quantum_address->text());
    quantum_pubkey_copy->click();
    QCOMPARE(QApplication::clipboard()->text(), quantum_pubkey->text());

    selfstake_lock_period->setCurrentIndex(5);
    ConfirmMessageBox(QMessageBox::Yes);
    selfstake_new->click();
    QTRY_VERIFY_WITH_TIMEOUT(selfstake_selector->findData(selfstake_address->text()) >= 0, 10000);
    const CTxDestination gui_selfstake_dest = DecodeDestination(selfstake_address->text().toStdString());
    QVERIFY(IsValidDestination(gui_selfstake_dest));
    QVERIFY(IsQuantumMigrationDestination(gui_selfstake_dest));
    QVERIFY(selfstake_copy->isEnabled());
    QVERIFY(selfstake_selector->isEnabled());
    QVERIFY(selfstake_selector->findData(selfstake_address->text()) >= 0);
    QVERIFY(!selfstake_output_selector->isEnabled());
    QVERIFY(!selfstake_fund_amount->isEnabled());
    QVERIFY(!selfstake_fund->isEnabled());
    QVERIFY(!selfstake_withdraw->isEnabled());
    QVERIFY(selfstake_status->text().contains(QString("9450")));

    selfstake_copy->click();
    QCOMPARE(QApplication::clipboard()->text(), selfstake_address->text());

    ConfirmMessageBox(QMessageBox::Yes);
    coldstake_operator_new->click();
    QTRY_VERIFY_WITH_TIMEOUT(coldstake_operator_address_selector->findData(coldstake_operator_address->text()) >= 0, 10000);
    const CTxDestination gui_operator_dest = DecodeDestination(coldstake_operator_address->text().toStdString());
    QVERIFY(IsValidDestination(gui_operator_dest));
    QVERIFY(IsQuantumMigrationDestination(gui_operator_dest));
    QVERIFY(IsHex(coldstake_operator_pubkey->text().toStdString()));
    QCOMPARE(coldstake_operator_pubkey->text().size(), int{ML_DSA::PUBLICKEY_BYTES * 2});
    QVERIFY(coldstake_operator_address_selector->isEnabled());
    QVERIFY(coldstake_operator_address_selector->findData(coldstake_operator_address->text()) >= 0);
    QVERIFY(!coldstake_operator_address_selector->currentText().contains(QString("40500")));
    QVERIFY(coldstake_operator_copy->isEnabled());
    QVERIFY(coldstake_operator_use->isEnabled());
    QVERIFY(!coldstake_operator_bond_amount->isEnabled());
    QVERIFY(!coldstake_operator_fund->isEnabled());
    QVERIFY(coldstake_operator_status->text().contains(QString("30-day")));

    coldstake_operator_copy->click();
    QCOMPARE(QApplication::clipboard()->text(), coldstake_operator_pubkey->text());
    coldstake_operator_use->click();
    QCOMPARE(coldstake_operator_selector->currentData().toString(), coldstake_operator_pubkey->text());
    QVERIFY(coldstake_operator_selector->currentText().contains(QString("operator")));

    coldstake_lock_period->setCurrentIndex(5);
    QVERIFY(coldstake_new->isEnabled());
    ConfirmMessageBox(QMessageBox::Yes);
    coldstake_new->click();
    QTRY_COMPARE_WITH_TIMEOUT(quantum_coldstake_count->text(), QString("1"), 10000);

    const CTxDestination gui_coldstake_dest = DecodeDestination(coldstake_address->text().toStdString());
    QVERIFY(IsValidDestination(gui_coldstake_dest));
    QVERIFY(IsQuantumColdStakeDestination(gui_coldstake_dest));
    QCOMPARE(quantum_coldstake_count->text(), QString("1"));
    QVERIFY(quantum_address_count->text().toInt() >= 2);
    QVERIFY(coldstake_delegation_selector->isEnabled());
    QVERIFY(coldstake_delegation_selector->findData(coldstake_address->text()) >= 0);
    QVERIFY(coldstake_copy->isEnabled());
    QVERIFY(!coldstake_fund_amount->isEnabled());
    QVERIFY(!coldstake_fund->isEnabled());
    QVERIFY(!coldstake_withdraw->isEnabled());
    QVERIFY(coldstake_status->text().contains(QString("Cold-stake address created")));

    coldstake_copy->click();
    QCOMPARE(QApplication::clipboard()->text(), coldstake_address->text());

    staking_enable->click();
    QVERIFY(walletModel.wallet().getEnabledStaking());
    QVERIFY(staking_status->text().startsWith(QString("Staking: syncing")));

    staking_enable->click();
    QVERIFY(!walletModel.wallet().getEnabledStaking());
    QCOMPARE(staking_status->text(), QString("Staking is off"));

    donation_percent->setValue(15);
    donation_enable->click();
    QCOMPARE(walletModel.wallet().getQQDevelopmentDonationPercentage(), 15U);
    QVERIFY(donation_status->text().contains(QString("15")));
    QCOMPARE(overview_donations->text(), QString("15% of stake rewards"));

    donation_percent->setValue(7);
    qApp->processEvents();
    QCOMPARE(walletModel.wallet().getQQDevelopmentDonationPercentage(), 7U);
    QVERIFY(donation_status->text().contains(QString("7")));
    QCOMPARE(overview_donations->text(), QString("7% of stake rewards"));

    donation_enable->click();
    QCOMPARE(walletModel.wallet().getQQDevelopmentDonationPercentage(), 0U);
    QVERIFY(donation_status->text().contains(QString("off")));
    QCOMPARE(overview_donations->text(), QString("0% of stake rewards"));

    QCOMPARE(pow_enable->isChecked(), false);
    QVERIFY(!walletModel.wallet().getPowMiningInfo().enabled);
    QCOMPARE(walletModel.wallet().getPowClaimRecoveryPolicy().mode,
             interfaces::WalletPowClaimRecoveryMode::UNSET);

    const int requested_threads = std::min(2, pow_cores->maximum());
    pow_cores->setValue(requested_threads);
    pow_percent->setValue(25);

    // The first start cannot bypass a recorded failed-claim choice. Cancel is
    // safe: it leaves both the miner and the durable policy untouched.
    AnswerInitialPowClaimRecoveryChoice(InitialPowClaimRecoveryChoice::CANCEL);
    pow_enable->click();
    QTRY_VERIFY_WITH_TIMEOUT(pow_enable->isEnabled(), 5000);
    QVERIFY(!pow_enable->isChecked());
    QVERIFY(!walletModel.wallet().getPowMiningInfo().enabled);
    QCOMPARE(walletModel.wallet().getPowClaimRecoveryPolicy().mode,
             interfaces::WalletPowClaimRecoveryMode::UNSET);

    const WalletModel::EncryptionStatus encryption_before_policy =
        walletModel.getEncryptionStatus();
    const bool staking_only_before_policy = walletModel.getWalletUnlockStakingOnly();
    AnswerInitialPowClaimRecoveryChoice(
        InitialPowClaimRecoveryChoice::PAUSE_AND_ASK);
    ConfirmMessageBox(QMessageBox::Yes);
    pow_enable->click();
    QTRY_COMPARE_WITH_TIMEOUT(
        walletModel.wallet().getPowClaimRecoveryPolicy().mode,
        interfaces::WalletPowClaimRecoveryMode::PAUSE_AND_ASK, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(pow_status->text().contains(QString("enabled")), 5000);
    QVERIFY(pow_status->text().contains(QString("configured new-anchor payout")));
    QCOMPARE(walletModel.getEncryptionStatus(), encryption_before_policy);
    QCOMPARE(walletModel.getWalletUnlockStakingOnly(), staking_only_before_policy);

    interfaces::WalletPowMiningInfo info;
    for (int i = 0; i < 50; ++i) {
        info = walletModel.wallet().getPowMiningInfo();
        if (info.enabled && info.payout_address_available && !info.payout_address.empty()) break;
        QTest::qWait(20);
    }
    QVERIFY(info.enabled);
    QCOMPARE(info.threads, requested_threads);
    QCOMPARE(info.cpu_percent, 25);
    QVERIFY(info.payout_address_available);
    QVERIFY(!info.payout_address.empty());

    const CTxDestination payout_dest = DecodeDestination(info.payout_address);
    QVERIFY(IsValidDestination(payout_dest));
    QVERIFY(IsQuantumMigrationDestination(payout_dest));
    const QString expected_payout = QString::fromStdString(info.payout_address);
    // Full-detail wallet walks run on WalletWorker. The Qt event thread only
    // queues the refresh and applies one immutable result.
    QSignalSpy payout_snapshot_ready(
        &walletModel, &WalletModel::stakingMiningSnapshotReady);
    std::promise<void> payout_main_lock_held;
    std::promise<void> release_payout_main_lock;
    std::shared_future<void> payout_main_lock_release =
        release_payout_main_lock.get_future().share();
    std::thread payout_main_lock_holder([&] {
        LOCK(cs_main);
        payout_main_lock_held.set_value();
        payout_main_lock_release.wait();
    });
    payout_main_lock_held.get_future().wait();
    const interfaces::WalletPowMiningInfo unavailable_info =
        walletModel.wallet().getPowMiningInfo();
    refresh_details->click();

    // Queue while cs_main is unavailable, then acquire cs_wallet before
    // releasing cs_main. This overlapping lock handoff forces the worker's
    // first PoW sub-read to be incomplete without delaying the GUI thread.
    std::promise<void> payout_wallet_lock_held;
    std::promise<void> release_payout_wallet_lock;
    std::shared_future<void> payout_wallet_lock_release =
        release_payout_wallet_lock.get_future().share();
    std::thread payout_wallet_lock_holder([&] {
        LOCK(core_wallet->cs_wallet);
        payout_wallet_lock_held.set_value();
        payout_wallet_lock_release.wait();
    });
    payout_wallet_lock_held.get_future().wait();
    release_payout_main_lock.set_value();
    payout_main_lock_holder.join();
    release_payout_wallet_lock.set_value();
    payout_wallet_lock_holder.join();
    QVERIFY(!unavailable_info.payout_address_available);
    QTRY_COMPARE_WITH_TIMEOUT(payout_snapshot_ready.count(), 1, 20000);
    QVERIFY(refresh_hint->text().contains(QStringLiteral("Detail panels updated")));
    QCOMPARE(pow_payout->text(), expected_payout);
    QVERIFY(pow_copy->isEnabled());

    pow_copy->click();
    QCOMPARE(QApplication::clipboard()->text(), pow_payout->text());
    QVERIFY(pow_warning->text().contains(QString("Back up this wallet")));
    QVERIFY(pow_warning->text().contains(QString("authenticated quantum payout carried by its claim")));
    QVERIFY(pow_warning->text().contains(QString("configures only future new-anchor claims")));
    QVERIFY(pow_warning->text().contains(QString("locked until Gold Rush ends")));
    const QString pow_guide = QuantumGuides::DetailedAppendixForTitle(
        QStringLiteral("PoW payout"));
    QVERIFY(pow_guide.contains(QStringLiteral(
        "retained claim family preserves its already-authenticated payout")));
    QVERIFY(pow_guide.contains(QStringLiteral(
        "same-anchor refresh does not allocate an unrelated future-new-anchor key")));
    QVERIFY(pow_guide.contains(QStringLiteral(
        "authenticated quantum payout carried by that claim")));
    QVERIFY(pow_guide.contains(QStringLiteral(
        "does not alter a retained family's authenticated payout")));

    pow_enable->click();
    qApp->processEvents();
    QVERIFY(!walletModel.wallet().getPowMiningInfo().enabled);
    QCOMPARE(walletModel.wallet().getPowMiningInfo().state, interfaces::WalletPowMiningState::DISABLED);
    QCOMPARE(pow_status->text(), QString("Gold Rush PoW mining is off."));

    {
        LOCK2(::cs_main, core_wallet->cs_wallet);
        for (const wallet::COutput& output : wallet::AvailableCoins(*core_wallet).All()) {
            QVERIFY(core_wallet->LockCoin(output.outpoint));
            cleanup.locked_coins.push_back(output.outpoint);
        }
    }
    QVERIFY(!cleanup.locked_coins.empty());

    ConfirmMessageBox(QMessageBox::Yes);
    pow_enable->click();
    QTRY_VERIFY_WITH_TIMEOUT(
        walletModel.wallet().getPowMiningInfo().state == interfaces::WalletPowMiningState::NO_SPENDABLE_LEGACY_FEE_UTXO,
        10000);
    QCOMPARE(walletModel.wallet().getPowMiningInfo().hashrate, 0.0);

    refresh_details->click();
    QTRY_VERIFY_WITH_TIMEOUT(pow_status->text().contains(QString("legacy BLK UTXO")), 10000);
    QTRY_VERIFY_WITH_TIMEOUT(pow_dashboard->text().contains(QString("waiting for a spendable legacy fee UTXO")), 10000);
    QVERIFY(!pow_dashboard->text().contains(QString("running at 0")));

    pow_enable->click();
    qApp->processEvents();
    QCOMPARE(walletModel.wallet().getPowMiningInfo().state, interfaces::WalletPowMiningState::DISABLED);
}

void TestPowClaimRecoveryPolicyControls(
    interfaces::Node& node,
    MiniGUI& mini_gui,
    const std::shared_ptr<CWallet>& core_wallet,
    const PlatformStyle* platform_style)
{
    WalletModel& wallet_model = *mini_gui.walletModel;
    interfaces::Wallet& wallet_interface = wallet_model.wallet();

    std::string error;
    QVERIFY(wallet_interface.setPowMining(false, 1, 1, error));
    interfaces::WalletPowClaimRecoveryPolicy reset_policy;
    QVERIFY(wallet_interface.setPowClaimRecoveryPolicy(reset_policy, error));
    QCOMPARE(wallet_interface.getPowClaimRecoveryPolicy().mode,
             interfaces::WalletPowClaimRecoveryMode::UNSET);

    StakingMiningPage page(platform_style);
    page.setClientModel(mini_gui.clientModel.get());
    page.setWalletModel(&wallet_model);
    page.show();
    qApp->processEvents();

    auto* recovery = page.findChild<QCheckBox*>(
        QStringLiteral("automationClaimRecovery"));
    auto* status = page.findChild<QLabel*>(QStringLiteral("automationStatus"));
    auto* refresh = page.findChild<QPushButton*>(QStringLiteral("stakingMiningRefresh"));
    QVERIFY(recovery);
    QVERIFY(status);
    QVERIFY(refresh);
    QCOMPARE(recovery->text(), QStringLiteral(
        "Permit bounded automatic fee-paying conflict recovery as an "
        "alternative to waiting"));
    QVERIFY(recovery->toolTip().contains(QStringLiteral("same confirmed anchor")));
    QVERIFY(recovery->toolTip().contains(QStringLiteral("waits while a member is live")));
    QVERIFY(recovery->toolTip().contains(QStringLiteral("no recovery transaction")));
    QVERIFY(recovery->toolTip().contains(QStringLiteral("ordinary claim fee")));
    QVERIFY(recovery->toolTip().contains(QStringLiteral("miner could otherwise continue")));
    QTRY_VERIFY_WITH_TIMEOUT(recovery->isEnabled(), 5000);
    QVERIFY(!recovery->isChecked());
    QVERIFY(status->text().contains(QStringLiteral("6 process-wide")));
    QVERIFY(status->text().contains(QStringLiteral("wallet-scoped")));
    QVERIFY(status->text().contains(QStringLiteral("no choice recorded")));

    // Escape is the safe cancellation path and must not persist consent.
    AnswerPowClaimRecoveryConsent(/*enable=*/false, /*use_escape=*/true);
    QTest::mouseClick(recovery, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(recovery->isEnabled(), 3000);
    QVERIFY(!recovery->isChecked());
    QCOMPARE(wallet_interface.getPowClaimRecoveryPolicy().mode,
             interfaces::WalletPowClaimRecoveryMode::UNSET);

    // The consent surface names the exact wallet. A wallet unload during its
    // nested event loop closes the modal and cannot persist authority to the
    // old or newly selected wallet.
    UnloadWalletDuringPowClaimRecoveryConsent(
        page, wallet_model.getDisplayName());
    QTest::mouseClick(recovery, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(!recovery->isEnabled(), 3000);
    QCOMPARE(wallet_interface.getPowClaimRecoveryPolicy().mode,
             interfaces::WalletPowClaimRecoveryMode::UNSET);
    // Do not reattach this same widget while the nested unload callback is
    // unwinding: the old setWalletModel(nullptr) frame still owns its cleanup.
    // A real wallet reload creates/rebinds a current view after that obsolete
    // consent surface has been discarded, so exercise the remainder on a
    // genuinely fresh page.
    StakingMiningPage active_page(platform_style);
    active_page.setClientModel(mini_gui.clientModel.get());
    active_page.setWalletModel(&wallet_model);
    active_page.show();
    recovery = active_page.findChild<QCheckBox*>(
        QStringLiteral("automationClaimRecovery"));
    status = active_page.findChild<QLabel*>(QStringLiteral("automationStatus"));
    refresh = active_page.findChild<QPushButton*>(
        QStringLiteral("stakingMiningRefresh"));
    QVERIFY(recovery);
    QVERIFY(status);
    QVERIFY(refresh);
    QTRY_VERIFY_WITH_TIMEOUT(recovery->isEnabled(), 5000);
    QVERIFY(!recovery->isChecked());

    // WalletModel owns globally unique correlation within this wallet. An
    // exact cancellation by one caller cannot cancel another caller's work.
    std::shared_ptr<const WalletModel::PowClaimRecoveryPolicyResult> first_result;
    std::shared_ptr<const WalletModel::PowClaimRecoveryPolicyResult> second_result;
    uint64_t first_id{0};
    uint64_t second_id{0};
    const QMetaObject::Connection request_connection = QObject::connect(
        &wallet_model, &WalletModel::powClaimRecoveryPolicyReady, &active_page,
        [&](quint64 request_id, quint64) {
            if (request_id == first_id) {
                first_result = wallet_model.takePowClaimRecoveryPolicyResult(request_id);
            } else if (request_id == second_id) {
                second_result = wallet_model.takePowClaimRecoveryPolicyResult(request_id);
            }
        });
    WalletModel::PowClaimRecoveryPolicyRequest first_request;
    first_request.generation = 1001;
    WalletModel::PowClaimRecoveryPolicyRequest second_request;
    second_request.generation = 1002;
    first_id = wallet_model.requestPowClaimRecoveryPolicy(first_request);
    second_id = wallet_model.requestPowClaimRecoveryPolicy(second_request);
    QVERIFY(first_id != 0);
    QVERIFY(second_id != 0);
    QVERIFY(first_id != second_id);
    wallet_model.cancelPowClaimRecoveryPolicy(first_id);
    QTRY_VERIFY_WITH_TIMEOUT(first_result != nullptr, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(second_result != nullptr, 5000);
    QVERIFY(second_result->success);
    QVERIFY(!second_result->cancelled);
    if (first_result) QCOMPARE(first_result->request.request_id, first_id);
    QObject::disconnect(request_connection);

    // Accept the bounded defaults. The write is asynchronous and wallet-
    // scoped; it must not infer consent to start the miner.
    const WalletModel::EncryptionStatus encryption_before =
        wallet_model.getEncryptionStatus();
    const bool staking_only_before = wallet_model.getWalletUnlockStakingOnly();

    // Accept from the new current view. The write is asynchronous and must
    // update that same view from Core's authoritative persisted result.
    QTRY_VERIFY_WITH_TIMEOUT(recovery->isEnabled() && !recovery->isChecked(), 5000);
    AnswerPowClaimRecoveryConsent(
        /*enable=*/true, /*use_escape=*/false, wallet_model.getDisplayName());
    recovery->click();
    QTRY_COMPARE_WITH_TIMEOUT(
        wallet_interface.getPowClaimRecoveryPolicy().mode,
        interfaces::WalletPowClaimRecoveryMode::AUTOMATIC, 10000);
    QTRY_VERIFY_WITH_TIMEOUT(recovery->isChecked(), 10000);
    QVERIFY(!wallet_interface.getPowMiningInfo().enabled);
    QCOMPARE(wallet_model.getEncryptionStatus(), encryption_before);
    QCOMPARE(wallet_model.getWalletUnlockStakingOnly(), staking_only_before);

    const interfaces::WalletPowClaimRecoveryPolicy stored =
        wallet_interface.getPowClaimRecoveryPolicy();
    QVERIFY(stored.max_fee_per_resolution > 0);
    QVERIFY(stored.aggregate_batch_fee_cap >= stored.max_fee_per_resolution);
    QVERIFY(stored.rolling_fee_budget >= stored.aggregate_batch_fee_cap);
    const wallet::ShadowPowClaimRecoveryPolicy core_stored =
        core_wallet->GetShadowPowClaimRecoveryPolicy();
    QVERIFY(core_stored.HasAutomaticAuthority());
    QCOMPARE(core_stored.max_fee_per_resolution, stored.max_fee_per_resolution);
    QCOMPARE(core_stored.aggregate_batch_fee_cap, stored.aggregate_batch_fee_cap);
    QCOMPARE(core_stored.rolling_fee_budget, stored.rolling_fee_budget);

    // A second interface instance sees the same durable wallet record, while
    // a different wallet remains UNSET.
    WalletContext& context = *node.walletLoader().context();
    auto same_wallet_interface = interfaces::MakeWallet(context, core_wallet);
    QVERIFY(same_wallet_interface->getPowClaimRecoveryPolicy() == stored);

    auto other_wallet = std::make_shared<CWallet>(
        node.context()->chain.get(), "qt-claim-recovery-isolation",
        CreateMockableWalletDatabase());
    QCOMPARE(other_wallet->LoadWallet(), wallet::DBErrors::LOAD_OK);
    auto other_wallet_interface = interfaces::MakeWallet(context, other_wallet);
    QCOMPARE(other_wallet_interface->getPowClaimRecoveryPolicy().mode,
             interfaces::WalletPowClaimRecoveryMode::UNSET);

    // A failed revocation must restore the actual authorized state and show a
    // prominent failure instead of quietly implying that spending authority
    // was removed.
    wallet::MockableDatabase& database = wallet::GetMockableDatabase(*core_wallet);
    database.m_fail_begin = true;
    ConfirmMessageBox(QMessageBox::Ok);
    QTest::mouseClick(recovery, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(recovery->isEnabled(), 5000);
    database.m_fail_begin = false;
    QVERIFY(recovery->isChecked());
    QCOMPARE(wallet_interface.getPowClaimRecoveryPolicy().mode,
             interfaces::WalletPowClaimRecoveryMode::AUTOMATIC);
    QVERIFY(status->text().contains(
        QStringLiteral("failed to begin durable automated PoW claim recovery policy update"),
        Qt::CaseInsensitive));
    // Unchecking records PAUSE_AND_ASK instead of silently erasing the
    // operator's choice or changing any fee bounds.
    QTest::mouseClick(recovery, Qt::LeftButton);
    QTRY_COMPARE_WITH_TIMEOUT(
        wallet_interface.getPowClaimRecoveryPolicy().mode,
        interfaces::WalletPowClaimRecoveryMode::PAUSE_AND_ASK, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(!recovery->isChecked(), 5000);
    QCOMPARE(wallet_interface.getPowClaimRecoveryPolicy().max_fee_per_resolution,
             stored.max_fee_per_resolution);
    QVERIFY(!wallet_interface.getPowMiningInfo().enabled);

    // An external CLI/RPC-equivalent write is reflected by the explicit
    // refresh; the GUI must not keep displaying stale standing authority.
    interfaces::WalletPowClaimRecoveryPolicy external = stored;
    external.mode = interfaces::WalletPowClaimRecoveryMode::AUTOMATIC;
    QVERIFY(wallet_interface.setPowClaimRecoveryPolicy(external, error));
    refresh->click();
    QTRY_VERIFY_WITH_TIMEOUT(recovery->isChecked(), 5000);

    external.mode = interfaces::WalletPowClaimRecoveryMode::PAUSE_AND_ASK;
    QVERIFY(wallet_interface.setPowClaimRecoveryPolicy(external, error));
    refresh->click();
    QTRY_VERIFY_WITH_TIMEOUT(!recovery->isChecked(), 5000);

    // Switching wallets while a click's preflight read is queued must cancel
    // the obsolete view request without persisting its intended change.
    QTest::mouseClick(recovery, Qt::LeftButton);
    active_page.setWalletModel(nullptr);
    qApp->processEvents();
    active_page.setWalletModel(&wallet_model);
    QTRY_VERIFY_WITH_TIMEOUT(recovery->isEnabled(), 5000);
    QVERIFY(!recovery->isChecked());
    QCOMPARE(wallet_interface.getPowClaimRecoveryPolicy().mode,
             interfaces::WalletPowClaimRecoveryMode::PAUSE_AND_ASK);

    // Leave the shared GUI wallet at the safe release default for later tests.
    QVERIFY(wallet_interface.setPowClaimRecoveryPolicy(reset_policy, error));

}

void TestPowClaimRecoveryManualDialog(
    interfaces::Node& node, const CKey& recovery_key,
    const PlatformStyle* platform_style)
{
    QtRecoveryShadowScheduleGuard schedule{/*whitelist_height=*/99,
                                           /*reward_start_height=*/100,
                                           /*gold_rush_blocks=*/1000};
    auto core_wallet = std::shared_ptr<CWallet>(
        wallet::CreateSyncedWallet(
            *node.context()->chain,
            node.context()->chainman->ActiveChain(), recovery_key)
            .release());
    core_wallet->SetBroadcastTransactions(true);
    MiniGUI mini_gui(node, platform_style);
    mini_gui.initModelForWallet(node, core_wallet, platform_style);
    WalletModel& wallet_model = *mini_gui.walletModel;
    interfaces::Wallet& wallet_interface = wallet_model.wallet();
    std::string error;
    QVERIFY(wallet_interface.setPowMining(false, 1, 1, error));

    const CBlockIndex* tip = WITH_LOCK(
        node.context()->chainman->GetMutex(),
        return node.context()->chainman->ActiveChain().Tip());
    QVERIFY(tip);
    std::optional<wallet::COutput> anchor;
    {
        LOCK2(::cs_main, core_wallet->cs_wallet);
        core_wallet->SetLastBlockProcessed(tip->nHeight, tip->GetBlockHash());
        const auto coins = wallet::AvailableCoins(*core_wallet).All();
        const auto candidate = std::find_if(
            coins.begin(), coins.end(), [](const wallet::COutput& output) {
                return output.spendable && output.depth > 0 &&
                       output.txout.nValue >
                           wallet::DEFAULT_TRANSACTION_MAXFEE;
            });
        if (candidate != coins.end()) {
            anchor = *candidate;
        }
    }
    QVERIFY(anchor.has_value());
    const CTransactionRef claim = MakeQtRecoveryTestClaim(
        anchor->outpoint,
        anchor->txout.nValue - wallet::DEFAULT_TRANSACTION_MAXFEE,
        anchor->txout.scriptPubKey);
    QVERIFY(TransactionHasShadowProof(*claim));
    QVERIFY(core_wallet->AddToWallet(
        claim, wallet::TxStateInactive{},
        [tip](wallet::CWalletTx& wtx, bool) {
            // This models an imported pre-provenance claim. It is wallet-
            // spendable and has complete quarantine facts, but no explicit
            // authored/adopted marker. The GUI must make adoption available
            // only after the operator selects this exact component.
            wtx.mapValue[wallet::SHADOW_POW_CLAIM_CREATED_HEIGHT_KEY] =
                ToString(tip->nHeight);
            wtx.mapValue[wallet::SHADOW_POW_CLAIM_CREATED_TIP_KEY] =
                tip->GetBlockHash().GetHex();
            wtx.mapValue[wallet::SHADOW_POW_QUARANTINE_MARKER_KEY] = "1";
            wtx.mapValue[wallet::SHADOW_POW_CLAIM_FIRST_QUARANTINE_HEIGHT_KEY] =
                ToString(tip->nHeight);
            wtx.mapValue[wallet::SHADOW_POW_CLAIM_FIRST_QUARANTINE_TIP_KEY] =
                tip->GetBlockHash().GetHex();
            wtx.mapValue[wallet::SHADOW_POW_CLAIM_BRANCH_QUARANTINE_HEIGHT_KEY] =
                ToString(tip->nHeight);
            wtx.mapValue[wallet::SHADOW_POW_CLAIM_BRANCH_QUARANTINE_TIP_KEY] =
                tip->GetBlockHash().GetHex();
            wtx.fFromMe = true;
            return true;
        }));

    StakingMiningPage page(platform_style);
    page.setClientModel(mini_gui.clientModel.get());
    page.setWalletModel(&wallet_model);
    page.show();
    qApp->processEvents();

    auto* review = page.findChild<QPushButton*>(
        QStringLiteral("powClaimRecoveryReview"));
    QVERIFY(review);
    QTRY_VERIFY_WITH_TIMEOUT(review->isVisible() && review->isEnabled(), 5000);
    QVERIFY(!wallet_interface.getPowMiningInfo().enabled);

    QTest::mouseClick(review, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(
        page.findChild<QDialog*>(QStringLiteral("powClaimRecoveryDialog")),
        5000);
    auto* dialog = page.findChild<QDialog*>(
        QStringLiteral("powClaimRecoveryDialog"));
    auto* wait = dialog->findChild<QPushButton*>(
        QStringLiteral("powClaimRecoveryWait"));
    auto* resolve = dialog->findChild<QPushButton*>(
        QStringLiteral("powClaimRecoveryResolve"));
    auto* adopt = dialog->findChild<QPushButton*>(
        QStringLiteral("powClaimRecoveryAdopt"));
    auto* automatic = dialog->findChild<QPushButton*>(
        QStringLiteral("powClaimRecoveryEnableAutomatic"));
    auto* refresh = dialog->findChild<QPushButton*>(
        QStringLiteral("powClaimRecoveryRefresh"));
    auto* table = dialog->findChild<QTableWidget*>(
        QStringLiteral("powClaimRecoveryComponents"));
    auto* result = dialog->findChild<QLabel*>(
        QStringLiteral("powClaimRecoveryResult"));
    auto* fee_authorization = dialog->findChild<QLabel*>(
        QStringLiteral("powClaimRecoveryFeeAuthorization"));
    auto* explanation = dialog->findChild<QLabel*>(
        QStringLiteral("powClaimRecoveryExplanation"));
    auto* acknowledge = dialog->findChild<QCheckBox*>(
        QStringLiteral("powClaimRecoveryAcknowledge"));
    QVERIFY(wait);
    QVERIFY(resolve);
    QVERIFY(adopt);
    QVERIFY(automatic);
    QVERIFY(refresh);
    QVERIFY(table);
    QVERIFY(result);
    QVERIFY(fee_authorization);
    QVERIFY(explanation);
    QVERIFY(acknowledge);
    QVERIFY(wait->isDefault());
    QVERIFY(explanation->text().contains(
        QStringLiteral("same confirmed anchor")));
    QVERIFY(explanation->text().contains(
        QStringLiteral("waits while a member is live")));
    QVERIFY(explanation->text().contains(
        QStringLiteral("ordinary claim fee")));
    QVERIFY(explanation->text().contains(
        QStringLiteral("miner could continue")));
    QVERIFY(explanation->text().contains(
        QStringLiteral("may become eligible again at a later height")));
    QVERIFY(explanation->text().contains(
        QStringLiteral("either the original claim or the conflicting recovery may confirm")));
    QVERIFY(acknowledge->text().contains(
        QStringLiteral("legacy QQP2 risk")));
    QTRY_VERIFY_WITH_TIMEOUT(
        result->text().contains(QStringLiteral("Read-only preview complete")),
        10000);
    QTRY_COMPARE_WITH_TIMEOUT(table->rowCount(), 1, 10000);
    QVERIFY(table->item(0, 0));
    QVERIFY(!table->item(0, 0)->text().isEmpty());
    QVERIFY(table->item(0, 5));
    QVERIFY(!adopt->isEnabled());

    // Positive imported-component adoption path: selecting the exact row
    // enables only adoption, confirmation is safe-default No, Core rechecks
    // the tip/fingerprint, and the old preview is invalidated on success.
    table->selectRow(0);
    QTRY_VERIFY_WITH_TIMEOUT(adopt->isEnabled(), 5000);
    ConfirmMessageBox(QMessageBox::Yes);
    QTest::mouseClick(adopt, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(
        result->text().contains(QStringLiteral("durably adopted")), 10000);
    QCOMPARE(table->rowCount(), 0);
    QVERIFY(!resolve->isEnabled());
    QVERIFY(!acknowledge->isChecked());

    QTest::mouseClick(refresh, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(
        result->text().contains(QStringLiteral("Read-only preview complete")),
        10000);
    QTRY_COMPARE_WITH_TIMEOUT(table->rowCount(), 1, 10000);
    table->selectRow(0);
    QVERIFY(!adopt->isEnabled());

    wallet::ShadowPowClaimRecoveryRequest core_preview_request;
    const wallet::ShadowPowClaimRecoveryPlan core_plan =
        core_wallet->PlanShadowPowClaimRecovery(core_preview_request);
    QVERIFY(core_plan.complete);
    QCOMPARE(core_plan.actions.size(), size_t{1});
    QVERIFY(core_plan.total_fee > 0);
    QVERIFY(core_plan.total_fee <= core_plan.aggregate_batch_fee_cap);
    QVERIFY(table->item(0, 5)->text().contains(
        FormatQtRecoveryAmount(core_plan.actions.front().fee)));
    const QString plan_id = QString::fromStdString(core_plan.plan_id.GetHex());
    QVERIFY(fee_authorization->text().contains(plan_id));
    QVERIFY(fee_authorization->text().contains(
        FormatQtRecoveryAmount(core_plan.total_fee)));
    QVERIFY(fee_authorization->text().contains(
        FormatQtRecoveryAmount(core_plan.max_fee_per_resolution)));
    QVERIFY(fee_authorization->text().contains(
        FormatQtRecoveryAmount(core_plan.aggregate_batch_fee_cap)));
    QVERIFY(fee_authorization->text().contains(
        QStringLiteral("Legacy QQP2 risk")));
    QVERIFY(acknowledge->isEnabled());
    QVERIFY(acknowledge->text().contains(plan_id));
    QVERIFY(acknowledge->text().contains(
        FormatQtRecoveryAmount(core_plan.total_fee)));
    QVERIFY(acknowledge->text().contains(
        FormatQtRecoveryAmount(core_plan.max_fee_per_resolution)));
    QVERIFY(acknowledge->text().contains(
        FormatQtRecoveryAmount(core_plan.aggregate_batch_fee_cap)));
    QVERIFY(!resolve->isEnabled());
    QVERIFY(automatic->isEnabled());
    QVERIFY(!wallet_interface.getPowMiningInfo().enabled);

    // Adoption made the imported provenance explicit. The exact fee
    // acknowledgement now enables only the newly plan-pinned Resolve action.
    QTest::mouseClick(acknowledge, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(resolve->isEnabled(), 5000);

    interfaces::WalletPowClaimRecoveryRequest interface_preview;
    const interfaces::WalletPowClaimRecoveryReview interface_review =
        wallet_interface.getPowClaimRecoveryReview(interface_preview);
    QVERIFY(interface_review.consistent);
    QCOMPARE(QString::fromStdString(interface_review.plan.plan_id),
             QString::fromStdString(core_plan.plan_id.GetHex()));

    // Exercise the built-in authorization/resolve route. The wallet is
    // unencrypted, so no passphrase dialog is needed; Core still rechecks the
    // exact plan and owns persistence plus relay.
    QTest::mouseClick(resolve, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(
        result->text().contains(
            QStringLiteral("Core completed the exact recovery plan")),
        20000);
    QCOMPARE(table->rowCount(), 0);
    QVERIFY(!resolve->isEnabled());
    QVERIFY(!acknowledge->isChecked());
    QVERIFY(!wallet_interface.getPowMiningInfo().enabled);

    QTest::mouseClick(wait, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(
        !page.findChild<QDialog*>(QStringLiteral("powClaimRecoveryDialog")),
        5000);

    uint256 managed_resolution_txid;
    {
        LOCK(core_wallet->cs_wallet);
        for (const auto& [txid, wtx] : core_wallet->mapWallet) {
            if (wtx.mapValue.count(
                    wallet::SHADOW_POW_RESOLUTION_SCHEMA_KEY) != 0) {
                managed_resolution_txid = txid;
                break;
            }
        }
    }
    QVERIFY(!managed_resolution_txid.IsNull());
    const auto revocation =
        core_wallet->RevokeManagedShadowPowResolutionRelayAuthority(
            managed_resolution_txid);
    QVERIFY(revocation.success);
    const auto revoked_interface_review =
        wallet_interface.getPowClaimRecoveryReview(interface_preview);
    QVERIFY(std::any_of(
        revoked_interface_review.plan.actions.begin(),
        revoked_interface_review.plan.actions.end(), [](const auto& action) {
            return action.relay_revoked && !action.relay_authorized;
        }));
    QVERIFY(std::any_of(
        revoked_interface_review.components.begin(),
        revoked_interface_review.components.end(), [](const auto& component) {
            return std::any_of(
                component.nodes.begin(), component.nodes.end(),
                [](const auto& graph_node) {
                    return graph_node.resolution_relay_revoked &&
                           !graph_node.resolution_relay_authorized;
                });
        }));

    // Inspection preserves a staking-only scope and never grants signing.
    wallet_model.setWalletUnlockStakingOnly(true);
    QTest::mouseClick(review, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(
        page.findChild<QDialog*>(QStringLiteral("powClaimRecoveryDialog")),
        5000);
    dialog = page.findChild<QDialog*>(QStringLiteral("powClaimRecoveryDialog"));
    result = dialog->findChild<QLabel*>(QStringLiteral("powClaimRecoveryResult"));
    wait = dialog->findChild<QPushButton*>(QStringLiteral("powClaimRecoveryWait"));
    table = dialog->findChild<QTableWidget*>(QStringLiteral("powClaimRecoveryComponents"));
    QTRY_VERIFY_WITH_TIMEOUT(
        result->text().contains(QStringLiteral("Read-only preview complete")),
        10000);
    QTRY_COMPARE_WITH_TIMEOUT(table->rowCount(), 1, 10000);
    QVERIFY(table->item(0, 6)->text().contains(
        QStringLiteral("local relay revoked")));
    QVERIFY(wallet_model.getWalletUnlockStakingOnly());
    QTest::mouseClick(wait, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(
        !page.findChild<QDialog*>(QStringLiteral("powClaimRecoveryDialog")),
        5000);
    wallet_model.setWalletUnlockStakingOnly(false);

    // A wallet switch closes the wallet-bound review and cancels a queued
    // request only before Core entry.
    QTest::mouseClick(review, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(
        page.findChild<QDialog*>(QStringLiteral("powClaimRecoveryDialog")),
        5000);
    page.setWalletModel(nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(
        !page.findChild<QDialog*>(QStringLiteral("powClaimRecoveryDialog")),
        5000);
    page.setWalletModel(&wallet_model);
    QTRY_VERIFY_WITH_TIMEOUT(review->isVisible() && review->isEnabled(), 5000);
    QVERIFY(!wallet_interface.getPowMiningInfo().enabled);
}

void TestPowClaimRecoveryStakingOnlyRequiresFullUnlock(
    interfaces::Node& node, const PlatformStyle* platform_style)
{
    auto wallet = std::make_shared<CWallet>(
        node.context()->chain.get(), "qt-claim-recovery-unlock-scope",
        CreateMockableWalletDatabase());
    QCOMPARE(wallet->LoadWallet(), wallet::DBErrors::LOAD_OK);

    MiniGUI mini_gui(node, platform_style);
    mini_gui.initModelForWallet(node, wallet, platform_style);
    WalletModel& model = *mini_gui.walletModel;
    SyncRecoveryReviewWalletTip(wallet, node);
    const SecureString passphrase{"qt-claim-recovery-passphrase"};
    QVERIFY(wallet->EncryptWallet(passphrase));

    // Generic signing requests must revoke an existing staking-only key before
    // asking for a normal unlock. The hidden-scope Unlock dialog receives a
    // locked wallet with the normal scope staged, and the context restores the
    // original unlocked staking-only scope only after the operation ends.
    QVERIFY(model.setWalletLocked(false, passphrase,
                                  /*staking_only=*/true));
    bool generic_normal_prompted{false};
    QMetaObject::Connection generic_unlock = QObject::connect(
        &model, &WalletModel::requireUnlock, &model, [&] {
            generic_normal_prompted = true;
            QCOMPARE(model.getEncryptionStatus(), WalletModel::Locked);
            QVERIFY(!model.getWalletUnlockStakingOnly());
            QVERIFY(model.setWalletLocked(false, passphrase,
                                          /*staking_only=*/false));
        });
    {
        auto context = model.requestUnlock();
        QVERIFY(context.isValid());
        QVERIFY(generic_normal_prompted);
        QCOMPARE(model.getEncryptionStatus(), WalletModel::Unlocked);
        QVERIFY(!model.getWalletUnlockStakingOnly());
    }
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Unlocked);
    QVERIFY(model.getWalletUnlockStakingOnly());
    QObject::disconnect(generic_unlock);

    // A cancelled normal-unlock request cannot clear staking-only scope on an
    // installed key. It leaves the wallet locked and restores the prior scope
    // marker without granting normal authority.
    {
        auto context = model.requestUnlock();
        QVERIFY(!context.isValid());
    }
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Locked);
    QVERIFY(model.getWalletUnlockStakingOnly());
    // Lock notifications update WalletModel's display cache asynchronously.
    // Establish that presentation precondition before constructing the page;
    // the assertions below test locked-marker rendering, not timer latency.
    QTRY_COMPARE_WITH_TIMEOUT(
        model.getCachedEncryptionStatus(), WalletModel::Locked, 1000);

    // The Staking & Mining page uses a separate normal-unlock helper. A
    // cancelled dialog must preserve the same locked staking-only preference
    // as the generic WalletModel path.
    QVERIFY(model.setWalletLocked(false, passphrase,
                                  /*staking_only=*/true));
    {
        StakingMiningPage unlock_page(platform_style);
        unlock_page.setClientModel(mini_gui.clientModel.get());
        unlock_page.setWalletModel(&model);
        unlock_page.show();
        auto* pow_unlock =
            unlock_page.findChild<QCheckBox*>("powUnlockWallet");
        QVERIFY(pow_unlock);
        QTRY_VERIFY_WITH_TIMEOUT(pow_unlock->isVisible(), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(pow_unlock->isEnabled(), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(!pow_unlock->isChecked(), 5000);
        QCOMPARE(model.getEncryptionStatus(), WalletModel::Unlocked);
        QVERIFY(model.getWalletUnlockStakingOnly());
        bool normal_unlock_rejected{false};
        WaitForModal(QStringLiteral("normal wallet unlock dialog"), [&normal_unlock_rejected] {
            QWidget* modal = QApplication::activeModalWidget();
            if (!modal || !modal->inherits("AskPassphraseDialog")) {
                return false;
            }
            normal_unlock_rejected = true;
            qobject_cast<QDialog*>(modal)->reject();
            return true;
        });
        pow_unlock->click();
        QVERIFY(normal_unlock_rejected);
        QTRY_COMPARE_WITH_TIMEOUT(
            model.getEncryptionStatus(), WalletModel::Locked, 5000);
        QVERIFY(model.getWalletUnlockStakingOnly());
        QVERIFY(!wallet->HasNormalPowMiningWalletAuthority());
        QTRY_VERIFY_WITH_TIMEOUT(!pow_unlock->isChecked(), 5000);
        QVERIFY(!model.wallet().getPowMiningInfo().enabled);
    }

    // The retained marker is only the staged preference for the next unlock.
    // A locked wallet must not be presented as actively staking-only unlocked.
    {
        StakingMiningPage scope_page(platform_style);
        scope_page.setClientModel(mini_gui.clientModel.get());
        scope_page.setWalletModel(&model);
        scope_page.show();
        auto* scope_refresh =
            scope_page.findChild<QPushButton*>("stakingMiningRefresh");
        auto* scope_checkbox =
            scope_page.findChild<QCheckBox*>("unlockStakingOnly");
        auto* scope_summary =
            scope_page.findChild<QLabel*>("stakingSummary");
        QVERIFY(scope_refresh);
        QVERIFY(scope_checkbox);
        QVERIFY(scope_summary);
        scope_refresh->click();
        QTRY_VERIFY_WITH_TIMEOUT(!scope_checkbox->isChecked(), 5000);
        QTRY_VERIFY_WITH_TIMEOUT(
            scope_summary->text().contains(QStringLiteral("Unlock mode: locked")),
            5000);
    }
    model.setWalletUnlockStakingOnly(false);

    interfaces::WalletPowClaimRecoveryRequest preview_request;
    const auto preview =
        model.wallet().getPowClaimRecoveryReview(preview_request);
    QVERIFY(preview.consistent);

    auto make_execution = [&] {
        WalletModel::PowClaimRecoveryOperationRequest request;
        request.generation = 1;
        request.operation =
            WalletModel::PowClaimRecoveryOperationRequest::Operation::EXECUTE;
        request.recovery.mode =
            interfaces::WalletPowClaimRecoveryRequestMode::COMMIT_AND_BROADCAST;
        request.recovery.acknowledge_fee_and_conflict_risk = true;
        request.recovery.max_fee_per_resolution =
            preview.plan.max_fee_per_resolution;
        request.recovery.aggregate_batch_fee_cap =
            preview.plan.aggregate_batch_fee_cap;
        request.recovery.expected_plan_id = preview.plan.plan_id;
        return request;
    };

    std::map<uint64_t,
             std::shared_ptr<const WalletModel::PowClaimRecoveryOperationResult>>
        results;
    const QMetaObject::Connection ready = QObject::connect(
        &model, &WalletModel::powClaimRecoveryOperationReady, &model,
        [&](quint64 request_id, quint64) {
            if (auto result =
                    model.takePowClaimRecoveryOperationResult(request_id)) {
                results.emplace(request_id, std::move(result));
            }
        });

    // locked -> locked after one successful, explicitly authorized normal
    // unlock. The temporary context may not leave signing authority behind.
    bool full_unlock_requested{false};
    QMetaObject::Connection unlock = QObject::connect(
        &model, &WalletModel::requireUnlock, &model, [&] {
            full_unlock_requested = true;
            QVERIFY(model.setWalletLocked(false, passphrase,
                                          /*staking_only=*/false));
        });
    uint64_t request_id =
        model.requestPowClaimRecoveryOperation(make_execution());
    QTRY_VERIFY_WITH_TIMEOUT(results.count(request_id) == 1, 5000);
    QVERIFY(full_unlock_requested);
    QVERIFY(results.at(request_id)->core_entered);
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Locked);
    QVERIFY(!model.getWalletUnlockStakingOnly());
    QObject::disconnect(unlock);

    // normal unlocked -> normal unlocked, with no unlock prompt.
    QVERIFY(model.setWalletLocked(false, passphrase,
                                  /*staking_only=*/false));
    QSignalSpy normal_prompt(&model, &WalletModel::requireUnlock);
    request_id = model.requestPowClaimRecoveryOperation(make_execution());
    QTRY_VERIFY_WITH_TIMEOUT(results.count(request_id) == 1, 5000);
    QVERIFY(results.at(request_id)->core_entered);
    QCOMPARE(normal_prompt.count(), 0);
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Unlocked);
    QVERIFY(!model.getWalletUnlockStakingOnly());

    // staking-only unlocked -> temporary full unlock -> staking-only unlocked.
    // The generic UnlockContext must not relock an originally unlocked wallet.
    model.setWalletUnlockStakingOnly(true);
    full_unlock_requested = false;
    unlock = QObject::connect(
        &model, &WalletModel::requireUnlock, &model, [&] {
            full_unlock_requested = true;
            QVERIFY(model.setWalletLocked(false, passphrase,
                                          /*staking_only=*/false));
        });
    request_id = model.requestPowClaimRecoveryOperation(make_execution());
    QTRY_VERIFY_WITH_TIMEOUT(results.count(request_id) == 1, 5000);
    QVERIFY(full_unlock_requested);
    QVERIFY(results.at(request_id)->core_entered);
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Unlocked);
    QVERIFY(model.getWalletUnlockStakingOnly());
    QObject::disconnect(unlock);

    // Cancelling the prompt after the model locked an initially staking-only
    // wallet cannot recreate that unlock without retaining a passphrase. The
    // wallet therefore remains locked and the result must say so explicitly.
    request_id = model.requestPowClaimRecoveryOperation(make_execution());
    QTRY_VERIFY_WITH_TIMEOUT(results.count(request_id) == 1, 5000);
    QVERIFY(!results.at(request_id)->core_entered);
    QVERIFY(!results.at(request_id)->success);
    QVERIFY(results.at(request_id)->error.find("remains locked") !=
            std::string::npos);
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Locked);
    QVERIFY(model.getWalletUnlockStakingOnly());

    // Entering the passphrase but selecting staking-only still cannot
    // authorize a recovery spend. It restores the original unlocked
    // staking-only state without briefly retaining a normal unlock context.
    QVERIFY(model.setWalletLocked(false, passphrase,
                                  /*staking_only=*/true));
    const QMetaObject::Connection staking_scope_unlock = QObject::connect(
        &model, &WalletModel::requireUnlock, &model, [&] {
            QVERIFY(model.setWalletLocked(false, passphrase,
                                          /*staking_only=*/true));
        });
    request_id = model.requestPowClaimRecoveryOperation(make_execution());
    QTRY_VERIFY_WITH_TIMEOUT(results.count(request_id) == 1, 5000);
    QVERIFY(!results.at(request_id)->core_entered);
    QVERIFY(results.at(request_id)->error.find(
                "prior staking-only unlock scope was restored") !=
            std::string::npos);
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Unlocked);
    QVERIFY(model.getWalletUnlockStakingOnly());
    QObject::disconnect(staking_scope_unlock);

    // A wallet-switch/unload token flipped from inside a successful full
    // unlock cancels before Core and restores the originally unlocked
    // staking-only state.
    const auto obsolete_view = std::make_shared<std::atomic<bool>>(true);
    bool obsolete_prompt_seen{false};
    bool obsolete_scope_restored_without_core_entry{false};
    const QMetaObject::Connection obsolete_unlock = QObject::connect(
        &model, &WalletModel::requireUnlock, &model, [&] {
            obsolete_prompt_seen = true;
            obsolete_view->store(false, std::memory_order_release);
            QVERIFY(model.setWalletLocked(false, passphrase,
                                          /*staking_only=*/false));
            // This callback runs inside the nested unlock prompt. The model
            // must observe the obsolete view and restore staking-only scope
            // without dispatching the cancelled request to Core.
            QTimer::singleShot(0, &model, [&] {
                obsolete_scope_restored_without_core_entry =
                    model.getEncryptionStatus() == WalletModel::Unlocked &&
                    model.getWalletUnlockStakingOnly() &&
                    results.count(request_id) == 1 &&
                    results.at(request_id)->cancelled &&
                    !results.at(request_id)->core_entered;
            });
        });
    auto obsolete_request = make_execution();
    obsolete_request.view_current = obsolete_view;
    request_id = model.requestPowClaimRecoveryOperation(
        std::move(obsolete_request));
    QTRY_VERIFY_WITH_TIMEOUT(
        obsolete_scope_restored_without_core_entry, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(results.count(request_id) == 1, 5000);
    QVERIFY(obsolete_prompt_seen);
    QVERIFY(results.at(request_id)->cancelled);
    QVERIFY(!results.at(request_id)->core_entered);
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Unlocked);
    QVERIFY(model.getWalletUnlockStakingOnly());
    QObject::disconnect(obsolete_unlock);

    // A close/cancel can also arrive through requireUnlock()'s nested event
    // loop before the successful prompt returns. The cancel site sees no
    // UnlockContext yet; the post-prompt path must nevertheless restore the
    // context it subsequently creates before anything is queued to Core.
    bool nested_cancel_seen{false};
    bool nested_cancel_scope_restored_without_core_entry{false};
    const QMetaObject::Connection cancel_during_unlock = QObject::connect(
        &model, &WalletModel::requireUnlock, &model, [&] {
            nested_cancel_seen = true;
            model.cancelPowClaimRecoveryOperation(request_id);
            QVERIFY(model.setWalletLocked(false, passphrase,
                                          /*staking_only=*/false));
            QTimer::singleShot(0, &model, [&] {
                nested_cancel_scope_restored_without_core_entry =
                    model.getEncryptionStatus() == WalletModel::Unlocked &&
                    model.getWalletUnlockStakingOnly() &&
                    results.count(request_id) == 1 &&
                    results.at(request_id)->cancelled &&
                    !results.at(request_id)->core_entered;
            });
        });
    request_id = model.requestPowClaimRecoveryOperation(make_execution());
    QTRY_VERIFY_WITH_TIMEOUT(nested_cancel_seen, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(
        nested_cancel_scope_restored_without_core_entry, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(results.count(request_id) == 1, 5000);
    QVERIFY(results.at(request_id)->cancelled);
    QVERIFY(!results.at(request_id)->core_entered);
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Unlocked);
    QVERIFY(model.getWalletUnlockStakingOnly());
    QObject::disconnect(cancel_during_unlock);

    // A second mutating request submitted from the first request's nested
    // unlock callback is rejected before another prompt/context or Core
    // entry. Once the first publishes and restores state, a later request is
    // accepted, proving the WalletModel single-flight gate is released.
    QVERIFY(model.setWalletLocked(true));
    model.setWalletUnlockStakingOnly(false);
    uint64_t overlapping_id{0};
    int overlap_prompts{0};
    unlock = QObject::connect(
        &model, &WalletModel::requireUnlock, &model, [&] {
            ++overlap_prompts;
            if (overlapping_id == 0) {
                overlapping_id =
                    model.requestPowClaimRecoveryOperation(make_execution());
            }
            QVERIFY(model.setWalletLocked(false, passphrase,
                                          /*staking_only=*/false));
        });
    const uint64_t first_id =
        model.requestPowClaimRecoveryOperation(make_execution());
    QTRY_VERIFY_WITH_TIMEOUT(overlapping_id != 0, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(results.count(first_id) == 1, 5000);
    QTRY_VERIFY_WITH_TIMEOUT(results.count(overlapping_id) == 1, 5000);
    QVERIFY(results.at(first_id)->core_entered);
    QVERIFY(results.at(overlapping_id)->busy_rejected);
    QVERIFY(!results.at(overlapping_id)->core_entered);
    QVERIFY(results.at(overlapping_id)->error.find("already in progress") !=
            std::string::npos);
    QCOMPARE(overlap_prompts, 1);
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Locked);
    QVERIFY(!model.getWalletUnlockStakingOnly());

    const uint64_t serialized_id =
        model.requestPowClaimRecoveryOperation(make_execution());
    QTRY_VERIFY_WITH_TIMEOUT(results.count(serialized_id) == 1, 5000);
    QVERIFY(results.at(serialized_id)->core_entered);
    QCOMPARE(overlap_prompts, 2);
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Locked);
    QVERIFY(!model.getWalletUnlockStakingOnly());
    QObject::disconnect(unlock);
    QObject::disconnect(ready);
}

void TestPowClaimRecoveryJoinCancelsQueuedMutation(
    interfaces::Node& node, const PlatformStyle* platform_style)
{
    auto wallet = std::make_shared<CWallet>(
        node.context()->chain.get(), "qt-claim-recovery-join-cancel",
        CreateMockableWalletDatabase());
    QCOMPARE(wallet->LoadWallet(), wallet::DBErrors::LOAD_OK);

    MiniGUI mini_gui(node, platform_style);
    mini_gui.initModelForWallet(node, wallet, platform_style);
    WalletModel& model = *mini_gui.walletModel;
    SyncRecoveryReviewWalletTip(wallet, node);
    const SecureString passphrase{"qt-claim-recovery-join-passphrase"};
    QVERIFY(wallet->EncryptWallet(passphrase));
    QVERIFY(model.setWalletLocked(false, passphrase,
                                  /*staking_only=*/true));

    interfaces::WalletPowClaimRecoveryRequest preview_request;
    const auto preview =
        model.wallet().getPowClaimRecoveryReview(preview_request);
    QVERIFY(preview.consistent);
    WalletModel::PowClaimRecoveryOperationRequest request;
    request.generation = 1;
    request.operation =
        WalletModel::PowClaimRecoveryOperationRequest::Operation::EXECUTE;
    request.recovery.mode =
        interfaces::WalletPowClaimRecoveryRequestMode::COMMIT_AND_BROADCAST;
    request.recovery.acknowledge_fee_and_conflict_risk = true;
    request.recovery.max_fee_per_resolution =
        preview.plan.max_fee_per_resolution;
    request.recovery.aggregate_batch_fee_cap =
        preview.plan.aggregate_batch_fee_cap;
    request.recovery.expected_plan_id = preview.plan.plan_id;

    std::shared_ptr<const WalletModel::PowClaimRecoveryOperationResult> result;
    uint64_t expected_id{0};
    QObject::connect(
        &model, &WalletModel::powClaimRecoveryOperationReady, &model,
        [&](quint64 request_id, quint64) {
            if (request_id == expected_id) {
                result = model.takePowClaimRecoveryOperationResult(request_id);
            }
        });
    QSignalSpy unlock_prompt(&model, &WalletModel::requireUnlock);
    expected_id = model.requestPowClaimRecoveryOperation(std::move(request));

    // join() runs before the queued unlock escalation. It must cancel the
    // operation token before stopping the worker; processing the queued GUI
    // callback afterward must yield a pre-Core cancellation, not a prompt or
    // a dispatch to the stopped thread.
    model.join();
    QTRY_VERIFY_WITH_TIMEOUT(result != nullptr, 5000);
    QVERIFY(result->cancelled);
    QVERIFY(!result->core_entered);
    QCOMPARE(unlock_prompt.count(), 0);
    QCOMPARE(model.getEncryptionStatus(), WalletModel::Unlocked);
    QVERIFY(model.getWalletUnlockStakingOnly());

    // Policy traffic uses the same stopped worker. It must fail closed via a
    // correlated result instead of invoking a null worker or retaining a
    // stale GUI policy after shutdown.
    std::shared_ptr<const WalletModel::PowClaimRecoveryPolicyResult>
        policy_result;
    uint64_t policy_id{0};
    QObject::connect(
        &model, &WalletModel::powClaimRecoveryPolicyReady, &model,
        [&](quint64 request_id, quint64) {
            if (request_id == policy_id) {
                policy_result =
                    model.takePowClaimRecoveryPolicyResult(request_id);
            }
        });
    WalletModel::PowClaimRecoveryPolicyRequest policy_request;
    policy_request.generation = 2;
    policy_id = model.requestPowClaimRecoveryPolicy(
        std::move(policy_request));
    QTRY_VERIFY_WITH_TIMEOUT(policy_result != nullptr, 5000);
    QVERIFY(policy_result->cancelled);
    QVERIFY(!policy_result->success);
    QVERIFY(!policy_result->policy_available);
}

void TestPowClaimRecoveryModelDestructionRestoresStakingScope(
    interfaces::Node& node, const PlatformStyle* platform_style)
{
    auto wallet = std::make_shared<CWallet>(
        node.context()->chain.get(), "qt-claim-recovery-prompt-destruction",
        CreateMockableWalletDatabase());
    QCOMPARE(wallet->LoadWallet(), wallet::DBErrors::LOAD_OK);

    MiniGUI mini_gui(node, platform_style);
    mini_gui.initModelForWallet(node, wallet, platform_style);
    WalletModel* const model = mini_gui.walletModel.get();
    SyncRecoveryReviewWalletTip(wallet, node);
    const SecureString passphrase{
        "qt-claim-recovery-prompt-destruction-passphrase"};
    QVERIFY(wallet->EncryptWallet(passphrase));
    QVERIFY(model->setWalletLocked(false, passphrase,
                                   /*staking_only=*/true));

    WalletContext& context = *node.walletLoader().context();
    auto observer = interfaces::MakeWallet(context, wallet);
    QVERIFY(observer->getWalletUnlockStakingOnly());
    QVERIFY(!observer->isLocked());

    interfaces::WalletPowClaimRecoveryRequest preview_request;
    const auto preview =
        model->wallet().getPowClaimRecoveryReview(preview_request);
    QVERIFY(preview.consistent);
    WalletModel::PowClaimRecoveryOperationRequest request;
    request.generation = 1;
    request.operation =
        WalletModel::PowClaimRecoveryOperationRequest::Operation::EXECUTE;
    request.recovery.mode =
        interfaces::WalletPowClaimRecoveryRequestMode::COMMIT_AND_BROADCAST;
    request.recovery.acknowledge_fee_and_conflict_risk = true;
    request.recovery.max_fee_per_resolution =
        preview.plan.max_fee_per_resolution;
    request.recovery.aggregate_batch_fee_cap =
        preview.plan.aggregate_batch_fee_cap;
    request.recovery.expected_plan_id = preview.plan.plan_id;

    bool prompt_seen{false};
    const QMetaObject::Connection destroy_during_prompt = QObject::connect(
        model, &WalletModel::requireUnlock, qApp, [&] {
            prompt_seen = true;
            mini_gui.sendCoinsDialog.setModel(nullptr);
            mini_gui.transactionView.setModel(nullptr);
            mini_gui.walletModel.reset();
        });
    QSignalSpy destroyed(model, &QObject::destroyed);
    model->requestPowClaimRecoveryOperation(std::move(request));
    QTRY_VERIFY_WITH_TIMEOUT(prompt_seen, 5000);
    QTRY_COMPARE_WITH_TIMEOUT(destroyed.count(), 1, 5000);
    QObject::disconnect(destroy_during_prompt);

    // Destruction happened synchronously after the escalation code locked the
    // wallet and before it could create a normal UnlockContext. join() must
    // still restore the pre-prompt staking-only scope marker rather than
    // silently leaving the wallet marked as a normal locked wallet.
    QVERIFY(observer->isLocked());
    QVERIFY(observer->getWalletUnlockStakingOnly());
}

void TestPowClaimRecoveryAmbiguousDatabaseDisablesActions(
    interfaces::Node& node, const PlatformStyle* platform_style)
{
    auto wallet = std::make_shared<CWallet>(
        node.context()->chain.get(), "qt-claim-recovery-ambiguous-database",
        CreateMockableWalletDatabase());
    QCOMPARE(wallet->LoadWallet(), wallet::DBErrors::LOAD_OK);

    MiniGUI mini_gui(node, platform_style);
    mini_gui.initModelForWallet(node, wallet, platform_style);
    WalletModel& model = *mini_gui.walletModel;
    const CBlockIndex* tip = WITH_LOCK(
        node.context()->chainman->GetMutex(),
        return node.context()->chainman->ActiveChain().Tip());
    QVERIFY(tip);
    {
        LOCK2(::cs_main, wallet->cs_wallet);
        wallet->SetLastBlockProcessed(tip->nHeight, tip->GetBlockHash());
    }
    interfaces::WalletPowClaimRecoveryPolicy automatic_policy;
    automatic_policy.mode =
        interfaces::WalletPowClaimRecoveryMode::AUTOMATIC;
    std::string policy_error;
    QVERIFY(model.wallet().setPowClaimRecoveryPolicy(
        automatic_policy, policy_error));
    {
        LOCK(wallet->cs_wallet);
        wallet->MarkShadowPowClaimRecoveryDatabaseAmbiguous();
    }

    interfaces::WalletPowClaimRecoveryRequest request;
    const auto review = model.wallet().getPowClaimRecoveryReview(request);
    QVERIFY(!review.consistent);
    QVERIFY(!review.error.empty());
    QVERIFY(!review.plan.complete);
    QVERIFY(std::any_of(
        review.plan.refused.begin(), review.plan.refused.end(),
        [](const auto& refused) {
            return refused.reason_code == "database-outcome-ambiguous";
        }));

    // A policy write with an ambiguous database outcome must not fall back
    // to the old in-memory policy and label it authoritative.
    std::shared_ptr<const WalletModel::PowClaimRecoveryPolicyResult>
        policy_result;
    uint64_t policy_id{0};
    const QMetaObject::Connection policy_ready = QObject::connect(
        &model, &WalletModel::powClaimRecoveryPolicyReady, &model,
        [&](quint64 request_id, quint64) {
            if (request_id == policy_id) {
                policy_result =
                    model.takePowClaimRecoveryPolicyResult(request_id);
            }
        });
    WalletModel::PowClaimRecoveryPolicyRequest policy_request;
    policy_request.generation = 1;
    policy_request.operation =
        WalletModel::PowClaimRecoveryPolicyRequest::Operation::SET_POLICY;
    policy_request.policy.mode =
        interfaces::WalletPowClaimRecoveryMode::PAUSE_AND_ASK;
    policy_id = model.requestPowClaimRecoveryPolicy(
        std::move(policy_request));
    QTRY_VERIFY_WITH_TIMEOUT(policy_result != nullptr, 5000);
    QVERIFY(policy_result->authoritative_state_checked);
    QVERIFY(policy_result->mutation_attempted);
    QVERIFY(!policy_result->success);
    QVERIFY(policy_result->mutation.durable_state_ambiguous);
    QVERIFY(!policy_result->mutation.authoritative_state_available);
    QVERIFY(!policy_result->policy_available);

    policy_result.reset();
    WalletModel::PowClaimRecoveryPolicyRequest policy_read;
    policy_read.generation = 1;
    policy_read.operation =
        WalletModel::PowClaimRecoveryPolicyRequest::Operation::INFO;
    policy_id = model.requestPowClaimRecoveryPolicy(std::move(policy_read));
    QTRY_VERIFY_WITH_TIMEOUT(policy_result != nullptr, 5000);
    QVERIFY(policy_result->authoritative_state_checked);
    QVERIFY(!policy_result->mutation_attempted);
    QVERIFY(!policy_result->success);
    QVERIFY(policy_result->mutation.durable_state_ambiguous);
    QVERIFY(!policy_result->policy_available);
    QObject::disconnect(policy_ready);

    // Adoption uses the same typed distinction: ambiguity is not collapsed
    // into an ordinary false/error result or reported as proven unchanged.
    std::shared_ptr<const WalletModel::PowClaimRecoveryOperationResult>
        adoption_result;
    uint64_t adoption_id{0};
    const QMetaObject::Connection adoption_ready = QObject::connect(
        &model, &WalletModel::powClaimRecoveryOperationReady, &model,
        [&](quint64 request_id, quint64) {
            if (request_id == adoption_id) {
                adoption_result =
                    model.takePowClaimRecoveryOperationResult(request_id);
            }
        });
    WalletModel::PowClaimRecoveryOperationRequest adoption_request;
    adoption_request.generation = 1;
    adoption_request.operation =
        WalletModel::PowClaimRecoveryOperationRequest::Operation::ADOPT;
    adoption_request.adoption_selector = std::string(64, '1');
    adoption_request.adoption_tip = std::string(64, '2');
    adoption_request.adoption_component_fingerprint = std::string(64, '3');
    adoption_id = model.requestPowClaimRecoveryOperation(
        std::move(adoption_request));
    QTRY_VERIFY_WITH_TIMEOUT(adoption_result != nullptr, 5000);
    QVERIFY(adoption_result->core_entered);
    QVERIFY(!adoption_result->success);
    QVERIFY(!adoption_result->adopted);
    QVERIFY(adoption_result->adoption.durable_state_ambiguous);
    QCOMPARE(
        adoption_result->adoption.status,
        interfaces::WalletPowClaimRecoveryAdoptionStatus::DATABASE_OUTCOME_AMBIGUOUS);

    // Closing or switching the originating view after the worker has been
    // dispatched but before GUI publication cannot suppress an authoritative
    // mutating result. The GUI-thread publication boundary rechecks the view
    // token and reports the ambiguous durable outcome application-wide.
    adoption_result.reset();
    QSignalSpy late_view_message(&model, &WalletModel::message);
    const auto stale_view = std::make_shared<std::atomic<bool>>(true);
    adoption_request = {};
    adoption_request.generation = 1;
    adoption_request.operation =
        WalletModel::PowClaimRecoveryOperationRequest::Operation::ADOPT;
    adoption_request.adoption_selector = std::string(64, '1');
    adoption_request.adoption_tip = std::string(64, '2');
    adoption_request.adoption_component_fingerprint = std::string(64, '3');
    adoption_request.view_current = stale_view;
    adoption_id = model.requestPowClaimRecoveryOperation(
        std::move(adoption_request));
    QTimer::singleShot(0, &model, [stale_view] {
        stale_view->store(false, std::memory_order_release);
    });
    QTRY_VERIFY_WITH_TIMEOUT(adoption_result != nullptr, 5000);
    QVERIFY(adoption_result->core_entered);
    QVERIFY(adoption_result->cancel_requested_after_core);
    QTRY_COMPARE_WITH_TIMEOUT(late_view_message.count(), 1, 5000);
    QVERIFY(late_view_message.at(0).at(1).toString().contains(
        QStringLiteral("indeterminate"), Qt::CaseInsensitive));
    QObject::disconnect(adoption_ready);

    StakingMiningPage page(platform_style);
    page.setClientModel(mini_gui.clientModel.get());
    page.setWalletModel(&model);
    page.show();
    qApp->processEvents();

    auto* automatic_policy_control = page.findChild<QCheckBox*>(
        QStringLiteral("automationClaimRecovery"));
    auto* automation_status = page.findChild<QLabel*>(
        QStringLiteral("automationStatus"));
    QVERIFY(automatic_policy_control);
    QVERIFY(automation_status);
    QTRY_VERIFY_WITH_TIMEOUT(
        automation_status->text().contains(
            QStringLiteral("outcome is ambiguous"), Qt::CaseInsensitive),
        5000);
    QVERIFY(!automatic_policy_control->isEnabled());
    QVERIFY(!automatic_policy_control->isChecked());

    // Detaching and reattaching the same live WalletModel is not a wallet
    // reload and therefore cannot clear the fail-closed ambiguity latch.
    page.setWalletModel(nullptr);
    page.setWalletModel(&model);
    QTRY_VERIFY_WITH_TIMEOUT(
        automation_status->text().contains(
            QStringLiteral("outcome is ambiguous"), Qt::CaseInsensitive),
        5000);
    QVERIFY(!automatic_policy_control->isEnabled());

    auto* open = page.findChild<QPushButton*>(
        QStringLiteral("powClaimRecoveryReview"));
    QVERIFY(open);
    QTest::mouseClick(open, Qt::LeftButton);
    QTRY_VERIFY_WITH_TIMEOUT(
        page.findChild<QDialog*>(QStringLiteral("powClaimRecoveryDialog")),
        5000);
    auto* dialog = page.findChild<QDialog*>(
        QStringLiteral("powClaimRecoveryDialog"));
    auto* resolve = dialog->findChild<QPushButton*>(
        QStringLiteral("powClaimRecoveryResolve"));
    auto* adopt = dialog->findChild<QPushButton*>(
        QStringLiteral("powClaimRecoveryAdopt"));
    auto* automatic = dialog->findChild<QPushButton*>(
        QStringLiteral("powClaimRecoveryEnableAutomatic"));
    auto* result = dialog->findChild<QLabel*>(
        QStringLiteral("powClaimRecoveryResult"));
    QVERIFY(resolve);
    QVERIFY(adopt);
    QVERIFY(automatic);
    QVERIFY(result);
    QTRY_VERIFY_WITH_TIMEOUT(
        result->text().contains(
            QStringLiteral("Exact transaction bytes or relay authority may already exist")),
        10000);
    QVERIFY(!resolve->isEnabled());
    QVERIFY(!adopt->isEnabled());
    QVERIFY(!automatic->isEnabled());
}

void TestStakingMiningPageSurvivesWalletModelDeletion(interfaces::Node& node, const std::shared_ptr<CWallet>& wallet, const PlatformStyle* platformStyle)
{
    MiniGUI mini_gui(node, platformStyle);
    mini_gui.initModelForWallet(node, wallet, platformStyle);

    WalletModel* wallet_model = mini_gui.walletModel.get();
    wallet_model->wallet().setEnabledStaking(true);

    StakingMiningPage page(platformStyle);
    page.setClientModel(mini_gui.clientModel.get());
    page.setWalletModel(wallet_model);
    page.show();
    qApp->processEvents();

    QCheckBox* staking_enable = page.findChild<QCheckBox*>("stakingEnable");
    QLabel* staking_status = page.findChild<QLabel*>("stakingStatus");
    QCheckBox* donation_enable = page.findChild<QCheckBox*>("qqDevelopmentDonationEnable");
    QSpinBox* donation_percent = page.findChild<QSpinBox*>("qqDevelopmentDonationPercent");
    QCheckBox* pow_enable = page.findChild<QCheckBox*>("powEnable");
    QLineEdit* pow_payout = page.findChild<QLineEdit*>("powPayout");
    QLabel* pow_status = page.findChild<QLabel*>("powStatus");

    QVERIFY(staking_enable);
    QVERIFY(staking_status);
    QVERIFY(donation_enable);
    QVERIFY(donation_percent);
    QVERIFY(pow_enable);
    QVERIFY(pow_payout);
    QVERIFY(pow_status);
    QVERIFY(staking_enable->isEnabled());
    QVERIFY(staking_enable->isChecked());

    mini_gui.walletModel.reset();
    qApp->processEvents();

    QVERIFY(QMetaObject::invokeMethod(&page, "updateStatus", Qt::DirectConnection));
    QCOMPARE(staking_enable->isChecked(), false);
    QCOMPARE(staking_status->text(), QString("No wallet loaded"));
    QVERIFY(!staking_enable->isEnabled());
    QVERIFY(!donation_enable->isEnabled());
    QVERIFY(!donation_percent->isEnabled());
    QVERIFY(!pow_enable->isEnabled());
    QVERIFY(pow_payout->text().isEmpty());
    QVERIFY(pow_status->text().contains(QString("Load a wallet")));
}

void TestStakingMiningPayoutClearsAcrossWalletIdentity(
    interfaces::Node& node,
    const std::shared_ptr<CWallet>& wallet_a,
    const PlatformStyle* platform_style)
{
    auto wallet_b = std::make_shared<CWallet>(
        node.context()->chain.get(), "qt-staking-payout-wallet-b",
        CreateMockableWalletDatabase());
    QCOMPARE(wallet_b->LoadWallet(), wallet::DBErrors::LOAD_OK);
    SyncRecoveryReviewWalletTip(wallet_b, node);

    MiniGUI mini_gui_a(node, platform_style);
    mini_gui_a.initModelForWallet(node, wallet_a, platform_style);
    MiniGUI mini_gui_b(node, platform_style);
    mini_gui_b.initModelForWallet(node, wallet_b, platform_style);
    QVERIFY(mini_gui_b.walletModel->wallet()
                .getPowMiningInfo()
                .payout_address.empty());

    StakingMiningPage page(platform_style);
    page.setClientModel(mini_gui_a.clientModel.get());
    page.setWalletModel(mini_gui_a.walletModel.get());
    page.show();
    qApp->processEvents();

    auto* pow_payout = page.findChild<QLineEdit*>(
        QStringLiteral("powPayout"));
    auto* pow_copy = page.findChild<QPushButton*>(
        QStringLiteral("powCopy"));
    auto* refresh = page.findChild<QPushButton*>(
        QStringLiteral("stakingMiningRefresh"));
    auto* refresh_hint = page.findChild<QLabel*>(
        QStringLiteral("stakingMiningRefreshHint"));
    QVERIFY(pow_payout);
    QVERIFY(pow_copy);
    QVERIFY(refresh);
    QVERIFY(refresh_hint);

    pow_payout->setText(QStringLiteral("wallet-a-payout"));
    QVERIFY(QMetaObject::invokeMethod(
        &page, "updateStatus", Qt::DirectConnection));
    QVERIFY(pow_copy->isEnabled());

    // A direct A -> B switch must revoke display and copy authority before an
    // event-loop turn or background detail refresh can expose wallet B.
    page.setWalletModel(mini_gui_b.walletModel.get());
    QVERIFY(pow_payout->text().isEmpty());
    QVERIFY(!pow_copy->isEnabled());

    // An accepted empty snapshot is equally authoritative. Seed obsolete UI
    // text after the switch so this assertion also detects a conditional
    // snapshot assignment that would preserve a previous value.
    pow_payout->setText(QStringLiteral("obsolete-wallet-b-payout"));
    QVERIFY(QMetaObject::invokeMethod(
        &page, "updateStatus", Qt::DirectConnection));
    QVERIFY(pow_copy->isEnabled());
    refresh->click();
    QTRY_VERIFY_WITH_TIMEOUT(
        refresh_hint->text().contains(QStringLiteral("Detail panels updated")),
        20000);
    QVERIFY(pow_payout->text().isEmpty());
    QVERIFY(!pow_copy->isEnabled());

    page.setWalletModel(nullptr);
}

void TestStakingMiningHeartbeatDoesNotWaitForWalletMutex(interfaces::Node& node, const PlatformStyle* platformStyle)
{
    auto wallet = std::make_shared<CWallet>(node.context()->chain.get(), "qt-staking-heartbeat", CreateMockableWalletDatabase());
    QCOMPARE(wallet->LoadWallet(), wallet::DBErrors::LOAD_OK);

    MiniGUI mini_gui(node, platformStyle);
    mini_gui.initModelForWallet(node, wallet, platformStyle);
    WalletModel& wallet_model = *mini_gui.walletModel;

    // The cache is initialized before the first view heartbeat, then refreshed
    // by every encrypt, unlock, and lock notification.
    QCOMPARE(wallet_model.getCachedEncryptionStatus(), WalletModel::Unencrypted);
    QVERIFY(wallet->EncryptWallet("qt-heartbeat-passphrase"));
    QTRY_COMPARE_WITH_TIMEOUT(wallet_model.getCachedEncryptionStatus(), WalletModel::Locked, 1000);
    QVERIFY(wallet->Unlock("qt-heartbeat-passphrase"));
    QTRY_COMPARE_WITH_TIMEOUT(wallet_model.getCachedEncryptionStatus(), WalletModel::Unlocked, 1000);

    // Cached state is display-only. Before the queued lock notification is
    // delivered, the backend must still reject a sensitive operation by
    // consulting the live wallet lock.
    QVERIFY(wallet->Lock());
    QCOMPARE(wallet_model.getCachedEncryptionStatus(), WalletModel::Unlocked);
    std::string mining_error;
    QVERIFY(!wallet_model.wallet().setPowMining(true, 1, 1, mining_error));
    QVERIFY(mining_error.find("unlocked wallet") != std::string::npos);
    QTRY_COMPARE_WITH_TIMEOUT(wallet_model.getCachedEncryptionStatus(), WalletModel::Locked, 1000);

    StakingMiningPage page(platformStyle);
    page.setClientModel(mini_gui.clientModel.get());
    page.setWalletModel(&wallet_model);
    page.show();
    qApp->processEvents();

    std::promise<void> mutex_held;
    std::future<void> mutex_held_future = mutex_held.get_future();
    std::thread holder([&] {
        LOCK(wallet->cs_wallet);
        mutex_held.set_value();
        std::this_thread::sleep_for(std::chrono::milliseconds{500});
    });
    mutex_held_future.wait();

    QElapsedTimer status_timer;
    status_timer.start();
    wallet_model.updateStatus();
    const qint64 status_elapsed_ms = status_timer.elapsed();

    QElapsedTimer heartbeat_timer;
    heartbeat_timer.start();
    const bool invoked = QMetaObject::invokeMethod(&page, "updateStatus", Qt::DirectConnection);
    const qint64 heartbeat_elapsed_ms = heartbeat_timer.elapsed();
    holder.join();

    QVERIFY(invoked);
    QVERIFY2(status_elapsed_ms < 100,
             qPrintable(QStringLiteral("Wallet status callback waited %1 ms for cs_wallet").arg(status_elapsed_ms)));
    QVERIFY2(heartbeat_elapsed_ms < 100,
             qPrintable(QStringLiteral("Staking page heartbeat waited %1 ms for cs_wallet").arg(heartbeat_elapsed_ms)));
}

void TestStakingMiningAsyncRefreshLifecycle(interfaces::Node& node, const PlatformStyle* platformStyle)
{
    auto wallet = std::make_shared<CWallet>(node.context()->chain.get(), "qt-staking-async-refresh", CreateMockableWalletDatabase());
    QCOMPARE(wallet->LoadWallet(), wallet::DBErrors::LOAD_OK);

    MiniGUI mini_gui(node, platformStyle);
    mini_gui.initModelForWallet(node, wallet, platformStyle);
    WalletModel& wallet_model = *mini_gui.walletModel;

    auto page = std::make_unique<StakingMiningPage>(platformStyle);
    page->setClientModel(mini_gui.clientModel.get());
    page->setWalletModel(&wallet_model);
    page->show();
    qApp->processEvents();

    QPushButton* refresh = page->findChild<QPushButton*>("stakingMiningRefresh");
    QLabel* refresh_hint = page->findChild<QLabel*>("stakingMiningRefreshHint");
    QLabel* staking_status = page->findChild<QLabel*>("stakingStatus");
    QVERIFY(refresh);
    QVERIFY(refresh_hint);
    QVERIFY(staking_status);

    QSignalSpy ready_spy(&wallet_model, &WalletModel::stakingMiningSnapshotReady);

    // A result built for any other tip must be marked stale before wallet
    // detail calls run, and must remain an immutable, inspectable result.
    WalletModel::StakingMiningSnapshotRequest stale_request;
    stale_request.request_id = 1000000;
    stale_request.generation = 1000000;
    stale_request.expected_tip = std::string(64, 'f');
    wallet_model.requestStakingMiningSnapshot(stale_request);
    QTRY_COMPARE_WITH_TIMEOUT(ready_spy.count(), 1, 5000);
    const std::shared_ptr<const WalletModel::StakingMiningSnapshot> stale_snapshot =
        wallet_model.takeStakingMiningSnapshot(stale_request.request_id);
    QVERIFY(stale_snapshot);
    QVERIFY(stale_snapshot->stale_tip);
    ready_spy.clear();

    std::promise<void> first_lock_held;
    std::promise<void> release_first_lock;
    std::shared_future<void> first_release = release_first_lock.get_future().share();
    std::thread first_holder([&] {
        LOCK(wallet->cs_wallet);
        first_lock_held.set_value();
        first_release.wait();
    });
    first_lock_held.get_future().wait();

    QElapsedTimer click_timer;
    click_timer.start();
    refresh->click();
    const qint64 click_elapsed_ms = click_timer.elapsed();

    // Give WalletWorker time to reach a wallet read while keeping the GUI
    // event queue free. A queued heartbeat must still run immediately.
    std::this_thread::sleep_for(std::chrono::milliseconds{50});
    bool heartbeat_seen{false};
    QTimer::singleShot(0, page.get(), [&] { heartbeat_seen = true; });
    QElapsedTimer heartbeat_timer;
    heartbeat_timer.start();
    qApp->processEvents(QEventLoop::AllEvents, 50);
    const qint64 heartbeat_elapsed_ms = heartbeat_timer.elapsed();

    // Repeated refreshes while the worker is occupied must not create a queue
    // of full wallet scans. They collapse to one pending latest request.
    for (int i = 0; i < 20; ++i) refresh->click();
    const bool queued_hint_seen = refresh_hint->text().contains(QString("queued"));

    QElapsedTimer switch_timer;
    switch_timer.start();
    page->setWalletModel(nullptr);
    const qint64 switch_elapsed_ms = switch_timer.elapsed();
    release_first_lock.set_value();
    first_holder.join();

    QTRY_COMPARE_WITH_TIMEOUT(ready_spy.count(), 1, 5000);
    const uint64_t first_request_id = ready_spy.at(0).at(0).toULongLong();
    const std::shared_ptr<const WalletModel::StakingMiningSnapshot> cancelled =
        wallet_model.takeStakingMiningSnapshot(first_request_id);
    QVERIFY(cancelled);
    QVERIFY(cancelled->cancelled);
    QVERIFY(queued_hint_seen);
    QCOMPARE(staking_status->text(), QString("No wallet loaded"));

    // Reattach and prove that destroying the page also performs bounded,
    // cooperative cancellation without waiting for the worker-held request.
    page->setWalletModel(&wallet_model);
    qApp->processEvents();
    refresh = page->findChild<QPushButton*>("stakingMiningRefresh");
    QVERIFY(refresh);

    std::promise<void> second_lock_held;
    std::promise<void> release_second_lock;
    std::shared_future<void> second_release = release_second_lock.get_future().share();
    std::thread second_holder([&] {
        LOCK(wallet->cs_wallet);
        second_lock_held.set_value();
        second_release.wait();
    });
    second_lock_held.get_future().wait();
    refresh->click();
    std::this_thread::sleep_for(std::chrono::milliseconds{50});

    QElapsedTimer destroy_timer;
    destroy_timer.start();
    page.reset();
    const qint64 destroy_elapsed_ms = destroy_timer.elapsed();
    release_second_lock.set_value();
    second_holder.join();

    QTRY_COMPARE_WITH_TIMEOUT(ready_spy.count(), 2, 5000);

    QVERIFY2(click_elapsed_ms < 100,
             qPrintable(QStringLiteral("Full-detail click blocked the GUI for %1 ms").arg(click_elapsed_ms)));
    QVERIFY(heartbeat_seen);
    QVERIFY2(heartbeat_elapsed_ms < 100,
             qPrintable(QStringLiteral("GUI heartbeat was delayed %1 ms during full refresh").arg(heartbeat_elapsed_ms)));
    QVERIFY2(switch_elapsed_ms < 100,
             qPrintable(QStringLiteral("Wallet switch waited %1 ms for full refresh").arg(switch_elapsed_ms)));
    QVERIFY2(destroy_elapsed_ms < 100,
             qPrintable(QStringLiteral("Page destruction waited %1 ms for full refresh").arg(destroy_elapsed_ms)));
}

void TestWalletPagesScale(MiniGUI& mini_gui, const PlatformStyle* platformStyle)
{
    TransactionView& transaction_view = mini_gui.transactionView;
    transaction_view.resize(480, 320);
    transaction_view.show();
    qApp->processEvents();

    auto* table = transaction_view.findChild<QTableView*>(QStringLiteral("transactionView"));
    QVERIFY(table);
    QVERIFY(table->isVisible());
    QVERIFY(transaction_view.minimumSizeHint().width() <= 480);
    transaction_view.hide();

    WalletView wallet_view(mini_gui.walletModel.get(), platformStyle, nullptr);
    wallet_view.setClientModel(mini_gui.clientModel.get());
    wallet_view.resize(640, 480);
    wallet_view.show();
    wallet_view.gotoHistoryPage();
    qApp->processEvents();

    QVERIFY(wallet_view.findChild<QTableView*>(QStringLiteral("transactionView")));
    QVERIFY(wallet_view.minimumSizeHint().width() <= 640);

    QElapsedTimer staking_page_timer;
    staking_page_timer.start();
    wallet_view.gotoStakingMiningPage();
    qApp->processEvents();
    QVERIFY2(staking_page_timer.elapsed() < 5000, "Staking/Mining page switch exceeded 5 seconds");
    auto* staking_scroll = wallet_view.findChild<QScrollArea*>(QStringLiteral("stakingMiningScrollPage"));
    QVERIFY(staking_scroll);
    QCOMPARE(wallet_view.currentWidget(), staking_scroll);
    wallet_view.hide();
}

//! Simple qt wallet tests.
//
// Test widgets can be debugged interactively calling show() on them and
// manually running the event loop, e.g.:
//
//     sendCoinsDialog.show();
//     QEventLoop().exec();
//
// This also requires overriding the default minimal Qt platform:
//
//     QT_QPA_PLATFORM=xcb     src/qt/test/test_blackcoin-qt  # Linux
//     QT_QPA_PLATFORM=windows src/qt/test/test_blackcoin-qt  # Windows
//     QT_QPA_PLATFORM=cocoa   src/qt/test/test_blackcoin-qt  # macOS
void TestGUI(interfaces::Node& node, const std::shared_ptr<CWallet>& wallet)
{
    // Create widgets for sending coins and listing transactions.
    std::unique_ptr<const PlatformStyle> platformStyle(PlatformStyle::instantiate("other"));
    HelpMessageDialog about_dialog(/*parent=*/nullptr, /*about=*/true);
    QLabel* about_message = about_dialog.findChild<QLabel*>("aboutMessage");
    QVERIFY(about_message);
    const QString expected_source_identity = QString::fromStdString(FormatSourceIdentity());
    QVERIFY(about_message->text().contains(GUIUtil::HtmlEscape(expected_source_identity)));
    QVERIFY(expected_source_identity.startsWith(QStringLiteral("Source commit: ")));
    if (IsSourceTreeDirty() || FormatSourceCommit().empty()) {
        QVERIFY(about_message->text().contains(QStringLiteral("color:#b00020")));
    }

    MiniGUI mini_gui(node, platformStyle.get());
    mini_gui.initModelForWallet(node, wallet, platformStyle.get());
    WalletModel& walletModel = *mini_gui.walletModel;
    SendCoinsDialog& sendCoinsDialog = mini_gui.sendCoinsDialog;

    TestStakingMiningPageControls(mini_gui, wallet, platformStyle.get());
    TestPowClaimRecoveryPolicyControls(node, mini_gui, wallet, platformStyle.get());
    TestPowClaimRecoveryStakingOnlyRequiresFullUnlock(node, platformStyle.get());
    TestPowClaimRecoveryJoinCancelsQueuedMutation(node, platformStyle.get());
    TestPowClaimRecoveryModelDestructionRestoresStakingScope(
        node, platformStyle.get());
    TestPowClaimRecoveryAmbiguousDatabaseDisablesActions(node, platformStyle.get());
    TestWalletPagesScale(mini_gui, platformStyle.get());
    TestStakingMiningPageSurvivesWalletModelDeletion(node, wallet, platformStyle.get());
    TestStakingMiningPayoutClearsAcrossWalletIdentity(
        node, wallet, platformStyle.get());
    TestStakingMiningHeartbeatDoesNotWaitForWalletMutex(node, platformStyle.get());
    TestStakingMiningAsyncRefreshLifecycle(node, platformStyle.get());

    // Update walletModel cached balance which will trigger an update for the 'labelBalance' QLabel.
    walletModel.pollBalanceChanged();
    // Check balance in send dialog
    CompareBalance(walletModel, walletModel.wallet().getBalance(), sendCoinsDialog.findChild<QLabel*>("labelBalance"));

    // Check 'UseAvailableBalance' functionality
    VerifyUseAvailableBalance(sendCoinsDialog, walletModel);

    // Send two transactions, and verify they are added to transaction list.
    TransactionTableModel* transactionTableModel = walletModel.getTransactionTableModel();
    QCOMPARE(transactionTableModel->rowCount({}), 105);
    // Blackcoin
    uint256 txid1 = SendCoins(*wallet.get(), sendCoinsDialog, PKHash(), 5 * COIN);
    uint256 txid2 = SendCoins(*wallet.get(), sendCoinsDialog, PKHash(), 10 * COIN);
    // Transaction table model updates on a QueuedConnection, so process events to ensure it's updated.
    qApp->processEvents();
    QCOMPARE(transactionTableModel->rowCount({}), 107);
    QVERIFY(FindTx(*transactionTableModel, txid1).isValid());
    QVERIFY(FindTx(*transactionTableModel, txid2).isValid());

    // Blackcoin
    // Call bumpfee. Test disabled, canceled, enabled, then failing cases.
    // BumpFee(transactionView, txid1, /*expectDisabled=*/true, /*expectError=*/"not BIP 125 replaceable", /*cancel=*/false);
    // BumpFee(transactionView, txid2, /*expectDisabled=*/false, /*expectError=*/{}, /*cancel=*/true);
    // BumpFee(transactionView, txid2, /*expectDisabled=*/false, /*expectError=*/{}, /*cancel=*/false);
    // BumpFee(transactionView, txid2, /*expectDisabled=*/true, /*expectError=*/"already bumped", /*cancel=*/false);

    // Check current balance on OverviewPage
    OverviewPage overviewPage(platformStyle.get());
    overviewPage.setWalletModel(&walletModel);
    walletModel.pollBalanceChanged(); // Manual balance polling update
    CompareBalance(walletModel, walletModel.wallet().getBalance(), overviewPage.findChild<QLabel*>("labelBalance"));

    // Check Request Payment button
    ReceiveCoinsDialog receiveCoinsDialog(platformStyle.get());
    receiveCoinsDialog.setModel(&walletModel);
    RecentRequestsTableModel* requestTableModel = walletModel.getRecentRequestsTableModel();

    // Label input
    QLineEdit* labelInput = receiveCoinsDialog.findChild<QLineEdit*>("reqLabel");
    labelInput->setText("TEST_LABEL_1");

    // Amount input
    BitcoinAmountField* amountInput = receiveCoinsDialog.findChild<BitcoinAmountField*>("reqAmount");
    amountInput->setValue(1);

    // Message input
    QLineEdit* messageInput = receiveCoinsDialog.findChild<QLineEdit*>("reqMessage");
    messageInput->setText("TEST_MESSAGE_1");
    QComboBox* addressType = receiveCoinsDialog.findChild<QComboBox*>("addressType");
    QVERIFY(addressType);
    QLabel* receive_type_notice = receiveCoinsDialog.findChild<QLabel*>("label_5");
    QVERIFY(receive_type_notice);
    QVERIFY(addressType->currentText().contains(QString("Legacy Blackcoin")));
    QVERIFY(receive_type_notice->text().contains(QString("Legacy Blackcoin address")));
    int initialRowCount = requestTableModel->rowCount({});
    QPushButton* requestPaymentButton = receiveCoinsDialog.findChild<QPushButton*>("receiveButton");
    requestPaymentButton->click();
    QString address;
    for (QWidget* widget : QApplication::topLevelWidgets()) {
        if (widget->inherits("ReceiveRequestDialog")) {
            ReceiveRequestDialog* receiveRequestDialog = qobject_cast<ReceiveRequestDialog*>(widget);
            QCOMPARE(receiveRequestDialog->QObject::findChild<QLabel*>("payment_header")->text(), QString("Payment information"));
            QCOMPARE(receiveRequestDialog->QObject::findChild<QLabel*>("uri_tag")->text(), QString("URI:"));
            QString uri = receiveRequestDialog->QObject::findChild<QLabel*>("uri_content")->text();
            QCOMPARE(uri.count("blackcoin:"), 2);
            QCOMPARE(receiveRequestDialog->QObject::findChild<QLabel*>("address_tag")->text(), QString("Address:"));
            QVERIFY(address.isEmpty());
            address = receiveRequestDialog->QObject::findChild<QLabel*>("address_content")->text();
            QVERIFY(!address.isEmpty());

            QCOMPARE(uri.count("amount=0.00000001"), 2);
            QCOMPARE(receiveRequestDialog->QObject::findChild<QLabel*>("amount_tag")->text(), QString("Amount:"));
            QCOMPARE(receiveRequestDialog->QObject::findChild<QLabel*>("amount_content")->text(), QString::fromStdString("0.00000001 " + CURRENCY_UNIT));

            QCOMPARE(uri.count("label=TEST_LABEL_1"), 2);
            QCOMPARE(receiveRequestDialog->QObject::findChild<QLabel*>("label_tag")->text(), QString("Label:"));
            QCOMPARE(receiveRequestDialog->QObject::findChild<QLabel*>("label_content")->text(), QString("TEST_LABEL_1"));

            QCOMPARE(uri.count("message=TEST_MESSAGE_1"), 2);
            QCOMPARE(receiveRequestDialog->QObject::findChild<QLabel*>("message_tag")->text(), QString("Message:"));
            QCOMPARE(receiveRequestDialog->QObject::findChild<QLabel*>("message_content")->text(), QString("TEST_MESSAGE_1"));
            receiveRequestDialog->close();
        }
    }

    // Clear button
    QPushButton* clearButton = receiveCoinsDialog.findChild<QPushButton*>("clearButton");
    clearButton->click();
    QCOMPARE(labelInput->text(), QString(""));
    QCOMPARE(amountInput->value(), CAmount(0));
    QCOMPARE(messageInput->text(), QString(""));

    // Check addition to history
    int currentRowCount = requestTableModel->rowCount({});
    QCOMPARE(currentRowCount, initialRowCount+1);

    // Check addition to wallet
    std::vector<std::string> requests = walletModel.wallet().getAddressReceiveRequests();
    QCOMPARE(requests.size(), size_t{1});
    RecentRequestEntry entry;
    DataStream{MakeUCharSpan(requests[0])} >> entry;
    QCOMPARE(entry.nVersion, int{1});
    QCOMPARE(entry.id, int64_t{1});
    QVERIFY(entry.date.isValid());
    QCOMPARE(entry.recipient.address, address);
    QCOMPARE(entry.recipient.label, QString{"TEST_LABEL_1"});
    QCOMPARE(entry.recipient.amount, CAmount{1});
    QCOMPARE(entry.recipient.message, QString{"TEST_MESSAGE_1"});
    QCOMPARE(entry.recipient.sPaymentRequest, std::string{});
    QCOMPARE(entry.recipient.authenticatedMerchant, QString{});

    // Check Remove button
    QTableView* table = receiveCoinsDialog.findChild<QTableView*>("recentRequestsView");
    table->selectRow(currentRowCount-1);
    QPushButton* removeRequestButton = receiveCoinsDialog.findChild<QPushButton*>("removeRequestButton");
    removeRequestButton->click();
    QCOMPARE(requestTableModel->rowCount({}), currentRowCount-1);

    // Check removal from wallet
    QCOMPARE(walletModel.wallet().getAddressReceiveRequests().size(), size_t{0});

    const int quantum_index = addressType->findText(QString("Quantum-resistant ML-DSA (upgraded wallet)"));
    QVERIFY(quantum_index >= 0);
    addressType->setCurrentIndex(quantum_index);
    QVERIFY(receive_type_notice->text().contains(QString("Quantum-resistant ML-DSA address")));
    QCOMPARE(requestPaymentButton->text(), QString("Create quantum ML-DSA address"));
    labelInput->setText("TEST_QUANTUM_LABEL");
    amountInput->clear();
    messageInput->setText("TEST_QUANTUM_MESSAGE");
    requestPaymentButton->click();
    qApp->processEvents();

    QString quantum_address;
    for (QWidget* widget : QApplication::topLevelWidgets()) {
        if (widget->inherits("ReceiveRequestDialog")) {
            ReceiveRequestDialog* receiveRequestDialog = qobject_cast<ReceiveRequestDialog*>(widget);
            if (receiveRequestDialog->QObject::findChild<QLabel*>("label_content")->text() == QString("TEST_QUANTUM_LABEL")) {
                quantum_address = receiveRequestDialog->QObject::findChild<QLabel*>("address_content")->text();
            }
            receiveRequestDialog->close();
        }
    }
    QVERIFY(!quantum_address.isEmpty());
    const CTxDestination quantum_dest = DecodeDestination(quantum_address.toStdString());
    QVERIFY(IsValidDestination(quantum_dest));
    QVERIFY(IsQuantumMigrationDestination(quantum_dest));
    QCOMPARE(requestTableModel->rowCount({}), initialRowCount + 1);

    requests = walletModel.wallet().getAddressReceiveRequests();
    QCOMPARE(requests.size(), size_t{1});
    DataStream{MakeUCharSpan(requests[0])} >> entry;
    QCOMPARE(entry.recipient.address, quantum_address);
    QCOMPARE(entry.recipient.label, QString{"TEST_QUANTUM_LABEL"});
    QCOMPARE(entry.recipient.message, QString{"TEST_QUANTUM_MESSAGE"});
}

void TestGUIWatchOnly(interfaces::Node& node, TestChain100Setup& test)
{
    const std::shared_ptr<CWallet>& wallet = SetupLegacyWatchOnlyWallet(node, test);

    // Create widgets and init models
    std::unique_ptr<const PlatformStyle> platformStyle(PlatformStyle::instantiate("other"));
    MiniGUI mini_gui(node, platformStyle.get());
    mini_gui.initModelForWallet(node, wallet, platformStyle.get());
    WalletModel& walletModel = *mini_gui.walletModel;
    SendCoinsDialog& sendCoinsDialog = mini_gui.sendCoinsDialog;

    // Update walletModel cached balance which will trigger an update for the 'labelBalance' QLabel.
    walletModel.pollBalanceChanged();
    // Check balance in send dialog
    CompareBalance(walletModel, walletModel.wallet().getBalances().watch_only_balance,
                   sendCoinsDialog.findChild<QLabel*>("labelBalance"));

    // Set change address
    sendCoinsDialog.getCoinControl()->destChange = GetDestinationForKey(test.coinbaseKey.GetPubKey(), OutputType::LEGACY);

    // Time to reject "save" PSBT dialog ('SendCoins' locks the main thread until the dialog receives the event).
    QTimer timer;
    timer.setInterval(500);
    QObject::connect(&timer, &QTimer::timeout, [&](){
        for (QWidget* widget : QApplication::topLevelWidgets()) {
            if (widget->inherits("QMessageBox")) {
                QMessageBox* dialog = qobject_cast<QMessageBox*>(widget);
                QAbstractButton* button = dialog->button(QMessageBox::Discard);
                button->setEnabled(true);
                button->click();
                timer.stop();
                break;
            }
        }
    });
    timer.start(500);

    // Send tx and verify PSBT copied to the clipboard.
    // Blackcoin
    SendCoins(*wallet.get(), sendCoinsDialog, PKHash(), 5 * COIN, QMessageBox::Save);
    const std::string& psbt_string = QApplication::clipboard()->text().toStdString();
    QVERIFY(!psbt_string.empty());

    // Decode psbt
    std::optional<std::vector<unsigned char>> decoded_psbt = DecodeBase64(psbt_string);
    QVERIFY(decoded_psbt);
    PartiallySignedTransaction psbt;
    std::string err;
    QVERIFY(DecodeRawPSBT(psbt, MakeByteSpan(*decoded_psbt), err));

    // Use a dedicated synced wallet so the real recovery/adoption route does
    // not depend on coin-control locks or mutate the shared GUI fixture.
    TestPowClaimRecoveryManualDialog(
        node, test.coinbaseKey, platformStyle.get());
}

void TestGUI(interfaces::Node& node)
{
    // Set up wallet and chain with 105 blocks (5 mature blocks for spending).
    TestChain100Setup test;
    for (int i = 0; i < 5; ++i) {
        test.CreateAndProcessBlock({}, GetScriptForRawPubKey(test.coinbaseKey.GetPubKey()));
    }
    auto wallet_loader = interfaces::MakeWalletLoader(*test.m_node.chain, *Assert(test.m_node.args));
    test.m_node.wallet_loader = wallet_loader.get();
    node.setContext(&test.m_node);

    // "Full" GUI tests, use descriptor wallet
    const std::shared_ptr<CWallet>& desc_wallet = SetupDescriptorsWallet(node, test);
    TestGUI(node, desc_wallet);

    // Legacy watch-only wallet test
    // Verify PSBT creation.
    TestGUIWatchOnly(node, test);
}

void TestQuantumFundingControlsFollowReorg(interfaces::Node& node)
{
    const std::vector<const char*> phase_args{
        "-regtest",
        "-shadowwhitelistheight=20",
        "-shadowgoldrushstartheight=30",
        "-shadowgoldrushendheight=106",
        "-qqgoldrushendheight=106",
        "-qqmigrationendheight=109",
        "-qqstaketierheight=108",
    };
    TestChain100Setup test{ChainType::REGTEST, phase_args};
    for (int i = 0; i < 5; ++i) {
        test.CreateAndProcessBlock({}, GetScriptForRawPubKey(test.coinbaseKey.GetPubKey()));
    }

    auto wallet_loader = interfaces::MakeWalletLoader(*test.m_node.chain, *Assert(test.m_node.args));
    test.m_node.wallet_loader = wallet_loader.get();
    node.setContext(&test.m_node);

    std::unique_ptr<const PlatformStyle> platform_style(PlatformStyle::instantiate("other"));
    const std::shared_ptr<CWallet>& wallet = SetupDescriptorsWallet(node, test);
    MiniGUI mini_gui(node, platform_style.get());
    mini_gui.initModelForWallet(node, wallet, platform_style.get());

    interfaces::Wallet& wallet_interface = mini_gui.walletModel->wallet();
    auto selfstake_result = wallet_interface.createQuantumStakeAddress("reorg-selfstake", 9450);
    QVERIFY(selfstake_result);
    auto operator_result = wallet_interface.createQuantumStakeAddress("coldstake-operator", 40500);
    QVERIFY(operator_result);
    auto staker_result = wallet_interface.createQuantumAddress("reorg-coldstake-staker");
    QVERIFY(staker_result);
    auto liquid_coldstake_result = wallet_interface.createQuantumColdStakeAddress(
        staker_result->public_key, "reorg-liquid-coldstake", 0);
    QVERIFY(liquid_coldstake_result);
    auto tiered_coldstake_result = wallet_interface.createQuantumColdStakeAddress(
        staker_result->public_key, "reorg-tiered-coldstake", 9450);
    QVERIFY(tiered_coldstake_result);

    StakingMiningPage page(platform_style.get());
    page.setClientModel(mini_gui.clientModel.get());
    page.setWalletModel(mini_gui.walletModel.get());
    page.show();
    qApp->processEvents();

    QPushButton* migration_legacy_sweep = page.findChild<QPushButton*>("migrationLegacySweep");
    QPushButton* migration_goldrush_sweep = page.findChild<QPushButton*>("migrationGoldrushSweep");
    QLineEdit* selfstake_address = page.findChild<QLineEdit*>("selfStakeAddress");
    BitcoinAmountField* selfstake_fund_amount = page.findChild<BitcoinAmountField*>("selfStakeFundAmount");
    QPushButton* selfstake_fund = page.findChild<QPushButton*>("selfStakeFund");
    QLineEdit* operator_address = page.findChild<QLineEdit*>("coldstakeOperatorAddress");
    BitcoinAmountField* operator_bond_amount = page.findChild<BitcoinAmountField*>("coldstakeOperatorBondAmount");
    QPushButton* operator_fund = page.findChild<QPushButton*>("coldstakeOperatorFund");
    QLineEdit* coldstake_address = page.findChild<QLineEdit*>("coldstakeAddress");
    BitcoinAmountField* coldstake_fund_amount = page.findChild<BitcoinAmountField*>("coldstakeFundAmount");
    QVERIFY(migration_legacy_sweep);
    QVERIFY(migration_goldrush_sweep);
    QVERIFY(selfstake_address);
    QVERIFY(selfstake_fund_amount);
    QVERIFY(selfstake_fund);
    QVERIFY(operator_address);
    QVERIFY(operator_bond_amount);
    QVERIFY(operator_fund);
    QVERIFY(coldstake_address);
    QVERIFY(coldstake_fund_amount);

    selfstake_address->setText(QString::fromStdString(selfstake_result->address));
    operator_address->setText(QString::fromStdString(operator_result->address));
    coldstake_address->setText(QString::fromStdString(tiered_coldstake_result->address));

    const auto height = [&] {
        return WITH_LOCK(test.m_node.chainman->GetMutex(), return test.m_node.chainman->ActiveChain().Height());
    };
    const auto update_controls = [&] {
        QVERIFY(QMetaObject::invokeMethod(&page, "updateStatus", Qt::DirectConnection));
        qApp->processEvents();
    };
    const auto expect_controls = [&](int expected_height, bool quantum_active, bool legacy_active, bool tiers_active) {
        QCOMPARE(height(), expected_height);
        const interfaces::WalletQuantumFundingStatus status = wallet_interface.getQuantumFundingStatus();
        QVERIFY(status.available);
        QCOMPARE(status.quantum_outputs_active, quantum_active);
        QCOMPARE(status.legacy_migration_active, legacy_active);
        QCOMPARE(status.stake_tiers_active, tiers_active);

        coldstake_address->setText(QString::fromStdString(tiered_coldstake_result->address));
        update_controls();
        QCOMPARE(migration_legacy_sweep->isEnabled(), legacy_active);
        QCOMPARE(migration_goldrush_sweep->isEnabled(), quantum_active);
        QCOMPARE(selfstake_fund_amount->isEnabled(), tiers_active);
        QCOMPARE(selfstake_fund->isEnabled(), tiers_active);
        QCOMPARE(operator_bond_amount->isEnabled(), tiers_active);
        QCOMPARE(operator_fund->isEnabled(), tiers_active);
        QCOMPARE(coldstake_fund_amount->isEnabled(), tiers_active);

        // Liquid cold-stake funding follows ordinary quantum-output support;
        // only tiered cold-stake addresses require stake-tier activation.
        coldstake_address->setText(QString::fromStdString(liquid_coldstake_result->address));
        update_controls();
        QCOMPARE(coldstake_fund_amount->isEnabled(), quantum_active);
        coldstake_address->setText(QString::fromStdString(tiered_coldstake_result->address));
    };
    const auto mine_block = [&] {
        test.CreateAndProcessBlock({}, GetScriptForRawPubKey(test.coinbaseKey.GetPubKey()));
        SyncWithValidationInterfaceQueue();
    };
    const auto invalidate_tip = [&] {
        CBlockIndex* tip = WITH_LOCK(test.m_node.chainman->GetMutex(), return test.m_node.chainman->ActiveChain().Tip());
        QVERIFY(tip);
        BlockValidationState state;
        QVERIFY(test.m_node.chainman->ActiveChainstate().InvalidateBlock(state, tip));
        SyncWithValidationInterfaceQueue();
    };

    // Tip 105 creates candidate 106, the final Gold Rush block. Both the UI
    // and the backend reject migration without allocating an unused address.
    expect_controls(105, /*quantum_active=*/false, /*legacy_active=*/false, /*tiers_active=*/false);
    const size_t goldrush_address_count = wallet_interface.listQuantumAddresses().size();
    QVERIFY(!wallet_interface.migrateLegacyToQuantum(/*allow_new_quantum_key=*/true));
    QCOMPARE(wallet_interface.listQuantumAddresses().size(), goldrush_address_count);

    // Candidate 107 is Migration but precedes the tier activation at 108.
    mine_block();
    expect_controls(106, /*quantum_active=*/true, /*legacy_active=*/true, /*tiers_active=*/false);

    // Candidate 108 is the first block that permits tiered funding.
    mine_block();
    expect_controls(107, /*quantum_active=*/true, /*legacy_active=*/true, /*tiers_active=*/true);

    mine_block();
    mine_block();
    // Candidate 110 is Final: ordinary quantum and tiered funding remain
    // available, but legacy migration closes. Failure must not reserve a key.
    expect_controls(109, /*quantum_active=*/true, /*legacy_active=*/false, /*tiers_active=*/true);
    const size_t final_address_count = wallet_interface.listQuantumAddresses().size();
    QVERIFY(!wallet_interface.migrateLegacyToQuantum(/*allow_new_quantum_key=*/true));
    QCOMPARE(wallet_interface.listQuantumAddresses().size(), final_address_count);

    // Reorg backward across Final, tier activation, and Gold Rush. Every
    // lightweight refresh must derive permissions from the new active tip.
    invalidate_tip();
    expect_controls(108, /*quantum_active=*/true, /*legacy_active=*/true, /*tiers_active=*/true);
    invalidate_tip();
    expect_controls(107, /*quantum_active=*/true, /*legacy_active=*/true, /*tiers_active=*/true);
    invalidate_tip();
    expect_controls(106, /*quantum_active=*/true, /*legacy_active=*/true, /*tiers_active=*/false);
    invalidate_tip();
    expect_controls(105, /*quantum_active=*/false, /*legacy_active=*/false, /*tiers_active=*/false);

    // Mine an alternate branch forward through the same exact boundaries.
    test.coinbaseKey.MakeNewKey(true);
    mine_block();
    expect_controls(106, /*quantum_active=*/true, /*legacy_active=*/true, /*tiers_active=*/false);
    mine_block();
    expect_controls(107, /*quantum_active=*/true, /*legacy_active=*/true, /*tiers_active=*/true);
    mine_block();
    mine_block();
    expect_controls(109, /*quantum_active=*/true, /*legacy_active=*/false, /*tiers_active=*/true);
}

} // namespace

void WalletTests::walletTests()
{
#ifdef Q_OS_MACOS
    if (QApplication::platformName() == "minimal") {
        // Disable for mac on "minimal" platform to avoid crashes inside the Qt
        // framework when it tries to look up unimplemented cocoa functions,
        // and fails to handle returned nulls
        // (https://bugreports.qt.io/browse/QTBUG-49686).
        QWARN("Skipping WalletTests on mac build with 'minimal' platform set due to Qt bugs. To run AppTests, invoke "
              "with 'QT_QPA_PLATFORM=cocoa test_blackcoin-qt' on mac, or else use a linux or windows build.");
        return;
    }
#endif
    TestGUI(m_node);
    TestQuantumFundingControlsFollowReorg(m_node);
}
