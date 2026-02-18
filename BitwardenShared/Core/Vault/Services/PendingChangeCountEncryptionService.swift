import CryptoKit
import Foundation

// MARK: - PendingChangeCountEncryptionError

/// Errors that can occur during encryption or decryption of the offline password change count.
///
enum PendingChangeCountEncryptionError: LocalizedError, Equatable {
    /// The encryption key could not be decoded from its stored format.
    case invalidKey

    /// The decrypted data does not contain the expected number of bytes for an Int16.
    case invalidData

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            "Unable to decode the user encryption key."
        case .invalidData:
            "Unable to decode the encrypted password change count."
        }
    }
}

// MARK: - PendingChangeCountEncryptionService

/// A protocol for a service that encrypts and decrypts the offline password change count
/// using the user's vault encryption key.
///
/// The offline password change count is encrypted before storage in Core Data to prevent
/// leaking behavioral metadata (how many times a password was changed while offline).
/// Encryption uses AES-256-GCM with a purpose-specific key derived from the user's
/// vault encryption key via HKDF.
///
protocol PendingChangeCountEncryptionService {
    /// Encrypts a password change count for secure storage.
    ///
    /// - Parameter count: The password change count to encrypt.
    /// - Returns: The encrypted count as opaque `Data`.
    ///
    func encrypt(count: Int16) async throws -> Data

    /// Decrypts a previously encrypted password change count.
    ///
    /// - Parameter data: The encrypted count data.
    /// - Returns: The decrypted password change count.
    ///
    func decrypt(data: Data) async throws -> Int16
}

// MARK: - DefaultPendingChangeCountEncryptionService

/// A default implementation of `PendingChangeCountEncryptionService` that uses AES-256-GCM
/// with a key derived from the user's vault encryption key.
///
class DefaultPendingChangeCountEncryptionService: PendingChangeCountEncryptionService {
    // MARK: Constants

    /// The HKDF info string used to derive a purpose-specific key for encrypting the
    /// password change count. This ensures the derived key is distinct from keys used
    /// for other purposes, even though they share the same root key material.
    static let hkdfInfo = Data("bitwarden-pending-change-count".utf8)

    /// The number of bytes for the HKDF-derived key (256 bits).
    static let derivedKeyByteCount = 32

    // MARK: Properties

    /// The client service for accessing the user's encryption key.
    private let clientService: ClientService

    // MARK: Initialization

    /// Initializes a `DefaultPendingChangeCountEncryptionService`.
    ///
    /// - Parameter clientService: The client service for accessing the user's encryption key.
    ///
    init(clientService: ClientService) {
        self.clientService = clientService
    }

    // MARK: PendingChangeCountEncryptionService

    func encrypt(count: Int16) async throws -> Data {
        let derivedKey = try await deriveKey()
        let plaintext = withUnsafeBytes(of: count) { Data($0) }
        let sealedBox = try AES.GCM.seal(plaintext, using: derivedKey)
        guard let combined = sealedBox.combined else {
            throw PendingChangeCountEncryptionError.invalidData
        }
        return combined
    }

    func decrypt(data: Data) async throws -> Int16 {
        let derivedKey = try await deriveKey()
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(sealedBox, using: derivedKey)
        guard plaintext.count == MemoryLayout<Int16>.size else {
            throw PendingChangeCountEncryptionError.invalidData
        }
        return plaintext.withUnsafeBytes { $0.load(as: Int16.self) }
    }

    // MARK: Private

    /// Derives a purpose-specific symmetric key from the user's vault encryption key
    /// using HKDF-SHA256.
    ///
    /// - Returns: A `SymmetricKey` suitable for AES-256-GCM encryption.
    ///
    private func deriveKey() async throws -> SymmetricKey {
        let userKeyString = try await clientService.crypto().getUserEncryptionKey()
        guard let keyData = Data(base64Encoded: userKeyString) else {
            throw PendingChangeCountEncryptionError.invalidKey
        }
        let inputKey = SymmetricKey(data: keyData)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            info: Self.hkdfInfo,
            outputByteCount: Self.derivedKeyByteCount
        )
    }
}
