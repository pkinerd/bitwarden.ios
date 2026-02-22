---
id: 30
title: "[R2-UP-3] PassthroughSubject change — semantically correct"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

`PassthroughSubject` change is semantically correct for event stream — accepted as-is.

**Disposition:** Accepted
**Action Plan:** AP-57 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-57_PassthroughSubjectChange.md`*

> **Issue:** #57 from ConsolidatedOutstandingIssues.md
> **Severity:** Medium | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/09_UpstreamChanges_Review.md

## Problem Statement

The `MockCipherService` changed its `cipherChangesSubject` property from `CurrentValueSubject<CipherChange, Never>` to `PassthroughSubject<CipherChange, Never>`. This alters timing semantics: `CurrentValueSubject` replays its most recent value to new subscribers, while `PassthroughSubject` does not. Tests that relied on subscribing to the subject after a value was sent would silently stop receiving that initial value, potentially masking timing-dependent bugs or causing test failures.

The concern is that this change, made as part of the offline sync work, could affect existing tests that use `MockCipherService.cipherChangesSubject` by altering their timing behavior.

## Current State

**MockCipherService:**
- `BitwardenShared/Core/Vault/Services/TestHelpers/MockCipherService.swift:23` declares:
  ```swift
  var cipherChangesSubject = PassthroughSubject<CipherChange, Never>()
  ```
- The mock also includes a `cipherChangesSubscribed` property (line 24) to track when a subscription is established -- this was added alongside the `PassthroughSubject` change to help tests coordinate timing.

**MockCipherDataStore (different layer):**
- `BitwardenShared/Core/Vault/Services/Stores/TestHelpers/MockCipherDataStore.swift:23` uses:
  ```swift
  var cipherChangesSubjectByUserId: [String: CurrentValueSubject<CipherChange, Never>] = [:]
  ```
- This is the data store level mock, which retains `CurrentValueSubject` -- only the service-level mock was changed.

**Production CipherService:**
- `BitwardenShared/Core/Vault/Services/CipherService.swift:463-465` delegates to `cipherDataStore.cipherChangesPublisher(userId:)`, which returns whatever the data store provides. The production code does not use either subject type directly.

**Test usage of `cipherChangesSubject`:**
- `AutofillCredentialService+AppExtensionTests.swift` sends values via `cipherService.cipherChangesSubject.send(...)` at lines 126, 179, 215, 252, 274, 303. These tests send values *after* the subscription is established (the processor subscribes during `perform(.appeared)`), so `PassthroughSubject` semantics are correct here.
- The `cipherChangesSubscribed` flag at `MockCipherService.swift:24` enables tests to verify subscription timing if needed.

## Assessment

**This issue is valid but the change is intentionally correct.** The switch from `CurrentValueSubject` to `PassthroughSubject` was a deliberate design choice for the mock, not an accidental regression:

1. **`CipherChange` is an event, not a state.** The `CipherChange` enum represents discrete events (`.upserted`, `.deleted`, `.replacedAll`), not a continuously-held value. There is no meaningful "current value" -- a `PassthroughSubject` more accurately models event-stream semantics.

2. **`CurrentValueSubject` requires an initial value.** For `CipherChange`, there is no sensible default initial value. A `CurrentValueSubject` would require fabricating a dummy initial value that would be replayed to every new subscriber, which is incorrect behavior.

3. **The `cipherChangesSubscribed` flag provides synchronization.** Tests that need to ensure the subscription is active before sending events can check `cipherChangesSubscribed`, which was added as part of this change to replace the implicit synchronization that `CurrentValueSubject` replay provided.

4. **All existing tests pass.** The `AutofillCredentialService+AppExtensionTests` tests all send events after the subscriber is established (post `.appeared` effect), so the timing change has no practical impact on them.

## Options

### Option A: Accept As Correct (Recommended)
- **Effort:** None
- **Description:** Accept the `PassthroughSubject` change as the correct semantic choice. `CipherChange` is an event stream, not a stateful value, and `PassthroughSubject` correctly models this.
- **Pros:** No work required; semantics are already correct.
- **Cons:** None.

### Option B: Add Documentation Comment
- **Effort:** 5 minutes
- **Description:** Add a brief comment to `MockCipherService.cipherChangesSubject` explaining why `PassthroughSubject` was chosen over `CurrentValueSubject`.
- **Pros:** Prevents future developers from "fixing" it back to `CurrentValueSubject`.
- **Cons:** Minimal value; the choice is self-evident from the type semantics.

### Option C: Revert to CurrentValueSubject
- **Effort:** 15 minutes
- **Description:** Revert to `CurrentValueSubject` with a dummy initial value.
- **Pros:** Maintains backward compatibility with any test patterns that relied on replay.
- **Cons:** Semantically incorrect for an event stream. Requires a fabricated initial value that could mask timing bugs. No tests actually depend on replay behavior.

## Recommendation

**Option A: Accept As Correct.** The change from `CurrentValueSubject` to `PassthroughSubject` is the right semantic choice for an event-stream publisher. All existing tests work correctly with the new subject type, and the added `cipherChangesSubscribed` flag provides explicit synchronization where needed. No further action is required.

## Dependencies

- None. This is a test infrastructure change that does not affect production code.

## Comments
