import Foundation

@testable import BitwardenShared

class MockPendingChangeCountEncryptionService: PendingChangeCountEncryptionService {
    var encryptCalledWith = [Int16]()
    var encryptResult: Result<Data, Error> = .success(Data("encrypted".utf8))

    var decryptCalledWith = [Data]()
    var decryptResult: Result<Int16, Error> = .success(0)

    func encrypt(count: Int16) async throws -> Data {
        encryptCalledWith.append(count)
        return try encryptResult.get()
    }

    func decrypt(data: Data) async throws -> Int16 {
        decryptCalledWith.append(data)
        return try decryptResult.get()
    }
}
