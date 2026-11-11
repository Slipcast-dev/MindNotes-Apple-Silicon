import CommonCrypto
import Foundation
import Security

/// Пароли страниц (ADR-0017): замок интерфейса. В пространстве хранятся соль и PBKDF2-ключ, сам пароль — нигде.
enum PageLockCrypto {
    static let rounds = 200_000

    static func make(page: UUID, password: String) -> PageLock {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return PageLock(page: page, salt: salt.base64EncodedString(), hash: derive(password, salt: salt, rounds: rounds).base64EncodedString(), rounds: rounds)
    }

    static func verify(_ password: String, _ lock: PageLock) -> Bool {
        guard let salt = Data(base64Encoded: lock.salt), let expected = Data(base64Encoded: lock.hash) else { return false }
        let actual = derive(password, salt: salt, rounds: lock.rounds)
        // Сравнение без раннего выхода.
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func derive(_ password: String, salt: Data, rounds: Int) -> Data {
        let secret = Array(password.utf8)
        var out = Data(count: 32)
        _ = out.withUnsafeMutableBytes { key in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.map { CChar(bitPattern: $0) }, secret.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     UInt32(min(max(rounds, 1), 10_000_000)), key.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return out
    }
}
