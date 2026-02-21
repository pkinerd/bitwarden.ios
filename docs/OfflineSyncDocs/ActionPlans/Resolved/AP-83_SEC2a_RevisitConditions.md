# AP-83: SEC-2.a — SEC-2 Resolution Should Be Revisited Under Specific Conditions

> **Issue:** #83 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Resolved (Accept as-is — none of the four revisit conditions are met; SEC-2 decision well-documented with prototype reference available if conditions change)
> **Source:** AP-SEC2 (in Resolved/) — `_OfflineSyncDocs/ActionPlans/Resolved/AP-SEC2_PasswordChangeCountEncryption.md`

## Problem Statement

Issue SEC-2 explored encrypting the `offlinePasswordChangeCount` field in `PendingCipherChangeData`. After a full AES-256-GCM prototype implementation across 4 commits, the team decided "Will Not Implement" based on a thorough comparative analysis. The plaintext `Int16` storage was accepted as consistent with the existing security model.

However, the SEC-2 resolution document (AP-SEC2) explicitly identifies four conditions under which this decision should be revisited:

1. **Full Core Data encryption at rest** is pursued (e.g., SQLCipher or `NSPersistentEncryptedStore`)
2. **The security model changes** to require encryption of all local metadata, not just vault content
3. **The count becomes persistent** (e.g., survives sync resolution) or carries more sensitive information
4. **A security audit** mandates field-level encryption regardless of the comparative analysis

This action plan serves as a tracking document for these revisit conditions.

## Reference Document

The full analysis, prototype details, and rationale are documented in:
`_OfflineSyncDocs/ActionPlans/Resolved/AP-SEC2_PasswordChangeCountEncryption.md`

Key findings from that document:
- The `offlinePasswordChangeCount` is **low sensitivity** (reveals "how many times," not "what to")
- It is **ephemeral** (deleted on sync resolution)
- It is **consistent** with other unencrypted metadata across the codebase (UserDefaults, Keychain, Core Data)
- The **actual sensitive data** (passwords) is already encrypted by the Bitwarden SDK
- Encrypting this single field while surrounding metadata remains plaintext would be **security theater**

## Current Code

- `BitwardenShared/Core/Vault/Models/Data/PendingCipherChangeData.swift` — `offlinePasswordChangeCount: Int16` stored as plaintext
- `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift:60` — `softConflictPasswordChangeThreshold` reads this value
- `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift:1079-1097` — `handleOfflineUpdate` writes this value

## Assessment

**Still valid as a tracking note.** The four revisit conditions remain relevant:

1. **Full Core Data encryption at rest:** No current plans to adopt SQLCipher or database-level encryption. If this changes, ALL metadata fields (not just `offlinePasswordChangeCount`) should be included, making per-field encryption unnecessary.

2. **Security model change:** The current security model accepts plaintext metadata (IDs, timestamps, operation types) throughout the codebase. If a future security review mandates encrypting all metadata, this field would be part of that broader initiative.

3. **Count becomes persistent:** The count is currently ephemeral — it is deleted when pending changes are resolved (typically seconds to minutes after going online). If the design changes to retain the count beyond resolution, the risk assessment should be revisited.

4. **Security audit mandate:** If an external security audit specifically flags this field, the prototype implementation (documented in AP-SEC2) provides a ready reference for AES-256-GCM encryption via CryptoKit with HKDF key derivation.

**Current status of conditions:**
- Condition 1: Not met (no database-level encryption initiative)
- Condition 2: Not met (no security model change)
- Condition 3: Not met (count remains ephemeral)
- Condition 4: Not met (no audit mandate)

**Hidden risks:** None. The decision is well-documented with a clear set of revisit triggers.

## Options

### Option A: Accept As-Is (Recommended)
- **Rationale:** None of the four revisit conditions are currently met. The SEC-2 resolution is well-documented and the prototype provides a ready implementation reference if conditions change. No action is needed at this time.

### Option B: Proactively Implement Encryption
- **Effort:** Medium (~4-8 hours, reference prototype in AP-SEC2)
- **Description:** Implement AES-256-GCM encryption of the count using the prototype from SEC-2.
- **Pros:** Preemptive security hardening
- **Cons:** Adds complexity without meaningful security benefit (per the comparative analysis), introduces new key management and failure modes, inconsistent with the treatment of other metadata fields

## Recommendation

**Option A: Accept As-Is.** The SEC-2 resolution is sound and well-documented. The revisit conditions provide clear triggers for reconsideration. No action needed until one of the four conditions is met. This action plan serves as the tracking document.

## Resolution

**Resolved as accepted design (2026-02-20).** All four revisit conditions remain unmet:

| Condition | Status |
|---|---|
| Full Core Data encryption at rest (SQLCipher/`NSPersistentEncryptedStore`) | Not planned |
| Security model change mandating all metadata encryption | No change |
| Count becomes persistent beyond sync resolution | Remains ephemeral |
| Security audit mandates field-level encryption | No audit mandate |

The SEC-2 decision is well-documented with a full AES-256-GCM prototype reference in `AP-SEC2` if conditions change in the future. The `offlinePasswordChangeCount` remains low-sensitivity, ephemeral metadata consistent with other unencrypted metadata throughout the codebase.

## Dependencies

- **AP-SEC2** (Resolved): Full analysis and prototype implementation reference
- **AP-81** (Issue #81): Core Data file protection — related security posture discussion
- **Issue R2-PCDS-1** (Issue #48): Core Data schema versioning — if encryption is added, the schema change (`Integer 16` to `Binary`) should follow migration best practices
