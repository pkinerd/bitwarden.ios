import BitwardenSdk
import Combine
import TestHelpers
import XCTest

@testable import BitwardenShared
@testable import BitwardenSharedMocks

// MARK: - OfflineSpinnerBugInvestigationTests

/// Investigation tests for the offline-created cipher spinner bug.
///
/// These tests systematically validate the hypothesized causes of the bug where
/// tapping an offline-created cipher in the vault list shows an infinite spinner
/// instead of the cipher details.
///
/// ## Hypotheses Under Test
///
/// **H1 (Primary):** `CipherView.id` is nil after the mock decrypt round-trip.
/// The `Cipher.withTemporaryId(_:)` method assigns a temp ID to the *encrypted* Cipher,
/// but the mock `CipherView(cipher:)` conversion or the real SDK decrypt may not
/// propagate the ID into the decrypted `CipherView`. If `CipherView.id` is nil,
/// `CipherItemState(existing:)` returns nil via its guard clause, causing
/// `buildViewItemState` to return nil, leaving the view in `.loading(nil)` forever.
///
/// **H2:** `resolveCreate` does not delete the old temp-ID cipher from the data store
/// after uploading to the server, potentially causing a duplicate cipher.
///
/// **H3:** The detail view's `cipherDetailsPublisher` uses single-cipher `decrypt(cipher:)`
/// which may throw for offline ciphers, while the vault list uses `decryptListWithFailures`
/// which is resilient to failures.
///
class OfflineSpinnerBugInvestigationTests: BitwardenTestCase {
    // MARK: Tests - H1: Round-trip CipherView.id Preservation

    /// Validates that the mock `CipherView(cipher:)` conversion preserves the cipher's ID.
    ///
    /// This is the most critical test: if ID is lost during the Cipher -> CipherView
    /// conversion, `CipherItemState(existing:)` will return nil due to its
    /// `guard cipherView.id != nil` check.
    func test_cipherViewFromCipher_preservesId() {
        let tempId = UUID().uuidString
        let cipher = Cipher.fixture(id: tempId, name: "Test Cipher")

        let cipherView = CipherView(cipher: cipher)

        XCTAssertEqual(
            cipherView.id,
            tempId,
            "CipherView.id should match the Cipher's ID after mock conversion"
        )
    }

    /// Validates the full offline creation round-trip:
    /// encrypt CipherView -> Cipher (via mock) -> withTemporaryId -> CipherView (via mock decrypt).
    ///
    /// This simulates the exact sequence that occurs during offline cipher creation
    /// and subsequent detail view loading.
    func test_offlineRoundTrip_mockEncryptThenWithTempIdThenDecrypt_preservesId() throws {
        // Step 1: Start with a CipherView (as the user would create)
        let originalCipherView = CipherView.fixture(
            id: nil,
            login: LoginView(
                username: "user@example.com",
                password: "password123",
                passwordRevisionDate: nil,
                uris: nil,
                totp: nil,
                autofillOnPageLoad: nil,
                fido2Credentials: nil
            ),
            name: "My Login"
        )

        // Step 2: Mock-encrypt the CipherView -> Cipher (simulates SDK encrypt)
        let encryptedCipher = Cipher(cipherView: originalCipherView)
        XCTAssertNil(encryptedCipher.id, "Newly encrypted cipher should have nil ID")

        // Step 3: Assign a temporary ID (as handleOfflineAdd does)
        let tempId = UUID().uuidString
        let cipherWithTempId = encryptedCipher.withTemporaryId(tempId)
        XCTAssertEqual(cipherWithTempId.id, tempId, "withTemporaryId should set the ID")

        // Step 4: Simulate storage and retrieval via CipherDetailsResponseModel round-trip
        let responseModel = try CipherDetailsResponseModel(cipher: cipherWithTempId)
        let storedCipher = Cipher(responseModel: responseModel)
        XCTAssertEqual(
            storedCipher.id,
            tempId,
            "Cipher ID should survive CipherDetailsResponseModel round-trip"
        )

        // Step 5: Mock-decrypt the stored cipher -> CipherView (simulates detail view)
        let decryptedCipherView = CipherView(cipher: storedCipher)

        // CRITICAL ASSERTION: Does the temp ID survive the full round-trip?
        XCTAssertEqual(
            decryptedCipherView.id,
            tempId,
            "INVESTIGATION: CipherView.id should equal tempId after full offline round-trip. "
                + "If this fails, it confirms H1: the detail view's CipherItemState guard returns nil."
        )
    }

    /// Validates that `withTemporaryId` sets `data` to nil, and confirms this
    /// does not prevent CipherDetailsResponseModel serialization.
    func test_withTemporaryId_dataNil_doesNotBreakSerialization() throws {
        let cipher = Cipher.fixture(id: "original-id", name: "Test")
        let cipherWithTempId = cipher.withTemporaryId("temp-id")

        // withTemporaryId explicitly sets data to nil
        // Verify this doesn't prevent JSON encoding via CipherDetailsResponseModel
        let responseModel = try CipherDetailsResponseModel(cipher: cipherWithTempId)
        let data = try JSONEncoder().encode(responseModel)
        XCTAssertFalse(data.isEmpty, "Should be able to encode cipher with nil data field")

        // Verify the round-trip preserves the temp ID
        let decoded = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: data)
        XCTAssertEqual(decoded.id, "temp-id")

        let roundTrippedCipher = Cipher(responseModel: decoded)
        XCTAssertEqual(roundTrippedCipher.id, "temp-id")
    }

    // MARK: Tests - H1: CipherItemState Guard Clause

    /// Confirms that `CipherItemState(existing:)` returns nil when the cipher has a nil ID.
    /// This is the direct mechanism that would cause the spinner bug if H1 is correct.
    func test_cipherItemState_nilId_returnsNil() {
        let cipherView = CipherView.fixture(id: nil, name: "No ID Cipher")

        let state = CipherItemState(
            existing: cipherView,
            hasPremium: true,
            iconBaseURL: nil
        )

        XCTAssertNil(
            state,
            "CipherItemState should return nil for a cipher with nil ID"
        )
    }

    /// Confirms that `CipherItemState(existing:)` succeeds when the cipher has an ID.
    func test_cipherItemState_withId_succeeds() {
        let cipherView = CipherView.fixture(id: "some-id", name: "Has ID Cipher")

        let state = CipherItemState(
            existing: cipherView,
            hasPremium: true,
            iconBaseURL: nil
        )

        XCTAssertNotNil(
            state,
            "CipherItemState should succeed for a cipher with a valid ID"
        )
    }

    /// Confirms that `CipherItemState(existing:)` succeeds with a UUID temp ID
    /// (the format used by offline creation).
    func test_cipherItemState_withTemporaryUuidId_succeeds() {
        let tempId = UUID().uuidString
        let cipherView = CipherView.fixture(id: tempId, name: "Offline Cipher")

        let state = CipherItemState(
            existing: cipherView,
            hasPremium: true,
            iconBaseURL: nil
        )

        XCTAssertNotNil(
            state,
            "CipherItemState should succeed for a cipher with a temp UUID ID"
        )
    }

    // MARK: Tests - H1: ViewItemState Construction

    /// Confirms that `ViewItemState(cipherView:hasPremium:iconBaseURL:)` returns nil
    /// when the underlying `CipherItemState` guard fails (nil ID).
    func test_viewItemState_nilId_returnsNil() {
        let cipherView = CipherView.fixture(id: nil, name: "No ID Cipher")

        let state = ViewItemState(
            cipherView: cipherView,
            hasPremium: true,
            iconBaseURL: nil
        )

        XCTAssertNil(
            state,
            "ViewItemState should return nil when CipherView.id is nil"
        )
    }

    /// Confirms that `ViewItemState` succeeds when the cipher has a valid temp ID.
    func test_viewItemState_withTempId_succeeds() {
        let tempId = UUID().uuidString
        let cipherView = CipherView.fixture(id: tempId, name: "Offline Cipher")

        let state = ViewItemState(
            cipherView: cipherView,
            hasPremium: true,
            iconBaseURL: nil
        )

        XCTAssertNotNil(
            state,
            "ViewItemState should succeed when CipherView has a temp UUID ID"
        )
    }

    // MARK: Tests - H3: Mock Decrypt Behavior

    /// Validates that `MockClientCiphers.decrypt(cipher:)` default implementation
    /// preserves the cipher ID in the resulting CipherView.
    func test_mockClientCiphers_decrypt_preservesCipherId() throws {
        let mockCiphers = MockClientCiphers()
        let tempId = UUID().uuidString
        let cipher = Cipher.fixture(id: tempId, name: "Offline Cipher")

        let decryptedView = try mockCiphers.decrypt(cipher: cipher)

        XCTAssertEqual(
            decryptedView.id,
            tempId,
            "MockClientCiphers.decrypt should preserve the cipher ID"
        )
    }

    /// Validates that `MockClientCiphers.decryptListWithFailures` includes
    /// the cipher with temp ID in its successes (not failures).
    func test_mockClientCiphers_decryptListWithFailures_includesTempIdCipher() {
        let mockCiphers = MockClientCiphers()
        let tempId = UUID().uuidString
        let cipher = Cipher.fixture(id: tempId, name: "Offline Cipher")

        let result = mockCiphers.decryptListWithFailures(ciphers: [cipher])

        XCTAssertEqual(result.successes.count, 1, "Should have one success")
        XCTAssertEqual(result.failures.count, 0, "Should have no failures")
        XCTAssertEqual(
            result.successes.first?.id,
            tempId,
            "The list view should preserve the temp ID"
        )
    }

    /// Validates the asymmetric decryption paths: the vault list uses
    /// `decryptListWithFailures` while the detail view uses `decrypt(cipher:)`.
    /// Both should handle offline-created ciphers identically.
    func test_asymmetricDecryptPaths_bothHandleTempIdCipher() throws {
        let mockCiphers = MockClientCiphers()
        let tempId = UUID().uuidString
        let cipher = Cipher.fixture(id: tempId, name: "Offline Cipher")

        // Path A: Vault list path (batch with failures)
        let listResult = mockCiphers.decryptListWithFailures(ciphers: [cipher])
        let listViewId = listResult.successes.first?.id

        // Path B: Detail view path (single cipher)
        let detailView = try mockCiphers.decrypt(cipher: cipher)
        let detailViewId = detailView.id

        XCTAssertEqual(listViewId, tempId, "List path should preserve temp ID")
        XCTAssertEqual(detailViewId, tempId, "Detail path should preserve temp ID")
        XCTAssertEqual(
            listViewId,
            detailViewId,
            "Both decrypt paths should produce the same ID"
        )
    }

    /// Validates that when `MockClientCiphers.decrypt` is configured to throw,
    /// the error propagates (simulating a real SDK failure for offline ciphers).
    func test_mockClientCiphers_decrypt_throwsError_propagates() {
        let mockCiphers = MockClientCiphers()
        let tempId = UUID().uuidString
        let cipher = Cipher.fixture(id: tempId, name: "Offline Cipher")

        // Configure mock to throw on decrypt
        mockCiphers.decryptResult = { _ in
            throw BitwardenTestError.example
        }

        XCTAssertThrowsError(
            try mockCiphers.decrypt(cipher: cipher),
            "decrypt should propagate the configured error"
        )
    }

    // MARK: Tests - JSON Round-Trip with Data Field

    /// Tests that a cipher created via `withTemporaryId` (which sets `data: nil`)
    /// can successfully round-trip through JSON encoding/decoding via
    /// CipherDetailsResponseModel. This is the exact path used in `handleOfflineAdd`.
    func test_cipherDetailsResponseModel_roundTrip_withTempIdCipher() throws {
        let originalCipher = Cipher.fixture(
            id: nil,
            login: Login(
                username: "user@example.com",
                password: "encrypted-password",
                passwordRevisionDate: nil,
                uris: nil,
                totp: nil,
                autofillOnPageLoad: nil,
                fido2Credentials: nil
            ),
            name: "Test Login",
            type: .login
        )

        let tempId = UUID().uuidString
        let cipherWithTempId = originalCipher.withTemporaryId(tempId)

        // Simulate handleOfflineAdd's encoding path
        let responseModel = try CipherDetailsResponseModel(cipher: cipherWithTempId)
        let jsonData = try JSONEncoder().encode(responseModel)

        // Simulate resolveCreate's decoding path
        let decodedModel = try JSONDecoder().decode(
            CipherDetailsResponseModel.self,
            from: jsonData
        )
        let recoveredCipher = Cipher(responseModel: decodedModel)

        XCTAssertEqual(recoveredCipher.id, tempId, "ID should survive JSON round-trip")
        XCTAssertEqual(recoveredCipher.name, "Test Login", "Name should survive JSON round-trip")
        XCTAssertEqual(recoveredCipher.type, .login, "Type should survive JSON round-trip")

        // Verify decryption produces a CipherView with the temp ID
        let decryptedView = CipherView(cipher: recoveredCipher)
        XCTAssertEqual(
            decryptedView.id,
            tempId,
            "Decrypted CipherView should have the temp ID after JSON round-trip"
        )
    }

    /// Tests the complete chain: CipherView.fixture(id: nil) -> encrypt -> withTemporaryId
    /// -> CipherDetailsResponseModel -> JSON -> decode -> Cipher -> CipherView -> CipherItemState.
    /// This is the end-to-end path from offline creation to detail view display.
    func test_endToEnd_offlineCipherToViewItemState() throws {
        // Simulate: user creates a new cipher
        let newCipherView = CipherView.fixture(
            id: nil,
            name: "New Offline Login"
        )

        // Simulate: SDK encrypts it (mock)
        let encrypted = Cipher(cipherView: newCipherView)

        // Simulate: handleOfflineAdd assigns temp ID
        let tempId = UUID().uuidString
        let withTempId = encrypted.withTemporaryId(tempId)

        // Simulate: store to Core Data via CipherDetailsResponseModel
        let responseModel = try CipherDetailsResponseModel(cipher: withTempId)
        let jsonData = try JSONEncoder().encode(responseModel)

        // Simulate: read from Core Data
        let decoded = try JSONDecoder().decode(
            CipherDetailsResponseModel.self,
            from: jsonData
        )
        let storedCipher = Cipher(responseModel: decoded)

        // Simulate: detail view decrypts the cipher
        let decryptedView = CipherView(cipher: storedCipher)

        // Simulate: ViewItemState construction (the path that triggers the spinner bug)
        let viewItemState = ViewItemState(
            cipherView: decryptedView,
            hasPremium: true,
            iconBaseURL: nil
        )

        XCTAssertNotNil(
            viewItemState,
            "INVESTIGATION: ViewItemState should be constructible from an offline-created cipher. "
                + "If this is nil, the detail view stays in .loading(nil) state (spinner forever)."
        )

        // If ViewItemState was created, verify it has the correct loading state
        if let state = viewItemState {
            guard case let .data(cipherItemState) = state.loadingState else {
                XCTFail("Expected .data loading state but got \(state.loadingState)")
                return
            }
            XCTAssertEqual(cipherItemState.name, "New Offline Login")
        }
    }
}
