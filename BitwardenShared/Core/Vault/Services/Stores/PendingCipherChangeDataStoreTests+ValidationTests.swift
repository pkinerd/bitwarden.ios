import BitwardenKitMocks
import CoreData
import XCTest

@testable import BitwardenShared

extension PendingCipherChangeDataStoreTests {
    // MARK: changeType Fallback Tests

    /// `changeType` computed property defaults to `.update` when `changeTypeRaw` is nil.
    func test_changeType_nilChangeTypeRaw_defaultsToUpdate() async throws {
        try await subject.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .create,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )

        // Manually set changeTypeRaw to nil via the background context.
        try await subject.backgroundContext.performAndSave {
            let request = PendingCipherChangeData.fetchByUserIdRequest(userId: "1")
            let records = try self.subject.backgroundContext.fetch(request)
            records.first?.changeTypeRaw = nil
        }

        let change = try await subject.fetchPendingChange(cipherId: "cipher-1", userId: "1")
        XCTAssertEqual(change?.changeType, .update)
    }

    /// `changeType` computed property defaults to `.update` when `changeTypeRaw` contains
    /// an unrecognized string value.
    func test_changeType_invalidChangeTypeRaw_defaultsToUpdate() async throws {
        try await subject.upsertPendingChange(
            cipherId: "cipher-1",
            userId: "1",
            changeType: .create,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )

        // Manually set changeTypeRaw to an invalid value.
        try await subject.backgroundContext.performAndSave {
            let request = PendingCipherChangeData.fetchByUserIdRequest(userId: "1")
            let records = try self.subject.backgroundContext.fetch(request)
            records.first?.changeTypeRaw = "unknownType"
        }

        let change = try await subject.fetchPendingChange(cipherId: "cipher-1", userId: "1")
        XCTAssertEqual(change?.changeType, .update)
    }

    // MARK: Sort Order Tests

    /// `fetchPendingChanges(userId:)` returns records sorted by `createdDate` in ascending order.
    func test_fetchPendingChanges_sortedByCreatedDate() async throws {
        // Insert records in reverse chronological order to verify sorting.
        try await subject.upsertPendingChange(
            cipherId: "cipher-third",
            userId: "1",
            changeType: .update,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )

        // Small delay to ensure different createdDate timestamps.
        try await Task.sleep(nanoseconds: 10_000_000)

        try await subject.upsertPendingChange(
            cipherId: "cipher-first",
            userId: "1",
            changeType: .create,
            cipherData: nil,
            originalRevisionDate: nil,
            offlinePasswordChangeCount: 0
        )

        let changes = try await subject.fetchPendingChanges(userId: "1")
        XCTAssertEqual(changes.count, 2)

        // First inserted record should come first (earlier createdDate).
        XCTAssertEqual(changes[0].cipherId, "cipher-third")
        XCTAssertEqual(changes[1].cipherId, "cipher-first")
    }

    // MARK: All Enum Cases Round-Trip Tests

    /// All four `PendingCipherChangeType` cases round-trip correctly through Core Data.
    func test_allChangeTypes_roundTripThroughCoreData() async throws {
        let cases: [(String, PendingCipherChangeType)] = [
            ("cipher-update", .update),
            ("cipher-create", .create),
            ("cipher-soft", .softDelete),
            ("cipher-hard", .hardDelete),
        ]

        for (cipherId, changeType) in cases {
            try await subject.upsertPendingChange(
                cipherId: cipherId,
                userId: "1",
                changeType: changeType,
                cipherData: nil,
                originalRevisionDate: nil,
                offlinePasswordChangeCount: 0
            )
        }

        for (cipherId, expectedType) in cases {
            let change = try await subject.fetchPendingChange(cipherId: cipherId, userId: "1")
            XCTAssertEqual(
                change?.changeType,
                expectedType,
                "Expected \(expectedType) for \(cipherId), got \(String(describing: change?.changeType))"
            )
        }
    }

    // MARK: deleteDataForUser Integration Tests

    /// `deleteDataForUser(userId:)` removes all pending cipher changes for the specified user
    /// and preserves pending changes belonging to other users.
    func test_deleteDataForUser_deletesPendingCipherChanges() async throws {
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

        try await subject.deleteDataForUser(userId: "1")

        let user1Changes = try await subject.fetchPendingChanges(userId: "1")
        XCTAssertTrue(user1Changes.isEmpty)

        let user2Changes = try await subject.fetchPendingChanges(userId: "2")
        XCTAssertEqual(user2Changes.count, 1)
        XCTAssertEqual(user2Changes.first?.cipherId, "cipher-3")
    }
}
