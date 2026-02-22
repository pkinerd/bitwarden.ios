---
id: 29
title: "[R2-UP-1] SDK API changes — verified no interaction with offline sync"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

SDK API changes (`.authenticator` → `.vaultAuthenticator`, `emailHashes` removal) verified — no interaction with offline sync code.

**Disposition:** Resolved
**Action Plan:** AP-56 (Resolved)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Resolved/AP-56_SDKAPIChangesVerification.md`*

> **Issue:** #56 from ConsolidatedOutstandingIssues.md
> **Severity:** Medium | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/09_UpstreamChanges_Review.md

## Problem Statement

The upstream SDK update introduced two API-breaking changes: the rename of `.authenticator(` to `.vaultAuthenticator(` in `AutofillCredentialService.swift` (3 occurrences) and `VaultAutofillListProcessor.swift` (1 occurrence), and the removal of the `emailHashes` property from `SendResponseModel` and `BitwardenSdk+Tools.swift`. The concern is whether these SDK API changes could affect the offline sync cipher operations, which also interact with the SDK's cipher types for encryption, decryption, and serialization.

## Current State

**`.authenticator` to `.vaultAuthenticator` rename:**
- All 4 occurrences in the codebase have been updated to `.vaultAuthenticator(`:
  - `BitwardenShared/Core/Autofill/Services/AutofillCredentialService.swift:336`
  - `BitwardenShared/Core/Autofill/Services/AutofillCredentialService.swift:551`
  - `BitwardenShared/Core/Autofill/Services/AutofillCredentialService.swift:590`
  - `BitwardenShared/UI/Vault/Vault/AutofillList/VaultAutofillListProcessor.swift:677`
- No references to the old `.authenticator(` enum case remain.

**`emailHashes` removal:**
- `SendResponseModel.swift` at `BitwardenShared/Core/Tools/Models/Response/SendResponseModel.swift` does not contain `emailHashes` -- it has been fully removed.
- `BitwardenSdk+Tools.swift` at `BitwardenShared/Core/Tools/Extensions/BitwardenSdk+Tools.swift` does not reference `emailHashes` -- the property has been fully removed from the `SendResponseModel(send:)` initializer and the `BitwardenSdk.Send(sendResponseModel:)` initializer.
- No references to `emailHashes` exist anywhere in `BitwardenShared/`.

**Offline sync code:**
- `OfflineSyncResolver.swift` at `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift` does not reference `.authenticator`, `.vaultAuthenticator`, or `emailHashes`.
- The offline sync code operates exclusively on `Cipher` / `CipherDetailsResponseModel` / `CipherView` types, not on autofill credential types or Send types.
- The SDK calls in offline sync are limited to `clientService.vault().ciphers().decrypt(cipher:)` and `clientService.vault().ciphers().encrypt(cipherView:)` -- these are unaffected by the autofill or Send API changes.

## Assessment

**This issue is no longer valid.** Both SDK API changes have been fully applied across the codebase:
1. The `.vaultAuthenticator` rename affects only the Autofill domain (`AutofillCredentialService`, `VaultAutofillListProcessor`), which is entirely orthogonal to offline sync cipher operations.
2. The `emailHashes` removal affects only the Tools/Send domain (`SendResponseModel`, `BitwardenSdk+Tools`), which is also orthogonal to offline sync.
3. The offline sync code uses only cipher-specific SDK APIs (`decrypt`, `encrypt`, `Cipher`, `CipherView`), none of which were changed in this SDK update.

The code compiles successfully with these changes applied, confirming no interaction between the SDK API changes and offline sync.

## Options

### Option A: Close As Verified (Recommended)
- **Effort:** None
- **Description:** Mark this issue as resolved. The SDK API changes are fully applied and have no interaction with offline sync cipher operations.
- **Pros:** No unnecessary work; issue is already fully addressed by the upstream merge.
- **Cons:** None.

### Option B: Add Regression Test
- **Effort:** 1 hour
- **Description:** Add a test that explicitly verifies offline sync resolver operations complete successfully with the current SDK version, to catch future SDK breaking changes.
- **Pros:** Provides ongoing regression protection against SDK API changes.
- **Cons:** The existing `OfflineSyncResolverTests` already exercise the full cipher encrypt/decrypt/create/update pipeline, making an additional explicit SDK version test redundant.

### Option C: Accept As-Is
- **Rationale:** The changes are already applied and verified. The offline sync code paths are entirely separate from the affected SDK APIs.

## Recommendation

**Option A: Close As Verified.** The SDK API changes (`vaultAuthenticator` rename, `emailHashes` removal) are fully applied and do not affect any offline sync code paths. The offline sync resolver operates exclusively on cipher-related SDK APIs, which were not modified. No further action is needed.

## Dependencies

- None. This issue is independent of all other offline sync issues.

## Comments
