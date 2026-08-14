// Copyright (c) 2017-2022 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/test/addressbooktests.h>
#include <qt/test/util.h>
#include <test/util/setup_common.h>

#include <interfaces/chain.h>
#include <interfaces/node.h>
#include <qt/addresstablemodel.h>
#include <qt/addressbookpage.h>
#include <qt/clientmodel.h>
#include <qt/editaddressdialog.h>
#include <qt/optionsmodel.h>
#include <qt/platformstyle.h>
#include <qt/qvalidatedlineedit.h>
#include <qt/walletmodel.h>

#include <key.h>
#include <key_io.h>
#include <wallet/wallet.h>
#include <wallet/test/util.h>
#include <walletinitinterface.h>

#include <chrono>

#include <QApplication>
#include <QLineEdit>
#include <QMessageBox>
#include <QTableView>
#include <QTimer>

using wallet::AddWallet;
using wallet::CWallet;
using wallet::CreateMockableWalletDatabase;
using wallet::GetMockableDatabase;
using wallet::RemoveWallet;
using wallet::WALLET_FLAG_DESCRIPTORS;
using wallet::WalletContext;

namespace
{

/**
 * Fill the edit address dialog box with data, submit it, and ensure that
 * the resulting message meets expectations.
 */
void EditAddressAndSubmit(
        EditAddressDialog* dialog,
        const QString& label, const QString& address, QString expected_msg)
{
    QString warning_text;

    dialog->findChild<QLineEdit*>("labelEdit")->setText(label);
    dialog->findChild<QValidatedLineEdit*>("addressEdit")->setText(address);

    ConfirmMessage(&warning_text, 5ms);
    dialog->accept();
    QCOMPARE(warning_text, expected_msg);
}

/**
 * Test adding various send addresses to the address book.
 *
 * There are three cases tested:
 *
 *   - new_address: a new address which should add as a send address successfully.
 *   - existing_s_address: an existing sending address which won't add successfully.
 *   - existing_r_address: an existing receiving address which won't add successfully.
 *
 * In each case, verify the resulting state of the address book and optionally
 * the warning message presented to the user.
 */
void TestAddAddressesToSendBook(interfaces::Node& node)
{
    TestChain100Setup test;
    auto wallet_loader = interfaces::MakeWalletLoader(*test.m_node.chain, *Assert(test.m_node.args));
    test.m_node.wallet_loader = wallet_loader.get();
    node.setContext(&test.m_node);
    const std::shared_ptr<CWallet> wallet = std::make_shared<CWallet>(node.context()->chain.get(), "", CreateMockableWalletDatabase());
    wallet->LoadWallet();
    wallet->SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
    {
        LOCK(wallet->cs_wallet);
        wallet->SetupDescriptorScriptPubKeyMans();
    }

    auto build_address = [&wallet]() {
        CKey key;
        key.MakeNewKey(true);
        CTxDestination dest(GetDestinationForKey(
            key.GetPubKey(), wallet->m_default_address_type));

        return std::make_pair(dest, QString::fromStdString(EncodeDestination(dest)));
    };

    CTxDestination r_key_dest, s_key_dest;

    // Add a preexisting "receive" entry in the address book.
    QString preexisting_r_address;
    QString r_label("already here (r)");

    // Add a preexisting "send" entry in the address book.
    QString preexisting_s_address;
    QString s_label("already here (s)");

    // Define a new address (which should add to the address book successfully).
    QString new_address_a;
    QString new_address_b;
    QString replacement_address;

    std::tie(r_key_dest, preexisting_r_address) = build_address();
    std::tie(s_key_dest, preexisting_s_address) = build_address();
    std::tie(std::ignore, new_address_a) = build_address();
    std::tie(std::ignore, new_address_b) = build_address();
    std::tie(std::ignore, replacement_address) = build_address();

    QVERIFY(wallet->SetAddressBook(r_key_dest, r_label.toStdString(), wallet::AddressPurpose::RECEIVE));
    QVERIFY(wallet->SetAddressBook(s_key_dest, s_label.toStdString(), wallet::AddressPurpose::SEND));

    auto check_addbook_size = [&wallet](int expected_size) {
        LOCK(wallet->cs_wallet);
        QCOMPARE(static_cast<int>(wallet->m_address_book.size()), expected_size);
    };

    // We should start with the two addresses we added earlier and nothing else.
    check_addbook_size(2);

    // Initialize relevant QT models.
    std::unique_ptr<const PlatformStyle> platformStyle(PlatformStyle::instantiate("other"));
    OptionsModel optionsModel(node);
    bilingual_str error;
    QVERIFY(optionsModel.Init(error));
    ClientModel clientModel(node, &optionsModel);
    WalletContext& context = *node.walletLoader().context();
    AddWallet(context, wallet);
    WalletModel walletModel(interfaces::MakeWallet(context, wallet), clientModel, platformStyle.get());
    RemoveWallet(context, wallet, /* load_on_start= */ std::nullopt);
    EditAddressDialog editAddressDialog(EditAddressDialog::NewSendingAddress);
    editAddressDialog.setModel(walletModel.getAddressTableModel());

    AddressBookPage address_book{platformStyle.get(), AddressBookPage::ForEditing, AddressBookPage::SendingTab};
    address_book.setModel(walletModel.getAddressTableModel());
    auto table_view = address_book.findChild<QTableView*>("tableView");
    QCOMPARE(table_view->model()->rowCount(), 1);

    EditAddressAndSubmit(
        &editAddressDialog, QString("uhoh"), preexisting_r_address,
        QString(
            "Address \"%1\" already exists as a receiving address with label "
            "\"%2\" and so cannot be added as a sending address."
            ).arg(preexisting_r_address).arg(r_label));
    check_addbook_size(2);
    QCOMPARE(table_view->model()->rowCount(), 1);

    EditAddressAndSubmit(
        &editAddressDialog, QString("uhoh, different"), preexisting_s_address,
        QString(
            "The entered address \"%1\" is already in the address book with "
            "label \"%2\"."
            ).arg(preexisting_s_address).arg(s_label));
    check_addbook_size(2);
    QCOMPARE(table_view->model()->rowCount(), 1);

    // Submit a new address which should add successfully - we expect the
    // warning message to be blank.
    EditAddressAndSubmit(
        &editAddressDialog, QString("io - new A"), new_address_a, QString(""));
    check_addbook_size(3);
    QCOMPARE(table_view->model()->rowCount(), 2);

    EditAddressAndSubmit(
        &editAddressDialog, QString("io - new B"), new_address_b, QString(""));
    check_addbook_size(4);
    QCOMPARE(table_view->model()->rowCount(), 3);

    auto search_line = address_book.findChild<QLineEdit*>("searchLineEdit");

    search_line->setText(r_label);
    QCOMPARE(table_view->model()->rowCount(), 0);

    search_line->setText(s_label);
    QCOMPARE(table_view->model()->rowCount(), 1);

    // Include separators that cannot occur in an encoded address so these
    // label-filter assertions cannot pick up a randomly generated address.
    search_line->setText("io - new");
    QCOMPARE(table_view->model()->rowCount(), 2);

    // Check wildcard "?".
    search_line->setText("io ?new");
    QCOMPARE(table_view->model()->rowCount(), 0);
    search_line->setText("io ? new");
    QCOMPARE(table_view->model()->rowCount(), 2);

    // Check wildcard "*".
    search_line->setText("io * new");
    QCOMPARE(table_view->model()->rowCount(), 2);
    search_line->setText("*");
    QCOMPARE(table_view->model()->rowCount(), 3);

    search_line->setText(preexisting_r_address);
    QCOMPARE(table_view->model()->rowCount(), 0);

    search_line->setText(preexisting_s_address);
    QCOMPARE(table_view->model()->rowCount(), 1);

    search_line->setText(new_address_a);
    QCOMPARE(table_view->model()->rowCount(), 1);

    search_line->setText(new_address_b);
    QCOMPARE(table_view->model()->rowCount(), 1);

    search_line->setText("");
    QCOMPARE(table_view->model()->rowCount(), 3);

    // Editing the address column atomically moves the sending entry while
    // preserving its label. A failed database write leaves both the wallet
    // and model on the old address.
    AddressTableModel* address_model = walletModel.getAddressTableModel();
    const int old_row = address_model->lookupAddress(new_address_a);
    QVERIFY(old_row >= 0);
    GetMockableDatabase(*wallet).m_fail_write_at = 0;
    QVERIFY(!address_model->setData(
        address_model->index(old_row, AddressTableModel::Address, QModelIndex()),
        replacement_address, Qt::EditRole));
    QCOMPARE(address_model->getEditStatus(), AddressTableModel::ADDRESS_BOOK_FAILURE);
    QVERIFY(address_model->lookupAddress(new_address_a) >= 0);
    QCOMPARE(address_model->lookupAddress(replacement_address), -1);

    GetMockableDatabase(*wallet).m_fail_write_at.reset();
    const int retry_row = address_model->lookupAddress(new_address_a);
    QVERIFY(address_model->setData(
        address_model->index(retry_row, AddressTableModel::Address, QModelIndex()),
        replacement_address, Qt::EditRole));
    QCOMPARE(address_model->lookupAddress(new_address_a), -1);
    const int replacement_row = address_model->lookupAddress(replacement_address);
    QVERIFY(replacement_row >= 0);
    QCOMPARE(address_model->data(
        address_model->index(replacement_row, AddressTableModel::Label, QModelIndex()),
        Qt::EditRole).toString(), QString("io - new A"));
    // The unfiltered model also contains the preexisting receiving entry.
    QCOMPARE(address_model->rowCount(QModelIndex()), 4);

    // A receiving-label commit failure occurs after one key is reserved. It
    // must be reported as an address-book partial result without retrying and
    // consuming a second key under the unlock-retry path.
    wallet::MockableDatabase& database = GetMockableDatabase(*wallet);
    const size_t keypool_before = WITH_LOCK(
        wallet->cs_wallet, return wallet->KeypoolCountExternalKeys());
    database.m_fail_commit = true;
    QCOMPARE(address_model->addRow(
        AddressTableModel::Receive, "label-commit-failure", "",
        wallet->m_default_address_type), QString());
    QCOMPARE(address_model->getEditStatus(),
             AddressTableModel::ADDRESS_BOOK_FAILURE);
    const size_t keypool_after = WITH_LOCK(
        wallet->cs_wallet, return wallet->KeypoolCountExternalKeys());
    QCOMPARE(keypool_before, keypool_after + 1);
}

} // namespace

void AddressBookTests::addressBookTests()
{
#ifdef Q_OS_MACOS
    if (QApplication::platformName() == "minimal") {
        // Disable for mac on "minimal" platform to avoid crashes inside the Qt
        // framework when it tries to look up unimplemented cocoa functions,
        // and fails to handle returned nulls
        // (https://bugreports.qt.io/browse/QTBUG-49686).
        QWARN("Skipping AddressBookTests on mac build with 'minimal' platform set due to Qt bugs. To run AppTests, invoke "
              "with 'QT_QPA_PLATFORM=cocoa test_blackcoin-qt' on mac, or else use a linux or windows build.");
        return;
    }
#endif
    TestAddAddressesToSendBook(m_node);
}
