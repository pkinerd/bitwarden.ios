import BitwardenSdk
import Foundation
import Networking

@testable import BitwardenShared

// MARK: - MockCipherAPIServiceForOfflineSync

/// A minimal mock for the cipher API service methods used by the offline sync resolver.
///
/// This mock exists because `CipherAPIService` does not have the `// sourcery: AutoMockable`
/// annotation, so no auto-generated mock is available. Only `getCipher(withId:)` is implemented;
/// all other protocol methods use `fatalError()` stubs. If the `CipherAPIService` protocol
/// changes (methods added, removed, or renamed), the stubs below must be updated to maintain
/// compilation. Consider adding `// sourcery: AutoMockable` to `CipherAPIService` to eliminate
/// this manual maintenance.
class MockCipherAPIServiceForOfflineSync: CipherAPIService {
    var getCipherResult: Result<CipherDetailsResponseModel, Error>!
    var getCipherCalledWith = [String]()

    func getCipher(withId id: String) async throws -> CipherDetailsResponseModel {
        getCipherCalledWith.append(id)
        return try getCipherResult.get()
    }

    var softDeleteCipherResult: Result<EmptyResponse, Error> = .success(EmptyResponse())
    var softDeleteCipherId: String?

    func softDeleteCipher(withID id: String) async throws -> EmptyResponse {
        softDeleteCipherId = id
        return try softDeleteCipherResult.get()
    }

    // MARK: Unused stubs - required by protocol

    func addCipher(_ cipher: Cipher, encryptedFor: String?) async throws -> CipherDetailsResponseModel { fatalError() }
    func archiveCipher(withID id: String) async throws -> EmptyResponse { fatalError() }
    func addCipherWithCollections(
        _ cipher: Cipher,
        encryptedFor: String?
    ) async throws -> CipherDetailsResponseModel { fatalError() }
    func bulkShareCiphers(
        _ ciphers: [Cipher],
        collectionIds: [String],
        encryptedFor: String?
    ) async throws -> BulkShareCiphersResponseModel { fatalError() }
    func deleteAttachment(
        withID attachmentId: String,
        cipherId: String
    ) async throws -> DeleteAttachmentResponse { fatalError() }
    func deleteCipher(withID id: String) async throws -> EmptyResponse { fatalError() }
    func downloadAttachment(
        withId id: String,
        cipherId: String
    ) async throws -> DownloadAttachmentResponse { fatalError() }
    func downloadAttachmentData(from url: URL) async throws -> URL? { fatalError() }
    func restoreCipher(withID id: String) async throws -> EmptyResponse { fatalError() }
    func saveAttachment(
        cipherId: String,
        fileName: String?,
        fileSize: Int?,
        key: String?
    ) async throws -> SaveAttachmentResponse { fatalError() }
    func shareCipher(
        _ cipher: Cipher,
        encryptedFor: String?
    ) async throws -> CipherDetailsResponseModel { fatalError() }

    func unarchiveCipher(withID id: String) async throws -> EmptyResponse { fatalError() }
    func updateCipher(
        _ cipher: Cipher,
        encryptedFor: String?
    ) async throws -> CipherDetailsResponseModel { fatalError() }
    func updateCipherCollections(_ cipher: Cipher) async throws { fatalError() }
    func updateCipherPreference(_ cipher: Cipher) async throws -> CipherDetailsResponseModel { fatalError() }
}
