import SwiftUI
import NitsCore

/// The menu-bar panel. Deliberately plain: this is a system utility, so it should
/// read as part of macOS rather than announce itself.
struct ControlPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.displays.isEmpty {
                Text("No displays found")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
                    if index > 0 { Divider().padding(.vertical, 10) }
                    DisplaySectionView(display: display)
                }
            }

            Divider().padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Restore levels on connect", isOn: $model.restoreOnConnect)
                    .toggleStyle(.checkbox)
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .toggleStyle(.checkbox)
                HStack(spacing: 6) {
                    Text("Key step")
                    Picker("Key step", selection: $model.keyStep) {
                        ForEach(KeyStep.allCases, id: \.self) { step in
                            Text(step.label).tag(step)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }
                .padding(.top, 2)
                .help("How far one brightness or volume key press moves. "
                      + "Shift+Option is always a quarter of this.")

                if model.launchAtLoginNeedsApproval {
                    Text("Approve nits in System Settings › General › Login Items.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if !model.hasAccessibilityPermission {
                    // Without the grant macOS keeps the keys, and nits only mirrors them.
                    Button("Grant Accessibility so nits handles the keyboard keys…") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            }
            .font(.system(size: 11))
            .padding(.top, 10)

            HStack {
                Button("Quit nits") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 10)
        }
        .padding(14)
        .frame(width: 290)
    }
}

private struct DisplaySectionView: View {
    @ObservedObject var display: DisplayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(display.name)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(display.backendSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if display.canSetBrightness {
                SliderRow(
                    systemImage: "sun.max.fill",
                    value: Binding(
                        get: { display.brightness },
                        set: { display.setBrightness($0) }),
                    onEditingChanged: { editing in
                        editing ? display.beginEditing() : display.endEditing()
                    })
            }

            if display.canSetContrast {
                SliderRow(
                    systemImage: "circle.righthalf.filled",
                    value: Binding(
                        get: { display.contrast },
                        set: { display.setContrast($0) }),
                    onEditingChanged: { editing in
                        editing ? display.beginEditing() : display.endEditing()
                    })
            }

            if display.canSetVolume {
                HStack(spacing: 8) {
                    Button {
                        display.toggleMute()
                    } label: {
                        Image(systemName: display.isMuted
                              ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(display.isMuted ? .secondary : .primary)
                    .help(display.isMuted ? "Unmute" : "Mute")

                    Slider(
                        value: Binding(
                            get: { display.volume },
                            set: { display.setVolume($0) }),
                        in: 0...1,
                        onEditingChanged: { editing in
                            editing ? display.beginEditing() : display.endEditing()
                        })
                    .controlSize(.small)
                    PercentLabel(value: display.volume)
                }
            }

            if !display.canSetBrightness && !display.canSetVolume && !display.canSetContrast {
                Text("No controllable features")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SliderRow: View {
    let systemImage: String
    @Binding var value: Float
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Slider(value: $value, in: 0...1, onEditingChanged: onEditingChanged)
                .controlSize(.small)
            PercentLabel(value: value)
        }
    }
}

/// Fixed width with monospaced digits, so the slider does not resize as the number
/// changes length while dragging.
private struct PercentLabel: View {
    let value: Float

    var body: some View {
        Text("\(Int((value * 100).rounded()))%")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .trailing)
    }
}
