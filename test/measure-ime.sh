#!/usr/bin/env bash
# Measure the fcitx5 candidate window, so its size can be tuned by data rather
# than guesswork.
#
# Real keystrokes go through uinput (an IME never sees wtype's synthetic keys), so
# the candidate window actually appears; its geometry is then read from the
# compositor and the glyph height from a screenshot.
#
#   test/measure-ime.sh --restart-fcitx --focus Chatgpt
#
# Reference heights on this 2x panel: bar text ~26 physical px, normal app text
# 28-32 px — the candidates should land in the same range.
set -uo pipefail
export XDG_RUNTIME_DIR=/run/user/1000
export PATH="$HOME/.local/bin:$PATH"
eval "$(systemctl --user show-environment | grep -E '^(WAYLAND_DISPLAY|HYPRLAND_INSTANCE_SIGNATURE|DBUS_SESSION_BUS_ADDRESS)=' | sed 's/^/export /')"

# Usage: test/measure-ime.sh [--restart-fcitx] [--focus CLASS]
#   measures the fcitx5 candidate window against the bar/app text, so HiDPI
#   sizing can be tuned with numbers instead of guesswork.
restart=0
focus_class=""
while (($#)); do
  case "$1" in
    --restart-fcitx) restart=1; shift ;;
    --focus) focus_class="${2:-}"; shift 2 ;;
    *) echo "measure-ime: unknown option '$1'" >&2; exit 2 ;;
  esac
done

if ((restart)); then
  pkill -x fcitx5; sleep 2
  setsid nohup fcitx5 -d --replace >/dev/null 2>&1 </dev/null &
  sleep 4
  cornice-tray-activate --id Fcitx --label Pinyin >/dev/null 2>&1 || true
  sleep 1
fi

# A window with a text field has to be focused (and the caret placed in it) for
# the input method to run; --focus names it, otherwise the current one is used.
if [[ -n $focus_class ]]; then
  hyprctl dispatch focuswindow "class:$focus_class" >/dev/null 2>&1
  sleep 1
  python3 "$(dirname "$0")/inject-click.py" --at 600 850 >/dev/null 2>&1
  sleep 1
fi

python3 "$(dirname "$0")/inject-type.py" "nihao" || exit 1
sleep 1.5
grim /tmp/ime-measure.png 2>/dev/null

echo "配置: $(grep -vE '^#|^$' "$HOME/.config/fcitx5/conf/classicui.conf" | tr '\n' ' ')"
hyprctl clients -j | jq -r '.[] | select(.class|test("fcitx";"i")) | "候选窗: \(.size|join("x")) at \(.at|join(",")) xwayland=\(.xwayland)"'
python3 - <<'PY'
from PIL import Image
import numpy as np, subprocess, json, os
env = {k: os.environ[k] for k in ("XDG_RUNTIME_DIR", "PATH", "HYPRLAND_INSTANCE_SIGNATURE") if k in os.environ}
clients = json.loads(subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, env=env).stdout)
target = next((c for c in clients if "fcitx" in c["class"]), None)
if not target:
    print("no candidate window found"); raise SystemExit(0)
x, y = target["at"]; w, h = target["size"]
img = Image.open("/tmp/ime-measure.png").convert("L")
crop = img.crop((x * 2, y * 2, (x + w) * 2, (y + h) * 2))
crop.save("/tmp/ime-candidate.png")
a = np.asarray(crop).astype(int)
rows = np.where((a < 120).sum(axis=1) > 0)[0]
glyph_px = (rows.max() - rows.min() + 1) if len(rows) else 0
print(f"候选窗 {w}x{h} 逻辑像素；窗内文字高度约 {glyph_px} 物理像素")
print("参考：状态栏文字约 26 物理像素（原生 2x），普通应用正文约 28–32")
PY
