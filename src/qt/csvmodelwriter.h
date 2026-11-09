// Copyright (c) 2011-2020 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BITCOIN_QT_CSVMODELWRITER_H
#define BITCOIN_QT_CSVMODELWRITER_H

#include <QList>
#include <QObject>

QT_BEGIN_NAMESPACE
class QAbstractItemModel;
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
        @returns true on success, false otherwise
    */
    bool write();

    /** Read the model on the calling (GUI) thread and return the complete CSV
        text. This is the only step that touches the model.
    */
    QString snapshot() const;

    /** Write CSV text produced by snapshot(). Touches no model or widget, so a
        caller may run it on a worker thread to keep file I/O off the GUI thread.
        @returns true on success, false otherwise
    */
    static bool writeSnapshot(const QString& filename, const QString& csv);

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
