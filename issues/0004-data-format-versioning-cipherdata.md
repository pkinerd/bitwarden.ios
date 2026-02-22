---
id: 4
title: "[R1] No data format versioning for cipherData JSON"
status: open
created: 2026-02-21
author: claude
labels: [bug]
priority: high
---

## Description

If `CipherDetailsResponseModel` changes in a future app update, old pending records fail to decode permanently, blocking sync.

**Severity:** Medium
**Complexity:** Low
**Est. Effort:** ~15-20 lines, 2-3 files, Core Data schema change

**Recommendation:** Add `dataVersion` attribute to Core Data entity (use Integer 64 per current schema conventions from `1bc17cb`). Deprioritize if R3 is implemented (R3 provides more general stuck-item solution). Bundle schema change with R3.

**Related Documents:** AP-R1, AP-00, OfflineSyncCodeReview.md, ReviewSection_PendingCipherChangeDataStore.md, Review2/02_OfflineSyncResolver

## Action Plan

*Source: `ActionPlans/AP-R1_DataFormatVersioning.md`*

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | R1 / PCDS-3 |
| **Component** | `PendingCipherChangeData` |
| **Severity** | Low |
| **Type** | Reliability |
| **File** | `BitwardenShared/Core/Vault/Models/Data/PendingCipherChangeData.swift` |

## Description

The `cipherData` field in `PendingCipherChangeData` stores `CipherDetailsResponseModel` as JSON-encoded `Data`. If this model changes in a future app update (added/removed/renamed fields), old pending records could fail to decode. The `JSONDecoder` will throw on missing required fields, causing the pending change resolution to fail for that item (it would be retried indefinitely on each sync).

## Context

The risk is limited by the short-lived nature of pending changes — they are resolved on the next successful sync after connectivity is restored. The scenario requires:
1. User makes offline edits
2. User stays offline long enough to receive an app update
3. The app update changes `CipherDetailsResponseModel` in an incompatible way
4. User regains connectivity after the update

This is a low-probability scenario, but it would result in permanently unresolvable pending changes.

---

## Options

### Option A: Add a Version Field to `PendingCipherChangeData` (Recommended)

Add a `dataVersion: Int16` attribute to the Core Data entity, set to `1` for the current format. If the model changes, bump the version and add migration logic or cleanup logic for old-format records.

**Approach:**
1. Add `dataVersion` attribute to `PendingCipherChangeData` entity (default value: 1)
2. Add `@NSManaged var dataVersion: Int16` to the Swift class
3. Set `dataVersion = 1` in the convenience init and upsert
4. In `OfflineSyncResolver`, before decoding `cipherData`, check the version. If it's an unsupported version, log a warning and delete the pending record (the data can't be resolved with the current code)

**Pros:**
- Explicitly tracks the format version
- Enables graceful handling of version mismatches in the future
- Small upfront cost

**Cons:**
- Core Data schema change — requires awareness of model versioning implications
- Until a format change actually occurs, the version field is unused overhead
- YAGNI argument: may never be needed if the model doesn't change

### Option B: Use Lenient JSON Decoding

Configure the `JSONDecoder` with lenient settings (or wrap the decode in a try/catch with a fallback) so that missing fields default to nil/zero rather than throwing.

**Approach:**
- When decoding `cipherData`, catch decode errors specifically
- On decode failure, log the error and delete the pending record (data is unrecoverable)
- Optionally, use a custom decoder that provides defaults for missing keys

**Pros:**
- No schema change
- Handles format mismatches gracefully (failed decode → delete pending record)
- Simple implementation

**Cons:**
- Lenient decoding may hide genuine data corruption
- Deleting the pending record means losing the user's offline changes
- Custom decoding is fragile and adds maintenance overhead

### Option C: Add an Expiry/TTL to Pending Changes

Instead of versioning, add a maximum age for pending changes. If a pending change is older than a threshold (e.g., 30 days), delete it on the assumption that it's stale.

**Approach:**
- In `OfflineSyncResolver.processPendingChanges`, check `createdDate` age
- If older than threshold, log and delete
- This naturally handles both format versioning and permanently-stuck records

**Pros:**
- Solves both versioning and retry-backoff (R3) issues
- Simple time-based logic
- No schema change needed (uses existing `createdDate`)

**Cons:**
- Deletes user data that may still be valid (just old)
- User who was offline for 31 days loses their changes
- Arbitrary threshold — hard to choose the right value
- Does not actually solve the format mismatch problem (a 1-day-old record with an old format still fails)

### Option D: Accept the Risk (No Change)

Accept the low probability of this scenario and handle it if it arises.

**Pros:**
- No code change
- YAGNI — the scenario is unlikely
- If it occurs, the worst case is that the pending change retries indefinitely (not data loss — the local cipher data is still in the regular `CipherData` store)

**Cons:**
- Permanently unresolvable pending changes could block sync (early-abort pattern prevents sync)
- Requires manual intervention if it occurs

---

## Recommendation

**Option A** — Add a version field. The cost is minimal (one Core Data attribute), and it provides a clean migration path if the format ever changes. The alternative (Option D) risks permanently blocked syncs in an edge case.

## Estimated Impact

- **Files changed:** 2-3 (`PendingCipherChangeData.swift`, Core Data model, `OfflineSyncResolver.swift`)
- **Lines added:** ~15-20
- **Risk:** Low — Core Data schema addition (lightweight migration handles new attributes)

## Related Issues

- **R3 (SS-5)**: Retry backoff — if retry backoff/expiry is implemented (Option C there), it also addresses permanently stuck records from format mismatches.
- **PCDS-1**: id optional/required mismatch — both relate to Core Data schema considerations.
- **PCDS-2**: dates optional/always-set — same category of "schema attributes could be more precisely typed."

## Updated Review Findings

The review provides additional context from the code analysis:

1. **Code verification**: `PendingCipherChangeData.swift:43` declares `@NSManaged var cipherData: Data?` which stores JSON-encoded `CipherDetailsResponseModel`. The encode happens in VaultRepository's offline handlers (e.g., `VaultRepository.swift:1014-1015`): `let cipherResponseModel = try CipherDetailsResponseModel(cipher: encryptedCipher); let cipherData = try JSONEncoder().encode(cipherResponseModel)`. The decode happens in `OfflineSyncResolver.swift:156`: `let responseModel = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: cipherData)`.

2. **Decoder behavior**: Swift's `JSONDecoder` with default settings fails on missing required keys. `CipherDetailsResponseModel` likely uses standard Codable synthesis, meaning new required fields would break decoding. New optional fields with defaults would be decoded to their default values (safe). Removed fields would cause decode failures.

3. **Impact of decode failure**: If `JSONDecoder().decode()` throws in `resolveCreate` (line 156), `resolveUpdate` (line 185), or `resolveSoftDelete` (line 306), the error propagates through `resolve()` and is caught by the per-item catch at `processPendingChanges` line 113-117. The pending record is NOT deleted. On every subsequent sync, this decode failure repeats - creating a permanently stuck item that blocks sync via the early-abort pattern.

4. **R3 interaction confirmed**: If R3 (retry backoff / TTL) is implemented, permanently stuck items from format mismatches would eventually be expired. This provides a complementary safety mechanism. The R3 TTL approach addresses both the R1 format versioning concern AND the general "permanently stuck item" problem.

5. **Schema change consideration**: Adding a `dataVersion: Int16` attribute to the Core Data entity requires lightweight migration. Core Data handles new attributes automatically (they get default values). This is the same migration mechanism used when the entity was first added.

6. **Recommendation refinement**: Given the interaction with R3, the priority depends on whether R3 is implemented:
   - **If R3 (TTL) is implemented**: R1 becomes lower priority - stuck items expire naturally
   - **If R3 is NOT implemented**: R1 provides the only graceful degradation path for format mismatches

**Updated conclusion**: Original recommendation (Option A - add version field) remains reasonable but **should be deprioritized in favor of R3 (TTL/retry backoff)** which provides a more general solution. If R3 is implemented with TTL-based expiry, R1 becomes optional defense-in-depth. If R3 is deferred, R1 should be implemented. Priority adjusted: Low (implement if R3 is deferred).

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 1: Open Issues Requiring Code Changes*

If `CipherDetailsResponseModel` changes in a future app update, old pending records fail to decode permanently, blocking sync. **Recommended:** Add `dataVersion` attribute to Core Data entity (use Integer 64 per current schema conventions from `1bc17cb`). Deprioritize if R3 is implemented (R3 provides more general stuck-item solution). Bundle schema change with R3.

## Code Review References

Relevant review documents:
- `ReviewSection_PendingCipherChangeDataStore.md`

## Comments

### claude — 2026-02-22

**Codebase validated — issue confirmed OPEN.**

1. PendingCipherChangeData.swift has NO `dataVersion` attribute
2. Core Data model (Bitwarden.xcdatamodel) has no dataVersion field
3. OfflineSyncResolver decodes cipherData with no version checking logic
4. Zero matches for "dataVersion" across entire codebase

If `CipherDetailsResponseModel` changes incompatibly, old pending records will fail to decode permanently.
