import Foundation
import Testing
@testable import PlinthBrowserImport

// Firefox-family passwords: NSS blobs built the way NSS builds them, with made-up keys (ported from the
// Plinth package's PlinthImport tests, which cover the cryptography against independent implementations).

private func hex(_ s: String) -> Data {
    var data = Data()
    var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); data.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return data
}


// MARK: - DER writer (the tests build blobs the way NSS does)

private func der(_ tag: UInt8, _ content: Data) -> Data {
    var out = Data([tag])
    if content.count < 128 { out.append(UInt8(content.count)) }
    else if content.count < 256 { out += [0x81, UInt8(content.count)] }
    else { out += [0x82, UInt8(content.count >> 8), UInt8(content.count & 0xFF)] }
    return out + content
}
private func seq(_ parts: Data...) -> Data { der(0x30, parts.reduce(Data(), +)) }
private func oct(_ d: Data) -> Data { der(0x04, d) }
private func int(_ n: Int) -> Data { der(0x02, n < 128 ? Data([UInt8(n)]) : Data([UInt8(n >> 8), UInt8(n & 0xFF)])) }
private func oid(_ d: Data) -> Data { der(0x06, d) }
private let null = Data([0x05, 0x00])
private let hmacSHA256 = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09])

// MARK: - Zen (Firefox NSS)

private let globalSalt = hex("000102030405060708090a0b0c0d0e0f10111213")

/// Legacy NSS PBE (SHA-1 key schedule + 3DES), built independently of the decryptor for the round-trip tests.
private func legacyPBE(_ plain: Data, entrySalt: Data, globalSalt: Data, password: Data = Data()) -> Data {
    let hp = PasswordCrypto.sha1(globalSalt + password)
    let pes = entrySalt + Data(repeating: 0, count: 20 - entrySalt.count)
    let chp = PasswordCrypto.sha1(hp + entrySalt)
    let k1 = PasswordCrypto.hmacSHA1(key: chp, pes + entrySalt)
    let tk = PasswordCrypto.hmacSHA1(key: chp, pes)
    let k2 = PasswordCrypto.hmacSHA1(key: chp, tk + entrySalt)
    let k = k1 + k2
    let ct = PasswordCrypto.encrypt(.tripleDES, key: k.prefix(24), iv: k.suffix(8), plain)!
    return seq(seq(oid(OID.pbeSHA1TripleDES), seq(oct(entrySalt), int(1))), oct(ct))
}

private func pbes2(_ plain: Data, salt: Data, iv14: Data, iterations: Int = 10, globalSalt: Data, password: Data = Data()) -> Data {
    let seed = PasswordCrypto.sha1(globalSalt + password)
    let key = PasswordCrypto.pbkdf2(.sha256, password: seed, salt: salt, iterations: iterations, keyLength: 32)!
    let ct = PasswordCrypto.encrypt(.aes, key: key, iv: Data([0x04, 0x0E]) + iv14, plain)!
    let kdf = seq(oid(OID.pbkdf2), seq(oct(salt), int(iterations), int(32), seq(oid(hmacSHA256), null)))
    let enc = seq(oid(OID.aes256CBC), oct(iv14))
    return seq(seq(oid(OID.pbes2), seq(kdf, enc)), oct(ct))
}

private func field(_ plain: String, key: Data, keyID: Data, aes: Bool, iv: Data) -> String {
    let ct = PasswordCrypto.encrypt(aes ? .aes : .tripleDES, key: key, iv: iv, Data(plain.utf8))!
    let alg = seq(oid(aes ? OID.aes256CBC : OID.tripleDESCBC), oct(iv))
    return seq(oct(keyID), alg, oct(ct)).base64EncodedString()
}

enum PWScheme { case legacy, modern }

struct ZenFixture {
    var scheme: PWScheme
    var passwordProtected = false
    var logins: [(host: String, user: String, password: String)]
}

private let keyID = hex("f8000000000000000000000000000001")

private func writeFirefoxPasswords(_ home: FakeHome, _ source: ImportSource, _ f: ZenFixture) {
    let root = home.root(source)
    let profile = root.appendingPathComponent("Profiles/abc.Default (release)")
    home.dir(profile)
    try! "[Profile0]\nName=x\nIsRelative=1\nPath=Profiles/abc.Default (release)\nDefault=1\n".write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
    makeSQLite(profile.appendingPathComponent("places.sqlite"), ["CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT)"])

    let key3DES = Data((1...24).map { UInt8($0) })
    let keyAES = Data((1...32).map { UInt8(0x40 + $0) })
    let loginKey = f.scheme == .legacy ? key3DES : keyAES
    let userPassword = f.passwordProtected ? Data("primary".utf8) : Data()
    let entrySalt = hex("6465666768696a6b6c6d6e6f7071727374757677")
    let check: Data, a11: Data
    switch f.scheme {
    case .legacy:
        check = legacyPBE(Data("password-check".utf8), entrySalt: entrySalt, globalSalt: globalSalt, password: userPassword)
        a11 = legacyPBE(loginKey, entrySalt: entrySalt, globalSalt: globalSalt, password: userPassword)
    case .modern:
        check = pbes2(Data("password-check".utf8), salt: Data((32..<64).map { UInt8($0) }), iv14: Data((1...14).map { UInt8($0) }), globalSalt: globalSalt, password: userPassword)
        a11 = pbes2(loginKey, salt: Data((64..<96).map { UInt8($0) }), iv14: Data((20...33).map { UInt8($0) }), globalSalt: globalSalt, password: userPassword)
    }
    makeSQLite(profile.appendingPathComponent("key4.db"), [
        "CREATE TABLE metaData (id TEXT PRIMARY KEY, item1, item2)",
        "INSERT INTO metaData VALUES ('password', \(hexLiteral(globalSalt)), \(hexLiteral(check)))",
        "CREATE TABLE nssPrivate (id INTEGER PRIMARY KEY, a11, a102)",
        "INSERT INTO nssPrivate VALUES (1, \(hexLiteral(a11)), \(hexLiteral(keyID)))",
    ])

    let aes = f.scheme == .modern
    var entries: [[String: Any]] = []
    for (i, l) in f.logins.enumerated() {
        let iv = aes ? Data((0..<16).map { UInt8($0 + i) }) : Data((0..<8).map { UInt8(200 + $0 + i) })
        entries.append(["hostname": l.host, "encryptedUsername": field(l.user, key: loginKey, keyID: keyID, aes: aes, iv: iv),
                        "encryptedPassword": field(l.password, key: loginKey, keyID: keyID, aes: aes, iv: iv),
                        "timeCreated": 1_700_000_000_000])
    }
    let doc: [String: Any] = ["nextId": 9, "logins": entries]
    try! JSONSerialization.data(withJSONObject: doc).write(to: profile.appendingPathComponent("logins.json"))
}

@Suite struct FirefoxFamilyPasswordTests {
    @Test(arguments: [ImportSource.firefox, .zen])
    func importsFromTheProfileTheBrowserLastUsed(_ source: ImportSource) throws {
        let home = FakeHome()
        writeFirefoxPasswords(home, source, ZenFixture(scheme: .modern, logins: [
            ("https://example.com", "amy@example.com", "made-up horse"),
            ("chrome://FirefoxAccounts", "ignored", "x"),
        ]))
        let logins = try ImportService.passwords(from: source, home: home.url)
        #expect(logins.map(\.username) == ["amy@example.com"])
        #expect(logins.map(\.password) == ["made-up horse"])
    }

    @Test func aPrimaryPasswordIsReportedWithTheBrowsersName() {
        let home = FakeHome()
        writeFirefoxPasswords(home, .firefox, ZenFixture(scheme: .legacy, passwordProtected: true, logins: [("https://example.com", "amy", "pw")]))
        do throws(ImportFailure) {
            _ = try ImportService.passwords(from: .firefox, home: home.url)
            Issue.record("should have thrown")
        } catch {
            #expect(error.message == FirefoxPasswords.masterPasswordMessage(.firefox))
            #expect(error.message.contains("Firefox"))
        }
    }
}
