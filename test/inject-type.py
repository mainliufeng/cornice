#!/usr/bin/env python3
"""Type real keystrokes through /dev/uinput.

Why this exists next to test/inject-click.py: `wtype` sends keys over the Wayland
virtual-keyboard protocol, which apps treat as already-composed text — so the
input method never runs and its candidate window never appears. Injecting at the
kernel level produces genuine key events, which is what an IME listens to.

    test/inject-type.py "nihao"          # types the letters
    test/inject-type.py --key Return
"""
import argparse
import fcntl
import os
import struct
import sys
import time

UINPUT_PATH = "/dev/uinput"

EV_SYN, EV_KEY = 0x00, 0x01
SYN_REPORT = 0
BUS_USB, UINPUT_MAX_NAME_SIZE = 0x03, 80

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

# Linux input event codes (linux/input-event-codes.h)
KEYS = {
    "a": 30, "b": 48, "c": 46, "d": 32, "e": 18, "f": 33, "g": 34, "h": 35,
    "i": 23, "j": 36, "k": 37, "l": 38, "m": 50, "n": 49, "o": 24, "p": 25,
    "q": 16, "r": 19, "s": 31, "t": 20, "u": 22, "v": 47, "w": 17, "x": 45,
    "y": 21, "z": 44,
    "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10,
    "0": 11,
    " ": 57, "-": 12, "=": 13, "[": 26, "]": 27, "\\": 43, ";": 39, "'": 40,
    "`": 41, ",": 51, ".": 52, "/": 53,
}
NAMED = {
    "Return": 28, "Enter": 28, "Escape": 1, "Backspace": 14, "Tab": 15,
    "space": 57, "Up": 103, "Down": 108, "Left": 105, "Right": 106,
}
SHIFT = 42
KT_LEFTSHIFT = 0
KT_RIGHTCTRL = 1
KT_LEFTCTRL = 1


def write_event(fd, type_, code, value):
    fd.write(struct.pack("llHHi", 0, 0, type_, code, value))


def create_keyboard():
    fd = open(UINPUT_PATH, "wb", buffering=0)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for code in set(KEYS.values()) | set(NAMED.values()) | {SHIFT, 29}:  # 29 = LEFTCTRL
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    name = b"cornice-inject-type"
    # The kernel wants the whole 1116-byte uinput_user_dev struct, zero padded.
    header = struct.pack("80sHHHHi", name, BUS_USB, 0x1, 0x1, 1, 0)
    fd.write(header + b"\0" * (1116 - len(header)))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(0.2)
    return fd


def tap(fd, code, shift=False, delay=0.04):
    if shift:
        write_event(fd, EV_KEY, SHIFT, 1)
        write_event(fd, EV_SYN, SYN_REPORT, 0)
    write_event(fd, EV_KEY, code, 1)
    write_event(fd, EV_SYN, SYN_REPORT, 0)
    time.sleep(delay)
    write_event(fd, EV_KEY, code, 0)
    write_event(fd, EV_SYN, SYN_REPORT, 0)
    time.sleep(delay)
    if shift:
        write_event(fd, EV_KEY, SHIFT, 0)
        write_event(fd, EV_SYN, SYN_REPORT, 0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("text", nargs="?", default="")
    parser.add_argument("--key", action="append", default=[],
                        help="named key, e.g. --key Return (repeatable)")
    parser.add_argument("--hold", type=float, default=0.04, help="delay between keys")
    args = parser.parse_args()

    try:
        fd = create_keyboard()
    except PermissionError:
        print("inject-type: cannot write /dev/uinput (permissions)", file=sys.stderr)
        return 2

    try:
        for chunk in args.key:
            for name in chunk.split(","):
                name = name.strip()
                if name not in NAMED:
                    print(f"inject-type: unknown key '{name}'", file=sys.stderr)
                    return 2
                tap(fd, NAMED[name], delay=args.hold)
        for char in args.text:
            lower = char.lower()
            if lower not in KEYS:
                print(f"inject-type: no mapping for '{char}'", file=sys.stderr)
                return 2
            tap(fd, KEYS[lower], shift=char.isupper(), delay=args.hold)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        fd.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
