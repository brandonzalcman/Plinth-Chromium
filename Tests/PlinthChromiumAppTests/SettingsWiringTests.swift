import Foundation
import Testing
import PlinthSettings
@testable import PlinthChromiumApp

@Suite struct DownloadSafetyTests {
    @Test func plainMediaAndDocumentsAreSafe() {
        for name in ["a.png", "photo.JPG", "x.heic", "doc.pdf", "song.mp3", "clip.mp4", "movie.mov", "notes.txt", "sound.m4a"] {
            #expect(DownloadSafety.isSafeToOpen(filename: name), "\(name)")
        }
    }

    @Test func appsScriptsArchivesAndUnknownsAreNot() {
        for name in ["Setup.app", "run.command", "script.sh", "tool.py", "a.js", "disk.dmg", "pkg.pkg", "arch.zip", "a.tar.gz",
                     "installer.exe", "noextension", "photo.jpg.app", "page.html", "pic.svg", "link.webloc", "x.jar",
                     "unknown.zzzzqq", "", ".png", "main.swift", "a.workflow"] {
            #expect(!DownloadSafety.isSafeToOpen(filename: name), "\(name)")
        }
        #expect(!DownloadSafety.isSafeToOpen(filename: "../../evil.sh"))
    }
}

@Suite struct ChromiumPreferencesTests {
    @Test func zoomFactorBecomesChromiumLevel() {
        #expect(ChromiumPreferences.zoomLevel(forFactor: 1) == 0)
        #expect(abs(ChromiumPreferences.zoomLevel(forFactor: 1.2) - 1) < 1e-9)
        #expect(abs(ChromiumPreferences.zoomLevel(forFactor: 1.44) - 2) < 1e-9)
        #expect(ChromiumPreferences.zoomLevel(forFactor: 0.5) < 0)
        #expect(ChromiumPreferences.zoomLevel(forFactor: 0) == 0)
        #expect(ChromiumPreferences.zoomLevel(forFactor: .nan) == 0)
    }

    @Test func settingsMapToPreferences() {
        var s = AppSettings()
        s.httpsOnly = true
        s.blockThirdPartyCookies = true
        s.defaultFontSize = 20
        s.minimumFontSize = 10
        s.defaultZoom = 1.2
        let values = Dictionary(uniqueKeysWithValues: ChromiumPreferences.values(for: s).map { ($0.name, $0.value) })
        #expect(values["https_only_mode_enabled"] == .bool(true))
        #expect(values["profile.cookie_controls_mode"] == .int(1))
        #expect(values["webkit.webprefs.default_font_size"] == .int(20))
        #expect(values["webkit.webprefs.minimum_font_size"] == .int(10))
        guard case .doubles(let zoom)? = values["partition.default_zoom_level"] else { Issue.record("no zoom"); return }
        #expect(abs((zoom["x"] ?? 0) - 1) < 1e-9)

        s.blockThirdPartyCookies = false
        let off = Dictionary(uniqueKeysWithValues: ChromiumPreferences.values(for: s).map { ($0.name, $0.value) })
        #expect(off["profile.cookie_controls_mode"] == .int(0))
    }

    @Test func onlyPreferenceChangesCount() {
        let a = AppSettings()
        var b = a
        b.globalPrivacyControl.toggle()
        b.askWhereToSave.toggle()
        #expect(!ChromiumPreferences.differ(a, b))
        b.minimumFontSize = 12
        #expect(ChromiumPreferences.differ(a, b))
    }

    @Test func boolsStayBoolsForChromium() {
        let object = ChromiumPreferences.Value.bool(true).object as! NSNumber
        #expect(CFGetTypeID(object) == CFBooleanGetTypeID())
        let level = ChromiumPreferences.Value.double(0.5).object as! NSNumber
        #expect(String(cString: level.objCType) == "d")
    }
}
