#!/usr/bin/env python3
"""Send a notification with inline reply and wait for the answer.

Cornice's notification centre is the only surface that offers inline reply (the
popup is deliberately not keyboard-focusable), so this client is what proves the
whole path end to end:

    python3 test/fake-notify-reply.py --text "ping" &
    cornice notifications          # open the centre
    # click "Reply", type, press Enter
    # → this process prints the reply and exits 0

Exits non-zero on timeout, so a test suite can assert on it.
"""
from __future__ import annotations

import argparse
import sys

try:
    from gi.repository import GLib, Gio  # type: ignore
except ImportError:  # pragma: no cover
    print("fake-notify-reply: python-gobject (gi) is required", file=sys.stderr)
    raise SystemExit(2)

NOTIFICATIONS = "org.freedesktop.Notifications"
PATH_ = "/org/freedesktop/Notifications"
IFACE = "org.freedesktop.Notifications"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", default="Reply test")
    parser.add_argument("--body", default="Type a reply in the notification centre and press Enter.")
    parser.add_argument("--placeholder", default="Reply to cornice…")
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--repeat", type=float, default=0.0,
                        help="re-send every N seconds (keeps a live notification around)")
    parser.add_argument("--bare", action="store_true",
                        help="send no actions at all (how Paseo and friends behave)")
    parser.add_argument("--default-action", action="store_true",
                        help="add a freedesktop 'default' action")
    parser.add_argument("--app-name", default="cornice reply test")
    parser.add_argument("--desktop-entry", default="")
    parser.add_argument("--sender-pid", type=int, default=None)
    parser.add_argument("--expire", type=int, default=0,
                        help="expire timeout in ms (0 = cornice's default)")
    parser.add_argument("--log", default="/tmp/fake-notify-reply.log")
    args = parser.parse_args()

    log = open(args.log, "a", encoding="utf-8")

    def record(what: str) -> None:
        log.write(what + "\n")
        log.flush()

    loop = GLib.MainLoop()
    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    result = {"code": 1}
    state: dict = {}

    def on_signal(_conn, _sender, _path, _iface, signal, params) -> None:
        if signal == "NotificationReplied":
            reply_id, text = params.unpack()
            record(f"replied id={reply_id} text={text}")
            print(text)
            result["code"] = 0
            loop.quit()
        elif signal == "ActionInvoked":
            action_id, _key = params.unpack()
            record(f"action id={action_id} key={_key}")
        elif signal == "NotificationClosed":
            closed_id, reason = params.unpack()
            record(f"closed id={closed_id} reason={reason}")

    connection.signal_subscribe(
        None, IFACE, None, PATH_, None,
        Gio.DBusSignalFlags.NONE, on_signal,
    )

    def notify() -> bool:
        actions = []
        if not args.bare:
            if args.default_action:
                actions += ["default", "Open"]
            actions += ["inline-reply", "Reply"]
        hints = {"x-kde-reply-placeholder-text": GLib.Variant("s", args.placeholder)}
        if args.desktop_entry:
            hints["desktop-entry"] = GLib.Variant("s", args.desktop_entry)
        if args.sender_pid is not None:
            hints["sender-pid"] = GLib.Variant("i", args.sender_pid)
        try:
            reply = connection.call_sync(
                NOTIFICATIONS, PATH_, IFACE, "Notify",
                GLib.Variant(
                    "(susssasa{sv}i)",
                    (
                        args.app_name,                 # app name
                        state.get("id", 0),            # replace the previous one
                        "dialog-question",             # icon
                        args.summary,
                        args.body,
                        actions,
                        hints,
                        args.expire,                   # 0 = cornice's own default
                    ),
                ),
                GLib.VariantType("(u)"),
                Gio.DBusCallFlags.NONE, 5000, None,
            )
        except GLib.Error as error:
            print(f"fake-notify-reply: Notify failed: {error.message}", file=sys.stderr)
            result["code"] = 3
            loop.quit()
            return False
        (notification_id,) = reply.unpack()
        state["id"] = notification_id
        record(f"sent id={notification_id}")
        print(f"sent notification {notification_id}", flush=True)
        if args.repeat > 0:
            # Re-sending keeps a *live* notification available: the shell drops
            # the tracked object when the popup expires, and inline reply needs
            # that object (history alone cannot answer).
            GLib.timeout_add(int(args.repeat * 1000), notify)
        return False

    GLib.timeout_add(200, notify)

    def on_timeout() -> bool:
        record("timeout")
        print("fake-notify-reply: timed out waiting for a reply", file=sys.stderr)
        loop.quit()
        return False

    GLib.timeout_add(int(args.timeout * 1000), on_timeout)
    loop.run()
    return result["code"]


if __name__ == "__main__":
    raise SystemExit(main())
