import QtQuick
import qs.Commons

// Themed slider used by volume and brightness panels.
Item {
  id: root

  property real value: 0            // 0..1
  property real step: 0.02
  property bool enabled: true

  signal moved(real value)

  implicitHeight: Style.widgetHeight
  implicitWidth: 160

  function valueAt(x) {
    return Util.clamp(x / width, 0, 1)
  }

  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width
    height: Math.max(4, Style.space(0.55))
    radius: Style.radius
    color: Color.hover
  }

  Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    width: track.width * Util.clamp(root.value, 0, 1)
    height: track.height
    radius: Style.radius
    color: root.enabled ? Color.accent : Color.muted

    Behavior on width {
      NumberAnimation { duration: 80 }
    }
  }

  Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    x: Util.clamp(track.width * Util.clamp(root.value, 0, 1) - width / 2, 0, track.width - width)
    width: Math.max(8, Style.space(1))
    height: width
    radius: width / 2
    color: Color.foreground
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.enabled
    cursorShape: Qt.PointingHandCursor
    onPressed: mouse => root.moved(root.valueAt(mouse.x))
    onPositionChanged: mouse => { if (pressed) root.moved(root.valueAt(mouse.x)) }
    onWheel: wheel => {
      const delta = wheel.angleDelta.y > 0 ? root.step : -root.step
      root.moved(Util.clamp(root.value + delta, 0, 1))
    }
  }
}
