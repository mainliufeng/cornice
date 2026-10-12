#pragma once
#include <QByteArray>
#include <QJsonObject>
#include <QMap>
#include <QSet>
#include <QString>
#include <memory>
#include <wayland-client.h>

struct zwlr_virtual_pointer_manager_v1;
struct zwp_virtual_keyboard_manager_v1;
struct zwlr_virtual_pointer_v1;
struct zwp_virtual_keyboard_v1;
struct xkb_keymap;
struct xkb_state;

// One persistent connection and two explicitly seat-bound virtual devices.
class SeatDriver {
  public:
    SeatDriver(const QString &display, const QString &name, const QString &output);
    ~SeatDriver();
    void input(const QJsonObject &params, int width, int height);
    void release();

  private:
    static void global(void *, wl_registry *, uint32_t, const char *, uint32_t);
    static void globalRemoved(void *, wl_registry *, uint32_t);
    static void bindGlobal(void *, wl_registry *, uint32_t, const char *, uint32_t);
    void sync();
    void disconnect();
    void setKeymap(const QByteArray &);
    void key(uint32_t code, bool pressed);
    void modifiers();
    void type(const QString &text);
    wl_display *m_display = nullptr;
    wl_registry *m_registry = nullptr;
    wl_seat *m_seat = nullptr;
    wl_output *m_output = nullptr;
    struct Global {
        QString interface;
        uint32_t version;
    };
    QMap<uint32_t, Global> m_globals;
    QMap<uint32_t, wl_seat *> m_seats;
    QMap<uint32_t, wl_output *> m_outputs;
    uint32_t m_pointerManagerGlobal = 0, m_keyboardManagerGlobal = 0;
    bool m_discovering = true, m_available = true;
    zwlr_virtual_pointer_manager_v1 *m_pointerManager = nullptr;
    zwp_virtual_keyboard_manager_v1 *m_keyboardManager = nullptr;
    zwlr_virtual_pointer_v1 *m_pointer = nullptr;
    zwp_virtual_keyboard_v1 *m_keyboard = nullptr;
    xkb_keymap *m_keymap = nullptr;
    xkb_state *m_state = nullptr;
    bool m_standardMap = true;
    QSet<uint32_t> m_keys;
    QSet<uint32_t> m_buttons;
    uint32_t m_modifiers = 0;
    QString m_name, m_outputName;
};
