// Copyright (c) 2026 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/accountpage.h>

#include <qt/bitcoinunits.h>
#include <qt/guiutil.h>
#include <qt/platformstyle.h>
#include <qt/quantumguides.h>
#include <qt/walletmodel.h>

#include <addresstype.h>
#include <interfaces/wallet.h>
#include <key_io.h>
#include <primitives/transaction.h>

#include <algorithm>
#include <limits>
#include <map>
#include <set>
#include <vector>

#include <QAbstractItemView>
#include <QApplication>
#include <QClipboard>
#include <QComboBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QFile>
#include <QFileDialog>
#include <QGridLayout>
#include <QGroupBox>
#include <QHeaderView>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QPalette>
#include <QPushButton>
#include <QSignalBlocker>
#include <QTextEdit>
#include <QTextStream>
#include <QShowEvent>
#include <QTimer>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QVBoxLayout>

namespace {
constexpr uint16_t OPERATOR_COMMITMENT_BLOCKS = 40500;
constexpr int FILTER_FAMILY_ROLE{Qt::UserRole + 2};
constexpr int FILTER_TEXT_ROLE{Qt::UserRole + 3};
constexpr int GROUP_AMOUNT_ROLE{Qt::UserRole + 4};

struct StakeOutputDetail
{
    QString role;
    QString state;
    uint32_t unlock_height{0};
    bool operator_bond{false};
};

struct ColdStakeDetail
{
    interfaces::WalletQuantumColdStakeInfo info;
    interfaces::WalletQuantumColdStakeBalanceInfo balance;
};

struct AccountOutputMetadata
{
    std::map<QString, StakeOutputDetail> stake_outputs;
    std::map<QString, ColdStakeDetail> coldstake_addresses;
};

struct OutputRowDetail
{
    QString family;
    QString type;
    QString status;
    QString notes;
};

QString formatBLK(CAmount amount, bool plus = false)
{
    return BitcoinUnits::formatWithUnit(BitcoinUnit::BTC, amount, plus, BitcoinUnits::SeparatorStyle::ALWAYS);
}

QLabel* makeCard(const QString& text, QWidget* parent)
{
    auto* label = new QLabel(text, parent);
    label->setWordWrap(true);
    label->setTextFormat(Qt::RichText);
    label->setMinimumHeight(78);
    GUIUtil::ConfigureThemedLabelPanel(label, QPalette::Base, QPalette::Text, 10);
    return label;
}

QString baseOutputFamily(const CTxDestination& dest, const CScript& script)
{
    if (IsQuantumColdStakeDestination(dest) || IsQuantumColdStakeScript(script)) return QObject::tr("Cold stake");
    if (IsEUTXOScript(script)) return QObject::tr("EUTXO");
    if (IsQuantumMigrationDestination(dest) || IsQuantumMigrationScript(script)) return QObject::tr("Quantum");
    if (IsValidDestination(dest)) return QObject::tr("Legacy");
    return QObject::tr("Other");
}

bool isDirectQuantumScript(const CScript& script)
{
    const auto tier = GetQuantumStakeTierProgram(script);
    return tier && !tier->tiered && !tier->cold_stake;
}

QString stakeStateLabel(const QString& state)
{
    if (state == QStringLiteral("bonded")) return QObject::tr("bonded");
    if (state == QStringLiteral("unbonding")) return QObject::tr("unbonding");
    if (state == QStringLiteral("withdrawable")) return QObject::tr("withdrawable");
    return state.isEmpty() ? QObject::tr("unknown") : state;
}

QString coldStakeRoleLabel(const interfaces::WalletQuantumColdStakeInfo& info)
{
    if (info.has_owner_key && info.has_staker_key) return QObject::tr("owner/staker");
    if (info.has_owner_key) return QObject::tr("owner");
    if (info.has_staker_key) return QObject::tr("staker");
    return QObject::tr("watch-only");
}

QString coldStakeStateLabel(const ColdStakeDetail& detail)
{
    if (!detail.balance.available) return QObject::tr("refreshing");
    if (!detail.info.tiered) return QObject::tr("delegated");
    if (detail.info.unlock_height == 0) return QObject::tr("bonded");
    const int spend_height = detail.balance.current_height + 1;
    if (detail.info.unlock_height <= static_cast<uint32_t>(std::max(0, spend_height))) {
        return QObject::tr("withdrawable");
    }
    return QObject::tr("unbonding");
}

QString stakeOutputNote(const StakeOutputDetail& detail)
{
    QString note = detail.operator_bond
        ? QObject::tr("30-day cold-staking node bond controlled by this wallet.")
        : QObject::tr("Self-staking quantum output controlled by this wallet.");
    if (detail.state == QStringLiteral("unbonding") && detail.unlock_height > 0) {
        note += QObject::tr(" Unlock height: %1.").arg(detail.unlock_height);
    } else if (detail.state == QStringLiteral("withdrawable")) {
        note += QObject::tr(" Matured unbonding output; withdrawal is available.");
    }
    return note;
}

QString coldStakeNote(const ColdStakeDetail& detail)
{
    QString note = QObject::tr("Cold-stake delegation where this wallet has %1 authority.")
        .arg(coldStakeRoleLabel(detail.info));
    if (detail.info.tiered && detail.info.unlock_height > 0) {
        note += QObject::tr(" Unlock height: %1.").arg(detail.info.unlock_height);
    }
    if (detail.balance.spendable_outputs > 0) {
        note += QObject::tr(" Owner-spend available: %1 across %2 output(s).")
            .arg(formatBLK(detail.balance.spendable_amount))
            .arg(detail.balance.spendable_outputs);
    }
    return note;
}

OutputRowDetail describeOutput(const CTxDestination& dest,
                               const COutPoint& outpoint,
                               const interfaces::WalletTxOut& out,
                               const QString& address,
                               const AccountOutputMetadata& metadata)
{
    OutputRowDetail detail;
    detail.family = baseOutputFamily(dest, out.txout.scriptPubKey);
    detail.type = detail.family;
    detail.notes = QObject::tr("Nonstandard or wallet-internal script group.");

    const QString outpoint_text = QString::fromStdString(outpoint.ToString());
    const auto stake_it = metadata.stake_outputs.find(outpoint_text);
    if (stake_it != metadata.stake_outputs.end()) {
        detail.family = QObject::tr("Quantum");
        detail.type = QObject::tr("%1 - %2").arg(stake_it->second.role, stakeStateLabel(stake_it->second.state));
        detail.status = stakeStateLabel(stake_it->second.state);
        detail.notes = stakeOutputNote(stake_it->second);
        return detail;
    }

    if (detail.family == QObject::tr("Cold stake")) {
        const auto coldstake_it = metadata.coldstake_addresses.find(address);
        if (coldstake_it != metadata.coldstake_addresses.end()) {
            const QString state = coldStakeStateLabel(coldstake_it->second);
            detail.type = QObject::tr("Cold stake - %1 - %2")
                .arg(coldStakeRoleLabel(coldstake_it->second.info), state);
            detail.status = state;
            detail.notes = coldStakeNote(coldstake_it->second);
        } else {
            detail.notes = QObject::tr("Cold-stake contract path. Owner and staker authority are separated.");
        }
        return detail;
    }

    if (detail.family == QObject::tr("Quantum")) {
        const auto tier = GetQuantumStakeTierProgram(out.txout.scriptPubKey);
        if (tier && tier->tiered) {
            const QString state = tier->IsUnbonding()
                ? (tier->unlock_height > 0 ? QObject::tr("unbonding") : QObject::tr("bonded"))
                : QObject::tr("bonded");
            detail.type = QObject::tr("Tiered quantum stake - %1").arg(state);
            detail.status = state;
            detail.notes = tier->unlock_height > 0
                ? QObject::tr("Tiered quantum staking output. Unlock height: %1.").arg(tier->unlock_height)
                : QObject::tr("Tiered quantum staking output.");
        } else if (isDirectQuantumScript(out.txout.scriptPubKey)) {
            detail.type = out.depth_in_main_chain > 0 && !out.is_spent
                ? QObject::tr("Direct quantum spendable")
                : QObject::tr("Direct quantum");
            detail.notes = QObject::tr("Direct ML-DSA quantum spend path.");
        } else {
            detail.notes = QObject::tr("Wallet-owned quantum output; staking or reward metadata may affect ordinary use.");
        }
        return detail;
    }

    if (detail.family == QObject::tr("Legacy")) {
        detail.notes = QObject::tr("Legacy spend path. Use for current-chain fees, sends, and legacy staking.");
    } else if (detail.family == QObject::tr("EUTXO")) {
        detail.notes = QObject::tr("EUTXO v15 is frozen in v30.1.1. This row is inspection-only; funding and spending are disabled. Do not send BLK to it.");
    }
    return detail;
}

QString outputStatus(const interfaces::WalletTxOut& out)
{
    if (out.is_spent) return QObject::tr("spent");
    if (out.depth_in_main_chain < 0) return QObject::tr("conflicted");
    if (out.depth_in_main_chain == 0) return QObject::tr("unconfirmed");
    return QObject::tr("confirmed");
}

QString minDepthText(int min_depth)
{
    if (min_depth < 0) return QObject::tr("conflicted");
    return QString::number(min_depth);
}

QString addressNote(const QString& family)
{
    if (family == QObject::tr("Legacy")) return QObject::tr("Legacy spend path. Use for current-chain fees, sends, and legacy staking.");
    if (family == QObject::tr("Quantum")) return QObject::tr("Direct quantum spend path. Gold Rush rewards remain locked until Gold Rush ends, then require no preliminary move after maturity.");
    if (family == QObject::tr("Cold stake")) return QObject::tr("Cold-stake contract path. Owner and staker authority are separated.");
    if (family == QObject::tr("EUTXO")) return QObject::tr("EUTXO v15 is frozen in v30.1.1. This row is inspection-only; funding and spending are disabled. Do not send BLK to it.");
    return QObject::tr("Nonstandard or wallet-internal script group.");
}

} // namespace

AccountPage::AccountPage(const PlatformStyle* platformStyle, QWidget* parent)
    : QWidget(parent),
      m_filter_timer(new QTimer(this))
{
    Q_UNUSED(platformStyle);
    setupUi();
    m_filter_timer->setSingleShot(true);
    m_filter_timer->setInterval(250);
    connect(m_filter_timer, &QTimer::timeout, this, &AccountPage::applySnapshotFilter);
}

AccountPage::~AccountPage()
{
    if (m_refresh_cancel) m_refresh_cancel->store(true, std::memory_order_release);
}

void AccountPage::setupUi()
{
    auto* outer = new QVBoxLayout(this);
    outer->setContentsMargins(16, 16, 16, 16);
    outer->setSpacing(10);

    auto* top = new QHBoxLayout();
    auto* title = new QLabel(tr("<b>Account detail</b><br>Inspect where this wallet's coins are, which addresses hold them, and which outputs need migration or staking attention."), this);
    title->setTextFormat(Qt::RichText);
    title->setWordWrap(true);
    top->addWidget(title, 1);
    m_guide = new QPushButton(tr("Guide"), this);
    m_guide->setToolTip(tr("Open a detailed guide for reading account balances and address-level coins."));
    top->addWidget(m_guide);
    outer->addLayout(top);

    auto* cards = new QGridLayout();
    cards->setHorizontalSpacing(8);
    cards->setVerticalSpacing(8);
    m_total_card = makeCard(tr("Wallet totals will appear here."), this);
    m_total_card->setObjectName(QStringLiteral("accountTotalCard"));
    m_legacy_card = makeCard(tr("Legacy balance will appear here."), this);
    m_legacy_card->setObjectName(QStringLiteral("accountLegacyCard"));
    m_quantum_card = makeCard(tr("Quantum balance will appear here."), this);
    m_quantum_card->setObjectName(QStringLiteral("accountQuantumCard"));
    m_attention_card = makeCard(tr("Migration and staking attention items will appear here."), this);
    m_attention_card->setObjectName(QStringLiteral("accountAttentionCard"));
    GUIUtil::ConfigureThemedLabelPanel(m_attention_card, QPalette::Highlight, QPalette::HighlightedText, 10);
    cards->addWidget(m_total_card, 0, 0);
    cards->addWidget(m_legacy_card, 0, 1);
    cards->addWidget(m_quantum_card, 1, 0);
    cards->addWidget(m_attention_card, 1, 1);
    cards->setColumnStretch(0, 1);
    cards->setColumnStretch(1, 1);
    outer->addLayout(cards);

    auto* controls = new QHBoxLayout();
    m_family_filter = new QComboBox(this);
    m_family_filter->addItem(tr("All coin families"), QString());
    m_family_filter->addItem(tr("Legacy"), tr("Legacy"));
    m_family_filter->addItem(tr("Quantum"), tr("Quantum"));
    m_family_filter->addItem(tr("Cold stake"), tr("Cold stake"));
    m_family_filter->addItem(tr("EUTXO"), tr("EUTXO"));
    m_family_filter->addItem(tr("Other"), tr("Other"));
    m_search = new QLineEdit(this);
    m_search->setPlaceholderText(tr("Search address, label, outpoint, or notes"));
    m_refresh = new QPushButton(tr("Refresh"), this);
    m_copy_address = new QPushButton(tr("Copy address"), this);
    m_copy_outpoint = new QPushButton(tr("Copy outpoint"), this);
    m_export = new QPushButton(tr("Export CSV"), this);
    controls->addWidget(m_family_filter);
    controls->addWidget(m_search, 1);
    controls->addWidget(m_refresh);
    controls->addWidget(m_copy_address);
    controls->addWidget(m_copy_outpoint);
    controls->addWidget(m_export);
    outer->addLayout(controls);

    m_tree = new QTreeWidget(this);
    m_tree->setObjectName(QStringLiteral("accountCoinTree"));
    m_tree->setColumnCount(ColumnCount);
    m_tree->setHeaderLabels(QStringList{
        tr("Type"), tr("Address / output"), tr("Label"), tr("Amount"), tr("Outputs"), tr("Conf."), tr("Status"), tr("Notes")});
    m_tree->setSelectionMode(QAbstractItemView::SingleSelection);
    m_tree->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_tree->setAlternatingRowColors(true);
    m_tree->setUniformRowHeights(true);
    m_tree->header()->setSectionResizeMode(Type, QHeaderView::ResizeToContents);
    m_tree->header()->setSectionResizeMode(Address, QHeaderView::Stretch);
    m_tree->header()->setSectionResizeMode(Label, QHeaderView::ResizeToContents);
    m_tree->header()->setSectionResizeMode(Amount, QHeaderView::ResizeToContents);
    m_tree->header()->setSectionResizeMode(Outputs, QHeaderView::ResizeToContents);
    m_tree->header()->setSectionResizeMode(Confirmations, QHeaderView::ResizeToContents);
    m_tree->header()->setSectionResizeMode(Status, QHeaderView::ResizeToContents);
    m_tree->header()->setSectionResizeMode(Notes, QHeaderView::Stretch);
    outer->addWidget(m_tree, 1);

    m_status = new QLabel(tr("Load a wallet to inspect account details."), this);
    m_status->setWordWrap(true);
    outer->addWidget(m_status);

    connect(m_guide, &QPushButton::clicked, this, &AccountPage::showGuide);
    connect(m_refresh, &QPushButton::clicked, this, &AccountPage::refresh);
    connect(m_copy_address, &QPushButton::clicked, this, &AccountPage::copySelectedAddress);
    connect(m_copy_outpoint, &QPushButton::clicked, this, &AccountPage::copySelectedOutpoint);
    connect(m_export, &QPushButton::clicked, this, &AccountPage::exportCsv);
    connect(m_family_filter, qOverload<int>(&QComboBox::currentIndexChanged), this, &AccountPage::scheduleRefresh);
    connect(m_search, &QLineEdit::textChanged, this, &AccountPage::scheduleRefresh);
}

void AccountPage::discardSnapshot()
{
    ++m_refresh_generation;
    if (m_refresh_cancel) m_refresh_cancel->store(true, std::memory_order_release);
    m_refresh_cancel.reset();
    m_refresh_queued = false;
    m_snapshot.reset();
    m_snapshot_rendered = false;
    m_filter_timer->stop();
    m_tree->clear();
}

void AccountPage::setWalletModel(WalletModel* walletModel)
{
    discardSnapshot();
    if (m_wallet_model) {
        disconnect(m_wallet_model, nullptr, this, nullptr);
    }
    m_wallet_model = walletModel;
    if (m_wallet_model) {
        // No balanceChanged/encryptionStatusChanged auto-refresh: those fire on
        // every block and would re-sweep the whole wallet on the GUI thread.
        connect(m_wallet_model, &QObject::destroyed, this, [this] {
            m_wallet_model = nullptr;
            discardSnapshot();
            renderSnapshot();
        });
    }
    renderSnapshot();
}

void AccountPage::setPrivacy(bool privacy)
{
    m_privacy = privacy;
    if (privacy) discardSnapshot();
    renderSnapshot();
}

bool AccountPage::rowMatchesFilter(const QString& family, const QString& address, const QString& label) const
{
    const QString selected_family = m_family_filter->currentData().toString();
    if (!selected_family.isEmpty() && family != selected_family) return false;

    const QString needle = m_search->text().trimmed();
    if (needle.isEmpty()) return true;
    return family.contains(needle, Qt::CaseInsensitive) ||
           address.contains(needle, Qt::CaseInsensitive) ||
           label.contains(needle, Qt::CaseInsensitive);
}

void AccountPage::scheduleRefresh()
{
    if (!m_filter_timer) return;
    m_filter_timer->start();
}

void AccountPage::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    renderSnapshot();
}

void AccountPage::refresh()
{
    if (!isVisible() || window()->isMinimized() || m_privacy || !m_wallet_model) return;
    if (m_refresh_cancel) {
        m_refresh_queued = true;
        m_refresh_cancel->store(true, std::memory_order_release);
        return;
    }
    m_status->setText(tr("Loading account details…"));
    const auto generation = m_refresh_generation;
    const QPointer<AccountPage> view{this};
    m_refresh_cancel = m_wallet_model->requestAccountSnapshot([view, generation](auto snapshot) {
        if (!view || view->m_refresh_generation != generation) return;
        view->m_refresh_cancel.reset();
        if (view->m_refresh_queued) {
            view->m_refresh_queued = false;
            view->refresh();
            return;
        }
        if (snapshot->cancelled) return;
        if (snapshot->stale) {
            view->m_status->setText(tr("Wallet state changed or is busy. Press Refresh to try again."));
            return;
        }
        if (!snapshot->error.empty()) {
            view->m_status->setText(tr("Unable to refresh account details: %1").arg(QString::fromStdString(snapshot->error).toHtmlEscaped()));
            return;
        }
        view->m_snapshot = std::move(snapshot);
        view->m_snapshot_rendered = false;
        view->renderSnapshot();
    });
    if (!m_refresh_cancel) m_status->setText(tr("Wallet is closing."));
}

void AccountPage::renderSnapshot()
{
    if (m_privacy) {
        m_total_card->setText(tr("<b>Values hidden</b><br>Privacy mode is enabled."));
        m_legacy_card->setText(tr("<b>Legacy</b><br>Hidden"));
        m_quantum_card->setText(tr("<b>Quantum</b><br>Hidden"));
        m_attention_card->setText(tr("<b>Attention</b><br>Hidden"));
        m_status->setText(tr("Disable privacy mode to inspect account-level coins."));
        return;
    }

    if (!m_snapshot) {
        m_total_card->setText(m_wallet_model ? tr("Wallet totals will appear here.") : tr("Load a wallet to inspect account details."));
        m_legacy_card->setText(QStringLiteral("-"));
        m_quantum_card->setText(QStringLiteral("-"));
        m_attention_card->setText(QStringLiteral("-"));
        if (!m_refresh_cancel) {
            m_status->setText(m_wallet_model ? tr("Press Refresh to load account details.") : tr("No wallet is loaded."));
        }
        return;
    }

    if (!isVisible() || window()->isMinimized()) return;
    if (m_snapshot_rendered) {
        applySnapshotFilter();
        return;
    }
    const auto& snapshot = *m_snapshot;
    const auto& balances = snapshot.balances;
    const auto& migration = snapshot.migration;
    const auto& demurrage = snapshot.demurrage;
    AccountOutputMetadata metadata;
    std::set<std::string> unverified_quantum_keys;
    for (const auto& info : snapshot.quantum_addresses) {
        if (!info.backup_verified) unverified_quantum_keys.insert(info.public_key);
        if (!info.tiered) continue;
        StakeOutputDetail detail;
        detail.operator_bond = info.label == "coldstake-operator" && info.unbonding_blocks == OPERATOR_COMMITMENT_BLOCKS;
        detail.role = detail.operator_bond ? tr("Operator bond") : tr("Self stake");
        const auto& outputs = snapshot.stake_outputs.at(info.address);
        for (const interfaces::WalletQuantumStakeOutputInfo& output : outputs) {
            StakeOutputDetail output_detail = detail;
            output_detail.state = QString::fromStdString(output.state);
            output_detail.unlock_height = output.unlock_height;
            const QString outpoint = QString::fromStdString(output.txid) + QStringLiteral(":") + QString::number(output.vout);
            metadata.stake_outputs[outpoint] = output_detail;
        }
    }
    for (const auto& info : snapshot.coldstake_delegations) {
        ColdStakeDetail detail;
        detail.info = info;
        detail.balance = snapshot.coldstake_balances.at(info.address);
        metadata.coldstake_addresses[QString::fromStdString(info.address)] = detail;
    }

    const CAmount lifecycle_locked = balances.synthetic_mature_locked_balance +
        balances.direct_quantum_phase_locked_balance +
        balances.quantum_contract_restricted_balance +
        balances.final_locked_legacy_balance + balances.demurrage_locked_balance;
    m_total_card->setText(tr("<b>Wallet lifecycle totals</b><br>Ordinary available: %1<br>Pending: %2<br>Immature: %3<br>Locked/restricted: %4")
        .arg(formatBLK(balances.balance))
        .arg(formatBLK(balances.unconfirmed_balance))
        .arg(formatBLK(balances.immature_balance))
        .arg(formatBLK(lifecycle_locked)));
    m_legacy_card->setText(tr("<b>Legacy lifecycle</b><br>Spendable now: %1<br>Final-locked: %2<br>Spendable legacy value must migrate before Final activation.")
        .arg(formatBLK(balances.legacy_balance))
        .arg(formatBLK(balances.final_locked_legacy_balance)));
    m_quantum_card->setText(tr("<b>Quantum lifecycle</b><br>Direct spendable: %1<br>Gold Rush immature: %2<br>Gold Rush mature/phase-locked: %3<br>Other phase/contract restricted: %4")
        .arg(formatBLK(balances.quantum_balance))
        .arg(formatBLK(balances.synthetic_immature_balance))
        .arg(formatBLK(balances.synthetic_mature_locked_balance))
        .arg(formatBLK(balances.direct_quantum_phase_locked_balance +
                       balances.quantum_contract_restricted_balance)));
    QString attention;
    if (migration.available) {
        attention = tr("<b>Attention</b><br>Legacy to migrate: %1<br>Gold Rush rewards phase-locked: %2<br>Staked/delegated quantum: %3<br>Demurrage locked: %4<br>Demurrage burned: %5")
            .arg(formatBLK(migration.eligible_legacy_amount))
            .arg(formatBLK(migration.goldrush_reward_amount_needing_move))
            .arg(formatBLK(migration.staked_quantum_amount))
            .arg(formatBLK(balances.demurrage_locked_balance))
            .arg(formatBLK(balances.demurrage_burned_balance));
    } else {
        attention = tr("<b>Attention</b><br>Migration status is busy; refresh shortly.");
    }
    if (!unverified_quantum_keys.empty()) {
        attention += tr("<br><b>Backup required:</b> %1 non-HD quantum key(s) do not have a completed reopen-and-sign backup verification event. Unlock the wallet and use Backup Wallet now. The wallet cannot track whether an external backup file is later moved or deleted.")
            .arg(static_cast<int>(unverified_quantum_keys.size()));
    }
    m_attention_card->setText(attention);

    QSignalBlocker tree_blocker(m_tree);
    m_tree->clear();

    for (const auto& entry : snapshot.coins) {
        const CTxDestination& dest = entry.first;
        const QString address = QString::fromStdString(EncodeDestination(dest));
        const auto label_entry = snapshot.labels.find(dest);
        const QString label = label_entry == snapshot.labels.end() ? QString{} : QString::fromStdString(label_entry->second);

        CAmount group_amount{0};
        int min_depth{std::numeric_limits<int>::max()};
        QString family = tr("Other");
        QString group_type;
        QString group_note;
        QString group_status;
        bool same_type{true};
        bool same_status{true};
        QString searchable = address + QStringLiteral(" ") + label;
        std::vector<OutputRowDetail> output_details;
        output_details.reserve(entry.second.size());
        for (const auto& coin_tuple : entry.second) {
            const COutPoint& outpoint = std::get<0>(coin_tuple);
            const interfaces::WalletTxOut& out = std::get<1>(coin_tuple);
            group_amount += out.txout.nValue;
            min_depth = std::min(min_depth, out.depth_in_main_chain);
            const OutputRowDetail detail = describeOutput(dest, outpoint, out, address, metadata);
            output_details.push_back(detail);
            if (family == tr("Other") || detail.family != tr("Other")) family = detail.family;
            if (group_type.isEmpty()) {
                group_type = detail.type;
                group_note = detail.notes;
                group_status = detail.status;
            } else {
                same_type = same_type && group_type == detail.type;
                same_status = same_status && group_status == detail.status;
            }
            searchable += QStringLiteral(" ") + QString::fromStdString(outpoint.ToString()) +
                          QStringLiteral(" ") + detail.type +
                          QStringLiteral(" ") + detail.notes;
        }

        if (entry.second.empty()) continue;

        if (!same_type || group_type.isEmpty()) {
            group_type = family;
            group_note = addressNote(family);
        }
        if (!same_status) {
            group_status.clear();
        }

        auto* parent = new QTreeWidgetItem(m_tree);
        parent->setText(Type, group_type);
        parent->setText(Address, address.isEmpty() ? tr("(script without address)") : address);
        parent->setText(Label, label);
        parent->setText(Amount, formatBLK(group_amount));
        parent->setText(Outputs, QString::number(static_cast<int>(entry.second.size())));
        parent->setText(Confirmations, minDepthText(min_depth == std::numeric_limits<int>::max() ? 0 : min_depth));
        parent->setText(Status, group_status.isEmpty()
            ? (min_depth <= 0 ? tr("needs confirmation") : tr("available"))
            : group_status);
        parent->setText(Notes, group_note);
        parent->setData(Address, Qt::UserRole, address);
        parent->setData(Type, FILTER_FAMILY_ROLE, family);
        parent->setData(Type, FILTER_TEXT_ROLE, searchable);
        parent->setData(Amount, GROUP_AMOUNT_ROLE, qlonglong(group_amount));
        parent->setToolTip(Address, address);
        parent->setToolTip(Notes, parent->text(Notes));

        for (int i = 0; i < static_cast<int>(entry.second.size()); ++i) {
            const auto& coin_tuple = entry.second.at(i);
            const COutPoint& outpoint = std::get<0>(coin_tuple);
            const interfaces::WalletTxOut& out = std::get<1>(coin_tuple);
            const OutputRowDetail& detail = output_details.at(i);
            const QString outpoint_text = QString::fromStdString(outpoint.ToString());
            auto* child = new QTreeWidgetItem(parent);
            child->setText(Type, detail.type);
            child->setText(Address, outpoint_text);
            child->setText(Label, label);
            child->setText(Amount, formatBLK(out.txout.nValue));
            child->setText(Outputs, tr("1"));
            child->setText(Confirmations, QString::number(out.depth_in_main_chain));
            child->setText(Status, detail.status.isEmpty() || out.depth_in_main_chain <= 0 || out.is_spent
                ? outputStatus(out)
                : detail.status);
            child->setText(Notes, detail.notes);
            child->setData(Address, Qt::UserRole, address);
            child->setData(Address, Qt::UserRole + 1, outpoint_text);
            child->setToolTip(Address, outpoint_text);
            child->setToolTip(Notes, detail.notes);
        }

    }

    if (migration.available && migration.goldrush_reward_outputs_needing_move > 0) {
        const QString family = tr("Quantum");
        const QString searchable = tr("Gold Rush locked aggregate quantum reward phase lock");
        auto* item = new QTreeWidgetItem(m_tree);
        item->setText(Type, tr("Gold Rush locked"));
        item->setText(Address, tr("(aggregate)"));
        item->setText(Label, QString());
        item->setText(Amount, formatBLK(migration.goldrush_reward_amount_needing_move));
        item->setText(Outputs, QString::number(migration.goldrush_reward_outputs_needing_move));
        item->setText(Confirmations, QStringLiteral("-"));
        item->setText(Status, tr("phase locked"));
        item->setText(Notes, tr("These Gold Rush reward outputs remain unspendable until Gold Rush ends and normal maturity is satisfied. They then become ordinary direct quantum outputs without a required fresh-address move. Exact outpoints are not exposed to this account view, so this aggregate row is not added to the visible balance total."));
        item->setToolTip(Notes, item->text(Notes));
        item->setData(Type, FILTER_FAMILY_ROLE, family);
        item->setData(Type, FILTER_TEXT_ROLE, searchable);
    }

    m_snapshot_rendered = true;
    applySnapshotFilter();
}

void AccountPage::applySnapshotFilter()
{
    if (!isVisible() || window()->isMinimized() || m_privacy || !m_snapshot_rendered) return;
    QSignalBlocker tree_blocker(m_tree);
    m_tree->clearSelection();
    int visible_groups{0};
    int visible_outputs{0};
    CAmount visible_amount{0};
    for (int row = 0; row < m_tree->topLevelItemCount(); ++row) {
        auto* item = m_tree->topLevelItem(row);
        const bool visible = rowMatchesFilter(item->data(Type, FILTER_FAMILY_ROLE).toString(),
            item->data(Type, FILTER_TEXT_ROLE).toString(), item->text(Label));
        item->setHidden(!visible);
        if (visible && item->childCount() > 0) {
            ++visible_groups;
            visible_outputs += item->childCount();
            visible_amount += item->data(Amount, GROUP_AMOUNT_ROLE).toLongLong();
        }
    }

    if (visible_groups <= 12) {
        m_tree->expandAll();
    } else {
        m_tree->expandToDepth(0);
    }

    if (m_refresh_cancel) return;
    const auto& snapshot = *m_snapshot;
    m_status->setText(tr("%1 address group(s), %2 output(s), %3 visible after filters. RGB assets: %4. EUTXO state records: %5. Demurrage monitored outputs: %6.")
        .arg(visible_groups)
        .arg(visible_outputs)
        .arg(formatBLK(visible_amount))
        .arg(static_cast<int>(snapshot.rgb_assets))
        .arg(static_cast<int>(snapshot.eutxo_states))
        .arg(snapshot.demurrage.available ? snapshot.demurrage.quantum_outputs : 0));
}

void AccountPage::copySelectedAddress()
{
    const QList<QTreeWidgetItem*> selected = m_tree->selectedItems();
    if (selected.empty()) return;
    const QString address = selected.front()->data(Address, Qt::UserRole).toString();
    if (!address.isEmpty()) QApplication::clipboard()->setText(address);
}

void AccountPage::copySelectedOutpoint()
{
    const QList<QTreeWidgetItem*> selected = m_tree->selectedItems();
    if (selected.empty()) return;
    QString outpoint = selected.front()->data(Address, Qt::UserRole + 1).toString();
    if (outpoint.isEmpty()) outpoint = selected.front()->text(Address);
    if (!outpoint.isEmpty()) QApplication::clipboard()->setText(outpoint);
}

void AccountPage::exportCsv()
{
    if (m_privacy || !m_snapshot_rendered) return;
    const auto snapshot = m_snapshot;
    const QPointer<AccountPage> view{this};
    const QString filename = QFileDialog::getSaveFileName(this, tr("Export account detail"), QString(), tr("Comma separated file (*.csv)"));
    if (!view || filename.isEmpty() || m_privacy || m_snapshot != snapshot || !m_snapshot_rendered) return;

    QFile file(filename);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        m_status->setText(tr("Unable to open %1 for writing.").arg(filename));
        return;
    }

    QTextStream out(&file);
    auto write_value = [&out](QString value) {
        value.replace('"', "\"\"");
        out << "\"" << value << "\"";
    };
    for (int col = 0; col < ColumnCount; ++col) {
        if (col) out << ",";
        write_value(m_tree->headerItem()->text(col));
    }
    out << "\n";
    for (int row = 0; row < m_tree->topLevelItemCount(); ++row) {
        QTreeWidgetItem* parent = m_tree->topLevelItem(row);
        if (!rowMatchesFilter(parent->data(Type, FILTER_FAMILY_ROLE).toString(),
                parent->data(Type, FILTER_TEXT_ROLE).toString(), parent->text(Label))) continue;
        const int rows = parent->childCount();
        for (int child_index = -1; child_index < rows; ++child_index) {
            QTreeWidgetItem* item = child_index < 0 ? parent : parent->child(child_index);
            for (int col = 0; col < ColumnCount; ++col) {
                if (col) out << ",";
                write_value(item->text(col));
            }
            out << "\n";
        }
    }
    m_status->setText(file.error() == QFile::NoError
        ? tr("Exported account detail to %1.").arg(filename)
        : tr("Export failed for %1.").arg(filename));
}

void AccountPage::showGuide()
{
    QDialog dialog(this);
    dialog.setWindowTitle(tr("Account detail guide"));
    dialog.resize(920, 720);
    dialog.setMinimumSize(620, 440);

    auto* layout = new QVBoxLayout(&dialog);
    auto* browser = new QTextEdit(&dialog);
    browser->setReadOnly(true);
    browser->setTextInteractionFlags(Qt::TextBrowserInteraction);
    browser->setHtml(QStringLiteral(
        "<html><body style=\"font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; font-size: 13px; line-height: 1.45;\">"
        "<style>"
        "h2 { margin-top: 20px; margin-bottom: 8px; }"
        "h3 { margin-top: 16px; margin-bottom: 6px; }"
        "p { margin-top: 4px; margin-bottom: 10px; }"
        "li { margin-bottom: 5px; }"
        "ol, ul { margin-top: 4px; }"
        "</style>%1</body></html>").arg(QuantumGuides::AccountGuide()));
    layout->addWidget(browser);

    auto* buttons = new QDialogButtonBox(QDialogButtonBox::Close, &dialog);
    connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    layout->addWidget(buttons);
    dialog.exec();
}
