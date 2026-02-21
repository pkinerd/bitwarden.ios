# AP-71: Sync Resolution May Be Delayed Up to One Sync Interval (~30 min)

> **Issue:** #71 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Medium
> **Status:** Triaged
> **Source:** OfflineSyncPlan.md

## Problem Statement

The offline sync resolution is triggered by embedding it into the existing `fetchSync()` method in `SyncService`. This means resolution only occurs when a sync is triggered by one of the existing mechanisms:

1. **Periodic sync** (every ~30 minutes, controlled by `Constants.minimumSyncInterval`)
2. **Foreground sync** (when the app enters the foreground)
3. **Push notification sync** (when the server sends a sync notification)
4. **Manual pull-to-refresh** (user-initiated)

There is no dedicated connectivity monitor that triggers resolution immediately when the network becomes available. This means that after reconnection, resolution may be delayed up to 30 minutes (the periodic sync interval) if the user does not interact with the app.

## Current Code

- `BitwardenShared/Core/Vault/Services/SyncService.swift:325-351` — Resolution is embedded in `fetchSync()`
- The resolution block runs before the actual sync API call, ensuring pending changes are resolved before `replaceCiphers` overwrites local data.

Sync triggers:
- Periodic sync: Configured via `Constants.minimumSyncInterval` (typically 30 minutes)
- Foreground sync: Triggered by `applicationDidBecomeActive` in `AppProcessor`
- Push notification: Server-initiated sync via `NotificationService`
- Pull-to-refresh: User-initiated in vault list views

## Assessment

**Still valid; accepted as a deliberate tradeoff.** The OfflineSyncPlan.md explicitly documents this decision:

> "This approach leverages existing sync mechanisms rather than introducing a separate connectivity monitor. The tradeoff is that sync resolution may be delayed by up to one sync interval (~30 min) compared to an immediate connectivity-based trigger, but this is acceptable given that users can always trigger resolution via pull-to-refresh."

**Actual impact:** In practice, the delay is usually much shorter than 30 minutes:

1. **Foreground sync:** When the app enters the foreground after being in the background, a sync is triggered. Since the most common connectivity recovery scenario is the user opening the app after moving to a WiFi-connected area, foreground sync covers this case with near-zero delay.

2. **User interaction:** If the user navigates to the vault or pulls to refresh, a sync is triggered immediately.

3. **Push notifications:** If the server sends a push notification (e.g., because another device synced), a sync is triggered.

The 30-minute worst case only applies when: (a) the app is actively in the foreground, (b) the user is not interacting with the vault, and (c) no push notifications arrive. This is a narrow scenario.

**Benefits of the current approach:**
- No new `NWPathMonitor` or `Reachability` dependency
- No battery drain from continuous network monitoring
- No false-positive reconnection events (NWPathMonitor can be unreliable)
- Simpler architecture with fewer moving parts
- Resolution always happens in the context of a sync, ensuring consistent state

**Hidden risks:** If a user has critical pending changes (e.g., a changed master password stored in a cipher), the delay could be problematic. However, the user can always pull-to-refresh to trigger immediate resolution.

## Options

### Option A: Accept As-Is (Recommended)
- **Rationale:** The existing sync triggers provide adequate coverage for the common connectivity recovery scenarios. The 30-minute worst case is narrow and mitigated by foreground sync and pull-to-refresh. Adding a connectivity monitor would increase complexity, battery usage, and introduce new failure modes without proportionate benefit.

### Option B: Add `NWPathMonitor` Connectivity Trigger
- **Effort:** Medium-High (~4-8 hours)
- **Description:** Add a `NWPathMonitor` observer that triggers `fetchSync` when the network path transitions from unsatisfied to satisfied.
- **Pros:** Near-immediate resolution when connectivity is restored
- **Cons:** `NWPathMonitor` can fire false positives (e.g., switching between WiFi networks), requires careful lifecycle management, adds battery drain, introduces a new dependency, may trigger sync during captive portal states where the server is unreachable

### Option C: Reduce Periodic Sync Interval When Pending Changes Exist
- **Effort:** Medium (~2-4 hours)
- **Description:** When `pendingChangeCount > 0`, reduce the periodic sync interval from ~30 minutes to ~5 minutes. Reset to normal when all changes are resolved.
- **Pros:** Faster resolution without a connectivity monitor, respects existing sync architecture
- **Cons:** Increased API load during offline periods (more frequent failed sync attempts), increased battery usage, requires storing "has pending changes" state for the periodic timer to check

### Option D: Show Toast Suggesting Pull-to-Refresh
- **Effort:** Low (~1-2 hours)
- **Description:** After an offline save succeeds, show a brief toast or banner: "Changes saved locally. Pull to refresh when online to sync." This guides the user to trigger resolution manually.
- **Pros:** Zero additional background processing, educates the user, leverages existing pull-to-refresh
- **Cons:** Requires UI changes, may be dismissed or ignored by users

## Recommendation

**Option A: Accept As-Is.** The foreground sync trigger covers the most common connectivity recovery scenario (user opens app after moving to connected area). The 30-minute worst case is narrow and acceptable. Pull-to-refresh provides an immediate escape hatch. The benefits of simplicity outweigh the marginal improvement of faster automatic resolution.

**Option D** could be considered as a future UX enhancement (related to Issue U3 — pending changes indicator) but is not necessary for the current release.

## Dependencies

- Related to Issue U3 (pending changes indicator): A UI indicator for pending changes would naturally include guidance on triggering resolution.
- Related to Issue R3 (retry backoff): If retry backoff is implemented, the periodic sync interval becomes less relevant because the system will automatically space out resolution attempts.
