# AP-80: AuthCoordinator Parameter Rename Is Compile-Affecting Upstream Change in Offline Sync Diff

> **Issue:** #80 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/09_UpstreamChanges_Review.md

## Problem Statement

The `AuthCoordinator.swift` file includes a parameter rename from `attemptAutmaticBiometricUnlock` (typo: missing the second 'o' in "Automatic") to `attemptAutomaticBiometricUnlock`. Unlike most other typo fixes in the diff, this is a **compile-affecting change** because it renames a function parameter that is referenced across multiple files. The change was part of the upstream spell-check initiative (`[PM-27525] Add spell check git pre-commit hook (#2319)`) but is mixed into the offline sync diff.

The concern is that this compile-affecting rename could be confused with an offline sync change during review, and that its presence in the diff complicates understanding the scope of the offline sync feature.

## Current State

**The rename is fully applied across all files.** A codebase-wide search for the old typo `attemptAutmaticBiometricUnlock` returns zero results in source code (only references remain in documentation files under `_OfflineSyncDocs/`).

The corrected parameter name `attemptAutomaticBiometricUnlock` appears in the following files:

- **Definition sites:**
  - `BitwardenShared/UI/Auth/AuthRoute.swift:175,182` -- enum case parameter definition
  - `BitwardenShared/UI/Auth/AuthEvent.swift:11,18,36,43` -- event enum parameter definitions
  - `BitwardenShared/UI/Auth/AuthCoordinator.swift:241,247,819,825,834` -- coordinator routing and `showVaultUnlock` method

- **Call sites (production):**
  - `BitwardenShared/UI/Auth/AuthRouter.swift:50,56,68,78,85` -- router handling
  - `BitwardenShared/UI/Auth/Extensions/AuthRouter+Redirects.swift` -- 14 references across redirect logic
  - `BitwardenShared/UI/Auth/Login/SingleSignOn/SingleSignOnProcessor.swift:229`
  - `BitwardenShared/UI/Auth/Login/TwoFactorAuth/TwoFactorAuthProcessor.swift:243`
  - `BitwardenShared/UI/Auth/Login/LoginDecryptionOptions/LoginDecryptionOptionsProcessor.swift:91`

- **Test sites:**
  - `BitwardenShared/UI/Auth/AuthCoordinatorTests.swift:629,646`
  - `BitwardenShared/UI/Auth/AuthRouterTests.swift` -- 30+ references
  - `BitwardenShared/UI/Auth/Login/SingleSignOn/SingleSignOnProcessorTests.swift:326`
  - `BitwardenShared/UI/Auth/Login/TwoFactorAuth/TwoFactorAuthProcessorTests.swift:562`
  - `BitwardenShared/UI/Auth/Login/LoginDecryptionOptions/LoginDecryptionOptionsProcessorTests.swift:75`

The rename is consistent -- every occurrence uses the corrected spelling `attemptAutomaticBiometricUnlock`. The code compiles successfully.

## Assessment

**This issue is valid as a process observation but requires no action.** The rename:

1. **Is compile-affecting** -- it changed a parameter name across ~50+ call sites in both production and test code. If partially applied, it would cause compilation failures.
2. **Is fully and consistently applied** -- zero instances of the old typo remain in source code.
3. **Has no functional impact** -- the behavior is identical; only the spelling of the parameter label changed.
4. **Does not interact with offline sync** -- the `AuthCoordinator` routing logic for vault unlock is unrelated to offline cipher sync. The parameter controls biometric unlock behavior, not network/sync behavior.
5. **Was part of the upstream spell-check hook** -- this is one of approximately 20 typo fixes from the same upstream initiative.

The compile-affecting nature makes this slightly more notable than comment-only typo fixes, but the change is fully applied and tested.

## Options

### Option A: Accept As-Is (Recommended)
- **Effort:** None
- **Description:** Accept the current state. The rename is complete, consistent, and has no interaction with offline sync functionality.
- **Pros:** No effort; no risk; the spelling correction is beneficial.
- **Cons:** The compile-affecting rename remains in the offline sync diff.

### Option B: Note in PR Description
- **Effort:** 5 minutes
- **Description:** Call out the `attemptAutomaticBiometricUnlock` rename explicitly in the PR description as a compile-affecting upstream change (not offline sync).
- **Pros:** Prevents PR reviewers from spending time analyzing it as a feature change.
- **Cons:** Minimal benefit if reviewers reference the upstream changes documentation.

### Option C: Extract Into Separate Commit via Rebase
- **Effort:** 1-2 hours (high risk)
- **Description:** Interactive rebase to isolate the parameter rename into its own commit, touching approximately 15+ files.
- **Pros:** Clean commit history; clear separation between upstream and feature changes.
- **Cons:** Very high risk -- the rename touches ~15 files, many of which also have offline sync or other changes. Rebase conflicts are likely and resolution would be error-prone.

## Recommendation

**Option A: Accept As-Is.** The parameter rename is fully applied, compiles correctly, and has no interaction with offline sync. It is one of many upstream spelling corrections that naturally landed in the feature branch during development. The review documentation in Review2/09_UpstreamChanges_Review.md already explicitly calls out this specific change and its compile-affecting nature (line 25, line 33). Attempting to extract it would risk destabilizing the branch for zero functional benefit.

## Dependencies

- Related to Issue #58 (R2-UP-4): The broader concern about upstream changes complicating the offline sync diff. This is one specific instance of that pattern.
- Related to Issue #59 (R2-UP-5) and Issue #79 (R2-DI-6): Similar instances of upstream typo fixes mixed into offline sync commits.
