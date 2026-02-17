# Action Plan: R2 (RES-2) — `conflictFolderId` Thread Safety

> **Status: [RESOLVED]** — `DefaultOfflineSyncResolver` converted from `class` to `actor`. Single-keyword change provides compiler-enforced thread safety for `conflictFolderId` cache. Option A implemented.

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | R2 / RES-2 |
| **Component** | `DefaultOfflineSyncResolver` |
| **Severity** | ~~Low~~ Resolved |
| **Type** | Reliability / Thread Safety |
| **File** | `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift` |

## Description

`DefaultOfflineSyncResolver` is a `class` (reference type) with a mutable `var conflictFolderId: String?`. There is no `actor` isolation, lock, or other synchronization mechanism. Currently safe because `processPendingChanges` is called sequentially from `SyncService.fetchSync()`, but fragile if the resolver were ever called concurrently from multiple callers or tasks.

## Context

`conflictFolderId` is a cache that avoids redundant folder lookups/creation within a single `processPendingChanges` batch. It's reset to `nil` at the start of each batch and populated on first conflict. The value is only mutated in `getOrCreateConflictFolder()` and read in subsequent calls within the same batch.

The `ServiceContainer` shares one resolver instance between `SyncService` and the container itself. Currently only `SyncService` calls `processPendingChanges`, but the shared instance means any future consumer via the container could introduce concurrency.

---

## Options

### Option A: Convert to `actor` (Recommended)

Convert `DefaultOfflineSyncResolver` from `class` to `actor`, which provides automatic isolation for all mutable state.

**Codebase precedent:** The project already uses Swift actors for 7 services:
- `actor DefaultPolicyService` (`PolicyService.swift:83`)
- `actor DefaultClientService` (`ClientService.swift:135`)
- `actor DefaultStateService` (`StateService.swift:1361`)
- `actor DefaultTokenService` (`TokenService.swift:46`)
- `actor DefaultAuthenticatorSyncService` (`AuthenticatorSyncService.swift:30`)
- `actor DefaultRehydrationHelper` (`RehydrationHelper.swift:18`)
- `actor DefaultAccountTokenProvider` (`AccountTokenProvider.swift:19`)

This is an established pattern in the codebase, not a novel approach.

**Approach:**
1. Change `class DefaultOfflineSyncResolver` to `actor DefaultOfflineSyncResolver`
2. The `OfflineSyncResolver` protocol already uses `func processPendingChanges(userId: String) async throws` — no protocol change needed
3. Internal methods that access `conflictFolderId` are automatically isolated
4. Test mock (`MockOfflineSyncResolver`) remains a class (mocks don't need actor isolation)

**Pros:**
- Compiler-enforced thread safety
- No manual synchronization needed
- Follows the established project pattern (7 existing actors)
- Future-proof against concurrent callers
- Trivial change: only the keyword changes

**Cons:**
- `actor` types have re-entrancy semantics — all method calls from outside are `await`-based, which they already are (protocol uses `async`)
- May require `nonisolated` annotations on init if the initializer is called from a non-async context (check `ServiceContainer.swift` wiring)
- All callers must `await` — but they already do since the protocol is `async`

### Option B: Add `@MainActor` Isolation

Annotate the class with `@MainActor` to ensure all access occurs on the main actor.

**Pros:**
- Simple annotation
- Compiler-enforced

**Cons:**
- `@MainActor` is inappropriate — sync resolution is a background operation that should NOT be on the main thread
- Would block the main thread during resolution
- Incorrect architectural choice

### Option C: Add a Comment Documenting Serial-Only Requirement

Add a comment to the class and/or `processPendingChanges` method documenting that it must only be called from a serial context.

**Approach:**
```swift
/// - Important: This resolver maintains mutable state (`conflictFolderId` cache).
///   It must only be called from a serial execution context (e.g., SyncService.fetchSync).
///   Concurrent calls from multiple tasks will produce undefined behavior.
```

**Pros:**
- No code change
- Documents the constraint
- Cheapest option

**Cons:**
- No compiler enforcement — relies on developer discipline
- Easy to violate accidentally as the codebase evolves
- Doesn't follow Swift concurrency best practices

### Option D: Use a Lock/NSLock for `conflictFolderId`

Keep the class but protect `conflictFolderId` with an `NSLock` or `os_unfair_lock`.

**Pros:**
- Minimal change — only the cache variable is protected
- No type change (stays as `class`)

**Cons:**
- Mixing locks with async/await is an anti-pattern in Swift
- Lock does not protect against re-entrancy in async methods
- More complex than necessary when `actor` is available
- Doesn't protect the read-modify-write pattern in `getOrCreateConflictFolder`

---

## Recommendation

**Option A** — Convert to `actor`. This is the Swift-native solution for a class with mutable state that could be accessed from concurrent contexts. Since the protocol already uses `async`, the migration is straightforward. If `actor` conversion introduces unexpected complexity (e.g., protocol conformance issues), fall back to Option C (document the constraint).

## Estimated Impact

- **Files changed:** 1-2 (`OfflineSyncResolver.swift`, possibly callers if protocol changes are needed)
- **Lines changed:** ~5 (keyword change + any annotations)
- **Risk:** Low — the functional behavior doesn't change; only the isolation model changes

## Related Issues

- **DI-4**: Shared resolver instance — if the resolver is shared, actor isolation is especially important to prevent concurrent access.
- **A3 (RES-5)**: Unused timeProvider — if converting to actor, removing unused dependencies first simplifies the migration.

## Updated Review Findings

The review confirms the original assessment with code-level detail:

1. **Code verification**: `OfflineSyncResolver.swift:55` declares `class DefaultOfflineSyncResolver`. Line 86 declares `private var conflictFolderId: String?`. This is mutable state on a reference type without any concurrency protection.

2. **Mutation points verified**:
   - Line 126: `conflictFolderId = nil` (reset at start of batch)
   - Line 347: `conflictFolderId = folderId` (set after finding existing folder)
   - Line 357: `conflictFolderId = id` (set after creating new folder)
   - Lines 336-337: `if let conflictFolderId { return conflictFolderId }` (read for cache hit)

3. **Actor conversion feasibility**: The `OfflineSyncResolver` protocol (line 40) defines `func processPendingChanges(userId: String) async throws` - already async. Converting `DefaultOfflineSyncResolver` from `class` to `actor` would:
   - Automatically isolate `conflictFolderId` mutations
   - Require no protocol changes (already async)
   - Require `nonisolated` on init if called from non-async context (check ServiceContainer)

4. **ServiceContainer init context**: `ServiceContainer.swift` creates the resolver in `defaultServices()` which is a synchronous factory method. The `DefaultOfflineSyncResolver.init` would need to be `nonisolated` when the type becomes an actor. Swift actors allow `nonisolated init` by default for stored property initialization, so this should work without annotation.

5. **Codebase precedent confirmed**: 7 existing services use `actor` in the project. This is a well-established pattern. The conversion is a single keyword change from `class` to `actor`.

6. **Mock compatibility**: `MockOfflineSyncResolver` is a separate `class` (in TestHelpers). It does NOT need to be an actor since mocks are test-only and called from controlled contexts.

**Updated conclusion**: Original recommendation (Option A - convert to actor) confirmed strongly. This is a single-keyword change that follows established project conventions and provides compile-time thread safety. No protocol changes needed. Priority: Low but trivial and follows best practices.
