# Action Plan: S8 — Feature Flag for Production Safety

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | S8 |
| **Component** | Feature-wide |
| **Severity** | Medium |
| **Type** | Production Safety |
| **File** | Multiple files |

## Description

The offline sync feature has no feature flag or kill switch. If issues are discovered in production (e.g., data corruption, sync loops, unexpected conflict behavior), the only mitigation is a code change and app update — a process that takes days to weeks through App Store review. A feature flag would allow the team to disable the offline sync behavior remotely without shipping an app update.

## Context

**The project has a well-established server-controlled feature flag system.** Feature flags are defined in `BitwardenShared/Core/Platform/Models/Enum/FeatureFlag.swift` as static properties on a `FeatureFlag` struct extension. Existing flags include `.archiveVaultItems`, `.cipherKeyEncryption`, `.migrateMyVaultToMyItems`, etc. Flags are checked via `configService.getFeatureFlag(.flagName)` which returns `Bool`. This pattern is already used in `SyncService.swift:560` for vault migration.

The offline sync feature touches `VaultRepository` (offline fallback handlers), `SyncService` (pre-sync resolution), and `OfflineSyncResolver` (conflict resolution). Disabling the feature means:
1. Not catching network errors for offline fallback (let errors propagate normally)
2. Not running pre-sync resolution in `SyncService.fetchSync()`
3. Existing pending changes would remain in Core Data until the feature is re-enabled or the user logs out

---

## Options

### Option A: Server-Controlled Feature Flag (Recommended)

Add a server-controlled feature flag using the existing `FeatureFlag` system and `ConfigService`. The flag is checked at the two entry points: VaultRepository offline catch blocks and SyncService pre-sync resolution.

**Concrete Approach:**
1. Add flag definition in `BitwardenShared/Core/Platform/Models/Enum/FeatureFlag.swift`:
   ```swift
   static let offlineSync = FeatureFlag(rawValue: "offline-sync-enable-offline-changes")
   ```
2. Add to `allCases` array in the same file
3. In VaultRepository's catch blocks (requires adding `configService` dependency or passing flag value):
   ```swift
   catch let error as URLError where error.isNetworkConnectionError {
       guard await configService.getFeatureFlag(.offlineSyncEnableOfflineChanges) else { throw error }
       // ... handleOffline...
   }
   ```
4. In SyncService's pre-sync block (already has `configService` via existing pattern):
   ```swift
   guard await configService.getFeatureFlag(.offlineSyncEnableOfflineChanges) else { /* skip resolution */ }
   ```
5. Both flags default to `false` (no `initialValue`) — the server must explicitly enable them, consistent with all other feature flags in the project

**Pros:**
- Can disable instantly via server configuration — no app update needed
- Follows the exact same pattern already used in `SyncService.swift:560` for `.migrateMyVaultToMyItems`
- Granular control (can enable/disable per user segment, region, etc.)
- Standard pattern for production safety — consistent with 11 existing feature flags
- Minimal code change at the two entry points

**Cons:**
- ~~VaultRepository currently does not have a `configService` dependency — needs to be added (or the flag check moved to the calling layer)~~ **[Resolved]** VaultRepository now has `configService` (line 332)
- Feature flag check adds a small async call to every cipher operation's error path
- Pending changes created before flag is disabled will remain orphaned until re-enabled or logout
- Does not address what happens to existing pending changes when the flag is turned off

**Note on VaultRepository dependency:** ~~SyncService already has access to `configService` (used for vault migration). VaultRepository would need `HasConfigService` added to its `Services` typealias.~~ **[Updated]** Both SyncService and VaultRepository now have `configService` dependencies, so the flag can be checked at both entry points without additional wiring.

### Option B: Local Feature Flag (App Configuration)

Add a local-only feature flag that can be toggled via app settings or a debug menu.

**Approach:**
- Add a `Bool` flag in `AppSettingsStore` (e.g., `isOfflineSyncEnabled`, defaulting to `true`)
- Check the flag at the same two entry points as Option A
- Optionally expose in a debug/settings menu for testing

**Pros:**
- No server dependency
- Simple implementation
- Useful for internal testing and QA

**Cons:**
- Cannot disable remotely for all users — each user must manually change the setting or update the app
- Not useful as a production kill switch
- Adds a user-facing setting for a feature that should be transparent

### Option C: Compile-Time Feature Flag

Use a compile-time flag (e.g., `#if OFFLINE_SYNC_ENABLED`) that can be toggled in the build configuration.

**Approach:**
- Add a compiler flag to the build settings
- Wrap all offline sync code in `#if` blocks
- Release builds can include or exclude the feature

**Pros:**
- Zero runtime overhead when disabled
- Clear code boundaries

**Cons:**
- Requires a new app build and App Store submission to toggle
- No better than removing the code entirely
- Does not serve as a production kill switch
- Conditional compilation makes the code harder to read and maintain

### Option D: No Feature Flag (Accept Risk)

Accept the current state — no feature flag. Rely on the feature's built-in safety mechanisms (early-abort sync, conflict backup creation, org cipher exclusion) and address any production issues via app updates.

**Pros:**
- No additional code or infrastructure
- Feature is already designed with multiple safety layers
- Simplest approach

**Cons:**
- No remote kill switch for production emergencies
- App Store review process means 1-7 days minimum to deploy a fix
- If a critical issue is found (e.g., sync loop causing battery drain), users are affected until the update ships
- Inconsistent with industry best practices for new feature rollout

---

## Recommendation

**Option A** — Server-controlled feature flag. The project already has a mature feature flag system with 9 existing flags, a `FeatureFlag` struct, and `configService.getFeatureFlag()` access pattern. Adding a new flag follows the exact established pattern (see `.migrateMyVaultToMyItems` usage in `SyncService.swift:560` as a direct precedent). The implementation cost is very low.

**Important considerations:**
1. When the flag is disabled, existing pending changes should remain in Core Data silently, to be resolved when re-enabled. This is simpler and safer than cleanup.
2. The flag check at the SyncService level (for resolution gating) is trivial since `configService` is already available. The VaultRepository check requires adding a `configService` dependency. A pragmatic approach: gate only the SyncService resolution initially, allowing offline saves to continue but preventing resolution until the flag is enabled.

## Estimated Impact

- **Files changed:** 3 (VaultRepository, SyncService, FeatureFlag.swift) — **[Updated]** Services.swift no longer needed since VaultRepository already has `configService`
- **Lines added:** ~15-20
- **Risk:** Low — additive check at two entry points

## Related Issues

- **R3 (SS-5)**: Retry backoff — a feature flag and retry backoff are complementary safety mechanisms. If the flag is implemented, retry backoff is less critical (the feature can be disabled entirely if there's a retry storm).
- **U2**: Inconsistent offline support — the feature flag should gate all offline operations uniformly.
- **U3**: No pending changes indicator — if the feature is flagged off while pending changes exist, the user should ideally be informed.
- **R4 (SS-3)**: Silent sync abort — logging is especially important when a feature flag controls behavior, for debugging.

## Updated Review Findings

The review confirms the original assessment with important code-level details. After reviewing the implementation:

1. **Feature flag system verification**: `FeatureFlag.swift` defines 9 existing flags as static properties on `FeatureFlag` extension (line 7). The pattern is `static let flagName = FeatureFlag(rawValue: "server-flag-name")`. The `allCases` array at line 35 lists all 9 flags. Adding `.offlineSyncEnableOfflineChanges` would follow this exact pattern. ~~**No offline sync feature flag has been added yet.**~~ **[Resolved]** Two feature flags have been added: `.offlineSyncEnableResolution` and `.offlineSyncEnableOfflineChanges`.

2. **SyncService precedent verified**: `SyncService.swift` already uses `configService.getFeatureFlag(.migrateMyVaultToMyItems)` at line 561. The pre-sync resolution block at lines 329-343 is the natural place for the offline sync flag check.

3. **VaultRepository dependency resolved**: **[Updated]** `VaultRepository.swift` now HAS a `configService` dependency (line 332). This removes the previously identified blocker for Tier 2 gating. Both SyncService and VaultRepository can check the feature flag without additional dependency wiring.

4. ~~**Pragmatic approach - two-tier gating**:~~
   - ~~**Tier 1 (simple, immediate)**: Gate only the SyncService resolution path.~~
   - ~~**Tier 2 (complete, now straightforward)**: Also gate VaultRepository offline fallback.~~

   **[Resolved]** Both tiers were implemented together:
   - **SyncService** (`SyncService.swift:341`): `offlineSyncEnableResolution` gates the entire pre-sync resolution block — when `false`, the block is skipped entirely (both resolution AND abort check), and `replaceCiphers` proceeds normally.
   - **VaultRepository** (`VaultRepository.swift`): Both `offlineSyncEnableResolution` AND `offlineSyncEnableOfflineChanges` must be `true` for offline save fallback. Each cipher operation's catch block (`addCipher`, `updateCipher`, `deleteCipher`, `softDeleteCipher`) checks both flags via AND logic — when either is `false`, errors propagate normally.

5. ~~**Important consideration**: Tier 1 alone creates an asymmetry~~ **[Resolved]** — Both tiers were implemented together, avoiding the asymmetry concern. The two-flag design additionally provides granular control: `offlineSyncEnableResolution` can be disabled independently to stop resolution while still allowing offline saves to drain (though documentation notes this is not recommended).

6. **Flag default values**: Both flags default to `false` (no `initialValue`), consistent with the project convention where all 11 feature flags use server-controlled rollout. An earlier iteration set `initialValue: .bool(true)` (enabled by default, acting as kill switches), but this was revised to align with the established project pattern. The server must explicitly enable both flags for offline sync to activate.

**Updated conclusion**: ~~Recommendation stands. **The feature flag has NOT been implemented yet** — no `.offlineSyncEnableOfflineChanges` flag exists in `FeatureFlag.swift` and no flag check gates the offline sync code paths. The implementation cost is now lower than originally estimated since VaultRepository already has `configService`. Priority remains Medium — this should be implemented before production release.~~ **[Resolved]** S8 is fully implemented. Two server-controlled feature flags gate the offline sync feature at all entry points:
- `.offlineSyncEnableResolution` (`"offline-sync-enable-resolution"`) — gates pre-sync resolution in SyncService
- `.offlineSyncEnableOfflineChanges` (`"offline-sync-enable-offline-changes"`) — gates offline save fallback in VaultRepository (only effective when resolution is also enabled)

Both default to `false` (server-controlled rollout). Tests explicitly set flag values via `configService.featureFlagsBool` and do not depend on `initialValue`.

---

## S8.a: Orphaned Pending Changes When Feature Flag Is Disabled

> **Issue:** #51 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Medium
> **Status:** Resolved (Design decision — orphaned pending changes are the intentional and safe result of the kill-switch design; two-flag architecture provides maximum operational flexibility)

### Problem Statement

When the feature flags (`offlineSyncEnableResolution` and/or `offlineSyncEnableOfflineChanges`) are disabled (either by server configuration or because they default to `false` before being enabled), existing pending change records remain in Core Data with no cleanup or notification mechanism. These records:

1. Are not processed during sync (the resolution block at `SyncService.swift:341` is skipped entirely when `offlineSyncEnableResolution` is `false`)
2. Are not deleted or cleaned up (no code runs to remove them when flags are disabled)
3. Are not visible to the user (no UI indicator exists for pending changes)
4. Continue to occupy Core Data storage indefinitely

If the flags are later re-enabled, these pending changes will be processed on the next sync cycle. If the flags are never re-enabled, the records persist until the user logs out (at which point `DataStore.deleteDataForUser` at `DataStore.swift:91-109` clears them).

### Current Code

**SyncService flag check at SyncService.swift:341-351:**
```swift
if await configService.getFeatureFlag(.offlineSyncEnableResolution),
   !isVaultLocked {
    let pendingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
    if pendingCount > 0 {
        try await offlineSyncResolver.processPendingChanges(userId: userId)
        let remainingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
        if remainingCount > 0 {
            return
        }
    }
}
```

When `offlineSyncEnableResolution` is `false`, the entire block is skipped. No count check, no resolution, no abort. The `replaceCiphers` call proceeds normally, potentially overwriting local cipher data that was modified by offline edits. However, the pending change records are NOT deleted -- they remain in Core Data.

**VaultRepository flag check (e.g., addCipher at VaultRepository.swift:536-541):**
```swift
guard !isOrgCipher,
      await configService.getFeatureFlag(.offlineSyncEnableResolution),
      await configService.getFeatureFlag(.offlineSyncEnableOfflineChanges)
else {
    throw error
}
```

When either flag is `false`, errors propagate normally -- no new pending changes are created.

**Data cleanup on logout at DataStore.swift:105:**
```swift
PendingCipherChangeData.deleteByUserIdRequest(userId: userId),
```

Pending changes are cleaned up on user logout/account deletion.

### Assessment

**Validity:** This issue is valid. When flags are disabled, pending changes become orphaned -- they exist in Core Data but are neither processed nor cleaned up. However, the practical impact is low:

1. **The "orphan" state is intentional and documented.** The feature flag design explicitly chose to leave pending changes in place when the flag is disabled, rather than deleting them. This is the safer approach -- if the flag is re-enabled, the changes can be resolved. Deleting them would permanently lose the user's offline edits.

2. **Storage impact is negligible.** Pending change records are small (a few KB each, plus the cipher data blob which is typically 1-5 KB). Even dozens of orphaned records would consume less than 100 KB. There is no performance impact from their presence.

3. **`replaceCiphers` overwrites local edits.** When resolution is skipped, the full sync's `replaceCiphers` call will overwrite the local cipher data with server data. If the user made offline edits to an existing cipher, those edits are lost from the local `CipherData` store. However, the `PendingCipherChangeData` record still contains the cipher data snapshot -- so the edits are preserved in the pending change record, awaiting resolution when the flag is re-enabled.

4. **No notification is needed.** The user has no visibility into pending changes regardless of flag state (see AP-U3). Adding a notification specifically for the flag-disabled case would require first implementing the pending changes UI indicator.

5. **The scenario is transient.** Flags will either be enabled (changes resolved) or the user will eventually log out (changes cleaned up). The orphaned state is not permanent.

**Blast radius:** Orphaned pending changes in Core Data:
- Occupy negligible storage (~1-5 KB per record)
- Do not affect app performance or behavior
- Contain the user's offline edit data, which could be resolved if flags are re-enabled
- Are cleaned up on user logout

**Likelihood:** This scenario occurs whenever:
- Flags default to `false` (the current default) and the user made offline edits before the flags were activated (not possible -- flags must be enabled for offline edits to be created)
- Flags were enabled, user made offline edits, then flags were disabled by the server (the intended kill-switch scenario)

The second scenario is the only realistic case, and it represents the deliberate use of the kill switch in a production emergency.

### Options for S8.a

#### Option A: Add Cleanup on Flag Disable (Cautious Approach)
- **Effort:** Medium (3-5 hours)
- **Description:** When the resolution flag is checked and found to be `false` in `SyncService.fetchSync()`, check if pending changes exist and log a warning. Optionally, provide a configuration option to auto-delete orphaned changes after a grace period (e.g., 30 days of the flag being disabled).
- **Pros:** Prevents indefinite orphaned records; provides observability
- **Cons:** Deleting pending changes permanently loses the user's offline edits; the grace period is arbitrary; adds complexity to the sync service; the records are harmless

#### Option B: Add Logging Only (Observability)
- **Effort:** Small (1 hour)
- **Description:** When `offlineSyncEnableResolution` is `false` in `SyncService.fetchSync()`, check pending change count and log a warning if > 0. This provides server-side telemetry about orphaned changes without changing behavior.
- **Pros:** Zero risk; provides insight into how many users have orphaned changes; helps inform future decisions
- **Cons:** Does not clean up the records; requires server-side log aggregation to be useful
- **Implementation:**
  ```swift
  if await configService.getFeatureFlag(.offlineSyncEnableResolution),
     !isVaultLocked {
      // ... existing resolution logic ...
  } else if !isVaultLocked {
      let orphanedCount = try? await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
      if let orphanedCount, orphanedCount > 0 {
          Logger.application.warning(
              "Offline sync resolution disabled; \(orphanedCount) pending changes remain orphaned"
          )
      }
  }
  ```

#### Option C: Accept As-Is
- **Rationale:** Orphaned pending changes are the deliberate and documented result of the kill-switch design. The records are small, harmless, and cleaned up on logout. The pending change data preserves the user's offline edits, which could be recovered if the flags are re-enabled. Deleting them preemptively would permanently lose that data, which is worse than leaving them. The flag disable scenario is inherently an emergency measure -- the team is prioritizing stability over offline sync, and the orphaned records are an acceptable trade-off. Adding cleanup logic for this emergency scenario adds complexity for minimal benefit.

### Recommendation for S8.a

**Option C: Accept As-Is**, with **Option B's logging** as a low-effort enhancement for observability. The orphaned records are intentional, harmless, and preserve user data. The only action worth taking is adding a log warning for telemetry purposes, which helps the team understand the impact when flags are disabled in production.

### Resolution for S8.a

**Resolved as design decision (2026-02-20).** The two-flag architecture provides maximum operational flexibility for handling the orphaned-changes scenario:

| Flag Configuration | Behavior | Orphaned Changes |
|---|---|---|
| Both enabled | Full offline sync active | N/A — changes are created and resolved normally |
| `offlineSyncEnableOfflineChanges` = `false`, resolution = `true` | No new offline saves; existing queue drains on next sync | Resolved automatically — this is the graceful wind-down path |
| `offlineSyncEnableResolution` = `false` (either flag state for changes) | Full kill switch — no new saves, no resolution | Pending changes remain in Core Data, preserved for re-enablement |
| Both disabled | Same as above | Same as above |

The "graceful wind-down" path (row 2) directly addresses S8.a's concern: the team can stop new offline saves from accumulating while allowing existing pending changes to resolve. This was not possible with a single flag and represents the maximum flexibility design.

For the full kill-switch scenario (row 3), orphaned records are:
- **Intentional**: The safer default is preserving user data over deleting it
- **Harmless**: ~1-5 KB per record, no performance impact
- **Recoverable**: Re-enabling the flag processes them on next sync
- **Bounded**: No new changes accumulate while flags are off
- **Cleaned on logout**: `DataStore.deleteDataForUser` removes them

The optional logging enhancement (Option B) remains a reasonable future improvement for production telemetry but is not required for correctness.

### Dependencies for S8.a

- **AP-U3_NoPendingChangesIndicator.md** (Issue U3): A pending changes UI indicator would make orphaned changes visible to users. Without it, users have no awareness of orphaned changes regardless of flag state.
- **AP-R2-MAIN-7** (Issue #43): If a maximum pending change count is implemented, it would also limit the number of orphaned records.
