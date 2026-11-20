//@ pragma UseQApplication
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.SystemTray
import Quickshell.Services.Pipewire

ShellRoot {
    id: root

    property bool wifiMenu: false
    property bool bluetoothMenu: false
    property bool audioMenu: false
    property bool calendarMenu: false
    property bool screenshotMenu: false

    property bool wifiAvailable: false
    property bool wifiEnabled: false
    property bool wifiBusy: false
    property string ethernetDevice: ""
    property bool ethernetConnected: false
    property bool bluetoothEnabled: false

    property var niriWorkspaces: []
    property var keyboardLayouts: []
    property int currentLayoutIdx: 0
    property string currentLayoutShort: {
        if (!keyboardLayouts || keyboardLayouts.length === 0)
            return "EN"
        let name = String(keyboardLayouts[currentLayoutIdx] || "").toLowerCase()
        if (name.includes("russian") || name.includes("ru"))
            return "RU"
        if (name.includes("english") || name.includes("us"))
            return "EN"
        return name.substring(0, 2).toUpperCase()
    }

    property string currentDate: Qt.formatDateTime(new Date(), "dd.MM  HH:mm")
    property int calYear: new Date().getFullYear()
    property int calMonth: new Date().getMonth()

    property var wifiNetworks: []
    property var bluetoothDevices: []

    property var audioSink: Pipewire.defaultAudioSink
    property var audioSource: Pipewire.defaultAudioSource

    property real outputVolume: audioSink && audioSink.audio ? audioSink.audio.volume * 100 : 0
    property real inputVolume: audioSource && audioSource.audio ? audioSource.audio.volume * 100 : 0
    property bool outputMuted: audioSink && audioSink.audio ? audioSink.audio.muted : false
    property bool inputMuted: audioSource && audioSource.audio ? audioSource.audio.muted : false

    property bool osdVisible: false
    property bool osdReady: false

    onOutputVolumeChanged: {
        if (osdReady) showVolumeOsd()
    }

    onOutputMutedChanged: {
        if (osdReady) showVolumeOsd()
    }

    IpcHandler {
        target: "shell"
        function launcher(): void { root.closeMenus(); settingsWindow.close(); popups.toggleLauncher() }
        function power(): void { root.closeMenus(); settingsWindow.close(); popups.togglePower() }
        function settings(): void { root.closeMenus(); popups.closeLauncher(); popups.closePower(); settingsWindow.toggle() }
        function screenshot(): void { root.toggleMenu("screenshot") }
        function screenshotArea(): void { root.closeMenus(); root.niriAction(["screenshot"]) }
        function screenshotScreen(): void { root.closeMenus(); root.niriAction(["screenshot-screen"]) }
        function screenshotWindow(): void { root.closeMenus(); root.niriAction(["screenshot-window"]) }
        function calendar(): void { root.toggleMenu("calendar") }
        function audio(): void { root.toggleMenu("audio") }
        function wifi(): void { root.toggleMenu("wifi") }
        function network(): void { root.toggleMenu("wifi") }
        function bluetooth(): void { root.toggleMenu("bluetooth") }
    }

    PwObjectTracker {
        objects: [
            Pipewire.defaultAudioSink,
            Pipewire.defaultAudioSource
        ]
    }

    Timer {
        interval: 1200
        running: true
        repeat: false
        onTriggered: root.osdReady = true
    }

    Timer {
        id: osdHideTimer
        interval: 1500
        repeat: false
        onTriggered: root.osdVisible = false
    }

    function showVolumeOsd() {
        osdVisible = true
        osdHideTimer.restart()
    }

    function run(command) {
        Quickshell.execDetached(command)
    }

    function niriAction(args) {
        Quickshell.execDetached(["niri", "msg", "action"].concat(args))
    }

    function closeMenus() {
        wifiMenu = false
        bluetoothMenu = false
        audioMenu = false
        calendarMenu = false
        screenshotMenu = false
    }

    function toggleMenu(name) {
        let wasOpen = (name === "wifi" && wifiMenu) ||
                      (name === "bluetooth" && bluetoothMenu) ||
                      (name === "audio" && audioMenu) ||
                      (name === "calendar" && calendarMenu) ||
                      (name === "screenshot" && screenshotMenu)
        closeMenus()
        popups.closeLauncher()
        popups.closePower()
        settingsWindow.close()
        if (!wasOpen) {
            if (name === "wifi") {
                wifiMenu = true
                refreshWifi()
            } else if (name === "bluetooth") {
                bluetoothMenu = true
                refreshBluetooth()
            } else if (name === "audio") {
                audioMenu = true
            } else if (name === "screenshot") {
                screenshotMenu = true
            } else if (name === "calendar") {
                let now = new Date()
                calYear = now.getFullYear()
                calMonth = now.getMonth()
                calendarMenu = true
            }
        }
    }

    function refreshWifi() {
        wifiRadio.running = true
        wifiHardware.running = true
        ethDeviceProc.running = true
        wifiList.running = true
    }

    function refreshBluetooth() {
        bluetoothInfo.running = true
        bluetoothList.running = true
    }

    function toggleWifi() {
        wifiBusy = true
        wifiActionProc.command = ["nmcli", "radio", "wifi", wifiEnabled ? "off" : "on"]
        wifiActionProc.running = true
    }

    function toggleEthernet() {
        if (!ethernetDevice) return
        wifiBusy = true
        wifiActionProc.command = ["nmcli", "device", ethernetConnected ? "disconnect" : "connect", ethernetDevice]
        wifiActionProc.running = true
    }

    function scanWifi() {
        wifiBusy = true
        wifiActionProc.command = ["nmcli", "device", "wifi", "rescan"]
        wifiActionProc.running = true
    }

    function connectWifi(ssid) {
        wifiBusy = true
        wifiActionProc.command = ["nmcli", "device", "wifi", "connect", ssid]
        wifiActionProc.running = true
    }

    function toggleBluetooth() {
        run(["bluetoothctl", "power", bluetoothEnabled ? "off" : "on"])
        bluetoothRefresh.start()
    }

    function connectBluetooth(address) {
        run(["bluetoothctl", "connect", address])
    }

    function parseWifi(data) {
        let lines = data.trim().split("\n")
        let result = []
        let seen = {}
        for (let line of lines) {
            let parts = line.split(":")
            if (parts.length < 4 || !parts[1] || seen[parts[1]])
                continue
            seen[parts[1]] = true
            result.push({
                connected: parts[0] === "*",
                ssid: parts[1],
                signal: parts[2],
                security: parts.slice(3).join(":")
            })
        }
        wifiNetworks = result
    }

    function parseBluetooth(data) {
        let lines = data.trim().split("\n")
        let result = []
        for (let line of lines) {
            let match = line.match(/^Device\s+([0-9A-Fa-f:]+)\s+(.+)$/)
            if (match) {
                result.push({
                    address: match[1],
                    name: match[2]
                })
            }
        }
        bluetoothDevices = result
    }

    function calendarDays(year, month) {
        let firstDay = new Date(year, month, 1).getDay()
        let startOffset = (firstDay + 6) % 7
        let daysInMonth = new Date(year, month + 1, 0).getDate()
        let today = new Date()
        let cells = []
        for (let i = 0; i < startOffset; i++)
            cells.push({ day: "", isToday: false })
        for (let d = 1; d <= daysInMonth; d++) {
            cells.push({
                day: String(d),
                isToday: year === today.getFullYear() && month === today.getMonth() && d === today.getDate()
            })
        }
        return cells
    }

    function shiftMonth(delta) {
        let m = calMonth + delta
        if (m < 0) {
            calMonth = 11
            calYear -= 1
        } else if (m > 11) {
            calMonth = 0
            calYear += 1
        } else {
            calMonth = m
        }
    }

    Process {
        id: wifiActionProc
        onExited: wifiRefresh.restart()
    }

    Process {
        id: niriWsFetch
        command: ["niri", "msg", "-j", "workspaces"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.niriWorkspaces = JSON.parse(text)
                } catch (e) {}
            }
        }
    }

    Process {
        id: niriKbFetch
        command: ["niri", "msg", "-j", "keyboard-layouts"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let obj = JSON.parse(text)
                    root.keyboardLayouts = obj.names || []
                    root.currentLayoutIdx = obj.current_idx || 0
                } catch (e) {}
            }
        }
    }

    Process {
        id: niriEventProc
        command: ["niri", "msg", "-j", "event-stream"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    let ev = JSON.parse(data)
                    if (ev.WorkspacesChanged) {
                        root.niriWorkspaces = ev.WorkspacesChanged.workspaces
                    } else if (ev.WorkspaceActivated) {
                        niriWsFetch.running = true
                    } else if (ev.KeyboardLayoutsChanged) {
                        let kb = ev.KeyboardLayoutsChanged.keyboard_layouts
                        root.keyboardLayouts = kb.names || []
                        root.currentLayoutIdx = kb.current_idx || 0
                    } else if (ev.KeyboardLayoutSwitched) {
                        root.currentLayoutIdx = ev.KeyboardLayoutSwitched.idx
                    }
                } catch (e) {}
            }
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: root.currentDate = Qt.formatDateTime(new Date(), "dd.MM  HH:mm")
    }

    Timer {
        id: wifiRefresh
        interval: 800
        repeat: false
        onTriggered: {
            root.refreshWifi()
            root.wifiBusy = false
        }
    }

    Timer {
        id: bluetoothRefresh
        interval: 1000
        repeat: false
        onTriggered: root.refreshBluetooth()
    }

    Process {
        id: wifiRadio
        command: ["nmcli", "-t", "-f", "WIFI", "radio"]
        stdout: StdioCollector {
            onStreamFinished: root.wifiEnabled = text.trim() === "enabled"
        }
    }

    Process {
        id: wifiHardware
        command: ["bash", "-c", "nmcli -t -f DEVICE,TYPE device status | grep ':wifi$'"]
        stdout: StdioCollector {
            onStreamFinished: root.wifiAvailable = text.trim().length > 0
        }
    }

    Process {
        id: ethDeviceProc
        command: ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device", "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                let lines = text.trim().split("\n")
                let dev = ""
                let conn = false
                for (let i = 0; i < lines.length; i++) {
                    let parts = lines[i].split(":")
                    if (parts.length >= 3 && parts[1] === "ethernet") {
                        dev = parts[0]
                        conn = parts[2] === "connected"
                        break
                    }
                }
                root.ethernetDevice = dev
                root.ethernetConnected = conn
            }
        }
    }

    Process {
        id: wifiList
        command: ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list"]
        stdout: StdioCollector {
            onStreamFinished: root.parseWifi(text)
        }
    }

    Process {
        id: bluetoothInfo
        command: ["bluetoothctl", "show"]
        stdout: StdioCollector {
            onStreamFinished: root.bluetoothEnabled = text.includes("Powered: yes")
        }
    }

    Process {
        id: bluetoothList
        command: ["bluetoothctl", "devices", "Paired"]
        stdout: StdioCollector {
            onStreamFinished: root.parseBluetooth(text)
        }
    }

    Component.onCompleted: {
        refreshWifi()
        refreshBluetooth()
    }

    Popups {
        id: popups
    }

    Settings {
        id: settingsWindow
    }

    PanelWindow {
        id: menuBackdrop
        visible: root.wifiMenu || root.bluetoothMenu || root.audioMenu || root.calendarMenu || root.screenshotMenu
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "fasdeqos-backdrop"

        MouseArea {
            anchors.fill: parent
            onClicked: root.closeMenus()
        }
    }

    PanelWindow {
        id: osdWindow
        property real osdAnim: root.osdVisible ? 1 : 0
        Behavior on osdAnim {
            NumberAnimation { duration: 240; easing.type: Easing.OutExpo }
        }

        visible: root.osdVisible || osdAnim > 0.01
        anchors {
            right: true
        }
        margins {
            right: 14
        }
        implicitWidth: 56
        implicitHeight: 204
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "fasdeqos-osd"

        Rectangle {
            anchors.fill: parent
            radius: Colors.uiRadius
            color: Colors.cSurface
            border.width: 1
            border.color: Colors.cOutlineVariant
            opacity: osdWindow.osdAnim
            scale: 0.92 + 0.08 * osdWindow.osdAnim
            transform: Translate { x: (1 - osdWindow.osdAnim) * 16 }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 10

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: root.outputMuted ? "󰖁" : "󰕾"
                    color: root.outputMuted ? Colors.cInactive : Colors.cPrimary
                    font.family: Colors.cFontFamily
                    font.pixelSize: 18
                }

                Item {
                    Layout.fillHeight: true
                    Layout.alignment: Qt.AlignHCenter
                    width: 8

                    Rectangle {
                        anchors.fill: parent
                        radius: 4
                        color: Colors.cSurfaceContainerHighest

                        Rectangle {
                            anchors.bottom: parent.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            radius: 4
                            height: parent.height * Math.max(0, Math.min(1, root.outputVolume / 100))
                            color: root.outputMuted ? Colors.cInactive : Colors.cPrimary

                            Behavior on height {
                                NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                            }
                        }
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: Math.round(root.outputVolume) + "%"
                    color: Colors.cOnSurface
                    font.family: Colors.cFontFamily
                    font.pixelSize: 10
                    font.weight: Font.Bold
                }
            }
        }
    }

    component M3Switch: Rectangle {
        id: sw
        property bool checked: false
        property bool enabled: true
        signal toggled(bool value)

        width: 42
        height: 22
        radius: Colors.smallRadius
        opacity: enabled ? 1 : 0.45
        color: checked ? Colors.cPrimary : Colors.cSurfaceContainerHighest
        border.width: 1
        border.color: checked ? Colors.cPrimary : Colors.cOutline

        Behavior on color { ColorAnimation { duration: 200 } }

        Rectangle {
            width: 16
            height: 16
            radius: Math.max(2, Colors.smallRadius - 2)
            anchors.verticalCenter: parent.verticalCenter
            x: sw.checked ? parent.width - width - 3 : 3
            color: sw.checked ? Colors.cOnPrimary : Colors.cOnSurfaceVariant

            Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutExpo } }
        }

        MouseArea {
            anchors.fill: parent
            enabled: sw.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: sw.toggled(!sw.checked)
        }
    }

    component M3Slider: Slider {
        id: sl
        implicitHeight: 22

        background: Rectangle {
            x: sl.leftPadding
            y: sl.topPadding + sl.availableHeight / 2 - height / 2
            width: sl.availableWidth
            height: 6
            radius: 3
            color: Colors.cSurfaceContainerHighest

            Rectangle {
                width: sl.visualPosition * parent.width
                height: parent.height
                radius: 3
                color: Colors.cPrimary
            }
        }

        handle: Rectangle {
            x: sl.leftPadding + sl.visualPosition * (sl.availableWidth - width)
            y: sl.topPadding + sl.availableHeight / 2 - height / 2
            width: 16
            height: 16
            radius: Math.max(2, Colors.smallRadius - 2)
            color: sl.pressed ? Colors.cOnPrimaryContainer : Colors.cPrimary
            border.width: 2
            border.color: Colors.cSurface

            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            scale: sl.pressed ? 1.14 : 1.0
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: bar
            required property var modelData
            screen: modelData

            anchors {
                top: true
                left: true
                right: true
            }

            implicitHeight: 36
            color: Colors.cSurface

            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "fasdeqos-bar"

            Item {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    onWheel: wheel => {
                        root.niriAction([wheel.angleDelta.y > 0 ? "focus-column-left" : "focus-column-right"])
                    }
                }

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10

                    Rectangle {
                        width: 28
                        height: 28
                        radius: Colors.smallRadius
                        anchors.verticalCenter: parent.verticalCenter
                        color: popups.launcherVisible ? Colors.cPrimaryContainer : (launchHover.hovered ? Colors.cSurfaceContainerHigh : "transparent")

                        Behavior on color { ColorAnimation { duration: 180 } }
                        HoverHandler { id: launchHover }

                        Rectangle {
                            anchors.centerIn: parent
                            width: 16
                            height: 16
                            radius: 8
                            color: "transparent"
                            border.width: 2.2
                            border.color: popups.launcherVisible ? Colors.cOnPrimaryContainer : Colors.cPrimary

                            Behavior on border.color { ColorAnimation { duration: 180 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.closeMenus()
                                settingsWindow.close()
                                popups.toggleLauncher()
                            }
                        }
                    }

                    Rectangle {
                        visible: Colors.showWorkspaces
                        width: workspaceRow.implicitWidth + 8
                        height: 26
                        radius: Math.min(13, Colors.uiRadius + 4)
                        anchors.verticalCenter: parent.verticalCenter
                        color: Colors.cBackground
                        border.width: 1
                        border.color: Colors.cOutlineVariant

                        Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutExpo } }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.NoButton
                            onWheel: wheel => {
                                wheel.accepted = true
                                root.niriAction([wheel.angleDelta.y > 0 ? "focus-workspace-up" : "focus-workspace-down"])
                            }
                        }

                        Row {
                            id: workspaceRow
                            anchors.centerIn: parent
                            spacing: 4

                            Repeater {
                                model: {
                                    let list = []
                                    let all = root.niriWorkspaces || []
                                    for (let i = 0; i < all.length; i++) {
                                        let ws = all[i]
                                        if (ws && ws.output === bar.screen.name)
                                            list.push(ws)
                                    }
                                    list.sort((a, b) => a.idx - b.idx)
                                    return list
                                }

                                delegate: Rectangle {
                                    required property var modelData
                                    property bool selected: modelData.is_active === true

                                    width: selected ? 38 : 20
                                    height: 20
                                    radius: Math.min(10, Colors.smallRadius + 3)
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: selected ? Colors.cPrimary : (wsHover.hovered ? Colors.cSurfaceContainerHighest : Colors.cSurfaceContainer)

                                    Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutExpo } }
                                    Behavior on color { ColorAnimation { duration: 180 } }

                                    HoverHandler { id: wsHover }

                                    Text {
                                        anchors.centerIn: parent
                                        text: String(modelData.idx)
                                        color: selected ? Colors.cOnPrimary : Colors.cOnSurfaceVariant
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 10
                                        font.weight: selected ? Font.Bold : Font.Medium
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.niriAction(["focus-workspace", String(modelData.idx)])
                                        onWheel: wheel => {
                                            wheel.accepted = true
                                            root.niriAction([wheel.angleDelta.y > 0 ? "focus-workspace-up" : "focus-workspace-down"])
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    visible: Colors.showClock
                    anchors.centerIn: parent
                    width: clockText.implicitWidth + 18
                    height: 26
                    radius: Colors.smallRadius
                    color: root.calendarMenu ? Colors.cPrimaryContainer : (clockHover.hovered ? Colors.cSurfaceContainerHigh : "transparent")

                    Behavior on color { ColorAnimation { duration: 180 } }
                    HoverHandler { id: clockHover }

                    Text {
                        id: clockText
                        anchors.centerIn: parent
                        text: root.currentDate
                        color: root.calendarMenu ? Colors.cOnPrimaryContainer : Colors.cOnSurface
                        font.family: Colors.cFontFamily
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleMenu("calendar")
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    Row {
                        visible: Colors.showTray && SystemTray.items.values.length > 0
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        Repeater {
                            model: SystemTray.items

                            delegate: Item {
                                id: trayItem
                                required property var modelData
                                width: 20
                                height: 24
                                anchors.verticalCenter: parent.verticalCenter

                                Image {
                                    anchors.centerIn: parent
                                    width: 17
                                    height: 17
                                    source: modelData.icon
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: mouse => {
                                        if (mouse.button === Qt.LeftButton) {
                                            modelData.activate()
                                        } else {
                                            let pos = trayItem.mapToItem(null, mouse.x, trayItem.height)
                                            if (modelData.hasMenu)
                                                modelData.display(bar, pos.x, pos.y)
                                            else
                                                modelData.secondaryActivate()
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        visible: Colors.showLayout
                        width: kbLabel.implicitWidth + 12
                        height: 26
                        radius: Colors.smallRadius
                        anchors.verticalCenter: parent.verticalCenter
                        color: kbHover.hovered ? Colors.cSurfaceContainerHigh : "transparent"

                        Behavior on color { ColorAnimation { duration: 180 } }
                        HoverHandler { id: kbHover }

                        Text {
                            id: kbLabel
                            anchors.centerIn: parent
                            text: root.currentLayoutShort
                            color: Colors.cSecondary
                            font.family: Colors.cFontFamily
                            font.pixelSize: 11
                            font.weight: Font.Bold
                            verticalAlignment: Text.AlignVCenter
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.niriAction(["switch-layout", "next"])
                        }
                    }

                    Rectangle {
                        visible: Colors.showScreenshot
                        width: 28
                        height: 26
                        radius: Colors.smallRadius
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.screenshotMenu ? Colors.cPrimaryContainer : (ssHover.hovered ? Colors.cSurfaceContainerHigh : "transparent")

                        Behavior on color { ColorAnimation { duration: 180 } }
                        HoverHandler { id: ssHover }

                        Text {
                            anchors.centerIn: parent
                            text: "󰄀"
                            color: root.screenshotMenu ? Colors.cOnPrimaryContainer : Colors.cOnSurface
                            font.family: Colors.cFontFamily
                            font.pixelSize: 16
                            verticalAlignment: Text.AlignVCenter
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleMenu("screenshot")
                        }
                    }

                    Rectangle {
                        visible: Colors.showWifi
                        width: 28
                        height: 26
                        radius: Colors.smallRadius
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.wifiMenu ? Colors.cPrimaryContainer : (wifiHover.hovered ? Colors.cSurfaceContainerHigh : "transparent")

                        Behavior on color { ColorAnimation { duration: 180 } }
                        HoverHandler { id: wifiHover }

                        Text {
                            anchors.centerIn: parent
                            text: root.ethernetConnected ? "󰈀" : (root.wifiAvailable ? (root.wifiEnabled ? "󰤨" : "󰤭") : "󰤮")
                            color: root.wifiMenu ? Colors.cOnPrimaryContainer : Colors.cOnSurface
                            font.family: Colors.cFontFamily
                            font.pixelSize: 16
                            verticalAlignment: Text.AlignVCenter
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleMenu("wifi")
                        }
                    }

                    Rectangle {
                        visible: Colors.showBluetooth
                        width: 28
                        height: 26
                        radius: Colors.smallRadius
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.bluetoothMenu ? Colors.cPrimaryContainer : (btHover.hovered ? Colors.cSurfaceContainerHigh : "transparent")

                        Behavior on color { ColorAnimation { duration: 180 } }
                        HoverHandler { id: btHover }

                        Text {
                            anchors.centerIn: parent
                            text: root.bluetoothEnabled ? "󰂯" : "󰂲"
                            color: root.bluetoothMenu ? Colors.cOnPrimaryContainer : (root.bluetoothEnabled ? Colors.cOnSurface : Colors.cInactive)
                            font.family: Colors.cFontFamily
                            font.pixelSize: 16
                            verticalAlignment: Text.AlignVCenter
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleMenu("bluetooth")
                        }
                    }

                    Rectangle {
                        visible: Colors.showAudio
                        width: volRow.implicitWidth + 12
                        height: 26
                        radius: Colors.smallRadius
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.audioMenu ? Colors.cPrimaryContainer : (volHover.hovered ? Colors.cSurfaceContainerHigh : "transparent")

                        Behavior on color { ColorAnimation { duration: 180 } }
                        HoverHandler { id: volHover }

                        Row {
                            id: volRow
                            anchors.centerIn: parent
                            spacing: 5

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.outputMuted ? "󰖁" : "󰕾"
                                color: root.audioMenu ? Colors.cOnPrimaryContainer : Colors.cPrimary
                                font.family: Colors.cFontFamily
                                font.pixelSize: 15
                                verticalAlignment: Text.AlignVCenter
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Math.round(root.outputVolume) + "%"
                                color: root.audioMenu ? Colors.cOnPrimaryContainer : Colors.cOnSurface
                                font.family: Colors.cFontFamily
                                font.pixelSize: 11
                                font.weight: Font.Medium
                                verticalAlignment: Text.AlignVCenter
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleMenu("audio")
                            onWheel: wheel => {
                                wheel.accepted = true
                                if (!root.audioSink || !root.audioSink.audio) return
                                let value = root.audioSink.audio.volume
                                value += wheel.angleDelta.y > 0 ? 0.05 : -0.05
                                root.audioSink.audio.volume = Math.max(0, Math.min(1.5, value))
                            }
                        }
                    }

                    Rectangle {
                        width: 28
                        height: 26
                        radius: Colors.smallRadius
                        anchors.verticalCenter: parent.verticalCenter
                        color: settingsWindow.settingsVisible ? Colors.cPrimaryContainer : (setHover.hovered ? Colors.cSurfaceContainerHigh : "transparent")

                        Behavior on color { ColorAnimation { duration: 180 } }
                        HoverHandler { id: setHover }

                        Text {
                            anchors.centerIn: parent
                            text: "󰒓"
                            color: settingsWindow.settingsVisible ? Colors.cOnPrimaryContainer : Colors.cOnSurface
                            font.family: Colors.cFontFamily
                            font.pixelSize: 17
                            verticalAlignment: Text.AlignVCenter
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.closeMenus()
                                popups.closeLauncher()
                                popups.closePower()
                                settingsWindow.toggle()
                            }
                        }
                    }

                    Rectangle {
                        width: 28
                        height: 26
                        radius: Colors.smallRadius
                        anchors.verticalCenter: parent.verticalCenter
                        color: pwrHover.hovered ? Colors.cErrorContainer : "transparent"

                        Behavior on color { ColorAnimation { duration: 180 } }
                        HoverHandler { id: pwrHover }

                        Text {
                            anchors.centerIn: parent
                            text: "⏻"
                            color: Colors.cError
                            font.family: Colors.cFontFamily
                            font.pixelSize: 16
                            verticalAlignment: Text.AlignVCenter
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.closeMenus()
                                settingsWindow.close()
                                popups.togglePower()
                            }
                        }
                    }
                }
            }

            PopupWindow {
                id: calendarPopup
                property real anim: root.calendarMenu ? 1 : 0
                Behavior on anim { NumberAnimation { duration: 260; easing.type: Easing.OutExpo } }

                visible: root.calendarMenu || anim > 0.01
                anchor.window: bar
                anchor.rect.x: Math.round((bar.width - width) / 2)
                anchor.rect.y: 42
                implicitWidth: 340
                implicitHeight: 330
                color: "transparent"

                Rectangle {
                    anchors.fill: parent
                    radius: Colors.uiRadius
                    color: Colors.cSurface
                    border.width: 1
                    border.color: Colors.cOutlineVariant
                    opacity: calendarPopup.anim
                    scale: 0.93 + 0.07 * calendarPopup.anim
                    transform: Translate { y: (1 - calendarPopup.anim) * -10 }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        onWheel: wheel => {
                            if (wheel.angleDelta.y > 0) root.shiftMonth(-1)
                            else if (wheel.angleDelta.y < 0) root.shiftMonth(1)
                        }
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 16
                        spacing: 12

                        RowLayout {
                            Layout.fillWidth: true

                            Rectangle {
                                width: 28
                                height: 28
                                radius: Colors.smallRadius
                                color: prevHover.hovered ? Colors.cSurfaceContainerHighest : Colors.cSurfaceContainer
                                Behavior on color { ColorAnimation { duration: 160 } }
                                HoverHandler { id: prevHover }

                                Text {
                                    anchors.centerIn: parent
                                    text: "‹"
                                    color: Colors.cPrimary
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 18
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.shiftMonth(-1)
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: Qt.formatDate(new Date(root.calYear, root.calMonth, 1), "MMMM yyyy")
                                color: Colors.cOnSurface
                                font.family: Colors.cFontFamily
                                font.pixelSize: 14
                                font.bold: true
                            }

                            Rectangle {
                                width: 28
                                height: 28
                                radius: Colors.smallRadius
                                color: nextHover.hovered ? Colors.cSurfaceContainerHighest : Colors.cSurfaceContainer
                                Behavior on color { ColorAnimation { duration: 160 } }
                                HoverHandler { id: nextHover }

                                Text {
                                    anchors.centerIn: parent
                                    text: "›"
                                    color: Colors.cPrimary
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 18
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.shiftMonth(1)
                                }
                            }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            columns: 7
                            rowSpacing: 6
                            columnSpacing: 6

                            Repeater {
                                model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
                                delegate: Text {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    horizontalAlignment: Text.AlignHCenter
                                    text: modelData
                                    color: Colors.cOnSurfaceVariant
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 11
                                    font.bold: true
                                }
                            }

                            Repeater {
                                model: root.calendarDays(root.calYear, root.calMonth)
                                delegate: Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 34
                                    radius: Colors.smallRadius
                                    color: modelData.isToday ? Colors.cPrimary : (dayHover.hovered && modelData.day !== "" ? Colors.cPrimaryContainer : "transparent")
                                    border.width: dayHover.hovered && modelData.day !== "" && !modelData.isToday ? 1 : 0
                                    border.color: Colors.cPrimary
                                    scale: dayHover.hovered && modelData.day !== "" ? 1.08 : 1.0

                                    Behavior on color { ColorAnimation { duration: 160 } }
                                    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutExpo } }

                                    HoverHandler { id: dayHover }

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.day
                                        color: modelData.isToday ? Colors.cOnPrimary : (dayHover.hovered ? Colors.cOnPrimaryContainer : Colors.cOnSurface)
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 12
                                        font.bold: modelData.isToday || dayHover.hovered
                                    }
                                }
                            }
                        }
                    }
                }
            }

            PopupWindow {
                id: screenshotPopup
                property real anim: root.screenshotMenu ? 1 : 0
                Behavior on anim { NumberAnimation { duration: 240; easing.type: Easing.OutExpo } }

                visible: root.screenshotMenu || anim > 0.01
                anchor.window: bar
                anchor.rect.x: bar.width - width - 140
                anchor.rect.y: 42
                implicitWidth: 210
                implicitHeight: 156
                color: "transparent"

                Rectangle {
                    anchors.fill: parent
                    radius: Colors.uiRadius
                    color: Colors.cSurface
                    border.width: 1
                    border.color: Colors.cOutlineVariant
                    opacity: screenshotPopup.anim
                    scale: 0.93 + 0.07 * screenshotPopup.anim
                    transform: Translate { y: (1 - screenshotPopup.anim) * -10 }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 6

                        Repeater {
                            model: [
                                { label: "Area", icon: "󰩭", action: "screenshot" },
                                { label: "Full Screen", icon: "󰹑", action: "screenshot-screen" },
                                { label: "Active Window", icon: "󰖯", action: "screenshot-window" }
                            ]

                            delegate: Rectangle {
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                radius: Colors.smallRadius
                                color: ssItemHover.hovered ? Colors.cPrimaryContainer : Colors.cSurfaceContainer

                                Behavior on color { ColorAnimation { duration: 160 } }
                                HoverHandler { id: ssItemHover }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10
                                    spacing: 10

                                    Text {
                                        text: modelData.icon
                                        color: ssItemHover.hovered ? Colors.cOnPrimaryContainer : Colors.cPrimary
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 16
                                    }

                                    Text {
                                        text: modelData.label
                                        color: ssItemHover.hovered ? Colors.cOnPrimaryContainer : Colors.cOnSurface
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 11
                                        font.bold: true
                                        Layout.fillWidth: true
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.closeMenus()
                                        root.niriAction([modelData.action])
                                    }
                                }
                            }
                        }
                    }
                }
            }

            PopupWindow {
                id: wifiPopup
                property real anim: root.wifiMenu ? 1 : 0
                Behavior on anim { NumberAnimation { duration: 260; easing.type: Easing.OutExpo } }

                visible: root.wifiMenu || anim > 0.01
                anchor.window: bar
                anchor.rect.x: bar.width - width - 110
                anchor.rect.y: 42
                implicitWidth: 310
                implicitHeight: 410
                color: "transparent"

                Rectangle {
                    anchors.fill: parent
                    radius: Colors.uiRadius
                    color: Colors.cSurface
                    border.width: 1
                    border.color: Colors.cOutlineVariant
                    opacity: wifiPopup.anim
                    scale: 0.93 + 0.07 * wifiPopup.anim
                    transform: Translate { y: (1 - wifiPopup.anim) * -10 }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 10

                        RowLayout {
                            Layout.fillWidth: true

                            Text {
                                text: "Network"
                                color: Colors.cOnSurface
                                font.family: Colors.cFontFamily
                                font.pixelSize: 15
                                font.bold: true
                                Layout.fillWidth: true
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 3
                            radius: 1.5
                            color: Colors.cSurfaceContainerHighest
                            visible: root.wifiBusy
                            clip: true

                            Rectangle {
                                id: busyBar
                                width: parent.width * 0.4
                                height: parent.height
                                radius: 1.5
                                color: Colors.cPrimary

                                SequentialAnimation on x {
                                    running: root.wifiBusy
                                    loops: Animation.Infinite
                                    NumberAnimation { from: -busyBar.width; to: busyBar.parent.width; duration: 900; easing.type: Easing.InOutQuad }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            visible: root.ethernetDevice.length > 0

                            Text {
                                text: "󰈀  Ethernet"
                                color: Colors.cOnSurface
                                font.family: Colors.cFontFamily
                                font.pixelSize: 12
                                Layout.fillWidth: true
                            }

                            M3Switch {
                                checked: root.ethernetConnected
                                enabled: !root.wifiBusy
                                onToggled: root.toggleEthernet()
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            visible: root.wifiAvailable

                            Text {
                                text: "󰤨  Wi-Fi"
                                color: Colors.cOnSurface
                                font.family: Colors.cFontFamily
                                font.pixelSize: 12
                                Layout.fillWidth: true
                            }

                            M3Switch {
                                checked: root.wifiEnabled
                                enabled: !root.wifiBusy
                                onToggled: root.toggleWifi()
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 34
                            radius: Colors.smallRadius
                            visible: root.wifiAvailable && root.wifiEnabled
                            color: scanBtnHover.hovered ? Colors.cPrimaryContainer : Colors.cSurfaceContainerHigh
                            Behavior on color { ColorAnimation { duration: 160 } }
                            HoverHandler { id: scanBtnHover }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 10

                                Text {
                                    text: "󰍉"
                                    color: scanBtnHover.hovered ? Colors.cOnPrimaryContainer : Colors.cPrimary
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 15
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: root.wifiBusy ? "Working..." : "Scan networks"
                                    color: scanBtnHover.hovered ? Colors.cOnPrimaryContainer : Colors.cOnSurface
                                    font.family: Colors.cFontFamily
                                    font.pixelSize: 10
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                enabled: !root.wifiBusy
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.scanWifi()
                            }
                        }

                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 5
                            visible: root.wifiAvailable
                            model: root.wifiEnabled ? root.wifiNetworks : []

                            delegate: Rectangle {
                                required property var modelData
                                width: ListView.view.width
                                height: 40
                                radius: Colors.smallRadius
                                color: modelData.connected ? Colors.cPrimaryContainer : (wItemHover.hovered ? Colors.cSurfaceContainerHigh : Colors.cSurfaceContainer)
                                Behavior on color { ColorAnimation { duration: 150 } }
                                HoverHandler { id: wItemHover }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10

                                    Text {
                                        text: "󰤨"
                                        color: modelData.connected ? Colors.cOnPrimaryContainer : Colors.cPrimary
                                        font.family: Colors.cFontFamily
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.ssid
                                        color: modelData.connected ? Colors.cOnPrimaryContainer : Colors.cOnSurface
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 10
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        text: modelData.signal + "%"
                                        color: modelData.connected ? Colors.cOnPrimaryContainer : Colors.cOnSurfaceVariant
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 9
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: root.wifiEnabled && !root.wifiBusy
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.connectWifi(modelData.ssid)
                                }
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: root.wifiAvailable && (!root.wifiEnabled || root.wifiNetworks.length === 0)
                            text: root.wifiEnabled ? "No networks found" : "Wi-Fi is turned off"
                            color: Colors.cInactive
                            font.family: Colors.cFontFamily
                            font.pixelSize: 10
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }
            }

            PopupWindow {
                id: bluetoothPopup
                property real anim: root.bluetoothMenu ? 1 : 0
                Behavior on anim { NumberAnimation { duration: 260; easing.type: Easing.OutExpo } }

                visible: root.bluetoothMenu || anim > 0.01
                anchor.window: bar
                anchor.rect.x: bar.width - width - 70
                anchor.rect.y: 42
                implicitWidth: 300
                implicitHeight: 330
                color: "transparent"

                Rectangle {
                    anchors.fill: parent
                    radius: Colors.uiRadius
                    color: Colors.cSurface
                    border.width: 1
                    border.color: Colors.cOutlineVariant
                    opacity: bluetoothPopup.anim
                    scale: 0.93 + 0.07 * bluetoothPopup.anim
                    transform: Translate { y: (1 - bluetoothPopup.anim) * -10 }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 10

                        RowLayout {
                            Layout.fillWidth: true

                            Text {
                                text: "Bluetooth"
                                color: Colors.cOnSurface
                                font.family: Colors.cFontFamily
                                font.pixelSize: 15
                                font.bold: true
                            }

                            Item { Layout.fillWidth: true }

                            M3Switch {
                                checked: root.bluetoothEnabled
                                onToggled: root.toggleBluetooth()
                            }
                        }

                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 5
                            model: root.bluetoothDevices

                            delegate: Rectangle {
                                required property var modelData
                                width: ListView.view.width
                                height: 40
                                radius: Colors.smallRadius
                                color: bItemHover.hovered ? Colors.cSurfaceContainerHigh : Colors.cSurfaceContainer
                                Behavior on color { ColorAnimation { duration: 150 } }
                                HoverHandler { id: bItemHover }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10

                                    Text {
                                        text: "󰂯"
                                        color: Colors.cPrimary
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 16
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.name
                                        color: Colors.cOnSurface
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 10
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        text: "→"
                                        color: Colors.cPrimary
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    enabled: root.bluetoothEnabled
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.connectBluetooth(modelData.address)
                                }
                            }
                        }

                        Text {
                            visible: root.bluetoothDevices.length === 0
                            text: "No paired devices"
                            color: Colors.cInactive
                            font.family: Colors.cFontFamily
                            font.pixelSize: 10
                        }
                    }
                }
            }

            PopupWindow {
                id: audioPopup
                property real anim: root.audioMenu ? 1 : 0
                Behavior on anim { NumberAnimation { duration: 260; easing.type: Easing.OutExpo } }

                visible: root.audioMenu || anim > 0.01
                anchor.window: bar
                anchor.rect.x: bar.width - width - 16
                anchor.rect.y: 42
                implicitWidth: 340
                implicitHeight: 400
                color: "transparent"

                Rectangle {
                    anchors.fill: parent
                    radius: Colors.uiRadius
                    color: Colors.cSurface
                    border.width: 1
                    border.color: Colors.cOutlineVariant
                    opacity: audioPopup.anim
                    scale: 0.93 + 0.07 * audioPopup.anim
                    transform: Translate { y: (1 - audioPopup.anim) * -10 }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 10

                        RowLayout {
                            Layout.fillWidth: true

                            Text {
                                text: "Sound & Audio"
                                color: Colors.cOnSurface
                                font.family: Colors.cFontFamily
                                font.pixelSize: 15
                                font.bold: true
                                Layout.fillWidth: true
                            }

                            Text {
                                text: "✕"
                                color: Colors.cOnSurfaceVariant
                                font.family: Colors.cFontFamily
                                font.pixelSize: 14
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.closeMenus()
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: "󰕾  Output"
                                color: Colors.cOnSurface
                                font.family: Colors.cFontFamily
                                font.pixelSize: 11
                                Layout.fillWidth: true
                            }
                            Text {
                                text: Math.round(root.outputVolume) + "%"
                                color: Colors.cPrimary
                                font.family: Colors.cFontFamily
                                font.pixelSize: 11
                                font.bold: true
                            }
                        }

                        M3Slider {
                            Layout.fillWidth: true
                            from: 0
                            to: 150
                            value: root.outputVolume
                            enabled: !!root.audioSink && !!root.audioSink.audio

                            onMoved: {
                                if (root.audioSink && root.audioSink.audio)
                                    root.audioSink.audio.volume = value / 100
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true

                            Text {
                                Layout.fillWidth: true
                                text: root.audioSink ? (root.audioSink.description || root.audioSink.name) : "No audio output"
                                color: Colors.cOnSurfaceVariant
                                font.family: Colors.cFontFamily
                                font.pixelSize: 9
                                elide: Text.ElideRight
                            }

                            M3Switch {
                                checked: !root.outputMuted
                                enabled: !!root.audioSink && !!root.audioSink.audio
                                onToggled: val => root.audioSink.audio.muted = !val
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            height: 1
                            color: Colors.cOutlineVariant
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: "󰍬  Microphone"
                                color: Colors.cOnSurface
                                font.family: Colors.cFontFamily
                                font.pixelSize: 11
                                Layout.fillWidth: true
                            }
                            Text {
                                text: Math.round(root.inputVolume) + "%"
                                color: Colors.cPrimary
                                font.family: Colors.cFontFamily
                                font.pixelSize: 11
                                font.bold: true
                            }
                        }

                        M3Slider {
                            Layout.fillWidth: true
                            from: 0
                            to: 150
                            value: root.inputVolume
                            enabled: !!root.audioSource && !!root.audioSource.audio

                            onMoved: {
                                if (root.audioSource && root.audioSource.audio)
                                    root.audioSource.audio.volume = value / 100
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true

                            Text {
                                Layout.fillWidth: true
                                text: root.audioSource ? (root.audioSource.description || root.audioSource.name) : "No microphone"
                                color: Colors.cOnSurfaceVariant
                                font.family: Colors.cFontFamily
                                font.pixelSize: 9
                                elide: Text.ElideRight
                            }

                            M3Switch {
                                checked: !root.inputMuted
                                enabled: !!root.audioSource && !!root.audioSource.audio
                                onToggled: val => root.audioSource.audio.muted = !val
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            height: 1
                            color: Colors.cOutlineVariant
                        }

                        Text {
                            text: "Output devices"
                            color: Colors.cOnSurfaceVariant
                            font.family: Colors.cFontFamily
                            font.pixelSize: 10
                        }

                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            spacing: 5
                            model: Pipewire.nodes.values.filter(node => node.isSink && !node.isStream)

                            delegate: Rectangle {
                                required property var modelData
                                property bool isCurrent: root.audioSink && root.audioSink.id === modelData.id
                                width: ListView.view.width
                                height: 36
                                radius: Colors.smallRadius
                                color: isCurrent ? Colors.cPrimaryContainer : (sinkItemHover.hovered ? Colors.cSurfaceContainerHigh : Colors.cSurfaceContainer)

                                Behavior on color { ColorAnimation { duration: 150 } }
                                HoverHandler { id: sinkItemHover }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10

                                    Text {
                                        text: "󰓃"
                                        color: isCurrent ? Colors.cOnPrimaryContainer : Colors.cPrimary
                                        font.family: Colors.cFontFamily
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.description || modelData.name
                                        color: isCurrent ? Colors.cOnPrimaryContainer : Colors.cOnSurface
                                        font.family: Colors.cFontFamily
                                        font.pixelSize: 9
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        visible: isCurrent
                                        text: "✓"
                                        color: Colors.cOnPrimaryContainer
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Pipewire.preferredDefaultAudioSink = modelData
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
