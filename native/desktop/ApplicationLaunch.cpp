#include "ApplicationLaunch.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSet>
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
QStringList strings(const QJsonValue &value, const QString &field, bool optional = false) {
    if (value.isUndefined() && optional) return {};
    if (!value.isArray() || value.toArray().size() > 128) invalid(field + " must be an array of up to 128 strings");
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
        const QSet<QString> fields{"executables", "backend", "profile", "profilePaths", "arguments", "environment", "reservedArguments", "scope", "enabled"};
        for (auto field = rule.begin(); field != rule.end(); ++field)
            if (!fields.contains(field.key())) invalid(it.key() + ": unknown field " + field.key());
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
            if (QSet<QString>{"WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE"}.contains(variable.key()))
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
QString expand(QString value, const QString &profile, const QString &desktop) {
    if (value.contains("{profile}") && profile.isEmpty()) invalid("{profile} requires a profile directory");
    value.replace("{profile}", profile).replace("{desktop}", desktop);
    return value;
}
ApplicationLaunchPlan build(const QStringList &argv, const QString &desktop, const QString &id, const QJsonObject &rule) {
    ApplicationLaunchPlan plan;
    plan.program = argv.first();
    plan.arguments = argv.mid(1);
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
    const auto environment = rule["environment"].toObject();
    for (auto it = environment.begin(); it != environment.end(); ++it) plan.environment[it.key()] = expand(it.value().toString(), plan.profile, desktop);
    return plan;
}
ApplicationLaunchPlan prepare(const QJsonObject &config, const QStringList &argv, const QString &desktop, bool primary) {
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
    return build(argv, desktop, id, selected);
}
} // namespace

void ApplicationLaunchPlan::applyEnvironment(QProcessEnvironment &target) const {
    for (auto it = environment.begin(); it != environment.end(); ++it) target.insert(it.key(), it.value().toString());
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
