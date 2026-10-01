import Testing
import Foundation
@testable import NitsCore

@Suite("Updates")
struct UpdatesTests {

    @Test("versions order numerically, not as strings")
    func versionOrdering() throws {
        let v = { (s: String) in try #require(AppVersion(s)) }
        #expect(try v("0.1.1") < v("0.2.0"))
        #expect(try v("0.9.0") < v("0.10.0"), "a string comparison would get this wrong")
        #expect(try v("1.0") > v("0.99.99"))
        #expect(try v("0.2") == v("0.2.0"))
        #expect(try v("0.2") < v("0.2.1"))
        #expect(try !(v("0.2.0") < v("0.2.0")))
    }

    @Test("a tag's leading v is ignored")
    func tagPrefix() {
        #expect(AppVersion("v0.2.0") == AppVersion("0.2.0"))
        #expect(AppVersion("v0.2.0")?.description == "0.2.0")
    }

    @Test("anything that is not dotted numbers has no version",
          arguments: ["", "v", "latest", "0.2.0-beta1", "0..2", "0.2.", "1.x", "-1.0"])
    func unparseable(string: String) {
        #expect(AppVersion(string) == nil)
    }

    private func releaseJSON(
        tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
        assets: String = """
            {"name": "nits-0.2.0.dmg.sha256", "digest": "sha256:FFFF",
             "browser_download_url": "https://github.com/atemp21/nits/releases/download/v0.2.0/nits-0.2.0.dmg.sha256"},
            {"name": "nits-0.2.0.dmg", "digest": "sha256:ABCDEF0123",
             "browser_download_url": "https://github.com/atemp21/nits/releases/download/v0.2.0/nits-0.2.0.dmg"}
            """
    ) -> Data {
        Data("""
            {"tag_name": "\(tag)", "draft": \(draft), "prerelease": \(prerelease),
             "html_url": "https://github.com/atemp21/nits/releases/tag/\(tag)",
             "unknown_field": 1, "assets": [\(assets)]}
            """.utf8)
    }

    @Test("a release decodes to its version, page and disk image")
    func decodesRelease() throws {
        let release = try ReleaseInfo.decode(githubRelease: releaseJSON())
        #expect(release.version == AppVersion("0.2.0"))
        #expect(release.pageURL.absoluteString
                == "https://github.com/atemp21/nits/releases/tag/v0.2.0")
        #expect(release.dmgURL.lastPathComponent == "nits-0.2.0.dmg",
                "the .dmg.sha256 asset must not be mistaken for the image")
        #expect(release.dmgSHA256 == "abcdef0123")
    }

    @Test("an asset without a digest still decodes")
    func missingDigest() throws {
        let json = releaseJSON(assets: """
            {"name": "nits-0.2.0.dmg", "browser_download_url": "https://example.com/nits-0.2.0.dmg"}
            """)
        #expect(try ReleaseInfo.decode(githubRelease: json).dmgSHA256 == nil)
    }

    @Test("releases that cannot be installed are rejected")
    func rejectsUnusableReleases() {
        #expect(throws: ReleaseInfo.DecodeError.notPublished) {
            try ReleaseInfo.decode(githubRelease: releaseJSON(draft: true))
        }
        #expect(throws: ReleaseInfo.DecodeError.notPublished) {
            try ReleaseInfo.decode(githubRelease: releaseJSON(prerelease: true))
        }
        #expect(throws: ReleaseInfo.DecodeError.unreadableVersion("nightly")) {
            try ReleaseInfo.decode(githubRelease: releaseJSON(tag: "nightly"))
        }
        #expect(throws: ReleaseInfo.DecodeError.noDiskImage) {
            try ReleaseInfo.decode(githubRelease: releaseJSON(assets: ""))
        }
        #expect(throws: ReleaseInfo.DecodeError.noDiskImage) {
            try ReleaseInfo.decode(githubRelease: releaseJSON(assets: """
                {"name": "nits-0.2.0.dmg", "browser_download_url": "http://example.com/nits-0.2.0.dmg"}
                """))
        }
    }

    @Test("a check is due daily, on first run, and after the clock moves back")
    func schedule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateSchedule.isDue(lastCheck: nil, now: now))
        #expect(!UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
        #expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }
}
