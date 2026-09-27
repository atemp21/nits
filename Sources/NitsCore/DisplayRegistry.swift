import Foundation
import IOKit
import CoreGraphics

/// Identity for a display that survives sleep, replug and reboot.
///
/// `CGDirectDisplayID` is NOT stable across reconnects, so preferences are keyed on
/// this instead. Some Samsung panels report no serial number in their EDID, so the
/// serial is optional and identity degrades to vendor + model + port location.
public struct DisplayIdentity: Hashable, Codable, Sendable {
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32?
    public let location: String?

    public var key: String {
        let serialPart = serial.map(String.init) ?? "noserial"
        let locationPart = location ?? "unknown"
        return "\(vendor)-\(model)-\(serialPart)-\(locationPart)"
    }
}

public struct DisplayInfo: Sendable {
    public let id: CGDirectDisplayID
    public let identity: DisplayIdentity
    public let name: String
    public let isBuiltIn: Bool
    /// nil when no DDC transport could be associated with this display.
    public let ddc: DDCChannel?

    public var supportsDDC: Bool { ddc != nil }
}

/// One AV service node found in the IORegistry, before it is matched to a display.
public struct AVServiceNode {
    public let location: String
    public let className: String
    public let registryPath: String
    /// EDID-derived attributes from the neighbouring framebuffer node, when present.
    public let productID: UInt32?
    public let serialNumber: UInt32?
    public let productName: String?
    public let service: IOAVServiceRef?

    public var isExternal: Bool { location == "External" }
}

public struct DisplayRegistry {
    private let api: PrivateDisplayAPI

    public init(api: PrivateDisplayAPI = SystemPrivateAPI.shared) {
        self.api = api
    }

    // MARK: - CoreGraphics side

    public static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    // MARK: - IORegistry side

    /// Walks the IORegistry and collects every DCPAVServiceProxy node.
    ///
    /// The framebuffer node carrying `DisplayAttributes` (product id, serial, name)
    /// and the `DCPAVServiceProxy` node carrying the I2C transport are separate
    /// entries that sit near each other in the same DCP subtree. We walk in tree
    /// order and associate each AV service with the most recently seen set of
    /// display attributes, which is how the working implementations of this do it.
    public func findAVServiceNodes(createServices: Bool = true) -> [AVServiceNode] {
        var nodes: [AVServiceNode] = []
        var iterator = io_iterator_t()

        guard IORegistryGetRootEntry(kIOMainPortDefault) != 0,
              IORegistryCreateIterator(
                kIOMainPortDefault, kIOServicePlane,
                IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return nodes }
        defer { IOObjectRelease(iterator) }

        // Attributes from the most recent framebuffer node seen in the walk.
        var pendingProductID: UInt32?
        var pendingSerial: UInt32?
        var pendingName: String?

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            let className = Self.className(of: entry) ?? ""

            if let attributes = Self.property(entry, "DisplayAttributes") as? [String: Any],
               let product = attributes["ProductAttributes"] as? [String: Any] {
                pendingProductID = (product["ProductID"] as? NSNumber)?.uint32Value
                pendingSerial = (product["SerialNumber"] as? NSNumber)?.uint32Value
                pendingName = product["ProductName"] as? String
            }

            guard className == "DCPAVServiceProxy" else { continue }

            let location = (Self.property(entry, "Location") as? String) ?? "Unknown"
            let service: IOAVServiceRef? =
                (createServices && location == "External") ? api.makeAVService(for: entry) : nil

            nodes.append(
                AVServiceNode(
                    location: location,
                    className: className,
                    registryPath: Self.path(of: entry) ?? "",
                    productID: pendingProductID,
                    serialNumber: pendingSerial,
                    productName: pendingName,
                    service: service))
        }

        return nodes
    }

    // MARK: - Join

    /// Enumerates active displays, attaching a DDC channel to each external one.
    public func displays() -> [DisplayInfo] {
        let nodes = findAVServiceNodes().filter(\.isExternal)
        var unclaimed = nodes

        return Self.activeDisplayIDs().map { id in
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            let rawSerial = CGDisplaySerialNumber(id)
            let serial: UInt32? = rawSerial == 0 ? nil : rawSerial

            var matched: AVServiceNode?
            if !isBuiltIn {
                // Prefer an exact product-id match, then fall back to serial.
                let index =
                    unclaimed.firstIndex { $0.productID == model && $0.serialNumber == rawSerial }
                    ?? unclaimed.firstIndex { $0.productID == model }
                    // Last resort: a lone unclaimed external service must be this
                    // display. Covers panels whose EDID omits a usable serial.
                    ?? (unclaimed.count == 1 ? unclaimed.startIndex : nil)

                if let index {
                    matched = unclaimed[index]
                    unclaimed.remove(at: index)
                }
            }

            let identity = DisplayIdentity(
                vendor: vendor, model: model, serial: serial, location: matched?.location)

            let name = matched?.productName
                ?? (isBuiltIn ? "Built-in Display" : "Display \(model)")

            let channel = matched?.service.map { DDCChannel(service: $0, api: api) }

            return DisplayInfo(
                id: id, identity: identity, name: name, isBuiltIn: isBuiltIn, ddc: channel)
        }
    }

    // MARK: - IORegistry helpers

    static func className(of entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }

    static func path(of entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS else {
            return nil
        }
        return String(cString: buffer)
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}
