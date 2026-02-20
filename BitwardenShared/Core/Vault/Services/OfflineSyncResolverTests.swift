import BitwardenKitMocks
import BitwardenSdk
import Networking
import TestHelpers
import XCTest

@testable import BitwardenShared
@testable import BitwardenSharedMocks

// MARK: - OfflineSyncResolverTests

// swiftlint:disable:next type_body_length
class OfflineSyncResolverTests: BitwardenTestCase {
    // MARK: Properties

    var cipherAPIService: MockCipherAPIServiceForOfflineSync!
    var cipherService: MockCipherService!
    var clientService: MockClientService!
    var pendingCipherChangeDataStore: MockPendingCipherChangeDataStore!
    var subject: DefaultOfflineSyncResolver!

    // MARK: Setup & Teardown

    override func setUp() {
        super.setUp()

        cipherAPIService = MockCipherAPIServiceForOfflineSync()
        cipherService = MockCipherService()
        clientService = MockClientService()
        pendingCipherChangeDataStore = MockPendingCipherChangeDataStore()

        subject = DefaultOfflineSyncResolver(
            cipherAPIService: cipherAPIService,
            cipherService: cipherService,
            clientService: clientService,
            pendingCipherChangeDataStore: pendingCipherChangeDataStore
        )
    }

    override func tearDown() {
        super.tearDown()

        cipherAPIService = nil
        cipherService = nil
        clientService = nil
        pendingCipherChangeDataStore = nil
        subject = nil
    }

    // MARK: Helpers

    /// Creates a single pending change in an in-memory data store and configures the mock.
    private func setupPendingChange(
        cipherId: String = "cipher-1",
        changeType: PendingCipherChangeType,
        cipherData: Data? = nil,
        originalRevisionDate: Date? = nil,
        offlinePasswordChangeCount: Int16 = 0
    ) async throws {
        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: cipherId,
            userId: "1",
            changeType: changeType,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            offlinePasswordChangeCount: offlinePasswordChangeCount
        )
        pendingCipherChangeDataStore.fetchPendingChangesResult =
            try await dataStore.fetchPendingChanges(userId: "1")
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
        let cipherData = try JSONEncoder().encode(CipherDetailsResponseModel.fixture(id: "cipher-1"))
        try await setupPendingChange(changeType: .create, cipherData: cipherData)

        try await subject.processPendingChanges(userId: "1")

        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.first?.id, "cipher-1")
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    /// `processPendingChanges(userId:)` with a `.update` pending change where the server
    /// has not changed (same revisionDate) calls `updateCipherWithServer`.
    func test_processPendingChanges_update_noConflict() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(id: "cipher-1", revisionDate: revisionDate)
        )
        try await setupPendingChange(
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 1
        )

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
    /// `cipherAPIService.softDeleteCipher(withID:)` and deletes the pending change.
    func test_processPendingChanges_softDelete_noConflict() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(id: "cipher-1", revisionDate: revisionDate)
        )
        try await setupPendingChange(
            changeType: .softDelete,
            cipherData: cipherData,
            originalRevisionDate: revisionDate
        )

        // Server cipher has the same revisionDate
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        ))

        try await subject.processPendingChanges(userId: "1")

        // Should call cipherAPIService.softDeleteCipher(withID:) directly.
        XCTAssertEqual(cipherAPIService.softDeleteCipherId, "cipher-1")

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
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(id: "cipher-1", revisionDate: originalRevisionDate)
        )
        try await setupPendingChange(
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            offlinePasswordChangeCount: 1
        )

        // Server cipher has a different revision date (triggers conflict).
        // The server revision date (June 15, 2024) is older than the local updatedDate
        // (approximately "now"), so local wins.
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: serverRevisionDate
        ))

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
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(
                id: "cipher-1", name: "Local Cipher", revisionDate: originalRevisionDate
            )
        )
        try await setupPendingChange(
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            offlinePasswordChangeCount: 1
        )

        // Server cipher has a different revision date (triggers conflict) and its
        // revision date (2099) is newer than the local updatedDate (~now).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            name: "Server Cipher",
            revisionDate: serverRevisionDate
        ))

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
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(id: "cipher-1", revisionDate: revisionDate)
        )
        try await setupPendingChange(
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 4
        )

        // Server cipher has the same revision date (no conflict).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        ))

        try await subject.processPendingChanges(userId: "1")

        // Soft conflict: should push local cipher to server.
        XCTAssertEqual(cipherService.updateCipherWithServerCiphers.count, 1)
        XCTAssertEqual(cipherService.updateCipherWithServerCiphers.first?.id, "cipher-1")

        // Should create a backup of the server cipher.
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    // MARK: Tests - Password History Preservation

    /// `processPendingChanges(userId:)` with a hard conflict where local wins preserves
    /// the server version's password history on the backup cipher and the local version's
    /// password history on the pushed cipher without merging the two.
    func test_processPendingChanges_update_conflict_localNewer_preservesPasswordHistory() async throws {
        let originalRevisionDate = Date(year: 2024, month: 6, day: 1)
        let serverRevisionDate = Date(year: 2024, month: 6, day: 15)

        // Local cipher with its own password history from offline edits.
        let localPasswordHistory = [
            CipherPasswordHistoryModel(
                lastUsedDate: Date(year: 2024, month: 5, day: 1),
                password: "local-old-pass"
            ),
        ]
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(
                id: "cipher-1",
                passwordHistory: localPasswordHistory,
                revisionDate: originalRevisionDate
            )
        )
        try await setupPendingChange(
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            offlinePasswordChangeCount: 1
        )

        // Server cipher with a different password history.
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            passwordHistory: [
                CipherPasswordHistoryModel(
                    lastUsedDate: Date(year: 2024, month: 6, day: 10),
                    password: "server-old-pass"
                ),
            ],
            revisionDate: serverRevisionDate
        ))

        try await subject.processPendingChanges(userId: "1")

        // Backup should contain the server version's password history (not merged).
        let backupCipher = try XCTUnwrap(cipherService.addCipherWithServerCiphers.first)
        XCTAssertEqual(backupCipher.passwordHistory?.count, 1)
        XCTAssertEqual(backupCipher.passwordHistory?.first?.password, "server-old-pass")

        // Pushed cipher should contain the local version's password history (not merged).
        let pushedCipher = try XCTUnwrap(cipherService.updateCipherWithServerCiphers.first)
        XCTAssertEqual(pushedCipher.passwordHistory?.count, 1)
        XCTAssertEqual(pushedCipher.passwordHistory?.first?.password, "local-old-pass")
    }

    /// `processPendingChanges(userId:)` with a hard conflict where server wins preserves
    /// the local version's password history on the backup cipher and the server version's
    /// password history in local storage without merging the two.
    func test_processPendingChanges_update_conflict_serverNewer_preservesPasswordHistory() async throws {
        let originalRevisionDate = Date(year: 2024, month: 6, day: 1)
        let serverRevisionDate = Date(year: 2099, month: 1, day: 1)

        // Local cipher with its own password history from offline edits.
        let localPasswordHistory = [
            CipherPasswordHistoryModel(
                lastUsedDate: Date(year: 2024, month: 5, day: 1),
                password: "local-old-pass-1"
            ),
            CipherPasswordHistoryModel(
                lastUsedDate: Date(year: 2024, month: 5, day: 15),
                password: "local-old-pass-2"
            ),
        ]
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(
                id: "cipher-1",
                passwordHistory: localPasswordHistory,
                revisionDate: originalRevisionDate
            )
        )
        try await setupPendingChange(
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            offlinePasswordChangeCount: 1
        )

        // Server cipher with a different password history.
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            passwordHistory: [
                CipherPasswordHistoryModel(
                    lastUsedDate: Date(year: 2024, month: 6, day: 10),
                    password: "server-old-pass"
                ),
            ],
            revisionDate: serverRevisionDate
        ))

        try await subject.processPendingChanges(userId: "1")

        // Backup should contain the local version's password history (not merged).
        let backupCipher = try XCTUnwrap(cipherService.addCipherWithServerCiphers.first)
        XCTAssertEqual(backupCipher.passwordHistory?.count, 2)
        XCTAssertEqual(backupCipher.passwordHistory?[0].password, "local-old-pass-1")
        XCTAssertEqual(backupCipher.passwordHistory?[1].password, "local-old-pass-2")

        // Local storage should contain the server version's password history (not merged).
        let storedCipher = try XCTUnwrap(cipherService.updateCipherWithLocalStorageCiphers.first)
        XCTAssertEqual(storedCipher.passwordHistory?.count, 1)
        XCTAssertEqual(storedCipher.passwordHistory?.first?.password, "server-old-pass")
    }

    /// `processPendingChanges(userId:)` with a soft conflict (4+ password changes, no
    /// server-side changes) preserves the local version's accumulated password history on
    /// the pushed cipher and the server version's password history on the backup cipher.
    func test_processPendingChanges_update_softConflict_preservesPasswordHistory() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)

        // Local cipher with accumulated password history from multiple offline password changes.
        let localPasswordHistory = [
            CipherPasswordHistoryModel(
                lastUsedDate: Date(year: 2024, month: 6, day: 2),
                password: "old-pass-1"
            ),
            CipherPasswordHistoryModel(
                lastUsedDate: Date(year: 2024, month: 6, day: 3),
                password: "old-pass-2"
            ),
            CipherPasswordHistoryModel(
                lastUsedDate: Date(year: 2024, month: 6, day: 4),
                password: "old-pass-3"
            ),
        ]
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(
                id: "cipher-1",
                passwordHistory: localPasswordHistory,
                revisionDate: revisionDate
            )
        )
        try await setupPendingChange(
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 4
        )

        // Server cipher has no password history (unchanged since going offline).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        ))

        try await subject.processPendingChanges(userId: "1")

        // Backup should contain the server version's password history (nil/empty).
        let backupCipher = try XCTUnwrap(cipherService.addCipherWithServerCiphers.first)
        XCTAssertNil(backupCipher.passwordHistory)

        // Pushed cipher should contain all accumulated local password history entries.
        let pushedCipher = try XCTUnwrap(cipherService.updateCipherWithServerCiphers.first)
        XCTAssertEqual(pushedCipher.passwordHistory?.count, 3)
        XCTAssertEqual(pushedCipher.passwordHistory?[0].password, "old-pass-1")
        XCTAssertEqual(pushedCipher.passwordHistory?[1].password, "old-pass-2")
        XCTAssertEqual(pushedCipher.passwordHistory?[2].password, "old-pass-3")
    }

    /// `processPendingChanges(userId:)` with a `.softDelete` pending change where the
    /// server revision date differs from the original (conflict) restores the server
    /// version locally and drops the pending delete so the user can review and re-decide.
    func test_processPendingChanges_softDelete_conflict() async throws {
        let originalRevisionDate = Date(year: 2024, month: 6, day: 1)
        let serverRevisionDate = Date(year: 2024, month: 6, day: 15)
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(id: "cipher-1", revisionDate: originalRevisionDate)
        )
        try await setupPendingChange(
            changeType: .softDelete,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate
        )

        // Server cipher has a different revision date (triggers conflict).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: serverRevisionDate
        ))

        try await subject.processPendingChanges(userId: "1")

        // Should restore the server version locally.
        XCTAssertEqual(cipherService.updateCipherWithLocalStorageCiphers.count, 1)
        XCTAssertEqual(cipherService.updateCipherWithLocalStorageCiphers.first?.id, "cipher-1")

        // Should NOT create a backup or call the soft delete API.
        XCTAssertTrue(cipherService.addCipherWithServerCiphers.isEmpty)
        XCTAssertNil(cipherAPIService.softDeleteCipherId)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    // MARK: Tests - Hard Delete

    /// `processPendingChanges(userId:)` with a `.hardDelete` change and no conflict
    /// calls `cipherAPIService.deleteCipher(withID:)` (permanent) and deletes the pending change.
    func test_processPendingChanges_hardDelete_noConflict() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        try await setupPendingChange(changeType: .hardDelete, originalRevisionDate: revisionDate)

        // Server cipher has the same revisionDate.
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        ))

        try await subject.processPendingChanges(userId: "1")

        // Should call cipherAPIService.deleteCipher(withID:) (permanent delete).
        XCTAssertEqual(cipherAPIService.deleteCipherId, "cipher-1")

        // Should NOT call soft delete.
        XCTAssertNil(cipherAPIService.softDeleteCipherId)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    /// `processPendingChanges(userId:)` with a `.hardDelete` pending change where the
    /// server revision date differs from the original (conflict) restores the server
    /// version locally and drops the pending delete so the user can review and re-decide.
    func test_processPendingChanges_hardDelete_conflict() async throws {
        let originalRevisionDate = Date(year: 2024, month: 6, day: 1)
        let serverRevisionDate = Date(year: 2024, month: 6, day: 15)
        try await setupPendingChange(changeType: .hardDelete, originalRevisionDate: originalRevisionDate)

        // Server cipher has a different revision date (triggers conflict).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: serverRevisionDate
        ))

        try await subject.processPendingChanges(userId: "1")

        // Should restore the server version locally.
        XCTAssertEqual(cipherService.updateCipherWithLocalStorageCiphers.count, 1)
        XCTAssertEqual(cipherService.updateCipherWithLocalStorageCiphers.first?.id, "cipher-1")

        // Should NOT create a backup or call any delete API.
        XCTAssertTrue(cipherService.addCipherWithServerCiphers.isEmpty)
        XCTAssertNil(cipherAPIService.deleteCipherId)
        XCTAssertNil(cipherAPIService.softDeleteCipherId)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    /// `processPendingChanges(userId:)` with a `.hardDelete` pending change where the server
    /// returns a 404 (cipher already deleted on server) cleans up the local record and
    /// pending change without attempting the delete.
    func test_processPendingChanges_hardDelete_cipherNotFound_cleansUp() async throws {
        try await setupPendingChange(
            changeType: .hardDelete,
            originalRevisionDate: Date(year: 2024, month: 6, day: 1)
        )

        // Server returns 404 — cipher is already gone.
        cipherAPIService.getCipherResult = .failure(OfflineSyncError.cipherNotFound)

        try await subject.processPendingChanges(userId: "1")

        // Should clean up the local cipher record.
        XCTAssertEqual(cipherService.deleteCipherWithLocalStorageId, "cipher-1")

        // Should NOT attempt to delete on the server.
        XCTAssertNil(cipherAPIService.deleteCipherId)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    /// `processPendingChanges(userId:)` retains the pending record when a `.hardDelete`
    /// resolution fails because `cipherAPIService.deleteCipher(withID:)` throws.
    func test_processPendingChanges_hardDelete_apiFailure_pendingRecordRetained() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        try await setupPendingChange(changeType: .hardDelete, originalRevisionDate: revisionDate)

        // Server fetch succeeds with the same revisionDate (no conflict).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        ))

        // Make the hard delete API call fail.
        cipherAPIService.deleteCipherError = BitwardenTestError.example

        try await subject.processPendingChanges(userId: "1")

        // The pending record should NOT be deleted.
        XCTAssertTrue(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.isEmpty)
    }

    // MARK: Tests - Cipher Not Found (404)

    /// `processPendingChanges(userId:)` with a `.update` pending change where the server
    /// returns a 404 (cipher deleted on server while offline) re-creates the cipher on the
    /// server to preserve the user's offline edits, then cleans up the pending change.
    func test_processPendingChanges_update_cipherNotFound_recreates() async throws {
        let cipherData = try JSONEncoder().encode(CipherDetailsResponseModel.fixture(id: "cipher-1"))
        try await setupPendingChange(
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: Date(year: 2024, month: 6, day: 1),
            offlinePasswordChangeCount: 1
        )

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
        let cipherData = try JSONEncoder().encode(CipherDetailsResponseModel.fixture(id: "cipher-1"))
        try await setupPendingChange(
            changeType: .softDelete,
            cipherData: cipherData,
            originalRevisionDate: Date(year: 2024, month: 6, day: 1)
        )

        // Server returns 404 — cipher is already gone.
        cipherAPIService.getCipherResult = .failure(OfflineSyncError.cipherNotFound)

        try await subject.processPendingChanges(userId: "1")

        // Should clean up the local cipher record.
        XCTAssertEqual(cipherService.deleteCipherWithLocalStorageId, "cipher-1")

        // Should NOT attempt to soft delete on the server.
        XCTAssertNil(cipherAPIService.softDeleteCipherId)

        // Should delete the pending change record.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
    }

    // MARK: Tests - OfflineSyncError

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
        let cipherData = try JSONEncoder().encode(CipherDetailsResponseModel.fixture(id: "cipher-1"))
        try await setupPendingChange(changeType: .create, cipherData: cipherData)

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
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(id: "cipher-1", revisionDate: revisionDate)
        )
        try await setupPendingChange(
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: revisionDate
        )

        // Make the server fetch fail with a non-404 error.
        cipherAPIService.getCipherResult = .failure(BitwardenTestError.example)

        try await subject.processPendingChanges(userId: "1")

        // The pending record should NOT be deleted.
        XCTAssertTrue(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.isEmpty)

        // The update should never have been attempted.
        XCTAssertTrue(cipherService.updateCipherWithServerCiphers.isEmpty)
    }

    /// `processPendingChanges(userId:)` retains the pending record when a `.softDelete`
    /// resolution fails because `cipherAPIService.softDeleteCipher(withID:)` throws.
    func test_processPendingChanges_softDelete_apiFailure_pendingRecordRetained() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(id: "cipher-1", revisionDate: revisionDate)
        )
        try await setupPendingChange(
            changeType: .softDelete,
            cipherData: cipherData,
            originalRevisionDate: revisionDate
        )

        // Server fetch succeeds with the same revisionDate (no conflict).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: revisionDate
        ))

        // Make the soft delete API call fail.
        cipherAPIService.softDeleteCipherError = BitwardenTestError.example

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
        let cipherData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(id: "cipher-1", revisionDate: originalRevisionDate)
        )
        try await setupPendingChange(
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            offlinePasswordChangeCount: 1
        )

        // Server has a different revisionDate (triggers conflict).
        cipherAPIService.getCipherResult = .success(.fixture(
            id: "cipher-1",
            revisionDate: serverRevisionDate
        ))

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
        let createData = try JSONEncoder().encode(CipherDetailsResponseModel.fixture(id: "cipher-1"))
        let updateData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(id: "cipher-2", revisionDate: revisionDate)
        )
        let softDeleteData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(id: "cipher-3", revisionDate: revisionDate)
        )
        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1", userId: "1", changeType: .create,
            cipherData: createData, originalRevisionDate: nil, offlinePasswordChangeCount: 0
        )
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-2", userId: "1", changeType: .update,
            cipherData: updateData, originalRevisionDate: revisionDate, offlinePasswordChangeCount: 0
        )
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-3", userId: "1", changeType: .softDelete,
            cipherData: softDeleteData, originalRevisionDate: revisionDate, offlinePasswordChangeCount: 0
        )
        pendingCipherChangeDataStore.fetchPendingChangesResult =
            try await dataStore.fetchPendingChanges(userId: "1")

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

        // SoftDelete should call cipherAPIService.softDeleteCipher(withID:) directly.
        XCTAssertNotNil(cipherAPIService.softDeleteCipherId)

        // All three pending records should be deleted.
        XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 3)
    }

    /// `processPendingChanges(userId:)` resolves successful items and retains failed items'
    /// pending records when a batch contains a mix of successful and failing resolutions.
    /// The catch-and-continue error handling ensures that one item's failure does not block others.
    func test_processPendingChanges_batch_mixedFailure_successfulItemResolved() async throws {
        let revisionDate = Date(year: 2024, month: 6, day: 1)
        // cipher-1 (.create) will succeed; cipher-2 (.update) will fail (getCipher throws).
        let createData = try JSONEncoder().encode(CipherDetailsResponseModel.fixture(id: "cipher-1"))
        let updateData = try JSONEncoder().encode(
            CipherDetailsResponseModel.fixture(id: "cipher-2", revisionDate: revisionDate)
        )
        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1", userId: "1", changeType: .create,
            cipherData: createData, originalRevisionDate: nil, offlinePasswordChangeCount: 0
        )
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-2", userId: "1", changeType: .update,
            cipherData: updateData, originalRevisionDate: revisionDate, offlinePasswordChangeCount: 0
        )
        pendingCipherChangeDataStore.fetchPendingChangesResult =
            try await dataStore.fetchPendingChanges(userId: "1")

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
        let createData1 = try JSONEncoder().encode(CipherDetailsResponseModel.fixture(id: "cipher-1"))
        let createData2 = try JSONEncoder().encode(CipherDetailsResponseModel.fixture(id: "cipher-2"))
        let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-1", userId: "1", changeType: .create,
            cipherData: createData1, originalRevisionDate: nil, offlinePasswordChangeCount: 0
        )
        try await dataStore.upsertPendingChange(
            cipherId: "cipher-2", userId: "1", changeType: .create,
            cipherData: createData2, originalRevisionDate: nil, offlinePasswordChangeCount: 0
        )
        pendingCipherChangeDataStore.fetchPendingChangesResult =
            try await dataStore.fetchPendingChanges(userId: "1")

        // Make addCipherWithServer fail for all items.
        cipherService.addCipherWithServerResult = .failure(BitwardenTestError.example)

        try await subject.processPendingChanges(userId: "1")

        // Both items should have been attempted.
        XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 2)

        // No pending records should be deleted since both failed.
        XCTAssertTrue(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.isEmpty)
    }
}
