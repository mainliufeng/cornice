#include "Background.hpp"
#include "hyprland-lock-scope-v1.h"
#include "ext-session-lock-v1.h"
#include <QCommandLineParser>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QJsonDocument>
#include <QJsonArray>
#include <QLocalSocket>
#include <QJsonObject>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QProcess>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickRenderControl>
#include <QQuickRenderTarget>
#include <QQuickWindow>
#include <QSocketNotifier>
#include <QTimer>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <pwd.h>
#include <security/pam_appl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon-compose.h>
#include <xkbcommon/xkbcommon.h>

class HumanLock;
struct Output {
  HumanLock *owner = nullptr;
  uint32_t id = 0;
  wl_output *output = nullptr;
  wl_surface *surface = nullptr;
  hyprland_lock_scope_surface_v1 *lockSurface = nullptr;
  ext_session_lock_surface_v1 *fullSurface = nullptr;
  bool roleKnown = false, privateOutput = false, configured = false,
       dirty = true;
  int width = 0, height = 0, scale = 1;
  std::unique_ptr<QQuickRenderControl> control;
  std::unique_ptr<QQuickWindow> window;
  std::unique_ptr<QQuickItem> item;
  QImage image;
};
class HumanLock : public QObject {
  Q_OBJECT
  Q_PROPERTY(QVariantMap appearance READ appearance NOTIFY appearanceChanged)
  Q_PROPERTY(
      QString backgroundSource READ backgroundSource NOTIFY appearanceChanged)
  Q_PROPERTY(QString pamService MEMBER pamService CONSTANT)
  Q_PROPERTY(QString pamDirectory MEMBER pamDirectory CONSTANT)
  Q_PROPERTY(QString user MEMBER user CONSTANT)
  Q_PROPERTY(QString scope READ scope CONSTANT)
  Q_PROPERTY(bool showUser MEMBER showUser CONSTANT)
  Q_PROPERTY(bool busy READ busy NOTIFY authenticationChanged)
  Q_PROPERTY(QString message READ message NOTIFY authenticationChanged)
public:
  QVariantMap m_appearance;
  LockBackground *background = nullptr; // owned by QQmlEngine
  int backgroundRevision = 0;
  QVariantMap appearance() const { return m_appearance; }
  QString backgroundSource() const {
    return background && !background->image.isNull()
               ? QString("image://lock-background/%1").arg(backgroundRevision)
               : QString{};
  }
  void setAppearance(const QJsonObject &value) {
    m_appearance = value.toVariantMap();
    background->load(value.value("backgroundSource").toString(),
                     value.value("blur").toDouble(1));
    ++backgroundRevision;
    emit appearanceChanged();
  }
  Q_INVOKABLE void clearMessage() {
    if (!m_busy && !m_message.isEmpty()) {
      m_message.clear();
      emit authenticationChanged();
    }
  }
  QString pamService, pamDirectory, user;
  wl_display *display = nullptr;
  wl_compositor *compositor = nullptr;
  wl_shm *shm = nullptr;
  wl_seat *seat = nullptr;
  wl_keyboard *keyboard = nullptr;
  wl_pointer *pointer = nullptr;
  hyprland_lock_scope_manager_v1 *manager = nullptr;
  hyprland_lock_scope_v1 *lock = nullptr;
  ext_session_lock_manager_v1 *fullManager = nullptr;
  ext_session_lock_v1 *fullLock = nullptr;
  bool fullScope = false, showUser = true;
  QString scope() const { return fullScope ? "session" : "human"; }
  bool ownsLock() const { return lock || fullLock; }
  std::map<uint32_t, std::unique_ptr<Output>> outputs;
  Output *keyFocus = nullptr, *pointerFocus = nullptr;
  xkb_context *xkb = nullptr;
  xkb_keymap *keymap = nullptr;
  xkb_state *keyState = nullptr;
  xkb_compose_table *composeTable = nullptr;
  xkb_compose_state *composeState = nullptr;
  QTimer repeatTimer;
  uint32_t repeatingKey = 0;
  int repeatRate = 0, repeatDelay = 0;
  bool repeating = false;
  QQmlEngine engine;
  QTimer renderTimer;
  QPointF pointerPosition;
  Qt::MouseButtons buttons;
  bool secure = false, emergencyAllowed = false;
  QByteArray input;
  QProcess authenticator;
  QTimer authTimer;
  bool m_busy = false;
  QString m_message;
  bool busy() const { return m_busy; }
  QString message() const { return m_message; }
  Q_INVOKABLE void authenticate(QString password) {
    if (m_busy || !secure || !ownsLock())
      return;
    m_busy = true;
    m_message = "正在验证…";
    emit authenticationChanged();
    event("authenticating");
    authenticator.setProgram(QCoreApplication::applicationFilePath());
    authenticator.setArguments({"--pam-worker", pamService, pamDirectory});
    authenticator.start();
    if (!authenticator.waitForStarted(1000)) {
      m_busy = false;
      m_message = "认证服务无法启动";
      emit authenticationChanged();
      return;
    }
    auto request = QJsonDocument(QJsonObject{{"password", password}})
                       .toJson(QJsonDocument::Compact);
    password.fill(QChar(0));
    password.clear();
    authenticator.write(request);
    authenticator.closeWriteChannel();
    request.fill(0);
    authTimer.start(30000);
  }
signals:
  void authenticationChanged();
  void appearanceChanged();

public:
  HumanLock() {
    background = new LockBackground();
    engine.addImageProvider("lock-background", background);
    xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    auto locale =
        qEnvironmentVariable(
            "LC_ALL", qEnvironmentVariable(
                          "LC_CTYPE", qEnvironmentVariable("LANG", "C.UTF-8")))
            .toUtf8();
    composeTable = xkb_compose_table_new_from_locale(
        xkb, locale.constData(), XKB_COMPOSE_COMPILE_NO_FLAGS);
    if (composeTable)
      composeState =
          xkb_compose_state_new(composeTable, XKB_COMPOSE_STATE_NO_FLAGS);
    connect(&repeatTimer, &QTimer::timeout, this, [this] {
      key(repeatingKey, WL_KEYBOARD_KEY_STATE_PRESSED, true);
      repeatTimer.start(std::max(1, 1000 / std::max(1, repeatRate)));
    });
    authTimer.setSingleShot(true);
    connect(&authTimer, &QTimer::timeout, this, [this] {
      authenticator.kill();
      m_message = "认证超时，请重试";
      emit authenticationChanged();
    });
    connect(&authenticator, &QProcess::finished, this,
            [this](int code, QProcess::ExitStatus status) {
              const bool timedOut = !authTimer.isActive();
              authTimer.stop();
              m_busy = false;
              if (!timedOut && code == 0 && status == QProcess::NormalExit &&
                  secure && ownsLock())
                unlock();
              else {
                if (!timedOut)
                  m_message = "验证失败，请重试";
                emit authenticationChanged();
                event("authentication-failed");
              }
            });
  }
  ~HumanLock() override {
    authenticator.kill();
    authenticator.waitForFinished(1000);
    outputs.clear();
    if (keyState)
      xkb_state_unref(keyState);
    if (keymap)
      xkb_keymap_unref(keymap);
    if (composeState)
      xkb_compose_state_unref(composeState);
    if (composeTable)
      xkb_compose_table_unref(composeTable);
    if (xkb)
      xkb_context_unref(xkb);
    // Disconnecting never requests unlock, including normal process teardown.
    if (display)
      wl_display_disconnect(display);
  }
  void event(const QString &name) {
    const auto bytes = QJsonDocument(QJsonObject{{"event", name},
                                                 {"scope", scope()},
                                                 {"secure", secure}})
                           .toJson(QJsonDocument::Compact);
    fwrite(bytes.data(), 1, bytes.size(), stdout);
    fputc('\n', stdout);
    fflush(stdout);
  }
  Q_INVOKABLE void unlock() {
    if (!ownsLock() || !secure)
      return;
    if (fullLock) {
      ext_session_lock_v1_unlock_and_destroy(fullLock);
      fullLock = nullptr;
    }
    if (lock) {
      hyprland_lock_scope_v1_unlock_and_destroy(lock);
      lock = nullptr;
    }
    if (wl_display_roundtrip(display) < 0) {
      event("disconnected");
      QCoreApplication::exit(2);
      return;
    }
    secure = false;
    event("unlocked");
    QCoreApplication::quit();
  }
  Qt::KeyboardModifiers modifiers() const {
    Qt::KeyboardModifiers result;
    if (!keyState)
      return result;
    if (xkb_state_mod_name_is_active(keyState, XKB_MOD_NAME_SHIFT,
                                     XKB_STATE_MODS_EFFECTIVE))
      result |= Qt::ShiftModifier;
    if (xkb_state_mod_name_is_active(keyState, XKB_MOD_NAME_CTRL,
                                     XKB_STATE_MODS_EFFECTIVE))
      result |= Qt::ControlModifier;
    if (xkb_state_mod_name_is_active(keyState, XKB_MOD_NAME_ALT,
                                     XKB_STATE_MODS_EFFECTIVE))
      result |= Qt::AltModifier;
    return result;
  }
  Output *forSurface(wl_surface *surface) {
    for (const auto &[id, o] : outputs)
      if (o->surface == surface)
        return o.get();
    return nullptr;
  }
  void key(uint32_t code, uint32_t state, bool autoRepeat = false) {
    if (!keyFocus || !keyFocus->window || !keyState)
      return;
    if (!autoRepeat) {
      if (!state && repeating && repeatingKey == code) {
        repeatTimer.stop();
        repeating = false;
      }
      if (state && repeatRate > 0 && xkb_keymap_key_repeats(keymap, code + 8)) {
        repeatingKey = code;
        repeating = true;
        repeatTimer.start(repeatDelay);
      }
    }
    auto sym = xkb_state_key_get_one_sym(keyState, code + 8);
    char text[128] = {};
    xkb_state_key_get_utf8(keyState, code + 8, text, sizeof(text));
    if (composeState && state && !autoRepeat) {
      xkb_compose_state_feed(composeState, sym);
      switch (xkb_compose_state_get_status(composeState)) {
      case XKB_COMPOSE_COMPOSING:
        text[0] = 0;
        break;
      case XKB_COMPOSE_COMPOSED:
        sym = xkb_compose_state_get_one_sym(composeState);
        xkb_compose_state_get_utf8(composeState, text, sizeof(text));
        xkb_compose_state_reset(composeState);
        break;
      case XKB_COMPOSE_CANCELLED:
        xkb_compose_state_reset(composeState);
        text[0] = 0;
        break;
      default:
        break;
      }
    }
    int qtKey = Qt::Key_unknown;
    switch (sym) {
    case XKB_KEY_Return:
    case XKB_KEY_KP_Enter:
      qtKey = Qt::Key_Return;
      break;
    case XKB_KEY_BackSpace:
      qtKey = Qt::Key_Backspace;
      break;
    case XKB_KEY_Delete:
      qtKey = Qt::Key_Delete;
      break;
    case XKB_KEY_Tab:
      qtKey = Qt::Key_Tab;
      break;
    case XKB_KEY_Escape:
      qtKey = Qt::Key_Escape;
      break;
    case XKB_KEY_Left:
      qtKey = Qt::Key_Left;
      break;
    case XKB_KEY_Right:
      qtKey = Qt::Key_Right;
      break;
    case XKB_KEY_Home:
      qtKey = Qt::Key_Home;
      break;
    case XKB_KEY_End:
      qtKey = Qt::Key_End;
      break;
    default: {
      const auto unicode = xkb_keysym_to_utf32(sym);
      if (unicode && unicode < 0x10000)
        qtKey = QChar(unicode).toUpper().unicode();
    }
    }
    QKeyEvent e(state ? QEvent::KeyPress : QEvent::KeyRelease, qtKey,
                modifiers(), code, sym, 0, QString::fromUtf8(text), autoRepeat);
    QCoreApplication::sendEvent(keyFocus->window.get(), &e);
    keyFocus->dirty = true;
  }
  void mouse(QEvent::Type type, Qt::MouseButton button = Qt::NoButton) {
    if (!pointerFocus || !pointerFocus->window)
      return;
    QMouseEvent e(type, pointerPosition, pointerPosition, button, buttons,
                  modifiers());
    QCoreApplication::sendEvent(pointerFocus->window.get(), &e);
    pointerFocus->dirty = true;
  }
  void configure(Output *o, uint32_t serial, uint32_t width, uint32_t height) {
    if (o->fullSurface)
      ext_session_lock_surface_v1_ack_configure(o->fullSurface, serial);
    else
      hyprland_lock_scope_surface_v1_ack_configure(o->lockSurface, serial);
    o->width = width;
    o->height = height;
    o->configured = true;
    if (!o->control) {
      o->control = std::make_unique<QQuickRenderControl>();
      o->window = std::make_unique<QQuickWindow>(o->control.get());
      engine.rootContext()->setContextProperty("lockController", this);
      QQmlComponent component(&engine, QUrl("qrc:/cornice/lock/HumanLock.qml"));
      o->item.reset(qobject_cast<QQuickItem *>(component.create()));
      if (!o->item) {
        for (const auto &error : component.errors())
          fprintf(stderr, "%s\n", error.toString().toUtf8().constData());
        QCoreApplication::exit(2);
        return;
      }
      o->item->setParentItem(o->window->contentItem());
      connect(o->control.get(), &QQuickRenderControl::renderRequested, this,
              [o] { o->dirty = true; });
      connect(o->control.get(), &QQuickRenderControl::sceneChanged, this,
              [o] { o->dirty = true; });
      // Software render control paints into a private QImage, not an xdg/layer
      // window. RenderControl owns an invisible window, never an xdg/layer
      // surface. The software backend needs no RHI initialization.
    }
    o->window->setGeometry(0, 0, width, height);
    o->item->setSize(QSizeF(width, height));
    o->image = QImage(width * o->scale, height * o->scale,
                      QImage::Format_ARGB32_Premultiplied);
    o->image.setDevicePixelRatio(o->scale);
    wl_surface_set_buffer_scale(o->surface, o->scale);
    o->image.fill(QColor("#131820"));
    o->window->setColor(QColor("#131820"));
    auto target = QQuickRenderTarget::fromPaintDevice(&o->image);
    target.setDevicePixelRatio(o->scale);
    o->window->setRenderTarget(target);
    QMetaObject::invokeMethod(o->item.get(), "focusPassword");
    o->dirty = true;
  }
  void paint(Output *o) {
    if (!o->configured || !o->dirty || !o->item)
      return;
    o->dirty = false;
    o->control->polishItems();
    o->control->sync();
    o->control->render();
    const auto length = o->image.sizeInBytes();
    const int fd = memfd_create("cornice-human-lock", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, length) != 0) {
      if (fd >= 0)
        close(fd);
      QCoreApplication::exit(2);
      return;
    }
    void *data =
        mmap(nullptr, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
      close(fd);
      QCoreApplication::exit(2);
      return;
    }
    memcpy(data, o->image.constBits(), length);
    munmap(data, length);
    auto pool = wl_shm_create_pool(shm, fd, length);
    auto buffer = wl_shm_pool_create_buffer(
        pool, 0, o->image.width(), o->image.height(), o->image.bytesPerLine(),
        WL_SHM_FORMAT_ARGB8888);
    static const wl_buffer_listener listener{
        [](void *, wl_buffer *b) { wl_buffer_destroy(b); }};
    wl_buffer_add_listener(buffer, &listener, nullptr);
    wl_shm_pool_destroy(pool);
    close(fd);
    wl_surface_attach(o->surface, buffer, 0, 0);
    wl_surface_damage(o->surface, 0, 0, o->width, o->height);
    wl_surface_commit(o->surface);
  }
  void createSurface(Output *o) {
    if (!ownsLock() || !o->roleKnown || (!fullScope && o->privateOutput) ||
        o->surface)
      return;
    o->surface = wl_compositor_create_surface(compositor);
    if (fullScope) {
      o->fullSurface =
          ext_session_lock_v1_get_lock_surface(fullLock, o->surface, o->output);
      static const ext_session_lock_surface_v1_listener listener{
          [](void *data, auto *, uint32_t serial, uint32_t w, uint32_t h) {
            auto *output = static_cast<Output *>(data);
            output->owner->configure(output, serial, w, h);
          }};
      ext_session_lock_surface_v1_add_listener(o->fullSurface, &listener, o);
      return;
    }
    o->lockSurface =
        hyprland_lock_scope_v1_get_lock_surface(lock, o->surface, o->output);
    static const hyprland_lock_scope_surface_v1_listener listener{
        [](void *data, auto *, uint32_t serial, uint32_t w, uint32_t h) {
          auto o = static_cast<Output *>(data);
          o->owner->configure(o, serial, w, h);
        }};
    hyprland_lock_scope_surface_v1_add_listener(o->lockSurface, &listener, o);
  }
  bool start() {
    display = wl_display_connect(nullptr);
    if (!display)
      return false;
    auto registry = wl_display_get_registry(display);
    static const wl_registry_listener listener{
        [](void *data, wl_registry *registry, uint32_t id, const char *iface,
           uint32_t version) {
          auto self = static_cast<HumanLock *>(data);
          if (!strcmp(iface, "wl_compositor"))
            self->compositor = static_cast<wl_compositor *>(wl_registry_bind(
                registry, id, &wl_compositor_interface, std::min(version, 4u)));
          else if (!strcmp(iface, "wl_shm"))
            self->shm = static_cast<wl_shm *>(
                wl_registry_bind(registry, id, &wl_shm_interface, 1));
          else if (!strcmp(iface, "wl_output")) {
            auto o = std::make_unique<Output>();
            o->owner = self;
            o->id = id;
            o->output = static_cast<wl_output *>(wl_registry_bind(
                registry, id, &wl_output_interface, std::min(version, 4u)));
            static const wl_output_listener outputListener{
                [](void *, wl_output *, int32_t, int32_t, int32_t, int32_t,
                   int32_t, const char *, const char *, int32_t) {},
                [](void *, wl_output *, uint32_t, int32_t, int32_t, int32_t) {},
                [](void *, wl_output *) {},
                [](void *data, wl_output *, int32_t scale) {
                  auto *o = static_cast<Output *>(data);
                  o->scale = std::max(1, scale);
                  if (o->configured) {
                    o->image = QImage(o->width * o->scale, o->height * o->scale,
                                      QImage::Format_ARGB32_Premultiplied);
                    o->image.setDevicePixelRatio(o->scale);
                    wl_surface_set_buffer_scale(o->surface, o->scale);
                    auto target =
                        QQuickRenderTarget::fromPaintDevice(&o->image);
                    target.setDevicePixelRatio(o->scale);
                    o->window->setRenderTarget(target);
                    o->dirty = true;
                  }
                },
                [](void *, wl_output *, const char *) {},
                [](void *, wl_output *, const char *) {}};
            wl_output_add_listener(o->output, &outputListener, o.get());
            self->outputs[id] = std::move(o);
            if (self->manager && self->ownsLock())
              hyprland_lock_scope_manager_v1_get_output_role(
                  self->manager, self->outputs[id]->output);
          } else if (!strcmp(iface, "hyprland_lock_scope_manager_v1")) {
            self->manager =
                static_cast<hyprland_lock_scope_manager_v1 *>(wl_registry_bind(
                    registry, id, &hyprland_lock_scope_manager_v1_interface, 1));
            static const hyprland_lock_scope_manager_v1_listener listener{
                [](void *data, auto *, wl_output *output,
                   uint32_t privateOutput) {
                  auto self = static_cast<HumanLock *>(data);
                  for (const auto &[id, o] : self->outputs)
                    if (o->output == output) {
                      o->roleKnown = true;
                      o->privateOutput = privateOutput;
                      self->createSurface(o.get());
                    }
                }};
            hyprland_lock_scope_manager_v1_add_listener(self->manager, &listener,
                                                       self);
          } else if (!strcmp(iface, "ext_session_lock_manager_v1")) {
            self->fullManager =
                static_cast<ext_session_lock_manager_v1 *>(wl_registry_bind(
                    registry, id, &ext_session_lock_manager_v1_interface, 1));
          } else if (!strcmp(iface, "wl_seat") && !self->seat) {
            self->seat = static_cast<wl_seat *>(wl_registry_bind(
                registry, id, &wl_seat_interface, std::min(version, 5u)));
            static const wl_seat_listener listener{
                [](void *data, wl_seat *seat, uint32_t caps) {
                  auto self = static_cast<HumanLock *>(data);
                  if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !self->keyboard) {
                    self->keyboard = wl_seat_get_keyboard(seat);
                    static const wl_keyboard_listener listener{
                        [](void *data, auto *, uint32_t format, int fd,
                           uint32_t size) {
                          auto self = static_cast<HumanLock *>(data);
                          void *dataMap = mmap(nullptr, size, PROT_READ,
                                               MAP_PRIVATE, fd, 0);
                          if (dataMap != MAP_FAILED &&
                              format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
                            if (self->keyState)
                              xkb_state_unref(self->keyState);
                            if (self->keymap)
                              xkb_keymap_unref(self->keymap);
                            self->keymap = xkb_keymap_new_from_string(
                                self->xkb, static_cast<char *>(dataMap),
                                XKB_KEYMAP_FORMAT_TEXT_V1,
                                XKB_KEYMAP_COMPILE_NO_FLAGS);
                            self->keyState = self->keymap
                                                 ? xkb_state_new(self->keymap)
                                                 : nullptr;
                          }
                          if (dataMap != MAP_FAILED)
                            munmap(dataMap, size);
                          close(fd);
                        },
                        [](void *data, auto *, uint32_t, wl_surface *surface,
                           wl_array *) {
                          auto self = static_cast<HumanLock *>(data);
                          self->keyFocus = self->forSurface(surface);
                          if (self->keyFocus && self->keyFocus->window) {
                            QFocusEvent e(QEvent::FocusIn);
                            QCoreApplication::sendEvent(
                                self->keyFocus->window.get(), &e);
                          }
                        },
                        [](void *data, auto *, uint32_t, wl_surface *) {
                          auto *self = static_cast<HumanLock *>(data);
                          self->keyFocus = nullptr;
                          self->repeatTimer.stop();
                          self->repeating = false;
                          if (self->composeState)
                            xkb_compose_state_reset(self->composeState);
                        },
                        [](void *data, auto *, uint32_t, uint32_t, uint32_t key,
                           uint32_t state) {
                          static_cast<HumanLock *>(data)->key(key, state);
                        },
                        [](void *data, auto *, uint32_t, uint32_t dep,
                           uint32_t lat, uint32_t locked, uint32_t group) {
                          auto self = static_cast<HumanLock *>(data);
                          if (self->keyState)
                            xkb_state_update_mask(self->keyState, dep, lat,
                                                  locked, 0, 0, group);
                        },
                        [](void *data, auto *, int32_t rate, int32_t delay) {
                          auto *self = static_cast<HumanLock *>(data);
                          self->repeatRate = std::max(0, rate);
                          self->repeatDelay = std::max(0, delay);
                          if (!rate)
                            self->repeatTimer.stop();
                        }};
                    wl_keyboard_add_listener(self->keyboard, &listener, self);
                  }
                  if ((caps & WL_SEAT_CAPABILITY_POINTER) && !self->pointer) {
                    self->pointer = wl_seat_get_pointer(seat);
                    static const wl_pointer_listener listener{
                        [](void *data, auto *, uint32_t, wl_surface *surface,
                           wl_fixed_t x, wl_fixed_t y) {
                          auto self = static_cast<HumanLock *>(data);
                          self->pointerFocus = self->forSurface(surface);
                          self->pointerPosition = {wl_fixed_to_double(x),
                                                   wl_fixed_to_double(y)};
                        },
                        [](void *data, auto *, uint32_t, wl_surface *) {
                          static_cast<HumanLock *>(data)->pointerFocus =
                              nullptr;
                        },
                        [](void *data, auto *, uint32_t, wl_fixed_t x,
                           wl_fixed_t y) {
                          auto self = static_cast<HumanLock *>(data);
                          self->pointerPosition = {wl_fixed_to_double(x),
                                                   wl_fixed_to_double(y)};
                          self->mouse(QEvent::MouseMove);
                        },
                        [](void *data, auto *, uint32_t, uint32_t,
                           uint32_t code, uint32_t state) {
                          auto self = static_cast<HumanLock *>(data);
                          auto button = code == 0x110   ? Qt::LeftButton
                                        : code == 0x111 ? Qt::RightButton
                                                        : Qt::MiddleButton;
                          if (state)
                            self->buttons |= button;
                          else
                            self->buttons &= ~button;
                          self->mouse(state ? QEvent::MouseButtonPress
                                            : QEvent::MouseButtonRelease,
                                      button);
                        },
                        [](void *, auto *, uint32_t, uint32_t, wl_fixed_t) {},
                        [](void *, auto *) {},
                        [](void *, auto *, uint32_t) {},
                        [](void *, auto *, uint32_t, uint32_t) {},
                        [](void *, auto *, uint32_t, int32_t) {},
                    };
                    wl_pointer_add_listener(self->pointer, &listener, self);
                  }
                },
                [](void *, auto *, const char *) {}};
            wl_seat_add_listener(self->seat, &listener, self);
          }
        },
        [](void *data, auto *, uint32_t id) {
          auto self = static_cast<HumanLock *>(data);
          auto it = self->outputs.find(id);
          if (it == self->outputs.end())
            return;
          if (self->keyFocus == it->second.get())
            self->keyFocus = nullptr;
          if (self->pointerFocus == it->second.get())
            self->pointerFocus = nullptr;
          if (it->second->fullSurface)
            ext_session_lock_surface_v1_destroy(it->second->fullSurface);
          if (it->second->lockSurface)
            hyprland_lock_scope_surface_v1_destroy(it->second->lockSurface);
          if (it->second->surface)
            wl_surface_destroy(it->second->surface);
          wl_output_destroy(it->second->output);
          self->outputs.erase(it);
        }};
    wl_registry_add_listener(registry, &listener, this);
    if (wl_display_roundtrip(display) < 0 || !manager ||
        (fullScope && !fullManager) || !compositor || !shm)
      return false;
    for (const auto &[id, o] : outputs)
      hyprland_lock_scope_manager_v1_get_output_role(manager, o->output);
    if (wl_display_roundtrip(display) < 0)
      return false;
    if (fullScope) {
      fullLock = ext_session_lock_manager_v1_lock(fullManager);
      static const ext_session_lock_v1_listener listener{
          [](void *data, auto *) {
            auto *self = static_cast<HumanLock *>(data);
            self->secure = true;
            self->event("secure");
          },
          [](void *data, auto *) {
            auto *self = static_cast<HumanLock *>(data);
            self->event("finished");
            QCoreApplication::quit();
          }};
      ext_session_lock_v1_add_listener(fullLock, &listener, this);
    } else {
      lock = hyprland_lock_scope_manager_v1_create_lock(manager);
      static const hyprland_lock_scope_v1_listener lockListener{
          [](void *data, auto *) {
            auto self = static_cast<HumanLock *>(data);
            self->secure = true;
            self->event("secure");
          },
          [](void *data, auto *) {
            auto self = static_cast<HumanLock *>(data);
            self->event("finished");
            QCoreApplication::quit();
          }};
      hyprland_lock_scope_v1_add_listener(lock, &lockListener, this);
    }
    if (!fullScope) {
      QLocalSocket socket;
      socket.connectToServer(qEnvironmentVariable("XDG_RUNTIME_DIR") + "/hypr/" +
                             qEnvironmentVariable("HYPRLAND_INSTANCE_SIGNATURE") + "/.socket.sock");
      if (!socket.waitForConnected(1000)) return false;
      socket.write("j/seat list");
      if (!socket.waitForBytesWritten(1000)) return false;
      QByteArray answer;
      while (socket.state() == QLocalSocket::ConnectedState) {
        if (!socket.bytesAvailable() && !socket.waitForReadyRead(1000) && socket.state() == QLocalSocket::ConnectedState) return false;
        answer += socket.readAll();
      }
      answer += socket.readAll();
      const auto document = QJsonDocument::fromJson(answer);
      if (!document.isArray()) return false;
      for (const auto &value : document.array()) {
        const auto seat = value.toObject();
        if (seat["primary"].toBool() || seat["scopePolicy"].toString() != "allow") continue;
        hyprland_lock_scope_v1_allow_seat(lock, seat["name"].toString().toUtf8().constData(),
          seat["seatId"].toString().toUtf8().constData(), seat["generation"].toString().toUtf8().constData());
      }
      for (const auto &[id, o] : outputs)
        if (o->privateOutput) hyprland_lock_scope_v1_exclude_output(lock, o->output);
      hyprland_lock_scope_v1_activate(lock);
    }
    for (const auto &[id, o] : outputs)
      createSurface(o.get());
    auto notifier = new QSocketNotifier(wl_display_get_fd(display),
                                        QSocketNotifier::Read, this);
    connect(notifier, &QSocketNotifier::activated, this, [this] {
      if (wl_display_dispatch(display) < 0)
        QCoreApplication::exit(2);
    });
    connect(&renderTimer, &QTimer::timeout, this, [this] {
      wl_display_dispatch_pending(display);
      for (const auto &[id, o] : outputs)
        paint(o.get());
      wl_display_flush(display);
    });
    renderTimer.start(33);
    auto commands =
        new QSocketNotifier(STDIN_FILENO, QSocketNotifier::Read, this);
    connect(commands, &QSocketNotifier::activated, this, [this, commands] {
      char bytes[1024];
      const auto n = read(STDIN_FILENO, bytes, sizeof(bytes));
      if (n <= 0) {
        commands->setEnabled(false);
        return;
      }
      input.append(bytes, n);
      if (input.size() > 4096) {
        QCoreApplication::exit(2);
        return;
      }
      while (input.contains('\n')) {
        const auto line = input.left(input.indexOf('\n'));
        input.remove(0, line.size() + 1);
        if (line == "emergency-unlock" && emergencyAllowed)
          unlock();
        else if (line.startsWith("appearance ")) {
          const auto value = QJsonDocument::fromJson(line.mid(11));
          if (value.isObject())
            setAppearance(value.object());
        }
      }
    });
    wl_display_flush(display);
    event("preparing");
    return true;
  }
};
struct PamSecret {
  QByteArray password;
  bool answered = false;
};
static int conversation(int count, const pam_message **messages,
                        pam_response **responses, void *data) {
  auto *secret = static_cast<PamSecret *>(data);
  auto *result =
      static_cast<pam_response *>(calloc(count, sizeof(pam_response)));
  if (!result)
    return PAM_BUF_ERR;
  for (int i = 0; i < count; ++i) {
    if (messages[i]->msg_style == PAM_PROMPT_ECHO_OFF ||
        messages[i]->msg_style == PAM_PROMPT_ECHO_ON) {
      result[i].resp =
          strdup(secret->answered ? "" : secret->password.constData());
      secret->answered = true;
    } else if (messages[i]->msg_style != PAM_TEXT_INFO &&
               messages[i]->msg_style != PAM_ERROR_MSG) {
      for (int j = 0; j < i; ++j)
        free(result[j].resp);
      free(result);
      return PAM_CONV_ERR;
    }
  }
  *responses = result;
  return PAM_SUCCESS;
}
int main(int argc, char **argv) {
  if (argc == 4 && !strcmp(argv[1], "--pam-worker")) {
    QFile stream;
    if (!stream.open(STDIN_FILENO, QIODevice::ReadOnly))
      return 2;
    auto request = stream.readAll();
    if (request.size() > 65536)
      return 2;
    PamSecret secret{QJsonDocument::fromJson(request)
                         .object()["password"]
                         .toString()
                         .toUtf8()};
    request.fill(0);
    const auto *account = getpwuid(getuid());
    if (!account)
      return 2;
    pam_conv conv{conversation, &secret};
    pam_handle_t *handle = nullptr;
    int result =
        pam_start_confdir(argv[2], account->pw_name, &conv, argv[3], &handle);
    const char *phase = "start";
    if (result == PAM_SUCCESS) {
      phase = "authenticate";
      result = pam_authenticate(handle, 0);
    }
    // Unlock an existing session using the same auth-only contract as
    // Quickshell. Lock services such as hyprlock need not define an account
    // stack; calling pam_acct_mgmt then falls back to other and denies access.
    if (result != PAM_SUCCESS)
      fprintf(stderr, "PAM %s failed for service %s: %s (%d)\n", phase, argv[2],
              pam_strerror(handle, result), result);
    secret.password.fill(0);
    if (handle)
      pam_end(handle, result);
    return result == PAM_SUCCESS ? 0 : 1;
  }
  qputenv("QT_QPA_PLATFORM", "offscreen");
  QQuickWindow::setSceneGraphBackend("software");
  QGuiApplication application(argc, argv);
  QCommandLineParser parser;
  parser.addHelpOption();
  parser.addOption({"pam-service", "PAM service", "service", "hyprlock"});
  parser.addOption(
      {"pam-directory", "PAM config directory", "directory", "/etc/pam.d"});
  parser.addOption(
      {"appearance", "Cornice theme and background JSON", "json", "{}"});
  parser.addOption({"hide-user", "Hide the account name on the lock screen"});
  parser.addOption({"scope", "Lock scope: human or session", "scope", "human"});
  parser.addOption(
      {"allow-emergency", "Allow the explicit owner recovery command"});
  parser.process(application);
  HumanLock lock;
  lock.setAppearance(
      QJsonDocument::fromJson(parser.value("appearance").toUtf8()).object());
  lock.pamService = parser.value("pam-service");
  lock.pamDirectory = parser.value("pam-directory");
  lock.user = getpwuid(getuid())
                  ? QString::fromUtf8(getpwuid(getuid())->pw_name)
                  : QString{};
  lock.emergencyAllowed = parser.isSet("allow-emergency");
  if (!QFileInfo(lock.pamDirectory + "/" + lock.pamService).isReadable()) {
    fprintf(stderr, "PAM configuration unavailable\n");
    return 2;
  }
  if (parser.value("scope") != "human" && parser.value("scope") != "session")
    return 2;
  lock.fullScope = parser.value("scope") == "session";
  lock.showUser = !parser.isSet("hide-user");
  if (!lock.start()) {
    fprintf(stderr, "Human lock provider unavailable\n");
    return 2;
  }
  return application.exec();
}
#include "main.moc"
