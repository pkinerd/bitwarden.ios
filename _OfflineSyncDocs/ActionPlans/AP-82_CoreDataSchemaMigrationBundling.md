# AP-82: Core Data Schema Changes Should Be Bundled in a Single Migration Step

> **Issue:** #82 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** AP-00_CrossReferenceMatrix.md (Cluster 5: Core Data Schema)

## Problem Statement

If both R1 (data format versioning — adding a `dataVersion: Int16` field to `PendingCipherChangeData`) and R3 (retry backoff — adding a `retryCount: Int16` and/or `lastAttemptDate: Date` fields) are implemented, they should be bundled in a single Core Data model version step to minimize schema churn.

Currently, the `PendingCipherChangeData` entity was added to the existing Core Data model without creating a versioned model file. Core Data's lightweight migration handles new entity additions automatically. However, any future modification to the entity's attributes (adding/removing/renaming fields) requires careful migration planning.

## Current Code

- Core Data schema: `BitwardenShared/Core/Platform/Services/Stores/Bitwarden.xcdatamodeld/Bitwarden.xcdatamodel/contents`
- `PendingCipherChangeData` entity with 9 attributes: `id`, `cipherId`, `userId`, `changeTypeRaw`, `cipherData`, `originalRevisionDate`, `createdDate`, `updatedDate`, `offlinePasswordChangeCount`
- No versioned model files (single `.xcdatamodel` used)

## Assessment

**Still valid as a planning note.** This is not an issue with the current code but a recommendation for future schema changes. The observation from the cross-reference matrix is correct:

1. **Current state is fine.** The initial addition of `PendingCipherChangeData` as a new entity requires no explicit model versioning — Core Data's lightweight migration handles new entities automatically.

2. **Future attribute additions need care.** Adding new attributes to `PendingCipherChangeData` (e.g., `dataVersion` for R1, `retryCount` for R3) can also be handled by lightweight migration IF:
   - New attributes have default values specified in the schema
   - No existing attributes are renamed or removed
   - No relationship changes are made

3. **Bundling minimizes risk.** Each schema change that creates a new model version introduces a migration step. If R1 and R3 are implemented separately, users who skip an app version could face a multi-step migration chain. Bundling all changes into a single version step simplifies migration and reduces the surface area for migration failures.

**Hidden risks:**
- If R1 is implemented first and then R3 is implemented months later, there would be two separate schema changes. Users upgrading from pre-R1 to post-R3 would undergo two lightweight migrations. This is generally safe but adds complexity.
- If the codebase adopts explicit model versioning (adding `Bitwarden 2.xcdatamodel`), all future changes must follow the versioned model pattern, which is more overhead.

## Options

### Option A: Bundle R1 and R3 Schema Changes (Recommended If Both Are Implemented)
- **Effort:** None (planning only)
- **Description:** When implementing R1 and R3, make all `PendingCipherChangeData` attribute additions in a single PR/commit. This could mean:
  - Add `dataVersion: Int16` (default 1) for R1
  - Add `retryCount: Int16` (default 0) for R3
  - Optionally add `lastAttemptDate: Date?` for R3
  All in one schema update.
- **Pros:** Single migration step, simpler upgrade path, reduced risk
- **Cons:** Requires implementing R1 and R3 in the same release cycle (or at least the schema portions)

### Option B: Accept Separate Migrations
- **Effort:** None
- **Description:** If R1 and R3 are implemented at different times, each adds its own attribute(s) independently. Core Data lightweight migration handles each step.
- **Pros:** Allows independent release timelines for R1 and R3
- **Cons:** Multiple migration steps for users who skip versions, slightly more complex upgrade path

### Option C: Accept As-Is — Neither R1 Nor R3 Implemented Yet
- **Rationale:** Both R1 and R3 are open issues with no committed implementation timeline. This observation is purely advisory for whenever those issues are addressed. No action needed now.

## Recommendation

**Option C: Accept As-Is** for now. This is a planning note, not a code issue. When R1 and/or R3 are ready for implementation, the developers should refer to this action plan and consider bundling schema changes. If only one of R1 or R3 is implemented, the standalone lightweight migration is safe. If both are planned for the same release cycle, bundling (Option A) is preferable.

## Dependencies

- **R1** (data format versioning): Would add `dataVersion: Int16` to `PendingCipherChangeData`
- **R3** (retry backoff): Would add `retryCount: Int16` (and optionally `lastAttemptDate: Date?`) to `PendingCipherChangeData`
- **R2-PCDS-1** (Issue #48): No explicit Core Data schema versioning step — related concern about future schema changes
