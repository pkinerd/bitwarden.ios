# Action Plan: U3 (VR-4) — No User-Visible Indicator for Pending Offline Changes

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | U3 / VR-4 |
| **Component** | Feature-wide (UI) |
| **Severity** | Informational |
| **Type** | UX / Feature Gap |
| **Files** | Multiple (new UI components would be needed) |

## Description

When cipher operations are saved offline, the user has no indication that their changes are pending sync. If sync resolution continues to fail (e.g., persistent server error), the user is unaware that their changes haven't been uploaded. There's no badge, toast, banner, or other indicator for unsynced changes.

## Context

The current design treats offline save as transparent — the user sees their edit applied locally and the system handles sync automatically. This is the correct behavior for the happy path (connectivity restored quickly). The gap is in the failure path: if sync resolution fails repeatedly, the user has no visibility.

This is a UX feature that goes beyond the current offline sync implementation scope. It would require UI-layer changes, state observation, and potentially new notification infrastructure.

---

## Options

### Option A: Add a Vault-Level Banner/Badge

Show a banner or badge in the vault list view when pending offline changes exist.

**Approach:**
1. Expose a `hasPendingChanges` observable from `VaultRepository` or via a new `OfflineSyncStatusService`
2. In the vault list processor/view, observe the pending changes state
3. Display a subtle banner: "Some changes are pending sync" with a dismissible action
4. Remove the banner when all pending changes are resolved

**Pros:**
- Users are aware of unsynced changes
- Provides confidence that the system is working
- Dismissible — doesn't block usage
- Follows patterns from other apps with offline support

**Cons:**
- Requires UI-layer changes (new view component, processor changes)
- State observation setup needed (reactive stream from data store)
- Banner design needs UX review
- Could be alarming to users who don't understand what "pending sync" means
- Significant implementation effort

### Option B: Add a Toast on Offline Save

Show a brief toast notification immediately when an operation is saved offline: "Saved offline. Will sync when connected."

**Approach:**
1. In VaultRepository's offline handlers, trigger a notification/event
2. The active coordinator/processor shows a toast via existing toast infrastructure
3. Toast auto-dismisses after a few seconds

**Pros:**
- Immediate feedback at the moment of offline save
- Uses existing toast infrastructure (if available)
- Temporary — doesn't clutter the UI
- Clear and actionable message

**Cons:**
- Only shown at the moment of save — not visible later
- Doesn't help with persistent sync failures (user may have dismissed the toast)
- Requires threading the notification through the repository → UI layer
- May need new infrastructure if the project doesn't have toast support

### Option C: Add a Sync Status in Settings/Profile

Add a "Sync Status" section in the settings or profile screen that shows pending change count.

**Approach:**
1. Add a new row in the settings/profile screen
2. Display: "Pending offline changes: N" (or hidden when 0)
3. Optionally, add a "Sync Now" button

**Pros:**
- Non-intrusive — users who care can check
- Doesn't affect the main vault experience
- Simple UI change in an existing screen

**Cons:**
- Not discoverable — users may not know to check settings
- Doesn't provide proactive notification
- Low visibility for an important status

### Option D: Defer to Future Enhancement (Recommended for Initial Release)

Track this as a future enhancement and ship the initial feature without a pending changes indicator.

**Pros:**
- No code change
- Reduces initial scope
- The automatic sync handles the happy path (most users)
- Allows time to design the UX properly

**Cons:**
- Users with persistent sync failures have no visibility
- Could lead to data confidence issues

---

## Recommendation

**Option D** for the initial release, with **Option B** (toast on offline save) as the first enhancement to implement after the feature ships. The toast provides the most immediate value with reasonable implementation effort. **Option A** (vault banner) is the ideal long-term solution but requires more design and implementation work.

## Estimated Impact

- **Option D:** No change
- **Option B:** Files changed: 3-5, Lines added: ~50-100, Risk: Low
- **Option A:** Files changed: 5-10, Lines added: ~200-400, Risk: Medium

## Related Issues

- **R3 (SS-5)**: Retry backoff — if pending changes expire/are deleted after max retries, the user should be notified (ties into this indicator).
- **R4 (SS-3)**: Silent sync abort — the abort could trigger a notification instead of being silent.
- **DI-1**: DataStore exposed to UI layer — if a UI indicator is built, `HasPendingCipherChangeDataStore` in the `Services` typealias is actually needed.
- **S8**: Feature flag — **[Resolved]** the indicator should respect the feature flag state (`.offlineSyncEnableResolution`, `.offlineSyncEnableOfflineChanges`). Both default to `false` (server-controlled rollout).

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Current state** (reviewed 2026-02-18): No user-facing indication exists when changes are saved offline. The `handleOffline*` methods in VaultRepository (lines 1007, 1034, 1099, 1145) silently save locally and queue pending changes. The user's edit appears applied (local storage updated), but there's no visible distinction between "saved to server" and "saved locally, pending sync." No toast, banner, badge, or settings entry has been added since the original assessment.

2. **Infrastructure availability**: `PendingCipherChangeDataStore` provides `pendingChangeCount(userId:)` which can be used to check if pending changes exist. This method is called in `SyncService.swift:335` and `SyncService.swift:338`. Exposing it through a UI-observable mechanism would require threading through the repository or creating a new service.

3. **Toast infrastructure assessment**: The project uses toast notifications in various places. If an existing toast/notification system exists, Option B (toast on offline save) could be implemented by emitting a notification from the VaultRepository offline handlers. This would require the active coordinator/processor to subscribe to the notification.

4. **DI-1 interaction**: The DI-1 action plan noted that `HasPendingCipherChangeDataStore` is exposed in the `Services` typealias. If U3 is implemented, this exposure is actually needed for UI-layer access to pending change counts.

**Updated conclusion** (2026-02-18): Original recommendation (Option D for initial release, Option B as first enhancement) confirmed. No work has been done on any of the options. This is a UX feature that goes beyond the current offline sync scope. The core feature can ship without it. However, it should be prioritized for the first follow-up release. Priority: Informational for initial release.
