// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.
#ifndef BITCOIN_QT_VISIBILITYCONTROLLER_H
#define BITCOIN_QT_VISIBILITYCONTROLLER_H

#include <QEvent>
#include <QGuiApplication>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QWidget>
#include <functional>
#include <utility>

/** Page work follows explicit application and top-level window state. Native
 * minimize/application-hide need not deliver a child QWidget hide event.
 * Inactive but visible windows keep working. Restore is event driven, with no
 * dependency on the work timer that suspension stopped.
 */
class VisibilityController final : public QObject
{
public:
    VisibilityController(QWidget& page, std::function<void(bool)> changed,
                         std::function<bool()> content_visible = [] { return true; })
        : m_page(&page), m_changed(std::move(changed)), m_content_visible(std::move(content_visible)),
          m_application_state(QGuiApplication::applicationState())
    {
        page.installEventFilter(this);
        connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState state) {
            m_application_state = state;
            refresh();
        });
    }

    static bool AllowsWork(bool page_visible, bool minimized, Qt::ApplicationState state, bool content_visible)
    {
        return page_visible && !minimized && content_visible &&
               state != Qt::ApplicationHidden && state != Qt::ApplicationSuspended;
    }
    bool active() const { return m_active; }
    void refresh()
    {
        if (!m_page) return;
        QWidget* window = m_page->window();
        if (m_window != window) {
            if (m_window && m_window != m_page) m_window->removeEventFilter(this);
            m_window = window;
            if (m_window != m_page) m_window->installEventFilter(this);
        }
        setActive(AllowsWork(m_page->isVisible() && window->isVisible(), window->isMinimized(), m_application_state, m_content_visible()));
    }
protected:
    bool eventFilter(QObject* object, QEvent* event) override
    {
        switch (event->type()) {
        case QEvent::Hide:
            if (object == m_page || object == m_window) setActive(false);
            break;
        case QEvent::Show:
        case QEvent::WindowStateChange:
        case QEvent::ParentChange:
            refresh();
            // Refresh once after delivery too, when widget visibility and a
            // reparented window are final. The receiver owns this queued call.
            QTimer::singleShot(0, this, [this] { refresh(); });
            break;
        default: break;
        }
        return QObject::eventFilter(object, event);
    }
private:
    QPointer<QWidget> m_page, m_window;
    std::function<void(bool)> m_changed;
    std::function<bool()> m_content_visible;
    Qt::ApplicationState m_application_state;
    bool m_active{false};
    void setActive(bool active)
    {
        if (m_active == active) return;
        m_active = active;
        m_changed(active);
    }
};
#endif // BITCOIN_QT_VISIBILITYCONTROLLER_H
