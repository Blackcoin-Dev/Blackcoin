// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_TEST_PRESENTATIONEFFICIENCYTESTS_H
#define BITCOIN_QT_TEST_PRESENTATIONEFFICIENCYTESTS_H

#if defined(HAVE_CONFIG_H)
#include <config/bitcoin-config.h>
#endif

#include <QObject>

namespace interfaces { class Node; }

class PresentationEfficiencyTests : public QObject
{
    Q_OBJECT

public:
    explicit PresentationEfficiencyTests(interfaces::Node& node) : m_node{node} {}

private Q_SLOTS:
#ifdef ENABLE_WALLET
    void recentTransactionProjection();
    void recentTransactionClick();
#endif
    void peerPollingFollowsVisibility();

private:
    interfaces::Node& m_node;
};

#endif // BITCOIN_QT_TEST_PRESENTATIONEFFICIENCYTESTS_H
