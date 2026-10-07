#include "SeatDriver.hpp"
#include "virtual-keyboard-unstable-v1.h"
#include "wlr-virtual-pointer-unstable-v1.h"
#include <QElapsedTimer>
#include <QJsonArray>
#include <QTemporaryFile>
#include <QThread>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <linux/input-event-codes.h>
#include <poll.h>
#include <stdexcept>
#include <xkbcommon/xkbcommon.h>

static void fail(const QString &text) { throw std::runtime_error(text.toStdString()); }
static uint32_t now() {
    return static_cast<uint32_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch())
            .count());
}

SeatDriver::SeatDriver(const QString &display, const QString &name, const QString &output)
    : m_name(name), m_outputName(output) {
    m_display = wl_display_connect(display.toUtf8().constData());
    if (!m_display)
        fail("Cannot connect to bound seat display");
    try {
        m_registry = wl_display_get_registry(m_display);
        static const wl_registry_listener listener = {global, [](void *, wl_registry *, uint32_t) {}};
        wl_registry_add_listener(m_registry, &listener, this);
        sync();
        sync();
        if (!m_seat || !m_output || !m_pointerManager || !m_keyboardManager)
            fail("Bound seat/output or virtual input protocol missing");
        m_pointer =
            zwlr_virtual_pointer_manager_v1_create_virtual_pointer_with_output(m_pointerManager, m_seat, m_output);
        m_keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(m_keyboardManager, m_seat);
        auto *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
        if (!context)
            fail("Keyboard context unavailable");
        xkb_rule_names rules{};
        rules.layout = "us";
        m_keymap = xkb_keymap_new_from_names(context, &rules, XKB_KEYMAP_COMPILE_NO_FLAGS);
        xkb_context_unref(context);
        if (!m_keymap)
            fail("Keyboard map unavailable");
        m_state = xkb_state_new(m_keymap);
        if (!m_state)
            fail("Keyboard state unavailable");
        char *map = xkb_keymap_get_as_string(m_keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
        QByteArray data(map);
        free(map);
        setKeymap(data);
        sync();
    } catch (...) {
        if (m_state)
            xkb_state_unref(m_state);
        if (m_keymap)
            xkb_keymap_unref(m_keymap);
        disconnect();
        throw;
    }
}

SeatDriver::~SeatDriver() {
    if (m_display) {
        try {
            release();
        } catch (...) {
        }
        disconnect();
    }
    if (m_keymap)
        xkb_keymap_unref(m_keymap);
    if (m_state)
        xkb_state_unref(m_state);
}

void SeatDriver::disconnect() {
    // Destroy every client-side proxy even after an IO failure. The server
    // releases its resources when this connection closes.
    const auto destroy = [](auto *proxy) {
        if (proxy)
            wl_proxy_destroy(reinterpret_cast<wl_proxy *>(proxy));
    };
    destroy(m_pointer);
    destroy(m_keyboard);
    destroy(m_pointerManager);
    destroy(m_keyboardManager);
    for (auto *seat : m_seats)
        destroy(seat);
    for (auto *output : m_outputs)
        destroy(output);
    destroy(m_registry);
    if (m_display)
        wl_display_disconnect(m_display);
    m_display = nullptr;
}

void SeatDriver::global(void *data, wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
    auto *self = static_cast<SeatDriver *>(data);
    if (!strcmp(interface, "wl_seat") && version >= 5) {
        auto *seat = static_cast<wl_seat *>(wl_registry_bind(registry, id, &wl_seat_interface, 5));
        self->m_seats.append(seat);
        static const wl_seat_listener listener = {[](void *, wl_seat *, uint32_t) {},
                                                  [](void *d, wl_seat *s, const char *n) {
                                                      auto *driver = static_cast<SeatDriver *>(d);
                                                      if (driver->m_name == QString::fromUtf8(n))
                                                          driver->m_seat = s;
                                                  }};
        wl_seat_add_listener(seat, &listener, self);
    } else if (!strcmp(interface, "wl_output") && version >= 4) {
        auto *output = static_cast<wl_output *>(wl_registry_bind(registry, id, &wl_output_interface, 4));
        self->m_outputs.append(output);
        static const wl_output_listener listener = {[](void *, wl_output *, int32_t, int32_t, int32_t, int32_t, int32_t,
                                                       const char *, const char *, int32_t) {},
                                                    [](void *, wl_output *, uint32_t, int32_t, int32_t, int32_t) {},
                                                    [](void *, wl_output *) {},
                                                    [](void *, wl_output *, int32_t) {},
                                                    [](void *d, wl_output *o, const char *n) {
                                                        auto *driver = static_cast<SeatDriver *>(d);
                                                        if (driver->m_outputName == QString::fromUtf8(n))
                                                            driver->m_output = o;
                                                    },
                                                    [](void *, wl_output *, const char *) {}};
        wl_output_add_listener(output, &listener, self);
    } else if (!strcmp(interface, "zwlr_virtual_pointer_manager_v1") && version >= 2)
        self->m_pointerManager = static_cast<zwlr_virtual_pointer_manager_v1 *>(
            wl_registry_bind(registry, id, &zwlr_virtual_pointer_manager_v1_interface, 2));
    else if (!strcmp(interface, "zwp_virtual_keyboard_manager_v1"))
        self->m_keyboardManager = static_cast<zwp_virtual_keyboard_manager_v1 *>(
            wl_registry_bind(registry, id, &zwp_virtual_keyboard_manager_v1_interface, 1));
}

void SeatDriver::sync() {
    // Bounded dispatch: a stalled compositor must not strand the desktop broker.
    bool done = false;
    auto *callback = wl_display_sync(m_display);
    const auto guard = std::unique_ptr<wl_callback, decltype(&wl_callback_destroy)>(callback, wl_callback_destroy);
    static const wl_callback_listener listener = {
        [](void *data, wl_callback *, uint32_t) { *static_cast<bool *>(data) = true; }};
    wl_callback_add_listener(callback, &listener, &done);
    QElapsedTimer timer;
    timer.start();
    while (!done) {
        if (wl_display_dispatch_pending(m_display) < 0)
            fail("Seat connection lost");
        if (done)
            break;
        if (timer.elapsed() > 2000) {
            fail("Seat input acknowledgement timed out");
        }
        wl_display_flush(m_display);
        pollfd fd{wl_display_get_fd(m_display), POLLIN, 0};
        const auto result = poll(&fd, 1, 100);
        if (result > 0 && wl_display_dispatch(m_display) < 0)
            fail("Seat connection lost");
    }
}

void SeatDriver::setKeymap(const QByteArray &map) {
    QTemporaryFile file;
    file.setAutoRemove(true);
    if (!file.open() || file.write(map) != map.size() || file.write("\0", 1) != 1 || !file.flush())
        fail("Cannot create private keymap");
    zwp_virtual_keyboard_v1_keymap(m_keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, file.handle(), map.size() + 1);
    sync();
}

void SeatDriver::key(uint32_t code, bool pressed) {
    zwp_virtual_keyboard_v1_key(m_keyboard, now(), code, pressed ? 1 : 0);
    if (m_standardMap) {
        xkb_state_update_key(m_state, code + 8, pressed ? XKB_KEY_DOWN : XKB_KEY_UP);
        const auto depressed = xkb_state_serialize_mods(m_state, XKB_STATE_MODS_DEPRESSED);
        zwp_virtual_keyboard_v1_modifiers(m_keyboard, depressed | m_modifiers,
                                          xkb_state_serialize_mods(m_state, XKB_STATE_MODS_LATCHED),
                                          xkb_state_serialize_mods(m_state, XKB_STATE_MODS_LOCKED),
                                          xkb_state_serialize_layout(m_state, XKB_STATE_LAYOUT_EFFECTIVE));
    }
    if (pressed)
        m_keys.insert(code);
    else
        m_keys.remove(code);
}

void SeatDriver::modifiers() { zwp_virtual_keyboard_v1_modifiers(m_keyboard, m_modifiers, 0, 0, 0); }

void SeatDriver::release() {
    if (!m_keyboard || !m_pointer)
        return;
    for (const auto code : QSet<uint32_t>(m_keys))
        key(code, false);
    m_modifiers = 0;
    modifiers();
    for (const auto code : m_buttons)
        zwlr_virtual_pointer_v1_button(m_pointer, now(), code, 0);
    m_buttons.clear();
    zwlr_virtual_pointer_v1_frame(m_pointer);
    sync();
}

void SeatDriver::type(const QString &text) {
    if (!m_keys.empty() || !m_buttons.empty() || m_modifiers)
        fail("Release held input before typing text");
    const auto characters = text.toUcs4();
    if (characters.size() > 4096)
        fail("Text exceeds 4096 code points");
    for (const auto cp : characters)
        if (cp == 0 || (cp < 32 && cp != 10 && cp != 9))
            fail("Unsupported control character");
    m_standardMap = false;
    // Direct Unicode keysyms: no clipboard mutation and no dependency on the
    // human seat's IME. Newline/tab retain their normal application semantics.
    static constexpr uint32_t codesForText[] = {30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50,
                                                49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44};
    for (qsizetype offset = 0; offset < characters.size(); offset += 26) {
        const auto length = std::min<qsizetype>(26, characters.size() - offset);
        QByteArray codes, symbols;
        for (int i = 0; i < length; ++i) {
            const uint32_t cp = characters[offset + i];
            if (cp == 0 || (cp < 32 && cp != 10 && cp != 9))
                fail("Unsupported control character");
            const auto sym = cp == 10  ? QByteArray("Return")
                             : cp == 9 ? QByteArray("Tab")
                                       : QByteArray("U") + QByteArray::number(cp, 16);
            codes += "<K" + QByteArray::number(i) + ">=" + QByteArray::number(codesForText[i] + 8) + ";";
            symbols += "key <K" + QByteArray::number(i) + "> { [ " + sym + " ] };";
        }
        setKeymap("xkb_keymap { xkb_keycodes { minimum=8; maximum=255;" + codes +
                  "}; xkb_types { type \"ONE_LEVEL\" { modifiers=None; map[None]=Level1; }; };"
                  "xkb_compatibility {}; xkb_symbols {" +
                  symbols + "}; };");
        for (int i = 0; i < length; ++i) {
            key(codesForText[i], true);
            key(codesForText[i], false);
        }
        sync();
    }
    char *map = xkb_keymap_get_as_string(m_keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    QByteArray original(map);
    free(map);
    setKeymap(original);
    m_standardMap = true;
}

void SeatDriver::input(const QJsonObject &params, int width, int height) {
    const auto action = params["action"].toString();
    if (action == "move" || action == "click") {
        const auto x = params["x"].toDouble(-1), y = params["y"].toDouble(-1);
        if (!std::isfinite(x) || !std::isfinite(y) || x < 0 || y < 0 || x >= width || y >= height)
            fail("Coordinates outside captured workspace");
        const auto button = params["button"].toString("left");
        const uint32_t code = button == "left"     ? BTN_LEFT
                              : button == "right"  ? BTN_RIGHT
                              : button == "middle" ? BTN_MIDDLE
                                                   : 0;
        if (!code || (params.contains("button") && !params["button"].isString()))
            fail("Unknown button");
        zwlr_virtual_pointer_v1_motion_absolute(m_pointer, now(), x, y, width, height);
        zwlr_virtual_pointer_v1_frame(m_pointer);
        if (action == "click") {
            zwlr_virtual_pointer_v1_button(m_pointer, now(), code, 1);
            zwlr_virtual_pointer_v1_button(m_pointer, now(), code, 0);
            zwlr_virtual_pointer_v1_frame(m_pointer);
        }
    } else if (action == "button") {
        const auto code = params["code"].toInt();
        if (!params["code"].isDouble() || params["code"].toDouble() != code || code < BTN_LEFT || code > BTN_TASK ||
            !params["pressed"].isBool())
            fail("Invalid pointer button event");
        const bool pressed = params["pressed"].toBool();
        zwlr_virtual_pointer_v1_button(m_pointer, now(), code, pressed);
        if (pressed)
            m_buttons.insert(code);
        else
            m_buttons.remove(code);
        zwlr_virtual_pointer_v1_frame(m_pointer);
    } else if (action == "scroll") {
        const double delta = params["delta"].toDouble();
        if (!params["delta"].isDouble() || !std::isfinite(delta) || std::abs(delta) > 10000)
            fail("Invalid scroll delta");
        const auto axisName = params["axis"].toString("vertical");
        if ((params.contains("axis") && !params["axis"].isString()) ||
            (axisName != "horizontal" && axisName != "vertical"))
            fail("Invalid scroll axis");
        const auto axis = axisName == "horizontal" ? 1 : 0;
        zwlr_virtual_pointer_v1_axis_source(m_pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
        zwlr_virtual_pointer_v1_axis(m_pointer, now(), axis, wl_fixed_from_double(delta));
        zwlr_virtual_pointer_v1_frame(m_pointer);
    } else if (action == "text") {
        if (!params["text"].isString())
            fail("Text string required");
        type(params["text"].toString());
    } else if (action == "key") {
        const auto code = params["code"].toInt(-1);
        if (!params["code"].isDouble() || params["code"].toDouble() != code || code < 0 || code > 247 ||
            !params["pressed"].isBool())
            fail("Invalid evdev key event");
        key(code, params["pressed"].toBool());
    } else if (action == "chord") {
        if (!m_keys.empty() || m_modifiers)
            fail("Release held keys before a chord");
        const auto keys = params["keys"].toArray();
        if (keys.isEmpty() || keys.size() > 8)
            fail("Invalid chord");
        uint32_t code = 0;
        bool hasKey = false;
        uint32_t pendingModifiers = 0;
        for (const auto &item : keys) {
            const auto name = item.toString();
            if (name == "CTRL" || name == "SHIFT" || name == "ALT" || name == "SUPER") {
                const auto mod = name == "CTRL"    ? XKB_MOD_NAME_CTRL
                                 : name == "SHIFT" ? XKB_MOD_NAME_SHIFT
                                 : name == "ALT"   ? XKB_MOD_NAME_ALT
                                                   : XKB_MOD_NAME_LOGO;
                const auto index = xkb_keymap_mod_get_index(m_keymap, mod);
                if (index == XKB_MOD_INVALID || index >= 32)
                    fail("Modifier unavailable");
                pendingModifiers |= 1u << index;
            } else {
                if (hasKey)
                    fail("Chord requires one non-modifier key");
                const auto sym = xkb_keysym_from_name(name.toUtf8().constData(), XKB_KEYSYM_CASE_INSENSITIVE);
                bool found = false;
                for (auto keycode = xkb_keymap_min_keycode(m_keymap); keycode <= xkb_keymap_max_keycode(m_keymap);
                     ++keycode) {
                    const xkb_keysym_t *syms = nullptr;
                    if (xkb_keymap_key_get_syms_by_level(m_keymap, keycode, 0, 0, &syms) == 1 && syms[0] == sym) {
                        code = keycode - 8;
                        found = true;
                        break;
                    }
                }
                if (!found)
                    fail("Unknown chord key");
                hasKey = true;
            }
        }
        if (!hasKey)
            fail("Chord requires a non-modifier key");
        m_modifiers = pendingModifiers;
        modifiers();
        key(code, true);
        key(code, false);
        m_modifiers = 0;
        modifiers();
    } else if (action == "release")
        release();
    else
        fail("Unknown input action");
    sync();
}
