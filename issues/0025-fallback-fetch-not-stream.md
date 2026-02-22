---
id: 25
title: "[R2-UI-1] Fallback fetchCipherDetailsDirectly() is one-time fetch, not stream"
status: open
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
---

## Description

Fallback `fetchCipherDetailsDirectly()` is a one-time fetch, not a stream — no live updates while viewing offline-created cipher.

**Severity:** Low
**Complexity:** Medium
**Action Plan:** AP-53

**Related Documents:** Review2/06_UILayer

## Action Plan

*Source: `ActionPlans/AP-53.md`*

> **Issue:** #53 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Medium
> **Status:** Triaged
> **Source:** Review2/06_UILayer_Review.md

## Problem Statement

When `ViewItemProcessor.streamCipherDetails()` encounters an error in the `cipherDetailsPublisher` stream (which can happen for offline-created ciphers whose encrypted data causes the publisher's `asyncTryMap` to fail), it falls back to `fetchCipherDetailsDirectly()`. This fallback method performs a single, one-time fetch of the cipher from the local data store and populates the view state. However, unlike the primary `cipherDetailsPublisher` stream, it does not establish an ongoing subscription to cipher data changes.

This means that if the user is viewing an offline-created cipher and another process modifies that cipher (e.g., the sync resolver runs and replaces the temp-ID cipher with a server-assigned ID), the view will not automatically update. The user would need to navigate away and back to see any changes.

## Current Behavior

In `ViewItemProcessor.swift`:

1. **Primary path** (`ViewItemProcessor.swift:600-608`): `streamCipherDetails()` creates an `async for` loop over `cipherDetailsPublisher(id:)`, which provides continuous updates whenever the underlying cipher data changes in Core Data.

2. **Fallback path** (`ViewItemProcessor.swift:619-632`): When the primary stream throws an error, `fetchCipherDetailsDirectly()` is called. This method:
   - Calls `services.vaultRepository.fetchCipher(withId: itemId)` — a single async call, not a publisher (`VaultRepository.swift:633-636`)
   - Builds the view state once via `buildViewItemState(from:)`
   - Sets `state = newState` and returns
   - No further updates are received

The `cipherDetailsPublisher` (`VaultRepository.swift:1214-1222`) works by subscribing to `cipherService.ciphersPublisher()` and filtering + decrypting the matching cipher. When the stream fails (e.g., decryption error for an offline-created cipher), the `for try await` loop exits and the fallback is invoked.

## Expected Behavior

After the fallback fetch succeeds, the user should continue to receive live updates to the cipher being viewed. If the cipher is modified (e.g., by the sync resolver replacing the temp-ID record), the view should reflect those changes without requiring the user to navigate away and back.

## Assessment

**Still Valid:** Yes. The fallback path at `ViewItemProcessor.swift:619-632` remains a one-time fetch.

**User Impact:** Low. This scenario only affects offline-created ciphers that fail in the publisher stream. In practice:
- The user would need to be viewing an offline-created cipher at the exact moment the sync resolver processes it. This is unlikely because sync resolution happens on reconnect, and the user would typically not be staring at an offline-created cipher at that instant.
- Even if it does happen, the stale data is not dangerous — it simply shows the version the user last saved. Navigating away and back (or pulling to refresh) would show the updated data.
- The primary stream is the normal path for all non-offline-created ciphers and works correctly.

**Priority:** Low. The fallback is defense-in-depth for an edge case. The lack of live updates is a minor UX imperfection, not a data safety or correctness issue.

## Options

### Option A: Re-attempt Stream Subscription After Fallback (Recommended)

- **Effort:** Small-Medium (~20-30 lines, 1 file)
- **Description:** After `fetchCipherDetailsDirectly()` succeeds and the view state is populated, attempt to re-subscribe to the `cipherDetailsPublisher`. If the re-subscription succeeds (which it may after the initial decryption issue resolves itself on a subsequent Core Data notification), the view gets live updates going forward. If it fails again, the one-time fetch result remains displayed.

  Implementation:
  ```swift
  private func fetchCipherDetailsDirectly() async {
      do {
          guard let cipher = try await services.vaultRepository.fetchCipher(withId: itemId),
                let newState = try await buildViewItemState(from: cipher)
          else {
              state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)
              return
          }
          state = newState
          // Re-attempt streaming after successful fallback fetch
          await resubscribeToCipherDetails()
      } catch {
          services.errorReporter.log(error: error)
          state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)
      }
  }

  private func resubscribeToCipherDetails() async {
      do {
          for try await cipher in try await services.vaultRepository.cipherDetailsPublisher(id: itemId) {
              guard let cipher else { continue }
              if let newState = try await buildViewItemState(from: cipher) {
                  state = newState
              }
          }
      } catch {
          // Stream failed again; keep showing the one-time fetch result.
          services.errorReporter.log(error: error)
      }
  }
  ```
- **UX Impact:** The view would eventually reflect any changes made by the sync resolver or other processes, providing a seamless experience.
- **Pros:**
  - Provides live updates after fallback recovery
  - Minimal code change
  - No new dependencies
  - Graceful degradation — if re-subscription fails, the one-time result remains
- **Cons:**
  - Could cause an infinite retry loop if the stream consistently fails. Should add a retry limit (e.g., 1 retry) to prevent this.
  - Slightly more complex control flow in the processor
  - Need to ensure Task cancellation is handled properly when the view disappears

### Option B: Use a Polling Mechanism After Fallback

- **Effort:** Medium (~30-40 lines, 1 file)
- **Description:** After the fallback fetch succeeds, start a periodic timer (e.g., every 5-10 seconds) that re-fetches the cipher via `fetchCipher(withId:)` and updates the state if the data changed. Stop polling when the view disappears.
- **Pros:**
  - Simpler than re-subscribing to a Combine publisher
  - Predictable behavior
- **Cons:**
  - Polling is wasteful if no changes occur
  - Adds a timer dependency
  - Still not truly "live" — there's a delay up to the poll interval
  - Not aligned with the app's existing reactive publisher pattern

### Option C: Accept As-Is

- **Rationale:** The fallback path is a defense-in-depth mechanism for offline-created ciphers. The scenario where a user is actively viewing an offline cipher while the sync resolver processes it is narrow. The one-time fetch provides a functional view of the cipher, and the user can navigate away and back to get updated data. Given the Low severity and the rarity of the scenario, the current behavior may be acceptable for the initial release.
- **Pros:**
  - Zero effort
  - No risk of introducing new bugs
- **Cons:**
  - Minor UX imperfection remains

## Recommendation

**Option C: Accept As-Is** for the initial release. The scenario is narrow (viewing an offline-created cipher at the exact moment sync resolution runs), the impact is cosmetic (stale but safe data), and the workaround is trivial (navigate away and back). If user feedback indicates this is a real problem, Option A with a single retry limit would be the preferred fix.

If Option A is pursued in a future iteration, ensure:
1. A maximum retry count of 1 to prevent infinite loops
2. Proper Task cancellation handling in `deinit` / `disappeared`
3. Test coverage for the re-subscription path (success and failure)

## Dependencies

- **Related Issues:**
  - #40 (P2-T4): Test gap — no test for cipher update after fallback. Would need to be addressed alongside Option A.
  - #46 (R2-VR-5): JSONEncoder failures in offline helpers — tangentially related to offline data reliability

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 4d: UX Improvements*

Fallback `fetchCipherDetailsDirectly()` is a one-time fetch, not a stream — no live updates while viewing offline-created cipher.

## Code Review References

Relevant review documents:
- `Review2/06_UILayer_Review.md`

## Comments

### claude — 2026-02-22

**Codebase validated — issue confirmed OPEN.**

1. `fetchCipherDetailsDirectly()` (ViewItemProcessor.swift:619-632) is a one-time fetch
2. On failure, sets state to `.error(errorMessage: Localizations.anErrorHasOccurred)` and returns
3. No retry mechanism, no continuous publisher stream established
4. Contrast: `streamCipherDetails()` uses `for try await` for continuous updates
