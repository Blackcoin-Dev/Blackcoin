// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_TEST_CSVMODELWRITERTESTS_H
#define BITCOIN_QT_TEST_CSVMODELWRITERTESTS_H

#include <QObject>
#include <QTest>

class CSVModelWriterTests : public QObject
{
    Q_OBJECT

private Q_SLOTS:
    void hostileValuesMatchLegacyBytes();
    void batchBoundariesMatchLegacyBytes();
    void emptyAndNullModels();
    void unwritablePathFails();
};

#endif // BITCOIN_QT_TEST_CSVMODELWRITERTESTS_H
