import Foundation
import NitsCore
import CoreGraphics

// nitsprobe — hardware diagnostics for nits.
//
// Read-only by default. Writes to the panel only when explicitly asked, so it is
// always safe to run.

let arguments = Array(CommandLine.arguments.dropFirst())

func flagValue(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    nitsprobe — diagnostics for DDC/CI and audio control

    usage: nitsprobe [options]

      --set-brightness N   write brightness N (0-100) to every external display
      --set-volume N       write VCP audio volume N (0-100) via DDC
      --vcp 0xNN           additionally read this VCP code
      -h, --help           this message

    With no options the probe only reads. Nothing is written to the panel.
    """)
    exit(0)
}

func header(_ title: String) {
    print("\n\u{001B}[1m\(title)\u{001B}[0m")
    print(String(repeating: "-", count: title.count))
}

// MARK: - Private API availability

header("Private API")
let api = SystemPrivateAPI.shared
print("DDC transport (IOAVService):   \(api.supportsDDC ? "available" : "UNAVAILABLE")")
print("Native brightness (DisplayServices): \(api.supportsNativeBrightness ? "available" : "UNAVAILABLE")")
if api.missingSymbols.isEmpty {
    print("All expected symbols resolved.")
} else {
    print("Missing symbols: \(api.missingSymbols.joined(separator: ", "))")
}

// MARK: - IORegistry AV service nodes

header("DCPAVServiceProxy nodes")
let registry = DisplayRegistry()
let nodes = registry.findAVServiceNodes()
if nodes.isEmpty {
    print("None found. DDC cannot work on this machine.")
}
for node in nodes {
    let productID = node.productID.map { String(format: "0x%04x (%d)", $0, $0) } ?? "-"
    let serial = node.serialNumber.map(String.init) ?? "-"
    print("""
    • location=\(node.location)  service=\(node.service == nil ? "not created" : "created")
      productName=\(node.productName ?? "-")  productID=\(productID)  serial=\(serial)
      path=\(node.registryPath)
    """)
}
let externalCount = nodes.filter(\.isExternal).count
print("\n\(nodes.count) node(s), \(externalCount) external.")
if externalCount == 0 {
    print("NOTE: no external AV service. Either no monitor is attached, or it is")
    print("      connected over a port that does not expose I2C (HDMI is the usual")
    print("      culprit on Apple Silicon — retry over USB-C/DisplayPort).")
}

// MARK: - Displays

header("Active displays")
let displays = registry.displays()
for display in displays {
    print("""
    • \(display.name)  [id \(display.id)]
      builtIn=\(display.isBuiltIn)  ddc=\(display.supportsDDC ? "yes" : "no")
      identity=\(display.identity.key)
    """)
    if display.isBuiltIn {
        let current = api.nativeBrightness(display.id)
        let settable = api.canChangeNativeBrightness(display.id)
        let shown = current.map { String(format: "%.3f", $0) } ?? "unreadable"
        print("      native brightness=\(shown)  settable=\(settable)")
    }
}

// MARK: - DDC reads

header("DDC reads")
var codes: [VCP] = [.brightness, .contrast, .audioVolume, .audioMute]
var extraCode: UInt8?
if let raw = flagValue("--vcp") {
    let trimmed = raw.hasPrefix("0x") ? String(raw.dropFirst(2)) : raw
    extraCode = UInt8(trimmed, radix: 16)
}

let ddcDisplays = displays.filter { $0.ddc != nil }
if ddcDisplays.isEmpty {
    print("No display has a DDC channel; nothing to read.")
}

for display in ddcDisplays {
    guard let channel = display.ddc else { continue }
    print("\(display.name):")
    for code in codes {
        do {
            let reading = try channel.get(code)
            print(String(
                format: "  0x%02x %-14@ current=%-5d max=%-5d  raw=[%@]",
                code.rawValue, code.label as NSString,
                Int(reading.current), Int(reading.maximum), reading.raw.hex))
        } catch {
            print(String(format: "  0x%02x %-14@ FAILED: %@",
                         code.rawValue, code.label as NSString, "\(error)"))
        }
    }
    if let extraCode {
        do {
            let reading = try channel.get(extraCode)
            print(String(format: "  0x%02x (extra)     current=%-5d max=%-5d  raw=[%@]",
                         extraCode, Int(reading.current), Int(reading.maximum), reading.raw.hex))
        } catch {
            print(String(format: "  0x%02x (extra)     FAILED: %@", extraCode, "\(error)"))
        }
    }
}

// MARK: - Audio

header("Audio output devices")
for device in AudioControl.outputDevices() {
    let level = AudioControl.volume(device.id).map { String(format: "%.3f", $0) } ?? "unreadable"
    let muted = AudioControl.isMuted(device.id).map(String.init(describing:)) ?? "-"
    print("""
    • \(device.name)\(device.isDefaultOutput ? "  (default output)" : "")
      transport=\(device.transport)  settableVolume=\(device.hasSettableVolume)  hasMute=\(device.hasMute)
      volume=\(level)  muted=\(muted)
    """)
}
print("""

If the monitor's speakers appear above with settableVolume=true, volume goes through
CoreAudio. If they appear with settableVolume=false, the panel owns the level and we
must drive it over DDC VCP 0x62 instead.
""")

// MARK: - Optional writes

if let raw = flagValue("--set-brightness"), let target = UInt16(raw) {
    header("DDC write: brightness = \(target)")
    for display in ddcDisplays {
        guard let channel = display.ddc else { continue }
        do {
            try channel.set(.brightness, value: target)
            print("\(display.name): wrote \(target) — look at the panel, did it change?")
        } catch {
            print("\(display.name): FAILED: \(error)")
        }
    }
}

if let raw = flagValue("--set-volume"), let target = UInt16(raw) {
    header("DDC write: audio volume = \(target)")
    for display in ddcDisplays {
        guard let channel = display.ddc else { continue }
        do {
            try channel.set(.audioVolume, value: target)
            print("\(display.name): wrote \(target)")
        } catch {
            print("\(display.name): FAILED: \(error)")
        }
    }
}

print("")
