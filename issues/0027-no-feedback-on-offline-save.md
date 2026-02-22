---
id: 27
title: "[VR-4] No user feedback on successful offline save"
status: open
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
---

## Description

No user feedback on successful offline save — operation completes silently.

**Severity:** Low
**Complexity:** Medium
**Action Plan:** AP-55

**Related Documents:** ReviewSection_VaultRepository.md

## Action Plan

*Source: `ActionPlans/AP-55.md`*

> **Issue:** #55 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Medium
> **Status:** Triaged
> **Source:** ReviewSection_VaultRepository.md (Issue VR-4)

## Problem Statement

When a user creates, edits, deletes, or soft-deletes a vault cipher while offline, the VaultRepository's offline handler methods (`handleOfflineAdd`, `handleOfflineUpdate`, `handleOfflineDelete`, `handleOfflineSoftDelete`) save the change locally and queue a pending change record, but the operation completes silently with the same behavior as a successful server save. The user receives no indication that their change was saved locally rather than synced to the server. They have no way to know that:

1. Their change has not yet been uploaded to the server.
2. The change will be synced automatically when connectivity returns.
3. There may be a delay before other devices see the change.

This contrasts with user expectations in other apps with offline support, which typically provide a brief notification (e.g., "Saved offline. Will sync when connected.") to set expectations.

## Current Behavior

The offline save flow for each operation is identical from the UI's perspective to an online save:

**Add cipher (offline):**
- `AddEditItemProcessor.saveItem()` (`AddEditItemProcessor.swift:669`) calls `addItem()` (`AddEditItemProcessor.swift:707`)
- `addItem()` calls `services.vaultRepository.addCipher(state.cipher)` (`AddEditItemProcessor.swift:721`)
- Inside `VaultRepository.addCipher()` (`VaultRepository.swift:505`), the server call fails, and `handleOfflineAdd()` (`VaultRepository.swift:1031`) saves locally
- `handleOfflineAdd` completes without error — control returns to `addItem()`
- `addItem()` calls `handleDismiss(didAddItem: true)` (`AddEditItemProcessor.swift:723`), which navigates to `.dismiss()`
- The user sees the add/edit view dismissed and the vault list updated with their new cipher
- **No toast, no banner, no offline indicator**

**Update cipher (offline):**
- `AddEditItemProcessor.updateItem()` (`AddEditItemProcessor.swift:878`) calls `services.vaultRepository.updateCipher()`
- Inside `VaultRepository.updateCipher()` (`VaultRepository.swift:970`), the server call fails, and `handleOfflineUpdate()` (`VaultRepository.swift:1058`) saves locally
- Control returns to `updateItem()`, which calls `delegate?.itemUpdated()` (`AddEditItemProcessor.swift:881`) and dismisses
- **No toast, no banner, no offline indicator**

**Delete/soft-delete cipher (offline):**
- Same pattern: `ViewItemProcessor.permanentDeleteItem()` or `softDeleteItem()` (`ViewItemProcessor.swift:334`, `ViewItemProcessor.swift:351`) call the repository, which silently falls back to offline storage
- The view is dismissed and the delegate is notified
- **No toast, no banner, no offline indicator**

The `handleOffline*` methods in `VaultRepository.swift` (lines 1031, 1058, 1123, 1169) do not throw errors and do not return any indicator to the calling code that an offline fallback occurred. The caller has no way to differentiate between "saved to server" and "saved locally, pending sync."

## Expected Behavior

After a successful offline save, the user should see a brief, non-blocking notification indicating that their change was saved locally and will sync when connectivity returns. For example:

- Toast: "Saved offline. Will sync when connected."
- Or: "Changes saved locally. Syncing when online."

This should be transient (auto-dismiss after 3-5 seconds) and non-alarming. It should not block the user's workflow.

## Assessment

**Still Valid:** Yes. The `handleOffline*` methods at `VaultRepository.swift:1031-1199` still complete silently. No toast, notification, or return value indicates an offline fallback occurred.

**User Impact:** Low-Medium. While the silent save is functionally correct (the data is safely persisted and will sync automatically), users of a password manager may be particularly concerned about whether their changes are synced across devices. Without feedback, a user might:
- Assume the change was synced and try to use the updated credentials on another device, only to find the old version.
- Not realize they were offline and be confused when changes appear to "revert" after a sync conflict is resolved.
- Lose confidence in the app's reliability.

The impact is mitigated by the fact that sync happens automatically and quickly once connectivity returns.

**Priority:** Low for initial release. This is a UX polish item. The core functionality (save locally, sync later) works correctly. However, this should be a high-priority follow-up enhancement.

**Relationship to AP-U3:** The existing AP-U3 (No Pending Changes Indicator) covers the broader problem of indicating pending offline changes. This AP-55 focuses specifically on the moment-of-save feedback, which is a subset of U3's Option B (Toast on Offline Save). The two are complementary, not duplicative.

## Options

### Option A: Return Offline Status from Repository Methods (Recommended)

- **Effort:** Medium (~40-60 lines, 3-4 files)
- **Description:** Modify the VaultRepository CRUD methods to return an indication of whether the operation was saved offline. Then, have the UI-layer processors show a toast when an offline save occurs.

  **Step 1: Add a return type or result indicator.**

  Option A.1 — Use an enum return type:
  ```swift
  enum CipherSaveResult {
      case savedOnline
      case savedOffline
  }

  func addCipher(_ cipher: CipherView) async throws -> CipherSaveResult
  ```
  This changes the public API, which affects all callers and mocks.

  Option A.2 — Use a callback/delegate pattern:
  ```swift
  // Add an optional offline save handler
  var onOfflineSave: (() -> Void)?
  ```
  This avoids changing the method signature but adds state to the repository.

  Option A.3 — Throw a non-error "notification" (anti-pattern, not recommended).

  **Step 2: Show toast in processors.**
  In `AddEditItemProcessor`:
  ```swift
  private func addItem(fido2UserVerified: Bool) async throws {
      let result = try await services.vaultRepository.addCipher(state.cipher)
      coordinator.hideLoadingOverlay()
      if result == .savedOffline {
          // Show toast before dismissing
          state.toast = Toast(title: Localizations.savedOfflineWillSyncWhenConnected)
      }
      handleDismiss(didAddItem: true)
  }
  ```

- **UX Impact:** Users receive immediate, contextual feedback at the moment of offline save.
- **Pros:**
  - Clear, typed API that distinguishes online vs offline save
  - Follows the existing toast pattern used throughout the app
  - Each processor can decide how to handle the offline indicator
- **Cons:**
  - Changes the public API of `VaultRepository` (all 4 CRUD methods)
  - Requires updating the `VaultRepository` protocol, mock, and all callers
  - The toast may be shown briefly before the view dismisses, so the user might not see it. The toast would need to be shown on the parent view (vault list) instead.
  - Feature flag check needed: only show feedback when offline sync flags are enabled

### Option B: Use Notification Center for Offline Save Events

- **Effort:** Medium (~30-50 lines, 3-4 files)
- **Description:** Have the `handleOffline*` methods post a `Notification` (via `NotificationCenter`) when an offline save occurs. The active coordinator or a global notification handler shows the toast.

  In `VaultRepository`:
  ```swift
  private func handleOfflineAdd(encryptedCipher: Cipher, userId: String) async throws {
      // ... existing save logic ...
      NotificationCenter.default.post(name: .didSaveOffline, object: nil)
  }
  ```

  In a global notification handler or the vault coordinator:
  ```swift
  NotificationCenter.default.addObserver(forName: .didSaveOffline, ...) { _ in
      // Show toast on the current view
  }
  ```

- **Pros:**
  - Does not change the VaultRepository public API
  - Decoupled — any UI component can observe the notification
  - Works across all CRUD operations without per-method changes
- **Cons:**
  - NotificationCenter is a global side channel, which can be harder to test
  - The notification may arrive after the view has been dismissed
  - Not aligned with the project's DI/protocol-based architecture
  - Threading concerns (notification posted from async context, observed on main thread)

### Option C: Show Toast on Parent View After Dismiss

- **Effort:** Medium (~30-40 lines, 3-5 files)
- **Description:** Instead of showing the toast on the add/edit view (which is being dismissed), pass the offline status to the parent view (vault list) via the delegate protocol, and show the toast there.

  Extend `CipherItemOperationDelegate`:
  ```swift
  func itemAdded(savedOffline: Bool) -> Bool
  func itemUpdated(savedOffline: Bool) -> Bool
  ```

  In the parent processor:
  ```swift
  func itemAdded(savedOffline: Bool) -> Bool {
      if savedOffline {
          state.toast = Toast(title: Localizations.savedOfflineWillSyncWhenConnected)
      }
      return true
  }
  ```

- **Pros:**
  - Toast is shown on the view that remains visible after dismiss
  - Uses existing delegate pattern
  - User will reliably see the toast
- **Cons:**
  - Requires changes to the delegate protocol (affects multiple implementations)
  - The "savedOffline" information must flow from VaultRepository through multiple layers
  - More complex data threading

### Option D: Accept As-Is

- **Rationale:** The silent offline save is an intentional UX decision for the initial release. The offline sync feature's design philosophy is transparency — the user's operation succeeds locally and syncs automatically. Adding notifications could:
  - Create anxiety ("Why isn't my password synced? Is it safe?")
  - Add UI noise for a transient condition that resolves automatically
  - Require additional localization effort

  The automatic sync on reconnect handles the common case. The rare case of persistent sync failure is addressed separately by Issue U3 (pending changes indicator) and R3 (retry backoff).

- **Pros:**
  - Zero effort
  - Keeps the UX simple and uncluttered
  - Avoids potentially alarming users
- **Cons:**
  - Users have no awareness of offline state
  - Cross-device sync expectations may not be met

## Recommendation

**Option D: Accept As-Is** for the initial release, with **Option A (A.1 variant) combined with Option C** as the recommended post-release enhancement. The rationale:

1. **Initial release:** The silent save behavior is defensible. The offline sync is designed to be transparent, and the automatic sync handles the common case. Adding offline notifications increases scope and requires UX design review.

2. **Post-release enhancement:** Option A (return `CipherSaveResult` from repository methods) combined with Option C (show toast on parent view after dismiss) provides the best user experience. The repository communicates the save status, the processor passes it to the delegate, and the parent view shows a toast that the user will actually see. This requires:
   - Changing `VaultRepository` protocol methods to return `CipherSaveResult`
   - Updating `AddEditItemProcessor` and `ViewItemProcessor` to propagate the result
   - Extending `CipherItemOperationDelegate` with `savedOffline` parameter
   - Adding a localization string: "Saved offline. Will sync when connected."

This aligns with AP-U3's Option B recommendation (toast on offline save) and should be implemented together with U3 in a single enhancement pass.

## Dependencies

- **Related Issues:**
  - #23 / U3: No user-visible indicator for pending offline changes (broader version of this issue). See AP-U3.
  - #1 / R3: Retry backoff — if offline changes fail to sync permanently, the user should be notified.
  - #2 / R4: Silent sync abort — related to user visibility into sync state.
  - Feature flags: `.offlineSyncEnableResolution` and `.offlineSyncEnableOfflineChanges` must both be enabled for offline save to occur, so feedback should respect these flags.

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 4d: UX Improvements*

No user feedback on successful offline save — operation completes silently.

## Code Review References

### From `ReviewSection_VaultRepository.md`

### Issue VR-4: No User Feedback on Successful Offline Save (Informational)

When a cipher is saved offline, the operation completes silently — the user has no indication that their change was saved locally but not yet synced to the server. There's no toast, badge, or other indicator.

**Assessment:** This is an intentional UX decision for the initial implementation. The sync happens automatically on reconnection, so the user doesn't need to take action. A future enhancement could add a subtle indicator when pending offline changes exist.

## Comments
