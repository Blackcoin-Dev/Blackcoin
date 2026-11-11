// Copyright (c) 2026 The Blackcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.
#ifndef BITCOIN_QT_TEST_UIWORKERTESTS_H
#define BITCOIN_QT_TEST_UIWORKERTESTS_H
#include <QObject>
class UiWorkerTests : public QObject
{
    Q_OBJECT
private Q_SLOTS:
    void deliveredPaintCalibration();
    void deliveredPaintRejectsConsumedEvents();
    void deliveredPaintLifecycleAndBounds();
    void deliveredPaintGenerationAndRestore();
    void deliveredPaintFileGuards();
    void slowNotifyJournal();
    void accumulatorCalibrationAndOverflow();
    void eventLoopCalibration();
    void outputCreationFailsClosed();
    void terminalStallBeforeQuit();
    void headerIdentityInvalidatesStakeCache();
    void consoleRejectsAfterShutdown();
    void peerSnapshotsDoNotBlockGui();
    void peerRowsPreserveIdentity();
    void blockTipBurstIsCoalesced();
    void blockTipSingleNotificationIsPrompt();
    void blockTipShutdownDropsPending();
};
#endif // BITCOIN_QT_TEST_UIWORKERTESTS_H
