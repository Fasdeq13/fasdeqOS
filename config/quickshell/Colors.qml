pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: colorsRoot

    property bool settingsLoaded: false

    property string currentTheme: "mono"
    property int uiRadius: 8
    readonly property int smallRadius: Math.max(2, Math.round(uiRadius * 0.65))
    property int launcherWidth: 580
    property int launcherHeight: 520

    property bool showWorkspaces: true
    property bool showClock: true
    property bool showTray: true
    property bool showLayout: true
    property bool showWifi: true
    property bool showBluetooth: true
    property bool showAudio: true
    property bool showScreenshot: true

    readonly property var themeList: [
        { "id": "mono", "name": "Mono", "preview": "#E6E6E6" },
        { "id": "sunset", "name": "Sunset", "preview": "#FF713D" },
        { "id": "crimson", "name": "Crimson", "preview": "#FF5277" },
        { "id": "emerald", "name": "Emerald", "preview": "#4CD98B" },
        { "id": "ocean", "name": "Ocean", "preview": "#5CB8FF" },
        { "id": "amethyst", "name": "Amethyst", "preview": "#B388FF" }
    ]

    property Timer saveTimer: Timer {
        interval: 250
        repeat: false
        onTriggered: colorsRoot.writeSettings()
    }

    property Process loadProc: Process {
        command: ["bash", "-c", "cat \"\$HOME/.config/quickshell/settings.json\" 2>/dev/null || echo '{}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let data = JSON.parse(text.trim() || "{}")
                    if (typeof data.currentTheme === "string") colorsRoot.currentTheme = data.currentTheme
                    if (typeof data.uiRadius === "number") colorsRoot.uiRadius = data.uiRadius
                    if (typeof data.launcherWidth === "number") colorsRoot.launcherWidth = data.launcherWidth
                    if (typeof data.launcherHeight === "number") colorsRoot.launcherHeight = data.launcherHeight
                    if (typeof data.showWorkspaces === "boolean") colorsRoot.showWorkspaces = data.showWorkspaces
                    if (typeof data.showClock === "boolean") colorsRoot.showClock = data.showClock
                    if (typeof data.showTray === "boolean") colorsRoot.showTray = data.showTray
                    if (typeof data.showLayout === "boolean") colorsRoot.showLayout = data.showLayout
                    if (typeof data.showWifi === "boolean") colorsRoot.showWifi = data.showWifi
                    if (typeof data.showBluetooth === "boolean") colorsRoot.showBluetooth = data.showBluetooth
                    if (typeof data.showAudio === "boolean") colorsRoot.showAudio = data.showAudio
                    if (typeof data.showScreenshot === "boolean") colorsRoot.showScreenshot = data.showScreenshot
                } catch (e) {}
                colorsRoot.settingsLoaded = true
                colorsRoot.syncNiriColors()
            }
        }
    }

    function scheduleSave() {
        if (settingsLoaded)
            saveTimer.restart()
    }

    function writeSettings() {
        let obj = {
            "currentTheme": currentTheme,
            "uiRadius": uiRadius,
            "launcherWidth": launcherWidth,
            "launcherHeight": launcherHeight,
            "showWorkspaces": showWorkspaces,
            "showClock": showClock,
            "showTray": showTray,
            "showLayout": showLayout,
            "showWifi": showWifi,
            "showBluetooth": showBluetooth,
            "showAudio": showAudio,
            "showScreenshot": showScreenshot
        }
        let jsonStr = JSON.stringify(obj, null, 2)
        let script = "mkdir -p \"$HOME/.config/quickshell\" && cat << 'EOF' > \"$HOME/.config/quickshell/settings.json\"\n" + jsonStr + "\nEOF\n"
        Quickshell.execDetached(["bash", "-c", script])
    }

    function paletteFor(theme) {
        if (theme === "sunset") {
            return {
                "bg": "#160D0B", "surf": "#21130F", "cont": "#2B1913", "high": "#382018", "highest": "#48271C", "variant": "#593125",
                "pri": "#FF713D", "priDim": "#E9582D", "priCont": "#78321F", "onPri": "#2C0D05", "onPriCont": "#FFD5C4",
                "sec": "#FFA17D", "secCont": "#653727", "ter": "#FFBD70", "terCont": "#63401F",
                "err": "#FF5449", "errCont": "#70251F", "onBg": "#FFE0D3", "onSurf": "#FFE0D3", "onSurfVar": "#D9AC98",
                "out": "#8C5743", "outVar": "#503126", "inact": "#9C7160"
            }
        }
        if (theme === "crimson") {
            return {
                "bg": "#160B0E", "surf": "#211015", "cont": "#2C161D", "high": "#391D26", "highest": "#492430", "variant": "#5A2E3C",
                "pri": "#FF5277", "priDim": "#E03E63", "priCont": "#7A1F38", "onPri": "#2E0712", "onPriCont": "#FFD6DF",
                "sec": "#FF94AA", "secCont": "#662839", "ter": "#FFB27D", "terCont": "#63381F",
                "err": "#FF5449", "errCont": "#70251F", "onBg": "#FFE0E6", "onSurf": "#FFE0E6", "onSurfVar": "#D9A8B3",
                "out": "#8C4D5D", "outVar": "#502A34", "inact": "#9C6B77"
            }
        }
        if (theme === "emerald") {
            return {
                "bg": "#0B1510", "surf": "#112018", "cont": "#172B20", "high": "#1E382A", "highest": "#264735", "variant": "#305943",
                "pri": "#4CD98B", "priDim": "#36B871", "priCont": "#175C37", "onPri": "#052614", "onPriCont": "#C8F7DC",
                "sec": "#8CE6B4", "secCont": "#224F37", "ter": "#A3D977", "terCont": "#385222",
                "err": "#FF5449", "errCont": "#70251F", "onBg": "#DCF5E7", "onSurf": "#DCF5E7", "onSurfVar": "#A3CCB5",
                "out": "#4D8065", "outVar": "#2A4A39", "inact": "#6B947E"
            }
        }
        if (theme === "ocean") {
            return {
                "bg": "#0B1117", "surf": "#101A24", "cont": "#162432", "high": "#1D2F42", "highest": "#253C54", "variant": "#2F4C69",
                "pri": "#5CB8FF", "priDim": "#3D9CE6", "priCont": "#1A4B75", "onPri": "#051E33", "onPriCont": "#D1EBFF",
                "sec": "#94D1FF", "secCont": "#24435E", "ter": "#7CE0D3", "terCont": "#1F524C",
                "err": "#FF5449", "errCont": "#70251F", "onBg": "#DCEEFF", "onSurf": "#DCEEFF", "onSurfVar": "#A3C2DB",
                "out": "#4D6F8C", "outVar": "#2A4052", "inact": "#6B879E"
            }
        }
        if (theme === "amethyst") {
            return {
                "bg": "#110D17", "surf": "#1A1324", "cont": "#231A30", "high": "#2E2240", "highest": "#3B2C52", "variant": "#4A3766",
                "pri": "#B388FF", "priDim": "#9666EB", "priCont": "#4A2B80", "onPri": "#1E0942", "onPriCont": "#E8DCFF",
                "sec": "#CCB0FF", "secCont": "#3F2B63", "ter": "#F299D4", "terCont": "#5E2B4D",
                "err": "#FF5449", "errCont": "#70251F", "onBg": "#ECE3FF", "onSurf": "#ECE3FF", "onSurfVar": "#C2B2DB",
                "out": "#6D598C", "outVar": "#3E3152", "inact": "#85749E"
            }
        }
        return {
            "bg": "#0E0E0E", "surf": "#161616", "cont": "#1F1F1F", "high": "#2A2A2A", "highest": "#363636", "variant": "#424242",
            "pri": "#F2F2F2", "priDim": "#CCCCCC", "priCont": "#3A3A3A", "onPri": "#111111", "onPriCont": "#FFFFFF",
            "sec": "#BDBDBD", "secCont": "#2E2E2E", "ter": "#9E9E9E", "terCont": "#282828",
            "err": "#FF5449", "errCont": "#521E1B", "onBg": "#F0F0F0", "onSurf": "#F0F0F0", "onSurfVar": "#A8A8A8",
            "out": "#666666", "outVar": "#333333", "inact": "#777777"
        }
    }

    function syncNiriColors() {
        let pal = paletteFor(currentTheme)
        let script = "mkdir -p \"$HOME/.config/niri\" && cat << 'EOF' > \"$HOME/.config/niri/colors.kdl\"\n" +
                     "layout {\n" +
                     "    focus-ring {\n" +
                     "        active-color \"" + pal.pri + "\"\n" +
                     "        inactive-color \"" + pal.outVar + "\"\n" +
                     "    }\n" +
                     "    border {\n" +
                     "        active-color \"" + pal.pri + "\"\n" +
                     "        inactive-color \"" + pal.outVar + "\"\n" +
                     "    }\n" +
                     "}\n" +
                     "EOF\n" +
                     "niri msg action load-config-file >/dev/null 2>&1 || touch \"\$HOME/.config/niri/config.kdl\"\n"
        Quickshell.execDetached(["bash", "-c", script])
    }

    onCurrentThemeChanged: {
        if (settingsLoaded) {
            syncNiriColors()
            scheduleSave()
        }
    }
    onUiRadiusChanged: scheduleSave()
    onLauncherWidthChanged: scheduleSave()
    onLauncherHeightChanged: scheduleSave()
    onShowWorkspacesChanged: scheduleSave()
    onShowClockChanged: scheduleSave()
    onShowTrayChanged: scheduleSave()
    onShowLayoutChanged: scheduleSave()
    onShowWifiChanged: scheduleSave()
    onShowBluetoothChanged: scheduleSave()
    onShowAudioChanged: scheduleSave()
    onShowScreenshotChanged: scheduleSave()

    Component.onCompleted: {
        loadProc.running = true
    }

    readonly property var p: paletteFor(currentTheme)

    readonly property color cBackground: p.bg
    readonly property color cSurface: p.surf
    readonly property color cSurfaceContainer: p.cont
    readonly property color cSurfaceContainerHigh: p.high
    readonly property color cSurfaceContainerHighest: p.highest
    readonly property color cSurfaceVariant: p.variant

    readonly property color cPrimary: p.pri
    readonly property color cPrimaryDim: p.priDim
    readonly property color cPrimaryContainer: p.priCont
    readonly property color cOnPrimary: p.onPri
    readonly property color cOnPrimaryContainer: p.onPriCont

    readonly property color cSecondary: p.sec
    readonly property color cSecondaryContainer: p.secCont
    readonly property color cTertiary: p.ter
    readonly property color cTertiaryContainer: p.terCont

    readonly property color cError: p.err
    readonly property color cErrorContainer: p.errCont

    readonly property color cOnBackground: p.onBg
    readonly property color cOnSurface: p.onSurf
    readonly property color cOnSurfaceVariant: p.onSurfVar

    readonly property color cOutline: p.out
    readonly property color cOutlineVariant: p.outVar

    readonly property color cOverlay: "#B3000000"

    readonly property color cActive: p.pri
    readonly property color cInactive: p.inact
    readonly property color cSuccess: "#C5D99A"

    readonly property string cFontFamily: "JetBrainsMono Nerd Font"
}
