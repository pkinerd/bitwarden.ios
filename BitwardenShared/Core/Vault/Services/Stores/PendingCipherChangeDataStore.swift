import CoreData
import Foundation

// MARK: - PendingCipherChangeDataStore

/// A protocol for a data store that handles performing data requests for pending cipher changes
/// queued during offline editing.
///
protocol PendingCipherChangeDataStore: AnyObject {
    /// Fetches all pending changes for a user.
    ///
    /// - Parameter userId: The user ID of the user associated with the pending changes.
    /// - Returns: The list of pending changes for the user.
    ///
    func fetchPendingChanges(userId: String) async throws -> [PendingCipherChangeData]

    /// Fetches a pending change for a specific cipher and user, if one exists.
    ///
    /// - Parameters:
    ///   - cipherId: The ID of the cipher.
    ///   - userId: The user ID associated with the pending change.
    /// - Returns: The pending change if it exists, or `nil`.
    ///
    func fetchPendingChange(cipherId: String, userId: String) async throws -> PendingCipherChangeData?

    /// Inserts or updates a pending change record. Upserts by (cipherId, userId).
    ///
    /// - Parameters:
    ///   - cipherId: The cipher's ID.
    ///   - userId: The active user ID.
    ///   - changeType: The type of offline change.
    ///   - cipherData: The JSON-encoded encrypted cipher snapshot.
    ///   - originalRevisionDate: The cipher's revision date before the first offline edit.
    ///   - offlinePasswordChangeCount: The number of offline password changes.
    ///
    func upsertPendingChange(
        cipherId: String,
        userId: String,
        changeType: PendingCipherChangeType,
        cipherData: Data?,
        originalRevisionDate: Date?,
        offlinePasswordChangeCount: Int
    ) async throws

    /// Deletes a pending change record by its record ID.
    ///
    /// - Parameter id: The pending change record ID.
    ///
    func deletePendingChange(id: String) async throws

    /// Deletes a pending change record for a specific cipher and user.
    ///
    /// - Parameters:
    ///   - cipherId: The cipher's ID.
    ///   - userId: The user ID.
    ///
    func deletePendingChange(cipherId: String, userId: String) async throws

    /// Deletes all pending changes for a user.
    ///
    /// - Parameter userId: The user ID.
    ///
    func deleteAllPendingChanges(userId: String) async throws

    /// Returns the count of pending changes for a user.
    ///
    /// - Parameter userId: The user ID.
    /// - Returns: The number of pending changes.
    ///
    func pendingChangeCount(userId: String) async throws -> Int
}

// MARK: - DataStore + PendingCipherChangeDataStore

extension DataStore: PendingCipherChangeDataStore {
    func fetchPendingChanges(userId: String) async throws -> [PendingCipherChangeData] {
        try await backgroundContext.perform {
            let request = PendingCipherChangeData.fetchByUserIdRequest(userId: userId)
            request.sortDescriptors = [NSSortDescriptor(key: "createdDate", ascending: true)]
            return try self.backgroundContext.fetch(request)
        }
    }

    func fetchPendingChange(cipherId: String, userId: String) async throws -> PendingCipherChangeData? {
        try await backgroundContext.perform {
            let request = PendingCipherChangeData.fetchByCipherIdRequest(userId: userId, cipherId: cipherId)
            return try self.backgroundContext.fetch(request).first
        }
    }

    func upsertPendingChange(
        cipherId: String,
        userId: String,
        changeType: PendingCipherChangeType,
        cipherData: Data?,
        originalRevisionDate: Date?,
        offlinePasswordChangeCount: Int
    ) async throws {
        try await backgroundContext.performAndSave {
            let request = PendingCipherChangeData.fetchByCipherIdRequest(userId: userId, cipherId: cipherId)
            let existing = try self.backgroundContext.fetch(request).first

            if let existing {
                // Update existing record, preserving originalRevisionDate from first offline edit
                existing.cipherData = cipherData
                existing.changeTypeRaw = changeType.rawValue
                existing.updatedDate = Date()
                existing.offlinePasswordChangeCount = Int64(offlinePasswordChangeCount)
                // Do NOT overwrite originalRevisionDate - it's the baseline for conflict detection
            } else {
                // Create new pending change record
                _ = PendingCipherChangeData(
                    context: self.backgroundContext,
                    cipherId: cipherId,
                    userId: userId,
                    changeType: changeType,
                    cipherData: cipherData,
                    originalRevisionDate: originalRevisionDate,
                    offlinePasswordChangeCount: offlinePasswordChangeCount
                )
            }
        }
    }

    func deletePendingChange(id: String) async throws {
        try await backgroundContext.performAndSave {
            let request = PendingCipherChangeData.fetchByIdRequest(id: id)
            let results = try self.backgroundContext.fetch(request)
            for result in results {
                self.backgroundContext.delete(result)
            }
        }
    }

    func deletePendingChange(cipherId: String, userId: String) async throws {
        try await backgroundContext.performAndSave {
            let request = PendingCipherChangeData.fetchByCipherIdRequest(userId: userId, cipherId: cipherId)
            let results = try self.backgroundContext.fetch(request)
            for result in results {
                self.backgroundContext.delete(result)
            }
        }
    }

    func deleteAllPendingChanges(userId: String) async throws {
        try await executeBatchDelete(PendingCipherChangeData.deleteByUserIdRequest(userId: userId))
    }

    func pendingChangeCount(userId: String) async throws -> Int {
        try await backgroundContext.perform {
            let request = PendingCipherChangeData.fetchByUserIdRequest(userId: userId)
            return try self.backgroundContext.count(for: request)
        }
    }
}
