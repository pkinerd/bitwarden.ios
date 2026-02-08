# Action Plan: SEC-1 (EXT-2) — `.secureConnectionFailed` May Mask TLS Security Issues

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | SEC-1 / EXT-2 |
| **Component** | `URLError+NetworkConnection` |
| **Severity** | Medium |
| **Type** | Security |
| **File** | `BitwardenShared/Core/Platform/Extensions/URLError+NetworkConnection.swift` |

## Description

`URLError.secureConnectionFailed` is included in the `isNetworkConnectionError` set, which means TLS failures trigger the offline fallback path. While this correctly handles captive-portal scenarios (where TLS handshake fails because the portal intercepts HTTPS), it also silently handles genuine TLS security failures — such as certificate pinning violations, MITM attacks, or server certificate misconfiguration. The user receives no warning about the TLS failure; their changes are saved locally and queued for later sync.

**Important security nuance:** No data is sent to the compromised server in this scenario. The offline fallback saves data locally only. The security concern is about the lack of user notification, not data exposure.

## Context

Bitwarden's security model trusts the server's TLS certificate. If certificate pinning is in use, a pinning failure could indicate an active MITM. The current behavior silently saves locally — which is safe from a data-protection standpoint — but gives the user no indication that their connection may be compromised.

The alternative (letting the TLS error propagate) means the user's edit is lost entirely in a captive-portal scenario, which is arguably worse for the user experience.

---

## Options

### Option A: Remove `.secureConnectionFailed` from the Offline Trigger Set

Remove `.secureConnectionFailed` from `isNetworkConnectionError` so TLS failures always propagate as errors to the user.

**Pros:**
- Users always see TLS failure errors — no silent masking
- Clear security boundary: TLS failures are security events, not connectivity events
- Simplest change (remove one line)

**Cons:**
- Captive-portal scenarios cause user's changes to be lost (error thrown, no offline save)
- Captive portals are common in hotels, airports, and corporate networks — this could frustrate users
- May cause confusion: the user sees a TLS error but doesn't understand it's a captive portal

### Option B: Keep `.secureConnectionFailed` but Add Logging (Recommended)

Keep the current behavior (offline fallback on TLS failure) but add a `Logger.application.warning()` log when the specific error is `.secureConnectionFailed`. This ensures the behavior is auditable without changing the user experience.

**Approach:**
- In `VaultRepository`'s offline catch blocks, check if the `URLError.code == .secureConnectionFailed` specifically
- Log using the established pattern (same as `OfflineSyncResolver.swift:132` which already uses `Logger.application.error()`):
  ```swift
  if urlError.code == .secureConnectionFailed {
      Logger.application.warning(
          "Offline fallback triggered by TLS connection failure — this may indicate a network security issue"
      )
  }
  ```
- `Logger.application` is already used in 22+ files across the project (defined in `Logger+Bitwarden.swift:10`)
- The user experience remains unchanged (silent offline save)

**Pros:**
- Preserves captive-portal offline support
- Adds auditability for security-sensitive scenarios
- Minimal code change
- Does not degrade UX in common captive-portal scenarios

**Cons:**
- User still receives no visible notification about TLS issues
- Logging alone may not be sufficient for security-critical applications
- Adds conditional logic to the catch blocks

### Option C: Separate TLS Errors into a Distinct Category with User Notification

Create a separate classification for TLS errors and handle them with a user-visible notification (e.g., a toast or alert) while still saving offline.

**Approach:**
- Split `isNetworkConnectionError` into two properties: `isConnectivityError` (no TLS) and `isTLSConnectionError`
- In VaultRepository catch blocks, handle both but show a user notification for TLS errors: "Your changes were saved locally. A secure connection could not be established — please verify your network."
- Still save offline in both cases

**Pros:**
- Users are informed about potential TLS issues
- Changes are not lost (offline save still occurs)
- Security-conscious users can take action (e.g., disconnect from the network)

**Cons:**
- Requires UI notification infrastructure (may not exist for background operations)
- Captive-portal users see a potentially alarming security message
- More complex implementation spanning multiple layers (extension, repository, potentially UI)
- Notification wording is tricky — must not cause unnecessary alarm but must convey the risk

### Option D: Attempt Retry Before Offline Fallback for TLS Errors

For `.secureConnectionFailed` specifically, attempt one retry before falling back to offline mode. This handles transient TLS issues (e.g., brief captive-portal redirect) while allowing persistent TLS failures to trigger offline mode.

**Pros:**
- Reduces false positives for transient TLS issues
- Persistent TLS failures still trigger offline mode
- No user notification complexity

**Cons:**
- Adds retry logic and delay to the save path
- A single retry may not resolve captive-portal issues (they persist until the user authenticates)
- Complicates the error-handling flow
- Uncertain benefit — transient TLS failures are rare

---

## Recommendation

**Option B** — Add logging for `.secureConnectionFailed` triggers. This is the pragmatic choice: it preserves the user experience for the common captive-portal case while adding auditability. The security posture is maintained because no data is sent to a compromised server. If future analysis of production logs reveals that TLS fallbacks are common, the team can reassess and implement Option C.

## Estimated Impact

- **Files changed:** 1-2 (VaultRepository offline handlers, possibly URLError extension)
- **Lines added:** ~10-15
- **Risk:** Low — logging only, no behavioral change

## Related Issues

- **EXT-1**: `.timedOut` classification — same category of "should this error code trigger offline mode?" Both involve judgment calls about error classification.
- **T6 (EXT-4)**: URLError test coverage — if the classification changes, tests need updating.
- **U1 (VR-1)**: Org cipher error timing — both relate to what the user sees (or doesn't see) during error scenarios.

## Updated Review Findings

The review confirms the original assessment with additional code-level detail. After reviewing the implementation:

1. **Code verification**: `URLError+NetworkConnection.swift:9-25` defines `isNetworkConnectionError` as a computed property with a switch on `self.code`. `.secureConnectionFailed` is one of 10 cases returning `true`. The property is used in VaultRepository catch blocks at lines ~515, ~643, ~900, ~928 in `VaultRepository.swift`.

2. **Impact analysis**: When `.secureConnectionFailed` triggers offline fallback:
   - The cipher data is saved locally (already encrypted by SDK)
   - NO data is transmitted to the potentially compromised server
   - The pending change is queued for resolution on next sync
   - On next sync, the resolver will attempt the API call (which may also fail with TLS error if the issue persists)
   - The early-abort pattern at `SyncService.swift:338-339` would prevent full sync if resolution fails

3. **Security posture**: The existing behavior is actually MORE secure than the alternative (propagating the error): when the error propagates, the user might retry on the same compromised network and succeed (if the MITM allows it), potentially sending data to a compromised endpoint. With the offline fallback, data stays local until a clean connection is available.

4. **Logging proposal verification**: `Logger.application` is already imported and used in `OfflineSyncResolver.swift:132`. Adding a `.warning()` log in VaultRepository's catch blocks is straightforward. However, the catch blocks don't currently differentiate between specific URLError codes - they just check `isNetworkConnectionError`. Adding code-specific logging would require checking `urlError.code == .secureConnectionFailed` inside the catch block.

5. **Updated recommendation**: **Option B (keep + log)** remains correct but with a refinement: the logging should be added in the `URLError+NetworkConnection.swift` extension itself or in a centralized place, rather than duplicating the check across 4 catch blocks. A cleaner approach: add a separate `isTLSConnectionError` computed property that VaultRepository can check after the offline save for logging purposes.

**Updated conclusion**: Original recommendation (Option B - keep behavior, add logging) confirmed. The security analysis actually strengthens the case for keeping `.secureConnectionFailed` as an offline trigger since it prevents data from being sent to potentially compromised servers. Severity remains Medium due to the lack of user notification, but the risk posture is better than originally stated.
