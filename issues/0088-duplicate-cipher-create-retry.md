---
id: 88
title: "[RES-1] Potential duplicate cipher on create retry after partial failure"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** Hypothetical — requires Core Data write failure after server success. AP-RES1 (Resolved)

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Resolved/AP-RES1_DuplicateCipherOnCreateRetry.md`*

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | RES-1 |
| **Component** | `OfflineSyncResolver` |
| **Severity** | Informational |
| **Status** | Resolved (Hypothetical — same class as P2-T2) |
| **Type** | Reliability / Edge Case |
| **File** | `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift` |

## Description

In `resolveCreate`, if `cipherService.addCipherWithServer` succeeds on the server but the subsequent local storage update fails, the pending record is NOT deleted (the `deletePendingChange` line is reached only after `addCipherWithServer` completes fully). On the next sync retry, `resolveCreate` will call `addCipherWithServer` again, creating a duplicate cipher on the server. The server has no deduplication mechanism for client-generated UUIDs.

## Context

The probability is very low because:
1. `addCipherWithServer` handles both the API call and local storage update internally
2. Local Core Data writes rarely fail
3. The failure would need to occur between the API response and local storage write

The consequence is a duplicate cipher — the user sees two copies but loses no data.

---

## Options

### Option A: Add Idempotency Key / Server-Side Deduplication

Work with the server team to add a client-generated idempotency key that prevents duplicate creation.

**Approach:**
1. Generate a unique idempotency key when the pending change is created
2. Send the key with the `addCipherWithServer` request
3. Server deduplicates based on the key

**Pros:**
- Eliminates the duplicate problem entirely
- Server-side guarantee — works regardless of client retry behavior
- Standard pattern for idempotent APIs

**Cons:**
- Requires server-side changes — cross-team coordination
- API contract change
- Longer timeline

### Option B: Check for Existing Cipher Before Create

Before calling `addCipherWithServer`, check if a cipher with the same temporary ID already exists on the server.

**Approach:**
1. Before `addCipherWithServer`, call `cipherAPIService.getCipher(withId: cipher.id)`
2. If it exists: the previous create succeeded — just delete the pending record
3. If 404: proceed with create

**Pros:**
- Client-side solution — no server changes needed
- Handles the retry scenario correctly

**Cons:**
- The temporary client-generated UUID will NOT match the server-assigned ID (the server assigns its own ID)
- This approach fundamentally doesn't work because the server ID and client temporary ID are different
- Additional API call for every create resolution

### Option C: Mark Pending Change as "In-Progress" During Resolution

Add a state flag to the pending change that indicates resolution is in progress. If the resolution partially succeeds, the "in-progress" marker helps the retry logic detect the partial state.

**Approach:**
1. Before resolving: set a flag on the pending record (e.g., `isResolving = true`)
2. After full success: delete the pending record
3. On retry: if `isResolving == true`, attempt to find the cipher on the server before re-creating

**Pros:**
- Detects partial failure state
- Can implement smarter retry logic

**Cons:**
- The server ID is unknown (it was assigned by the server and lost during the partial failure)
- Searching for the cipher on the server by name/content is unreliable
- Adds complexity to the data model and resolution logic

### Option D: Accept the Risk (Recommended)

Accept the very low probability of this scenario. A duplicate cipher is a minor inconvenience, not data loss.

**Pros:**
- No code change
- The probability is extremely low
- The consequence is benign (duplicate, not data loss)
- User can manually delete the duplicate

**Cons:**
- Imperfect — a duplicate cipher is still undesirable
- No automated recovery

---

## Recommendation

**Option D** — Accept the risk. The probability of this scenario is extremely low (requires a failure between the API response and local storage write), and the consequence is benign (duplicate cipher). The cost of implementing a robust solution (Option A) requires server changes that are disproportionate to the risk. If duplicate reports emerge in production, Option A (idempotency key) is the correct long-term fix.

## Estimated Impact

- **Files changed:** 0
- **Risk:** None

## Related Issues

- **S4 (RES-4)**: API failure during resolution — the create failure test could verify that pending records are retained on failure, providing confidence in the retry behavior.
- **R3 (SS-5)**: Retry backoff — if retry backoff is implemented, permanently failing create operations would eventually be expired rather than retried indefinitely.
- **RES-2 (404 handling)**: The RES-2 fix (commit `e929511`) added 404 handling to `resolveUpdate` — when a cipher is not found on the server, it re-creates it via `addCipherWithServer`. This is a separate code path from `resolveCreate` but shares the same `addCipherWithServer` call, so the same theoretical duplicate risk applies if the re-create call partially fails.

## Updated Review Findings

The review confirms the original assessment with code-level detail. After reviewing the implementation:

1. **Code verification**: `OfflineSyncResolver.swift:151-172` shows `resolveCreate`:
   ```swift
   let responseModel = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: cipherData)
   let cipher = Cipher(responseModel: responseModel)
   let tempId = cipher.id
   try await cipherService.addCipherWithServer(cipher, encryptedFor: userId)
   if let tempId {
       try await cipherService.deleteCipherWithLocalStorage(id: tempId)
   }
   if let recordId = pendingChange.id {
       try await pendingCipherChangeDataStore.deletePendingChange(id: recordId)
   }
   ```
   **[Updated]** The method now has an intermediate step: after `addCipherWithServer`, it deletes the orphaned temp-ID cipher record via `deleteCipherWithLocalStorage(id: tempId)` before deleting the pending change. The critical sequence is now: `addCipherWithServer` → `deleteCipherWithLocalStorage` → `deletePendingChange`. The fundamental concern remains unchanged: if `addCipherWithServer` succeeds but `deletePendingChange` fails (Core Data error), the next sync retries `addCipherWithServer` for the same cipher data, creating a duplicate on the server.

2. **Probability assessment**: For `deletePendingChange` to fail after `addCipherWithServer` succeeds:
   - Core Data write must fail (disk full, database corruption, etc.)
   - The app would need to survive this failure and attempt sync again
   - In practice, a Core Data failure severe enough to prevent deletion would likely also prevent the fetch in the next sync attempt
   - Extremely low probability

3. **Server-side idempotency**: The Bitwarden server does NOT provide client-generated IDs for create operations. The `Cipher` passed to `addCipherWithServer` uses a temporary client-side ID (assigned in `handleOfflineAdd` at VaultRepository.swift:1007-1025). The server assigns a NEW server ID each time. Two calls with the same cipher data produce two different server-side ciphers — a genuine duplicate.

4. **Mitigation approaches verified**:
   - **Delete-before-push** (swap order): Delete pending record first, then push to server. If push fails, the pending record is already deleted — the user's change is lost. This is WORSE than the current approach.
   - **Idempotency key**: Add a client-generated UUID to the pending record, pass as a header to the server. Server deduplicates by this key. Requires server-side changes — out of scope.
   - **Post-push cleanup with retry**: After successful push, retry `deletePendingChange` with a short retry loop. Reduces the window but doesn't eliminate it.

**Updated conclusion**: Original recommendation (accept risk) confirmed. The scenario requires two simultaneous failures (rare), and the consequence (duplicate cipher) is recoverable (user can manually delete). The mitigation options either shift the risk to data loss or require server changes. Priority: Informational, accept risk for initial release.

## Resolution

**Resolved as hypothetical (2026-02-20).** This is the parent issue of P2-T2. The duplicate cipher scenario requires `deleteCipherWithLocalStorage` or `deletePendingChange` to fail after `addCipherWithServer` succeeds — the same Core Data write failure that P2-T2 was resolved for. As the action plan confirms: "Core Data write must fail (disk full, database corruption, etc.) — the app would need to survive this failure and attempt sync again — in practice, a Core Data failure severe enough to prevent deletion would likely also prevent the fetch in the next sync attempt." With P2-T2 resolved as unrealistic, this parent issue should be aligned: the trigger condition (local storage failure after server success) is the same impossibility.

## Comments
