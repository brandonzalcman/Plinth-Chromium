import Foundation
import Testing
import PlinthPasswords
@testable import PlinthBrowserImport

// Every login here is made up, and the Safe Storage password comes from a fake: the Keychain is never asked.

@Suite struct DirectPasswordImportTests {
    @Test(arguments: [ImportSource.brave, .edge, .vivaldi, .chromium, .chrome])
    func eachBrowserAsksForItsOwnKeychainItem(_ source: ImportSource) throws {
        let home = FakeHome()
        writeLoginData(home.root(source).appendingPathComponent("Default"), rows: [("https://site.example/login", "amy", "made-up-1")])
        let keys = RecordingKeys()
        let logins = try ImportService.passwords(from: source, home: home.url, keys: keys)
        #expect(logins.map(\.username) == ["amy"])
        #expect(logins.map(\.password) == ["made-up-1"])
        let item = source.safeStorageItem!
        #expect(keys.asked == ["\(item.service)|\(item.account)"])
    }

    @Test func everyProfileIsReadAndOperaFromItsDataFolder() throws {
        let home = FakeHome()
        writeLoginData(home.root(.opera), rows: [("https://a.example/", "one", "pw-a")])
        writeLoginData(home.root(.opera).appendingPathComponent("_side_profiles/x"), rows: [("https://b.example/", "two", "pw-b")])
        let logins = try ImportService.passwords(from: .opera, home: home.url, keys: RecordingKeys())
        #expect(logins.map(\.username) == ["one", "two"])
    }

    @Test func aWrongKeyIsReportedNotTurnedIntoGarbage() {
        let home = FakeHome()
        writeLoginData(home.root(.brave).appendingPathComponent("Default"), rows: [("https://a.example/", "amy", "pw")],
                       secret: Data("some other browser's key".utf8))
        #expect(throws: ImportFailure.self) { _ = try ImportService.passwords(from: .brave, home: home.url, keys: RecordingKeys()) }
    }

    @Test func noLoginsMeansTheKeychainIsNeverAsked() {
        let home = FakeHome()
        home.dir(home.root(.edge).appendingPathComponent("Default"))
        let keys = RecordingKeys()
        #expect(throws: ImportFailure.self) { _ = try ImportService.passwords(from: .edge, home: home.url, keys: keys) }
        #expect(keys.asked.isEmpty)
    }

    @Test func safariOffersTheCSVRoute() {
        #expect(!ImportService.canReadPasswordsDirectly(.safari))
        #expect(ImportService.directPasswordsNeedKeychain(.chrome))
        #expect(!ImportService.directPasswordsNeedKeychain(.firefox))
        do throws(ImportFailure) { _ = try ImportService.passwords(from: .safari, home: FakeHome().url, keys: RecordingKeys()) }
        catch { #expect(error.message.contains("Export All Passwords")) }
    }

    @Test func aFirefoxProfileWithoutLoginsIsReported() {
        let home = FakeHome()
        writePlaces(home.root(.firefox).appendingPathComponent("Profiles/p"), bookmarks: [], visits: [])
        #expect(throws: ImportFailure.self) { _ = try ImportService.passwords(from: .firefox, home: home.url) }
    }
}

@Suite struct PasswordCSVTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func chromeFamilyExports() throws {
        let text = "name,url,username,password,note\nexample.com,https://example.com/login,amy,made-up-1,\n"
        let result = try PasswordCSV.parse(text, now: now)
        #expect(result.format == .chromium)
        #expect(result.logins.map(\.username) == ["amy"])
        #expect(result.logins[0].origin.host == "example.com")
        // Edge writes the same columns without "note".
        #expect(try PasswordCSV.parse("name,url,username,password\nx,https://x.example/,u,p\n").format == .chromium)
    }

    @Test func applePasswordsAndSafari() throws {
        let text = "Title,URL,Username,Password,Notes,OTPAuth\r\nExample,https://example.com/,amy,\"made,up\",,\r\n"
        let result = try PasswordCSV.parse(text, now: now)
        #expect(result.format == .applePasswords)
        #expect(result.logins.map(\.password) == ["made,up"])
    }

    @Test func firefoxKeepsWhenTheLoginWasCreatedAndSkipsNonWebEntries() throws {
        let text = """
            "url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"
            "https://example.com","amy","made-up","","https://example.com","{1}","1700000000000","1700000000000","1700000000000"
            "chrome://FirefoxAccounts","x","y","","","{2}","1700000000000","1700000000000","1700000000000"
            """
        let result = try PasswordCSV.parse(text, now: now)
        #expect(result.format == .firefox)
        #expect(result.logins.count == 1)
        #expect(result.logins[0].created == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(result.skipped == 1)
    }

    @Test func onePasswordOldAndNew() throws {
        let new = "Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nEx,https://example.com,amy,pw,,false,false,,\n"
        #expect(try PasswordCSV.parse(new).format == .onePassword)
        let old = "title,website,username,password,notes\nEx,https://example.com,amy,pw,\n"
        let result = try PasswordCSV.parse(old)
        #expect(result.format == .onePassword)
        #expect(result.logins.count == 1)
    }

    @Test func bitwardenTakesOnlyLogins() throws {
        let text = """
            folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
            ,,login,Example,,,0,https://example.com,amy,pw,
            ,,note,A note,secret text,,0,,,,
            """
        let result = try PasswordCSV.parse(text)
        #expect(result.format == .bitwarden)
        #expect(result.logins.map(\.username) == ["amy"])
        #expect(result.skipped == 1)
    }

    @Test func otherManagersByColumnNames() throws {
        let result = try PasswordCSV.parse("Website,Email,Password\nhttps://example.com,amy@example.com,pw\n")
        #expect(result.format == .generic)
        #expect(result.logins.map(\.username) == ["amy@example.com"])
    }

    @Test func rowsWithoutASiteUserOrPasswordAreSkipped() throws {
        let text = "name,url,username,password\na,https://a.example/,,pw\nb,not a url,u,pw\nc,https://c.example/,u,\nd,https://d.example/,u,pw\n"
        let result = try PasswordCSV.parse(text)
        #expect(result.logins.count == 1)
        #expect(result.skipped == 3)
    }

    @Test func aFileWithoutLoginColumnsIsRefused() {
        #expect(throws: PasswordCSV.Failure.self) { _ = try PasswordCSV.parse("date,amount\n2026-01-01,4\n") }
        #expect(throws: PasswordCSV.Failure.self) { _ = try PasswordCSV.parse("") }
    }

    @Test func detectionNamesColumns() {
        let detected = PasswordCSV.detect(header: ["name", "url", "username", "password", "note"])
        #expect(detected?.format == .chromium)
        #expect(detected?.columns == PasswordCSV.Columns(url: 1, username: 2, password: 3))
    }
}
