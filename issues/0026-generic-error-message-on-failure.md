---
id: 26
title: "[R2-UI-2] Generic error message when both publisher stream and fallback fail"
status: open
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
---

## Description

Generic "An error has occurred" message when both publisher stream and fallback fail — should show offline-specific message.

**Severity:** Low
**Complexity:** Low
**Action Plan:** AP-54

**Related Documents:** Review2/06_UILayer

## Action Plan

*Source: `ActionPlans/AP-54.md`*

> **Issue:** #54 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/06_UILayer_Review.md

## Problem Statement

When a user attempts to view a cipher and both the `cipherDetailsPublisher` stream and the `fetchCipherDetailsDirectly()` fallback fail, the `ViewItemProcessor` displays a generic "An error has occurred" message via `Localizations.anErrorHasOccurred`. This message provides no context about why the failure occurred or what the user can do about it. In the offline sync context, the most likely cause is that an offline-created cipher failed to decrypt through both code paths. A more specific error message — such as "This item may not be available until you reconnect" — would help the user understand the situation and set appropriate expectations.

## Current Behavior

In `ViewItemProcessor.swift`, the `fetchCipherDetailsDirectly()` method has two failure paths that both display the same generic error:

1. **Guard failure** (`ViewItemProcessor.swift:623-625`): When `fetchCipher(withId:)` returns `nil` or `buildViewItemState(from:)` returns `nil`:
   ```swift
   guard let cipher = try await services.vaultRepository.fetchCipher(withId: itemId),
         let newState = try await buildViewItemState(from: cipher)
   else {
       state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)
       return
   }
   ```

2. **Catch block** (`ViewItemProcessor.swift:628-631`): When any error is thrown during the fetch or state building:
   ```swift
   } catch {
       services.errorReporter.log(error: error)
       state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)
   }
   ```

Both paths use the exact same `Localizations.anErrorHasOccurred` string, which resolves to a generic "An error has occurred" message. There is no differentiation between:
- A cipher that genuinely doesn't exist
- A decryption failure (likely for offline-created ciphers)
- A general data loading error

The error is also displayed within the view's loading state (not an alert), meaning the user sees it inline on the screen where the cipher details would normally appear.

## Expected Behavior

When both the publisher stream and the direct fetch fallback fail, the error message should be context-specific. For the offline sync scenario, the message should indicate that the item may be temporarily unavailable and will be accessible once connectivity is restored and sync completes. For example:

- "This item couldn't be loaded. It may become available after your vault syncs."
- "Unable to load item details. Please try again after connecting to the internet."

The message should be actionable — telling the user that no action is needed on their part beyond waiting for sync.

## Assessment

**Still Valid:** Yes. The code at `ViewItemProcessor.swift:624` and `ViewItemProcessor.swift:630` still uses `Localizations.anErrorHasOccurred` without any offline-specific context.

**User Impact:** Low. This scenario requires both the stream AND the fallback to fail, which is a double-failure edge case. The most likely trigger is an offline-created cipher with corrupted or incompatible encrypted data. In normal offline operation, the fallback (`fetchCipherDetailsDirectly`) succeeds, so users rarely see this error.

**Priority:** Low. This is a polish item that improves the UX for a rare double-failure scenario. The generic error is functional (it prevents an infinite spinner) but not informative.

## Options

### Option A: Add Offline-Specific Error Message (Recommended)

- **Effort:** Low (~10-15 lines, 2 files)
- **Description:** Add a new localization string for an offline-specific error and use it in the fallback failure path. The implementation would check whether the error is network-related or the cipher appears to be offline-created (e.g., has a UUID-format temp ID) and show the appropriate message.

  Implementation in `ViewItemProcessor.swift`:
  ```swift
  private func fetchCipherDetailsDirectly() async {
      do {
          guard let cipher = try await services.vaultRepository.fetchCipher(withId: itemId),
                let newState = try await buildViewItemState(from: cipher)
          else {
              state.loadingState = .error(
                  errorMessage: Localizations.itemCouldNotBeLoadedTryAgainAfterSync
              )
              return
          }
          state = newState
      } catch {
          services.errorReporter.log(error: error)
          state.loadingState = .error(
              errorMessage: Localizations.itemCouldNotBeLoadedTryAgainAfterSync
          )
      }
  }
  ```

  New localization string:
  ```
  "ItemCouldNotBeLoadedTryAgainAfterSync" = "This item couldn't be loaded. It may become available after your vault syncs.";
  ```

- **UX Impact:** Users who encounter this rare double-failure see a helpful, non-alarming message that sets expectations about recovery.
- **Pros:**
  - Minimal code change
  - No architectural changes needed
  - Reduces user confusion in the (rare) failure scenario
  - Consistent with the offline sync philosophy of graceful degradation
- **Cons:**
  - Requires a new localization string (translation effort across supported languages)
  - The message assumes the issue is sync-related, which may not always be true (could be a general decryption bug)

### Option B: Differentiate Error Types

- **Effort:** Medium (~20-30 lines, 2-3 files)
- **Description:** Inspect the caught error to determine its type and show different messages:
  - Network/URL errors: "This item is unavailable while offline. It will be available after your vault syncs."
  - Decryption errors: "This item couldn't be decrypted. Please try again after syncing."
  - Cipher not found: "This item was not found in your vault."
  - Other: Keep the generic "An error has occurred."

- **Pros:**
  - More precise feedback for each failure type
  - Better debugging experience for users
- **Cons:**
  - More complex implementation
  - Requires understanding the error taxonomy from the SDK
  - Multiple new localization strings
  - The distinction between error types may not be meaningful to end users

### Option C: Accept As-Is

- **Rationale:** The double-failure scenario (both stream and fallback fail) is extremely rare in practice. The fallback was specifically added to handle offline-created ciphers, and it works correctly in the common case. The generic error message is functional — it prevents an infinite loading state and signals to the user that something went wrong. The error is also logged via `errorReporter`, so support teams can diagnose specific cases if needed. Investing effort in improving a message for a rare edge case may not be the best use of development time for the initial release.
- **Pros:**
  - Zero effort
  - No new localization strings
- **Cons:**
  - Generic message remains unhelpful for the rare user who encounters it

## Recommendation

**Option A: Add Offline-Specific Error Message.** Despite the low severity, this is a very low-effort change (one new localization string, two line changes) that meaningfully improves the user experience for anyone who encounters it. The generic "An error has occurred" is a known UX anti-pattern that provides no actionable information. A specific message like "This item couldn't be loaded. It may become available after your vault syncs." gives the user confidence that the app is handling the situation and that recovery will happen automatically.

This could be combined with Issue #5 (U2-B: offline-specific error messages for unsupported operations) in a single localization pass to minimize translation overhead.

## Dependencies

- **Related Issues:**
  - #5 / U2-B: Offline-specific error messages for unsupported operations (could share localization work)
  - #53 / R2-UI-1: The fallback one-time fetch issue. If Option A from AP-53 is implemented (re-attempt stream), this error would only appear if the re-attempt also fails, making it even rarer.
  - #11 / U1: Org cipher error timing — related UX concern about generic error messages in offline context

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 4d: UX Improvements*

Generic "An error has occurred" message when both publisher stream and fallback fail — should show offline-specific message.

## Code Review References

Relevant review documents:
- `Review2/06_UILayer_Review.md`

## Comments

### claude — 2026-02-22

**Codebase validated — issue confirmed OPEN.**

1. When `fetchCipherDetailsDirectly()` fails: `state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)`
2. Error is generic — no distinction between cipher not found, decryption failure, network error, etc.
3. Actual error is logged via `errorReporter.log(error:)` but user sees only "An error has occurred"
