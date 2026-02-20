import InlineSnapshotTesting
import Networking
import XCTest

@testable import BitwardenShared

class GetCipherRequestTests: BitwardenTestCase {
    // MARK: Properties

    var subject: GetCipherRequest!

    // MARK: Setup & Teardown

    override func setUp() {
        super.setUp()
        subject = GetCipherRequest(cipherId: "CIPHER_ID")
    }

    override func tearDown() {
        super.tearDown()
        subject = nil
    }

    // MARK: Tests

    /// `method` returns the method of the request.
    func test_method() {
        XCTAssertEqual(subject.method, .get)
    }

    /// `path` returns the path of the request.
    func test_path() {
        XCTAssertEqual(subject.path, "/ciphers/CIPHER_ID")
    }

    /// `validate(_:)` does not throw for non-404 responses and throws
    /// `OfflineSyncError.cipherNotFound` for a 404 response.
    func test_validate() {
        XCTAssertNoThrow(try subject.validate(.success()))
        XCTAssertNoThrow(try subject.validate(.failure(statusCode: 400)))
        XCTAssertNoThrow(try subject.validate(.failure(statusCode: 500)))

        XCTAssertThrowsError(try subject.validate(.failure(statusCode: 404))) { error in
            XCTAssertEqual(error as? OfflineSyncError, .cipherNotFound)
        }
    }
}
