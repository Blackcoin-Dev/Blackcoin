// Copyright (c) 2011-2022 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/transactionview.h>
#include <qt/visibilitycontroller.h>
#include <qt/uiperf.h>

#include <qt/addresstablemodel.h>
#include <qt/bitcoinunits.h>
#include <qt/csvmodelwriter.h>
#include <qt/editaddressdialog.h>
#include <qt/guiutil.h>
#include <qt/optionsmodel.h>
#include <qt/platformstyle.h>
#include <qt/transactiondescdialog.h>
#include <qt/transactionfilterproxy.h>
#include <qt/transactionrecord.h>
#include <qt/transactiontablemodel.h>
#include <qt/walletmodel.h>

#include <node/interface_ui.h>

#include <chrono>
#include <optional>
#include <utility>

#include <QApplication>
#include <QComboBox>
#include <QDateTimeEdit>
#include <QDesktopServices>
#include <QDoubleValidator>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QPoint>
#include <QScrollBar>
#include <QSettings>
#include <QSizePolicy>
#include <QTableView>
#include <QTimer>
#include <QUrl>
#include <QVBoxLayout>

TransactionView::TransactionView(const PlatformStyle *platformStyle, QWidget *parent)
    : QWidget(parent), m_platform_style{platformStyle}
{
    // Build filter row
    setContentsMargins(0,0,0,0);

    QGridLayout* filter_layout = new QGridLayout();
    filter_layout->setContentsMargins(0, 0, 0, 0);
    filter_layout->setHorizontalSpacing(platformStyle->getUseExtraSpacing() ? 5 : 4);
    filter_layout->setVerticalSpacing(4);
    filter_layout->setColumnMinimumWidth(0, platformStyle->getUseExtraSpacing() ? 26 : 23);

    watchOnlyWidget = new QComboBox(this);
    watchOnlyWidget->setFixedWidth(24);
    watchOnlyWidget->addItem("", TransactionFilterProxy::WatchOnlyFilter_All);
    watchOnlyWidget->addItem(platformStyle->SingleColorIcon(":/icons/eye_plus"), "", TransactionFilterProxy::WatchOnlyFilter_Yes);
    watchOnlyWidget->addItem(platformStyle->SingleColorIcon(":/icons/eye_minus"), "", TransactionFilterProxy::WatchOnlyFilter_No);
    filter_layout->addWidget(watchOnlyWidget, 0, 1);

    dateWidget = new QComboBox(this);
    if (platformStyle->getUseExtraSpacing()) {
        dateWidget->setFixedWidth(121);
    } else {
        dateWidget->setFixedWidth(120);
    }
    dateWidget->addItem(tr("All"), All);
    dateWidget->addItem(tr("Today"), Today);
    dateWidget->addItem(tr("This week"), ThisWeek);
    dateWidget->addItem(tr("This month"), ThisMonth);
    dateWidget->addItem(tr("Last month"), LastMonth);
    dateWidget->addItem(tr("This year"), ThisYear);
    dateWidget->addItem(tr("Range…"), Range);
    filter_layout->addWidget(dateWidget, 0, 2);

    typeWidget = new QComboBox(this);
    if (platformStyle->getUseExtraSpacing()) {
        typeWidget->setFixedWidth(121);
    } else {
        typeWidget->setFixedWidth(120);
    }

    typeWidget->addItem(tr("All"), TransactionFilterProxy::ALL_TYPES);
    typeWidget->addItem(tr("Received with"), TransactionFilterProxy::TYPE(TransactionRecord::RecvWithAddress) |
                                        TransactionFilterProxy::TYPE(TransactionRecord::RecvFromOther));
    typeWidget->addItem(tr("Sent to"), TransactionFilterProxy::TYPE(TransactionRecord::SendToAddress) |
                                  TransactionFilterProxy::TYPE(TransactionRecord::SendToOther));
    typeWidget->addItem(tr("Staked"), TransactionFilterProxy::TYPE(TransactionRecord::Staked));
    typeWidget->addItem(tr("Mined"), TransactionFilterProxy::TYPE(TransactionRecord::Generated));
    typeWidget->addItem(tr("Other"), TransactionFilterProxy::TYPE(TransactionRecord::Other));

    filter_layout->addWidget(typeWidget, 0, 3);

    search_widget = new QLineEdit(this);
    search_widget->setPlaceholderText(tr("Enter address, transaction id, or label to search"));
    search_widget->setMinimumWidth(120);
    search_widget->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);

    amountWidget = new QLineEdit(this);
    amountWidget->setPlaceholderText(tr("Min amount"));
    if (platformStyle->getUseExtraSpacing()) {
        amountWidget->setFixedWidth(97);
    } else {
        amountWidget->setFixedWidth(100);
    }
    QDoubleValidator *amountValidator = new QDoubleValidator(0, 1e20, 8, this);
    QLocale amountLocale(QLocale::C);
    amountLocale.setNumberOptions(QLocale::RejectGroupSeparator);
    amountValidator->setLocale(amountLocale);
    amountWidget->setValidator(amountValidator);
    filter_layout->addWidget(amountWidget, 0, 4);
    filter_layout->addWidget(search_widget, 1, 1, 1, 4);
    filter_layout->setColumnStretch(3, 1);

    // Delay before filtering transactions
    static constexpr auto input_filter_delay{200ms};

    QTimer* amount_typing_delay = new QTimer(this);
    amount_typing_delay->setSingleShot(true);
    amount_typing_delay->setInterval(input_filter_delay);

    QTimer* prefix_typing_delay = new QTimer(this);
    prefix_typing_delay->setSingleShot(true);
    prefix_typing_delay->setInterval(input_filter_delay);

    QVBoxLayout *vlayout = new QVBoxLayout(this);
    vlayout->setContentsMargins(0,0,0,0);
    vlayout->setSpacing(0);

    transactionView = new UiPaintTableView(this);
    transactionView->setObjectName("transactionView");
    vlayout->addLayout(filter_layout);
    m_history_state = new QLabel(tr("Loading wallet history…"), this);
    m_history_state->setObjectName(QStringLiteral("transactionHistoryState"));
    // The status text must not set the page's minimum width: wrap it so a
    // narrow window keeps its layout while history is loading or updating.
    m_history_state->setWordWrap(true);
    m_history_state->setMinimumWidth(0);
    m_history_state->hide();
    vlayout->addWidget(m_history_state);
    vlayout->addWidget(createDateRangeWidget());
    vlayout->addWidget(transactionView);
    vlayout->setSpacing(0);
    transactionView->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOn);
    transactionView->setTabKeyNavigation(false);
    transactionView->setContextMenuPolicy(Qt::CustomContextMenu);
    transactionView->installEventFilter(this);
    transactionView->setAlternatingRowColors(true);
    transactionView->setSelectionBehavior(QAbstractItemView::SelectRows);
    transactionView->setSelectionMode(QAbstractItemView::ExtendedSelection);
    transactionView->setSortingEnabled(true);
    transactionView->verticalHeader()->hide();

    QSettings settings;
    if (!transactionView->horizontalHeader()->restoreState(settings.value("TransactionViewHeaderState").toByteArray())) {
        transactionView->setColumnWidth(TransactionTableModel::Status, STATUS_COLUMN_WIDTH);
        transactionView->setColumnWidth(TransactionTableModel::Watchonly, WATCHONLY_COLUMN_WIDTH);
        transactionView->setColumnWidth(TransactionTableModel::Date, DATE_COLUMN_WIDTH);
        transactionView->setColumnWidth(TransactionTableModel::Type, TYPE_COLUMN_WIDTH);
        transactionView->setColumnWidth(TransactionTableModel::Amount, AMOUNT_MINIMUM_COLUMN_WIDTH);
        transactionView->horizontalHeader()->setMinimumSectionSize(MINIMUM_COLUMN_WIDTH);
        transactionView->horizontalHeader()->setStretchLastSection(true);
    }

    contextMenu = new QMenu(this);
    contextMenu->setObjectName("contextMenu");
    copyAddressAction = contextMenu->addAction(tr("&Copy address"), this, &TransactionView::copyAddress);
    copyLabelAction = contextMenu->addAction(tr("Copy &label"), this, &TransactionView::copyLabel);
    contextMenu->addAction(tr("Copy &amount"), this, &TransactionView::copyAmount);
    contextMenu->addAction(tr("Copy transaction &ID"), this, &TransactionView::copyTxID);
    contextMenu->addAction(tr("Copy &raw transaction"), this, &TransactionView::copyTxHex);
    contextMenu->addAction(tr("Copy full transaction &details"), this, &TransactionView::copyTxPlainText);
    contextMenu->addAction(tr("&Show transaction details"), this, &TransactionView::showDetails);
    contextMenu->addSeparator();
    abandonAction = contextMenu->addAction(tr("A&bandon transaction"), this, &TransactionView::abandonTx);
    contextMenu->addAction(tr("&Edit address label"), this, &TransactionView::editLabel);

    connect(dateWidget, qOverload<int>(&QComboBox::activated), this, &TransactionView::chooseDate);
    connect(typeWidget, qOverload<int>(&QComboBox::activated), this, &TransactionView::chooseType);
    connect(watchOnlyWidget, qOverload<int>(&QComboBox::activated), this, &TransactionView::chooseWatchonly);
    connect(amountWidget, &QLineEdit::textEdited, this, [this] {
        static_cast<UiPaintTableView*>(transactionView)->measurementAction(UiPaintProbe::Action::FILTER_RESULT, true, {}, UiPaintProbe::FilterChannel::AMOUNT);
    });
    connect(search_widget, &QLineEdit::textEdited, this, [this] {
        static_cast<UiPaintTableView*>(transactionView)->measurementAction(UiPaintProbe::Action::FILTER_RESULT, true, {}, UiPaintProbe::FilterChannel::SEARCH);
    });
    connect(amountWidget, &QLineEdit::textChanged, amount_typing_delay, qOverload<>(&QTimer::start));
    connect(amount_typing_delay, &QTimer::timeout, this, &TransactionView::changedAmount);
    connect(search_widget, &QLineEdit::textChanged, prefix_typing_delay, qOverload<>(&QTimer::start));
    connect(prefix_typing_delay, &QTimer::timeout, this, &TransactionView::changedSearch);

    connect(transactionView, &QTableView::doubleClicked, this, &TransactionView::doubleClicked);
    connect(transactionView, &QTableView::customContextMenuRequested, this, &TransactionView::contextualMenu);

    // Double-clicking on a transaction on the transaction history page shows details
    connect(this, &TransactionView::doubleClicked, this, &TransactionView::showDetails);
    m_visibility = std::make_unique<VisibilityController>(*this, [this](bool active) {
        if (transactionProxyModel) transactionProxyModel->setActive(active);
        updateHistoryState();
    });
    m_visibility->refresh();
}

TransactionView::~TransactionView()
{
    m_visibility.reset();
    QSettings settings;
    settings.setValue("TransactionViewHeaderState", transactionView->horizontalHeader()->saveState());
}

void TransactionView::setModel(WalletModel *_model)
{
    m_pending_focus = std::monostate{};
    transactionView->setModel(nullptr);
    delete transactionProxyModel;
    transactionProxyModel = nullptr;
    this->model = _model;
    if(_model)
    {
        transactionProxyModel = new TransactionPresentationProxy(this);
        auto* history = _model->getTransactionTableModel();
        connect(history, &TransactionTableModel::historyLoaded, this, [this, history] {
            if (!model || model->getTransactionTableModel() != history) return;
            updateHistoryState();
            const auto pending = std::exchange(m_pending_focus, std::monostate{});
            if (const auto* index = std::get_if<QPersistentModelIndex>(&pending); index && index->isValid()) {
                // Recreate the index after publication and replay so its
                // internal record pointer comes from the current model data.
                focusTransaction(history->index(index->row(), index->column()));
            } else if (const auto* txid = std::get_if<uint256>(&pending)) {
                focusTransaction(*txid);
            } else if (m_visibility->active()) {
                ensureHistorySource();
            }
        });
        connect(history, &TransactionTableModel::historyLoadFailed, this, [this, history] {
            if (!model || model->getTransactionTableModel() != history) return;
            updateHistoryState();
        });
        transactionProxyModel->setSortCaseSensitivity(Qt::CaseInsensitive);
        transactionProxyModel->setSortRole(Qt::EditRole);
        m_visibility->refresh();
        transactionProxyModel->setActive(m_visibility->active());
        transactionView->setModel(transactionProxyModel);
        transactionView->sortByColumn(TransactionTableModel::Date, Qt::DescendingOrder);
        static_cast<UiPaintTableView*>(transactionView)->observeHistoryProjection(transactionProxyModel);
        connect(transactionProxyModel, &TransactionPresentationProxy::projectionStarted, this, [this] {
            updateHistoryState();
        });
        connect(transactionProxyModel, &TransactionPresentationProxy::projectionReady, this, [this] {
            updateHistoryState();
            const auto pending = std::exchange(m_pending_focus, std::monostate{});
            if (const auto* index = std::get_if<QPersistentModelIndex>(&pending); index && index->isValid()) {
                focusTransaction(model->getTransactionTableModel()->index(index->row(), index->column()));
            } else if (const auto* txid = std::get_if<uint256>(&pending)) {
                focusTransaction(*txid);
            }
        });
        transactionProxyModel->setSourceModel(history);
        if (m_visibility->active()) ensureHistorySource();
        updateHistoryState();

        if (_model->getOptionsModel())
        {
            // Add third party transaction URLs to context menu
            QStringList listUrls = GUIUtil::SplitSkipEmptyParts(_model->getOptionsModel()->getThirdPartyTxUrls(), "|");
            bool actions_created = false;
            for (int i = 0; i < listUrls.size(); ++i)
            {
                QString url = listUrls[i].trimmed();
                QString host = QUrl(url, QUrl::StrictMode).host();
                if (!host.isEmpty())
                {
                    if (!actions_created) {
                        contextMenu->addSeparator();
                        actions_created = true;
                    }
                    /*: Transactions table context menu action to show the
                        selected transaction in a third-party block explorer.
                        %1 is a stand-in argument for the URL of the explorer. */
                    contextMenu->addAction(tr("Show in %1").arg(host), [this, url] { openThirdPartyTxUrl(url); });
                }
            }
        }

        // show/hide column Watch-only
        updateWatchOnlyColumn(_model->haveWatchOnly());

        // Watch-only signal
        connect(_model, &WalletModel::notifyWatchonlyChanged, this, &TransactionView::updateWatchOnlyColumn);
    }
    updateHistoryState();
}

void TransactionView::updateHistoryState()
{
    const auto* history = model ? model->getTransactionTableModel() : nullptr;
    const bool failed = history && history->historyLoadHasFailed();
    const bool loaded = history && history->isHistoryLoaded();
    const bool projected = transactionProxyModel && transactionProxyModel->isReady();
    if (failed) m_history_state->setText(tr("Wallet history could not be loaded. Reopen the wallet to try again."));
    else if (!loaded) m_history_state->setText(tr("Loading wallet history…"));
    else m_history_state->setText(tr("Updating transaction history…"));
    m_history_state->setVisible(history && (failed || !loaded || !projected));
    search_widget->setEnabled(loaded && !failed);
    // Removed source identities can be absent while the next projection is
    // pending. Navigation queues until readiness; user actions stay disabled.
    transactionView->setEnabled(loaded && !failed && projected);
}

bool TransactionView::ensureHistorySource()
{
    if (!model || !transactionProxyModel) return false;
    auto* history = model->getTransactionTableModel();
    if (!history->isHistoryLoaded()) return false;
    m_visibility->refresh();
    transactionProxyModel->setActive(m_visibility->active());
    return true;
}

void TransactionView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    m_visibility->refresh();
    ensureHistorySource();
}

void TransactionView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    m_visibility->refresh();
}

void TransactionView::changeEvent(QEvent* e)
{
    if (e->type() == QEvent::PaletteChange) {
        watchOnlyWidget->setItemIcon(
            TransactionFilterProxy::WatchOnlyFilter_Yes,
            m_platform_style->SingleColorIcon(QStringLiteral(":/icons/eye_plus")));
        watchOnlyWidget->setItemIcon(
            TransactionFilterProxy::WatchOnlyFilter_No,
            m_platform_style->SingleColorIcon(QStringLiteral(":/icons/eye_minus")));
    }

    QWidget::changeEvent(e);
}

void TransactionView::chooseDate(int idx)
{
    if (!transactionProxyModel) return;
    static_cast<UiPaintTableView*>(transactionView)->measurementAction(UiPaintProbe::Action::FILTER_RESULT, true, {}, UiPaintProbe::FilterChannel::COMBO);
    QDate current = QDate::currentDate();
    dateRangeWidget->setVisible(false);
    switch(dateWidget->itemData(idx).toInt())
    {
    case All:
        transactionProxyModel->setDateRange(
                std::nullopt,
                std::nullopt);
        break;
    case Today:
        transactionProxyModel->setDateRange(
                GUIUtil::StartOfDay(current),
                std::nullopt);
        break;
    case ThisWeek: {
        // Find last Monday
        QDate startOfWeek = current.addDays(-(current.dayOfWeek()-1));
        transactionProxyModel->setDateRange(
                GUIUtil::StartOfDay(startOfWeek),
                std::nullopt);

        } break;
    case ThisMonth:
        transactionProxyModel->setDateRange(
                GUIUtil::StartOfDay(QDate(current.year(), current.month(), 1)),
                std::nullopt);
        break;
    case LastMonth:
        transactionProxyModel->setDateRange(
                GUIUtil::StartOfDay(QDate(current.year(), current.month(), 1).addMonths(-1)),
                GUIUtil::StartOfDay(QDate(current.year(), current.month(), 1)));
        break;
    case ThisYear:
        transactionProxyModel->setDateRange(
                GUIUtil::StartOfDay(QDate(current.year(), 1, 1)),
                std::nullopt);
        break;
    case Range:
        dateRangeWidget->setVisible(true);
        dateRangeChanged();
        break;
    }
}

void TransactionView::chooseType(int idx)
{
    if(!transactionProxyModel)
        return;
    static_cast<UiPaintTableView*>(transactionView)->measurementAction(UiPaintProbe::Action::FILTER_RESULT, true, {}, UiPaintProbe::FilterChannel::COMBO);
    transactionProxyModel->setTypeFilter(
        typeWidget->itemData(idx).toInt());
}

void TransactionView::chooseWatchonly(int idx)
{
    if(!transactionProxyModel)
        return;
    static_cast<UiPaintTableView*>(transactionView)->measurementAction(UiPaintProbe::Action::FILTER_RESULT, true, {}, UiPaintProbe::FilterChannel::COMBO);
    transactionProxyModel->setWatchOnlyFilter(
        static_cast<TransactionFilterProxy::WatchOnlyFilter>(watchOnlyWidget->itemData(idx).toInt()));
}

void TransactionView::changedSearch()
{
    if(!transactionProxyModel)
        return;
    static_cast<UiPaintTableView*>(transactionView)->measurementDeferred(true, UiPaintProbe::FilterChannel::SEARCH);
    transactionProxyModel->setSearchString(search_widget->text());
    static_cast<UiPaintTableView*>(transactionView)->measurementDeferred(false, UiPaintProbe::FilterChannel::SEARCH);
}

void TransactionView::changedAmount()
{
    if(!transactionProxyModel)
        return;
    static_cast<UiPaintTableView*>(transactionView)->measurementDeferred(true, UiPaintProbe::FilterChannel::AMOUNT);
    CAmount amount_parsed = 0;
    if (BitcoinUnits::parse(model->getOptionsModel()->getDisplayUnit(), amountWidget->text(), &amount_parsed)) {
        transactionProxyModel->setMinAmount(amount_parsed);
    }
    else
    {
        transactionProxyModel->setMinAmount(0);
    }
    static_cast<UiPaintTableView*>(transactionView)->measurementDeferred(false, UiPaintProbe::FilterChannel::AMOUNT);
}

void TransactionView::exportClicked()
{
    if (!model || !model->getOptionsModel()) {
        return;
    }

    if (!model->getTransactionTableModel()->isHistoryLoaded()) {
        Q_EMIT message(tr("History Unavailable"), tr("Wait for wallet history to finish loading before exporting."),
            CClientUIInterface::MSG_WARNING);
        return;
    }

    // CSV is currently the only supported format
    QString filename = GUIUtil::getSaveFileName(this,
        tr("Export Transaction History"), QString(),
        /*: Expanded name of the CSV file format.
            See: https://en.wikipedia.org/wiki/Comma-separated_values. */
        tr("Comma separated file") + QLatin1String(" (*.csv)"), nullptr);

    if (filename.isNull())
        return;

    if (!exportTransactions(filename)) {
        Q_EMIT message(tr("Exporting Failed"), tr("There was an error trying to save the transaction history to %1.").arg(filename),
            CClientUIInterface::MSG_ERROR);
    }
    else {
        Q_EMIT message(tr("Exporting Successful"), tr("The transaction history was successfully saved to %1.").arg(filename),
            CClientUIInterface::MSG_INFORMATION);
    }
}

bool TransactionView::exportTransactions(const QString& filename)
{
    if (!model || !model->getOptionsModel() || !ensureHistorySource()) return false;

    const auto export_model = transactionProxyModel->makeExportModel();
    CSVModelWriter writer(filename);

    // name, column, role
    writer.setModel(export_model.get());
    writer.addColumn(tr("Confirmed"), 0, TransactionTableModel::ConfirmedRole);
    if (model->wallet().haveWatchOnly())
        writer.addColumn(tr("Watch-only"), TransactionTableModel::Watchonly);
    writer.addColumn(tr("Date"), 0, TransactionTableModel::DateRole);
    writer.addColumn(tr("Type"), TransactionTableModel::Type, Qt::EditRole);
    writer.addColumn(tr("Label"), 0, TransactionTableModel::ExportLabelRole);
    writer.addColumn(tr("Address"), 0, TransactionTableModel::AddressRole);
    writer.addColumn(BitcoinUnits::getAmountColumnTitle(model->getOptionsModel()->getDisplayUnit()), 0, TransactionTableModel::FormattedAmountRole);
    writer.addColumn(tr("ID"), 0, TransactionTableModel::TxHashRole);

    return writer.write();
}

void TransactionView::contextualMenu(const QPoint &point)
{
    if (!transactionProxyModel || !transactionProxyModel->isReady()) return;
    QModelIndex index = transactionView->indexAt(point);
    QModelIndexList selection = transactionView->selectionModel()->selectedRows(0);
    if (selection.empty())
        return;

    // check if transaction can be abandoned, disable context menu action in case it doesn't
    uint256 hash;
    hash.SetHex(selection.at(0).data(TransactionTableModel::TxHashRole).toString().toStdString());
    abandonAction->setEnabled(model->wallet().transactionCanBeAbandoned(hash));
    copyAddressAction->setEnabled(GUIUtil::hasEntryData(transactionView, 0, TransactionTableModel::AddressRole));
    copyLabelAction->setEnabled(GUIUtil::hasEntryData(transactionView, 0, TransactionTableModel::ExportLabelRole));

    if (index.isValid()) {
        GUIUtil::PopupMenu(contextMenu, transactionView->viewport()->mapToGlobal(point));
    }
}

void TransactionView::abandonTx()
{
    if (!transactionProxyModel || !transactionProxyModel->isReady()) return;
    if(!transactionView || !transactionView->selectionModel())
        return;
    QModelIndexList selection = transactionView->selectionModel()->selectedRows(0);
    if (selection.empty()) return;

    // get the hash from the TxHashRole (QVariant / QString)
    uint256 hash;
    QString hashQStr = selection.at(0).data(TransactionTableModel::TxHashRole).toString();
    hash.SetHex(hashQStr.toStdString());

    // Abandon the wallet transaction over the walletModel
    model->wallet().abandonTransaction(hash);
}

void TransactionView::copyAddress()
{
    if (!transactionProxyModel || !transactionProxyModel->isReady()) return;
    GUIUtil::copyEntryData(transactionView, 0, TransactionTableModel::AddressRole);
}

void TransactionView::copyLabel()
{
    if (!transactionProxyModel || !transactionProxyModel->isReady()) return;
    GUIUtil::copyEntryData(transactionView, 0, TransactionTableModel::ExportLabelRole);
}

void TransactionView::copyAmount()
{
    if (!transactionProxyModel || !transactionProxyModel->isReady()) return;
    GUIUtil::copyEntryData(transactionView, 0, TransactionTableModel::FormattedAmountRole);
}

void TransactionView::copyTxID()
{
    if (!transactionProxyModel || !transactionProxyModel->isReady()) return;
    GUIUtil::copyEntryData(transactionView, 0, TransactionTableModel::TxHashRole);
}

void TransactionView::copyTxHex()
{
    if (!transactionProxyModel || !transactionProxyModel->isReady()) return;
    GUIUtil::copyEntryData(transactionView, 0, TransactionTableModel::TxHexRole);
}

void TransactionView::copyTxPlainText()
{
    if (!transactionProxyModel || !transactionProxyModel->isReady()) return;
    GUIUtil::copyEntryData(transactionView, 0, TransactionTableModel::TxPlainTextRole);
}

void TransactionView::editLabel()
{
    if (!transactionProxyModel || !transactionProxyModel->isReady()) return;
    if(!transactionView->selectionModel() ||!model)
        return;
    QModelIndexList selection = transactionView->selectionModel()->selectedRows();
    if(!selection.isEmpty())
    {
        AddressTableModel *addressBook = model->getAddressTableModel();
        if(!addressBook)
            return;
        QString address = selection.at(0).data(TransactionTableModel::AddressRole).toString();
        if(address.isEmpty())
        {
            // If this transaction has no associated address, exit
            return;
        }
        // Is address in address book? Address book can miss address when a transaction is
        // sent from outside the UI.
        int idx = addressBook->lookupAddress(address);
        if(idx != -1)
        {
            // Edit sending / receiving address
            QModelIndex modelIdx = addressBook->index(idx, 0, QModelIndex());
            // Determine type of address, launch appropriate editor dialog type
            QString type = modelIdx.data(AddressTableModel::TypeRole).toString();

            auto dlg = new EditAddressDialog(
                type == AddressTableModel::Receive
                ? EditAddressDialog::EditReceivingAddress
                : EditAddressDialog::EditSendingAddress, this);
            dlg->setModel(addressBook);
            dlg->loadRow(idx);
            GUIUtil::ShowModalDialogAsynchronously(dlg);
        }
        else
        {
            // Add sending address
            auto dlg = new EditAddressDialog(EditAddressDialog::NewSendingAddress,
                this);
            dlg->setModel(addressBook);
            dlg->setAddress(address);
            GUIUtil::ShowModalDialogAsynchronously(dlg);
        }
    }
}

void TransactionView::showDetails()
{
    if (!transactionProxyModel || !transactionProxyModel->isReady()) return;
    if(!transactionView->selectionModel())
        return;
    QModelIndexList selection = transactionView->selectionModel()->selectedRows();
    if(!selection.isEmpty())
    {
        TransactionDescDialog *dlg = new TransactionDescDialog(selection.at(0));
        dlg->setAttribute(Qt::WA_DeleteOnClose);
        m_opened_dialogs.append(dlg);
        connect(dlg, &QObject::destroyed, [this, dlg] {
            m_opened_dialogs.removeOne(dlg);
        });
        dlg->show();
    }
}

void TransactionView::openThirdPartyTxUrl(QString url)
{
    if (!transactionProxyModel || !transactionProxyModel->isReady()) return;
    if(!transactionView || !transactionView->selectionModel())
        return;
    QModelIndexList selection = transactionView->selectionModel()->selectedRows(0);
    if(!selection.isEmpty())
         QDesktopServices::openUrl(QUrl::fromUserInput(url.replace("%s", selection.at(0).data(TransactionTableModel::TxHashRole).toString())));
}

QWidget *TransactionView::createDateRangeWidget()
{
    dateRangeWidget = new QFrame();
    dateRangeWidget->setFrameStyle(static_cast<int>(QFrame::Panel) | static_cast<int>(QFrame::Raised));
    dateRangeWidget->setContentsMargins(1,1,1,1);
    QHBoxLayout *layout = new QHBoxLayout(dateRangeWidget);
    layout->setContentsMargins(0,0,0,0);
    layout->addSpacing(23);
    layout->addWidget(new QLabel(tr("Range:")));

    dateFrom = new QDateTimeEdit(this);
    dateFrom->setDisplayFormat("dd/MM/yy");
    dateFrom->setCalendarPopup(true);
    dateFrom->setMinimumWidth(100);
    dateFrom->setDate(QDate::currentDate().addDays(-7));
    layout->addWidget(dateFrom);
    layout->addWidget(new QLabel(tr("to")));

    dateTo = new QDateTimeEdit(this);
    dateTo->setDisplayFormat("dd/MM/yy");
    dateTo->setCalendarPopup(true);
    dateTo->setMinimumWidth(100);
    dateTo->setDate(QDate::currentDate());
    layout->addWidget(dateTo);
    layout->addStretch();

    // Hide by default
    dateRangeWidget->setVisible(false);

    // Notify on change
    connect(dateFrom, &QDateTimeEdit::dateChanged, this, &TransactionView::dateRangeChanged);
    connect(dateTo, &QDateTimeEdit::dateChanged, this, &TransactionView::dateRangeChanged);

    return dateRangeWidget;
}

void TransactionView::dateRangeChanged()
{
    if(!transactionProxyModel)
        return;
    transactionProxyModel->setDateRange(
            GUIUtil::StartOfDay(dateFrom->date()),
            GUIUtil::StartOfDay(dateTo->date()).addDays(1));
}

void TransactionView::focusTransaction(const QModelIndex &idx)
{
    if (!model || !idx.isValid() || idx.model() != model->getTransactionTableModel()) return;
    if (!ensureHistorySource() || !transactionProxyModel->isReady()) {
        m_pending_focus = QPersistentModelIndex{idx};
        return;
    }
    QModelIndex targetIdx = transactionProxyModel->mapFromSource(idx);
    transactionView->scrollTo(targetIdx);
    transactionView->setCurrentIndex(targetIdx);
    transactionView->setFocus();
}

void TransactionView::focusTransaction(const uint256& txid)
{
    if (!model) return;
    if (!ensureHistorySource() || !transactionProxyModel->isReady()) {
        m_pending_focus = txid;
        return;
    }

    const QModelIndexList results = model->getTransactionTableModel()->indexesForTransaction(txid);

    transactionView->setFocus();
    transactionView->selectionModel()->clearSelection();
    for (const QModelIndex& index : results) {
        const QModelIndex targetIndex = transactionProxyModel->mapFromSource(index);
        transactionView->selectionModel()->select(
            targetIndex,
            QItemSelectionModel::Rows | QItemSelectionModel::Select);
        // Called once per destination to ensure all results are in view, unless
        // transactions are not ordered by (ascending or descending) date.
        transactionView->scrollTo(targetIndex);
        // scrollTo() does not scroll far enough the first time when transactions
        // are ordered by ascending date.
        if (index == results[0]) transactionView->scrollTo(targetIndex);
    }
}

// Need to override default Ctrl+C action for amount as default behaviour is just to copy DisplayRole text
bool TransactionView::eventFilter(QObject *obj, QEvent *event)
{
    if (event->type() == QEvent::KeyPress)
    {
        QKeyEvent *ke = static_cast<QKeyEvent *>(event);
        if (ke->key() == Qt::Key_C && ke->modifiers().testFlag(Qt::ControlModifier))
        {
             if (!transactionProxyModel || !transactionProxyModel->isReady()) return true;
             GUIUtil::copyEntryData(transactionView, 0, TransactionTableModel::TxPlainTextRole);
             return true;
        }
    }
    if (event->type() == QEvent::EnabledChange) {
        if (!isEnabled()) {
            closeOpenedDialogs();
        }
    }
    return QWidget::eventFilter(obj, event);
}

// show/hide column Watch-only
void TransactionView::updateWatchOnlyColumn(bool fHaveWatchOnly)
{
    watchOnlyWidget->setVisible(fHaveWatchOnly);
    transactionView->setColumnHidden(TransactionTableModel::Watchonly, !fHaveWatchOnly);
}

void TransactionView::closeOpenedDialogs()
{
    // close all dialogs opened from this view
    for (QDialog* dlg : m_opened_dialogs) {
        dlg->close();
    }
    m_opened_dialogs.clear();
}
