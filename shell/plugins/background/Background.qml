import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

// Wallpaper layer.
//
// One background-layer surface per screen, drawing a static image. Config:
//
//   "background": {
//     "enabled": true,
//     "path": "~/Pictures/wallpaper.png",     // single image
//     "dir": "~/Pictures/wallpapers",         // or a directory to cycle through
//     "mode": "fill",                         // fill | fit | stretch | center
//     "perWorkspace": { "1": "~/one.png" },   // per workspace id overrides
//     "force": false                          // draw even when mpvpaper runs
//   }
//
// A running video wallpaper (mpvpaper) owns the background too, so by default
// this layer steps aside for it instead of fighting over the same pixels.
Item {
  id: root

  property var host: null
  property var plugin: null

  readonly property var settings: (host && host.config && host.config.background)
    ? host.config.background : ({})

  readonly property bool wanted: Util.option(settings, "enabled", false)
  readonly property bool force: Util.option(settings, "force", false)
  readonly property string mode: Util.option(settings, "mode", "fill")

  // Another wallpaper tool owns the background too. Video wallpapers are the
  // obvious case (mpvpaper), but hyprpaper/swaybg/swww/wbg count as well — the
  // layer steps aside for all of them unless `force` is set.
  readonly property var otherWallpaperTools: ["mpvpaper", "hyprpaper", "swaybg", "swww-daemon", "wbg"]
  property string otherWallpaperTool: ""
  readonly property bool videoWallpaper: otherWallpaperTool === "mpvpaper"
  readonly property bool active: wanted && (otherWallpaperTool === "" || force)

  // Files available when `dir` is used, and the chosen index.
  property var images: []
  property int index: 0

  // Explicit override set over IPC (takes precedence until it is cleared).
  property string override_:""

  function expand(path) {
    const value = String(path || "")
    if (value.startsWith("~")) return (Quickshell.env("HOME") || "") + value.slice(1)
    return value
  }

  // A shipped default so a fresh install is not a flat colour.
  readonly property string shippedDefault: (Quickshell.env("CORNICE_PATH") || "/usr/share/cornice")
    + "/wallpapers/default.png"

  readonly property string singlePath: expand(Util.option(settings, "path", ""))
  readonly property string directory: expand(Util.option(settings, "dir", ""))

  function workspacePath(workspaceId) {
    const map = Util.option(settings, "perWorkspace", ({}))
    const entry = map[String(workspaceId)]
    return entry === undefined ? "" : expand(entry)
  }

  // Resolution order: IPC override → per-workspace → directory pick → single path.
  function pathFor(workspaceId) {
    if (override_ !== "") return override_
    const perWorkspace = workspacePath(workspaceId)
    if (perWorkspace !== "") return perWorkspace
    if (images.length > 0) return images[index % images.length]
    if (singlePath !== "") return singlePath
    return shippedDefault
  }

  readonly property var monitors: Hyprland.monitors ? Hyprland.monitors.values : []

  function workspaceFor(screenName) {
    for (const monitor of monitors) {
      if (String(monitor.name) !== String(screenName)) continue
      return monitor.activeWorkspace ? monitor.activeWorkspace.id : 0
    }
    return Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0
  }

  // ---- video wallpaper detection -------------------------------------------
  Process {
    id: wallpaperProbe

    command: ["sh", "-c",
      "for tool in " + otherWallpaperTools.join(" ") + "; do " +
      "pgrep -x \"$tool\" >/dev/null 2>&1 && { echo \"$tool\"; exit 0; }; done; echo \"\""]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const tool = String(text).trim()
        if (tool !== root.otherWallpaperTool) {
          root.otherWallpaperTool = tool
          console.log("cornice: wallpaper tool " + (tool === "" ? "gone — background layer active" : "\"" + tool + "\" detected — background layer idle"))
        }
      }
    }
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    onTriggered: wallpaperProbe.running = true
  }

  // ---- directory listing ---------------------------------------------------
  // Scans must not overlap: a second scan resetting `images` while the first was
  // still streaming produced counts that matched no directory.
  property bool scanPending: false

  function rescan() {
    if (directory === "") {
      images = []
      return
    }
    if (lister.running) {
      scanPending = true
      return
    }
    images = []
    lister.running = true
  }

  Process {
    id: lister

    command: ["sh", "-c",
      "d=" + JSON.stringify(directory) + "; " +
      "[ -d \"$d\" ] || exit 0; " +
      "find \"$d\" -maxdepth 1 -type f \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \\) | sort"]
    running: false
    stdout: SplitParser {
      onRead: line => {
        const path = String(line).trim()
        if (path !== "") root.images = root.images.concat([path])
      }
    }
    onExited: {
      if (root.scanPending) {
        root.scanPending = false
        root.rescan()
      }
    }
  }

  onDirectoryChanged: rescan()
  Component.onCompleted: rescan()

  // ---- the surfaces --------------------------------------------------------
  Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: surface

      required property var modelData

      screen: modelData
      visible: root.active && root.pathFor(root.workspaceFor(modelData.name)) !== ""
      color: Color.background
      exclusiveZone: 0
      aboveWindows: false
      focusable: false

      anchors.top: true
      anchors.bottom: true
      anchors.left: true
      anchors.right: true

      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.namespace: "cornice-background"
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Image {
        anchors.fill: parent
        asynchronous: true
        cache: false
        source: {
          const path = root.pathFor(root.workspaceFor(surface.modelData.name))
          return path === "" ? "" : "file://" + path
        }
        fillMode: root.mode === "fit" || root.mode === "center"
          ? Image.PreserveAspectFit
          : root.mode === "stretch" ? Image.Stretch : Image.PreserveAspectCrop
        smooth: true

        onStatusChanged: {
          if (status === Image.Error) console.warn("cornice: background image failed to load: " + source)
        }
      }
    }
  }

  ShellIpc {
    target: "background"

    function status(): string {
      return JSON.stringify({
        enabled: root.wanted,
        active: root.active,
        videoWallpaper: root.videoWallpaper,
        otherWallpaperTool: root.otherWallpaperTool,
        forced: root.force,
        mode: root.mode,
        directory: root.directory,
        images: root.images.length,
        index: root.index,
        override: root.override_,
        current: root.pathFor(root.workspaceFor(""))
      })
    }

    function set(path: string): string {
      root.override_ = root.expand(path)
      return root.override_
    }

    function clear(): string {
      root.override_ = ""
      return "ok"
    }

    function next(): string {
      if (root.images.length === 0) return "no-images"
      root.index = (root.index + 1) % root.images.length
      root.override_ = root.images[root.index]
      return root.override_
    }

    function previous(): string {
      if (root.images.length === 0) return "no-images"
      root.index = (root.index - 1 + root.images.length) % root.images.length
      root.override_ = root.images[root.index]
      return root.override_
    }

    function reload(): string {
      root.rescan()
      return "ok"
    }
  }
}
