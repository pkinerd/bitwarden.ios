import BitwardenKitMocks
import CryptoKit
import XCTest

@testable import BitwardenShared

class PendingChangeCountEncryptionServiceTests: BitwardenTestCase {
    // MARK: Properties

    var clientService: MockClientService!
    var subject: DefaultPendingChangeCountEncryptionService!

    // MARK: Setup & Teardown

    override func setUp() {
        super.setUp()

        clientService = MockClientService()

        // Configure the mock crypto client to return a valid base64-encoded 256-bit key.
        let testKey = SymmetricKey(size: .bits256)
        let keyData = testKey.withUnsafeBytes { Data(Array($0)) }
        clientService.mockCrypto.getUserEncryptionKeyResult = .success(keyData.base64EncodedString())

        subject = DefaultPendingChangeCountEncryptionService(
            clientService: clientService
        )
    }

    override func tearDown() {
        super.tearDown()

        clientService = nil
        subject = nil
    }

    // MARK: Tests

    /// `encrypt(count:)` followed by `decrypt(data:)` returns the original count.
    func test_encryptDecrypt_roundTrip() async throws {
        let originalCount: Int16 = 4
        let encrypted = try await subject.encrypt(count: originalCount)
        let decrypted = try await subject.decrypt(data: encrypted)
        XCTAssertEqual(decrypted, originalCount)
    }

    /// `encrypt(count:)` followed by `decrypt(data:)` works for a count of zero.
    func test_encryptDecrypt_roundTrip_zero() async throws {
        let originalCount: Int16 = 0
        let encrypted = try await subject.encrypt(count: originalCount)
        let decrypted = try await subject.decrypt(data: encrypted)
        XCTAssertEqual(decrypted, originalCount)
    }

    /// `encrypt(count:)` produces non-deterministic ciphertext (different each time due to
    /// random nonce).
    func test_encrypt_producesNonDeterministicOutput() async throws {
        let count: Int16 = 3
        let encrypted1 = try await subject.encrypt(count: count)
        let encrypted2 = try await subject.encrypt(count: count)
        XCTAssertNotEqual(encrypted1, encrypted2)
    }

    /// `decrypt(data:)` throws an error when given invalid data.
    func test_decrypt_invalidData_throws() async throws {
        let invalidData = Data("not-encrypted".utf8)
        await assertAsyncThrows {
            _ = try await subject.decrypt(data: invalidData)
        }
    }

    /// `encrypt(count:)` throws an error when the user encryption key is not valid base64.
    func test_encrypt_invalidKey_throws() async throws {
        clientService.mockCrypto.getUserEncryptionKeyResult = .success("not-base64!@#$")
        await assertAsyncThrows(error: PendingChangeCountEncryptionError.invalidKey) {
            _ = try await subject.encrypt(count: 1)
        }
    }

    /// `decrypt(data:)` throws an error when the user encryption key is not valid base64.
    func test_decrypt_invalidKey_throws() async throws {
        // First encrypt with a valid key.
        let encrypted = try await subject.encrypt(count: 1)

        // Now break the key.
        clientService.mockCrypto.getUserEncryptionKeyResult = .success("not-base64!@#$")
        await assertAsyncThrows(error: PendingChangeCountEncryptionError.invalidKey) {
            _ = try await subject.decrypt(data: encrypted)
        }
    }

    /// `decrypt(data:)` fails when decrypted with a different key than it was encrypted with.
    func test_decrypt_wrongKey_throws() async throws {
        let encrypted = try await subject.encrypt(count: 5)

        // Change to a different key.
        let differentKey = SymmetricKey(size: .bits256)
        let differentKeyData = differentKey.withUnsafeBytes { Data(Array($0)) }
        clientService.mockCrypto.getUserEncryptionKeyResult = .success(differentKeyData.base64EncodedString())

        await assertAsyncThrows {
            _ = try await subject.decrypt(data: encrypted)
        }
    }
}
