# Review: Upstream and Incidental Changes

## Overview

The fork includes many file changes that are NOT related to the offline sync feature. These come from the upstream Bitwarden iOS repository's ongoing development between the fork point and the current state. This document catalogs these changes to distinguish them from offline sync changes.

## Categorization of Non-Offline-Sync Changes

### Category 1: Typo/Spelling Fixes

These appear to be from the upstream `[PM-27525] Add spell check git pre-commit hook (#2319)` commit and related work:

| File | Change |
|------|--------|
| `BitwardenShared/Core/Auth/Repositories/AuthRepository.swift` | "thes" → "the" |
| `BitwardenShared/Core/Auth/Services/Biometrics/BiometricsService.swift` | "occured" → "occurred" |
| `BitwardenShared/Core/Auth/Services/TrustDeviceService.swift` | "refering" → "referring" (3 occurrences) |
| `BitwardenShared/Core/Autofill/Services/CredentialIdentityFactory.swift` | "IdenittyFactory" → "IdentityFactory", "implemenation" → "implementation" |
| `BitwardenShared/Core/Autofill/Utilities/ActionExtensionHelper.swift` | "Wether" → "Whether" |
| `BitwardenShared/Core/Platform/Services/CameraService.swift` | "DefaultCamerAuthorizationService" → "DefaultCameraAuthorizationService" |
| `BitwardenShared/Core/Platform/Services/PlatformClientService.swift` | "pubilc" → "public" |
| `BitwardenShared/Core/Platform/Services/ServiceContainer.swift` | "Exhange" → "Exchange", "appllication" → "application", "DefultExportVaultService" → "DefaultExportVaultService" |
| `BitwardenShared/Core/Platform/Utilities/KeyManagementTypes.swift` | "CoseKey" → "CaseKey" |
| `BitwardenShared/Core/Platform/Utilities/Rehydration/RehydrationHelper.swift` | "Attemps" → "Attempts" |
| `BitwardenShared/UI/Auth/AuthCoordinator.swift` | "attemptAutmaticBiometricUnlock" → "attemptAutomaticBiometricUnlock" |
| `BitwardenShared/UI/Platform/Application/AppProcessor.swift` | "Perpares" → "Prepares" |
| `BitwardenShared/UI/Platform/Application/Extensions/View+Backport.swift` | "availalbe" → "available" |
| `BitwardenShared/UI/Vault/Extensions/AlertVaultTests.swift` | "appropirate" → "appropriate" |
| `BitwardenShared/UI/Vault/VaultItem/ViewItem/ViewLoginItem/Extensions/LoginViewUpdateTests.swift` | "Propteries" → "Properties" |
| `BitwardenShared/Core/Vault/Services/SyncService.swift` | "nofication" → "notification" |
| `.typos.toml` | Updated typo configuration |

**Assessment**: These are harmless spelling corrections. The `AuthCoordinator.swift` change also renames a parameter (`attemptAutmaticBiometricUnlock` → `attemptAutomaticBiometricUnlock`) which would be a compile-affecting change within that file.

### Category 2: SDK API Changes

These reflect updates to the Bitwarden SDK:

| File | Change |
|------|--------|
| `BitwardenShared/Core/Autofill/Services/AutofillCredentialService.swift` | `.authenticator(` → `.vaultAuthenticator(` (3 occurrences) |
| `BitwardenShared/Core/Auth/Services/ClientFido2Service.swift` | Method rename for FIDO2 |
| `AuthenticatorShared/Core/Auth/Services/ClientFido2Service.swift` | Same SDK changes in Authenticator target |
| `AuthenticatorShared/Core/Auth/Services/TestHelpers/MockClientFido2*.swift` | Mock updates for SDK changes |
| `BitwardenShared/Core/Auth/Services/TestHelpers/MockClientFido2Service.swift` | Mock updates |
| `Bitwarden.xcworkspace/xcshareddata/swiftpm/Package.resolved` | SPM dependency updates |
| `BitwardenShared/Core/Tools/Extensions/BitwardenSdk+Tools.swift` | Removed `emailHashes` property |
| `BitwardenShared/Core/Tools/Models/Response/SendResponseModel.swift` | Removed `emailHashes` |

**Assessment**: Standard SDK version update changes. The `authenticator` → `vaultAuthenticator` rename and `emailHashes` removal are API-breaking changes that must be applied when updating the SDK dependency.

### Category 3: Upstream Feature Changes & Test Updates

#### Vault Domain (Typo Fixes, Not Offline Sync)

| File | Change |
|------|--------|
| `Core/Vault/Models/API/CipherPermissionsModel.swift` | Typo: "acive" → "active" |
| `Core/Vault/Helpers/CipherMatchingHelper.swift` | Typo: "implemenetation" → "implementation" |
| `Core/Vault/Helpers/VaultListDataPreparator.swift` | Typo: "bulider" → "builder" |
| `Core/Vault/Helpers/VaultListSectionsBuilderFactory.swift` | Typo: "implemetnation" → "implementation" |
| `Core/Vault/Helpers/VaultListSectionsBuilderTests.swift` | Typo: "combinining" → "combining" |
| `Core/Vault/Services/ExportVaultService.swift` | Typo: "encypted" → "encrypted"; class rename fix |
| `Core/Vault/Services/ExportVaultServiceTests.swift` | Updated for `DefultExportVaultService` → `DefaultExportVaultService` |
| `Core/Vault/Services/Fido2CredentialStoreService.swift` | Typo: "Fido2DebugginReportBuilder" → "Fido2DebuggingReportBuilder" |
| `Core/Vault/Services/TOTP/TOTPExpirationCalculatorTests.swift` | Typo: "test_remainingSecons" → "test_remainingSeconds" |
| `Core/Vault/Services/VaultTimeoutServiceTests.swift` | Added `biometricsRepository.getBiometricUnlockStatusReturnValue` setup |

#### Vault Domain (Offline Sync Infrastructure)

| File | Change |
|------|--------|
| `Core/Vault/Services/TestHelpers/MockCipherService.swift` | Changed `cipherChangesSubject` from `CurrentValueSubject` to `PassthroughSubject`; added `cipherChangesSubscribed` property |
| `Core/Vault/Services/CipherServiceTests.swift` | Added `test_addCipherWithServer_networkError_throwsURLError()` and similar network error propagation tests (~32 lines) |
| `Core/Vault/Services/TestHelpers/BitwardenSdk+VaultMocking.swift` | Mock updates for SDK type changes |

**Note**: The `MockCipherService` and `CipherServiceTests` changes directly support offline sync testing by verifying that network errors propagate correctly through the CipherService layer — a prerequisite for the VaultRepository's offline fallback error classification.

#### Auth Domain

| File | Change |
|------|--------|
| `Core/Auth/Services/Biometrics/BiometricsRepository.swift` | Added `// sourcery: AutoMockable` annotation |
| `Core/Auth/Services/TestHelpers/MockBiometricsRepository.swift` | New auto-generated mock |
| `Core/Auth/Repositories/AuthRepositoryTests.swift` | Test updates (typo fixes, mock adjustments) |
| `Core/Auth/Services/AuthServiceTests.swift` | Test updates |
| `Core/Auth/Services/LocalAuth/LocalAuthServiceTests.swift` | Test updates |
| `UI/Auth/AuthCoordinatorTests.swift` | Updated for `attemptAutmaticBiometricUnlock` → `attemptAutomaticBiometricUnlock` |
| `UI/Auth/AuthRouterTests.swift` | Test updates |
| `UI/Auth/CompleteRegistration/MasterPasswordGenerator/MasterPasswordGeneratorProcessor.swift` | Minor changes |
| `UI/Auth/CompleteRegistration/MasterPasswordGuidance/MasterPasswordGuidanceProcessor.swift` | Minor changes |
| `UI/Auth/Login/LoginDecryptionOptions/LoginDecryptionOptionsState.swift` | Minor changes |
| `UI/Auth/Login/LoginProcessorTests.swift` | Test updates |
| `UI/Auth/Login/TwoFactorAuth/TwoFactorAuthProcessorTests.swift` | Test updates |
| `UI/Auth/Login/TwoFactorAuth/TwoFactorAuthState.swift` | Minor changes |
| `UI/Auth/Utilities/VaultUnlockSetupHelperTests.swift` | Test updates |
| `UI/Auth/VaultUnlock/VaultUnlockProcessorTests.swift` | Test updates |
| `UI/Auth/VaultUnlockSetup/VaultUnlockSetupProcessorTests.swift` | Test updates |

#### Autofill Domain

| File | Change |
|------|--------|
| `Core/Autofill/Services/AutofillCredentialService+AppExtensionTests.swift` | Test updates for SDK changes |
| `Core/Autofill/Services/CredentialIdentityFactoryTests.swift` | Test updates for typo fixes |
| `UI/Autofill/Utilities/Fido2UserVerificationMediatorTests.swift` | Test updates |

#### Tools Domain (Send Feature)

| File | Change |
|------|--------|
| `Core/Tools/Models/Enum/SendAccessType.swift` | New file: Send access type enum |
| `Core/Tools/Models/Enum/SendAccessTypeTests.swift` | Tests for access type |
| `Core/Tools/Models/Response/Fixtures/SendResponseModel+Fixtures.swift` | Test fixtures |
| `Core/Tools/Extensions/TestHelpers/BitwardenSdk+ToolsFixtures.swift` | SDK type fixtures |
| `Core/Tools/Repositories/SendRepositoryTests.swift` | Test updates |
| `Core/Tools/Services/API/FileAPIServiceTests.swift` | Test updates |
| `Core/Tools/Services/API/SendAPIServiceTests.swift` | Test updates |
| `Core/Tools/Utilities/CXFCredentialsResultBuilder.swift` | New: credential exchange builder |
| `UI/Tools/ExportCXF/ExportCXFRoute.swift` | New export route |
| `UI/Tools/ImportCXF/ImportCXF/ImportCXFState.swift` | Import state |
| `UI/Tools/ImportCXF/ImportCXFRoute.swift` | Import route |
| `UI/Tools/PreviewContent/SendView+Fixtures.swift` | Preview fixtures |
| `UI/Tools/Send/SendItem/AddEditSendItem/AddEditSendItemAction.swift` | Send item actions |
| `UI/Tools/Send/SendItem/AddEditSendItem/AddEditSendItemEffect.swift` | Send item effects |
| `UI/Tools/Send/SendItem/AddEditSendItem/AddEditSendItemProcessor.swift` | Send item processor |
| `UI/Tools/Send/SendItem/AddEditSendItem/AddEditSendItemProcessorTests.swift` | Tests |
| `UI/Tools/Send/SendItem/AddEditSendItem/AddEditSendItemState.swift` | Send item state |
| `UI/Tools/Send/SendItem/AddEditSendItem/AddEditSendItemStateTests.swift` | Tests |
| `UI/Tools/Send/SendItem/AddEditSendItem/AddEditSendItemView+ViewInspectorTests.swift` | View tests |
| `UI/Tools/Send/SendItem/AddEditSendItem/AddEditSendItemView.swift` | View |
| `UI/Tools/Send/SendItem/SendItemCoordinator.swift` | Coordinator |
| `UI/Tools/Send/SendItem/SendItemCoordinatorTests.swift` | Tests |
| `UI/Tools/Send/SendItem/SendItemRoute.swift` | Routes |

#### Platform Domain

| File | Change |
|------|--------|
| `Core/Platform/Services/StateServiceTests.swift` | Test updates |
| `Core/Platform/Utilities/ServerVersionTests.swift` | Test updates |
| `UI/Platform/Application/AppProcessorTests.swift` | Test updates |
| `UI/Platform/Application/Utilities/PendingAppIntentActionMediatorTests.swift` | Test updates |
| `UI/Platform/Settings/Settings/AccountSecurity/AccountSecurityProcessorTests.swift` | Test updates |
| `UI/Platform/Settings/Settings/AccountSecurity/DeleteAccount/DeleteAccountProcessorTests.swift` | Test updates |

#### Authenticator App

| File | Change |
|------|--------|
| `AuthenticatorShared/Core/Auth/Services/TestHelpers/MockClientFido2Authenticator.swift` | SDK changes |
| `AuthenticatorShared/Core/Auth/Services/TestHelpers/MockClientFido2Client.swift` | SDK changes |
| `AuthenticatorShared/Core/Auth/Services/TestHelpers/MockPlatformClientService.swift` | SDK changes |
| `AuthenticatorShared/Core/Vault/Services/Importers/Support/Base32.swift` | Minor changes |
| `AuthenticatorShared/Core/Vault/Services/TOTP/OTPAuthModelTests.swift` | Test updates |
| `AuthenticatorShared/UI/Platform/Tutorial/Tutorial/TutorialProcessor.swift` | Minor changes |
| `AuthenticatorShared/UI/Vault/VaultItem/AuthenticatorKeyCapture/CameraPreviewView.swift` | Minor changes |
| `AuthenticatorShared/UI/Vault/VaultItem/AuthenticatorKeyCapture/ScanCodeProcessor.swift` | Minor changes |

#### BitwardenKit Framework

| File | Change |
|------|--------|
| `BitwardenKit/Core/Platform/Models/Domain/EnvironmentURLDataTests.swift` | Test updates |
| `BitwardenKit/Core/Platform/Services/API/Extensions/JSONDecoderBitwardenTests.swift` | Test updates |
| `BitwardenKit/Core/Platform/Services/FlightRecorder.swift` | Minor changes |
| `BitwardenKit/Core/Platform/Services/FlightRecorderTests.swift` | Test updates |
| `BitwardenKit/Core/Platform/Utilities/StackNavigator.swift` | Minor changes |
| `BitwardenKit/UI/Platform/Application/Extensions/View+Toolbar.swift` | Minor changes |
| `BitwardenKit/UI/Platform/Application/Views/AccessoryButton.swift` | Minor changes |
| `BitwardenKit/UI/Platform/Application/Views/BitwardenMenuField.swift` | Minor changes |

#### Vault UI Domain (Not Offline Sync)

| File | Change |
|------|--------|
| `UI/Vault/Helpers/TextAutofillHelperFactory.swift` | Minor changes |
| `UI/Vault/Helpers/TextAutofillHelperTests.swift` | Test updates |
| `UI/Vault/Helpers/TextAutofillOptionsHelper/IdentityTextAutofillOptionsHelperTests.swift` | Test updates |
| `UI/Vault/Helpers/TextAutofillOptionsHelper/SSHKeyTextAutofillOptionsHelperTests.swift` | Test updates |
| `UI/Vault/Vault/AutofillList/VaultAutofillListEffect.swift` | Minor changes |
| `UI/Vault/Vault/AutofillList/VaultAutofillListProcessor+Fido2Tests.swift` | Test updates |
| `UI/Vault/Vault/AutofillList/VaultAutofillListProcessor+TotpTests.swift` | Test updates |
| `UI/Vault/Vault/AutofillList/VaultAutofillListProcessor.swift` | Minor changes |
| `UI/Vault/Vault/AutofillList/VaultAutofillListView.swift` | Minor changes |
| `UI/Vault/VaultItem/AddEditItem/AddEditItemProcessorTests.swift` | Test updates |
| `UI/Vault/VaultItem/AuthenticatorKeyCapture/CameraPreviewView.swift` | Minor changes |
| `UI/Vault/VaultItem/AuthenticatorKeyCapture/ManualEntryProcessor.swift` | Minor changes |
| `UI/Vault/VaultItem/AuthenticatorKeyCapture/ScanCodeProcessor.swift` | Minor changes |
| `UI/Vault/VaultItem/CipherItemState+HeaderTests.swift` | Test updates |

### Category 4: CI/Build Changes

| File | Change |
|------|--------|
| `.github/workflows/build-test-package-simulator.yml` | CI configuration |
| `.github/workflows/test-bwa.yml` | CI configuration |
| `.github/workflows/test.yml` | CI configuration |
| `.github/PULL_REQUEST_TEMPLATE.md` | Template update |
| `.github/renovate.json` | Dependency management |
| `Configs/Common-bwa.xcconfig` | Build configuration |
| `Configs/Common-bwpm.xcconfig` | Build configuration |
| `Configs/Common-bwth.xcconfig` | Build configuration |
| `Scripts/setup-hooks.sh` | Git hooks setup |
| `project-common.yml` | Project configuration |

### Category 5: Localization

| File | Change |
|------|--------|
| `BitwardenResources/Localizations/en.lproj/Localizable.strings` | New strings |
| `BitwardenResources/Localizations/cs.lproj/Localizable.strings` | Translations |
| `BitwardenResources/Localizations/it.lproj/Localizable.strings` | Translations |
| `BitwardenResources/Localizations/it.lproj/Localizable.stringsdict` | Translations |
| `BitwardenResources/Localizations/pl.lproj/Localizable.strings` | Translations |
| `BitwardenResources/Localizations/tr.lproj/Localizable.strings` | Translations |

### Category 6: Other Data Files

| File | Change |
|------|--------|
| `BitwardenKit/Core/Platform/Utilities/Resources/public_suffix_list.dat` | Updated list |

## New External Dependencies

**No new external libraries or dependencies are introduced by the offline sync feature.** All new functionality uses existing project dependencies:
- Core Data (Apple framework, already used)
- BitwardenSdk (already a project dependency)
- OSLog (Apple framework, already used)

The `Package.resolved` changes reflect SDK version updates from upstream, not offline sync additions.

## Impact of Upstream Changes on Review

The upstream changes are significant in volume (~100+ files) but are orthogonal to the offline sync feature. They don't interact with the offline sync code paths. The key upstream changes that could potentially affect offline sync are:

1. **SDK API changes** (`.authenticator` → `.vaultAuthenticator`): These don't affect cipher operations used by offline sync.
2. **`CipherPermissionsModel` changes**: Could affect how permissions are handled, but the offline sync code doesn't directly use permissions.
3. **`ExportVaultService` rename**: The `DefultExportVaultService` → `DefaultExportVaultService` fix was included in the offline sync commits, suggesting it was noticed and fixed during offline sync development.

### Category 7: Previous Review Documentation

The `_OfflineSyncDocs/` directory contains documentation from prior review iterations:

| File/Directory | Content |
|----------------|---------|
| `_OfflineSyncDocs/OfflineSyncPlan.md` | Original feature plan |
| `_OfflineSyncDocs/OfflineSyncCodeReview.md` | First code review |
| `_OfflineSyncDocs/OfflineSyncCodeReview_Phase2.md` | Phase 2 review |
| `_OfflineSyncDocs/OfflineSyncChangelog.md` | Change history |
| `_OfflineSyncDocs/ReviewSection_*.md` | Section-by-section reviews |
| `_OfflineSyncDocs/ActionPlans/` | Action plans from reviews |
| `_OfflineSyncDocs/ActionPlans/Resolved/` | Resolved action items |
| `_OfflineSyncDocs/ActionPlans/Superseded/` | Superseded items |

These are documentation artifacts and don't affect the codebase. The current Review2 supersedes all prior review documents.

## Summary

The offline sync feature introduces **no new external dependencies**. The upstream changes are standard ongoing development and do not interfere with the offline sync implementation. Approximately 60% of the changed files in the diff are upstream changes, and 40% are offline sync specific.

### Complete Upstream File Count by Category

| Category | File Count |
|----------|-----------|
| Typo/spelling fixes | ~20 |
| SDK API changes | ~10 |
| Feature changes & test updates | ~55 |
| CI/build configuration | ~8 |
| Localization | ~6 |
| Other data files | ~2 |
| Previous review documentation | ~25 |
| **Total upstream/incidental** | **~126** |
