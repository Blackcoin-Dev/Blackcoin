// Copyright (c) 2011-2020 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_CSVMODELWRITER_H
#define BITCOIN_QT_CSVMODELWRITER_H

#include <QList>
#include <QObject>

QT_BEGIN_NAMESPACE
class QAbstractItemModel;
class QIODevice;
QT_END_NAMESPACE

/** Export a Qt table model to a CSV file. This is useful for analyzing or post-processing the data in
    a spreadsheet.
 */
class CSVModelWriter : public QObject
{
    Q_OBJECT

public:
    explicit CSVModelWriter(const QString &filename, QObject *parent = nullptr);

    void setModel(const QAbstractItemModel *model);
    void addColumn(const QString &title, int column, int role=Qt::EditRole);

    /** Perform export of the model to CSV.
        Rows are read on the calling (GUI) thread in fixed-size batches; each
        formatted batch is handed to a writer thread so file I/O overlaps model
        reads. At most two batches are held in memory. Returns after the file
        is complete, so the export reflects one consistent model state.
        @returns true on success, false otherwise
    */
    bool write();

    /** Same as write(), into an already open device (used by tests to inject
        device failures). The device is written only from the writer thread.
    */
    bool write(QIODevice& device);

    /** Rows formatted per batch handed to the writer thread. */
    static constexpr int BATCH_ROWS{4096};

private:
    QString filename;
    const QAbstractItemModel* model{nullptr};

    struct Column
    {
        QString title;
        int column;
        int role;
    };
    QList<Column> columns;
};

#endif // BITCOIN_QT_CSVMODELWRITER_H
