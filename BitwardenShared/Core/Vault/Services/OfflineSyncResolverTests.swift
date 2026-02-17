import BitwardenKitMocks
import BitwardenSdk
import Networking
import XCTest

@testable import BitwardenShared
@testable import BitwardenSharedMocks

// MARK: - MockCipherAPIServiceForOfflineSync

/// A minimal inline mock for the cipher API service methods used by the offline sync resolver.
///
/// This mock exists because `CipherAPIService` does not have the `// sourcery: AutoMockable`
/// annotation, so no auto-generated mock is available. Only `getCipher(withId:)` is implemented;
/// all other protocol methods use `fatalError()` stubs. If the `CipherAPIService` protocol
/// changes (methods added, removed, or renamed), the stubs below must be updated to maintain
/// compilation. Consider adding `// sourcery: AutoMockable` to `CipherAPIService` to eliminate
/// this manual maintenance.
class MockCipherAPIServiceForOfflineSync: CipherAPIService {
    var getCipherResult: Result<CipherDetailsResponseModel, Error> = .success(.fixture())
    var getCipherCalledWith = [String]()

    func getCipher(withId id: String) async throws -> CipherDetailsResponseModel {
        getCipherCalledWith.append(id)
        return try getCipherResult.get()
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
    func softDeleteCipher(withID id: String) async throws -> EmptyResponse { fatalError() }
    func unarchiveCipher(withID id: String) async throws -> EmptyResponse { fatalError() }
    func updateCipher(
        _ cipher: Cipher,
        encryptedFor: String?
    ) async throws -> CipherDetailsResponseModel { fatalError() }
    func updateCipherCollections(_ cipher: Cipher) async throws { fatalError() }
    func updateCipherPreference(_ cipher: Cipher) async throws -> CipherDetailsResponseModel { fatalError() }
}

// MARK: - OfflineSyncResolverTests

// swiftlint:disable:next type_body_length
class OfflineSyncResolverTests: BitwardenTestCase {
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

    // MARK: Tests - processPendingChanges

    /// `processPendingChanges(userId:)` does nothing when there are no pending changes.
    func test_processPendingChanges_noPendingChanges() async throws {
        pendingCipherChangeDataStore.fetchPendingChangesResult = []

        try await subject.processPendingChanges(userId: "1")

        XCTAssertTrue(pendingCipherChangeDataStore.fetchPendingChangesCalledWith.contains("1"))
        XCTAssertTrue(cipherService.addCipherWithServerCiphers.isEmpty)
        XCTAssertTrue(cipherService.updateCipherWithServerCiphers.isEmpty)
    }

    /// `processPendingChanges(userId:)` with a `.create` pending change calls `addCipherWithServer`
    /// and then deletes the pending change record.
    func test_processPendingChanges_create() async throws {
        let cipherResponseModel = CipherDetailsResponseModel.fixture(id: "cipher-1")
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .create,
            cipherData: cipherData,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        try await subject.processPendingChanges(userId: "1")

        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.first?.id, "cipher-1")
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    /// `processPendingChanges(userId:)` with a `.update` pending change where the server
    /// has not changed (same revisionDate) calls `updateCipherWithServer`.
    func test_processPendingChanges_update_noConflict() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 1
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server cipher has the same revisionDate
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        ))

        try await subject.processPendingChanges(userId: "1")

        // Should call updateCipherWithServer (no conflict, fewer than 4 password changes)
        XCTAssertEqual(cipherService.updateCipherWithServerCiphers.count, 1)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    /// `processPendingChanges(userId:)` with a `.softDelete` change calls
    /// `softDeleteCipherWithServer` and deletes the pending change.
    func test_processPendingChanges_softDelete_noConflict() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .softDelete,
            cipherData: cipherData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server cipher has the same revisionDate
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        ))

        try await subject.processPendingChanges(userId: "1")

        // Should call softDeleteCipherWithServer
        XCTAssertEqual(cipherService.softDeleteCipherId, "cipher-1")

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    // MARK: Tests - Conflict Resolution

    /// `processPendingChanges(userId:)` with a `.update` pending change where the server
    /// revision date differs from the original revision date (conflict detected) and the
    /// local `updatedDate` is newer than the server revision date pushes the local cipher
    /// to the server and creates a backup of the server version.
    func test_processPendingChanges_update_conflict_localNewer() async throws {
        let originalRevisionDate = Date(year: 2024, month: 6, day: 1)
        let serverRevisionDate = Date(year: 2024, month: 6, day: 15)
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-1",
            revisionDate: originalRevisionDate
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            offlinePasswordChangeCount: 1
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server cipher has a different revision date (triggers conflict).
        // The server revision date (June 15, 2024) is older than the local updatedDate
        // (approximately "now"), so local wins.
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: serverRevisionDate
        ))

        // Set up folder creation for the backup cipher.
        folderService.fetchAllFoldersResult = .success([])
        folderService.addFolderWithServerResult = .success(
            Folder.fixture(id: "conflict-folder-id", name: "Offline Sync Conflicts")
        )

        try await subject.processPendingChanges(userId: "1")

        // Local is newer: should push local cipher to server.
        XCTAssertEqual(cipherService.updateCipherWithServerCiphers.count, 1)
        XCTAssertEqual(cipherService.updateCipherWithServerCiphers.first?.id, "cipher-1")

        // Should create a backup of the server cipher.
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)

        // Server cipher should not be written to local storage.
        XCTAssertTrue(cipherService.updateCipherWithLocalStorageCiphers.isEmpty)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    /// `processPendingChanges(userId:)` with a `.update` pending change where the server
    /// revision date differs from the original revision date (conflict detected) and the
    /// server revision date is newer than the local `updatedDate` keeps the server version
    /// in local storage and creates a backup of the local version.
    func test_processPendingChanges_update_conflict_serverNewer() async throws {
        let originalRevisionDate = Date(year: 2024, month: 6, day: 1)
        // Use a far-future date so the server revision date is always newer than the
        // local updatedDate (which is set to Date() at the time of upsert).
        let serverRevisionDate = Date(year: 2099, month: 1, day: 1)
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-1",
            name: "Local Cipher",
            revisionDate: originalRevisionDate
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            offlinePasswordChangeCount: 1
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server cipher has a different revision date (triggers conflict) and its
        // revision date (2099) is newer than the local updatedDate (~now).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            name: "Server Cipher",
            revisionDate: serverRevisionDate
        ))

        // Set up folder creation for the backup cipher.
        folderService.fetchAllFoldersResult = .success([])
        folderService.addFolderWithServerResult = .success(
            Folder.fixture(id: "conflict-folder-id", name: "Offline Sync Conflicts")
        )

        try await subject.processPendingChanges(userId: "1")

        // Server is newer: should update local storage with the server cipher.
        XCTAssertEqual(cipherService.updateCipherWithLocalStorageCiphers.count, 1)
        XCTAssertEqual(cipherService.updateCipherWithLocalStorageCiphers.first?.id, "cipher-1")

        // Should create a backup of the local cipher.
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)

        // Should NOT push local cipher to the server.
        XCTAssertTrue(cipherService.updateCipherWithServerCiphers.isEmpty)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    /// `processPendingChanges(userId:)` with a `.update` pending change where the server
    /// revision date matches the original (no conflict) but the offline password change
    /// count is at least 4 (soft conflict) pushes the local cipher and creates a backup
    /// of the server version.
    func test_processPendingChanges_update_softConflict() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 4
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server cipher has the same revision date (no conflict).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        ))

        // Set up folder creation for the backup cipher.
        folderService.fetchAllFoldersResult = .success([])
        folderService.addFolderWithServerResult = .success(
            Folder.fixture(id: "conflict-folder-id", name: "Offline Sync Conflicts")
        )

        try await subject.processPendingChanges(userId: "1")

        // Soft conflict: should push local cipher to server.
        XCTAssertEqual(cipherService.updateCipherWithServerCiphers.count, 1)
        XCTAssertEqual(cipherService.updateCipherWithServerCiphers.first?.id, "cipher-1")

        // Should create a backup of the server cipher.
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    /// `processPendingChanges(userId:)` with a `.softDelete` pending change where the
    /// server revision date differs from the original (conflict) creates a backup of the
    /// server version before completing the soft delete.
    func test_processPendingChanges_softDelete_conflict() async throws {
        let originalRevisionDate = Date(year: 2024, month: 6, day: 1)
        let serverRevisionDate = Date(year: 2024, month: 6, day: 15)
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-1",
            revisionDate: originalRevisionDate
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .softDelete,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server cipher has a different revision date (triggers conflict).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: serverRevisionDate
        ))

        // Set up folder creation for the backup cipher.
        folderService.fetchAllFoldersResult = .success([])
        folderService.addFolderWithServerResult = .success(
            Folder.fixture(id: "conflict-folder-id", name: "Offline Sync Conflicts")
        )

        try await subject.processPendingChanges(userId: "1")

        // Should create a backup of the server cipher before deleting.
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)

        // Should complete the soft delete.
        XCTAssertEqual(cipherService.softDeleteCipherId, "cipher-1")
        XCTAssertNotNil(cipherService.softDeleteCipher)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    /// `processPendingChanges(userId:)` when resolving a conflict creates the
    /// "Offline Sync Conflicts" folder via `folderService` and assigns the backup
    /// cipher to that folder.
    func test_processPendingChanges_update_conflict_createsConflictFolder() async throws {
        let originalRevisionDate = Date(year: 2024, month: 6, day: 1)
        let serverRevisionDate = Date(year: 2024, month: 6, day: 15)
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-1",
            name: "My Login",
            revisionDate: originalRevisionDate
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            offlinePasswordChangeCount: 1
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server cipher has a different revision date (triggers conflict).
        // The server revision date (June 15, 2024) is older than the local updatedDate
        // (approximately "now"), so local wins and the server version is backed up.
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            name: "My Login",
            revisionDate: serverRevisionDate
        ))

        // No existing folders; a new conflict folder should be created.
        folderService.fetchAllFoldersResult = .success([])
        folderService.addFolderWithServerResult = .success(
            Folder.fixture(id: "conflict-folder-id", name: "Offline Sync Conflicts")
        )

        try await subject.processPendingChanges(userId: "1")

        // Should encrypt the folder name before creating it on the server.
        XCTAssertEqual(
            clientService.mockVault.clientFolders.encryptedFolders.first?.name,
            "Offline Sync Conflicts"
        )
        XCTAssertEqual(folderService.addedFolderName, "Offline Sync Conflicts")

        // The backup cipher view should be assigned to the conflict folder.
        XCTAssertEqual(
            clientService.mockVault.clientCiphers.encryptedCiphers.first?.folderId,
            "conflict-folder-id"
        )

        // The backup cipher view name should include the offline conflict marker.
        XCTAssertTrue(
            clientService.mockVault.clientCiphers.encryptedCiphers.first?.name
                .contains("offline conflict") ?? false
        )

        // Should push the local cipher and create a backup.
        XCTAssertEqual(cipherService.updateCipherWithServerCiphers.count, 1)
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)
    }

    // MARK: Tests - Cipher Not Found (404)

    /// `processPendingChanges(userId:)` with a `.update` pending change where the server
    /// returns a 404 (cipher deleted on server while offline) re-creates the cipher on the
    /// server to preserve the user's offline edits, then cleans up the pending change.
    func test_processPendingChanges_update_cipherNotFound_recreates() async throws {
        let cipherResponseModel = CipherDetailsResponseModel.fixture(id: "cipher-1")
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: Date(year: 2024, month: 6, day: 1),
            offlinePasswordChangeCount: 1
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server returns 404 — cipher was deleted while offline.
        cipherAPIService.getCipherResult = .failure(OfflineSyncError.cipherNotFound)

        try await subject.processPendingChanges(userId: "1")

        // Should re-create the cipher on the server via addCipherWithServer.
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.first?.id, "cipher-1")

        // Should NOT call updateCipherWithServer (the update path is skipped).
        XCTAssertTrue(cipherService.updateCipherWithServerCiphers.isEmpty)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    /// `processPendingChanges(userId:)` with a `.softDelete` pending change where the server
    /// returns a 404 (cipher already deleted on server) cleans up the local record and
    /// pending change without attempting the soft delete.
    func test_processPendingChanges_softDelete_cipherNotFound_cleansUp() async throws {
        let cipherResponseModel = CipherDetailsResponseModel.fixture(id: "cipher-1")
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .softDelete,
            cipherData: cipherData,
            originalRevisionDate: Date(year: 2024, month: 6, day: 1),
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server returns 404 — cipher is already gone.
        cipherAPIService.getCipherResult = .failure(OfflineSyncError.cipherNotFound)

        try await subject.processPendingChanges(userId: "1")

        // Should clean up the local cipher record.
        XCTAssertEqual(cipherService.deleteCipherWithLocalStorageId, "cipher-1")

        // Should NOT attempt to soft delete on the server.
        XCTAssertNil(cipherService.softDeleteCipherId)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    // MARK: Tests - OfflineSyncError

    /// `OfflineSyncError.organizationCipherOfflineEditNotSupported` provides a localized description.
    func test_offlineSyncError_localizedDescription() {
        let error = OfflineSyncError.organizationCipherOfflineEditNotSupported
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Organization") ?? false)
    }

    /// `OfflineSyncError.vaultLocked` provides a localized description.
    func test_offlineSyncError_vaultLocked_localizedDescription() {
        let error = OfflineSyncError.vaultLocked
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("locked") ?? false)
    }

    // MARK: Tests - API Failure Handling

    /// `processPendingChanges(userId:)` retains the pending record when a `.create`
    /// resolution fails because `addCipherWithServer` throws.
    func test_processPendingChanges_create_apiFailure_pendingRecordRetained() async throws {
        let cipherResponseModel = CipherDetailsResponseModel.fixture(id: "cipher-1")
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .create,
            cipherData: cipherData,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Make the API call fail.
        cipherService.addCipherWithServerResult = .failure(BitwardenTestError.example)

        try await subject.processPendingChanges(userId: "1")

        // The pending record should NOT be deleted when the API call fails.
        XCTAssertTrue(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.isEmpty)
    }

    /// `processPendingChanges(userId:)` retains the pending record when an `.update`
    /// resolution fails because `getCipher` throws a non-404 error during server fetch.
    func test_processPendingChanges_update_serverFetchFailure_pendingRecordRetained() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Make the server fetch fail with a non-404 error.
        cipherAPIService.getCipherResult = .failure(BitwardenTestError.example)

        try await subject.processPendingChanges(userId: "1")

        // The pending record should NOT be deleted.
        XCTAssertTrue(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.isEmpty)

        // The update should never have been attempted.
        XCTAssertTrue(cipherService.updateCipherWithServerCiphers.isEmpty)
    }

    /// `processPendingChanges(userId:)` retains the pending record when a `.softDelete`
    /// resolution fails because `softDeleteCipherWithServer` throws.
    func test_processPendingChanges_softDelete_apiFailure_pendingRecordRetained() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .softDelete,
            cipherData: cipherData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server fetch succeeds with the same revisionDate (no conflict).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        ))

        // Make the soft delete API call fail.
        cipherService.softDeleteWithServerResult = .failure(BitwardenTestError.example)

        try await subject.processPendingChanges(userId: "1")

        // The pending record should NOT be deleted.
        XCTAssertTrue(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.isEmpty)
    }

    /// `processPendingChanges(userId:)` retains the pending record when an `.update`
    /// resolution detects a conflict but the backup creation fails because
    /// `addCipherWithServer` throws during `createBackupCipher`.
    func test_processPendingChanges_update_backupFailure_pendingRecordRetained() async throws {
        let originalRevisionDate = Date(year: 2024, month: 6, day: 1)
        let serverRevisionDate = Date(year: 2024, month: 6, day: 15)
        let cipherResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-1",
            revisionDate: originalRevisionDate
        )
        let cipherData = try JSONEncoder().encode(cipherResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            offlinePasswordChangeCount: 1
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server has a different revisionDate (triggers conflict).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: serverRevisionDate
        ))

        // Set up folder creation for the backup cipher.
        folderService.fetchAllFoldersResult = .success([])
        folderService.addFolderWithServerResult = .success(
            Folder.fixture(id: "conflict-folder-id", name: "Offline Sync Conflicts")
        )

        // Make the backup cipher creation fail. In the conflict path (local newer),
        // the backup is created first via `createBackupCipher` which calls
        // `addCipherWithServer`. This failure prevents the main update from executing.
        cipherService.addCipherWithServerResult = .failure(BitwardenTestError.example)

        try await subject.processPendingChanges(userId: "1")

        // The pending record should NOT be deleted.
        XCTAssertTrue(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.isEmpty)

        // The main update should NOT have been attempted since the backup failed first.
        XCTAssertTrue(cipherService.updateCipherWithServerCiphers.isEmpty)
    }

    // MARK: Tests - Batch Processing

    /// `processPendingChanges(userId:)` processes multiple pending changes of different
    /// types (create, update, soft delete) in a single batch and cleans up all resolved records.
    func test_processPendingChanges_batch_allSucceed() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)

        // Create pending change: cipher-1 (.create)
        let createResponseModel = CipherDetailsResponseModel.fixture(id: "cipher-1")
        let createData = try JSONEncoder().encode(createResponseModel)

        // Update pending change: cipher-2 (.update)
        let updateResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-2",
            revisionDate: revisionDate
        )
        let updateData = try JSONEncoder().encode(updateResponseModel)

        // SoftDelete pending change: cipher-3 (.softDelete)
        let softDeleteResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-3",
            revisionDate: revisionDate
        )
        let softDeleteData = try JSONEncoder().encode(softDeleteResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .create,
            cipherData: createData,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-2",
            userId: "1",
            changeType: .update,
            cipherData: updateData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 0
        )
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-3",
            userId: "1",
            changeType: .softDelete,
            cipherData: softDeleteData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Server returns same revisionDate for update and soft delete (no conflict).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-2",
            revisionDate: revisionDate
        ))

        try await subject.processPendingChanges(userId: "1")

        // Create should call addCipherWithServer.
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.first?.id, "cipher-1")

        // Update should call updateCipherWithServer.
        XCTAssertEqual(cipherService.updateCipherWithServerCiphers.count, 1)

        // SoftDelete should call softDeleteCipherWithServer.
        XCTAssertNotNil(cipherService.softDeleteCipherId)

        // All three pending records should be deleted.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 3)
    }

    /// `processPendingChanges(userId:)` resolves successful items and retains failed items'
    /// pending records when a batch contains a mix of successful and failing resolutions.
    /// The catch-and-continue error handling ensures that one item's failure does not block others.
    func test_processPendingChanges_batch_mixedFailure_successfulItemResolved() async throws {
        // Create pending change: cipher-1 (.create) — will succeed.
        let createResponseModel = CipherDetailsResponseModel.fixture(id: "cipher-1")
        let createData = try JSONEncoder().encode(createResponseModel)

        // Update pending change: cipher-2 (.update) — will fail (getCipher throws).
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        let updateResponseModel = CipherDetailsResponseModel.fixture(
            id: "cipher-2",
            revisionDate: revisionDate
        )
        let updateData = try JSONEncoder().encode(updateResponseModel)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .create,
            cipherData: createData,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-2",
            userId: "1",
            changeType: .update,
            cipherData: updateData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // The create path does not call getCipher, so it succeeds.
        // The update path calls getCipher, which fails.
        cipherAPIService.getCipherResult = .failure(BitwardenTestError.example)

        try await subject.processPendingChanges(userId: "1")

        // Create should have succeeded.
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.first?.id, "cipher-1")

        // Only the create's pending record should be deleted; the update's remains.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)

        // The update should not have been attempted (failed at getCipher).
        XCTAssertTrue(cipherService.updateCipherWithServerCiphers.isEmpty)
    }

    /// `processPendingChanges(userId:)` retains all pending records when every item in
    /// the batch fails.
    func test_processPendingChanges_batch_allFail() async throws {
        // Two create pending changes — both will fail.
        let createResponseModel1 = CipherDetailsResponseModel.fixture(id: "cipher-1")
        let createData1 = try JSONEncoder().encode(createResponseModel1)

        let createResponseModel2 = CipherDetailsResponseModel.fixture(id: "cipher-2")
        let createData2 = try JSONEncoder().encode(createResponseModel2)

        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .create,
            cipherData: createData1,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-2",
            userId: "1",
            changeType: .create,
            cipherData: createData2,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        let pendingChanges = try await dataStore.fetchPendingChanges(userId: "1")
        pendingCipherChangeDataStore.fetchPendingChangesResult = pendingChanges

        // Make addCipherWithServer fail for all items.
        cipherService.addCipherWithServerResult = .failure(BitwardenTestError.example)

        try await subject.processPendingChanges(userId: "1")

        // Both items should have been attempted.
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 2)

        // No pending records should be deleted since both failed.
        XCTAssertTrue(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.isEmpty)
    }
}
