# Action Plan: VI-1 — Offline-Created Cipher Fails to Load in Detail View

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | VI-1 |
| **Component** | `ViewItemProcessor` / `VaultRepository` / `CipherItemState` |
| **Severity** | Medium |
| **Type** | Usability / Reliability |
| **Files** | `ViewItemProcessor.swift`, `VaultRepository.swift`, `Publisher+Async.swift`, `CipherItemState.swift`, `ViewItemState.swift` |

## Description

When a user creates a new vault item while offline, the item appears correctly in the vault list. However, tapping the item to view or edit it results in an infinite spinner — the detail view never loads. The user must navigate back and cannot view, edit, or interact with the item they just created until connectivity is restored and the item syncs.

### Root Cause Analysis

The failure involves a chain of three contributing factors:

**Factor 1: `asyncTryMap` terminates the publisher stream on error.**

`VaultRepository.cipherDetailsPublisher(id:)` at `VaultRepository.swift:1111-1119` uses `asyncTryMap` with `decrypt(cipher:)`:

```swift
func cipherDetailsPublisher(id: String) async throws -> AsyncThrowingPublisher<...> {
    try await cipherService.ciphersPublisher()
        .asyncTryMap { ciphers -> CipherView? in
            guard let cipher = ciphers.first(where: { $0.id == id }) else { return nil }
            return try await self.clientService.vault().ciphers().decrypt(cipher: cipher)
        }
        .eraseToAnyPublisher()
        .values
}
```

The `asyncTryMap` extension at `Publisher+Async.swift:49-58` uses `flatMap(maxPublishers: .max(1))` with a `Future`. When `decrypt(cipher:)` throws an error, the `Future` completes with `.failure`, and `flatMap` propagates the error downstream, **terminating the entire publisher stream**. No further values are emitted.

**Factor 2: Offline-created ciphers may fail `decrypt()` even though they succeed with `decryptListWithFailures()`.**

The vault list uses `decryptListWithFailures()` (via `CiphersClientWrapperService.swift:67`) which is resilient — decryption failures for individual items are reported separately and don't prevent the list from rendering. In contrast, the detail view's `cipherDetailsPublisher` uses `decrypt(cipher:)` which throws on any decryption error.

Offline-created ciphers are stored via `Cipher.withTemporaryId()` at `CipherView+OfflineSync.swift:16-47`, which sets `data: nil`. The `handleOfflineAdd` method then persists this cipher locally. If `decrypt()` fails for this cipher (e.g., due to the `nil` data field or key mismatch), the publisher stream terminates.

**Factor 3: `streamCipherDetails()` catch block only logs the error.**

`ViewItemProcessor.streamCipherDetails()` at `ViewItemProcessor.swift:549-600` subscribes to the publisher in a `for try await` loop. When the stream terminates with an error:

```swift
} catch {
    services.errorReporter.log(error: error)
}
```

The catch block logs the error but does **not** update `state.loadingState` to `.error(errorMessage:)`. The state remains at its initial value of `.loading(nil)` (set at `ViewItemState.swift:29`), leaving the view permanently showing a spinner.

**Contributing Factor: `CipherItemState` failable init rejects nil IDs.**

Even if decryption succeeds, `CipherItemState.init?(existing:hasPremium:iconBaseURL:)` at `CipherItemState.swift:385` contains `guard cipherView.id != nil else { return nil }`. When this returns `nil`, the `ViewItemState.init?` failable initializer at `ViewItemState.swift:71-75` also returns `nil`. In `streamCipherDetails()` at line 578-582, this causes `guard var newState = ViewItemState(...) else { continue }` to skip the update, and the view remains in the loading state. However, offline-created ciphers *do* have an ID (the temporary UUID), so this factor only applies if decryption strips or fails to return the ID.

### Reproduction Steps

1. Enable airplane mode (device offline)
2. Open Bitwarden vault
3. Add a new login item and save
4. Item appears in the vault list
5. Tap the item to view it
6. **Result:** Infinite spinner, item never loads
7. **Expected:** Item details should display

### Asymmetry with Vault List

The vault list successfully displays the offline-created cipher because `VaultListProcessor.streamVaultList()` at `VaultListProcessor.swift:319-343` uses `CiphersClientWrapperService` which internally calls `decryptListWithFailures()`. This method returns successes and failures separately — a single cipher's decryption failure doesn't prevent other items from appearing. For items that fail decryption, the list shows them with an `isDecryptionFailure` flag.

The detail view, however, uses `decrypt()` (single-cipher, throws on error) via `asyncTryMap`, which is the less resilient path.

---

## Options

### Option A: Add Error State Handling in `streamCipherDetails()` Catch Block

Update the catch block in `ViewItemProcessor.streamCipherDetails()` to set the loading state to `.error` instead of silently logging.

**Approach:**
1. In `streamCipherDetails()` at `ViewItemProcessor.swift:597-599`, update the catch block:
   ```swift
   } catch {
       services.errorReporter.log(error: error)
       state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)
   }
   ```

**Pros:**
- Minimal change — 1 line added
- User sees an error message instead of infinite spinner
- Follows the existing `LoadingState.error` pattern used elsewhere in the app
- No architectural changes needed

**Cons:**
- User still cannot view the offline-created item — they see an error instead of a spinner
- Does not address the root cause (publisher stream termination on decryption error)
- The error message is generic and doesn't explain why the item can't be viewed

### Option B: Add Direct Fetch Fallback in `streamCipherDetails()` (Recommended)

When the publisher stream terminates with an error, fall back to a one-shot `fetchCipher(withId:)` call and use the result to populate the state.

**Approach:**
1. Extract the state-building logic from `streamCipherDetails()` into a reusable method (e.g., `updateState(with:)`)
2. In the catch block, attempt a direct `fetchCipher(withId:)` call
3. If successful, use the result to populate the state
4. If that also fails, set the state to `.error`

```swift
} catch {
    services.errorReporter.log(error: error)
    do {
        if let cipher = try await services.vaultRepository.fetchCipher(withId: itemId) {
            try await updateState(with: cipher)
        } else {
            state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)
        }
    } catch {
        state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)
    }
}
```

Note: `VaultRepository.fetchCipher(withId:)` at `VaultRepository.swift:610-613` already uses `try?` for decryption, making it resilient to decryption failures (returns `nil` instead of throwing).

**Pros:**
- User can view the offline-created item if direct decryption succeeds
- Falls back to error state if direct fetch also fails
- `fetchCipher(withId:)` exists and uses `try?` for resilient decryption
- No publisher architecture changes needed
- Moderate change (~20-30 lines)

**Cons:**
- The direct fetch is a one-shot operation — the view won't reactively update if the underlying cipher data changes while the view is open
- Adds complexity to `streamCipherDetails()` with a two-tier approach
- If the root issue is that `decrypt()` throws for these ciphers, `fetchCipher` uses `try?` which returns `nil`, and the user sees an error anyway

### Option C: Use `try?` in `cipherDetailsPublisher` to Prevent Stream Termination

Change `cipherDetailsPublisher` to use `try?` for decryption so that individual decryption failures return `nil` instead of terminating the stream.

**Approach:**
1. In `VaultRepository.cipherDetailsPublisher(id:)` at `VaultRepository.swift:1113-1115`:
   ```swift
   .asyncTryMap { ciphers -> CipherView? in
       guard let cipher = ciphers.first(where: { $0.id == id }) else { return nil }
       return try? await self.clientService.vault().ciphers().decrypt(cipher: cipher)
   }
   ```

**Pros:**
- Prevents stream termination — the publisher continues to emit values
- If the cipher becomes decryptable later (e.g., after sync), the stream picks it up
- Matches the resilient pattern used by `CiphersClientWrapperService`
- Minimal change — 1 character (`try` → `try?`)

**Cons:**
- Silences all decryption errors in the detail view publisher — errors are not logged or reported
- A `nil` return causes the `guard let cipher else { continue }` in `streamCipherDetails()` to skip the value, which keeps the view in `.loading(nil)` state (same spinner problem, just no stream termination)
- Does not solve the problem on its own — needs to be combined with Option A or a nil-handling mechanism

### Option D: Use `asyncMap` with `decryptListWithFailures()` in `cipherDetailsPublisher`

Replace `decrypt()` with `decryptListWithFailures()` in the publisher, matching the resilient approach used by the vault list.

**Approach:**
1. In `VaultRepository.cipherDetailsPublisher(id:)`, change to use `asyncMap` (non-throwing) instead of `asyncTryMap`:
   ```swift
   .asyncMap { ciphers -> CipherView? in
       guard let cipher = ciphers.first(where: { $0.id == id }) else { return nil }
       let result = try? await self.clientService.vault().ciphers()
           .decryptListWithFailures(ciphers: [cipher])
       return result?.successes.first
   }
   ```
2. Update the publisher return type from `AsyncThrowingPublisher` to a non-throwing publisher
3. Update all callers to use `for await` instead of `for try await`

**Pros:**
- Uses the same resilient decryption path as the vault list
- No stream termination on individual cipher decryption failure
- Consistent decryption strategy across list and detail views

**Cons:**
- Changing the publisher signature from throwing to non-throwing affects all callers
- `decryptListWithFailures()` with a single-element array is awkward usage
- More invasive than Options A-C — requires updating `VaultRepository` protocol, all callers, and tests
- `try?` wrapping `decryptListWithFailures` means batch-level errors are silenced

### Option E: Combined Approach — Error State + Direct Fetch Fallback (Recommended)

Combine Option A (error state in catch) and Option B (direct fetch fallback) for a layered solution that handles both the immediate symptom and provides a recovery path.

**Approach:**
1. In the catch block of `streamCipherDetails()`:
   a. Log the error
   b. Attempt `fetchCipher(withId:)` as fallback
   c. If fallback succeeds, populate the state
   d. If fallback fails or returns nil, set `.error` state
2. Optionally add error state handling at the `guard var newState` point to handle the `CipherItemState` nil-ID rejection

**Pros:**
- Layered defense: stream error → fallback → error state
- User can view the item if direct fetch works, even when the publisher fails
- User sees clear error state if all paths fail
- Does not modify the publisher architecture
- Moderate complexity (~30-40 lines)

**Cons:**
- Fallback is a one-shot (no reactive updates)
- Adds a secondary code path that needs testing
- Does not fix the fundamental `asyncTryMap` stream-termination behavior (other callers of `cipherDetailsPublisher` may have the same issue)

### Option F: Fix at the Publisher Level — Replace `asyncTryMap` with Error-Resilient Mapping

Replace `asyncTryMap` with a custom mapping operator that catches errors per-emission rather than terminating the stream.

**Approach:**
1. Create a new extension (e.g., `asyncTryMapNonTerminating`) or modify the existing `asyncTryMap` to catch errors per-value:
   ```swift
   .flatMap(maxPublishers: .max(1)) { value in
       Future { promise in
           Task {
               do {
                   let result = try await transform(value)
                   promise(.success(result))
               } catch {
                   // Instead of failing the publisher, emit a sentinel or skip
                   promise(.success(nil))
               }
           }
       }
   }
   ```
2. Apply this operator in `cipherDetailsPublisher`
3. Add nil-handling in `streamCipherDetails()` or at the publisher level

**Pros:**
- Fixes the root cause — decryption errors don't terminate the stream
- The publisher continues to emit future values (reactive updates work)
- Could be reused by other publishers that have the same issue
- Most architecturally correct solution

**Cons:**
- Adding a new publisher operator affects the `BitwardenKit` target
- Need to decide how to represent errors (nil, Result type, or custom wrapper)
- More complex to implement and test
- Risk of masking errors if applied too broadly

---

## Recommendation

**Option E (Combined: Error State + Direct Fetch Fallback)** as the primary approach. This provides the best user experience improvement with moderate implementation risk:

1. The catch block sets `.error` state (preventing infinite spinner)
2. Before setting error state, a direct `fetchCipher` fallback is attempted (allowing the user to view the item if possible)
3. The `fetchCipher(withId:)` method already exists and uses `try?` for resilient decryption

If a broader fix is desired, **Option F** (error-resilient publisher mapping) addresses the root cause and benefits all callers of `cipherDetailsPublisher`, but it is more complex and should be considered as a follow-up improvement.

**Option A alone is insufficient** — it replaces the spinner with an error but doesn't attempt to actually show the item. **Option C alone is insufficient** — it prevents stream termination but results in the same spinner because `nil` triggers `continue`.

## Estimated Impact

- **Files changed:** 1-2 (`ViewItemProcessor.swift`, optionally `ViewItemProcessorTests.swift`)
- **Lines added:** ~30-50
- **Risk:** Low — the change is additive (catch block enhancement), no existing behavior is altered for the success path
- **Test additions:** 1-2 new tests (error fallback, direct fetch fallback)

## Related Issues

- **R3 (SS-5)**: Retry backoff — if a permanently failing item blocks sync, the offline-created cipher remains in its temporary state indefinitely, making this view failure permanent until R3 provides automated cleanup or recovery.
- **R4 (SS-3)**: Silent sync abort — the view failure is exacerbated by the user having no visibility into whether their item has synced or not. R4 logging aids debugging but not user experience.
- **U3 (VR-4)**: Pending changes indicator — if users had visibility into pending offline changes, they would understand why the item can't be viewed normally.
- **CS-2 (EXT-2)**: Fragile SDK copy methods — `Cipher.withTemporaryId()` sets `data: nil`, which may contribute to the decryption failure. If SDK changes affect the copy, this issue could worsen.
- **S3 / S4**: Batch processing and API failure tests — better test coverage of the offline flow would have caught this gap earlier.

## Updated Review Findings

This issue was discovered during manual testing of the offline sync feature. After detailed code analysis:

1. **Code verification**: `ViewItemProcessor.swift:549-600` confirms the publisher subscription pattern with error-only-logging catch block. `VaultRepository.swift:1111-1119` confirms `asyncTryMap` with `decrypt()`. `Publisher+Async.swift:49-58` confirms `flatMap`-based implementation that terminates on error.

2. **Asymmetry confirmed**: The vault list path (`CiphersClientWrapperService.swift:67`) uses `decryptListWithFailures()` which is resilient. The detail view path uses `decrypt()` which throws. This asymmetry means the list can display items that the detail view cannot load.

3. **`LoadingState` has the right tools**: The `.error(errorMessage:)` case at `LoadingState.swift:15` exists but is not used in the `streamCipherDetails()` catch block. The fix is straightforward.

4. **`fetchCipher(withId:)` is suitable for fallback**: At `VaultRepository.swift:610-613`, this method uses `try?` for decryption, making it resilient. It returns `nil` instead of throwing on decryption failure, which is the correct behavior for a fallback.

5. **Not specific to offline-created ciphers**: While this issue was discovered with offline-created ciphers, the underlying `asyncTryMap` stream-termination behavior could affect any cipher that fails `decrypt()`. The offline creation path simply makes this failure more likely due to the temporary cipher's non-standard construction (temporary UUID, `data: nil`).

**Conclusion**: This is a Medium severity usability issue. The infinite spinner with no error feedback is a poor user experience. The recommended fix (Option E) provides both recovery and clear feedback. The broader publisher fix (Option F) should be considered as a future improvement to the reactive data pipeline.
