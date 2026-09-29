import QtQuick
import qs.Commons

// Search-and-pick list for the places / world-clock editors.
//
// A value is never typed: the field filters a list that comes from a real source
// (geocoding results, the local timezone database), so an unknown city or a
// mistyped zone cannot be chosen by accident.
Item {
  id: root

  property var items: []
  property string placeholder: ""
  property string emptyText: ""
  property bool busy: false
  property int maxVisible: 5
  property string query: ""

  signal picked(int index)

  // Callers pass an expression that can evaluate to undefined while a service is
  // still loading; never let that reach a .length or a model.
  readonly property var rows: (items === undefined || items === null) ? [] : items

  readonly property real rowHeight: Style.space(2.6)

  implicitWidth: 320
  implicitHeight: field.implicitHeight + Style.space(0.5)
    + Math.min(maxVisible, Math.max(1, rows.length)) * rowHeight

  function clear() {
    field.text = ""
    query = ""
    field.forceFocus()
  }

  // The picker exists to be searched, so it takes the keyboard when it appears.
  onVisibleChanged: if (visible) field.forceFocus()
  Component.onCompleted: if (visible) field.forceFocus()

  TextField {
    id: field
    width: parent.width
    placeholder: root.placeholder
    onTextChanged: root.query = text
  }

  ListView {
    id: list
    anchors.top: field.bottom
    anchors.topMargin: Style.space(0.5)
    width: parent.width
    height: root.implicitHeight - field.implicitHeight - Style.space(0.5)
    clip: true
    model: root.rows
    boundsBehavior: Flickable.StopAtBounds

    delegate: Rectangle {
      required property var modelData
      required property int index

      width: list.width
      height: root.rowHeight
      color: hoverArea.containsMouse ? Color.hover : "transparent"

      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.space(0.8)
        anchors.rightMargin: Style.space(0.8)
        spacing: Style.space(0.8)

        Text {
          width: parent.width - detailText.width - Style.space(0.8)
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.label
          color: Color.foreground
          elide: Text.ElideRight
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSize
        }

        Text {
          id: detailText
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.detail === undefined ? "" : modelData.detail
          color: Color.muted
          font.family: Style.fontFamily
          font.pixelSize: Style.smallFontSize
        }
      }

      MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.picked(index)
      }
    }
  }

  Text {
    anchors.top: field.bottom
    anchors.topMargin: Style.space(1)
    width: parent.width
    visible: root.rows.length === 0
    text: root.busy ? I18n.t("editor.searching") : root.emptyText
    color: Color.muted
    font.family: Style.fontFamily
    font.pixelSize: Style.smallFontSize
  }
}
