// Copyright (c) 2011-2018 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/csvmodelwriter.h>

#include <QAbstractItemModel>
#include <QFile>
#include <QTextStream>

CSVModelWriter::CSVModelWriter(const QString& _filename, QObject* parent)
    : QObject(parent),
      filename(_filename)
{
}

void CSVModelWriter::setModel(const QAbstractItemModel *_model)
{
    this->model = _model;
}

void CSVModelWriter::addColumn(const QString &title, int column, int role)
{
    Column col;
    col.title = title;
    col.column = column;
    col.role = role;

    columns.append(col);
}

static void appendValue(QString& out, const QString& value)
{
    out += QLatin1Char('"');
    if (value.contains(QLatin1Char('"'))) {
        QString escaped = value;
        escaped.replace(QLatin1Char('"'), QLatin1String("\"\""));
        out += escaped;
    } else {
        out += value;
    }
    out += QLatin1Char('"');
}

QString CSVModelWriter::snapshot() const
{
    const int numRows = model ? model->rowCount() : 0;
    QString out;

    // Header row
    for (int i = 0; i < columns.size(); ++i) {
        if (i != 0) out += QLatin1Char(',');
        appendValue(out, columns[i].title);
    }
    out += QLatin1Char('\n');
    if (numRows > 0) out.reserve(out.size() * (numRows + 1));

    // Data rows
    for (int j = 0; j < numRows; ++j) {
        for (int i = 0; i < columns.size(); ++i) {
            if (i != 0) out += QLatin1Char(',');
            const QVariant data = model->index(j, columns[i].column).data(columns[i].role);
            appendValue(out, data.toString());
        }
        out += QLatin1Char('\n');
    }
    return out;
}

bool CSVModelWriter::writeSnapshot(const QString& filename, const QString& csv)
{
    QFile file(filename);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;
    QTextStream out(&file);
    out << csv;
    out.flush();
    file.close();
    return file.error() == QFile::NoError;
}

bool CSVModelWriter::write()
{
    return writeSnapshot(filename, snapshot());
}
