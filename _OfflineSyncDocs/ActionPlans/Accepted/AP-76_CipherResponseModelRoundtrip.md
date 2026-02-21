# AP-76: VaultRepository Roundtripping Through `CipherDetailsResponseModel` JSON

> **Issue:** #76 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** OfflineSyncCodeReview.md

## Problem Statement

The review (R2-VR-9) observes that each offline handler in `VaultRepository` converts a `Cipher` to `CipherDetailsResponseModel` and then JSON-encodes it to store in the `pendingCipherChangeDataStore`. The suggestion is to use `Cipher` directly instead of roundtripping through `CipherDetailsResponseModel` JSON, potentially saving ~20 lines per handler.

## Current Code

The pattern appears 4 times in `VaultRepository.swift`:

**`handleOfflineAdd` (lines 1038-1039):**
```swift
let cipherResponseModel = try CipherDetailsResponseModel(cipher: encryptedCipher)
let cipherData = try JSONEncoder().encode(cipherResponseModel)
```

**`handleOfflineUpdate` (lines 1070-1071):**
```swift
let cipherResponseModel = try CipherDetailsResponseModel(cipher: encryptedCipher)
let cipherData = try JSONEncoder().encode(cipherResponseModel)
```

**`handleOfflineDelete` (lines 1150-1151):**
```swift
let cipherResponseModel = try CipherDetailsResponseModel(cipher: cipher)
let cipherData = try JSONEncoder().encode(cipherResponseModel)
```

**`handleOfflineSoftDelete` (lines 1188-1189):**
```swift
let cipherResponseModel = try CipherDetailsResponseModel(cipher: encryptedCipher)
let cipherData = try JSONEncoder().encode(cipherResponseModel)
```

On the resolver side, the data is decoded back:

**`resolveCreate` (line 150):**
```swift
let responseModel = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: cipherData)
let localCipher = Cipher(responseModel: responseModel)
```

**`resolveUpdate` (line 179):**
```swift
let localResponseModel = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: localCipherData)
let localCipher = Cipher(responseModel: localResponseModel)
```

## Assessment

**This issue is valid in observation but the suggested alternative is not feasible without significant changes.** The `Cipher` type (from `BitwardenSdk`) is not `Codable`. The project uses `CipherDetailsResponseModel` as the standard serialization intermediary for cipher data throughout the codebase:

1. **`CipherData` (Core Data entity):** Uses `CipherDetailsResponseModel` as its `Model` type (line 9: `typealias Model = CipherDetailsResponseModel`). All cipher persistence goes through this model.

2. **`Cipher` has no direct JSON encoding.** The SDK's `Cipher` type does not conform to `Codable` directly. `CipherDetailsResponseModel(cipher:)` is the established serialization path.

3. **Consistency:** The `PendingCipherChangeData.cipherData` field stores the same format as `CipherData.modelData` -- both use `CipherDetailsResponseModel` JSON. This consistency means the resolver can reconstruct ciphers using the same pattern used everywhere else in the app.

4. **Alternative would require a new serialization format.** Storing `Cipher` directly would require either:
   - Making `Cipher` conform to `Codable` (not possible -- it's an SDK type)
   - Using a different serialization approach (e.g., protobuf, custom encoding)
   - Storing raw `Cipher` binary data via `NSCoding` or similar

All alternatives would introduce a new, non-standard serialization path that diverges from the rest of the codebase.

**The 2-line encode/decode pattern is the project's established way to persist cipher data.** It is not roundtripping in the sense of unnecessary conversion -- it is the required serialization step because `Cipher` is not directly encodable.

## Options

### Option A: Extract a Helper for Cipher Serialization
- **Effort:** ~20 minutes, ~10 lines added, ~8 lines removed
- **Description:** Create a small helper to reduce the 2-line pattern to 1 line:
  ```swift
  private func encodeCipherData(_ cipher: Cipher) throws -> Data {
      let responseModel = try CipherDetailsResponseModel(cipher: cipher)
      return try JSONEncoder().encode(responseModel)
  }
  ```
  Each handler would then use: `let cipherData = try encodeCipherData(encryptedCipher)`
- **Pros:** Reduces repetition; centralizes the serialization logic; if the serialization format changes, only one place needs updating
- **Cons:** Very minor indirection; the 2-line pattern is already clear

### Option B: Store Cipher Differently
- **Effort:** High (~4+ hours), schema change, migration
- **Description:** Change `PendingCipherChangeData.cipherData` to store cipher data in a different format that avoids the `CipherDetailsResponseModel` intermediate.
- **Pros:** Eliminates the conversion step
- **Cons:** `Cipher` is not `Codable`; would diverge from the project's standard cipher persistence pattern; requires schema change; breaks existing pending change records; no practical benefit

### Option C: Accept As-Is (Recommended)
- **Rationale:** The `Cipher` -> `CipherDetailsResponseModel` -> JSON pattern is the project's established serialization path for cipher data. It is used everywhere ciphers are persisted (including `CipherData` Core Data entity). The pattern is only 2 lines, is well-understood, and is consistent with the rest of the codebase. The "roundtripping" is not unnecessary -- it is the required serialization step.

## Recommendation

**Option C: Accept As-Is.** The `CipherDetailsResponseModel` serialization is not a roundtrip -- it is the only way to serialize `Cipher` objects in the project, since the SDK type is not `Codable`. The pattern is consistent with how all cipher data is persisted in the app. The 2-line pattern is clear and idiomatic for this codebase.

If code reduction is desired, Option A (extract a small helper) would be a reasonable minor improvement.

## Dependencies

- Related to Issue #R1 (data format versioning) -- if a version field is added to `PendingCipherChangeData`, the serialization format becomes even more important to standardize. Using the same `CipherDetailsResponseModel` format as the main cipher store is the right choice.
