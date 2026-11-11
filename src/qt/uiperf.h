// Copyright (c) 2026 The Blackcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.
#ifndef BITCOIN_QT_UIPERF_H
#define BITCOIN_QT_UIPERF_H

#include <qt/transactionfilterproxy.h>

#include <QAction>
#include <QApplication>
#include <QComboBox>
#include <QDockWidget>
#include <QMainWindow>
#include <QHeaderView>
#include <QInputEvent>
#include <QItemSelectionModel>
#include <QLabel>
#include <QPaintEvent>
#include <QPointer>
#include <QPushButton>
#include <QStandardItemModel>
#include <QTableView>
#include <QThread>
#include <QVBoxLayout>
#include <QWindowStateChangeEvent>
#include <exception>

#include <QDateTime>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QObject>
#include <QTimer>

#include <algorithm>
#include <array>
#include <vector>

#ifndef Q_OS_WIN
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

/** Opt-in timer-lateness trace. This does not measure input-to-paint latency.
 * No disk writes occur while sampling. The caller must finish after app.exec().
 * A crash leaves an empty/incomplete trace, never a completed measurement.
 */
class UiPerfProbe : public QObject
{
public:
    static constexpr int PERIOD_MS{20};
    static constexpr size_t TRACE_CAPACITY{65536};
    static constexpr size_t TIME_BUCKET_CAPACITY{18000}; // Five hours at one-second resolution.
    explicit UiPerfProbe(size_t capacity = TRACE_CAPACITY) : m_capacity(std::min(capacity, TRACE_CAPACITY))
    {
        m_timer.setTimerType(Qt::PreciseTimer);
        m_timer.setInterval(PERIOD_MS);
        connect(&m_timer, &QTimer::timeout, this, [this] { record(m_clock.nsecsElapsed()); });
    }
    bool start(const QString& path, QString& error)
    {
        if (m_started || !QFileInfo(path).isAbsolute()) { error = QStringLiteral("UI performance output must be a new absolute path"); return false; }
#ifdef Q_OS_WIN
        error = QStringLiteral("UI performance trace secure file creation is supported on POSIX platforms only");
        return false;
#else
        const QByteArray native = QFile::encodeName(path);
        const int fd = ::open(native.constData(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR);
        if (fd < 0) { error = QStringLiteral("Cannot exclusively create UI performance output"); return false; }
        struct stat st{};
        if (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != ::getuid() || (st.st_mode & 0777) != 0600 ||
            !m_file.open(fd, QIODevice::WriteOnly, QFileDevice::AutoCloseHandle)) {
            ::close(fd);
            error = QStringLiteral("UI performance output failed ownership/type/mode checks");
            return false;
        }
        // Allocate only when explicitly enabled, before the measured loop.
        m_samples.reserve(m_capacity);
        m_time_buckets.reserve(TIME_BUCKET_CAPACITY);
        m_started = true;
        m_started_utc = QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
        m_clock.start();
        m_timer.start();
        return true;
#endif
    }
    // Public accumulator permits deterministic monotonicity/overflow tests.
    void record(qint64 elapsed_ns)
    {
        if (elapsed_ns <= m_last_ns) { ++m_nonmonotonic; return; }
        const qint64 gap = elapsed_ns - m_last_ns;
        m_last_ns = elapsed_ns;
        const qint64 late = std::max<qint64>(0, gap - PERIOD_MS * 1000000LL);
        m_max_lateness_ns = std::max(m_max_lateness_ns, late);
        ++m_count;
        const std::array<qint64, 6> limits{5000000, 16000000, 50000000, 100000000, 250000000, 1000000000};
        size_t bucket{0};
        while (bucket < limits.size() && late > limits[bucket]) ++bucket;
        ++m_histogram[bucket];
        const auto second = static_cast<size_t>(elapsed_ns / 1000000000LL);
        if (second < TIME_BUCKET_CAPACITY) {
            if (m_time_buckets.size() <= second) m_time_buckets.resize(second + 1);
            auto& time_bucket = m_time_buckets[second];
            ++time_bucket.count;
            time_bucket.max_lateness_ns = std::max(time_bucket.max_lateness_ns, late);
            ++time_bucket.histogram[bucket];
        } else {
            ++m_unbucketed;
        }
        if (m_samples.size() < m_capacity) m_samples.push_back({elapsed_ns, gap});
        else ++m_dropped;
    }
    qint64 count() const { return m_count; }
    qint64 dropped() const { return m_dropped; }
    qint64 nonmonotonic() const { return m_nonmonotonic; }
    qint64 maxLatenessNs() const { return m_max_lateness_ns; }
    bool finish(QString& error)
    {
        m_timer.stop();
        if (!m_started || m_finished) return true;
        m_finished = true;
        // Seal the measured interval before any serialization/I/O. The event
        // loop may have quit inside a blocking callback before the timer could
        // report its final gap. Preserve that right-censored interval separately
        // rather than inventing a delivered callback or omitting the stall.
        const qint64 measurement_end_ns = m_clock.nsecsElapsed();
        const qint64 terminal_gap_ns = std::max<qint64>(0, measurement_end_ns - m_last_ns);
        const qint64 terminal_lateness_lower_bound_ns = std::max<qint64>(0, terminal_gap_ns - PERIOD_MS * 1000000LL);
        const qint64 covered_max_lateness_ns = std::max(m_max_lateness_ns, terminal_lateness_lower_bound_ns);
        const auto write = [this](const QJsonObject& object) {
            const QByteArray line = QJsonDocument(object).toJson(QJsonDocument::Compact) + '\n';
            return m_file.write(line) == line.size();
        };
        bool ok = write({{"schema", 2}, {"metric", "event_loop_timer_lateness"}, {"paint_latency", false},
                         {"period_ms", PERIOD_MS}, {"start_utc", m_started_utc}, {"trace_capacity", static_cast<qint64>(m_capacity)},
                         {"time_bucket_capacity_seconds", static_cast<qint64>(TIME_BUCKET_CAPACITY)}});
        qint64 sequence{0};
        for (const Sample& sample : m_samples) {
            ok = write({{"kind", "sample"}, {"sequence", ++sequence}, {"elapsed_ns", sample.elapsed}, {"gap_ns", sample.gap},
                        {"lateness_ns", std::max<qint64>(0, sample.gap - PERIOD_MS * 1000000LL)}}) && ok;
        }
        for (size_t second = 0; second < m_time_buckets.size(); ++second) {
            const auto& time_bucket = m_time_buckets[second];
            QJsonArray counts;
            for (const auto count : time_bucket.histogram) counts.append(count);
            ok = write({{"kind", "second"}, {"elapsed_second", static_cast<qint64>(second)},
                        {"samples", time_bucket.count}, {"max_lateness_ns", time_bucket.max_lateness_ns},
                        {"histogram_counts", counts}}) && ok;
        }
        ok = write({{"kind", "terminal_interval"}, {"start_elapsed_ns", m_last_ns},
                    {"end_elapsed_ns", measurement_end_ns}, {"gap_ns", terminal_gap_ns},
                    {"lateness_lower_bound_ns", terminal_lateness_lower_bound_ns},
                    {"timer_callback_delivered", false}}) && ok;
        QJsonArray histogram;
        for (const auto value : m_histogram) histogram.append(value);
        if (ok) ok = write({{"complete", true}, {"samples", m_count}, {"retained", static_cast<qint64>(m_samples.size())},
                    {"truncated_raw_trace_samples", m_dropped}, {"time_bucket_overflow_samples", m_unbucketed},
                    {"all_callback_statistics_include_truncated_samples", true}, {"nonmonotonic_rejected", m_nonmonotonic},
                    {"max_lateness_ns", m_max_lateness_ns}, {"histogram_le_ms", QJsonArray{5, 16, 50, 100, 250, 1000}},
                    {"histogram_counts", histogram}, {"histogram_scope", "delivered_callbacks_only"},
                    {"terminal_interval_accounted", true}, {"terminal_gap_ns", terminal_gap_ns},
                    {"terminal_lateness_lower_bound_ns", terminal_lateness_lower_bound_ns},
                    {"covered_max_lateness_ns", covered_max_lateness_ns},
                    {"elapsed_ns", measurement_end_ns}}) && ok;
        ok = m_file.flush() && ok;
        m_file.close();
        if (!ok) error = QStringLiteral("UI performance trace write failed; measurement is incomplete");
        return ok;
    }
private:
    struct Sample { qint64 elapsed; qint64 gap; };
    struct TimeBucket {
        qint64 count{0};
        qint64 max_lateness_ns{0};
        std::array<qint64, 7> histogram{};
    };
    size_t m_capacity;
    std::vector<Sample> m_samples;
    std::vector<TimeBucket> m_time_buckets;
    std::array<qint64, 7> m_histogram{};
    QTimer m_timer;
    QElapsedTimer m_clock;
    QFile m_file;
    QString m_started_utc;
    qint64 m_last_ns{0}, m_count{0}, m_dropped{0}, m_nonmonotonic{0}, m_max_lateness_ns{0}, m_unbucketed{0};
    bool m_started{false}, m_finished{false};
};

/** Diagnostic notify durations are inclusive of nested dispatch and must not
 * be summed as independent stalls. Receiver categories contain no object names,
 * wallet identifiers or pointers. Threshold is capture policy, not a pass gate.
 */
class UiSlowNotifyJournal
{
public:
    static constexpr size_t CAPACITY{4096};
    static constexpr qint64 THRESHOLD_NS{100000000};
    enum class Receiver { APPLICATION, REGISTERED_VIEWPORT, TABLE, WIDGET, OTHER_OBJECT };
    struct Record {
        quint64 sequence{0}, parent{0};
        qint64 started_ns{0}, ended_ns{0};
        int event_type{0}, loop_level{0}, depth{0}, target_role{-1};
        Receiver receiver{Receiver::OTHER_OBJECT};
        bool exception{false};
    };
    void reserve() { m_records.reserve(CAPACITY); }
    void complete(const Record& record)
    {
        ++m_completed;
        if (record.ended_ns - record.started_ns < THRESHOLD_NS) return;
        ++m_slow;
        if (m_records.size() == CAPACITY) { ++m_overflow; return; }
        m_records.push_back(record);
    }
    const std::vector<Record>& records() const { return m_records; }
    quint64 completed() const { return m_completed; }
    quint64 slow() const { return m_slow; }
    quint64 overflow() const { return m_overflow; }
private:
    std::vector<Record> m_records;
    quint64 m_completed{0}, m_slow{0}, m_overflow{0};
};

/** Opt-in Qt delivery to view paint-handler completion. All hot-path records
 * are bounded, in-memory POD values. This is NOT physical input to display,
 * compositor completion, or proof that a particular pixel changed. Paint must
 * cover the relevant region after the matching semantic state is ready.
 */
class UiPaintProbe : public QObject
{
public:
    enum class Role { HISTORY, PEERS, CALIBRATION };
    enum class Action { ROW, SORT, NAVIGATE, FILTER_RESULT, RESTORE, CALIBRATION };
    enum class FilterChannel { NONE, SEARCH, AMOUNT, COMBO };
    enum class EpochReason { NONE, SOURCE_BINDING, SOURCE_RESET, SOURCE_DESTROYED, SOURCE_ROWS, SOURCE_DATA, FILTER, SORT, ACTIVATION, SOURCE_LAYOUT };
    enum class Outcome { PENDING, PAINTED, NO_DELIVERED_INPUT, OVERLAPPED, TIMEOUT,
                         HIDDEN, REBOUND, DESTROYED, GENERATION_CHANGED, NO_STATE_CHANGE,
                         SHUTDOWN, EXCEPTION };
    static constexpr size_t CAPACITY{65536};
    static constexpr size_t TARGET_CAPACITY{16};
    static constexpr size_t INPUT_DEPTH{32};
    static constexpr qint64 DEADLINE_NS{5000000000LL};
    struct Record {
        quint64 id{0}, target{0}, generation{0}, input{0}, raw_input_timestamp_ms{0}, unconfirmed_paints{0};
        qint64 delivered_ns{0}, semantic_ns{0}, ready_ns{0}, paint_begin_ns{0}, paint_end_ns{0}, terminal_ns{0};
        qint64 requested_delay_ms{0}, actual_delay_ns{0};
        quint64 cancel_previous_generation{0}, cancel_new_generation{0};
        EpochReason epoch_reason{EpochReason::NONE};
        int event_type{0};
        Role role{Role::HISTORY};
        Action action{Action::ROW};
        FilterChannel filter_channel{FilterChannel::NONE};
        Outcome outcome{Outcome::PENDING};
        bool spontaneous{false}, calibration{false};
    };
    static UiPaintProbe* current() { return slot(); } // Null in every other thread.
    explicit UiPaintProbe(size_t capacity = CAPACITY, qint64 deadline_ns = DEADLINE_NS)
        : m_capacity(std::min(capacity, CAPACITY)), m_deadline_ns(std::max<qint64>(1, std::min(deadline_ns, DEADLINE_NS)))
    {
        m_timer.setInterval(100);
        connect(&m_timer, &QTimer::timeout, this, [this] { expire(); });
    }
    ~UiPaintProbe() override { if (slot() == this) slot() = nullptr; }
    bool start(const QString& path, QString& error)
    {
        if (m_started || slot() || !qApp || QThread::currentThread() != qApp->thread() || !QFileInfo(path).isAbsolute()) {
            error = QStringLiteral("Paint trace requires the GUI thread and a new absolute private path"); return false;
        }
#ifdef Q_OS_WIN
        error = QStringLiteral("Secure paint trace creation requires POSIX"); return false;
#else
        const QByteArray native = QFile::encodeName(path);
        const int fd = ::open(native.constData(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR);
        if (fd < 0) { error = QStringLiteral("Cannot exclusively create paint trace"); return false; }
        struct stat st{};
        if (::fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != ::getuid() || (st.st_mode & 0777) != 0600 ||
            !m_file.open(fd, QIODevice::WriteOnly, QFileDevice::AutoCloseHandle)) {
            ::close(fd); error = QStringLiteral("Paint trace failed ownership/type/mode checks"); return false;
        }
        m_records.reserve(m_capacity);
        m_slow_notify.reserve();
        m_started = true;
        m_utc = QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs);
        m_last_app_state = qApp->applicationState();
        m_clock.start();
        slot() = this;
        m_timer.start();
        return true;
#endif
    }
    class NotifyScope
    {
    public:
        NotifyScope(QObject* receiver, QEvent* event) : m_probe(current()), m_exceptions(std::uncaught_exceptions())
        {
            if (m_probe) {
                m_dispatch = m_probe->dispatchBegin(receiver, event);
                m_token = m_probe->enter(receiver, event);
            }
        }
        ~NotifyScope()
        {
            if (m_probe && current() == m_probe) {
                const auto ended = m_probe->now();
                const bool exception = std::uncaught_exceptions() > m_exceptions;
                m_probe->leave(m_token, exception);
                m_probe->dispatchEnd(m_dispatch, ended, exception);
            }
        }
        NotifyScope(const NotifyScope&) = delete;
        NotifyScope& operator=(const NotifyScope&) = delete;
    private:
        QPointer<UiPaintProbe> m_probe;
        int m_token{-1}, m_exceptions;
        UiSlowNotifyJournal::Record m_dispatch;
    };
    qint64 now() const { return m_clock.nsecsElapsed(); }
    bool hasDeliveredInput() const { return activeInput() != nullptr; }
    const std::vector<Record>& records() const { return m_records; }
    quint64 dropped() const { return m_dropped; }
    const UiSlowNotifyJournal& slowNotifyJournal() const { return m_slow_notify; }
    void bind(QWidget* view, Role role, quint64 generation, bool ready)
    {
        if (find(view)) return;
        for (auto& target : m_targets) {
            if (target.view) continue;
            // QPointer may already have become null before a destroyed callback.
            cancel(target, Outcome::DESTROYED);
            target = Target{};
            target.view = view;
            target.role = role;
            target.id = ++m_target_sequence;
            target.generation = generation;
            target.ready = ready;
            return;
        }
        ++m_target_overflow;
    }
    void remove(QWidget* view, Outcome reason)
    {
        if (auto* target = find(view)) { cancel(*target, reason); *target = Target{}; }
    }
    void cancel(QWidget* view, Outcome reason) { if (auto* target = find(view)) cancel(*target, reason); }
    void action(QWidget* view, Action action, bool await_update = false, const QRect& region = {}, FilterChannel channel = FilterChannel::NONE)
    {
        auto* target = find(view);
        if (!target) return;
        const auto* input = activeInput();
        // Child show delivery during a restore is part of that one restore
        // trial, not a new input or an overlapping navigation request.
        if (!input && action == Action::NAVIGATE && target->pending >= 0 &&
            m_records[target->pending].action == Action::RESTORE) return;
        if (target->pending >= 0 && input && m_records[target->pending].input == input->id) {
            // A sort can synchronously move the current row. Preserve the
            // explicit sort/navigation trial instead of starting a second one.
            return;
        }
        begin(*target, action, input, await_update, region, 0, channel);
    }
    // Called only around the existing debounce callback, not when a keystroke
    // occurs. An unrelated model generation during the debounce censors it.
    void deferred(QWidget* view, bool active, FilterChannel channel)
    {
        if (auto* target = find(view)) {
            if (active) {
                target->deferred = target->pending >= 0 && m_records[target->pending].action == Action::FILTER_RESULT &&
                    m_records[target->pending].filter_channel == channel;
            } else {
                const bool matching_callback = target->deferred;
                target->deferred = false;
                if (matching_callback && target->pending >= 0 && target->await_update) cancel(*target, Outcome::NO_STATE_CHANGE);
            }
        }
    }
    void generation(QWidget* view, quint64 generation, bool ready, EpochReason reason = EpochReason::NONE)
    {
        auto* target = find(view);
        if (!target) return;
        if (target->generation != generation && target->pending >= 0) {
            auto& record = m_records[target->pending];
            const auto* input = activeInput();
            const bool same_input = input && input->id == record.input;
            const bool own_debounce = target->deferred && target->await_update && record.action == Action::FILTER_RESULT;
            const bool same_restore = m_restore_depth && QThread::currentThread()->loopLevel() == m_restore_loop && record.action == Action::RESTORE;
            const bool external_source_change = reason == EpochReason::SOURCE_BINDING || reason == EpochReason::SOURCE_RESET ||
                reason == EpochReason::SOURCE_DESTROYED || reason == EpochReason::SOURCE_ROWS || reason == EpochReason::SOURCE_DATA || reason == EpochReason::SOURCE_LAYOUT;
            if (!external_source_change && (same_input || own_debounce || same_restore)) {
                record.generation = generation;
                record.ready_ns = 0;
                target->await_update = false;
            } else {
                cancel(*target, Outcome::GENERATION_CHANGED, generation, reason);
            }
        }
        target->generation = generation;
        target->ready = ready;
        if (ready && target->pending >= 0 && !target->await_update && m_records[target->pending].ready_ns == 0) m_records[target->pending].ready_ns = now();
    }
    void calibrationDelay(QWidget* view, int requested_ms, qint64 actual_ns)
    {
        if (auto* target = find(view); target && target->pending >= 0) {
            auto& record = m_records[target->pending];
            if (record.calibration) { record.requested_delay_ms = requested_ms; record.actual_delay_ns = actual_ns; }
        }
    }
    struct PaintToken { quint64 target{0}, record{0}, generation{0}; qint64 started{0}; bool covered{false}; };
    PaintToken beforePaint(QWidget* view, const QRegion& region)
    {
        expire();
        auto* target = find(view);
        if (!target || target->pending < 0 || !target->ready || target->await_update || !view->isVisible() || view->window()->isMinimized()) return {};
        auto& record = m_records[target->pending];
        const QRect required = target->region.isEmpty() ? view->rect() : target->region.intersected(view->rect());
        // Constant work, no region unions or allocations in this hook. A
        // fragmented region is conservatively unconfirmed even if its union
        // covers the target. Report that limitation separately from elapsed time.
        const bool covered = !required.isEmpty() && region.rectCount() == 1 && region.boundingRect().contains(required);
        if (!covered) ++record.unconfirmed_paints;
        return {target->id, record.id, target->generation, now(), covered};
    }
    void afterPaint(QWidget* view, const PaintToken& token)
    {
        auto* target = find(view);
        if (!token.covered || !target || target->id != token.target || target->pending < 0 ||
            target->generation != token.generation || !target->ready || target->await_update) return;
        auto& record = m_records[target->pending];
        if (record.id != token.record) return;
        const auto ended = now();
        if (ended - record.delivered_ns > m_deadline_ns) { cancel(*target, Outcome::TIMEOUT); return; }
        record.paint_begin_ns = token.started;
        record.paint_end_ns = ended;
        record.terminal_ns = ended;
        record.outcome = Outcome::PAINTED;
        target->pending = -1;
    }
    // Seal both probes before either serializes its potentially large output.
    // This prevents post-loop disk/JSON work from becoming a measured stall.
    void seal()
    {
        if (!m_started || m_sealed) return;
        m_sealed = true;
        m_timer.stop();
        expire();
        for (auto& target : m_targets) cancel(target, Outcome::SHUTDOWN);
        if (slot() == this) slot() = nullptr;
        m_end_ns = now();
    }
    bool finish(QString& error)
    {
        if (!m_started || m_finished) return true;
        m_finished = true;
        seal();
        const auto ended = m_end_ns;
        QJsonArray records;
        for (const auto& record : m_records) {
            records.append(QJsonObject{{"id", qint64(record.id)}, {"target", qint64(record.target)}, {"generation", qint64(record.generation)},
                {"input_id", qint64(record.input)}, {"qt_input_timestamp_ms", QString::number(record.raw_input_timestamp_ms)},
                {"event_type", record.event_type}, {"spontaneous", record.spontaneous}, {"role", int(record.role)},
                {"action", int(record.action)}, {"filter_channel", int(record.filter_channel)}, {"outcome", int(record.outcome)}, {"calibration", record.calibration},
                {"delivered_ns", record.delivered_ns}, {"semantic_ns", record.semantic_ns}, {"ready_ns", record.ready_ns},
                {"paint_begin_ns", record.paint_begin_ns}, {"paint_end_ns", record.paint_end_ns}, {"terminal_ns", record.terminal_ns},
                {"requested_delay_ms", record.requested_delay_ms}, {"actual_delay_ns", record.actual_delay_ns},
                {"unconfirmed_paints", qint64(record.unconfirmed_paints)},
                {"cancel_previous_generation", qint64(record.cancel_previous_generation)},
                {"cancel_new_generation", qint64(record.cancel_new_generation)}, {"epoch_reason", int(record.epoch_reason)}});
        }
        QJsonArray slow_dispatches;
        for (const auto& dispatch : m_slow_notify.records()) {
            slow_dispatches.append(QJsonObject{{"sequence", qint64(dispatch.sequence)}, {"parent", qint64(dispatch.parent)},
                {"started_ns", dispatch.started_ns}, {"ended_ns", dispatch.ended_ns},
                {"inclusive_duration_ns", dispatch.ended_ns - dispatch.started_ns}, {"event_type", dispatch.event_type},
                {"loop_level", dispatch.loop_level}, {"depth", dispatch.depth}, {"receiver_category", int(dispatch.receiver)},
                {"registered_target_role", dispatch.target_role}, {"exception", dispatch.exception}});
        }
        const QJsonObject dispatch_journal{{"threshold_ns", UiSlowNotifyJournal::THRESHOLD_NS},
            {"capacity", qint64(UiSlowNotifyJournal::CAPACITY)}, {"started", qint64(m_dispatch_sequence)},
            {"completed", qint64(m_slow_notify.completed())}, {"slow_total", qint64(m_slow_notify.slow())},
            {"overflow", qint64(m_slow_notify.overflow())}, {"outstanding_at_seal", m_dispatch_depth},
            {"storage_lossless", m_slow_notify.overflow() == 0 && m_dispatch_depth == 0},
            {"durations_include_nested_dispatch", true}, {"stack_or_gap_attribution", false},
            {"receiver_categories", QJsonArray{"application", "registered_viewport", "table", "widget", "other_object"}},
            {"records", slow_dispatches}};
        const QJsonObject document{{"schema", "blackcoin.qt-delivery-paint.v1"}, {"complete", true}, {"start_utc", m_utc},
            {"metric", "qt_delivered_event_to_relevant_view_paint_handler_completion"}, {"physical_input_to_display", false},
            {"qt_timestamp_subtracted_from_monotonic_clock", false}, {"automatic_pass_judgment", false},
            {"restore_scope", "visible_registered_history_or_peers_or_calibration_viewport"},
            {"paint_scope", "original_view_paint_handler_returned_after_covering_relevant_region"},
            {"roles", QJsonArray{"history", "peers", "calibration"}},
            {"actions", QJsonArray{"row", "sort", "navigate", "filter_final_result", "restore_event", "calibration"}},
            {"filter_channels", QJsonArray{"none", "search", "amount", "combo"}},
            {"epoch_reasons", QJsonArray{"none", "source_binding", "source_reset", "source_destroyed", "source_rows", "source_data", "filter", "sort", "activation", "source_layout"}},
            {"outcomes", QJsonArray{"pending", "painted", "no_delivered_input", "overlapped", "timeout", "hidden", "rebound", "destroyed", "generation_changed", "no_state_change", "shutdown", "exception"}},
            {"elapsed_ns", ended}, {"deadline_ns", m_deadline_ns}, {"capacity", qint64(m_capacity)},
            {"dropped_trials", qint64(m_dropped)}, {"target_overflow", qint64(m_target_overflow)},
            {"input_depth_overflow", qint64(m_input_overflow)},
            {"storage_lossless", m_dropped == 0 && m_target_overflow == 0 && m_input_overflow == 0 && m_slow_notify.overflow() == 0 && m_dispatch_depth == 0},
            {"coverage_requires_external_operation_inventory", true}, {"slow_notify_journal", dispatch_journal}, {"records", records}};
        const QByteArray bytes = QJsonDocument(document).toJson(QJsonDocument::Compact) + '\n';
        const bool written = m_file.write(bytes) == bytes.size();
        const bool flushed = m_file.flush();
        m_file.close();
        if (!written || !flushed) error = QStringLiteral("Paint trace write failed; measurement is incomplete");
        return written && flushed;
    }
private:
    struct Input { const QEvent* event{nullptr}; quint64 id{0}, timestamp{0}; qint64 delivered{0}; int type{0}, loop{0}; bool spontaneous{false}; };
    struct Target {
        QPointer<QWidget> view;
        Role role{Role::HISTORY};
        quint64 id{0}, generation{0};
        int pending{-1};
        QRect region;
        bool ready{false}, await_update{false}, deferred{false};
    };
    static UiPaintProbe*& slot() { static thread_local UiPaintProbe* value{nullptr}; return value; }
    Target* find(QWidget* view) { for (auto& target : m_targets) if (target.view == view) return &target; return nullptr; }
    const Input* activeInput() const
    {
        if (m_suppressed) return nullptr;
        const int loop = QThread::currentThread()->loopLevel();
        for (size_t i = m_depth; i > 0; --i) if (m_inputs[i - 1].loop == loop) return &m_inputs[i - 1];
        return nullptr;
    }
    UiSlowNotifyJournal::Record dispatchBegin(QObject* receiver, QEvent* event)
    {
        UiSlowNotifyJournal::Record record;
        record.started_ns = now();
        record.sequence = ++m_dispatch_sequence;
        record.parent = m_active_dispatch;
        record.depth = ++m_dispatch_depth;
        record.event_type = int(event->type());
        record.loop_level = QThread::currentThread()->loopLevel();
        using Receiver = UiSlowNotifyJournal::Receiver;
        if (receiver == qApp) record.receiver = Receiver::APPLICATION;
        else if (auto* widget = qobject_cast<QWidget*>(receiver)) {
            if (auto* target = find(widget)) {
                record.receiver = Receiver::REGISTERED_VIEWPORT;
                record.target_role = int(target->role);
            } else record.receiver = qobject_cast<QTableView*>(receiver) ? Receiver::TABLE : Receiver::WIDGET;
        }
        m_active_dispatch = record.sequence;
        return record;
    }
    void dispatchEnd(UiSlowNotifyJournal::Record record, qint64 ended, bool exception)
    {
        record.ended_ns = ended;
        record.exception = exception;
        m_slow_notify.complete(record);
        m_active_dispatch = record.parent;
        --m_dispatch_depth;
    }
    int enter(QObject* receiver, QEvent* event)
    {
        const auto delivered = now();
        expire();
        const auto type = event->type();
        bool restoring{false};
        if (type == QEvent::WindowStateChange) {
            auto* window = qobject_cast<QWidget*>(receiver);
            const auto* changed = static_cast<QWindowStateChangeEvent*>(event);
            if (window && (changed->oldState() & Qt::WindowMinimized) && !window->isMinimized()) { restore(window, int(type), delivered); restoring = true; }
        } else if (type == QEvent::ApplicationStateChange && receiver == qApp) {
            const auto state = qApp->applicationState();
            if (state == Qt::ApplicationActive && (m_last_app_state == Qt::ApplicationHidden || m_last_app_state == Qt::ApplicationSuspended)) { restore(nullptr, int(type), delivered); restoring = true; }
            m_last_app_state = state;
        }
        if (restoring) {
            if (!m_restore_depth) m_restore_loop = QThread::currentThread()->loopLevel();
            ++m_restore_depth;
            return -3;
        }
        if (type != QEvent::MouseButtonPress && type != QEvent::MouseButtonRelease && type != QEvent::KeyPress && type != QEvent::Wheel) return -1;
        for (size_t i = 0; i < m_depth; ++i) if (m_inputs[i].event == event) return -1;
        if (m_depth == INPUT_DEPTH || m_suppressed) { ++m_input_overflow; ++m_suppressed; return -2; }
        const int token = int(m_depth++);
        const auto* input = static_cast<QInputEvent*>(event);
        m_inputs[token] = {event, ++m_input_sequence, quint64(input->timestamp()), delivered, int(type), QThread::currentThread()->loopLevel(), event->spontaneous()};
        return token;
    }
    void leave(int token, bool exception)
    {
        if (token == -3) { --m_restore_depth; return; }
        if (token == -2) { --m_suppressed; return; }
        if (token < 0) return;
        if (exception) for (auto& target : m_targets) if (target.pending >= 0 && m_records[target.pending].input == m_inputs[token].id) cancel(target, Outcome::EXCEPTION);
        m_depth = size_t(token);
    }
    void restore(QWidget* window, int type, qint64 delivered)
    {
        for (auto& target : m_targets) {
            if (!target.view || !target.view->isVisible() || target.view->window()->isMinimized() ||
                (window && target.view->window() != window)) continue;
            begin(target, Action::RESTORE, nullptr, false, {}, type, FilterChannel::NONE, delivered);
        }
    }
    void begin(Target& target, Action action, const Input* input, bool await_update, const QRect& region, int restore_type, FilterChannel channel = FilterChannel::NONE, qint64 restore_delivered = 0)
    {
        cancel(target, Outcome::OVERLAPPED);
        if (m_records.size() == m_capacity) { ++m_dropped; return; }
        Record record;
        record.id = m_records.size() + 1;
        record.target = target.id;
        record.generation = target.generation;
        record.role = target.role;
        record.action = action;
        record.filter_channel = channel;
        record.calibration = target.role == Role::CALIBRATION;
        record.semantic_ns = now();
        record.delivered_ns = input ? input->delivered : (restore_type ? restore_delivered : record.semantic_ns);
        if (input) { record.input = input->id; record.raw_input_timestamp_ms = input->timestamp; record.event_type = input->type; record.spontaneous = input->spontaneous; }
        else if (restore_type) record.event_type = restore_type;
        else { record.outcome = Outcome::NO_DELIVERED_INPUT; record.terminal_ns = record.semantic_ns; }
        if (target.ready && !await_update) record.ready_ns = record.semantic_ns;
        m_records.push_back(record);
        if (record.outcome == Outcome::PENDING) target.pending = int(m_records.size() - 1);
        target.region = region;
        target.await_update = await_update;
    }
    void cancel(Target& target, Outcome reason, quint64 next_generation = 0, EpochReason epoch_reason = EpochReason::NONE)
    {
        if (target.pending < 0) return;
        auto& record = m_records[target.pending];
        record.outcome = reason;
        record.cancel_previous_generation = target.generation;
        record.cancel_new_generation = next_generation ? next_generation : target.generation;
        record.epoch_reason = epoch_reason;
        record.terminal_ns = now();
        target.pending = -1;
        target.await_update = false;
    }
    void expire()
    {
        const auto elapsed = now();
        for (auto& target : m_targets) {
            if (target.pending < 0) continue;
            if (!target.view) cancel(target, Outcome::DESTROYED);
            else if (elapsed - m_records[target.pending].delivered_ns > m_deadline_ns) cancel(target, Outcome::TIMEOUT);
        }
    }
    size_t m_capacity, m_depth{0}, m_suppressed{0}, m_restore_depth{0};
    int m_restore_loop{0};
    qint64 m_deadline_ns, m_end_ns{0};
    quint64 m_input_sequence{0}, m_target_sequence{0}, m_dropped{0}, m_target_overflow{0}, m_input_overflow{0};
    std::vector<Record> m_records;
    UiSlowNotifyJournal m_slow_notify;
    quint64 m_dispatch_sequence{0}, m_active_dispatch{0};
    int m_dispatch_depth{0};
    std::array<Target, TARGET_CAPACITY> m_targets{};
    std::array<Input, INPUT_DEPTH> m_inputs{};
    QElapsedTimer m_clock;
    QTimer m_timer;
    QFile m_file;
    QString m_utc;
    Qt::ApplicationState m_last_app_state{Qt::ApplicationInactive};
    bool m_started{false}, m_finished{false}, m_sealed{false};
};

/** No Q_OBJECT or build target: preserves QTableView behavior and calls its
 * original paintEvent exactly once. notify() returning for a Paint event alone
 * is insufficient because an event filter can consume it before this hook.
 */
class UiPaintTableView : public QTableView
{
public:
    explicit UiPaintTableView(QWidget* parent = nullptr) : QTableView(parent)
    {
        connect(horizontalHeader(), &QHeaderView::sortIndicatorChanged, this, [this] {
            measurementAction(UiPaintProbe::Action::SORT, m_role == UiPaintProbe::Role::HISTORY);
        });
    }
    ~UiPaintTableView() override { if (auto* probe = UiPaintProbe::current()) probe->remove(viewport(), UiPaintProbe::Outcome::DESTROYED); }
    void setMeasurementRole(UiPaintProbe::Role role)
    {
        if (role == m_role) return;
        if (auto* probe = UiPaintProbe::current()) probe->remove(viewport(), UiPaintProbe::Outcome::REBOUND);
        m_role = role;
    }
    void measurementAction(UiPaintProbe::Action action, bool await_update = false, const QRect& region = {}, UiPaintProbe::FilterChannel channel = UiPaintProbe::FilterChannel::NONE)
    {
        if (auto* probe = observer()) probe->action(viewport(), action, await_update, region, channel);
    }
    void measurementPending(UiPaintProbe::EpochReason reason = UiPaintProbe::EpochReason::NONE, bool ready = false)
    {
        ++m_generation;
        m_ready = ready;
        if (auto* probe = observer()) probe->generation(viewport(), m_generation, ready, reason);
    }
    // Product Started signals also describe internal queued continuation. They
    // mark the existing epoch pending, never invent a new semantic change.
    void measurementContinuing()
    {
        m_ready = false;
        if (auto* probe = observer()) probe->generation(viewport(), m_generation, false);
    }
    void measurementReady()
    {
        m_ready = true;
        if (auto* probe = observer()) probe->generation(viewport(), m_generation, true);
    }
    void observeHistoryProjection(TransactionPresentationProxy* projection)
    {
        // Call after setModel: these connections are retired with that binding.
        Q_ASSERT(model() == projection && m_role == UiPaintProbe::Role::HISTORY);
        m_connections.push_back(connect(projection, &TransactionPresentationProxy::diagnosticInvalidated, this,
            [this](TransactionPresentationProxy::DiagnosticChange change, bool ready) {
                using Change = TransactionPresentationProxy::DiagnosticChange;
                using Reason = UiPaintProbe::EpochReason;
                Reason reason{Reason::NONE};
                switch (change) {
                case Change::SOURCE_BINDING: reason = Reason::SOURCE_BINDING; break;
                case Change::SOURCE_RESET: reason = Reason::SOURCE_RESET; break;
                case Change::SOURCE_DESTROYED: reason = Reason::SOURCE_DESTROYED; break;
                case Change::SOURCE_ROWS: reason = Reason::SOURCE_ROWS; break;
                case Change::SOURCE_DATA: reason = Reason::SOURCE_DATA; break;
                case Change::FILTER: reason = Reason::FILTER; break;
                case Change::SORT: reason = Reason::SORT; break;
                case Change::ACTIVATION: reason = Reason::ACTIVATION; break;
                case Change::SOURCE_LAYOUT: reason = Reason::SOURCE_LAYOUT; break;
                }
                measurementPending(reason, ready);
            }));
        m_connections.push_back(connect(projection, &TransactionPresentationProxy::projectionStarted, this, &UiPaintTableView::measurementContinuing));
        m_connections.push_back(connect(projection, &TransactionPresentationProxy::projectionReady, this, [this, projection] {
            // Existing publication may still have an external restart queued.
            if (projection->isReady()) measurementReady();
            else measurementContinuing();
        }));
    }
    void measurementDeferred(bool active, UiPaintProbe::FilterChannel channel) { if (auto* probe = observer()) probe->deferred(viewport(), active, channel); }
    void setModel(QAbstractItemModel* model) override
    {
        if (auto* probe = UiPaintProbe::current()) probe->remove(viewport(), UiPaintProbe::Outcome::REBOUND);
        for (const auto& connection : m_connections) disconnect(connection);
        m_connections.clear();
        ++m_generation;
        m_ready = m_role != UiPaintProbe::Role::HISTORY;
        QTableView::setModel(model);
        if (!model) return;
        m_connections.push_back(connect(selectionModel(), &QItemSelectionModel::currentChanged, this, [this](const QModelIndex& index) {
            // Model publication can move the current index without user input.
            // It must not supersede a pending sort/navigation result. An AX
            // selection without delivered input has no row-latency sample.
            if (auto* probe = UiPaintProbe::current(); probe && probe->hasDeliveredInput() && index.isValid())
                measurementAction(UiPaintProbe::Action::ROW, false, visualRect(index));
        }));
        if (m_role != UiPaintProbe::Role::HISTORY) {
            const auto changed = [this] {
                ++m_generation;
                if (auto* probe = observer()) probe->generation(viewport(), m_generation, true);
            };
            m_connections.push_back(connect(model, &QAbstractItemModel::dataChanged, this, changed));
            m_connections.push_back(connect(model, &QAbstractItemModel::layoutChanged, this, changed));
            m_connections.push_back(connect(model, &QAbstractItemModel::rowsInserted, this, changed));
            m_connections.push_back(connect(model, &QAbstractItemModel::rowsRemoved, this, changed));
            m_connections.push_back(connect(model, &QAbstractItemModel::modelReset, this, changed));
        }
    }
protected:
    void paintEvent(QPaintEvent* event) override
    {
        auto* probe = observer();
        if (!probe) { QTableView::paintEvent(event); return; }
        const auto token = probe->beforePaint(viewport(), event->region());
        QPointer<UiPaintTableView> self(this);
        QTableView::paintEvent(event);
        if (self && UiPaintProbe::current() == probe) probe->afterPaint(viewport(), token);
    }
    void showEvent(QShowEvent* event) override
    {
        QTableView::showEvent(event);
        measurementAction(UiPaintProbe::Action::NAVIGATE);
    }
    void hideEvent(QHideEvent* event) override
    {
        if (auto* probe = UiPaintProbe::current()) probe->cancel(viewport(), UiPaintProbe::Outcome::HIDDEN);
        QTableView::hideEvent(event);
    }
private:
    UiPaintProbe* observer()
    {
        auto* probe = UiPaintProbe::current();
        if (probe) probe->bind(viewport(), m_role, m_generation, m_ready);
        return probe;
    }
    UiPaintProbe::Role m_role{UiPaintProbe::Role::HISTORY};
    quint64 m_generation{1};
    bool m_ready{true};
    std::vector<QMetaObject::Connection> m_connections;
};

/** Explicit developer-only calibration. Nothing is clicked automatically. Each
 * Run click changes a visible synthetic cell; ordinary model notifications drive
 * painting. Requested sleeps and measured blocking intervals remain separate.
 */
class UiPaintCalibration : public QWidget
{
public:
    explicit UiPaintCalibration(QWidget* parent = nullptr) : QWidget(parent)
    {
        setWindowTitle(QStringLiteral("Developer paint calibration (synthetic, excluded from product budgets)"));
        setAttribute(Qt::WA_QuitOnClose, false);
        auto* layout = new QVBoxLayout(this);
        layout->addWidget(new QLabel(QStringLiteral("Choose a controlled dispatch delay, then click Run. No physical/display timing is measured."), this));
        m_delays = new QComboBox(this);
        for (int delay : {0, 100, 500, 1500}) m_delays->addItem(QString::number(delay) + QStringLiteral(" ms"), delay);
        layout->addWidget(m_delays);
        m_run = new QPushButton(QStringLiteral("Run one calibration action"), this);
        layout->addWidget(m_run);
        m_table = new UiPaintTableView(this);
        m_table->setMeasurementRole(UiPaintProbe::Role::CALIBRATION);
        m_model = new QStandardItemModel(1, 1, this);
        m_model->setData(m_model->index(0, 0), QStringLiteral("Generation 0"));
        m_table->setModel(m_model);
        m_table->horizontalHeader()->setStretchLastSection(true);
        layout->addWidget(m_table);
        connect(m_run, &QPushButton::clicked, this, [this] {
            const int delay = m_delays->currentData().toInt();
            m_table->measurementAction(UiPaintProbe::Action::CALIBRATION, false, m_table->visualRect(m_model->index(0, 0)));
            QElapsedTimer actual;
            actual.start();
            QThread::msleep(static_cast<unsigned long>(delay));
            if (auto* probe = UiPaintProbe::current()) probe->calibrationDelay(m_table->viewport(), delay, actual.nsecsElapsed());
            ++m_generation;
            m_model->setData(m_model->index(0, 0), QStringLiteral("Generation %1").arg(m_generation));
        });
        resize(620, 240);
    }
    static UiPaintCalibration* attachToMainWindow(QMainWindow* window)
    {
        // An opt-in scene in the already controllable main window. No floating
        // secondary surface, automatic action, or ordinary settings mutation.
        auto* dock = new QDockWidget(QStringLiteral("Developer paint calibration (synthetic)"), window);
        dock->setObjectName(QStringLiteral("developerPaintCalibrationDock"));
        dock->setFeatures(QDockWidget::NoDockWidgetFeatures);
        dock->setAllowedAreas(Qt::NoDockWidgetArea);
        dock->toggleViewAction()->setEnabled(false);
        auto* scene = new UiPaintCalibration(dock);
        dock->setWidget(scene);
        window->addDockWidget(Qt::BottomDockWidgetArea, dock);
        dock->show();
        return scene;
    }
    QPushButton* runButton() const { return m_run; }
    QComboBox* delays() const { return m_delays; }
    UiPaintTableView* table() const { return m_table; }
private:
    QComboBox* m_delays;
    QPushButton* m_run;
    UiPaintTableView* m_table;
    QStandardItemModel* m_model;
    quint64 m_generation{0};
};

#endif
