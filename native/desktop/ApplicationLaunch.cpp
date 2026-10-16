#include "ApplicationLaunch.hpp"
#include "../common/ApplicationLocation.hpp"
#include <unistd.h>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSet>
#include <QProcess>
#include <QUrl>
#include <QMimeDatabase>
#include <QStandardPaths>
#include <stdexcept>

namespace {
[[noreturn]] void invalid(const QString &message) {
    throw std::runtime_error(("Desktop application configuration: " + message).toStdString());
}
QJsonObject readObject(const QString &path, bool optional = false) {
    QFile file(path);
    if (!file.exists() && optional) return {};
    if (!file.open(QIODevice::ReadOnly)) invalid("cannot read " + path);
    if (file.size() > 1024 * 1024) invalid("configuration exceeds 1 MiB: " + path);
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(file.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) invalid("invalid JSON object: " + path);
    return document.object();
}
QJsonObject merge(QJsonObject base, const QJsonObject &overrides) {
    for (auto it = overrides.begin(); it != overrides.end(); ++it) {
        if (it.value().isObject() && base[it.key()].isObject())
            base[it.key()] = merge(base[it.key()].toObject(), it.value().toObject());
        else base[it.key()] = it.value();
    }
    return base;
}
QStringList strings(const QJsonValue &value, const QString &field, bool optional = false, int maximum = 128) {
    if (value.isUndefined() && optional) return {};
    if (!value.isArray() || value.toArray().size() > maximum) invalid(field + " must be an array of up to " + QString::number(maximum) + " strings");
    QStringList result;
    for (const auto &entry : value.toArray()) {
        if (!entry.isString() || entry.toString().contains(QChar(0)) || entry.toString().size() > 16384)
            invalid(field + " contains an invalid string");
        result.append(entry.toString());
    }
    return result;
}
bool segment(const QString &value) {
    return QRegularExpression("^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$").match(value).hasMatch();
}
QJsonObject settings() {
    auto prefix = qEnvironmentVariable("CORNICE_PATH");
    if (prefix.isEmpty()) prefix = QDir(QCoreApplication::applicationDirPath()).absoluteFilePath("../..");
    const auto defaults = readObject(prefix + "/config/default.json");
    const auto user = readObject(QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/cornice/config.json", true);
    const auto effective = merge(defaults, user).value("desktopApplications");
    if (!effective.isObject() || !effective.toObject()["rules"].isObject()) invalid("desktopApplications.rules must be an object");
    const auto result = effective.toObject();
    const auto rules = result["rules"].toObject();
    if (rules.size() > 128) invalid("at most 128 application rules are supported");
    for (auto it = rules.begin(); it != rules.end(); ++it) {
        if (!segment(it.key())) invalid("invalid rule ID: " + it.key());
        if (it.value().isNull()) continue;
        if (!it.value().isObject()) invalid(it.key() + " must be an object or null");
        const auto rule = it.value().toObject();
        const QSet<QString> fields{"executables", "backend", "profile", "profilePaths", "arguments", "environment", "reservedArguments", "scope", "enabled", "singleInstance"};
        for (auto field = rule.begin(); field != rule.end(); ++field)
            if (!fields.contains(field.key())) invalid(it.key() + ": unknown field " + field.key());
        if (rule.contains("singleInstance") && (!rule["singleInstance"].isString() || rule["singleInstance"].toString().trimmed().isEmpty() || rule["singleInstance"].toString().size() > 128 || rule["singleInstance"].toString().contains(QChar(0))))
            invalid(it.key() + ".singleInstance must be a nonempty application name");
        if (rule.contains("enabled") && !rule["enabled"].isBool()) invalid(it.key() + ".enabled must be boolean");
        if (!rule["enabled"].toBool(true)) continue;
        const auto names = strings(rule["executables"], it.key() + ".executables");
        if (names.isEmpty()) invalid(it.key() + ".executables must not be empty");
        for (const auto &name : names)
            if (!segment(name)) invalid(it.key() + ": executable matches must be basenames");
        if (rule.contains("backend") && !rule["backend"].isString()) invalid(it.key() + ".backend must be a string");
        const auto backend = rule["backend"].toString("process");
        if (backend != "process" && backend != "chromium") invalid(it.key() + ": backend must be process or chromium");
        if (rule.contains("scope") && !rule["scope"].isString()) invalid(it.key() + ".scope must be a string");
        const auto scope = rule["scope"].toString("all");
        if (scope != "all" && scope != "secondary") invalid(it.key() + ": scope must be all or secondary");
        if (rule.contains("profile") && (!rule["profile"].isString() || !segment(rule["profile"].toString())))
            invalid(it.key() + ": profile must be one directory name");
        if (rule.contains("profilePaths")) {
            if (!rule.contains("profile") || !rule["profilePaths"].isObject())
                invalid(it.key() + ": profilePaths requires profile and an object of desktop paths");
            const auto paths = rule["profilePaths"].toObject();
            for (auto path = paths.begin(); path != paths.end(); ++path) {
                const auto value = path.value().toString();
                if (!segment(path.key()) || !path.value().isString() || value.contains(QChar(0)) ||
                    !(QDir::isAbsolutePath(value) || value.startsWith("~/")))
                    invalid(it.key() + ": profilePaths must map desktop names to absolute or ~/ paths");
            }
        }
        const auto arguments = strings(rule["arguments"], it.key() + ".arguments", true);
        const auto reserved = strings(rule["reservedArguments"], it.key() + ".reservedArguments", true);
        for (const auto &prefix : reserved) if (prefix.isEmpty() || !prefix.startsWith('-')) invalid(it.key() + ": reserved arguments must be option prefixes");
        if (rule.contains("environment") && !rule["environment"].isObject()) invalid(it.key() + ".environment must be an object");
        const auto environment = rule["environment"].toObject();
        for (auto variable = environment.begin(); variable != environment.end(); ++variable) {
            if (!QRegularExpression("^[A-Za-z_][A-Za-z0-9_]*$").match(variable.key()).hasMatch() || !variable.value().isString() || variable.value().toString().contains(QChar(0)))
                invalid(it.key() + ": invalid environment entry");
            if (QSet<QString>{"WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "CORNICE_DESKTOP_NAME", "CORNICE_DESKTOP_OUTPUT", "CORNICE_SHELL_SOCKET", "CORNICE_PRIMARY_SHELL_SOCKET", "HYPRLAND_ACTION_ID", "HYPRLAND_SEAT_NAME", "HYPRLAND_SEAT_ID", "HYPRLAND_SEAT_GENERATION", "HYPRLAND_SEAT_OUTPUT"}.contains(variable.key()))
                invalid(it.key() + ": compositor identity environment is managed by the Broker");
        }
        if (backend == "chromium") {
            if (!rule.contains("profile") || arguments.count("--user-data-dir={profile}") != 1)
                invalid(it.key() + ": chromium requires profile and exactly one --user-data-dir={profile} argument");
            for (const auto &arg : arguments)
                if (arg.startsWith("--remote-debugging") || (arg.startsWith("--user-data-dir") && arg != "--user-data-dir={profile}"))
                    invalid(it.key() + ": browser transport and profile are managed");
        }
    }
    return result;
}
QStringList simpleCommand(const QString &command) {
    QStringList result;
    QString word;
    QChar quote;
    bool started = false, escaped = false;
    for (const auto character : command) {
        if (escaped) { word += character; escaped = false; started = true; continue; }
        if (character == '\\' && quote != '\'') { escaped = true; started = true; continue; }
        if (!quote.isNull()) {
            if (character == quote) quote = {};
            else {
                if (quote == '"' && (character == '$' || character == '`'))
                    invalid("shell expansion is not a desktop application command; launch an explicit argv");
                word += character;
            }
            started = true;
            continue;
        }
        if (character == '\'' || character == '"') { quote = character; started = true; continue; }
        if (character.isSpace()) {
            if (started) { result.append(word); word.clear(); started = false; }
            continue;
        }
        if (QString(";&|<>$`*?(){}~").contains(character))
            invalid("compound shell commands cannot guarantee desktop application routing; launch an explicit argv");
        word += character;
        started = true;
    }
    if (escaped || !quote.isNull()) invalid("unterminated application command quote");
    if (started) result.append(word);
    if (result.isEmpty()) invalid("empty application command");
    return result;
}
QString executable(const QStringList &names) {
    const auto paths = (QDir::homePath() + "/.local/bin:" + qEnvironmentVariable("PATH")).split(':', Qt::SkipEmptyParts);
    for (const auto &name : names) {
        const auto value = QStandardPaths::findExecutable(name, paths);
        if (!value.isEmpty()) return value;
    }
    invalid("application executable is not installed");
}
QStringList urlCommand(const QJsonObject &config, const QString &target, bool primary) {
    const QUrl url = QUrl::fromUserInput(target, QDir::currentPath(), QUrl::AssumeLocalFile);
    if (!url.isValid()) invalid("invalid application URL");
    const auto scheme = url.scheme().toLower();
    if (scheme == "http" || scheme == "https") {
        const auto rule = config["rules"].toObject()[config["browser"].toString()].toObject();
        if (rule.isEmpty() || !rule["enabled"].toBool(true) || rule["backend"] != "chromium")
            invalid("HTTP URLs require the configured desktop browser");
        return {executable(strings(rule["executables"], "browser.executables")), url.toString()};
    }
    const auto mime = url.isLocalFile() ? QMimeDatabase().mimeTypeForFile(url.toLocalFile()).name() : "x-scheme-handler/" + scheme;
    QProcess query;
    query.start("xdg-mime", {"query", "default", mime});
    if (!query.waitForFinished(2000)) { query.kill(); query.waitForFinished(1000); invalid("application URL handler lookup timed out"); }
    const auto desktopId = QString::fromUtf8(query.readAllStandardOutput()).trimmed();
    if (query.exitCode() || !QRegularExpression("^[A-Za-z0-9_.-]+\\.desktop$").match(desktopId).hasMatch())
        invalid("no desktop application handles " + mime);
    const auto path = QStandardPaths::locate(QStandardPaths::GenericDataLocation, "applications/" + desktopId);
    QFile file(path);
    if (path.isEmpty() || !file.open(QIODevice::ReadOnly) || file.size() > 1024 * 1024)
        invalid("cannot read the configured URL handler");
    QString command;
    bool inEntry = false;
    for (auto line : QString::fromUtf8(file.readAll()).split('\n')) {
        line = line.trimmed();
        if (line.startsWith('[')) inEntry = line == "[Desktop Entry]";
        else if (inEntry && line.startsWith("Exec=")) { command = line.mid(5); break; }
    }
    auto argv = simpleCommand(command);
    bool substituted = false;
    for (auto &argument : argv) {
        if (argument == "%u" || argument == "%U" || argument == "%f" || argument == "%F") {
            argument = (argument == "%f" || argument == "%F") && url.isLocalFile() ? url.toLocalFile() : url.toString();
            substituted = true;
        } else if (argument.contains('%')) {
            argument.replace("%%", "%");
            if (argument.contains(QRegularExpression("%[a-zA-Z]"))) invalid("URL handler has unsupported desktop-entry fields");
        }
    }
    if (!substituted) argv.append(url.isLocalFile() ? url.toLocalFile() : url.toString());
    if (!primary) {
        bool adapted = false;
        for (const auto &entry : config["rules"].toObject()) {
            const auto rule = entry.toObject();
            if (rule["enabled"].toBool(true) && (rule.contains("profile") || rule.contains("singleInstance")) &&
                strings(rule["executables"], "handler.executables", true).contains(QFileInfo(argv.first()).fileName())) adapted = true;
        }
        if (!adapted) invalid("URL handler needs a desktopApplications profile or singleInstance rule on secondary desktops: " + desktopId);
    }
    return argv;
}
QStringList normalizeCommand(const QJsonObject &config, QStringList argv, bool primary, QJsonObject &environment, QStringList &warnings) {
    for (int depth = 0; depth < 8; ++depth) {
        if (argv.isEmpty()) invalid("application command required");
        const auto name = QFileInfo(argv.first()).fileName();
        if (name == "env") {
            argv.removeFirst();
            if (argv.value(0) == "--") argv.removeFirst();
            while (!argv.isEmpty() && argv.first().contains('=')) {
                const auto entry = argv.takeFirst();
                const auto separator = entry.indexOf('=');
                const auto key = entry.left(separator);
                if (!QRegularExpression("^[A-Za-z_][A-Za-z0-9_]*$").match(key).hasMatch()) invalid("invalid application environment");
                if (key.startsWith("HYPRLAND_") || key.startsWith("CORNICE_") ||
                    QSet<QString>{"WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"}.contains(key))
                    invalid("compositor identity environment is managed by the Broker");
                environment[key] = entry.mid(separator + 1);
            }
            if (argv.value(0).startsWith('-')) invalid("unsupported env option; launch explicit application argv");
            continue;
        }
        if ((name == "sh" || name == "bash" || name == "zsh" || name == "dash") && argv.size() == 3 && argv[1] == "-c") {
            // Only literal single commands can be safely unwrapped for profile
            // adaptation. General scripts still inherit the desktop environment,
            // as before, and explicitly report the limit instead of changing
            // shell semantics or pretending nested single-instance apps isolate.
            try {
                argv = simpleCommand(argv[2]);
            } catch (const std::runtime_error &) {
                warnings.append("Compound shell command inherits the desktop environment; profile rules cannot inspect applications launched inside the script");
                return argv;
            }
            if (argv.value(0) == "exec") argv.removeFirst();
            continue;
        }
        if (name == "xdg-open" || (name == "gio" && argv.value(1) == "open")) {
            const int count = name == "gio" ? 3 : 2;
            if (argv.size() != count) invalid("open requires exactly one URL or file");
            argv = urlCommand(config, argv.last(), primary);
            continue;
        }
        return argv;
    }
    invalid("application command wrappers exceed routing depth");
}
QString expand(QString value, const QString &profile, const QString &desktop) {
    if (value.contains("{profile}") && profile.isEmpty()) invalid("{profile} requires a profile directory");
    value.replace("{profile}", profile).replace("{desktop}", desktop);
    return value;
}
ApplicationLaunchPlan build(const QStringList &argv, const QString &desktop, const QString &id, const QJsonObject &rule) {
    ApplicationLaunchPlan plan;
    plan.program = argv.first();
    plan.arguments = argv.mid(1);
    plan.requestedArguments = plan.arguments;
    if (id.isEmpty()) return plan;
    plan.rule = id;
    plan.backend = rule["backend"].toString("process");
    plan.policy = QJsonDocument(rule).toJson(QJsonDocument::Compact);
    const auto reserved = strings(rule["reservedArguments"], id + ".reservedArguments", true);
    for (const auto &arg : plan.arguments) {
        // This driver owns its debug pipe regardless of user policy overrides.
        if (plan.backend == "chromium" && (arg.startsWith("--remote-debugging") || arg.startsWith("--user-data-dir")))
            invalid("browser debug endpoints and profile overrides are disabled; use desktop.browser");
        for (const auto &prefix : reserved)
            if (arg.startsWith(prefix)) invalid(id + ": caller cannot override reserved option " + prefix);
    }
    if (rule.contains("profile")) {
        plan.profile = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/cornice/desktops/" + desktop + "/" + rule["profile"].toString();
        const auto configured = rule["profilePaths"].toObject()[desktop].toString();
        if (!configured.isEmpty()) {
            plan.profile = configured.startsWith("~/") ? QDir::homePath() + configured.mid(1) : configured;
            plan.profile = QDir::cleanPath(plan.profile);
        }
        if (!QDir().mkpath(plan.profile)) invalid("cannot create profile directory");
    }
    QStringList arguments;
    for (const auto &arg : strings(rule["arguments"], id + ".arguments", true)) arguments.append(expand(arg, plan.profile, desktop));
    plan.arguments = arguments + plan.arguments;
    if (plan.arguments.size() > 256) invalid("combined configured and requested arguments exceed 256");
    const auto environment = rule["environment"].toObject();
    for (auto it = environment.begin(); it != environment.end(); ++it) plan.environment[it.key()] = expand(it.value().toString(), plan.profile, desktop);
    return plan;
}
QString singletonConflict(const QJsonObject &config, const QStringList &command, const QJsonObject &environment, const QString &desktop, bool primary) {
    for (const auto &value : config["rules"].toObject()) {
        const auto rule = value.toObject();
        if (!rule["enabled"].toBool(true) || !rule.contains("singleInstance") || (primary && rule["scope"] == "secondary")) continue;
        if (!strings(rule["executables"], "singleInstance.executables").contains(QFileInfo(command.first()).fileName())) continue;
        const auto search = environment["PATH"].toString(QDir::homePath() + "/.local/bin:" + qEnvironmentVariable("PATH"));
        const auto executable = QFileInfo(QStandardPaths::findExecutable(command.first(), search.split(':', Qt::SkipEmptyParts))).canonicalFilePath();
        if (executable.isEmpty()) return {};
        for (const auto &pid : QDir("/proc").entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
            bool numeric = false; const auto number = pid.toLongLong(&numeric);
            if (!numeric || number == getpid() || QFileInfo("/proc/" + pid).ownerId() != getuid()) continue;
            if (QFileInfo("/proc/" + pid + "/exe").canonicalFilePath() != executable) continue;
            const auto owner = CorniceApplication::desktopForPid(number);
            if (owner == desktop) continue;
            if (owner.isEmpty()) return rule["singleInstance"].toString() + QStringLiteral(" 已有一个实例在运行，无法确认所在桌面。请在已有实例所在的桌面使用。");
            const auto location = CorniceApplication::label(owner);
            return rule["singleInstance"].toString() + QStringLiteral(" 已在") + location
                + QStringLiteral("运行，只能打开一个实例。请切换到应用所在的桌面使用。");
        }
    }
    return {};
}
ApplicationLaunchPlan prepare(const QJsonObject &config, const QStringList &requested, const QString &desktop, bool primary) {
    QJsonObject requestedEnvironment;
    QStringList warnings;
    const auto argv = normalizeCommand(config, requested, primary, requestedEnvironment, warnings);
    if (argv.isEmpty() || argv.first().isEmpty() || !segment(desktop)) invalid("explicit application and desktop required");
    QString id;
    QJsonObject selected;
    const auto rules = config["rules"].toObject();
    for (auto it = rules.begin(); it != rules.end(); ++it) {
        if (!it.value().isObject()) continue;
        const auto rule = it.value().toObject();
        if (!rule["enabled"].toBool(true) || (primary && rule["scope"] == "secondary")) continue;
        if (!strings(rule["executables"], it.key() + ".executables").contains(QFileInfo(argv.first()).fileName())) continue;
        if (!id.isEmpty()) invalid("multiple rules match " + argv.first());
        id = it.key(); selected = rule;
    }
    const auto conflict = singletonConflict(config, argv, requestedEnvironment, desktop, primary);
    if (!conflict.isEmpty()) throw std::runtime_error(conflict.toStdString());
    auto plan = build(argv, desktop, id, selected);
    plan.warnings = warnings; plan.basePolicy = plan.policy; plan.requestedEnvironment = requestedEnvironment;
    for (auto it = requestedEnvironment.begin(); it != requestedEnvironment.end(); ++it) {
        if (plan.environment.contains(it.key())) invalid("application environment conflicts with configured policy: " + it.key());
        plan.environment[it.key()] = it.value();
    }
    if (plan.backend == "chromium") {
        // Relative launcher commands and default browser reconnects must name
        // the same actual executable. Resolve against the launch environment,
        // rather than making a new runtime identity from an argv spelling.
        const auto search = plan.environment.contains("PATH") ? plan.environment["PATH"].toString() :
            QDir::homePath() + "/.local/bin:" + qEnvironmentVariable("PATH");
        const auto executable = QStandardPaths::findExecutable(plan.program, search.split(':', Qt::SkipEmptyParts));
        if (executable.isEmpty()) invalid("managed browser executable is not installed");
        plan.program = QDir::cleanPath(executable);
    }
    // Requested env wrappers are launch policy too: reconnecting an existing
    // managed browser may not silently discard a changed proxy or application env.
    plan.policy += QJsonDocument(plan.environment).toJson(QJsonDocument::Compact);
    return plan;
}
} // namespace

QJsonObject ApplicationLaunchPlan::toJson() const {
    return {{"program",program},{"backend",backend},{"profile",profile},{"rule",rule},
        {"arguments",QJsonArray::fromStringList(arguments)},{"requestedArguments",QJsonArray::fromStringList(requestedArguments)},
        {"warnings",QJsonArray::fromStringList(warnings)},{"environment",environment},{"requestedEnvironment",requestedEnvironment},{"policy",QString::fromLatin1(policy.toBase64())},{"basePolicy",QString::fromLatin1(basePolicy.toBase64())}};
}
ApplicationLaunchPlan ApplicationLaunchPlan::fromJson(const QJsonObject &value) {
    ApplicationLaunchPlan plan;
    plan.program = value["program"].toString(); plan.backend = value["backend"].toString();
    plan.profile = value["profile"].toString(); plan.rule = value["rule"].toString();
    plan.arguments = strings(value["arguments"], "planned arguments", false, 256);
    plan.requestedArguments = strings(value["requestedArguments"], "requested arguments");
    plan.warnings = strings(value["warnings"], "planned warnings");
    plan.environment = value["environment"].toObject(); plan.policy = QByteArray::fromBase64(value["policy"].toString().toLatin1());
    plan.requestedEnvironment = value["requestedEnvironment"].toObject(); plan.basePolicy = QByteArray::fromBase64(value["basePolicy"].toString().toLatin1());
    if (plan.program.isEmpty()) invalid("prepared program is missing");
    return plan;
}
void ApplicationLaunchPlan::applyEnvironment(QProcessEnvironment &target) const {
    for (auto it = environment.begin(); it != environment.end(); ++it) target.insert(it.key(), it.value().toString());
}
QString ApplicationLaunch::singletonConflict(const QStringList &argv, const QString &desktop, bool primary) {
    const auto config = settings();
    QJsonObject environment;
    QStringList warnings;
    const auto command = normalizeCommand(config, argv, primary, environment, warnings);
    return ::singletonConflict(config, command, environment, desktop, primary);
}
ApplicationLaunchPlan ApplicationLaunch::prepare(const QStringList &argv, const QString &desktop, bool primary) {
    return ::prepare(settings(), argv, desktop, primary);
}
ApplicationLaunchPlan ApplicationLaunch::browser(const QString &desktop, bool primary, const QString &program, const QStringList &arguments) {
    const auto config = settings();
    if (!program.isEmpty()) {
        auto plan = ::prepare(config, QStringList{program} + arguments, desktop, primary);
        if (plan.backend != "chromium") invalid("requested executable has no managed chromium rule");
        return plan;
    }
    const auto id = config["browser"].toString();
    const auto rule = config["rules"].toObject()[id].toObject();
    if (rule.isEmpty() || !rule["enabled"].toBool(true) || rule["backend"] != "chromium" || (primary && rule["scope"] == "secondary"))
        invalid("desktopApplications.browser must select an enabled chromium rule for this desktop");
    const auto paths = (QDir::homePath() + "/.local/bin:" + qEnvironmentVariable("PATH")).split(':', Qt::SkipEmptyParts);
    for (const auto &name : strings(rule["executables"], id + ".executables")) {
        const auto executable = QStandardPaths::findExecutable(name, paths);
        if (!executable.isEmpty()) return ::prepare(config, QStringList{executable} + arguments, desktop, primary);
    }
    invalid("no executable installed for browser rule " + id);
}
