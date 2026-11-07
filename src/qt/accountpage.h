// Copyright (c) 2026 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_ACCOUNTPAGE_H
#define BITCOIN_QT_ACCOUNTPAGE_H

#include <consensus/amount.h>
#include <qt/walletmodel.h>

#include <QPointer>
#include <QWidget>

class PlatformStyle;

QT_BEGIN_NAMESPACE
class QComboBox;
class QLabel;
class QLineEdit;
class QPushButton;
class QShowEvent;
class QTimer;
class QTreeWidget;
QT_END_NAMESPACE

class AccountPage : public QWidget
{
    Q_OBJECT

public:
    explicit AccountPage(const PlatformStyle* platformStyle, QWidget* parent = nullptr);
    ~AccountPage() override;
    void setWalletModel(WalletModel* walletModel);
    void setPrivacy(bool privacy);

protected:
    void showEvent(QShowEvent* event) override;

private Q_SLOTS:
    void refresh();
    void scheduleRefresh();
    void copySelectedAddress();
    void copySelectedOutpoint();
    void exportCsv();
    void showGuide();

private:
    enum Column {
        Type = 0,
        Address,
        Label,
        Amount,
        Outputs,
        Confirmations,
        Status,
        Notes,
        ColumnCount
    };

    QPointer<WalletModel> m_wallet_model;
    bool m_privacy{false};
    std::shared_ptr<std::atomic<bool>> m_refresh_cancel;
    std::shared_ptr<const WalletModel::AccountSnapshot> m_snapshot;
    uint64_t m_refresh_generation{0};
    bool m_refresh_queued{false};
    bool m_snapshot_rendered{false};

    QLabel* m_total_card{nullptr};
    QLabel* m_legacy_card{nullptr};
    QLabel* m_quantum_card{nullptr};
    QLabel* m_attention_card{nullptr};
    QLabel* m_status{nullptr};
    QComboBox* m_family_filter{nullptr};
    QLineEdit* m_search{nullptr};
    QPushButton* m_refresh{nullptr};
    QPushButton* m_copy_address{nullptr};
    QPushButton* m_copy_outpoint{nullptr};
    QPushButton* m_export{nullptr};
    QPushButton* m_guide{nullptr};
    QTreeWidget* m_tree{nullptr};
    QTimer* m_filter_timer{nullptr};

    void setupUi();
    void renderSnapshot();
    void applySnapshotFilter();
    void discardSnapshot();
    bool rowMatchesFilter(const QString& family, const QString& address, const QString& label) const;
};

#endif // BITCOIN_QT_ACCOUNTPAGE_H
