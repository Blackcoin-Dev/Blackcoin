// Copyright (c) 2026 The Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/test/csvmodelwritertests.h>

#include <qt/csvmodelwriter.h>

#include <QByteArray>
#include <QDateTime>
#include <QFile>
#include <QIODevice>
#include <QStandardItemModel>
#include <QTemporaryDir>
#include <QTextStream>
#include <QVariant>

namespace {
struct Column {
    QString title;
    int column;
    int role;
};

//! Byte-for-byte reference: the pre-batching writer, streaming each piece.
QByteArray LegacyCsv(const QString& path, const QAbstractItemModel* model, const QList<Column>& columns)
{
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) return {};
    QTextStream out(&file);
    const auto value = [&](const QString& v) {
        QString escaped = v;
        escaped.replace('"', "\"\"");
        out << "\"" << escaped << "\"";
    };
    for (int i = 0; i < columns.size(); ++i) {
        if (i != 0) out << ",";
        value(columns[i].title);
    }
    out << "\n";
    const int rows = model ? model->rowCount() : 0;
    for (int j = 0; j < rows; ++j) {
        for (int i = 0; i < columns.size(); ++i) {
            if (i != 0) out << ",";
            value(model->index(j, columns[i].column).data(columns[i].role).toString());
        }
        out << "\n";
    }
    out.flush();
    file.close();
    QFile in(path);
    in.open(QIODevice::ReadOnly);
    return in.readAll();
}

QByteArray WriterCsv(const QString& path, const QAbstractItemModel* model, const QList<Column>& columns, bool* ok)
{
    CSVModelWriter writer(path);
    writer.setModel(model);
    for (const auto& c : columns) writer.addColumn(c.title, c.column, c.role);
    *ok = writer.write();
    QFile in(path);
    in.open(QIODevice::ReadOnly);
    return in.readAll();
}

//! Accepts the first byte_limit bytes, then fails every write.
class FailingDevice : public QIODevice
{
public:
    explicit FailingDevice(qint64 byte_limit) : m_limit(byte_limit) {}
    qint64 written() const { return m_written; }

protected:
    qint64 readData(char*, qint64) override { return -1; }
    qint64 writeData(const char*, qint64 len) override
    {
        if (m_written + len > m_limit) return -1;
        m_written += len;
        return len;
    }

private:
    const qint64 m_limit;
    qint64 m_written{0};
};

//! Counts model reads; read only from the test (GUI) thread.
class CountingModel : public QStandardItemModel
{
public:
    using QStandardItemModel::QStandardItemModel;
    mutable int reads{0};
    QVariant data(const QModelIndex& index, int role) const override
    {
        ++reads;
        return QStandardItemModel::data(index, role);
    }
};

QList<QVariant> HostileValues()
{
    return {
        QStringLiteral("plain"),
        QStringLiteral("quote \" inside"),
        QStringLiteral("\"\""),
        QStringLiteral("comma, separated"),
        QStringLiteral("line\nfeed"),
        QStringLiteral("crlf\r\nend"),
        QStringLiteral("lone\rcr"),
        QString::fromUtf8("unicode \xC3\xBC \xE2\x82\xBF emoji \xF0\x9F\x9A\x80"),
        QString(),
        QVariant(),
        QVariant(true),
        QVariant(-0.0),
        QVariant(1e22),
        QVariant(QDateTime(QDate(2026, 11, 9), QTime(1, 2, 3), Qt::UTC)),
        QVariant(QByteArray("bytes\"\x01")),
        QStringLiteral("  padded  "),
    };
}
} // namespace

void CSVModelWriterTests::hostileValuesMatchLegacyBytes()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const auto values = HostileValues();
    QStandardItemModel model(values.size(), 2);
    for (int r = 0; r < values.size(); ++r) {
        model.setData(model.index(r, 0), values[r], Qt::EditRole);
        model.setData(model.index(r, 1), values[values.size() - 1 - r], Qt::EditRole);
    }
    const QList<Column> columns{{QStringLiteral("Title \"quoted\", here"), 0, Qt::EditRole},
                                {QStringLiteral("Second"), 1, Qt::EditRole}};
    bool ok{false};
    const QByteArray actual = WriterCsv(dir.filePath("new.csv"), &model, columns, &ok);
    QVERIFY(ok);
    QCOMPARE(actual, LegacyCsv(dir.filePath("old.csv"), &model, columns));
}

void CSVModelWriterTests::batchBoundariesMatchLegacyBytes()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const auto values = HostileValues();
    for (const int rows : {CSVModelWriter::BATCH_ROWS - 1, CSVModelWriter::BATCH_ROWS,
                           CSVModelWriter::BATCH_ROWS + 1, 2 * CSVModelWriter::BATCH_ROWS + 3}) {
        QStandardItemModel model(rows, 1);
        for (int r = 0; r < rows; ++r) model.setData(model.index(r, 0), values[r % values.size()], Qt::EditRole);
        const QList<Column> columns{{QStringLiteral("Value"), 0, Qt::EditRole}};
        bool ok{false};
        const QByteArray actual = WriterCsv(dir.filePath(QStringLiteral("new-%1.csv").arg(rows)), &model, columns, &ok);
        QVERIFY(ok);
        QCOMPARE(actual, LegacyCsv(dir.filePath(QStringLiteral("old-%1.csv").arg(rows)), &model, columns));
    }
}

void CSVModelWriterTests::emptyAndNullModels()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QList<Column> columns{{QStringLiteral("Only header"), 0, Qt::EditRole}};
    QStandardItemModel empty(0, 1);
    bool ok{false};
    QCOMPARE(WriterCsv(dir.filePath("empty.csv"), &empty, columns, &ok),
             LegacyCsv(dir.filePath("empty-old.csv"), &empty, columns));
    QVERIFY(ok);
    QCOMPARE(WriterCsv(dir.filePath("null.csv"), nullptr, columns, &ok),
             LegacyCsv(dir.filePath("null-old.csv"), nullptr, columns));
    QVERIFY(ok);
}

void CSVModelWriterTests::zeroColumns()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    QStandardItemModel model(5, 2);
    const QList<Column> columns;
    bool ok{false};
    QCOMPARE(WriterCsv(dir.filePath("zero.csv"), &model, columns, &ok),
             LegacyCsv(dir.filePath("zero-old.csv"), &model, columns));
    QVERIFY(ok);
}

void CSVModelWriterTests::deviceFailureAfterFirstBatchStopsEarly()
{
    const int rows = 6 * CSVModelWriter::BATCH_ROWS;
    CountingModel model(rows, 1);
    for (int r = 0; r < rows; ++r) model.setData(model.index(r, 0), QStringLiteral("value %1").arg(r), Qt::EditRole);
    model.reads = 0;

    // Room for roughly one formatted batch: the second batch write fails while
    // the producer keeps formatting and blocks in Push for the next slot.
    FailingDevice device(qint64{CSVModelWriter::BATCH_ROWS} * 20);
    QVERIFY(device.open(QIODevice::WriteOnly));
    CSVModelWriter writer(QStringLiteral("unused"));
    writer.setModel(&model);
    writer.addColumn(QStringLiteral("Value"), 0);
    QVERIFY(!writer.write(device));
    QVERIFY(device.written() > 0);
    // The producer stops after the failure instead of reading every row.
    QVERIFY2(model.reads < rows, qPrintable(QStringLiteral("reads=%1 rows=%2").arg(model.reads).arg(rows)));
}

void CSVModelWriterTests::unwritablePathFails()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    QStandardItemModel model(1, 1);
    CSVModelWriter writer(dir.filePath("missing-directory/out.csv"));
    writer.setModel(&model);
    writer.addColumn(QStringLiteral("Value"), 0);
    QVERIFY(!writer.write());
}
