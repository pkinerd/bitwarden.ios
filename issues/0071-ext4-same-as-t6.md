---
id: 71
title: "[EXT-4] Same as T6"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** Superseded by URLError extension deletion. Commit: `e13aefe`

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Resolved/AP-T6_IncompleteURLErrorTestCoverage.md`*

> **Status: [RESOLVED]** — The `URLError+NetworkConnection.swift` extension and `URLError+NetworkConnectionTests.swift` test file have both been deleted. The test coverage gap no longer exists because the code it would have tested no longer exists.

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | T6 / EXT-4 |
| **Component** | ~~`URLError+NetworkConnectionTests`~~ **[Deleted]** |
| **Severity** | ~~Low~~ **Resolved** |
| **Type** | Test Gap |
| **File** | ~~`BitwardenShared/Core/Platform/Extensions/URLError+NetworkConnectionTests.swift`~~ **[Deleted]** |

## Description

Only 3 of the 10 `isNetworkConnectionError == true` error codes are tested individually (`.notConnectedToInternet`, `.networkConnectionLost`, `.timedOut`). The remaining 7 codes (`.cannotFindHost`, `.cannotConnectToHost`, `.dnsLookupFailed`, `.dataNotAllowed`, `.internationalRoamingOff`, `.callIsActive`, `.secureConnectionFailed`) lack individual test cases.

## Context

While the switch statement is straightforward and the coverage of 3 positive + 2 negative cases demonstrates the basic behavior, comprehensive testing protects against accidental removal of a case during future edits. If someone removes `.secureConnectionFailed` (per SEC-1 discussion), a test would catch that.

---

## Options

### Option A: Add Individual Tests for All Remaining Codes (Recommended)

Add 7 more test methods, one per untested error code.

**Approach:**
```swift
func test_cannotFindHost_isNetworkError() {
    XCTAssertTrue(URLError(.cannotFindHost).isNetworkConnectionError)
}
// ... for each of the 7 remaining codes
```

**Pros:**
- Complete coverage — every positive case has a test
- Protects against accidental removal
- Each test is trivial (1-2 lines)
- Clear and self-documenting

**Cons:**
- 7 trivial tests add ~35 lines
- Arguably over-testing a simple switch statement

### Option B: Add a Single Parameterized Test

Add one test that iterates over all 10 error codes and verifies each returns `true`.

**Approach:**
```swift
func test_allNetworkConnectionErrors_returnTrue() {
    let codes: [URLError.Code] = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
        .cannotConnectToHost, .timedOut, .dnsLookupFailed, .dataNotAllowed,
        .internationalRoamingOff, .callIsActive, .secureConnectionFailed
    ]
    for code in codes {
        XCTAssertTrue(URLError(code).isNetworkConnectionError, "\(code) should be a network error")
    }
}
```

**Pros:**
- Compact — one test covers all cases
- Easy to update when codes are added or removed

**Cons:**
- If one assertion fails, the test stops at the first failure (unless using `XCTAssertTrue` in a loop, which reports the specific failure via the message)
- Less clear in test output which specific code failed (though the message parameter helps)
- Replaces the existing individual tests (or coexists with them)

### Option C: Keep Current Coverage (No Change)

The 3 existing positive tests and 2 negative tests provide sufficient confidence in the behavior.

**Pros:**
- No code change
- The switch statement is simple enough that partial testing is adequate

**Cons:**
- Incomplete coverage
- No protection against accidental removal of specific codes

---

## Recommendation

**Option A** — Add individual tests for all remaining codes. The test code is trivial, and complete coverage provides protection against accidental changes, especially relevant given the SEC-1 discussion about potentially removing `.secureConnectionFailed`.

## Estimated Impact

- **Files changed:** 1 (`URLError+NetworkConnectionTests.swift`)
- **Lines added:** ~35
- **Risk:** None — test-only changes

## Related Issues

- **SEC-1 (EXT-2)**: `.secureConnectionFailed` classification — if this code is removed from the set, the test for it should also be removed (or changed to verify `false`).
- **EXT-1**: `.timedOut` classification — already has a test; adding tests for all codes ensures consistency.

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Code verification**: `URLError+NetworkConnection.swift` has a switch statement with 10 cases returning `true` and a `default` returning `false`. The existing tests cover `.notConnectedToInternet`, `.networkConnectionLost`, and `.timedOut` positively, plus `.badURL` and `.cancelled` negatively.

2. **Untested positive cases**: `.cannotFindHost`, `.cannotConnectToHost`, `.dnsLookupFailed`, `.dataNotAllowed`, `.internationalRoamingOff`, `.callIsActive`, `.secureConnectionFailed` - 7 codes without individual tests.

3. **SEC-1 dependency**: If SEC-1 decides to remove `.secureConnectionFailed` from the set, the test for it should verify `false` instead of `true`. This is why T6 should be implemented AFTER SEC-1 is resolved. The current recommendation (Option B in SEC-1: keep + log) means `.secureConnectionFailed` stays in the set and should have a positive test.

4. **Test simplicity**: Each additional test is 3 lines:
   ```swift
   func test_cannotFindHost_isNetworkError() {
       XCTAssertTrue(URLError(.cannotFindHost).isNetworkConnectionError)
   }
   ```
   7 such tests add ~35 lines total. Trivial effort for complete coverage.

**Updated conclusion**: Original recommendation (Option A - add individual tests for all remaining codes) confirmed. Implement after SEC-1 and EXT-1 decisions are finalized. Priority: Low but trivial.

## Resolution Details

Superseded by T6 resolution — URLError extension deleted. Commit: `e13aefe`.

## Comments
