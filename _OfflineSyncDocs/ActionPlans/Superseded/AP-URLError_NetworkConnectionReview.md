# Historical Review: URLError+NetworkConnection Extension

> **Status: [SUPERSEDED]** — `URLError+NetworkConnection.swift` and `URLError+NetworkConnectionTests.swift` were deleted in commit `e13aefe`. Error handling simplified to plain `catch` blocks — all API errors now trigger offline save. Issues EXT-1, EXT-2, EXT-4 all resolved by this deletion. See [AP-SEC1](../Resolved/AP-SEC1_SecureConnectionFailedClassification.md), [AP-EXT1](../Resolved/AP-EXT1_TimedOutClassification.md), [AP-T6](../Resolved/AP-T6_IncompleteURLErrorTestCoverage.md).

---

## Files (Deleted)

| File | Type | Lines | Status |
|------|------|-------|--------|
| ~~`BitwardenShared/Core/Platform/Extensions/URLError+NetworkConnection.swift`~~ | ~~Extension~~ | ~~26~~ | **Deleted** |
| ~~`BitwardenShared/Core/Platform/Extensions/URLError+NetworkConnectionTests.swift`~~ | ~~Tests~~ | ~~39~~ | **Deleted** |

---

## Purpose (Historical)

Provided a computed property `isNetworkConnectionError` on `URLError` that distinguished network connectivity failures from other URL loading errors. This was the gating mechanism that determined whether an API failure should trigger offline save behavior.

## Implementation

```swift
extension URLError {
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
```

## Error Code Analysis

| URLError Code | Category | Appropriate for Offline Trigger? |
|---------------|----------|----------------------------------|
| `.notConnectedToInternet` | No network | **Yes** — canonical offline case |
| `.networkConnectionLost` | Network dropped | **Yes** — connection lost mid-request |
| `.cannotFindHost` | DNS failure | **Yes** — indicates no connectivity or DNS unreachable |
| `.cannotConnectToHost` | TCP failure | **Yes** — server unreachable |
| `.timedOut` | Timeout | **Debatable** — see Issue EXT-1 below |
| `.dnsLookupFailed` | DNS failure | **Yes** — DNS resolver failure |
| `.dataNotAllowed` | Cellular restriction | **Yes** — user has restricted data |
| `.internationalRoamingOff` | Roaming restriction | **Yes** — data unavailable abroad |
| `.callIsActive` | Call blocking data | **Yes** — old iOS behavior where call blocks data |
| `.secureConnectionFailed` | TLS failure | **Debatable** — see Issue EXT-2 below |

## Test Coverage

| Test | Scenario | Result |
|------|----------|--------|
| `test_notConnectedToInternet_isNetworkError` | `.notConnectedToInternet` | `true` |
| `test_networkConnectionLost_isNetworkError` | `.networkConnectionLost` | `true` |
| `test_timedOut_isNetworkError` | `.timedOut` | `true` |
| `test_badURL_isNotNetworkError` | `.badURL` | `false` |
| `test_badServerResponse_isNotNetworkError` | `.badServerResponse` | `false` |

**Test Gap:** Only 3 of the 10 positive cases were tested. The remaining 7 (`cannotFindHost`, `cannotConnectToHost`, `dnsLookupFailed`, `dataNotAllowed`, `internationalRoamingOff`, `callIsActive`, `secureConnectionFailed`) were not individually tested.

---

## Why This Was Superseded

The `URLError+NetworkConnection.swift` extension and all related error filtering were deleted in commit `e13aefe` because:

1. The networking stack separates transport errors (`URLError`) from HTTP errors (`ServerError`, `ResponseValidationError`) at a different layer
2. The encrypt step occurs outside the `do/catch`, so SDK errors propagate normally
3. There is no realistic scenario where the server is online and reachable but a pending change is permanently invalid
4. Fine-grained URLError filtering was unnecessary maintenance burden

VaultRepository catch blocks were simplified from `catch let error as URLError where error.isNetworkConnectionError` to plain `catch` (later evolved to a denylist pattern in PRs #26, #28).

## Related Issues

- [AP-SEC1](../Resolved/AP-SEC1_SecureConnectionFailedClassification.md) — `.secureConnectionFailed` TLS classification concern (EXT-2)
- [AP-EXT1](../Resolved/AP-EXT1_TimedOutClassification.md) — `.timedOut` timeout classification concern (EXT-1)
- [AP-T6](../Resolved/AP-T6_IncompleteURLErrorTestCoverage.md) — Incomplete test coverage (EXT-4)
