# AP-64: Each Offline Update Decrypts Previous Version to Compare Passwords

> **Issue:** #64 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/03_VaultRepository_Review.md

## Problem Statement

In `VaultRepository.handleOfflineUpdate()`, each offline update to a cipher requires decrypting the previous version to compare the password field and determine whether to increment the `offlinePasswordChangeCount`. If a user makes many rapid edits to the same cipher while offline, each save triggers a decrypt-compare cycle:

1. Fetch existing pending change from Core Data
2. Decode the existing `cipherData` JSON into `CipherDetailsResponseModel`
3. Create a `Cipher` from the response model
4. Decrypt the cipher via the SDK (`clientService.vault().ciphers().decrypt()`)
5. Compare `existingDecrypted.login?.password` with `cipherView.login?.password`

This involves JSON deserialization + SDK decryption for every save, which could be costly if edits are very frequent.

## Current Code

- `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift:1082-1097`
```swift
// Detect password change by comparing with the previous version
if let existingData = existing?.cipherData {
    let existingModel = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: existingData)
    let existingCipher = Cipher(responseModel: existingModel)
    let existingDecrypted = try await clientService.vault().ciphers().decrypt(cipher: existingCipher)
    if existingDecrypted.login?.password != cipherView.login?.password {
        passwordChangeCount += 1
    }
} else {
    // First offline edit: check if password changed from the pre-offline version
    if let localCipher = try await cipherService.fetchCipher(withId: cipherId) {
        let localDecrypted = try await clientService.vault().ciphers().decrypt(cipher: localCipher)
        if localDecrypted.login?.password != cipherView.login?.password {
            passwordChangeCount += 1
        }
    }
}
```

## Assessment

**Still valid but impact is negligible in practice.** The concern is theoretically valid but practically irrelevant:

1. **Typical usage pattern:** Users edit a cipher, save, and move on. It is extremely rare for a user to edit the same cipher many times in rapid succession while offline. The most common case is a single edit to a single cipher.

2. **SDK decryption is fast:** The Bitwarden SDK's `decrypt(cipher:)` operation is an in-memory AES-GCM decryption. This typically completes in under 1 millisecond. Even 100 rapid edits would add less than 100ms of decryption overhead.

3. **JSON decoding is fast:** `JSONDecoder` for a single `CipherDetailsResponseModel` is sub-millisecond.

4. **The bottleneck is elsewhere:** The actual bottleneck in `handleOfflineUpdate` is the Core Data write (`updateCipherWithLocalStorage` and `upsertPendingChange`), not the decryption. Core Data disk I/O dominates the cost.

5. **This runs on user action:** The decrypt-compare happens when the user saves an edit, not in a tight loop. The user's editing speed is the natural rate limiter.

**Hidden risks:** None. The decryption is ephemeral (in-memory only) and does not persist plaintext anywhere.

## Options

### Option A: Accept As-Is (Recommended)
- **Rationale:** The decrypt-compare cost is negligible for realistic usage patterns. SDK decryption is fast (sub-millisecond), and the user's editing cadence naturally limits the frequency. Optimizing this would add complexity without measurable benefit.

### Option B: Cache Decrypted Password Hash
- **Effort:** Medium (~2-4 hours)
- **Description:** Instead of comparing decrypted passwords, store a hash (e.g., SHA-256) of the password in the `PendingCipherChangeData` entity. Compare hashes instead of full decryption.
- **Pros:** Avoids decryption entirely on subsequent edits
- **Cons:** Requires Core Data schema change, introduces a new field that stores derived password data (security concern — even a hash reveals whether password changed), adds complexity, minimal benefit for sub-millisecond optimization

### Option C: Skip Password Change Detection for Non-Login Ciphers
- **Effort:** Low (~15 minutes)
- **Description:** Add an early return before the decrypt-compare block: `guard cipherView.type == .login else { ... }`. For non-login ciphers (cards, identities, notes), there is no password to compare.
- **Pros:** Avoids unnecessary decryption for non-login types
- **Cons:** Marginal benefit; non-login ciphers have `login?.password == nil` which already short-circuits the comparison

## Recommendation

**Option A: Accept As-Is.** The performance concern is theoretical, not practical. The decrypt-compare cycle adds sub-millisecond overhead per save, which is undetectable by users. The current implementation is straightforward and correct. Optimizing it would introduce complexity without measurable benefit.

## Dependencies

- None.
