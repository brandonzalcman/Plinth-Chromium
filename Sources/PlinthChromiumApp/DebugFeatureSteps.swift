import AppKit
import PlinthBrowserImport
import PlinthModel
import PlinthPasswords
import PlinthRules
import PlinthStore
import PlinthSync

/// Scripted steps for bookmarks, history, import, passwords and sync (see DebugSteps.swift). The
/// password and import steps act only on a scratch profile (`PLINTH_STORAGE`), whose vault is in memory
/// and whose imports read `PLINTH_IMPORT_HOME`. Passwords are never logged: only their length.
@MainActor
extension DebugSteps {
    /// Runs one step, or returns false if it isn't one of these.
    static func runFeature(_ command: String, _ arg: String, _ app: ChromiumApp) async -> Bool {
        let store = app.store!
        let selected = { app.keyWindowID.flatMap { store.window($0)?.selectedPageID } }
        switch command {
        case "bookmark":
            app.keyController?.bookmarkCurrentPage()
            log("panel: \(app.keyController.map { String(describing: $0.chrome.panel) } ?? "-")")
        case "bookmarks":
            app.keyController?.toggleBookmarks()
        case "history":
            app.keyController?.toggleHistory()
        case "bmstate":
            let folders = app.bookmarks.folders.map { app.bookmarks.path(of: $0.id).joined(separator: "/") }
            log("bookmarks: \(app.bookmarks.bookmarks.count) [\(app.bookmarks.bookmarks.prefix(8).map(\.title).joined(separator: " | "))] folders=\(folders)")
            let hits = app.bookmarks.results(for: arg.isEmpty ? "a" : arg, amid: store.suggestions(for: arg.isEmpty ? "a" : arg, limit: 7))
            log("command bar '\(arg)': " + hits.map { "\($0.title)\($0.id.hasPrefix(SearchResult.bookmarkIDPrefix) ? " [bookmark]" : "")" }.joined(separator: " | "))
        case "historycount":
            log("history: \(store.history.count) newest=\(store.history.first.map { $0.url.absoluteString } ?? "-")")
        case "clearhistory":
            log("cleared \(app.clearHistory(since: nil)) entries; now \(store.history.count)")
        case "import":
            guard app.isScratchProfile, let source = ImportSource(rawValue: arg) else { log("import: needs a scratch profile and a browser"); return true }
            do {
                let report = try await ImportService.run(source, bookmarks: true, history: true, into: store, bookmarkStore: app.bookmarks, home: app.importHome)
                log("import \(arg): bookmarks=\(report.bookmarksImported) history=\(report.historyImported) notes=\(report.notes)")
            } catch {
                log("import \(arg) failed: \((error as? ImportFailure)?.message ?? "\(error)")")
            }
        case "installed":
            log("installed: \(ImportService.installedSources(home: app.importHome).map(\.rawValue)) "
                + ImportSource.allCases.map { "\($0.rawValue)=\(ImportService.profiles($0, home: app.importHome).map(\.name))" }.joined(separator: " "))
        case "pw":
            passwordStep(arg, app)
        case "pwimport":
            guard app.isScratchProfile, let source = ImportSource(rawValue: arg) else { log("pwimport: needs a scratch profile and a browser"); return true }
            do throws(ImportFailure) {
                let logins = try ImportService.passwords(from: source, home: app.importHome, keys: app.safeStorageKeys)
                let merged = app.passwords.vault.merge(logins.compactMap { l in WebOrigin(url: l.url).map { Login(origin: $0, username: l.username, password: l.password) } })
                app.passwords.model.reload()
                log("pwimport \(arg): read=\(logins.count) added=\(merged.added) duplicates=\(merged.duplicates)")
            } catch {
                log("pwimport \(arg) failed: \(error.message)")
            }
        case "pwcsv":
            guard app.isScratchProfile, let text = try? String(contentsOfFile: arg, encoding: .utf8) else { log("pwcsv: unreadable"); return true }
            do {
                let parsed = try PasswordCSV.parse(text)
                let merged = app.passwords.vault.merge(parsed.logins)
                app.passwords.model.reload()
                log("pwcsv: format=\(parsed.format.rawValue) added=\(merged.added) skipped=\(parsed.skipped)")
            } catch { log("pwcsv: not a password export") }
        case "pwfocus", "pwtype", "pwsubmit":
            // Scripted input in the selected page; the password script counts it only in test mode.
            guard let page = selected(), let browser = app.pool.existing(page) else { log("\(command): no page"); return true }
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let selector = Self.jsString(parts.first ?? "")
            let text = Self.jsString(parts.count > 1 ? parts[1] : "")
            let script: String
            switch command {
            case "pwfocus":
                script = "(function(){var e=document.querySelector(\(selector)); if(!e) return; e.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,composed:true})); e.focus();})()"
            case "pwtype":
                script = "(function(){var e=document.querySelector(\(selector)); if(!e) return; e.focus(); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,\(text)); e.dispatchEvent(new Event('input',{bubbles:true,composed:true}));})()"
            default:
                script = "(function(){var e=document.querySelector(\(selector)); if(!e) return; var f=e.form||e; f.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true})); setTimeout(function(){ if(f.tagName==='FORM') HTMLFormElement.prototype.submit.call(f); },400);})()"
            }
            browser.executeJavaScript(script)
        case "pwvalue":
            guard let page = selected(), let browser = app.pool.existing(page) else { log("pwvalue: no page"); return true }
            let value = await withCheckedContinuation { (done: CheckedContinuation<Any?, Never>) in
                browser.evaluateJavaScript("(function(){var e=document.querySelector(\(Self.jsString(arg))); return e ? (e.type==='password' ? 'password:' + e.value.length : e.value) : 'none';})()") { done.resume(returning: $0) }
            }
            log("pwvalue \(arg): \(value.map { "\($0)" } ?? "nil")")
        case "sync":
            log("sync: state=\(app.syncState) running=\(app.sync != nil) canSync=\(app.canSync) devices=\(app.otherDevices.map { "\($0.deviceName)(\($0.pages.map(\.name).joined(separator: ",")))" }) error=\(app.sync?.lastError.map { "\($0)" } ?? "-")")
        case "syncon":
            app.setSyncEnabled(true)
        case "syncoff":
            app.setSyncEnabled(false)
        case "syncnow":
            if let sync = app.sync {
                let result = await SyncWiring.syncNow(sync, store: store)
                if case .success(let devices) = result { app.otherDevices = devices }
                log("syncnow: \(result) pins=\(store.pins.map(\.name)) history=\(store.history.count)")
            } else { log("syncnow: sync is off") }
        case "syncpeer":
            await syncPeer(app)
        case "shot":
            // A picture of this app's windows only, by Scripts/dev/shoot.swift compiled to PLINTH_SHOOT_TOOL.
            guard let tool = ProcessInfo.processInfo.environment["PLINTH_SHOOT_TOOL"] else { log("shot: no PLINTH_SHOOT_TOOL"); return true }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tool)
            task.arguments = [String(ProcessInfo.processInfo.processIdentifier), arg]
            try? task.run()
            while task.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        case "settingsat":
            app.showSettings()
            SettingsWindowController.shared?.select(section: arg)
        default:
            return await runWelcomeOrPeek(command, arg, app)
        }
        return true
    }

    /// Another device on the same in-memory server: it pins a site, visits a page and keeps one open, then
    /// syncs. The app's next sync should bring the pin and the visit, and list the open page.
    private static func syncPeer(_ app: ChromiumApp) async {
        guard let transport = app.memorySyncTransport else { log("syncpeer: needs PLINTH_SYNC=memory with sync on"); return }
        let peer = BrowserStore(identity: app.identity, namer: PageNamer(), fader: ChromiumApp.fader(for: .standard), storageDirectory: nil)
        let window = peer.createWindow()
        peer.openPage(url: URL(string: "https://peer.example/reading")!, in: window)
        if let site = peer.window(window)?.sites.first { peer.pin(site: site.id) }
        peer.openPage(url: URL(string: "https://swift.org/documentation/")!, in: window)
        let engine = SyncEngine(transport: transport, deviceID: "peer-device", deviceName: "Peer Mac", stateURL: nil)
        let coordinator = SyncCoordinator(engine: engine)
        let result = await SyncWiring.syncNow(coordinator, store: peer)
        log("syncpeer: \(result) peerPins=\(peer.pins.map(\.name)) peerHistory=\(peer.history.count)")
    }

    private static func passwordStep(_ arg: String, _ app: ChromiumApp) {
        guard app.isScratchProfile else { return }
        let p = arg.split(separator: " ").map(String.init)
        let vault = app.passwords.vault
        switch p.first {
        case "add" where p.count == 4:
            if let origin = WebOrigin(string: p[1]) { try? vault.save(Login(origin: origin, username: p[2], password: p[3])) }
            app.passwords.model.reload()
        case "answer" where p.count == 2:
            app.passwords.debugAnswer = ["save": .save, "notnow": .notNow, "never": .never][p[1]]
        case "pending":
            let page = app.keyWindowID.flatMap { app.store.window($0)?.selectedPageID }
            log("pending: \(page.map { app.passwords.debugPending($0) } ?? "none")")
        case "list":
            log("passwords: " + ((try? vault.list()) ?? []).map { summary in
                let length = (try? vault.password(for: summary.key))??.count ?? 0
                return "\(summary.origin) \(summary.username) (\(length) chars)"
            }.joined(separator: " | ") + " never: \(app.passwords.preferences.neverSave.map(\.description))")
        case "delete" where p.count == 3:
            if let origin = WebOrigin(string: p[1]) { try? vault.delete(LoginKey(origin: origin, username: p[2])) }
            app.passwords.model.reload()
        case "clear":
            for login in (try? vault.list()) ?? [] { try? vault.delete(login.key) }
            app.passwords.model.reload()
        default:
            log("pw: unknown \(arg.prefix(20))")
        }
    }

    /// A Swift string as a JavaScript string literal.
    nonisolated static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }
}
