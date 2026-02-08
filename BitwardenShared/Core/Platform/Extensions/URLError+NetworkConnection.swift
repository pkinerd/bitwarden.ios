import Foundation

extension URLError {
    /// Whether this error represents a network connectivity issue
    /// (as opposed to a server-side error, auth error, etc.).
    ///
    /// Used to determine if an API call failure should trigger offline save behaviour.
    ///
    var isNetworkConnectionError: Bool {
        switch code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .timedOut,
             .dnsLookupFailed,
             .dataNotAllowed,
             .internationalRoamingOff,
             .callIsActive,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
}
