// Copyright (c) 2011-2018 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/csvmodelwriter.h>

#include <QAbstractItemModel>
#include <QFile>
#include <QTextStream>

#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

namespace {
void AppendValue(QString& out, const QString& value)
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

/** Single writer thread fed by a queue bounded to one pending batch. */
class BatchWriter
{
public:
    explicit BatchWriter(QFile& file) : m_thread([this, &file] { Run(file); }) {}
    ~BatchWriter() { Finish(); }

    //! Queue one formatted batch. Returns false once the writer has failed.
    bool Push(QString batch)
    {
        std::unique_lock lock{m_mutex};
        m_space.wait(lock, [this] { return m_queue.empty() || m_failed; });
        if (m_failed) return false;
        m_queue.push_back(std::move(batch));
        m_ready.notify_one();
        return true;
    }

    //! Wait for every queued batch to be written. Returns false on any failure.
    bool Finish()
    {
        {
            std::lock_guard lock{m_mutex};
            m_done = true;
        }
        m_ready.notify_one();
        if (m_thread.joinable()) m_thread.join();
        return !m_failed;
    }

private:
    void Run(QFile& file)
    {
        // Text mode keeps the legacy line-ending translation; the stream is
        // flushed after every batch so a write error is seen promptly.
        QTextStream out(&file);
        while (true) {
            QString batch;
            {
                std::unique_lock lock{m_mutex};
                m_ready.wait(lock, [this] { return !m_queue.empty() || m_done; });
                if (m_queue.empty()) return;
                batch = std::move(m_queue.front());
                m_queue.pop_front();
            }
            m_space.notify_one();
            out << batch;
            out.flush();
            if (out.status() != QTextStream::Ok || file.error() != QFile::NoError) {
                std::lock_guard lock{m_mutex};
                m_failed = true;
                m_queue.clear();
                m_space.notify_all();
                return;
            }
        }
    }

    std::mutex m_mutex;
    std::condition_variable m_ready;
    std::condition_variable m_space;
    std::deque<QString> m_queue;
    bool m_done{false};
    bool m_failed{false};
    std::thread m_thread;
};
} // namespace

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

bool CSVModelWriter::write()
{
    QFile file(filename);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;

    const int numRows = model ? model->rowCount() : 0;
    bool ok{true};
    {
        BatchWriter writer{file};
        QString batch;

        // Header row
        for (int i = 0; i < columns.size(); ++i) {
            if (i != 0) batch += QLatin1Char(',');
            AppendValue(batch, columns[i].title);
        }
        batch += QLatin1Char('\n');

        // Data rows, read here on the model's thread in bounded batches.
        for (int j = 0; j < numRows; ++j) {
            for (int i = 0; i < columns.size(); ++i) {
                if (i != 0) batch += QLatin1Char(',');
                const QVariant data = model->index(j, columns[i].column).data(columns[i].role);
                AppendValue(batch, data.toString());
            }
            batch += QLatin1Char('\n');
            if ((j + 1) % BATCH_ROWS == 0) {
                if (!writer.Push(std::move(batch))) break;
                batch = QString{};
            }
        }
        if (!batch.isEmpty()) writer.Push(std::move(batch));
        ok = writer.Finish();
    }
    file.close();
    return ok && file.error() == QFile::NoError;
}
