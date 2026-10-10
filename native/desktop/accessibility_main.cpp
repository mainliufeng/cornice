#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVariant>
#include <QThread>
#include <QLocalSocket>
#include <QRegularExpression>
#include <stdexcept>
#undef signals
#include <atspi/atspi.h>

namespace {
QElapsedTimer elapsed;
int remaining = 160, maxDepth = 12, count = 0;
bool truncated = false;
QSet<QString> visited;
void budget() {
    if (elapsed.elapsed() > 3500)
        throw std::runtime_error("native accessibility timed out");
}
void check(GError *&error) {
    if (error) {
        auto message = QString::fromUtf8(error->message);
        g_error_free(error);
        error = nullptr;
        throw std::runtime_error(message.toStdString());
    }
    budget();
}
QString take(gchar *value) {
    auto text = QString::fromUtf8(value ? value : "").left(4096);
    g_free(value);
    return text;
}
QString name(AtspiAccessible *object) {
    GError *error = nullptr;
    auto value = take(atspi_accessible_get_name(object, &error));
    check(error);
    return value;
}
void enableAccessibility() {
    // Qt registers its bridge when the session accessibility status changes.
    // This is a session setting, never a persistent user configuration edit.
    for (const auto *property : {"IsEnabled", "ScreenReaderEnabled"}) {
        auto message =
            QDBusMessage::createMethodCall("org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Properties", "Set");
        message << QString("org.a11y.Status") << QString(property) << QVariant::fromValue(QDBusVariant(true));
        QDBusConnection::sessionBus().call(message, QDBus::Block, 250);
    }
}
QJsonObject identity(AtspiAccessible *object) {
    auto base = ATSPI_OBJECT(object);
    return {{"bus", QString::fromUtf8(base->app->bus_name)},
            {"path", QString::fromUtf8(base->path)},
            {"name", name(object)},
            {"role", int(atspi_accessible_get_role(object, nullptr))}};
}
QString key(AtspiAccessible *object) {
    auto base = ATSPI_OBJECT(object);
    return QString::fromUtf8(base->app->bus_name) + ":" + QString::fromUtf8(base->path);
}
AtspiAccessible *window(const QJsonObject &target) {
    GError *error = nullptr;
    auto desktop = atspi_get_desktop(0);
    if (!desktop)
        throw std::runtime_error("AT-SPI accessibility bus unavailable");
    AtspiAccessible *match = nullptr;
    const int apps = atspi_accessible_get_child_count(desktop, &error);
    check(error);
    for (int i = 0; i < apps && i < 256; ++i) {
        auto app = atspi_accessible_get_child_at_index(desktop, i, &error);
        check(error);
        if (!app)
            continue;
        const auto pid = atspi_accessible_get_process_id(app, &error);
        check(error);
        if (pid == guint(target.value("pid").toInt())) {
            const int windows = atspi_accessible_get_child_count(app, &error);
            check(error);
            for (int j = 0; j < windows && j < 128; ++j) {
                auto candidate = atspi_accessible_get_child_at_index(app, j, &error);
                check(error);
                if (!candidate)
                    continue;
                const auto role = atspi_accessible_get_role(candidate, &error);
                check(error);
                if ((role == ATSPI_ROLE_FRAME || role == ATSPI_ROLE_DIALOG || role == ATSPI_ROLE_WINDOW ||
                     role == ATSPI_ROLE_FILLER || role == ATSPI_ROLE_PANEL) &&
                    name(candidate) == target.value("title").toString()) {
                    if (match) {
                        g_object_unref(candidate);
                        g_object_unref(app);
                        g_object_unref(desktop);
                        g_object_unref(match);
                        throw std::runtime_error("AT-SPI window mapping is ambiguous");
                    }
                    match = candidate;
                } else
                    g_object_unref(candidate);
            }
        }
        g_object_unref(app);
    }
    g_object_unref(desktop);
    if (!match)
        throw std::runtime_error("native accessibility unsupported: application does not expose this PID/title window "
                                 "via AT-SPI; use browser CDP or an explicit visual fallback");
    return match;
}
QJsonObject tree(AtspiAccessible *object, int depth) {
    budget();
    if (remaining-- <= 0 || depth > maxDepth || visited.contains(key(object))) {
        truncated = true;
        return {};
    }
    visited.insert(key(object));
    ++count;
    GError *error = nullptr;
    const auto role = atspi_accessible_get_role(object, &error);
    check(error);
    QJsonObject node{{"identity", identity(object)},
                     {"role", take(atspi_accessible_get_role_name(object, &error))},
                     {"name", name(object)}};
    check(error);
    node.insert("description", take(atspi_accessible_get_description(object, &error)));
    check(error);
    auto states = atspi_accessible_get_state_set(object);
    QJsonArray flags;
    const std::pair<AtspiStateType, const char *> wanted[] = {
        {ATSPI_STATE_ENABLED, "enabled"},   {ATSPI_STATE_SENSITIVE, "sensitive"},
        {ATSPI_STATE_SHOWING, "showing"},   {ATSPI_STATE_VISIBLE, "visible"},
        {ATSPI_STATE_FOCUSED, "focused"},   {ATSPI_STATE_FOCUSABLE, "focusable"},
        {ATSPI_STATE_EDITABLE, "editable"}, {ATSPI_STATE_CHECKED, "checked"},
        {ATSPI_STATE_SELECTED, "selected"}, {ATSPI_STATE_DEFUNCT, "defunct"},
        {ATSPI_STATE_EXPANDED, "expanded"}, {ATSPI_STATE_MULTI_LINE, "multiline"}};
    for (auto [state, label] : wanted)
        if (states && atspi_state_set_contains(states, state))
            flags.append(label);
    node.insert("states", flags);
    if (states)
        g_object_unref(states);
    QJsonArray actions;
    if (auto action = atspi_accessible_get_action_iface(object)) {
        int n = atspi_action_get_n_actions(action, &error);
        check(error);
        for (int i = 0; i < n && i < 16; ++i) {
            actions.append(take(atspi_action_get_action_name(action, i, &error)));
            check(error);
        }
        g_object_unref(action);
    }
    node.insert("actions", actions);
    if (auto component = atspi_accessible_get_component_iface(object)) {
        auto rect = atspi_component_get_extents(component, ATSPI_COORD_TYPE_WINDOW, &error);
        if (!error && rect)
            node.insert("bounds", QJsonArray{rect->x, rect->y, rect->width, rect->height});
        if (rect)
            g_free(rect);
        if (error) {
            g_error_free(error);
            error = nullptr;
        }
        g_object_unref(component);
    }
    // Password widgets remain redacted even when a toolkit exposes their text.
    if (role == ATSPI_ROLE_PASSWORD_TEXT)
        node.insert("text", "[redacted]");
    else if (auto text = atspi_accessible_get_text_iface(object)) {
        int length = atspi_text_get_character_count(text, &error);
        check(error);
        node.insert("text", take(atspi_text_get_text(text, 0, qMin(length, 2048), &error)));
        check(error);
        if (length > 2048)
            node.insert("textTruncated", true);
        g_object_unref(text);
    }
    QJsonArray children;
    int n = atspi_accessible_get_child_count(object, &error);
    check(error);
    for (int i = 0; i < n; ++i) {
        if (remaining <= 0 || depth >= maxDepth) {
            truncated = true;
            break;
        }
        auto child = atspi_accessible_get_child_at_index(object, i, &error);
        check(error);
        if (child) {
            auto result = tree(child, depth + 1);
            if (!result.isEmpty())
                children.append(result);
            g_object_unref(child);
        }
    }
    node.insert("children", children);
    return node;
}
AtspiAccessible *find(AtspiAccessible *object, const QJsonObject &target, int depth = 0) {
    budget();
    if (remaining-- <= 0 || depth > 20 || visited.contains(key(object)))
        return nullptr;
    visited.insert(key(object));
    auto base = ATSPI_OBJECT(object);
    if (QString::fromUtf8(base->app->bus_name) == target.value("bus").toString() &&
        QString::fromUtf8(base->path) == target.value("path").toString()) {
        const auto current = identity(object);
        if (current.value("name") != target.value("name") || current.value("role") != target.value("role"))
            throw std::runtime_error("native element changed; request a fresh tree");
        return ATSPI_ACCESSIBLE(g_object_ref(object));
    }
    GError *error = nullptr;
    int n = atspi_accessible_get_child_count(object, &error);
    check(error);
    for (int i = 0; i < n && remaining > 0; ++i) {
        auto child = atspi_accessible_get_child_at_index(object, i, &error);
        check(error);
        if (!child)
            continue;
        auto found = find(child, target, depth + 1);
        g_object_unref(child);
        if (found)
            return found;
    }
    return nullptr;
}
QJsonDocument compositor(const QJsonObject &authorization, const QString &command) {
    auto instance = authorization.value("instance").toString();
    if (!QRegularExpression("^[A-Za-z0-9_.-]{1,160}$").match(instance).hasMatch())
        throw std::runtime_error("native action missing compositor authorization");
    auto runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    QLocalSocket socket;
    socket.connectToServer(runtime + "/hypr/" + instance + "/.socket.sock");
    if (!socket.waitForConnected(250))
        throw std::runtime_error("native action compositor unavailable");
    socket.write(("j/" + command).toUtf8());
    if (!socket.waitForBytesWritten(250))
        throw std::runtime_error("native action compositor write failed");
    QByteArray answer;
    while (socket.state() == QLocalSocket::ConnectedState) {
        if (!socket.bytesAvailable() && !socket.waitForReadyRead(250) && socket.state() == QLocalSocket::ConnectedState)
            throw std::runtime_error("native action compositor timed out");
        answer += socket.readAll();
        if (answer.size() > 4 * 1024 * 1024)
            throw std::runtime_error("native action compositor response exceeds budget");
    }
    answer += socket.readAll();
    return QJsonDocument::fromJson(answer);
}
void authorize(const QJsonObject &request) {
    auto authorization = request.value("authorization").toObject();
    auto seat = authorization.value("name").toString();
    if (!QRegularExpression("^[A-Za-z0-9_-]{1,64}$").match(seat).hasMatch())
        throw std::runtime_error("native action requires a seat authorization");
    auto current = compositor(authorization, "seat state " + seat).object();
    if (current.isEmpty() || current.value("paused").toBool(true) || !current.value("available").toBool() ||
        (current.value("locked").toBool() &&
         (current.value("lockScope") != "scoped" || current.value("scopePolicy") != "allow")))
        throw std::runtime_error("native action desktop is paused, locked or unavailable");
    for (const auto &field : {"seatId", "generation", "workspace", "viewEpoch", "lockEpoch"}) {
        if (authorization.value(field).toString().isEmpty() || current.value(field) != authorization.value(field))
            throw std::runtime_error("native action desktop identity/view changed before input");
    }
    auto target = request.value("window").toObject();
    int matches = 0;
    bool found = false;
    for (auto value : compositor(authorization, "clients").array()) {
        auto candidate = value.toObject();
        if (candidate.value("pid") == target.value("pid") && candidate.value("title") == target.value("title")) {
            ++matches;
            auto workspace = candidate.value("workspace").toObject().value("name").toString();
            auto expected = current.value("workspace").toString();
            if (expected.startsWith("name:"))
                expected.remove(0, 5);
            found = candidate.value("address") == target.value("address") && workspace == expected;
        }
    }
    if (matches != 1 || !found)
        throw std::runtime_error("native action window left the authorized workspace or became ambiguous");
}
QJsonObject act(AtspiAccessible *root, const QJsonObject &request) {
    remaining = 1000;
    auto element = find(root, request.value("identity").toObject());
    if (!element)
        throw std::runtime_error("native element no longer belongs to the authorized window; request a fresh tree");
    auto states = atspi_accessible_get_state_set(element);
    bool enabled = states && atspi_state_set_contains(states, ATSPI_STATE_ENABLED) &&
                   atspi_state_set_contains(states, ATSPI_STATE_SENSITIVE) &&
                   !atspi_state_set_contains(states, ATSPI_STATE_DEFUNCT);
    if (states)
        g_object_unref(states);
    if (!enabled) {
        g_object_unref(element);
        throw std::runtime_error("native element is disabled or defunct");
    }
    GError *error = nullptr;
    bool ok = false;
    auto action = request.value("action").toString();
    if (action == "setText") {
        if (auto editable = atspi_accessible_get_editable_text_iface(element)) {
            auto text = request.value("text").toString().toUtf8();
            authorize(request);
            ok = atspi_editable_text_set_text_contents(editable, text.constData(), &error);
            g_object_unref(editable);
        }
    } else if (action == "focus") {
        if (auto component = atspi_accessible_get_component_iface(element)) {
            authorize(request);
            ok = atspi_component_grab_focus(component, &error);
            g_object_unref(component);
        }
    } else if (action == "click") {
        if (auto actions = atspi_accessible_get_action_iface(element)) {
            int n = atspi_action_get_n_actions(actions, &error);
            check(error);
            int choice = -1;
            for (int i = 0; i < n && i < 16; ++i) {
                auto label = take(atspi_action_get_action_name(actions, i, &error)).toLower();
                check(error);
                if (label == "click" || label == "press" || label == "activate") {
                    choice = i;
                    break;
                }
            }
            if (choice >= 0) {
                authorize(request);
                ok = atspi_action_do_action(actions, choice, &error);
            }
            g_object_unref(actions);
        }
    }
    g_object_unref(element);
    check(error);
    if (!ok)
        throw std::runtime_error("native element does not support this semantic action");
    return {{"ok", true}, {"action", action}, {"applied", true}};
}
} // namespace
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    elapsed.start();
    QJsonObject result;
    try {
        QFile in;
        if (!in.open(stdin, QIODevice::ReadOnly))
            throw std::runtime_error("native accessibility stdin unavailable");
        auto bytes = in.read(128 * 1024 + 1);
        if (bytes.size() > 128 * 1024)
            throw std::runtime_error("native accessibility request exceeds budget");
        auto request = QJsonDocument::fromJson(bytes).object();
        if (!request.value("window").isObject() || request.value("window").toObject().value("pid").toInt() <= 0)
            throw std::runtime_error("native accessibility requires a trusted window");
        enableAccessibility();
        atspi_set_timeout(250, 250);
        if (atspi_init() != 0)
            throw std::runtime_error("AT-SPI accessibility bus unavailable");
        AtspiAccessible *root = nullptr;
        for (int attempt = 0; attempt < 4; ++attempt) {
            try {
                root = window(request.value("window").toObject());
                break;
            } catch (const std::exception &) {
                if (attempt == 3)
                    throw;
                while (g_main_context_iteration(nullptr, false)) {
                }
                QThread::msleep(80);
            }
        }
        if (request.value("operation") == "action")
            result = act(root, request);
        else {
            remaining = qBound(1, request.value("maxNodes").toInt(160), 300);
            maxDepth = qBound(1, request.value("maxDepth").toInt(12), 20);
            auto node = tree(root, 0);
            result = {{"ok", true},
                      {"tree", node},
                      {"nodeCount", count},
                      {"truncated", truncated},
                      {"boundsCoordinates", "window"}};
        }
        g_object_unref(root);
    } catch (const std::exception &error) {
        result = {{"ok", false}, {"error", QString::fromUtf8(error.what())}};
    }
    QFile out;
    if (!out.open(stdout, QIODevice::WriteOnly))
        return 2;
    out.write(QJsonDocument(result).toJson(QJsonDocument::Compact));
    out.write("\n");
    out.flush();
    return result.value("ok").toBool() ? 0 : 1;
}
