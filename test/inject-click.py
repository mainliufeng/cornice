#!/usr/bin/env python3
"""Inject a real mouse click through /dev/uinput.

Needed to verify pointer interactions (bar widgets opening panels) without a
human hand: keyboard injection tools like wtype cannot press mouse buttons.

Requires write access to /dev/uinput (a udev rule or an ACL); no root.

    test/inject-click.py --at 1400 19        # absolute, in logical pixels
    test/inject-click.py --at 1400 19 --button right
"""
import argparse
import fcntl
import os
import struct
import sys
import time

UINPUT_PATH = "/dev/uinput"

EV_SYN, EV_KEY, EV_REL = 0x00, 0x01, 0x02
SYN_REPORT = 0
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
REL_X, REL_Y, REL_WHEEL = 0x00, 0x01, 0x08
BUS_USB, UINPUT_MAX_NAME_SIZE = 0x03, 80

# ioctl numbers from <linux/uinput.h>
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_RELBIT = 0x40045566
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502


def write_event(fd, type_, code, value):
    fd.write(struct.pack("llHHi", 0, 0, type_, code, value))


def cursor_position():
    out = os.popen("hyprctl cursorpos 2>/dev/null").read().strip()
    if not out:
        return None
    try:
        x, y = out.replace(",", " ").split()[:2]
        return int(x), int(y)
    except ValueError:
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--at", nargs=2, type=int, required=True, metavar=("X", "Y"))
    parser.add_argument("--button", choices=("left", "right", "middle"), default="left")
    parser.add_argument("--move-only", action="store_true",
                        help="move the pointer there and stop (for hover checks)")
    parser.add_argument("--wheel", type=int, default=0,
                        help="scroll notches: positive up, negative down (no click)")
    parser.add_argument("--settle", type=float, default=0.06)
    parser.add_argument("--iterations", type=int, default=20)
    args = parser.parse_args()

    start = cursor_position()
    if start is None:
        print("could not read the cursor position (is Hyprland running?)", file=sys.stderr)
        return 1

    target = (args.at[0], args.at[1])
    button = {"left": BTN_LEFT, "right": BTN_RIGHT, "middle": BTN_MIDDLE}[args.button]

    try:
        fd = os.open(UINPUT_PATH, os.O_WRONLY | os.O_NONBLOCK)
    except PermissionError:
        print(f"no write access to {UINPUT_PATH}", file=sys.stderr)
        return 2

    with os.fdopen(fd, "wb", buffering=0) as dev:
        fcntl.ioctl(dev, UI_SET_EVBIT, EV_KEY)
        fcntl.ioctl(dev, UI_SET_EVBIT, EV_REL)
        fcntl.ioctl(dev, UI_SET_KEYBIT, button)
        for axis in (REL_X, REL_Y, REL_WHEEL):
            fcntl.ioctl(dev, UI_SET_RELBIT, axis)

        # struct uinput_user_dev is 80 + 8 + 4 + 4*(ABS_CNT*4) bytes; the kernel
        # requires the full structure, so zero-fill the axis tables.
        name = b"cornice-test-mouse"
        header = struct.pack("80sHHHHi", name, BUS_USB, 1, 1, 1, 0)
        dev.write(header + b"\0" * (1116 - len(header)))
        fcntl.ioctl(dev, UI_DEV_CREATE)
        time.sleep(0.3)

        def move(dx, dy):
            # Relative moves, in steps: compositors coalesce single big jumps.
            while dx or dy:
                step_x = max(-60, min(60, dx))
                step_y = max(-60, min(60, dy))
                write_event(dev, EV_REL, REL_X, step_x)
                write_event(dev, EV_REL, REL_Y, step_y)
                write_event(dev, EV_SYN, SYN_REPORT, 0)
                dev.flush()
                dx -= step_x
                dy -= step_y
                time.sleep(0.01)

        # Relative moves are not exact (the compositor coalesces events and may
        # apply acceleration), so steer with feedback until the pointer is
        # actually on target — otherwise the click silently lands elsewhere.
        for _ in range(args.iterations):
            now = cursor_position()
            if now is None:
                break
            dx, dy = target[0] - now[0], target[1] - now[1]
            if abs(dx) <= 2 and abs(dy) <= 2:
                break
            move(dx, dy)
            time.sleep(args.settle)

        landed = cursor_position()
        print(f"cursor now: {landed} (target {target})")
        if landed is None or abs(landed[0] - target[0]) > 3 or abs(landed[1] - target[1]) > 3:
            print("warning: pointer is not on target; click may miss", file=sys.stderr)

        if args.wheel:
            notch = 1 if args.wheel > 0 else -1
            for _ in range(abs(args.wheel)):
                write_event(dev, EV_REL, REL_WHEEL, notch)
                write_event(dev, EV_SYN, SYN_REPORT, 0)
                dev.flush()
                time.sleep(0.05)
            time.sleep(0.2)
            fcntl.ioctl(dev, UI_DEV_DESTROY)
            return 0

        if args.move_only:
            # Hover checks need the pointer on the widget without pressing it
            # (clicking the volume widget would mute, for instance).
            time.sleep(0.3)
            fcntl.ioctl(dev, UI_DEV_DESTROY)
            return 0

        write_event(dev, EV_KEY, button, 1)
        write_event(dev, EV_SYN, SYN_REPORT, 0)
        dev.flush()
        time.sleep(0.05)
        write_event(dev, EV_KEY, button, 0)
        write_event(dev, EV_SYN, SYN_REPORT, 0)
        dev.flush()
        time.sleep(args.settle)

        fcntl.ioctl(dev, UI_DEV_DESTROY)

    print(f"clicked {args.button} at {target} (from {start})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
