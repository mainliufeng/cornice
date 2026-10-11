#include <QCoreApplication>
#include <QLocalSocket>
#include <QTimer>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstring>

// A compositor event connection, not a health probe: silence never logs out a
// desktop. Only actual connection loss ends this guard and its dependent apps.
static bool ready() {
    const auto address = qgetenv("NOTIFY_SOCKET");
    if (address.isEmpty() || address.size() >= int(sizeof(sockaddr_un::sun_path))) return false;
    sockaddr_un destination{}; destination.sun_family = AF_UNIX;
    std::memcpy(destination.sun_path,address.constData(),address.size());
    if (destination.sun_path[0] == '@') destination.sun_path[0] = '\0';
    const int descriptor = ::socket(AF_UNIX,SOCK_DGRAM|SOCK_CLOEXEC,0);
    if (descriptor < 0) return false;
    const auto size = offsetof(sockaddr_un,sun_path)+address.size()+(address[0]=='@' ? 0 : 1);
    const auto sent = ::sendto(descriptor,"READY=1",7,MSG_NOSIGNAL,reinterpret_cast<sockaddr *>(&destination),size);
    ::close(descriptor); return sent == 7;
}
int main(int argc, char **argv) {
    QCoreApplication app(argc,argv);
    if (app.arguments().size()!=2) return 2;
    QLocalSocket compositor;
    QTimer deadline; deadline.setSingleShot(true); deadline.start(4000);
    QObject::connect(&deadline,&QTimer::timeout,&app,[&] { app.exit(1); });
    QObject::connect(&compositor,&QLocalSocket::connected,&app,[&] { if (!ready()) app.exit(1); else deadline.stop(); });
    QObject::connect(&compositor,&QLocalSocket::errorOccurred,&app,[&](QLocalSocket::LocalSocketError) { app.exit(1); });
    QObject::connect(&compositor,&QLocalSocket::disconnected,&app,[&] { app.quit(); });
    QObject::connect(&compositor,&QLocalSocket::readyRead,&app,[&] { compositor.readAll(); });
    compositor.connectToServer(app.arguments()[1]);
    return app.exec();
}
