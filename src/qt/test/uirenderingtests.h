// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.
#ifndef BITCOIN_QT_TEST_UIRENDERINGTESTS_H
#define BITCOIN_QT_TEST_UIRENDERINGTESTS_H
#include <QObject>
class UiRenderingTests : public QObject
{
    Q_OBJECT
private Q_SLOTS:
    void slicedSortMatchesOracle_data();
    void slicedSortMatchesOracle();
    void updatesAndSelectionDuringProjection();
    void hiddenDetachAndReentry();
    void recentRowsDuringPartialHistory();
    void accountLargeGroupCancellationAndFilter();
    void atomicPublicationAndIdentity();
    void explicitVisibilityTransitions();
    void paintProjectionContinuation();
    void paintProjectionInvalidation();
    void paintProjectionDeadline();
};
#endif // BITCOIN_QT_TEST_UIRENDERINGTESTS_H
