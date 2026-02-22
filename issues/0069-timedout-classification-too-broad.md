---
id: 69
title: "[EXT-1] .timedOut classification too broad"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** URLError extension deleted. Commit: `e13aefe`

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Resolved/AP-EXT1_TimedOutClassification.md`*

> **Status: [SUPERSEDED]** — The `URLError+NetworkConnection.swift` extension has been deleted entirely. VaultRepository catch blocks now use plain `catch` — all API errors trigger offline save by design. The fine-grained URLError classification approach was removed as unnecessary. This issue no longer exists.

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | EXT-1 |
| **Component** | ~~`URLError+NetworkConnection`~~ **[Deleted]** |
| **Severity** | ~~Medium~~ **Superseded** |
| **Type** | Design Decision |
| **File** | ~~`BitwardenShared/Core/Platform/Extensions/URLError+NetworkConnection.swift`~~ **[Deleted]** |

## Description

`URLError.timedOut` is included in `isNetworkConnectionError`, which triggers offline fallback. While timeouts commonly indicate network issues, they can also occur when the server is slow but the network is functional. In this case, the user IS online — the server is just overloaded or the payload is large. Triggering offline save for a slow server creates an unnecessary pending change that will be resolved (likely without conflict) on the next sync, but it adds complexity to the sync flow and could confuse users if they notice the behavior.

## Context

Timeout scenarios:
1. **No route to server** — genuine connectivity issue. Offline fallback is correct.
2. **Server overloaded** — network is fine, server is slow. Offline fallback is a false positive.
3. **Large payload on slow connection** — network is marginal. Offline fallback may be appropriate.
4. **DNS resolution slow** — network issue. Offline fallback is correct.

The current iOS default request timeout is typically 60 seconds. After waiting 60 seconds for a response, triggering offline mode means the user has already waited a long time.

---

## Options

### Option A: Remove `.timedOut` from the Offline Trigger Set

Only treat explicit connectivity errors as offline triggers. Timeouts propagate as regular errors.

**Pros:**
- Eliminates false positives from slow servers
- Users see a clear timeout error and can retry manually
- Simpler error classification

**Cons:**
- Users who are genuinely offline (but the error manifests as timeout rather than an explicit connectivity error) lose their changes
- Some network issues present as timeouts (e.g., packet loss causing TCP retransmit timeouts)
- Reduces the scope of offline protection

### Option B: Keep `.timedOut` in the Set (Accept Current Behavior) (Recommended)

Keep the current classification. The false-positive scenario (slow server triggers offline save) is handled correctly by the resolution system — the pending change will be resolved on the next sync without conflict.

**Pros:**
- Broader offline protection — catches genuine connectivity issues that manifest as timeouts
- False positives are harmless: the change syncs successfully on the next attempt
- No code change needed
- Consistent with the principle of preferring data safety over precision

**Cons:**
- Unnecessary conflict resolution work for false-positive timeouts
- Slight complexity in understanding why a change went through offline mode when the user was "online"
- If timeout is due to server overload, the resolution attempt on next sync may also timeout (though the early-abort pattern handles this)

### Option C: Add a Retry Before Offline Fallback for Timeouts

For `.timedOut` specifically, attempt one immediate retry before falling back to offline mode.

**Approach:**
- In VaultRepository's catch block, if the URLError code is `.timedOut`, retry the API call once
- If the retry also fails (any error), then fall back to offline mode

**Pros:**
- Reduces false positives: transient timeouts resolved by retry
- If the server is just briefly overloaded, the retry may succeed
- User doesn't need to know about the retry

**Cons:**
- Doubles the wait time for genuine connectivity timeouts (2x 60s = 120s total)
- Adds retry logic complexity to VaultRepository
- The retry may also timeout, burning additional user time
- Inconsistent with the "fail fast, resolve later" offline philosophy

### Option D: Use a Shorter Timeout Threshold for Offline Classification

Rather than using the standard request timeout (60s), implement a shorter "offline detection" timeout. If the request doesn't get any response within, say, 10 seconds, classify it as offline and save locally.

**Approach:**
- Set a custom `URLSessionConfiguration.timeoutIntervalForRequest` for cipher operations
- Use a shorter timeout (e.g., 10-15 seconds) so the user doesn't wait long
- If this short timeout fires, trigger offline mode
- If the server responds (even with an error), handle normally

**Pros:**
- Users wait less time before offline mode activates
- Faster feedback for genuine connectivity issues
- Reduces false positives (most slow-server scenarios respond within 10-15s)

**Cons:**
- Requires modifying URL session configuration for specific API calls
- 10-15s may be too short for users on very slow connections (2G, satellite)
- Different timeout for cipher operations vs other API calls could cause confusion
- Significant implementation complexity

---

## Recommendation

**Option B** — Keep `.timedOut` in the set and accept the current behavior. The false-positive scenario is benign (the change resolves without conflict on the next sync), and removing it risks losing user data in genuine offline scenarios that present as timeouts. The cost of a false positive (one unnecessary sync resolution) is far lower than the cost of a false negative (lost user changes).

## Estimated Impact

- **Files changed:** 0 (accept current behavior)
- **Lines added:** 0
- **Risk:** None

## Related Issues

- **SEC-1 (EXT-2)**: `.secureConnectionFailed` classification — both are judgment calls about which error codes should trigger offline mode. Consider reviewing the full error code set holistically.
- **T6 (EXT-4)**: URLError test coverage — `.timedOut` IS tested (it's one of the 3 positive cases tested), so no test gap here.
- **R3 (SS-5)**: Retry backoff — if false-positive timeouts are a concern, retry backoff in the resolver prevents repeated timeout-related resolution attempts.

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Code verification**: `URLError+NetworkConnection.swift` includes `.timedOut` in the `isNetworkConnectionError` set. The property is a simple switch statement with no conditional logic per code.

2. **False positive analysis**: If `.timedOut` triggers offline fallback for a slow-but-online server:
   - Local data is saved and pending change queued
   - On next sync (when server is responsive), resolver calls `cipherAPIService.getCipher()` (for update/softDelete) or `cipherService.addCipherWithServer()` (for create)
   - Resolution succeeds, pending change deleted, normal sync proceeds
   - Net effect: user's change is applied with a slight delay - no data loss, no conflict

3. **False negative analysis**: If `.timedOut` were removed and a genuine offline scenario presents as timeout:
   - User's edit would be lost (error thrown, no offline save)
   - User may or may not retry depending on the error message
   - Data loss risk is non-trivial

4. **Asymmetric risk confirmed**: The cost of a false positive (unnecessary offline-then-sync cycle) is far lower than the cost of a false negative (lost user changes). This supports keeping `.timedOut` in the set.

**Updated conclusion**: Original recommendation (Option B - keep current behavior) confirmed. No changes needed. The false-positive scenario is fully handled by the resolution system. Priority remains Medium for the design decision documentation, but no code change is warranted.

## Resolution Details

URLError extension deleted. `.timedOut` classification concern resolved by removing the extension entirely. Commit: `e13aefe`.

## Comments
