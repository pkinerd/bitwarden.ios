---
id: 76
title: "[U4] English-only conflict folder name"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** Conflict folder removed entirely.

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Superseded/AP-U4_EnglishOnlyConflictFolderName.md`*

## Status: SUPERSEDED

> **The dedicated "Offline Sync Conflicts" folder has been removed entirely.** Backup ciphers now retain the original cipher's folder assignment. This eliminates the English-only folder name concern, the folder creation logic, the `FolderService` dependency, and the `conflictFolderId` cache. This action plan is no longer applicable.
>
> The backup cipher name format has also been simplified from `"{name} - offline conflict {timestamp}"` to `"{name} - {timestamp}"`.

---

## ~~Issue Summary~~

| Field | Value |
|-------|-------|
| **ID** | U4 / RES-8 |
| **Component** | ~~`DefaultOfflineSyncResolver`~~ |
| **Severity** | ~~Informational~~ **Superseded** |
| **Type** | ~~Localization / UX~~ |
| **File** | ~~`BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift`~~ |

## ~~Description~~

~~The conflict folder name "Offline Sync Conflicts" is hardcoded in English, not localized. Non-English users will see an English folder name in their vault. The backup cipher name format "{name} - offline conflict {timestamp}" is also English-only.~~

**[Superseded]** The conflict folder has been removed. Backup ciphers retain their original folder assignment.

## Context

Localization of the folder name is complex because:
1. The encrypted folder name syncs to the server and to all devices
2. Different devices may have different locale settings
3. Searching for an existing folder by name requires decrypting all folders — if the name varies by locale, the search may not find a previously-created folder from a device with a different locale
4. The "Offline Sync Conflicts" folder is created automatically, not by the user

---

## Options

### Option A: Localize the Folder Name

Use the app's localization system (`NSLocalizedString` or equivalent) for both the folder name and backup cipher name prefix.

**Approach:**
1. Add "Offline Sync Conflicts" and "offline conflict" to the localization strings files
2. Use `Localizations.offlineSyncConflicts` (or equivalent) in the resolver
3. When searching for existing folder, search across all known localizations of the name

**Pros:**
- Better UX for non-English users
- Follows app localization standards

**Cons:**
- Cross-device inconsistency: a folder created on an English device won't be found by a French device
- Would result in multiple conflict folders (one per locale) if user has devices in different languages
- "Search across all localizations" is complex and fragile
- Localization strings would need to be maintained for all supported languages

### Option B: Use a Machine-Readable Folder Identifier

Instead of a human-readable name, use a hidden or machine-readable identifier for the conflict folder.

**Approach:**
- Store the conflict folder ID in `AppSettingsStore` or as a known constant
- Use the ID for lookup rather than decrypting and comparing names
- The folder's display name can still be localized

**Pros:**
- Eliminates the cross-device locale problem
- Faster lookup (no need to decrypt all folders)
- Display name can be localized independently

**Cons:**
- Stored folder ID can become stale (folder deleted, account switched)
- Need to handle the case where the stored ID refers to a deleted folder
- More complex than a simple name comparison
- New storage dependency

### Option C: Accept English-Only (Recommended)

Keep "Offline Sync Conflicts" as a fixed English string. The folder is a system-created artifact, and its name should be consistent across all devices and locales.

**Pros:**
- Simple and consistent
- No cross-device locale issues
- The folder name is descriptive enough for non-English speakers to understand
- System-created folders in many apps use English names (precedent from other platforms)
- No code change

**Cons:**
- Non-English users see an English folder name
- Doesn't follow app localization standards
- May generate accessibility/localization bug reports

---

## Recommendation

**Option C** — Accept English-only for the initial release. The cross-device consistency benefit outweighs the localization concern. If localization is required in the future, **Option B** (machine-readable ID with localized display) is the correct approach, not Option A.

## Estimated Impact

- **Files changed:** 0
- **Risk:** None

## Related Issues

- **RES-7**: Backup ciphers lack attachments — both relate to the properties of backup/conflict artifacts.
- **CS-2**: Fragile SDK copy methods — the backup cipher naming is done in the `update(name:folderId:)` method which is fragile.

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

**Superseded status verified** (2026-02-18): The code references in the original review findings below are now historical — none of this code exists in the current codebase.

1. ~~**Code verification**: `OfflineSyncResolver.swift:340` hardcodes `let folderName = "Offline Sync Conflicts"`.~~ **Confirmed removed.** No references to "Offline Sync Conflicts", `conflictFolderId`, or `getOrCreateConflictFolder` exist anywhere in `OfflineSyncResolver.swift` or the broader codebase.

2. **Current backup behavior** (verified in `OfflineSyncResolver.swift:337`): The backup cipher name format is now `"\(decryptedCipher.name) - \(timestampString)"` — the "offline conflict" text has been removed as noted in the superseded header. The `createBackupCipher` method (lines 325-348) uses `decryptedCipher.update(name: backupName)` which retains the original cipher's `folderId` (confirmed in `CipherView+OfflineSync.swift:34-41` — `update(name:)` copies `folderId` from the receiver).

3. **No folder logic remains**: The `FolderService` is not used by `OfflineSyncResolver`. There is no folder creation, no folder name comparison, no `conflictFolderId` cache. The superseded status is fully confirmed.

**Updated conclusion** (2026-02-18): This action plan remains correctly marked as SUPERSEDED. All the code it originally described has been removed. No action needed.

## Resolution Details

Conflict folder removed entirely; backup ciphers retain original folder. English-only name no longer applicable.

## Comments
