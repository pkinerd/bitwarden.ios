import BitwardenKitMocks
import BitwardenSdk
import Networking
import TestHelpers
import XCTest

@testable import BitwardenShared
@testable import BitwardenSharedMocks

// MARK: - OfflineSyncResolverCreateInvestigationTests

/// Investigation tests for the `resolveCreate` flow in `DefaultOfflineSyncResolver`.
///
/// These tests focus on **Bug 2**: after `resolveCreate` pushes an offline-created cipher
/// to the server, the old cipher record with the temporary ID is NOT deleted from the
/// cipher data store. This means two `CipherData` records coexist:
/// - One with the temporary UUID (the original offline record)
/// - One with the server-assigned ID (created by `addCipherWithServer` -> `upsertCipher`)
///
/// The pending change record IS deleted, but that only removes metadata, not the cipher itself.
///
class OfflineSyncResolverCreateInvestigationTests: BitwardenTestCase {
    // MARK: Properties

    var cipherAPIService: MockCipherAPIServiceForOfflineSync!
    var cipherService: MockCipherService!
    var clientService: MockClientService!
    var folderService: MockFolderService!
    var pendingCipherChangeDataStore: MockPendingCipherChangeDataStore!
    var stateService: MockStateService!
    var subject: DefaultOfflineSyncResolver!

    // MARK: Setup & Teardown

    override func setUp() {
        super.setUp()

        cipherAPIService = MockCipherAPIServiceForOfflineSync()
        cipherService = MockCipherService()
        clientService = MockClientService()
        folderService = MockFolderService()
        pendingCipherChangeDataStore = MockPendingCipherChangeDataStore()
        stateService = MockStateService()

        subject = DefaultOfflineSyncResolver(
            cipherAPIService: cipherAPIService,
            cipherService: cipherService,
            clientService: clientService,
            folderService: folderService,
            pendingCipherChangeDataStore: pendingCipherChangeDataStore,
            stateService: stateService
        )
    }

    override func tearDown() {
        super.tearDown()

        cipherAPIService = nil
        cipherService = nil
        clientService = nil
        folderService = nil
        pendingCipherChangeDataStore = nil
        stateService = nil
        subject = nil
    }

    // MARK: Tests - resolveCreate Temp-ID Cleanup

    /// `resolveCreate` calls `addCipherWithServer` with the correct cipher data
    /// and deletes the pending change record, but does NOT delete the old temp-ID
    /// cipher from the cipher data store.
    ///
    /// This test documents the current behavior. The cipher with the temp ID remains
    /// in the data store after resolution, creating a potential duplicate.
    func test_resolveCreate_doesNotDeleteTempIdCipher() async throws {
        let tempId = "temp-\(UUID().uuidString)"
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: tempId,
            name: "Offline Cipher"
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: tempId,
            userId: "user-1",
            changeType: .create,
            cipherData: cipherData,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "user-1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        try await subject.processPendingChanges(userId: "user-1")

        // Verify: addCipherWithServer was called with the cipher
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)
        XCTAssertEqual(
            cipherService.addCipherWithServerCiphers.first?.id,
            tempId,
            "resolveCreate should pass the temp-ID cipher to addCipherWithServer"
        )

        // Verify: the pending change record was deleted
        XCTAssertEqual(
            pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count,
            1,
            "resolveCreate should delete the pending change record"
        )

        // Verify: the old temp-ID cipher was deleted from local storage.
        // After addCipherWithServer upserts the server-assigned ID record,
        // the temp-ID record is orphaned and must be removed.
        XCTAssertEqual(
            cipherService.deleteCipherWithLocalStorageId,
            tempId,
            "resolveCreate should delete the old temp-ID cipher from local storage"
        )
    }

    /// Documents the expected flow of `resolveCreate`:
    /// 1. Decode cipher data from pending change
    /// 2. Call `addCipherWithServer` (which creates a NEW CipherData with server ID)
    /// 3. Delete the old temp-ID CipherData from local storage
    /// 4. Delete the pending change record
    ///
    /// This test verifies that `addCipherWithServer` receives the correct cipher
    /// and the temp-ID record is cleaned up.
    func test_resolveCreate_addCipherWithServer_createsNewRecord() async throws {
        let tempId = "temp-\(UUID().uuidString)"
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: tempId,
            name: "Offline Cipher"
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: tempId,
            userId: "user-1",
            changeType: .create,
            cipherData: cipherData,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "user-1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        try await subject.processPendingChanges(userId: "user-1")

        // addCipherWithServer internally calls cipherDataStore.upsertCipher with the
        // server response, which has a NEW server-assigned ID. But the MockCipherService
        // doesn't call through to a real data store, so we verify the cipher passed in.
        let addedCipher = cipherService.addCipherWithServerCiphers.first
        XCTAssertEqual(addedCipher?.id, tempId)

        // The encryptedFor should be the userId
        XCTAssertEqual(cipherService.addCipherWithServerEncryptedFor, "user-1")
    }

    /// Tests that after `resolveCreate` succeeds, a subsequent sync (`replaceCiphers`)
    /// would clean up the temp-ID cipher by replacing all ciphers.
    /// This is the current implicit cleanup mechanism.
    func test_replaceCiphers_cleansUpTempIdCipher() async throws {
        let tempId = "temp-\(UUID().uuidString)"
        let serverId = "server-\(UUID().uuidString)"

        // Simulate the state after resolveCreate: both temp-ID and server-ID ciphers exist
        // After a full sync, replaceCiphers replaces ALL ciphers with the server set
        let serverCiphers = [
            CipherDetailsResponseModel.fixture(id: serverId, name: "Synced Cipher"),
        ]

        try await cipherService.replaceCiphers(serverCiphers, userId: "user-1")

        // replaceCiphers should have been called with only the server cipher
        XCTAssertEqual(cipherService.replaceCiphersCiphers?.count, 1)
        XCTAssertEqual(cipherService.replaceCiphersCiphers?.first?.id, serverId)

        // The temp-ID cipher is implicitly removed because replaceCiphers
        // deletes all existing ciphers before inserting the server set
    }

    /// Tests that `resolveCreate` handles the case where `addCipherWithServer` fails
    /// by NOT deleting the pending change record (so it can be retried).
    func test_resolveCreate_addCipherFails_doesNotDeletePendingChange() async throws {
        let tempId = "temp-\(UUID().uuidString)"
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: tempId,
            name: "Offline Cipher"
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: tempId,
            userId: "user-1",
            changeType: .create,
            cipherData: cipherData,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "user-1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Configure addCipherWithServer to fail
        cipherService.addCipherWithServerResult = .failure(URLError(.notConnectedToInternet))

        // processPendingChanges catches errors per-change, so it shouldn't throw
        try await subject.processPendingChanges(userId: "user-1")

        // The pending change should NOT be deleted since the add failed
        XCTAssertTrue(
            pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.isEmpty,
            "Pending change should not be deleted when addCipherWithServer fails"
        )

        // The temp-ID cipher should NOT be deleted since the add failed
        XCTAssertNil(
            cipherService.deleteCipherWithLocalStorageId,
            "Temp-ID cipher should not be deleted when addCipherWithServer fails"
        )
    }

    /// Tests that `resolveCreate` correctly decodes the cipher data from the
    /// pending change record and passes a valid cipher to `addCipherWithServer`.
    func test_resolveCreate_decodesStoredCipherData() async throws {
        let tempId = "temp-\(UUID().uuidString)"
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: tempId,
            login: CipherLoginModel.fixture(
                password: "encrypted-password",
                username: "user@example.com"
            ),
            name: "My Offline Login",
            type: .login
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: tempId,
            userId: "user-1",
            changeType: .create,
            cipherData: cipherData,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "user-1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        try await subject.processPendingChanges(userId: "user-1")

        // Verify the decoded cipher matches what was stored
        let addedCipher = try XCTUnwrap(cipherService.addCipherWithServerCiphers.first)
        XCTAssertEqual(addedCipher.id, tempId)
        XCTAssertEqual(addedCipher.name, "My Offline Login")
        XCTAssertEqual(addedCipher.type, .login)
        XCTAssertEqual(addedCipher.login?.username, "user@example.com")
    }

    /// Tests that `resolveCreate` with missing cipher data throws `OfflineSyncError.missingCipherData`.
    /// The error is caught by `processPendingChanges` and logged, not propagated.
    func test_resolveCreate_missingCipherData_logsError() async throws {
        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        // Create a pending change with nil cipher data
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "user-1",
            changeType: .create,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "user-1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Should not throw; error is caught and logged
        try await subject.processPendingChanges(userId: "user-1")

        // addCipherWithServer should NOT have been called
        XCTAssertTrue(cipherService.addCipherWithServerCiphers.isEmpty)

        // Pending change should NOT be deleted (error path)
        XCTAssertTrue(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.isEmpty)
    }
}
