import XCTest

@testable import BitwardenShared

class URLErrorNetworkConnectionTests: BitwardenTestCase {
    // MARK: Tests

    /// `isNetworkConnectionError` returns `true` for `notConnectedToInternet`.
    func test_notConnectedToInternet_isNetworkError() {
        let error = URLError(.notConnectedToInternet)
        XCTAssertTrue(error.isNetworkConnectionError)
    }

    /// `isNetworkConnectionError` returns `true` for `networkConnectionLost`.
    func test_networkConnectionLost_isNetworkError() {
        let error = URLError(.networkConnectionLost)
        XCTAssertTrue(error.isNetworkConnectionError)
    }

    /// `isNetworkConnectionError` returns `true` for `timedOut`.
    func test_timedOut_isNetworkError() {
        let error = URLError(.timedOut)
        XCTAssertTrue(error.isNetworkConnectionError)
    }

    /// `isNetworkConnectionError` returns `false` for `badURL`, which is not a network
    /// connectivity error.
    func test_badURL_isNotNetworkError() {
        let error = URLError(.badURL)
        XCTAssertFalse(error.isNetworkConnectionError)
    }

    /// `isNetworkConnectionError` returns `false` for `badServerResponse`, which is not a network
    /// connectivity error.
    func test_badServerResponse_isNotNetworkError() {
        let error = URLError(.badServerResponse)
        XCTAssertFalse(error.isNetworkConnectionError)
    }
}
