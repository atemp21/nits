import Testing
import Foundation
@testable import NitsCore

@Suite("Preferences")
struct PreferencesTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nits-tests-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
    }

    @Test("settings round-trip through the file")
    func roundTrip() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = PreferencesStore(url: url)
        store.update("19501-3870-809056048-External") { settings in
            settings.brightness = 0.42
            settings.volume = 0.19
            settings.isMuted = true
            settings.contrast = 0.75
        }
        store.saveNow()

        let reloaded = PreferencesStore(url: url)
        let settings = reloaded.settings(for: "19501-3870-809056048-External")
        #expect(settings?.brightness == 0.42)
        #expect(settings?.volume == 0.19)
        #expect(settings?.isMuted == true)
        #expect(settings?.contrast == 0.75)
    }

    @Test("displays are kept separate by identity key")
    func perDisplayIsolation() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = PreferencesStore(url: url)
        store.update("display-a") { $0.brightness = 0.1 }
        store.update("display-b") { $0.brightness = 0.9 }
        store.saveNow()

        let reloaded = PreferencesStore(url: url)
        #expect(reloaded.settings(for: "display-a")?.brightness == 0.1)
        #expect(reloaded.settings(for: "display-b")?.brightness == 0.9)
    }

    @Test("an update merges rather than replacing")
    func updateMerges() {
        let store = PreferencesStore(url: temporaryURL())
        store.update("key") { $0.brightness = 0.5 }
        store.update("key") { $0.volume = 0.25 }
        #expect(store.settings(for: "key")?.brightness == 0.5)
        #expect(store.settings(for: "key")?.volume == 0.25)
    }

    @Test("restoreOnConnect persists")
    func restoreFlagPersists() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = PreferencesStore(url: url)
        #expect(store.restoreOnConnect, "restoring should be the default")
        store.restoreOnConnect = false
        store.saveNow()

        #expect(PreferencesStore(url: url).restoreOnConnect == false)
    }

    /// Settings files written before contrast existed must still load.
    @Test("a settings file with no contrast field decodes")
    func decodesWithoutContrast() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"displays":{"key":{"brightness":0.3}},"restoreOnConnect":true}"#
        try Data(json.utf8).write(to: url)

        let store = PreferencesStore(url: url)
        #expect(store.settings(for: "key")?.brightness == 0.3)
        #expect(store.settings(for: "key")?.contrast == nil)
    }

    @Test("an unknown display has no settings")
    func unknownDisplay() {
        #expect(PreferencesStore(url: temporaryURL()).settings(for: "nope") == nil)
    }

    @Test("a corrupt file falls back to defaults instead of crashing")
    func corruptFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not json".utf8).write(to: url)

        let store = PreferencesStore(url: url)
        #expect(store.restoreOnConnect)
        #expect(store.settings(for: "anything") == nil)
    }
}
