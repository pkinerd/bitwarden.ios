# Action Plan: T5 (RES-6) — Inline Mock `MockCipherAPIServiceForOfflineSync` is Fragile

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | T5 / RES-6 |
| **Component** | `OfflineSyncResolverTests` |
| **Severity** | Low |
| **Type** | Test Maintenance |
| **File** | `BitwardenShared/Core/Vault/Services/OfflineSyncResolverTests.swift` |

## Description

The test file defines an inline `MockCipherAPIServiceForOfflineSync` that implements the full `CipherAPIService` protocol with `fatalError()` stubs for 15+ unused methods. Only `getCipher(withId:)` is actually implemented for the tests. Any change to the `CipherAPIService` protocol (adding/removing/renaming methods) will require updating this inline mock at compile time.

## Context

**Codebase findings:**
- **No project-level `MockCipherAPIService` exists.** A search across the entire `BitwardenShared` target confirms the only mock is the inline `MockCipherAPIServiceForOfflineSync` in the test file.
- **`CipherAPIService` is NOT annotated with `// sourcery: AutoMockable`.** The protocol is defined at `BitwardenShared/Core/Vault/Services/API/Cipher/CipherAPIService.swift:18`.
- **The project uses Sourcery `@AutoMockable` for mock generation** (template at `Sourcery/Templates/AutoMockable.stencil`), but `CipherAPIService` is not included.
- The inline mock only implements `getCipher(withId:)`. All 15+ other methods use `fatalError()` stubs. If S3/S4 batch and failure tests are added, the mock will need additional configurable methods (e.g., throwing behavior for specific calls).

---

## Options

### Option A: Add `AutoMockable` Annotation to `CipherAPIService` (Recommended)

Annotate `CipherAPIService` with `// sourcery: AutoMockable` to auto-generate a project-level mock via Sourcery.

**Approach:**
1. Add `// sourcery: AutoMockable` above `protocol CipherAPIService` in `CipherAPIService.swift:17`
2. Run Sourcery to regenerate mocks
3. Replace the inline `MockCipherAPIServiceForOfflineSync` with the generated `MockCipherAPIService`
4. Configure only `getCipherResult` for resolver tests

**Pros:**
- Eliminates the inline mock entirely
- Auto-generated mock updates automatically when the protocol changes
- Follows the established project pattern for Sourcery-based mocks
- Reusable across all future tests that need `CipherAPIService`
- Zero ongoing maintenance

**Cons:**
- Auto-generated mock may not crash on unexpected calls (returns defaults instead of `fatalError()`)
- Generated mock file adds to the Sourcery output size
- Need to verify Sourcery is configured and running in the build pipeline

### Option B: Create a Manual Project-Level `MockCipherAPIService`

Create a hand-written mock in the standard test helpers location.

**Approach:**
1. Create `MockCipherAPIService.swift` in `BitwardenShared/Core/Vault/Services/API/Cipher/TestHelpers/`
2. Implement all protocol methods with configurable `Result` properties
3. Replace the inline mock in the resolver tests

**Pros:**
- Full control over mock behavior (can use `fatalError()` for unused methods)
- No Sourcery dependency
- Follows the pattern of `MockPendingCipherChangeDataStore`

**Cons:**
- Creating a full mock for a 15+ method protocol is significant manual work
- Must be manually updated when the protocol changes

### Option C: Keep Inline Mock with Maintenance Comment

Keep the inline mock but add a clear comment about the maintenance requirement.

**Pros:**
- No change needed
- The `fatalError()` stubs are explicit about what's unused
- Compiler will flag protocol changes immediately

**Cons:**
- Maintenance burden remains
- Each protocol change requires editing the test file
- If S3/S4 tests are added, the mock grows in complexity

---

## Recommendation

**Option A** — Add `AutoMockable` annotation to `CipherAPIService`. Since no project-level mock exists and the project already uses Sourcery for mock generation, this is the lowest-effort, most maintainable approach. The generated mock will auto-update when the protocol changes, eliminating the maintenance burden entirely. If Sourcery is not convenient to run, **Option C** (keep inline mock with comment) is acceptable as the compiler enforces protocol conformance at build time.

## Estimated Impact

- **Files changed:** 1 (`OfflineSyncResolverTests.swift`), possibly 1 new file if creating a project-level mock
- **Lines changed:** Depends on option chosen
- **Risk:** Very low — test-only changes

## Related Issues

- **S3 (RES-3)**: Batch processing tests — new tests will also use this mock, increasing the dependency on it.
- **S4 (RES-4)**: API failure tests — these tests need the mock to throw errors, adding more configuration.
- **CS-2**: Fragile SDK copy methods — same class of problem (manual conformance to changing external types).

## Updated Review Findings

The review confirms the original assessment with additional detail. After reviewing the implementation:

1. **Inline mock verification**: `OfflineSyncResolverTests.swift:11-62` defines `MockCipherAPIServiceForOfflineSync` with:
   - `getCipherResult` and `getCipherCalledWith` for the one implemented method
   - 15 `fatalError()` stubs for unused methods (lines 22-61)
   - The stubs cover: `addCipher`, `archiveCipher`, `addCipherWithCollections`, `bulkShareCiphers`, `deleteAttachment`, `deleteCipher`, `downloadAttachment`, `downloadAttachmentData`, `restoreCipher`, `saveAttachment`, `shareCipher`, `softDeleteCipher`, `unarchiveCipher`, `updateCipher`, `updateCipherCollections`, `updateCipherPreference`

2. **AutoMockable assessment**: The project uses Sourcery for mock generation (`Sourcery/Templates/AutoMockable.stencil`). `CipherAPIService` at its protocol definition does NOT have the `// sourcery: AutoMockable` annotation. Adding it would auto-generate a complete mock.

3. **Impact of S3/S4 on this issue**: If S3 (batch tests) and S4 (API failure tests) are implemented, the inline mock would need additional configurable properties beyond `getCipherResult`. For example, failure tests need the mock to support tracking and failing `addCipher` and `updateCipher` calls. However, these API calls go through `MockCipherService` (not the API mock) in the current test architecture - the resolver calls `cipherService.addCipherWithServer()` and `cipherService.updateCipherWithServer()`, which are mocked via `MockCipherService`. The `CipherAPIService` mock is only used for `getCipher(withId:)` (server state fetch).

4. **Key insight**: The inline mock's 15 `fatalError()` stubs are the maintenance burden, not functional limitation. The resolver only uses `getCipher(withId:)` from `CipherAPIService`. All other cipher operations go through `CipherService`. So the mock only needs this one method, but protocol conformance requires implementing everything.

5. **Recommendation refinement**: **Option A (AutoMockable)** is ideal for long-term maintainability. **Option C (keep with comment)** is acceptable for the short term since the compiler enforces protocol conformance and `fatalError()` stubs catch unexpected calls. The choice depends on whether Sourcery mock generation is convenient to run in the build pipeline.

**Updated conclusion**: Original recommendation (Option A - AutoMockable annotation) confirmed as the ideal approach. If Sourcery integration is not convenient to set up, Option C (keep inline mock with maintenance comment) is acceptable. The functional impact is limited since only `getCipher` is used by the resolver. Priority: Low.
