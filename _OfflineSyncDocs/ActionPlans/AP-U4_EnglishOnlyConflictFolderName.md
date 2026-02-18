# Action Plan: U4 (RES-8) — ~~English-Only Conflict Folder Name~~ **SUPERSEDED**

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

1. **Code verification**: `OfflineSyncResolver.swift:340` hardcodes `let folderName = "Offline Sync Conflicts"`. The folder search at lines 343-349 decrypts ALL folders and compares names using `==`. The backup cipher name format at line 314: `"\(decryptedCipher.name) - offline conflict \(timestampString)"`.

2. **Cross-device scenario analysis**: Bitwarden syncs folders across all devices. If the folder name were localized:
   - English device creates folder "Offline Sync Conflicts"
   - French device looks for "Conflits de synchronisation hors ligne" — doesn't find it — creates another folder
   - User now has 2 conflict folders on different devices
   - This is a worse UX than a single English folder

3. **Platform consistency**: Other Bitwarden clients (Android, desktop, web) would need the same folder name for cross-platform consistency. Using a fixed English name ensures all platforms find the same folder.

4. **Folder decryption overhead**: `getOrCreateConflictFolder` (lines 334-359) decrypts all folders to find the conflict folder by name. This O(n) scan is mitigated by the `conflictFolderId` cache at line 86. The cache is reset per batch (line 126) and populated on first access. For users with many folders, this single-per-batch decryption is acceptable.

**Updated conclusion**: Original recommendation (Option C - accept English-only) confirmed. Cross-device and cross-platform consistency is the deciding factor. Localization would create multiple folders per locale, which is worse UX than a single English folder. Priority: Informational, no change needed.
