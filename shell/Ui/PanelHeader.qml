import QtQuick
import qs.Commons

// Shared hierarchy for device panels: one clear title and a quieter status.
Item {
  id: root
  property string title: ""
  property string subtitle: ""
  property string glyph: ""
  implicitHeight: Style.space(7.5)
  Rectangle {
    id: badge
    visible: root.glyph !== ""
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(6)
    height: width
    radius: Style.radius
    color: Color.surface
    Text {
      anchors.centerIn: parent
      text: root.glyph
      color: Color.accent
      font.family: Style.iconFamily
      font.pixelSize: Style.fontSize + 10
    }
  }
  Column {
    anchors.left: root.glyph !== "" ? badge.right : parent.left
    anchors.leftMargin: root.glyph !== "" ? Style.space(1.5) : 0
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(0.5)
    Text {
      width: parent.width
      text: root.title
      color: Color.foreground
      font.family: Style.fontFamily
      font.pixelSize: Style.fontSize + 8
      font.bold: true
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      visible: root.subtitle !== ""
      text: root.subtitle
      color: Color.muted
      font.family: Style.fontFamily
      font.pixelSize: Style.smallFontSize
      elide: Text.ElideRight
    }
  }
}
