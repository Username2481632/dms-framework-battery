import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "dmsFrameworkBattery"

    property bool showTimeRemaining: pluginData.showTimeRemaining ?? false
    property bool showWatts: pluginData.showWatts ?? false
    property bool showChargeLimit: pluginData.showChargeLimit ?? true

    readonly property var presets: [50, 60, 70, 80, 90, 100]
    // The EC rejects a limit below 20; ectool passes anything through
    readonly property int minimumLimit: 20

    // The limit as the EC last reported it; -1 until the first read succeeds
    property int chargeLimit: -1
    property int pendingLimit: -1
    property string limitError: ""
    property int _exitCode: -1
    readonly property bool busy: ecProcess.running
    readonly property int shownLimit: pendingLimit >= 0 ? pendingLimit : chargeLimit
    readonly property bool limiting: showChargeLimit && chargeLimit > 0 && chargeLimit < 100

    // null follows the limit itself; "preset" or "custom" is the user's pick while the popout is open
    property var limitMode: null
    readonly property bool customMode: limitMode !== null ? limitMode === "custom" : (shownLimit > 0 && !presets.includes(shownLimit))

    readonly property real rate: BatteryService.signedChangeRate
    readonly property bool holding: BatteryService.isPluggedIn && rate === 0 && limiting
    readonly property string powerText: rate === 0 ? "" : (rate > 0 ? "+" : "−") + Math.abs(rate).toFixed(1) + " W"

    // DMS's own smoothed estimate runs to 100%; while a limit applies, charging stops
    // at the limit, so the estimate is scaled to the share of the remaining energy
    // that lies below it.
    readonly property string timeText: {
        if (rate < 0) {
            const left = BatteryService.formatTimeRemaining();
            return left === "Unknown" ? "" : left;
        }
        if (rate > 0) {
            const toFull = BatteryService.estimatedSeconds();
            const capacity = BatteryService.batteryCapacity;
            const energy = BatteryService.batteryEnergy;
            const target = (limiting ? chargeLimit : 100) / 100 * capacity;
            if (!toFull || capacity <= energy || target <= energy)
                return "";
            return BatteryService.formatDuration(toFull * (target - energy) / (capacity - energy));
        }
        return "";
    }

    // The EC holds the charge between five points under the limit and the limit, and
    // drains the battery on AC when it is above it.
    readonly property string statusText: {
        if (holding)
            return "Held at the " + chargeLimit + "% limit";
        if (BatteryService.isPluggedIn && rate < 0 && limiting)
            return "Draining to the " + chargeLimit + "% limit";
        if (rate > 0 && timeText)
            return "Charging · " + timeText + (limiting ? " to " + chargeLimit + "%" : " to full");
        if (rate < 0 && timeText)
            return "Discharging · " + timeText + " left";
        return BatteryService.batteryStatus;
    }

    readonly property color levelColor: {
        if (BatteryService.isLowBattery && !BatteryService.isCharging)
            return Theme.error;
        if (BatteryService.isCharging || BatteryService.isPluggedIn)
            return Theme.primary;
        return Theme.surfaceText;
    }

    readonly property var stats: [
        {
            "label": "Health",
            "value": BatteryService.batteryHealth
        },
        {
            "label": "Capacity",
            "value": BatteryService.batteryCapacity > 0 ? BatteryService.batteryCapacity.toFixed(1) + " Wh" : "N/A"
        },
        {
            "label": "Power",
            "value": powerText || "0 W"
        }
    ]

    // `ectool fwchargelimit [N]` sets the limit when given one and always prints the
    // limit the EC holds afterwards, so a write reports its own outcome.
    function runEc(limit) {
        if (ecProcess.running)
            return;
        pendingLimit = limit ?? -1;
        _exitCode = -1;
        ecProcess.command = ["pkexec", "ectool", "fwchargelimit"].concat(limit !== undefined ? [String(limit)] : []);
        ecProcess.running = true;
    }

    function setChargeLimit(limit) {
        limitMode = null;
        runEc(limit);
    }

    function finishEc() {
        const out = stdoutCollector.text.trim();
        const detail = stderrCollector.text.trim() || out;
        const action = pendingLimit >= 0 ? "set the charge limit to " + pendingLimit + "%" : "read the charge limit";
        pendingLimit = -1;
        if (_exitCode === 0 && /^\d+$/.test(out)) {
            chargeLimit = parseInt(out);
            limitError = "";
            return;
        }
        switch (_exitCode) {
        case -1:
            limitError = "Couldn't " + action + ": pkexec could not be started.";
            break;
        case 126:
            limitError = "Couldn't " + action + ": authentication was dismissed.";
            break;
        case 127:
            limitError = "Couldn't " + action + ": pkexec refused, or ectool is missing" + (detail ? " (" + detail + ")" : "") + ".";
            break;
        default:
            limitError = "Couldn't " + action + (detail ? ": " + detail : " (exit " + _exitCode + ")") + ".";
        }
    }

    // Quickshell ends both output streams before `exited`, and `running` turns false
    // after it — or alone, when the command could not be started at all.
    Process {
        id: ecProcess
        stdout: StdioCollector {
            id: stdoutCollector
        }
        stderr: StdioCollector {
            id: stderrCollector
        }
        onExited: exitCode => root._exitCode = exitCode
        onRunningChanged: {
            if (!running)
                root.finishEc();
        }
    }

    function setProfile(profile) {
        if (!PowerProfileWatcher.applyProfile(profile))
            ToastService.showError(PowerProfileWatcher.available ? "Failed to set power profile" : "power-profiles-daemon not available");
    }

    // The limit is read when the widget loads and again whenever the popout opens, so
    // what it shows is what the EC holds even after something else has changed it.
    Component.onCompleted: {
        if (showChargeLimit)
            runEc();
    }

    onInteractionActiveChanged: {
        if (!interactionActive) {
            limitMode = null;
            return;
        }
        if (showChargeLimit)
            runEc();
    }

    horizontalBarPill: Component {
        RowLayout {
            spacing: Theme.spacingXS

            DIcon {
                name: BatteryService.getBatteryIcon()
                size: Theme.iconSizeSmall
                color: root.levelColor
            }

            StyledText {
                text: Math.round(BatteryService.batteryLevel) + "%"
                font.pixelSize: Theme.fontSizeSmall
            }

            StyledText {
                text: root.timeText
                visible: root.showTimeRemaining && root.timeText !== ""
                opacity: 0.7
                font.pixelSize: Theme.fontSizeSmall
            }

            StyledText {
                text: root.powerText
                visible: root.showWatts && root.powerText !== ""
                opacity: 0.7
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

    verticalBarPill: Component {
        ColumnLayout {
            spacing: Theme.spacingXS

            DIcon {
                name: BatteryService.getBatteryIcon()
                size: Theme.iconSizeSmall
                color: root.levelColor
                Layout.alignment: Qt.AlignHCenter
            }

            StyledText {
                text: Math.round(BatteryService.batteryLevel) + "%"
                font.pixelSize: Theme.fontSizeSmall
                Layout.alignment: Qt.AlignHCenter
            }

            StyledText {
                text: root.powerText
                visible: root.showWatts && root.powerText !== ""
                opacity: 0.7
                font.pixelSize: Theme.fontSizeSmall
                Layout.alignment: Qt.AlignHCenter
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            Item {
                width: parent.width
                implicitHeight: content.implicitHeight + Theme.spacingL * 2

                ColumnLayout {
                    id: content

                    x: Theme.spacingL
                    y: Theme.spacingL
                    width: parent.width - Theme.spacingL * 2
                    spacing: Theme.spacingL

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingM

                        DIcon {
                            name: BatteryService.getBatteryIcon()
                            size: Theme.iconSizeLarge
                            color: root.levelColor
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingXS

                            StyledText {
                                text: Math.round(BatteryService.batteryLevel) + "%"
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Bold
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: root.statusText
                                font.pixelSize: Theme.fontSizeSmall
                                opacity: 0.7
                                elide: Text.ElideRight
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingM

                        Repeater {
                            model: root.stats

                            StyledRect {
                                required property var modelData

                                Layout.fillWidth: true
                                Layout.minimumWidth: 90
                                Layout.preferredHeight: 90
                                color: Theme.surfaceContainerHighest
                                radius: Theme.cornerRadius
                                border.width: 1
                                border.color: Theme.surfaceContainerHigh

                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: Theme.spacingXS

                                    StyledText {
                                        text: modelData.label
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.primary
                                        Layout.alignment: Qt.AlignHCenter
                                    }

                                    StyledText {
                                        text: modelData.value
                                        font.pixelSize: Theme.fontSizeLarge
                                        font.weight: Font.Bold
                                        Layout.alignment: Qt.AlignHCenter
                                    }
                                }
                            }
                        }
                    }

                    DButtonGroup {
                        readonly property var profiles: PowerProfileWatcher.availableProfiles

                        Layout.fillWidth: true
                        fillWidth: true
                        visible: PowerProfileWatcher.available
                        model: profiles.map(profile => Theme.getPowerProfileLabel(profile))
                        currentIndex: profiles.indexOf(PowerProfileWatcher.currentProfile)
                        selectionMode: "single"
                        onSelectionChanged: (index, selected) => {
                            if (selected)
                                root.setProfile(profiles[index]);
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingL
                        visible: root.showChargeLimit

                        RowLayout {
                            spacing: Theme.spacingS

                            DIcon {
                                name: "battery_change"
                                size: Theme.iconSize
                            }

                            StyledText {
                                text: "Charge limit"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Bold
                            }
                        }

                        DButtonGroup {
                            Layout.fillWidth: true
                            fillWidth: true
                            model: ["Preset", "Custom"]
                            currentIndex: root.customMode ? 1 : 0
                            selectionMode: "single"
                            onSelectionChanged: (index, selected) => {
                                if (selected)
                                    root.limitMode = index === 1 ? "custom" : "preset";
                            }
                        }

                        DButtonGroup {
                            Layout.fillWidth: true
                            fillWidth: true
                            checkEnabled: false
                            visible: !root.customMode
                            enabled: !root.busy
                            model: root.presets.map(limit => limit + "%")
                            currentIndex: root.presets.indexOf(root.shownLimit)
                            selectionMode: "single"
                            onSelectionChanged: (index, selected) => {
                                if (selected && root.presets[index] !== root.shownLimit)
                                    root.setChargeLimit(root.presets[index]);
                            }
                        }

                        RowLayout {
                            spacing: Theme.spacingL
                            visible: root.customMode

                            DTextField {
                                id: customLimitField

                                readonly property int value: parseInt(text)
                                readonly property bool valid: value >= root.minimumLimit && value <= 100

                                Layout.preferredWidth: 120
                                text: root.shownLimit > 0 ? String(root.shownLimit) : ""
                                placeholderText: root.minimumLimit + "–100"
                                validator: IntValidator {
                                    bottom: 0
                                    top: 100
                                }
                                isError: text !== "" && !valid
                                onAccepted: {
                                    if (valid && value !== root.chargeLimit && !root.busy)
                                        root.setChargeLimit(value);
                                }

                                Connections {
                                    target: root
                                    function onShownLimitChanged() {
                                        if (root.shownLimit > 0)
                                            customLimitField.text = String(root.shownLimit);
                                    }
                                }
                            }

                            DButton {
                                text: "Apply"
                                iconName: "check"
                                busy: root.busy
                                enabled: customLimitField.valid && customLimitField.value !== root.chargeLimit && !root.busy
                                onClicked: root.setChargeLimit(customLimitField.value)
                            }
                        }

                        StyledText {
                            Layout.fillWidth: true
                            visible: root.limitError !== ""
                            text: root.limitError
                            color: Theme.error
                            font.pixelSize: Theme.fontSizeSmall
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 450
}
