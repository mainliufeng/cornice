#include "Broker.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QLockFile>
#include <QProcess>
#include <QSaveFile>
#include <QTextStream>
#include <QUuid>
#include <csignal>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

static volatile sig_atomic_t stopping = 0;
static void stop(int) { stopping = 1; }
static QString take(QStringList &args) {
    if (args.isEmpty())
        throw std::runtime_error("Missing argument");
    return args.takeFirst();
}
static QJsonObject readJson(const QByteArray &bytes) {
    QJsonParseError error;
    const auto document = QJsonDocument::fromJson(bytes, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject())
        throw std::runtime_error("JSON object required");
    return document.object();
}
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    try {
        auto args = app.arguments();
        args.removeFirst();
        QString instance = qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE");
        if (args.value(0) == "--instance") {
            args.removeFirst();
            instance = take(args);
        }
        const auto command = take(args);
        if (command == "ensure") {
            const auto socket = desktopSocket(instance);
            try {
                const auto reply = desktopRequest(socket, {{"id", "ensure"}, {"method", "doctor"}});
                if (reply["ok"].toBool())
                    return 0;
            } catch (...) {
            }
            QProcess process;
            process.setProgram(app.applicationFilePath());
            process.setArguments({"--instance", instance, "serve"});
            process.setStandardOutputFile(QFileInfo(socket).path() + "/desktopd.log", QIODevice::Append);
            process.setStandardErrorFile(QFileInfo(socket).path() + "/desktopd.log", QIODevice::Append);
            QDir().mkpath(QFileInfo(socket).path());
            if (!process.startDetached())
                throw std::runtime_error("Cannot start desktop service");
            return 0;
        }
        if (command == "serve") {
            const auto path = desktopSocket(instance);
            QDir().mkpath(QFileInfo(path).path());
            QLockFile lock(path + ".lock");
            lock.setStaleLockTime(0);
            if (!lock.tryLock(0))
                throw std::runtime_error("Desktop service already running for this instance");
            std::signal(SIGPIPE, SIG_IGN);
            Broker broker(instance);
            broker.listen();
            std::signal(SIGTERM, stop);
            std::signal(SIGINT, stop);
            QTimer timer;
            QObject::connect(&timer, &QTimer::timeout, &app, [&app] {
                if (stopping)
                    app.quit();
            });
            timer.start(100);
            return app.exec();
        }
        QJsonObject request{{"id", QUuid::createUuid().toString(QUuid::WithoutBraces)}};
        QString socket = (command == "tool" || command == "detach") ? QString{} : desktopSocket(instance), bindingPath, outputPath;
        if (command == "request") {
            QFile input;
            if (!input.open(stdin, QIODevice::ReadOnly))
                throw std::runtime_error("Cannot read request");
            request = readJson(input.readAll());
        } else if (command == "tool" || command == "detach") {
            bindingPath = take(args);
            QFile file(bindingPath);
            struct stat info{};
            if (!file.open(QIODevice::ReadOnly) || fstat(file.handle(), &info) || !S_ISREG(info.st_mode) ||
                info.st_uid != getuid() || (info.st_mode & 0077) || info.st_size > 16384)
                throw std::runtime_error("Private agent binding file required");
            const auto binding = readJson(file.readAll());
            socket = binding["socket"].toString();
            if (command == "detach") {
                request["method"] = "detach";
                request["params"] = QJsonObject{{"name",binding["name"]},{"seatId",binding["seatId"]},
                    {"generation",binding["generation"]},{"bindingToken",binding["token"]}};
            } else {
                request["token"] = binding["token"];
                request["method"] = take(args);
                request["params"] = args.isEmpty() ? QJsonObject{} : readJson(take(args).toUtf8());
            }
        } else {
            request["method"] = command;
            QJsonObject params;
            if (command != "list" && command != "doctor")
                params["name"] = take(args);
            if (command == "create") {
                while (!args.isEmpty()) {
                    const auto flag = take(args);
                    if (flag != "--workspace" && flag != "--output" && flag != "--virtual-output" &&
                        flag != "--human-lock-policy")
                        throw std::runtime_error("Expected --workspace or --output");
                    params[flag.mid(2)] = take(args);
                }
            } else if (command == "view-focus") {
                params["address"] = take(args);
            } else if (command == "view-workspace") {
                params["slot"] = take(args).toInt();
            } else if (command == "allow-agent") {
                const auto value = take(args);
                if (value != "on" && value != "off") throw std::runtime_error("Expected on or off");
                params["allowed"] = value == "on";
            } else if (command == "lock-policy") {
                params["policy"] = take(args);
            } else if (command == "launch") {
                if (args.value(0) == "--")
                    args.removeFirst();
                params["argv"] = QJsonArray::fromStringList(args);
                args.clear();
            } else if (command == "bind" || command == "capture")
                outputPath = take(args);
            if (!args.isEmpty())
                throw std::runtime_error("Unexpected arguments");
            request["params"] = params;
        }
        const auto reply = desktopRequest(socket, request);
        if (!reply["ok"].toBool()) {
            QTextStream(stderr) << "cornice desktop: " << reply["error"].toString() << '\n';
            return 1;
        }
        auto result = reply["result"].toObject();
        if (!outputPath.isEmpty()) {
            QSaveFile file(outputPath);
            if (!file.open(QIODevice::WriteOnly))
                throw std::runtime_error("Cannot open output file");
            file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
            if (command == "bind")
                file.write(QJsonDocument(result).toJson());
            else {
                file.write(QByteArray::fromBase64(result.take("pngBase64").toString().toLatin1()));
            }
            if (!file.commit())
                throw std::runtime_error("Cannot save output file");
            if (command == "bind") {
                result.remove("token");
                result["bindingFile"] = outputPath;
            } else
                result["path"] = outputPath;
        }
        QTextStream(stdout) << QJsonDocument(result).toJson(QJsonDocument::Compact) << '\n';
        return 0;
    } catch (const std::exception &error) {
        QTextStream(stderr) << "cornice desktop: " << error.what() << '\n';
        return 1;
    }
}
