# AP-66: `specificPeopleUnavailable(action:)` Alert Is Upstream Change Mixed Into Offline Sync Files

> **Issue:** #66 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/06_UILayer_Review.md

## Problem Statement

The `Alert+Vault.swift` file contains a new `specificPeopleUnavailable(action:)` static method that adds a premium subscription alert for the "Specific People" Send feature. This alert is unrelated to offline sync — it is an upstream feature change that happens to appear in the same file diff because `Alert+Vault.swift` was also modified in the offline sync branch.

The alert is used by `AddEditSendItemProcessor` for the Send feature's "Specific People" access type, which requires premium. It follows the established `Alert` factory pattern used throughout the codebase (e.g., `archiveUnavailable(action:)`).

## Current Code

- `BitwardenShared/UI/Vault/Extensions/Alert+Vault.swift:38-49`
```swift
static func specificPeopleUnavailable(
    action: @escaping () -> Void,
) -> Alert {
    Alert(
        title: Localizations.premiumSubscriptionRequired,
        message: Localizations.sharingWithSpecificPeopleIsPremiumFeatureDescriptionLong,
        alertActions: [
            AlertAction(title: Localizations.upgradeToPremium, style: .default) { _, _ in action() },
            AlertAction(title: Localizations.cancel, style: .cancel),
        ],
    )
}
```

- Consumer: `BitwardenShared/UI/Tools/Send/SendItem/AddEditSendItem/AddEditSendItemProcessor.swift`
- Tests: `BitwardenShared/UI/Vault/Extensions/AlertVaultTests.swift`

## Assessment

**Still valid; purely a code review cleanliness observation.** This is not a bug or a risk — it is a note that the offline sync diff contains changes unrelated to offline sync. The review correctly identified this as an upstream change mixed into the same files.

**Actual impact:** None. The alert is functionally correct and properly tested. It has no interaction with offline sync code. The only concern is that it makes the offline sync diff slightly harder to review by introducing unrelated changes.

**Hidden risks:** None. The alert follows established patterns and is properly tested.

## Options

### Option A: Accept As-Is (Recommended)
- **Rationale:** This is a valid upstream change that happened to land in the same branch. Attempting to separate it (e.g., cherry-picking or rebasing) would be more effort than the cleanliness benefit warrants. The alert is properly implemented, tested, and follows established patterns. The review has already documented it as an upstream change, which is sufficient for future reference.

### Option B: Document in Commit Message
- **Effort:** Low (~5 minutes)
- **Description:** If the offline sync branch is rebased or squashed before merge, ensure the commit message or PR description notes that `specificPeopleUnavailable` in `Alert+Vault.swift` is an upstream change, not an offline sync change.
- **Pros:** Helps future reviewers understand the change provenance
- **Cons:** Minimal value if the branch has already been reviewed

## Recommendation

**Option A: Accept As-Is.** The upstream change is properly implemented, tested, and documented in the review. No action needed beyond acknowledging it as a non-offline-sync change in the review documentation, which has already been done.

## Dependencies

- None. This is independent of all offline sync issues.
