// Copyright (c) 2014-2022 The Blackcoin - Blackcoin developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/initexecutor.h>

#include <interfaces/node.h>
#include <util/exception.h>
#include <logging.h>
#include <util/thread_qos.h>
#include <util/threadnames.h>

#include <exception>

#include <QDebug>
#include <QMetaObject>
#include <QObject>
#include <QString>
#include <QThread>

InitExecutor::InitExecutor(interfaces::Node& node)
    : QObject(), m_node(node)
{
    m_context.moveToThread(&m_thread);
    m_thread.start();
}

InitExecutor::~InitExecutor()
{
    qDebug() << __func__ << ": Stopping thread";
    m_thread.quit();
    m_thread.wait();
    qDebug() << __func__ << ": Stopped thread";
}

void InitExecutor::handleRunawayException(const std::exception* e)
{
    PrintExceptionContinue(e, "Runaway exception");
    Q_EMIT runawayException(QString::fromStdString(m_node.getWarnings().translated));
}

void InitExecutor::initialize()
{
    QMetaObject::invokeMethod(&m_context, [this] {
        try {
            util::ThreadRename("qt-init");
            // The init thread loads every wallet. Left at the default, macOS
            // may run it on the efficiency cores while the window is in the
            // background.
            // A thread does not inherit its starter's class (measured), so
            // every node thread started with TraceThread asks for the class
            // itself from now on: scheduler, network, script checks, import.
            util::SetDefaultThreadQosUserInitiated(true);
            const bool qos_set = util::SetCurrentThreadQosUserInitiated();
            LogPrintf("qt-init thread QoS: set=%s class=%s\n", qos_set ? "yes" : "no",
                      util::CurrentThreadQosName().value_or("n/a"));
            qDebug() << "Running initialization in thread";
            interfaces::BlockAndHeaderTipInfo tip_info;
            interfaces::AppInitResult result = m_node.appInitMain(&tip_info);
            Q_EMIT initializeResult(result, tip_info);
        } catch (const std::exception& e) {
            handleRunawayException(&e);
        } catch (...) {
            handleRunawayException(nullptr);
        }
    });
}

void InitExecutor::shutdown()
{
    QMetaObject::invokeMethod(&m_context, [this] {
        try {
            util::SetCurrentThreadQosUserInitiated();
            qDebug() << "Running Shutdown in thread";
            m_node.appShutdown();
            qDebug() << "Shutdown finished";
            Q_EMIT shutdownResult();
        } catch (const std::exception& e) {
            handleRunawayException(&e);
        } catch (...) {
            handleRunawayException(nullptr);
        }
    });
}
