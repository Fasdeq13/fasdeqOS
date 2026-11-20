import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: root

    property bool launcherVisible: false
    property bool powerVisible: false
    property string searchText: ""
    property int selectedIndex: 0

    property var applications: DesktopEntries.applications.values

    property real animProgress: (launcherVisible || powerVisible) ? 1 : 0
    Behavior on animProgress {
        NumberAnimation { duration: 260; easing.type: Easing.OutExpo }
    }

    signal launcherClosed()
    signal powerClosed()

    function openLauncher() {
        powerVisible = false
        launcherVisible = true
        searchText = ""
        selectedIndex = 0
        Qt.callLater(function() {
            searchField.forceActiveFocus()
        })
    }

    function toggleLauncher() {
        if (launcherVisible) closeLauncher()
        else openLauncher()
    }

    function closeLauncher() {
        launcherVisible = false
        searchText = ""
        launcherClosed()
    }

    function openPower() {
        launcherVisible = false
        powerVisible = true
        Qt.callLater(function() {
            contentItem.forceActiveFocus()
        })
    }

    function togglePower() {
        if (powerVisible) closePower()
        else openPower()
    }

    function closePower() {
        powerVisible = false
        powerClosed()
    }

    function filteredApplications() {
        if (!applications)
            return []

        let result = []
        let query = searchText.toLowerCase().trim()

        for (let i = 0; i < applications.length; ++i) {
            let app = applications[i]
            if (!app || app.noDisplay)
                continue

            let name = String(app.name || "").toLowerCase()
            let comment = String(app.comment || "").toLowerCase()

            if (query === "" || name.includes(query) || comment.includes(query))
                result.push(app)
        }

        return result
    }

    function launchSelected() {
        let list = filteredApplications()
        if (list.length === 0 || selectedIndex < 0 || selectedIndex >= list.length)
            return
        let app = list[selectedIndex]
        if (app && app.execute) {
            app.execute()
            closeLauncher()
        }
    }

    function moveSelection(amount) {
        let count = filteredApplications().length
        if (count === 0) {
            selectedIndex = 0
            return
        }
        selectedIndex = (selectedIndex + amount + count) % count
        appList.positionViewAtIndex(selectedIndex, ListView.Contain)
    }

    function executePower(action) {
        if (action === 1)
            Quickshell.execDetached(["niri", "msg", "action", "quit", "--skip-confirmation"])
        else if (action === 2)
            Quickshell.execDetached(["systemctl", "reboot"])
        else if (action === 3)
            Quickshell.execDetached(["systemctl", "poweroff"])
        closePower()
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    visible: launcherVisible || powerVisible || animProgress > 0.01
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: (launcherVisible || powerVisible) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WlrLayershell.namespace: "fasdeqos-popups"

    Item {
        id: contentItem
        anchors.fill: parent
        focus: root.launcherVisible || root.powerVisible

        Keys.onEscapePressed: {
            if (root.launcherVisible) root.closeLauncher()
            else root.closePower()
        }

        Keys.onUpPressed: {
            if (root.launcherVisible) root.moveSelection(-1)
        }

        Keys.onDownPressed: {
            if (root.launcherVisible) root.moveSelection(1)
        }

        Keys.onTabPressed: root.moveSelection(1)
        Keys.onBacktabPressed: root.moveSelection(-1)

        Keys.onReturnPressed: {
            if (root.launcherVisible) root.launchSelected()
        }

        Keys.onEnterPressed: {
            if (root.launcherVisible) root.launchSelected()
        }

        Keys.onPressed: function(event) {
            if (!root.powerVisible) return
            if (event.key === Qt.Key_1) {
                root.executePower(1)
                event.accepted = true
            } else if (event.key === Qt.Key_2) {
                root.executePower(2)
                event.accepted = true
            } else if (event.key === Qt.Key_3) {
                root.executePower(3)
                event.accepted = true
            }
        }

        Rectangle {
            anchors.fill: parent
            color: Colors.cOverlay
            opacity: root.animProgress

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (root.launcherVisible) root.closeLauncher()
                    else if (root.powerVisible) root.closePower()
                }
            }
        }

        Rectangle {
            id: launcher
            width: Colors.launcherWidth
            height: Colors.launcherHeight
            radius: Colors.uiRadius
            anchors.centerIn: parent
            visible: root.launcherVisible || (opacity > 0.01 && !root.powerVisible)
            color: Colors.cSurface
            border.width: 1
            border.color: Colors.cOutlineVariant

            opacity: root.launcherVisible ? root.animProgress : 0
            scale: 0.93 + 0.07 * opacity
            transform: Translate { y: (1 - launcher.opacity) * 14 }

            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    spacing: 12

                    Rectangle {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        radius: Colors.smallRadius
                        color: Colors.cPrimaryContainer

                        Rectangle {
                            anchors.centerIn: parent
                            width: 18
                            height: 18
                            radius: 9
                            color: "transparent"
                            border.width: 2.5
                            border.color: Colors.cPrimary
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        Text {
                            text: "Applications"
                            color: Colors.cOnSurface
                            font.family: Colors.cFontFamily
                            font.pixelSize: 15
                            font.weight: Font.Bold
                        }

                        Text {
                            text: "Find something to launch"
                            color: Colors.cOnSurfaceVariant
                            font.family: Colors.cFontFamily
                            font.pixelSize: 10
                        }
                    }

                    Text {
                        text: "ESC"
                        color: Colors.cInactive
                        font.family: Colors.cFontFamily
                        font.pixelSize: 10
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: Colors.smallRadius
                    color: Colors.cBackground
                    clip: true

                    ListView {
                        id: appList
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 4
                        clip: true
                        model: root.filteredApplications()
                        currentIndex: root.selectedIndex

                        delegate: Rectangle {
                            id: appDelegate
                            required property var modelData
                            required property int index

                            width: appList.width
                            height: 58
                            radius: Colors.smallRadius
                            color: index === root.selectedIndex ? Colors.cSurfaceContainerHighest : "transparent"
                            border.width: index === root.selectedIndex ? 1 : 0
                            border.color: Colors.cPrimaryDim

                            Behavior on color { ColorAnimation { duration: 160 } }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 10
                                spacing: 12

                                Rectangle {
                                    Layout.preferredWidth: 38
                                    Layout.preferredHeight: 38
                                    radius: Colors.smallRadius
                                    color: Colors.cSurfaceContainer

                                    Image {
                                        anchors.centerIn: parent
                                        width: 24
                                        height: 24
                                        source: appDelegate.modelData.icon ? Quickshell.iconPath(appDelegate.modelData.icon, true) : ""
                                        sourceSize.width: 64
                                        sourceSize.height: 64
                                        fillMode: Image.PreserveAspectFit
                                        smooth: true
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2

                                    Text {
                                        Layout.fillWidth: true
                                        text: appDelegate.modelData.name || "Application"
                                        color: Colors.cOnSurface
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 12
                                        font.weight: Font.DemiBold
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: appDelegate.modelData.comment || appDelegate.modelData.genericName || ""
                                        color: Colors.cOnSurfaceVariant
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 9
                                        elide: Text.ElideRight
                                    }
                                }

                                Text {
                                    visible: index === root.selectedIndex
                                    text: "↵"
                                    color: Colors.cPrimary
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 16
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onEntered: root.selectedIndex = appDelegate.index
                                onClicked: {
                                    root.selectedIndex = appDelegate.index
                                    root.launchSelected()
                                }
                            }
                        }

                        ScrollBar.vertical: ScrollBar { active: true }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: root.filteredApplications().length === 0
                        text: "No applications found"
                        color: Colors.cInactive
                        font.family: Colors.cFontFamily
                        font.pixelSize: 12
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44
                    radius: Colors.smallRadius
                    color: Colors.cSurfaceContainerHigh
                    border.width: 1
                    border.color: searchField.activeFocus ? Colors.cPrimary : Colors.cOutlineVariant

                    Behavior on border.color { ColorAnimation { duration: 160 } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 10

                        Text {
                            text: "󰍉"
                            color: Colors.cPrimary
                            font.family: Colors.cFontFamily
                            font.pixelSize: 18
                        }

                        TextField {
                            id: searchField
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            placeholderText: "Search applications..."
                            placeholderTextColor: Colors.cInactive
                            text: root.searchText
                            color: Colors.cOnSurface
                            font.family: Colors.cFontFamily
                            font.pixelSize: 12
                            background: Item {}
                            selectByMouse: true
                            focus: root.launcherVisible

                            onTextChanged: {
                                root.searchText = text
                                root.selectedIndex = 0
                                appList.positionViewAtBeginning()
                            }

                            Keys.onUpPressed: root.moveSelection(-1)
                            Keys.onDownPressed: root.moveSelection(1)
                            Keys.onTabPressed: root.moveSelection(1)
                            Keys.onBacktabPressed: root.moveSelection(-1)
                            Keys.onReturnPressed: root.launchSelected()
                            Keys.onEnterPressed: root.launchSelected()
                            Keys.onEscapePressed: root.closeLauncher()
                        }

                        Text {
                            text: "ESC"
                            color: Colors.cInactive
                            font.family: Colors.cFontFamily
                            font.pixelSize: 9
                        }
                    }
                }
            }
        }

        Rectangle {
            id: powerMenu
            width: 600
            height: 250
            radius: Colors.uiRadius
            color: Colors.cSurface
            border.width: 1
            border.color: Colors.cOutlineVariant
            anchors.centerIn: parent
            visible: root.powerVisible || (opacity > 0.01 && !root.launcherVisible)

            opacity: root.powerVisible ? root.animProgress : 0
            scale: 0.93 + 0.07 * opacity
            transform: Translate { y: (1 - powerMenu.opacity) * 14 }

            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 16

                RowLayout {
                    Layout.fillWidth: true

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            text: "Power menu"
                            color: Colors.cOnSurface
                            font.family: Colors.cFontFamily
                            font.pixelSize: 17
                            font.weight: Font.Bold
                        }

                        Text {
                            text: "Choose a session action"
                            color: Colors.cOnSurfaceVariant
                            font.family: Colors.cFontFamily
                            font.pixelSize: 10
                        }
                    }

                    Text {
                        text: "ESC"
                        color: Colors.cInactive
                        font.family: Colors.cFontFamily
                        font.pixelSize: 10
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 10

                    Repeater {
                        model: [
                            { number: "1", title: "Log Out", icon: "󰍃", description: "End your session", bg: Colors.cPrimaryContainer, fg: Colors.cPrimary },
                            { number: "2", title: "Reboot", icon: "󰜉", description: "Restart your system", bg: Colors.cTertiaryContainer, fg: Colors.cTertiary },
                            { number: "3", title: "Power Off", icon: "⏻", description: "Shut down your system", bg: Colors.cErrorContainer, fg: Colors.cError }
                        ]

                        delegate: Rectangle {
                            id: powerCard
                            required property var modelData
                            required property int index

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: Colors.smallRadius
                            color: cardMouse.containsMouse ? Colors.cSurfaceContainerHighest : Colors.cSurfaceContainer
                            border.width: 1
                            border.color: cardMouse.containsMouse ? modelData.fg : Colors.cOutlineVariant

                            Behavior on color { ColorAnimation { duration: 160 } }
                            Behavior on border.color { ColorAnimation { duration: 160 } }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 8

                                Rectangle {
                                    Layout.preferredWidth: 42
                                    Layout.preferredHeight: 42
                                    radius: Colors.smallRadius
                                    color: powerCard.modelData.bg

                                    Text {
                                        anchors.centerIn: parent
                                        text: powerCard.modelData.icon
                                        color: powerCard.modelData.fg
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 22
                                    }
                                }

                                Text {
                                    text: powerCard.modelData.title
                                    color: Colors.cOnSurface
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 12
                                    font.weight: Font.Bold
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: powerCard.modelData.description
                                    color: Colors.cOnSurfaceVariant
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 9
                                    wrapMode: Text.WordWrap
                                }

                                Item { Layout.fillHeight: true }

                                Text {
                                    text: "[" + powerCard.modelData.number + "]"
                                    color: powerCard.modelData.fg
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 11
                                }
                            }

                            MouseArea {
                                id: cardMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.executePower(powerCard.index + 1)
                            }
                        }
                    }
                }
            }
        }
    }
}
