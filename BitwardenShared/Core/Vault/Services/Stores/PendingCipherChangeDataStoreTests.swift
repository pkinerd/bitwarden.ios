import BitwardenKitMocks
import CoreData
import XCTest

@testable import BitwardenShared

class PendingCipherChangeDataStoreTests: BitwardenTestCase {
    // MARK: Properties

    var subject: DataStore!

    // MARK: Setup & Teardown

    override func setUp() {
        super.setUp()

        subject = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
    }

    override func tearDown() {
        super.tearDown()

        subject = nil
    }

    // MARK: Tests

    /// `fetchPendingChanges(userId:)` returns an empty array when the user has no pending changes.
    func test_fetchPendingChanges_empty() async throws {
        let changes = try await subject.fetchPendingChanges(userId: "1")
        XCTAssertTrue(changes.isEmpty)
    }

    /// `fetchPendingChanges(userId:)` returns only the pending changes for the specified user
    /// and not for other users.
    func test_fetchPendingChanges_returnsUserChanges() async throws {
        try await subject.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: Data("cipher1".utf8),
            originalRevisionDate: Date(year: 2024, month: 1, day: 1),
            offlinePasswordChangeCount: 0
        )
        try await subject.upsertPendingChange(
            cipherId: "cipher-2",
            userId: "1",
            changeType: .create,
            cipherData: Data("cipher2".utf8),
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        try await subject.upsertPendingChange(
            cipherId: "cipher-3",
            userId: "2",
            changeType: .softDelete,
            cipherData: nil,
            originalRevisionDate: Date(year: 2024, month: 2, day: 1),
            offlinePasswordChangeCount: 0
        )

        let user1Changes = try await subject.fetchPendingChanges(userId: "1")
        XCTAssertEqual(user1Changes.count, 2)
        XCTAssertEqual(user1Changes[0].cipherId, "cipher-1")
        XCTAssertEqual(user1Changes[1].cipherId, "cipher-2")

        let user2Changes = try await subject.fetchPendingChanges(userId: "2")
        XCTAssertEqual(user2Changes.count, 1)
        XCTAssertEqual(user2Changes[0].cipherId, "cipher-3")
    }

    /// `fetchPendingChange(cipherId:userId:)` returns the specific pending change
    /// matching the cipher and user ID.
    func test_fetchPendingChange_byId() async throws {
        try await subject.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: Data("cipher1".utf8),
            originalRevisionDate: Date(year: 2024, month: 1, day: 1),
            offlinePasswordChangeCount: 1
        )
        try await subject.upsertPendingChange(
            cipherId: "cipher-2",
            userId: "1",
            changeType: .create,
            cipherData: Data("cipher2".utf8),
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )

        let result = try await subject.fetchPendingChange(cipherId: "cipher-1", userId: "1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.cipherId, "cipher-1")
        XCTAssertEqual(result?.userId, "1")
        XCTAssertEqual(result?.changeType, .update)
        XCTAssertEqual(result?.offlinePasswordChangeCount, 1)

        let noResult = try await subject.fetchPendingChange(cipherId: "cipher-99", userId: "1")
        XCTAssertNil(noResult)
    }

    /// `upsertPendingChange(...)` creates a new pending change record when none exists.
    func test_upsertPendingChange_insert() async throws {
        let revisionDate = Date(year: 2024, month: 3, day: 15)
        let cipherData = Data("encrypted-cipher".utf8)

        try await subject.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: cipherData,
            originalRevisionDate: revisionDate,
            offlinePasswordChangeCount: 2
        )

        let changes = try await subject.fetchPendingChanges(userId: "1")
        XCTAssertEqual(changes.count, 1)

        let change = try XCTUnwrap(changes.first)
        XCTAssertEqual(change.cipherId, "cipher-1")
        XCTAssertEqual(change.userId, "1")
        XCTAssertEqual(change.changeType, .update)
        XCTAssertEqual(change.cipherData, cipherData)
        XCTAssertEqual(change.originalRevisionDate, revisionDate)
        XCTAssertEqual(change.offlinePasswordChangeCount, 2)
        XCTAssertNotNil(change.id)
        XCTAssertNotNil(change.createdDate)
        XCTAssertNotNil(change.updatedDate)
    }

    /// `upsertPendingChange(...)` updates an existing record and preserves
    /// the `originalRevisionDate` from the first offline edit.
    func test_upsertPendingChange_update() async throws {
        let originalDate = Date(year: 2024, month: 1, day: 1)
        try await subject.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: Data("original".utf8),
            originalRevisionDate: originalDate,
            offlinePasswordChangeCount: 0
        )

        // Update the same cipher with new data and a different originalRevisionDate.
        let newDate = Date(year: 2024, month: 6, day: 1)
        try await subject.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: Data("updated".utf8),
            originalRevisionDate: newDate,
            offlinePasswordChangeCount: 1
        )

        let changes = try await subject.fetchPendingChanges(userId: "1")
        XCTAssertEqual(changes.count, 1)

        let change = try XCTUnwrap(changes.first)
        XCTAssertEqual(change.cipherData, Data("updated".utf8))
        XCTAssertEqual(change.offlinePasswordChangeCount, 1)
        // originalRevisionDate should be preserved from the first insert, not overwritten.
        XCTAssertEqual(change.originalRevisionDate, originalDate)
    }

    /// `deletePendingChange(id:)` removes the pending change matching the record ID.
    func test_deletePendingChange_byId() async throws {
        try await subject.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )

        let changes = try await subject.fetchPendingChanges(userId: "1")
        let recordId = try XCTUnwrap(changes.first?.id)

        try await subject.deletePendingChange(id: recordId)

        let remaining = try await subject.fetchPendingChanges(userId: "1")
        XCTAssertTrue(remaining.isEmpty)
    }

    /// `deletePendingChange(cipherId:userId:)` removes the pending change matching the cipher
    /// and user ID.
    func test_deletePendingChange_byCipherId() async throws {
        try await subject.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        try await subject.upsertPendingChange(
            cipherId: "cipher-2",
            userId: "1",
            changeType: .create,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )

        try await subject.deletePendingChange(cipherId: "cipher-1", userId: "1")

        let remaining = try await subject.fetchPendingChanges(userId: "1")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.cipherId, "cipher-2")
    }

    /// `deleteAllPendingChanges(userId:)` removes all pending changes for the given user
    /// without affecting other users' changes.
    func test_deleteAllPendingChanges() async throws {
        try await subject.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        try await subject.upsertPendingChange(
            cipherId: "cipher-2",
            userId: "1",
            changeType: .create,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        try await subject.upsertPendingChange(
            cipherId: "cipher-3",
            userId: "2",
            changeType: .softDelete,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )

        try await subject.deleteAllPendingChanges(userId: "1")

        let user1Changes = try await subject.fetchPendingChanges(userId: "1")
        XCTAssertTrue(user1Changes.isEmpty)

        let user2Changes = try await subject.fetchPendingChanges(userId: "2")
        XCTAssertEqual(user2Changes.count, 1)
    }

    /// `pendingChangeCount(userId:)` returns the correct count of pending changes for a user.
    func test_pendingChangeCount() async throws {
        var count = try await subject.pendingChangeCount(userId: "1")
        XCTAssertEqual(count, 0)

        try await subject.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .update,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        try await subject.upsertPendingChange(
            cipherId: "cipher-2",
            userId: "1",
            changeType: .create,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )
        try await subject.upsertPendingChange(
            cipherId: "cipher-3",
            userId: "2",
            changeType: .update,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )

        count = try await subject.pendingChangeCount(userId: "1")
        XCTAssertEqual(count, 2)

        count = try await subject.pendingChangeCount(userId: "2")
        XCTAssertEqual(count, 1)
    }
}
