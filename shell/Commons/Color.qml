pragma Singleton
import QtQuick
import qs.Commons

// Surface roles derived from theme tokens. Widgets read these, never raw hex.
QtObject {
  id: root

  readonly property color foreground: Theme.colors.foreground
  readonly property color background: Theme.colors.background
  readonly property color accent: Theme.colors.accent
  readonly property color urgent: Theme.colors.urgent
  readonly property color muted: Theme.colors.muted

  readonly property color barBackground: Theme.colors.barBackground !== undefined
    ? Theme.colors.barBackground
    : background

  readonly property color barForeground: Theme.colors.barForeground !== undefined
    ? Theme.colors.barForeground
    : foreground

  readonly property color surface: Theme.colors.surface !== undefined
    ? Theme.colors.surface
    : Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06)

  readonly property color surfaceBorder: Theme.colors.surfaceBorder !== undefined
    ? Theme.colors.surfaceBorder
    : Qt.rgba(foreground.r, foreground.g, foreground.b, 0.18)

  readonly property color hover: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.10)

  readonly property color workspaceActive: Qt.rgba(accent.r, accent.g, accent.b, 0.85)
  readonly property color workspaceActiveText: background
  readonly property color workspaceOccupied: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.25)
}
