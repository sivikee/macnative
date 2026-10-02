import Foundation
import Security

/// Steam's modern login (IAuthenticationService), as used by the official client:
/// credentials + Steam Guard, or a QR code scanned with the Steam mobile app.
/// The result is a long-lived refresh token used to log on to the CM.
enum SteamAuth {
    enum GuardType: Int {
        case none = 1, emailCode = 2, deviceCode = 3, deviceConfirmation = 4, emailConfirmation = 5
    }

    struct Session {
        var clientID: UInt64
        var requestID: Data
        var steamID: UInt64
        var interval: Double
        var allowed: [GuardType]
        var challengeURL: String?
    }

    struct Tokens {
        var refreshToken: String
        var accountName: String
        var guardData: String?
    }

    static var deviceName: String { "MacNative on \(Host.current().localizedName ?? "Mac")" }

    private static func deviceDetails(_ w: inout ProtoWriter) {
        w.string(1, deviceName)
        w.int32(2, 1)       // k_EAuthTokenPlatformType_SteamClient
        w.int32(3, 0)       // EOSType WinUnknown: we run Windows games
    }

    // MARK: Credentials

    static func beginWithCredentials(_ c: SteamConnection, account: String, password: String,
                                     guardData: String?) async throws -> Session {
        let key = try await c.call("Authentication.GetPasswordRSAPublicKey#1", authenticated: false) {
            $0.string(1, account)
        }
        guard let mod = key.string(1), let exp = key.string(2), let timestamp = key.uint64(3) else {
            throw SteamError(message: "Steam didn't return a login key")
        }
        let encrypted = try rsaEncrypt(Data(password.utf8), modulusHex: mod, exponentHex: exp)

        let r = try await c.call("Authentication.BeginAuthSessionViaCredentials#1", authenticated: false) { w in
            w.string(1, deviceName)
            w.string(2, account)
            w.string(3, encrypted.base64EncodedString())
            w.uint64(4, timestamp)
            w.bool(5, true)
            w.int32(6, 1)                  // platform: Steam client
            w.int32(7, 1)                  // persistence: persistent
            w.string(8, "Client")
            w.message(9, deviceDetails)
            if let guardData { w.string(10, guardData) }
        }
        return Session(clientID: r.uint64(1) ?? 0, requestID: r.bytes(2) ?? Data(), steamID: r.uint64(5) ?? 0,
                       interval: Double(r.float(3) ?? 1), allowed: allowed(r.messages(4)), challengeURL: nil)
    }

    static func submitGuardCode(_ c: SteamConnection, session: Session, code: String, type: GuardType) async throws {
        _ = try await c.call("Authentication.UpdateAuthSessionWithSteamGuardCode#1", authenticated: false) { w in
            w.uint64(1, session.clientID)
            w.fixed64(2, session.steamID)
            w.string(3, code.trimmingCharacters(in: .whitespaces).uppercased())
            w.int32(4, Int32(type.rawValue))
        }
    }

    // MARK: QR

    static func beginWithQR(_ c: SteamConnection) async throws -> Session {
        let r = try await c.call("Authentication.BeginAuthSessionViaQR#1", authenticated: false) { w in
            w.string(1, deviceName)
            w.int32(2, 1)
            w.message(3, deviceDetails)
            w.string(4, "Client")
        }
        return Session(clientID: r.uint64(1) ?? 0, requestID: r.bytes(3) ?? Data(), steamID: 0,
                       interval: Double(r.float(4) ?? 5), allowed: allowed(r.messages(5)), challengeURL: r.string(2))
    }

    // MARK: Poll

    enum PollResult {
        case pending(newChallengeURL: String?)
        case done(Tokens)
    }

    static func poll(_ c: SteamConnection, session: inout Session) async throws -> PollResult {
        let r = try await c.call("Authentication.PollAuthSessionStatus#1", authenticated: false) { w in
            w.uint64(1, session.clientID)
            w.bytes(2, session.requestID)
        }
        if let newID = r.uint64(1), newID != 0 { session.clientID = newID }
        if let refresh = r.string(3), !refresh.isEmpty {
            return .done(Tokens(refreshToken: refresh, accountName: r.string(6) ?? "", guardData: r.string(7)))
        }
        return .pending(newChallengeURL: r.string(2).flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func allowed(_ list: [ProtoMessage]) -> [GuardType] {
        list.compactMap { $0.int32(1).flatMap { GuardType(rawValue: Int($0)) } }
    }

    // MARK: RSA

    /// PKCS#1 v1.5 encryption with Steam's per-account public key.
    static func rsaEncrypt(_ data: Data, modulusHex: String, exponentHex: String) throws -> Data {
        guard let n = Data(hex: modulusHex), let e = Data(hex: exponentHex) else {
            throw SteamError(message: "Invalid login key from Steam")
        }
        let der = DER.sequence(DER.integer(n) + DER.integer(e))
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error),
              let out = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, data as CFData, &error) else {
            throw error?.takeRetainedValue() ?? SteamError(message: "Couldn't encrypt password")
        }
        return out as Data
    }

    private enum DER {
        static func length(_ n: Int) -> Data {
            if n < 0x80 { return Data([UInt8(n)]) }
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        static func integer(_ value: Data) -> Data {
            var v = Data(value.drop { $0 == 0 })
            if v.isEmpty { v = Data([0]) }
            if v.first! & 0x80 != 0 { v.insert(0, at: 0) }
            return Data([0x02]) + length(v.count) + v
        }
        static func sequence(_ content: Data) -> Data { Data([0x30]) + length(content.count) + content }
    }
}

extension Data {
    init?(hex: String) {
        var s = hex.count % 2 == 1 ? "0" + hex : hex
        var out = Data(capacity: s.count / 2)
        while !s.isEmpty {
            guard let b = UInt8(s.prefix(2), radix: 16) else { return nil }
            out.append(b)
            s.removeFirst(2)
        }
        self = out
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
