import Foundation

@testable import BitwardenShared

class MockPendingCipherChangeDataStore: PendingCipherChangeDataStore {
    var fetchPendingChangesResult: [PendingCipherChangeData] = []
    var fetchPendingChangesCalledWith = [String]()

    var fetchPendingChangeResult: PendingCipherChangeData?
    var fetchPendingChangeCalledWith = [(cipherId: String, userId: String)]()

    var upsertPendingChangeCalledWith = [(
        cipherId: String,
        userId: String,
        changeType: PendingCipherChangeType,
        cipherData: Data?,
        originalRevisionDate: Date?,
        encryptedPasswordChangeCount: Data?
    )]()
    var upsertPendingChangeResult: Result<Void, Error> = .success(())

    var deletePendingChangeByIdCalledWith = [String]()
    var deletePendingChangeByCipherIdCalledWith = [(cipherId: String, userId: String)]()
    var deleteAllPendingChangesCalledWith = [String]()

    var pendingChangeCountResult: Int = 0
    var pendingChangeCountResults: [Int] = []
    var pendingChangeCountCalledWith = [String]()

    func fetchPendingChanges(userId: String) async throws -> [PendingCipherChangeData] {
        fetchPendingChangesCalledWith.append(userId)
        return fetchPendingChangesResult
    }

    func fetchPendingChange(cipherId: String, userId: String) async throws -> PendingCipherChangeData? {
        fetchPendingChangeCalledWith.append((cipherId, userId))
        return fetchPendingChangeResult
    }

    func upsertPendingChange(
        cipherId: String,
        userId: String,
        changeType: PendingCipherChangeType,
        cipherData: Data?,
        originalRevisionDate: Date?,
        encryptedPasswordChangeCount: Data?
    ) async throws {
        upsertPendingChangeCalledWith.append((
            cipherId: cipherId,
            userId: userId,
            changeType: changeType,
            cipherData: cipherData,
            originalRevisionDate: originalRevisionDate,
            encryptedPasswordChangeCount: encryptedPasswordChangeCount
        ))
        try upsertPendingChangeResult.get()
    }

    func deletePendingChange(id: String) async throws {
        deletePendingChangeByIdCalledWith.append(id)
    }

    func deletePendingChange(cipherId: String, userId: String) async throws {
        deletePendingChangeByCipherIdCalledWith.append((cipherId, userId))
    }

    func deleteAllPendingChanges(userId: String) async throws {
        deleteAllPendingChangesCalledWith.append(userId)
    }

    func pendingChangeCount(userId: String) async throws -> Int {
        pendingChangeCountCalledWith.append(userId)
        if !pendingChangeCountResults.isEmpty {
            return pendingChangeCountResults.removeFirst()
        }
        return pendingChangeCountResult
    }
}
