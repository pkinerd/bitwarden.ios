---
id: 43
title: "[PLAN-1] Denylist future SDK errors — data preservation bias correct"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

Data preservation bias is correct for a password manager — accepted as-is.

**Disposition:** Accepted
**Action Plan:** AP-70 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-70_DenylistFutureSDKErrors.md`*

> **Issue:** #70 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** OfflineSyncPlan.md

## Problem Statement

The VaultRepository's error classification uses a denylist pattern: specific known error types (`ServerError`, `ResponseValidationError` with HTTP status < 500, `CipherAPIServiceError`) are rethrown to the caller, while all other errors fall through to the offline fallback handler. If a future SDK update introduces a new error type that represents a client-side validation failure or a non-retryable condition, this error would not be caught by the existing denylist and would incorrectly trigger offline fallback.

## Current Code

- `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift:992-1010` (example from `updateCipher`)
```swift
} catch let error as ServerError {
    throw error
} catch let error as ResponseValidationError where error.response.statusCode < 500 {
    throw error
} catch let error as CipherAPIServiceError {
    throw error
} catch {
    guard !isOrgCipher,
          await configService.getFeatureFlag(.offlineSyncEnableResolution),
          await configService.getFeatureFlag(.offlineSyncEnableOfflineChanges)
    else {
        throw error
    }
    try await handleOfflineUpdate(...)
}
```

This pattern is repeated in `addCipher`, `deleteCipher`, `updateCipher`, and `softDeleteCipher`.

## Assessment

**Still valid but the bias is correct for a password manager.** The denylist pattern was a deliberate design choice, and its bias is toward data preservation:

1. **Conservative approach:** When in doubt, save locally rather than lose the user's edit. This is the correct bias for a password manager where data loss is the worst outcome.

2. **Known error types are comprehensive:** The three rethrown types cover:
   - `ServerError`: Server returned a structured error response (authentication, authorization, business logic)
   - `ResponseValidationError` (< 500): HTTP 4xx client errors (bad request, forbidden, not found)
   - `CipherAPIServiceError`: Client-side validation errors (missing ID, etc.)

3. **SDK errors from encryption propagate naturally:** The encryption step (`clientService.vault().ciphers().encrypt()`) happens BEFORE the `do` block, so SDK errors from encryption propagate normally without entering the catch chain.

4. **The risk scenario is narrow:** A new error type would need to be:
   - Thrown by the server communication layer (inside the `do` block)
   - Not a subtype of `ServerError`, `ResponseValidationError`, or `CipherAPIServiceError`
   - Indicative of a non-retryable client-side failure (rather than a transient issue)

   In practice, the Bitwarden SDK and networking layer have a stable error taxonomy. New error types are rare and are typically added to existing hierarchies.

5. **Feature flags provide a safety net:** Both `offlineSyncEnableResolution` and `offlineSyncEnableOfflineChanges` flags gate the offline behavior. If a problematic new error type causes issues, the feature can be disabled server-side.

**Hidden risks:** The most likely new error type scenario is a new `ResponseValidationError` variant or a new SDK error from a cipher operation. `ResponseValidationError` is already handled (< 500 rethrown, >= 500 triggers offline). SDK errors from encryption are outside the `do` block. The remaining risk is a new error type from within `addCipherWithServer`/`updateCipherWithServer`/etc., which is very unlikely given the stable API.

## Options

### Option A: Accept As-Is (Recommended)
- **Rationale:** The denylist pattern is the correct design for a password manager. The bias toward saving data locally is preferable to the alternative (losing user edits). The feature flags provide a server-controlled kill switch if issues arise. The known error types are comprehensive and the risk of a new error type silently triggering offline fallback is low and non-catastrophic (the data is preserved, just handled as offline when it should have been rethrown).

### Option B: Add Allowlist Logging
- **Effort:** Low (~15-30 minutes, 3-4 lines per method)
- **Description:** In the final `catch` block, log the specific error type that triggered offline fallback: `Logger.application.info("Offline fallback triggered by \(type(of: error)): \(error)")`. This provides observability for when unexpected error types enter the offline path.
- **Pros:** Enables detection of new error types triggering offline fallback in production, zero risk to existing behavior
- **Cons:** Slightly verbose logging, 4 methods to update

### Option C: Switch to Allowlist Pattern
- **Effort:** Medium (~2-4 hours)
- **Description:** Invert the pattern: only catch specific "offline-eligible" errors (e.g., `URLError`, `ResponseValidationError` >= 500) for offline fallback, and rethrow everything else.
- **Pros:** Prevents any new error type from silently triggering offline fallback
- **Cons:** Risks losing user data if a transient error type is not in the allowlist. The conservative bias of the current denylist is more appropriate for a password manager. Any new transient error type would need to be manually added.

## Recommendation

**Option A: Accept As-Is** for the error classification itself. The denylist bias toward data preservation is correct.

**Optionally combine with Option B** for observability. Adding a log line in the fallback `catch` block would help identify if unexpected error types are triggering offline save in production. This is a zero-risk improvement that aids debugging.

## Dependencies

- Related to Issue #45 (R2-VR-1): Error classification may be overly broad — same root observation from a different perspective.
- Related to Issue S8: Feature flags provide a kill switch if the denylist causes issues.

## Comments
