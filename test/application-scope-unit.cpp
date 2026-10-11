#include "ApplicationScope.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QCryptographicHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QProcess>
#include <QTemporaryDir>
#include <QThread>
#include <QUuid>
#include <csignal>
#include <cstdio>
#include <stdexcept>
#include <memory>
#include <unistd.h>

static void require(bool condition, const char *message) { if (!condition) throw std::runtime_error(message); }
static bool spin(std::function<bool()> condition, int timeout=8000) {
    QElapsedTimer timer; timer.start();
    while (!condition() && timer.elapsed() < timeout) { QCoreApplication::processEvents(QEventLoop::AllEvents,20); QThread::msleep(2); }
    return condition();
}
static QString run(QString program, QStringList arguments) {
    QProcess process; process.start(program,arguments);
    require(process.waitForFinished(4000),"private systemd fixture command timed out");
    require(process.exitStatus()==QProcess::NormalExit && process.exitCode()==0,"private systemd fixture command failed");
    return QString::fromUtf8(process.readAllStandardOutput()).trimmed();
}
static QJsonObject read(const QString &path) { QFile file(path); if (!file.open(QIODevice::ReadOnly)) return {}; return QJsonDocument::fromJson(file.readAll()).object(); }
static void write(const QString &path,QJsonObject object) { QFile file(path); require(file.open(QIODevice::WriteOnly),"private fixture result failed"); file.write(QJsonDocument(object).toJson()); }
static int worker(QCoreApplication &app,const QStringList &args) {
    const auto directory=args[2], instance=args[3], mode=args[4];
    QTimer gate; gate.setInterval(10);
    QObject::connect(&gate,&QTimer::timeout,&app,[&] {
        if (!QFile::exists(directory+"/gate-"+instance)) return;
        gate.stop(); auto environment=QProcessEnvironment::systemEnvironment();
        environment.insert("XDG_RUNTIME_DIR",directory); environment.insert("HYPRLAND_INSTANCE_SIGNATURE",instance);
        environment.insert("SCOPE_PRIVATE_PROBE","retained-value");
        for (const auto *key:{"WAYLAND_DISPLAY","WAYLAND_SOCKET","DISPLAY","DBUS_SESSION_BUS_ADDRESS"}) environment.remove(key);
        const auto program = mode=="bad-exec" ? directory+"/bad-exec" : mode=="fast" ? "/usr/bin/true" : "/usr/bin/sleep";
        auto *job = new ApplicationScope({program,{},directory+"/app-"+instance+".log",(mode=="bad-exec" || mode=="fast") ? QStringList{} : QStringList{"120"},environment},&app);
        auto encode = [](const ApplicationScopeResult &result) { return QJsonObject{{"pid",result.pid},{"unit",result.unit},{"managed",result.managed},{"exited",result.exited},{"error",result.error}}; };
        if (mode=="pair") {
            auto results=std::make_shared<QList<ApplicationScopeResult>>();
            const auto complete=[&,instance,encode,results](ApplicationScopeResult result) {
                results->append(result); if (results->size()!=2) return;
                auto object=encode(results->at(0)); object["peer"]=encode(results->at(1));
                write(directory+"/result-"+instance,object);
            };
            job->whenStarted(complete);
            auto *peer=new ApplicationScope({program,{},directory+"/app-"+instance+".log",{"120"},environment},&app);
            peer->whenStarted(complete);
        } else {
            job->whenStarted([&,instance,encode](ApplicationScopeResult result) { write(directory+"/result-"+instance,encode(result)); });
        }
        if (mode=="denied") job->setSubmissionCheck([] { return QString("Control revoked before application submission"); });
        if (mode=="cancel" || mode=="cancel-app") {
            auto *cancel = new QTimer(job); cancel->setInterval(0);
            QObject::connect(cancel,&QTimer::timeout,job,[job,cancel,mode] {
                if (mode=="cancel" ? job->preparingGuard() : job->submitted()) { cancel->stop(); job->cancel(mode=="cancel" ? "Unit cancelled during actual guard submission" : "Unit cancelled after actual application submission"); }
            }); cancel->start();
        }
    });
    write(directory+"/worker-"+instance,{{"ready",true}}); gate.start();
    return app.exec();
}
int main(int argc,char **argv) {
    QCoreApplication app(argc,argv);
    const auto args=app.arguments();
    if (args.value(1)=="--worker") return worker(app,args);
    const auto user=QString::number(getuid());
    require(ApplicationScope::sliceForCgroup("0::/user.slice/user-"+user+".slice/session-23.scope")=="app.slice","direct SDDM session incorrectly reused a host slice in the user-manager namespace");
    require(ApplicationScope::sliceForCgroup("0::/user.slice/user-"+user+".slice/user@"+user+".service/app.slice/cornice.service")=="app.slice","managed application slice was not retained");
    require(ApplicationScope::sliceForCgroup("0::/user.slice/user-"+user+".slice/user@"+user+".service/corniceapptestbounded.slice/parent.service")=="corniceapptestbounded.slice","private bounded user-manager slice was not retained");
    std::puts("PASS direct sessions default to app.slice and only user-manager child slices are reused");
    const QStringList metadata{"DISPLAY","NOTIFY_SOCKET","INVOCATION_ID","JOURNAL_STREAM"};
    require(ApplicationScope::unsetManagerKeys(QProcessEnvironment{},metadata,true)==QStringList{"DISPLAY"},"guard unset fresh systemd notification or invocation metadata");
    require(ApplicationScope::unsetManagerKeys(QProcessEnvironment{},metadata,false)==QStringList({"DISPLAY","NOTIFY_SOCKET"}),"ordinary applications inherited a stale notify socket or unset fresh per-unit metadata");
    std::puts("PASS stale manager keys are removed while fresh systemd notification and invocation metadata remain available");
    QTemporaryDir temporary("/tmp/cornice-app-scope-XXXXXX"); require(temporary.isValid(),"private fixture directory failed");
    const auto directory=temporary.path(), suffix=QUuid::createUuid().toString(QUuid::WithoutBraces).remove('-');
    const auto slice="corniceapptest"+suffix+".slice";
    QStringList services, appUnits, guards;
    QList<qint64> pids;
    QLocalServer compositorA,compositorB,compositorBad,compositorFast,compositorCancel,compositorCancelApp,compositorDenied,compositorPair;
    auto fixtureSocket = [&](QLocalServer &server,QString instance) {
        const auto path=directory+"/hypr/"+instance+"/.socket2.sock";
        require(QDir().mkpath(QFileInfo(path).path()) && server.listen(path),"private compositor fixture failed");
    };
    fixtureSocket(compositorA,"a"); fixtureSocket(compositorB,"b");
    auto unit = [&](QString instance,QString mode) {
        const auto service="cornice-app-test-"+suffix+"-"+instance+".service"; services.append(service);
        guards.append("cornice-compositor-"+QString::fromLatin1(QCryptographicHash::hash((directory+'\0'+instance).toUtf8(),QCryptographicHash::Sha256).toHex().left(32))+".service");
        run("systemd-run",{"--user","--quiet","--collect","--unit="+service,"--slice="+slice,"--property=Type=exec","--property=UnsetEnvironment=DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET DBUS_SESSION_BUS_ADDRESS","--property=CPUQuota=200%","--property=MemoryMax=3G","--property=MemorySwapMax=0","--property=TasksMax=64","--property=RuntimeMaxSec=120",QCoreApplication::applicationFilePath(),"--worker",directory,instance,mode});
        require(spin([&] { return read(directory+"/worker-"+instance)["ready"].toBool(); }),"private fixture worker did not start");
        run("systemctl",{"--user","set-property","--runtime",slice,"CPUQuota=200%","MemoryMax=3G","MemorySwapMax=0","TasksMax=128"});
        write(directory+"/gate-"+instance,{{"ready",true}});
        require(spin([&] { return QFile::exists(directory+"/result-"+instance); }),"application isolation acknowledgement timed out");
        const auto result=read(directory+"/result-"+instance);
        if (!result["error"].toString().isEmpty()) std::fprintf(stderr,"Fixture %s: %s\n",qPrintable(instance),qPrintable(result["error"].toString()));
        if (!result["unit"].toString().isEmpty()) appUnits.append(result["unit"].toString());
        if (!result["peer"].toObject()["unit"].toString().isEmpty()) appUnits.append(result["peer"].toObject()["unit"].toString());
        return result;
    };
    auto stop = [](QString name) { QProcess process; process.start("systemctl",{"--user","stop",name}); process.waitForFinished(4000); };
    auto cleanup = [&] {
        for (const auto &service:services) stop(service);
        for (auto *server:{&compositorA,&compositorB,&compositorBad,&compositorFast,&compositorCancel,&compositorCancelApp,&compositorDenied,&compositorPair}) {
            server->close(); for (auto *socket:server->findChildren<QLocalSocket *>()) socket->abort();
        }
        for (const auto &application:appUnits) stop(application);
        for (const auto &guard:guards) stop(guard);
        spin([&] { for (const auto pid:pids) if (::kill(pid,0)==0) return false; return true; },4000);
        stop(slice);
    };
    try {
        const auto a=unit("a","sleep"), b=unit("b","sleep");
        require(a["error"].toString().isEmpty() && b["error"].toString().isEmpty() && a["managed"].toBool() && b["managed"].toBool(),"independent application units failed to start");
        const auto pidA=a["pid"].toInteger(),pidB=b["pid"].toInteger(); pids={pidA,pidB};
        require(pidA>0 && pidB>0 && pidA!=pidB,"real application PID acknowledgements missing");
        for (const auto &result:{a,b}) {
            const auto pid=result["pid"].toInteger(); QFile command("/proc/"+QString::number(pid)+"/cmdline"); require(command.open(QIODevice::ReadOnly) && command.readAll().startsWith("/usr/bin/sleep\0"),"application PID is a supervisor rather than the actual executable");
            QFile cgroup("/proc/"+QString::number(pid)+"/cgroup"); require(cgroup.open(QIODevice::ReadOnly),"real application cgroup missing"); const auto path=cgroup.readAll();
            require(path.contains(result["unit"].toString().toUtf8()) && path.contains(slice.toUtf8()),"application did not retain the bounded fixture slice in its independent unit");
            QFile environment("/proc/"+QString::number(pid)+"/environ"); require(environment.open(QIODevice::ReadOnly),"actual application environment unavailable"); const auto values=environment.readAll();
            require(values.contains("SCOPE_PRIVATE_PROBE=retained-value\0"),"application launch environment was not preserved");
            for (const auto &entry:values.split('\0')) require(!entry.startsWith("DISPLAY=") && !entry.startsWith("WAYLAND_DISPLAY=") && !entry.startsWith("WAYLAND_SOCKET="),"manager display environment leaked into the explicitly non-display application");
        }
        std::puts("PASS real user manager executes applications in independent capped units and acknowledges actual PIDs/environment");
        for (const auto &service:services) stop(service);
        require(::kill(pidA,0)==0 && ::kill(pidB,0)==0,"stopping the launcher service terminated its independently owned application");
        std::puts("PASS stopping real parent user services preserves submitted applications");
        // A third launch deliberately fails exec after the file passes executable
        // validation, exercising Type=exec JobRemoved failure, not a mock result.
        QFile bad(directory+"/bad-exec"); require(bad.open(QIODevice::WriteOnly),"bad-exec fixture failed"); bad.write("#!/nonexistent/cornice-unit-interpreter\n"); bad.close(); bad.setPermissions(QFileDevice::ReadOwner|QFileDevice::WriteOwner|QFileDevice::ExeOwner);
        fixtureSocket(compositorBad,"bad");
        const auto failed=unit("bad","bad-exec");
        require(!failed["error"].toString().isEmpty() && failed["pid"].toInteger()==0,"real exec failure reported a fake successful application PID");
        std::puts("PASS real failed exec yields an observable failed startup with no successful PID");
        fixtureSocket(compositorFast,"fast");
        const auto fast=unit("fast","fast");
        require(fast["error"].toString().isEmpty(),"a real fast-exiting executable was falsely reported as a failed launch");
        require(fast["pid"].toInteger()>0 || fast["exited"].toBool(),"a successful fast-exiting executable had no truthful startup state");
        std::puts("PASS real fast-exiting executable returns a truthful executed-or-exited acknowledgement without replay");
        fixtureSocket(compositorCancel,"cancel");
        const auto cancelled=unit("cancel","cancel");
        require(cancelled["pid"].toInteger()==0 && cancelled["error"].toString().contains("no application was submitted"),"guard-stage cancellation crossed the application submission boundary");
        QElapsedTimer settle; settle.start(); require(spin([&] { return settle.elapsed()>400; }),"guard cancellation observation timed out");
        QProcess absent; absent.start("systemctl",{"--user","show",cancelled["unit"].toString(),"--property=MainPID","--value"}); absent.waitForFinished(3000);
        const auto cancelledPid=absent.readAllStandardOutput().trimmed();
        require(cancelledPid.isEmpty() || cancelledPid=="0","late guard acknowledgement started an application after cancellation");
        std::puts("PASS cancellation during real guard submission prevents late startup from submitting a new application");
        fixtureSocket(compositorCancelApp,"cancelapp");
        const auto submitted=unit("cancelapp","cancel-app");
        require(submitted["pid"].toInteger()==0 && submitted["error"].toString().contains("already submitted"),"post-submission cancellation falsely promised an unexecuted application");
        qint64 submittedPid=0;
        require(spin([&] {
            QProcess query; query.start("systemctl",{"--user","show",submitted["unit"].toString(),"--property=MainPID","--value"});
            if (!query.waitForFinished(1000)) return false;
            submittedPid=query.readAllStandardOutput().trimmed().toLongLong(); return submittedPid>0;
        }),"late manager acknowledgement did not preserve the already submitted application");
        pids.append(submittedPid);
        std::puts("PASS cancellation after real application submission reports uncertainty and preserves the executed application");
        fixtureSocket(compositorDenied,"denied");
        const auto denied=unit("denied","denied");
        require(denied["error"].toString().contains("Control revoked") && denied["error"].toString().contains("no application was submitted"),"final control validation failed to stop application submission");
        std::puts("PASS final control validation after real guard startup prevents a revoked application from executing");
        fixtureSocket(compositorPair,"pair");
        const auto pair=unit("pair","pair"), peer=pair["peer"].toObject();
        require(pair["error"].toString().isEmpty() && peer["error"].toString().isEmpty() && pair["pid"].toInteger()>0 && peer["pid"].toInteger()>0 && pair["pid"]!=peer["pid"],"concurrent applications could not share a real starting compositor guard");
        pids.append(pair["pid"].toInteger()); pids.append(peer["pid"].toInteger());
        std::puts("PASS concurrent real application launches safely share one compositor lifetime guard");
        for (auto *socket:compositorA.findChildren<QLocalSocket *>()) socket->abort(); compositorA.close();
        require(spin([&] { return ::kill(pidA,0)!=0; }),"compositor connection loss did not end its owned application unit");
        require(::kill(pidB,0)==0,"one compositor guard terminated another instance's application");
        std::puts("PASS actual compositor connection loss closes only that instance's submitted applications");
        cleanup();
        std::puts("PASS private systemd fixture removes its own services, app units, guards and capped slice");
        return 0;
    } catch (const std::exception &error) { std::fprintf(stderr,"FAIL %s\n",error.what()); cleanup(); temporary.setAutoRemove(false); std::fprintf(stderr,"Private fixture evidence: %s\n",qPrintable(directory)); return 1; }
}
