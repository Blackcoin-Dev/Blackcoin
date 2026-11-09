// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/test/transactionsortkeytests.h>

#include <interfaces/wallet.h>
#include <qt/transactionrecord.h>
#include <tinyformat.h>
#include <uint256.h>

#include <QString>

namespace {
QString LegacyDateKey(const TransactionRecord& rec)
{
    return QString::fromStdString(strprintf("%020s-%s", rec.time, rec.status.sortKey));
}

interfaces::WalletTxStatus Status(int height, unsigned int received)
{
    interfaces::WalletTxStatus wtx{};
    wtx.block_height = height;
    wtx.blocks_to_maturity = 0;
    wtx.depth_in_main_chain = height > 0 ? 3 : 0;
    wtx.time_received = received;
    wtx.lock_time = 0;
    wtx.is_trusted = true;
    wtx.is_abandoned = false;
    wtx.is_coinbase = false;
    wtx.is_coinstake = false;
    wtx.is_in_main_chain = height > 0;
    return wtx;
}
} // namespace

void TransactionSortKeyTests::sortKeysMatchLegacyFormatting()
{
    TransactionRecord rec(uint256::ONE, 1762650000);
    rec.idx = 2;

    // Before any status update the sort key is empty.
    QVERIFY(rec.status.sortKey.empty());
    QCOMPARE(rec.dateSortKey(), LegacyDateKey(rec));
    QCOMPARE(rec.statusSortKey(), QString{});

    // The cached Date key follows every status update.
    rec.updateStatus(Status(/*height=*/0, /*received=*/1762650001), uint256::ZERO, /*numBlocks=*/100, /*block_time=*/0);
    QVERIFY(!rec.status.sortKey.empty());
    QCOMPARE(rec.dateSortKey(), LegacyDateKey(rec));
    QCOMPARE(rec.statusSortKey(), QString::fromStdString(rec.status.sortKey));

    const QString unconfirmed = rec.dateSortKey();
    rec.updateStatus(Status(/*height=*/123456, /*received=*/1762650001), uint256::ONE, /*numBlocks=*/123460, /*block_time=*/0);
    QCOMPARE(rec.dateSortKey(), LegacyDateKey(rec));
    QVERIFY(rec.dateSortKey() != unconfirmed);
    QCOMPARE(rec.statusSortKey(), QString::fromStdString(rec.status.sortKey));

    // Copies carry the same key.
    const TransactionRecord copy = rec;
    QCOMPARE(copy.dateSortKey(), LegacyDateKey(rec));
}
