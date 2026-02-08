import Foundation

class MockOfflineSyncResolver: OfflineSyncResolver {
    var processPendingChangesCalledWith = [String]()
    var processPendingChangesResult: Result<Void, Error> = .success(())

    func processPendingChanges(userId: String) async throws {
        processPendingChangesCalledWith.append(userId)
        try processPendingChangesResult.get()
    }
}
