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
