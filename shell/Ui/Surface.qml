import QtQuick
import qs.Commons

// A themed card: background, optional border, optional padding.
Rectangle {
  id: root

  property bool bordered: true
  property real padding: Style.space(1.5)

  radius: Style.radius
  color: Color.panel
  border.width: bordered ? 1 : 0
  border.color: Color.surfaceBorder

  default property alias content: inner.data

  Item {
    id: inner
    anchors.fill: parent
    anchors.margins: root.padding
  }
}
