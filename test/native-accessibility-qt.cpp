// Real Qt Widgets accessibility fixture. No mocked accessibility providers.
#include <QApplication>
#include <QFile>
#include <QLineEdit>
#include <QPushButton>
#include <QVBoxLayout>
#include <QWidget>
int main(int argc, char **argv) {
    QApplication app(argc, argv);
    QWidget window;
    window.setWindowTitle("native-qt-window");
    auto layout = new QVBoxLayout(&window);
    auto entry = new QLineEdit;
    entry->setAccessibleName("Qt Answer");
    auto button = new QPushButton("Qt Record a click");
    layout->addWidget(entry);
    layout->addWidget(button);
    QObject::connect(entry, &QLineEdit::textChanged, [&](const QString &text) {
        QFile file(QString::fromLocal8Bit(argv[1]));
        if (file.open(QIODevice::WriteOnly))
            file.write(text.toUtf8());
    });
    QObject::connect(button, &QPushButton::clicked, [&] {
        QFile file(QString::fromLocal8Bit(argv[1]) + ".click");
        if (file.open(QIODevice::WriteOnly))
            file.write("1");
    });
    window.resize(480, 320);
    window.show();
    return app.exec();
}
