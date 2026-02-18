# Review: UI Layer Changes (ViewItemProcessor, Alerts)

## Files Reviewed

| File | Status | Lines Changed |
|------|--------|--------------|
| `BitwardenShared/UI/Vault/VaultItem/ViewItem/ViewItemProcessor.swift` | Modified | +110/-56 |
| `BitwardenShared/UI/Vault/VaultItem/ViewItem/ViewItemProcessorTests.swift` | Modified | +87 |
| `BitwardenShared/UI/Vault/Extensions/Alert+Vault.swift` | Modified | +19 |
| `BitwardenShared/UI/Vault/Extensions/AlertVaultTests.swift` | Modified | +29 |

## Overview

The UI layer changes address a specific problem: offline-created ciphers can fail in the `cipherDetailsPublisher` stream's `asyncTryMap` (which decrypts ciphers), causing the publisher to terminate and leaving the user on a blank screen. The fix adds a fallback path that fetches and decrypts the cipher directly when the publisher fails.

## Architecture Compliance (Architecture.md)

### ViewItemProcessor Changes

The processor refactors the state-building logic and adds a fallback fetch path:

1. **`buildViewItemState(from:)` extraction** — The existing inline state-building logic in `streamCipherDetails()` is extracted into a new private method `buildViewItemState(from:)`. This is a pure refactor that reduces duplication.

2. **`fetchCipherDetailsDirectly()` addition** — A new fallback method that:
   - Calls `services.vaultRepository.fetchCipher(withId:)` to get the cipher directly from the data store
   - Builds the view state using `buildViewItemState(from:)`
   - Sets the loading state to `.error` if the cipher can't be found

3. **Modified `streamCipherDetails()`** — On stream failure, instead of just logging the error, it now calls `fetchCipherDetailsDirectly()` as a fallback.

**Assessment**:
- **Compliant**: The processor handles effects (asynchronous data loading) per the architecture pattern.
- **Compliant**: State mutations occur through the processor's `state` property.
- **Good**: The refactoring doesn't change the external behavior for online ciphers — only the error recovery path is new.
- **Good**: Error logging is preserved alongside the fallback attempt.
- **Good**: The fallback properly sets `.error` loading state when the cipher can't be found, providing user feedback.

### Alert+Vault Changes

A new `specificPeopleUnavailable(action:)` alert is added:

```swift
static func specificPeopleUnavailable(action: @escaping () -> Void) -> Alert {
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

**Assessment**: This appears to be an **upstream change** unrelated to offline sync. It adds a premium subscription alert for "Specific People" Send feature. Follows the established `Alert` factory pattern.

## Detailed ViewItemProcessor Analysis

### Before (original)

```swift
private func streamCipherDetails() async {
    do {
        for try await cipher in try await services.vaultRepository.cipherDetailsPublisher(id: itemId) {
            // ... build state inline (~30 lines)
            state = newState
        }
    } catch {
        services.errorReporter.log(error: error)
    }
}
```

### After (modified)

```swift
private func streamCipherDetails() async {
    do {
        for try await cipher in try await services.vaultRepository.cipherDetailsPublisher(id: itemId) {
            guard let cipher else { continue }
            if let newState = try await buildViewItemState(from: cipher) {
                state = newState
            }
        }
    } catch {
        services.errorReporter.log(error: error)
        await fetchCipherDetailsDirectly()
    }
}

private func fetchCipherDetailsDirectly() async {
    do {
        guard let cipher = try await services.vaultRepository.fetchCipher(withId: itemId),
              let newState = try await buildViewItemState(from: cipher)
        else {
            state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)
            return
        }
        state = newState
    } catch {
        services.errorReporter.log(error: error)
        state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)
    }
}
```

**Assessment**:
- **Good**: The fallback path provides degraded-but-functional behavior. The user can see their cipher even if the publisher stream fails.
- **Note**: The fallback path is a one-time fetch, not a stream. The user won't receive live updates if other changes occur while viewing. This is acceptable as a fallback — the primary stream is the normal path.
- **Good**: Both the stream error and any fallback error are logged via `errorReporter`.
- **Good**: The `.error` loading state provides clear user feedback when neither path works.

## Security Assessment

- **No concerns**: The fallback path uses the same `fetchCipher(withId:)` and SDK decryption that the publisher uses internally. No new security surface is introduced.

## Data Safety (User Data Loss Prevention)

- **Not directly applicable**: The ViewItemProcessor doesn't modify data, it only reads and displays it. However, the fallback ensures that offline-created ciphers can be viewed by the user, which is important for usability and user confidence that their data was saved.

## Usability Assessment

- **Improved**: Without this change, an offline-created cipher would show a blank screen or spinner when the user taps on it. With the fallback, the cipher details are displayed correctly.
- **Adequate**: If both paths fail, the user sees a generic error message. A more specific message (e.g., "This item may not be available until you reconnect") could improve the experience.

## Code Style Compliance

- **Compliant**: DocC documentation on the new methods
- **Compliant**: MARK comment structure maintained
- **Minor — long `buildViewItemState` method**: The extracted method is ~35 lines. This is within acceptable limits but could be considered for further decomposition in a future refactor.

## Test Coverage

The `ViewItemProcessorTests.swift` adds 87 lines covering:

- `test_perform_appeared_errors` — Updated to verify fallback behavior and error state
- `test_perform_appeared_errors_fallbackFetchSuccess` — Publisher fails, direct fetch succeeds
- `test_perform_appeared_errors_fallbackFetchFailure` — Both publisher and direct fetch fail (cipher not found)
- `test_perform_appeared_errors_fallbackFetchThrows` — Both publisher and direct fetch throw errors

**Assessment**: Comprehensive coverage of the new fallback paths. Tests verify both successful fallback and various failure modes.

## Upstream vs Offline Sync Changes

Within the files reviewed in this section:

**Offline sync related**:
- `ViewItemProcessor.swift`: `buildViewItemState` extraction and `fetchCipherDetailsDirectly` fallback
- `ViewItemProcessorTests.swift`: Fallback path tests

**Upstream/unrelated**:
- `Alert+Vault.swift`: `specificPeopleUnavailable` alert (unrelated to offline sync)
- `AlertVaultTests.swift`: Tests for the new alert

## Summary

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Architecture compliance | **Good** | Processor pattern, state mutations via processor |
| Usability | **Improved** | Users can view offline-created ciphers |
| Security | **No concerns** | Same read paths as existing code |
| Code style | **Good** | DocC, MARK comments, naming |
| Test coverage | **Good** | Fallback paths well tested |
| Data safety | **N/A** | Read-only UI changes |
