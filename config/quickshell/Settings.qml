import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: root

    property bool settingsVisible: false

    function open() {
        settingsVisible = true
        Qt.callLater(function() {
            focusRoot.forceActiveFocus()
        })
    }

    function close() {
        settingsVisible = false
    }

    function toggle() {
        if (settingsVisible) close()
        else open()
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    property real cardAnim: settingsVisible ? 1 : 0
    Behavior on cardAnim {
        NumberAnimation { duration: 260; easing.type: Easing.OutExpo }
    }

    visible: settingsVisible || cardAnim > 0.01
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: settingsVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WlrLayershell.namespace: "fasdeqos-settings"

    Item {
        id: focusRoot
        anchors.fill: parent
        focus: root.settingsVisible

        Keys.onEscapePressed: root.close()

        Rectangle {
            anchors.fill: parent
            color: Colors.cOverlay
            opacity: root.cardAnim

            MouseArea {
                anchors.fill: parent
                onClicked: root.close()
            }
        }

        Rectangle {
            width: 500
            height: 560
            radius: Colors.uiRadius
            anchors.centerIn: parent
            color: Colors.cSurface
            border.width: 1
            border.color: Colors.cOutlineVariant
            opacity: root.cardAnim
            scale: 0.93 + 0.07 * root.cardAnim
            transform: Translate { y: (1 - root.cardAnim) * 14 }

            MouseArea {
                anchors.fill: parent
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 14

                RowLayout {
                    Layout.fillWidth: true

                    Text {
                        text: "Settings"
                        color: Colors.cOnSurface
                        font.family: Colors.cFontFamily
                        font.pixelSize: 17
                        font.weight: Font.Bold
                        Layout.fillWidth: true
                    }

                    Rectangle {
                        width: 28
                        height: 28
                        radius: Colors.smallRadius
                        color: closeHover.hovered ? Colors.cSurfaceContainerHighest : Colors.cSurfaceContainer

                        Behavior on color { ColorAnimation { duration: 180 } }
                        HoverHandler { id: closeHover }

                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            color: Colors.cOnSurfaceVariant
                            font.family: Colors.cFontFamily
                            font.pixelSize: 12
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.close()
                        }
                    }
                }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: width
                    contentHeight: settingsCol.implicitHeight
                    clip: true

                    ColumnLayout {
                        id: settingsCol
                        width: parent.width
                        spacing: 14

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                text: "Color Scheme"
                                color: Colors.cOnSurfaceVariant
                                font.family: Colors.cFontFamily
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Repeater {
                                    model: Colors.themeList

                                    delegate: Rectangle {
                                        required property var modelData
                                        property bool selected: Colors.currentTheme === modelData.id

                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 54
                                        radius: Colors.smallRadius
                                        color: selected ? Colors.cPrimaryContainer : (thHover.hovered ? Colors.cSurfaceContainerHigh : Colors.cSurfaceContainer)
                                        border.width: selected ? 2 : 1
                                        border.color: selected ? Colors.cPrimary : Colors.cOutlineVariant

                                        Behavior on color { ColorAnimation { duration: 200 } }
                                        Behavior on border.color { ColorAnimation { duration: 200 } }
                                        HoverHandler { id: thHover }

                                        ColumnLayout {
                                            anchors.centerIn: parent
                                            spacing: 5

                                            Rectangle {
                                                Layout.alignment: Qt.AlignHCenter
                                                width: 16
                                                height: 16
                                                radius: Math.min(8, Colors.smallRadius)
                                                color: modelData.preview
                                            }

                                            Text {
                                                Layout.alignment: Qt.AlignHCenter
                                                text: modelData.name
                                                color: selected ? Colors.cOnPrimaryContainer : Colors.cOnSurface
                                                font.family: Colors.cFontFamily
                                                font.pixelSize: 9
                                                font.bold: selected
                                            }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: Colors.currentTheme = modelData.id
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            height: 1
                            color: Colors.cOutlineVariant
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                text: "Appearance & Sizing"
                                color: Colors.cOnSurfaceVariant
                                font.family: Colors.cFontFamily
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Text {
                                    text: "Corner Radius"
                                    color: Colors.cOnSurface
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 10
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: Colors.uiRadius + "px"
                                    color: Colors.cPrimary
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 10
                                    font.bold: true
                                }
                            }

                            Slider {
                                Layout.fillWidth: true
                                from: 0
                                to: 24
                                stepSize: 1
                                value: Colors.uiRadius
                                onMoved: Colors.uiRadius = Math.round(value)
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Text {
                                    text: "Launcher Width"
                                    color: Colors.cOnSurface
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 10
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: Colors.launcherWidth + "px"
                                    color: Colors.cPrimary
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 10
                                    font.bold: true
                                }
                            }

                            Slider {
                                Layout.fillWidth: true
                                from: 420
                                to: 820
                                stepSize: 10
                                value: Colors.launcherWidth
                                onMoved: Colors.launcherWidth = Math.round(value)
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Text {
                                    text: "Launcher Height"
                                    color: Colors.cOnSurface
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 10
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: Colors.launcherHeight + "px"
                                    color: Colors.cPrimary
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 10
                                    font.bold: true
                                }
                            }

                            Slider {
                                Layout.fillWidth: true
                                from: 380
                                to: 720
                                stepSize: 10
                                value: Colors.launcherHeight
                                onMoved: Colors.launcherHeight = Math.round(value)
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            height: 1
                            color: Colors.cOutlineVariant
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Text {
                                text: "Bar Applets"
                                color: Colors.cOnSurfaceVariant
                                font.family: Colors.cFontFamily
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                            }

                            Repeater {
                                model: [
                                    { label: "Workspaces", key: "showWorkspaces" },
                                    { label: "Clock & Calendar", key: "showClock" },
                                    { label: "System Tray", key: "showTray" },
                                    { label: "Keyboard Layout", key: "showLayout" },
                                    { label: "Screenshot", key: "showScreenshot" },
                                    { label: "Wi-Fi / Network", key: "showWifi" },
                                    { label: "Bluetooth", key: "showBluetooth" },
                                    { label: "Audio", key: "showAudio" }
                                ]

                                delegate: Rectangle {
                                    required property var modelData
                                    property bool isOn: Colors[modelData.key]

                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 38
                                    radius: Colors.smallRadius
                                    color: rowHover.hovered ? Colors.cSurfaceContainerHigh : Colors.cSurfaceContainer

                                    Behavior on color { ColorAnimation { duration: 160 } }
                                    HoverHandler { id: rowHover }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 12
                                        anchors.rightMargin: 12

                                        Text {
                                            text: modelData.label
                                            color: Colors.cOnSurface
                                            font.family: Colors.cFontFamily
                                            font.pixelSize: 11
                                            Layout.fillWidth: true
                                        }

                                        Rectangle {
                                            width: 42
                                            height: 22
                                            radius: Colors.smallRadius
                                            color: isOn ? Colors.cPrimary : Colors.cSurfaceContainerHighest
                                            border.width: 1
                                            border.color: isOn ? Colors.cPrimary : Colors.cOutline

                                            Behavior on color { ColorAnimation { duration: 200 } }

                                            Rectangle {
                                                width: 16
                                                height: 16
                                                radius: Math.max(2, Colors.smallRadius - 2)
                                                anchors.verticalCenter: parent.verticalCenter
                                                x: isOn ? parent.width - width - 3 : 3
                                                color: isOn ? Colors.cOnPrimary : Colors.cOnSurfaceVariant

                                                Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutExpo } }
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: Colors[modelData.key] = !Colors[modelData.key]
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
