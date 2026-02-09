# Action Plan: U1 (VR-1) — Organization Cipher Error Appears After Network Timeout Delay

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | U1 / VR-1 |
| **Component** | `VaultRepository` |
| **Severity** | Informational |
| **Type** | UX |
| **Files** | `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift` |

## Description

The organization cipher check for `addCipher`, `updateCipher`, and `softDeleteCipher` happens after the network request fails (in the `catch` block). This means the user must wait for the full network timeout (potentially 30-60 seconds) before seeing the "organization ciphers not supported offline" error. The user experiences a long wait followed by a confusing error about organization ciphers rather than about connectivity.

## Context

The current flow: attempt API call → wait for timeout → catch URLError → check isOrgCipher → throw error. The org check could theoretically happen before the API call, but the architecture deliberately detects offline by actual API failure (not by proactive connectivity checking, which was removed during simplification).

For `deleteCipher`, the org check happens inside `handleOfflineDelete` after fetching the cipher, which is correct since the method only receives an ID.

---

## Options

### Option A: Pre-Check Organization Ownership Before API Call (Recommended)

Move the `isOrgCipher` check before the API call for add/update/softDelete. If the cipher has an `organizationId` and the network call fails, the user sees the org error immediately. But since we can't know if the network will fail until we try, the pre-check should conditionally throw only when offline.

**Revised approach:** Check `organizationId` BEFORE the API call. Capture the fact. If the API succeeds, the check doesn't matter. If the API fails with a network error, use the pre-captured flag to throw the org-specific error immediately. This is what the current code already does — the issue is about the wait for timeout, not the check order.

**Alternative approach:** Before the API call, if the cipher has an `organizationId`, attempt a lightweight connectivity check (e.g., a HEAD request with a short timeout, or check `NWPathMonitor` status). If connectivity is absent, throw the org error immediately without attempting the full API call.

**Pros:**
- User gets immediate feedback for org ciphers when offline
- Reduces unnecessary wait time

**Cons:**
- Requires a connectivity check mechanism (reintroduces complexity removed during simplification)
- Connectivity checks can be inaccurate (false positive/negative)
- Adds a dependency on connectivity monitoring for just one scenario
- Only benefits org cipher users who are offline — narrow impact

### Option B: Add a Short Pre-Flight Timeout for Org Ciphers

For org cipher operations specifically, add a short pre-flight request (or a shorter timeout on the main request) so the timeout occurs faster.

**Pros:**
- Reduces wait time for org cipher offline errors
- No connectivity monitoring needed

**Cons:**
- Different timeout behavior for org vs non-org ciphers is confusing
- A shorter timeout increases false positives (slow server treated as offline)
- Complex to implement per-operation timeout customization

### Option C: Accept Current Behavior (Recommended)

Accept the timeout delay as an inherent tradeoff of detecting offline status by API failure.

**Pros:**
- No code change
- Consistent behavior across all operations
- The timeout is the same as for any other API failure — not unique to this feature
- Users rarely edit org ciphers while offline (org ciphers typically require online access for key management)

**Cons:**
- Poor UX for users who attempt to edit org ciphers while offline
- Long wait followed by a confusing error

---

## Recommendation

**Option C** — Accept current behavior. The scenario is narrow (org cipher edits while offline), and the delay is the same as any other network timeout the app experiences. Implementing a connectivity pre-check (Option A) reintroduces the complexity that was deliberately removed. If this becomes a significant user complaint, Option A could be revisited.

## Estimated Impact

- **Files changed:** 0
- **Risk:** None

## Related Issues

- **U2**: Inconsistent offline support — similar UX concern about what happens for unsupported operations offline.
- **EXT-1**: `.timedOut` classification — the timeout duration affects how long the user waits before the org error appears.
- **S8**: Feature flag — a feature flag doesn't address this specific UX issue but provides a way to disable the entire feature if UX issues accumulate.

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Code verification**: In `VaultRepository.swift`, the offline catch blocks for `addCipher` (~line 515), `updateCipher` (~line 928), and `softDeleteCipher` (~line 901) all follow the same pattern:
   ```swift
   } catch let error as URLError where error.isNetworkConnectionError {
       let isOrgCipher = cipher.organizationId != nil
       guard !isOrgCipher else {
           throw OfflineSyncError.organizationCipherOfflineEditNotSupported
       }
       // ... offline handler
   }
   ```
   The org check happens AFTER the URLError is caught, which means after the full network timeout.

2. **Timeout analysis**: iOS default URLSession timeout is 60 seconds. For `.timedOut` errors, the user waits the full timeout. For `.notConnectedToInternet`, the error is typically near-instant. The issue is most impactful for `.timedOut` and `.cannotConnectToHost` codes which can have significant delays.

3. **Pre-check feasibility**: The `organizationId` is available on the `CipherView`/`Cipher` before the API call. A pre-check would be: `if cipher.organizationId != nil && !isOnline { throw .organizationCipherOfflineEditNotSupported }`. But the "isOnline" check is the complexity - the architecture deliberately avoids proactive connectivity checking.

4. **Alternative: check BEFORE API call, throw AFTER**: Could cache `isOrgCipher` before the API call, but this doesn't save the wait time since the error is thrown in the catch block either way.

**Updated conclusion**: Original recommendation (Option C - accept current behavior) confirmed. The timeout delay is inherent to the error-detection-by-failure design. Changing this would require reintroducing connectivity monitoring, which was deliberately removed. The scenario is narrow (org cipher edits while offline with slow timeout). Priority: Informational, no change needed.
