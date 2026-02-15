import BitwardenKit
import BitwardenKitMocks
import BitwardenResources
import BitwardenSdk
import Combine
import TestHelpers
import XCTest

@testable import BitwardenShared
@testable import BitwardenSharedMocks

// MARK: - ViewItemProcessorOfflineInvestigationTests

/// Investigation tests for the ViewItemProcessor behavior with offline-created ciphers.
///
/// These tests examine how the detail view processor handles ciphers that were created
/// offline with temporary IDs, specifically investigating the spinner bug where the
/// detail view stays in `.loading(nil)` state indefinitely.
///
/// ## Key Investigation Points
///
/// 1. Does the publisher stream correctly emit an offline cipher with a temp ID?
/// 2. Does `buildViewItemState` succeed or return nil for offline ciphers?
/// 3. Does the fallback path (`fetchCipherDetailsDirectly`) work for offline ciphers?
/// 4. What happens when the publisher emits a cipher whose decrypt returns nil ID?
///
class ViewItemProcessorOfflineInvestigationTests: BitwardenTestCase {
    // MARK: Properties

    var authRepository: MockAuthRepository!
    var configService: MockConfigService!
    var coordinator: MockCoordinator<VaultItemRoute, VaultItemEvent>!
    var delegate: MockCipherItemOperationDelegate!
    var errorReporter: MockErrorReporter!
    var eventService: MockEventService!
    var pasteboardService: MockPasteboardService!
    var rehydrationHelper: MockRehydrationHelper!
    var stateService: MockStateService!
    var subject: ViewItemProcessor!
    var vaultItemActionHelper: MockVaultItemActionHelper!
    var vaultRepository: MockVaultRepository!

    // MARK: Setup & Teardown

    override func setUp() {
        super.setUp()
        authRepository = MockAuthRepository()
        configService = MockConfigService()
        coordinator = MockCoordinator<VaultItemRoute, VaultItemEvent>()
        delegate = MockCipherItemOperationDelegate()
        errorReporter = MockErrorReporter()
        eventService = MockEventService()
        pasteboardService = MockPasteboardService()
        rehydrationHelper = MockRehydrationHelper()
        stateService = MockStateService()
        vaultItemActionHelper = MockVaultItemActionHelper()
        vaultRepository = MockVaultRepository()
    }

    override func tearDown() {
        super.tearDown()
        authRepository = nil
        configService = nil
        coordinator = nil
        delegate = nil
        errorReporter = nil
        eventService = nil
        pasteboardService = nil
        rehydrationHelper = nil
        stateService = nil
        subject = nil
        vaultItemActionHelper = nil
        vaultRepository = nil
    }

    // MARK: Helpers

    /// Creates a ViewItemProcessor configured with the given item ID.
    private func createSubject(itemId: String) {
        let services = ServiceContainer.withMocks(
            authRepository: authRepository,
            configService: configService,
            errorReporter: errorReporter,
            eventService: eventService,
            pasteboardService: pasteboardService,
            rehydrationHelper: rehydrationHelper,
            stateService: stateService,
            vaultRepository: vaultRepository
        )
        subject = ViewItemProcessor(
            coordinator: coordinator.asAnyCoordinator(),
            delegate: delegate,
            itemId: itemId,
            services: services,
            state: ViewItemState(),
            vaultItemActionHelper: vaultItemActionHelper
        )
    }

    // MARK: Tests - Publisher Stream with Offline Cipher

    /// When the `cipherDetailsPublisher` emits a cipher with a valid temp ID,
    /// the processor should transition from `.loading(nil)` to `.data(...)`.
    @MainActor
    func test_appeared_offlineCipherWithTempId_transitionsToData() {
        let tempId = UUID().uuidString
        createSubject(itemId: tempId)

        let offlineCipher = CipherView.fixture(
            id: tempId,
            login: LoginView(
                username: "user@example.com",
                password: "password",
                passwordRevisionDate: nil,
                uris: nil,
                totp: nil,
                autofillOnPageLoad: nil,
                fido2Credentials: nil
            ),
            name: "Offline Login"
        )
        vaultRepository.cipherDetailsSubject.send(offlineCipher)
        vaultRepository.fetchCollectionsResult = .success([])

        let task = Task {
            await subject.perform(.appeared)
        }

        waitFor(subject.state.loadingState != .loading(nil))
        task.cancel()

        guard case let .data(cipherState) = subject.state.loadingState else {
            XCTFail(
                "INVESTIGATION: Expected .data state but got \(subject.state.loadingState). "
                    + "If this is .loading(nil), the buildViewItemState returned nil, "
                    + "likely because CipherView.id was nil after decryption."
            )
            return
        }

        XCTAssertEqual(cipherState.name, "Offline Login")
    }

    /// When the `cipherDetailsPublisher` emits a cipher with nil ID,
    /// `buildViewItemState` returns nil and the state remains `.loading(nil)`.
    /// The stream continues with `guard let cipher else { continue }` and the
    /// `if let newState = ... { state = newState }` check, causing the spinner.
    @MainActor
    func test_appeared_cipherWithNilId_staysInLoadingState() {
        let tempId = UUID().uuidString
        createSubject(itemId: tempId)

        // Simulate: publisher emits a cipher view with nil ID
        // (This would happen if the SDK decrypt strips the ID)
        let cipherWithNilId = CipherView.fixture(
            id: nil,
            name: "Cipher With Nil ID"
        )
        vaultRepository.cipherDetailsSubject.send(cipherWithNilId)
        vaultRepository.fetchCollectionsResult = .success([])

        let task = Task {
            await subject.perform(.appeared)
        }

        // Wait briefly to see if state transitions.
        // Since ViewItemState init returns nil for nil ID, and the processor does
        // `if let newState = try await buildViewItemState(from: cipher) { state = newState }`,
        // the state should remain .loading(nil) - the spinner bug.
        waitFor(
            { subject.state.loadingState != .loading(nil) },
            timeout: 1
        )
        task.cancel()

        // INVESTIGATION: Document the actual behavior
        switch subject.state.loadingState {
        case .loading:
            // This confirms the spinner bug mechanism:
            // nil ID -> CipherItemState returns nil -> ViewItemState returns nil
            // -> buildViewItemState returns nil -> state stays .loading(nil)
            break // Expected: this IS the spinner bug
        case .data:
            XCTFail("Unexpected: state transitioned to .data despite nil ID cipher")
        case .error:
            // Also acceptable: if an error was set by the fallback path
            break
        }
    }

    /// When the publisher stream fails (throws), the processor should fall back to
    /// `fetchCipherDetailsDirectly`. If the direct fetch returns a cipher with valid
    /// temp ID, the state should transition to `.data`.
    @MainActor
    func test_appeared_publisherFails_fallbackWithTempId_transitionsToData() {
        let tempId = UUID().uuidString
        createSubject(itemId: tempId)

        let offlineCipher = CipherView.fixture(
            id: tempId,
            login: LoginView(
                username: "user@example.com",
                password: "password",
                passwordRevisionDate: nil,
                uris: nil,
                totp: nil,
                autofillOnPageLoad: nil,
                fido2Credentials: nil
            ),
            name: "Offline Fallback"
        )
        vaultRepository.fetchCipherResult = .success(offlineCipher)
        vaultRepository.fetchCollectionsResult = .success([])

        // Make the publisher stream fail to trigger the fallback
        vaultRepository.cipherDetailsSubject.send(
            completion: .failure(BitwardenTestError.example)
        )

        let task = Task {
            await subject.perform(.appeared)
        }

        waitFor(subject.state.loadingState != .loading(nil))
        task.cancel()

        guard case let .data(cipherState) = subject.state.loadingState else {
            XCTFail(
                "INVESTIGATION: Expected .data state from fallback but got "
                    + "\(subject.state.loadingState). The fallback path should have "
                    + "loaded the offline cipher successfully."
            )
            return
        }

        XCTAssertEqual(cipherState.name, "Offline Fallback")
        XCTAssertEqual(vaultRepository.fetchCipherId, tempId)
    }

    /// When the publisher stream fails and the fallback returns a cipher with nil ID,
    /// the state should transition to `.error` (not stay in `.loading(nil)`).
    @MainActor
    func test_appeared_publisherFails_fallbackNilId_transitionsToError() {
        let tempId = UUID().uuidString
        createSubject(itemId: tempId)

        // Fallback returns a cipher with nil ID
        let cipherWithNilId = CipherView.fixture(
            id: nil,
            name: "Nil ID Fallback"
        )
        vaultRepository.fetchCipherResult = .success(cipherWithNilId)
        vaultRepository.fetchCollectionsResult = .success([])

        // Make the publisher stream fail to trigger the fallback
        vaultRepository.cipherDetailsSubject.send(
            completion: .failure(BitwardenTestError.example)
        )

        let task = Task {
            await subject.perform(.appeared)
        }

        waitFor(subject.state.loadingState != .loading(nil))
        task.cancel()

        XCTAssertEqual(
            subject.state.loadingState,
            .error(errorMessage: Localizations.anErrorHasOccurred),
            "INVESTIGATION: When fallback returns nil-ID cipher, ViewItemState returns nil, "
                + "so fetchCipherDetailsDirectly should set .error state."
        )
    }

    /// When the publisher stream fails and the fallback also returns nil (cipher not found),
    /// the state should transition to `.error`.
    @MainActor
    func test_appeared_publisherFails_fallbackReturnsNil_transitionsToError() {
        let tempId = UUID().uuidString
        createSubject(itemId: tempId)

        vaultRepository.fetchCipherResult = .success(nil)

        // Make the publisher stream fail
        vaultRepository.cipherDetailsSubject.send(
            completion: .failure(BitwardenTestError.example)
        )

        let task = Task {
            await subject.perform(.appeared)
        }

        waitFor(subject.state.loadingState != .loading(nil))
        task.cancel()

        XCTAssertEqual(
            subject.state.loadingState,
            .error(errorMessage: Localizations.anErrorHasOccurred),
            "Should show error when cipher is not found"
        )
    }

    // MARK: Tests - Verifying the Publisher Filtering

    /// The `cipherDetailsPublisher` filters ciphers by ID:
    /// `ciphers.first(where: { $0.id == id })`.
    /// Verify that when using the mock, a cipher with temp ID is correctly
    /// emitted when queried with that temp ID.
    @MainActor
    func test_cipherDetailsPublisher_emitsOfflineCipherByTempId() {
        let tempId = UUID().uuidString
        createSubject(itemId: tempId)

        let offlineCipher = CipherView.fixture(id: tempId, name: "Found By Temp ID")
        vaultRepository.cipherDetailsSubject.send(offlineCipher)
        vaultRepository.fetchCollectionsResult = .success([])

        let task = Task {
            await subject.perform(.appeared)
        }

        waitFor(subject.state.loadingState != .loading(nil))
        task.cancel()

        guard case let .data(state) = subject.state.loadingState else {
            XCTFail("Expected .data state")
            return
        }

        XCTAssertEqual(
            state.name,
            "Found By Temp ID",
            "Publisher should emit and processor should display the offline cipher"
        )
    }

    // MARK: Tests - Multiple Ciphers (Duplicate Scenario)

    /// When the publisher emits an updated cipher (e.g., after resolveCreate creates
    /// a new server-ID cipher), the detail view should update to show the new data.
    @MainActor
    func test_appeared_publisherEmitsUpdate_stateUpdates() {
        let tempId = UUID().uuidString
        createSubject(itemId: tempId)

        // Initial emission: offline cipher with temp ID
        let offlineCipher = CipherView.fixture(id: tempId, name: "Original Name")
        vaultRepository.cipherDetailsSubject.send(offlineCipher)
        vaultRepository.fetchCollectionsResult = .success([])

        let task = Task {
            await subject.perform(.appeared)
        }

        waitFor(subject.state.loadingState != .loading(nil))

        guard case let .data(initialState) = subject.state.loadingState else {
            task.cancel()
            XCTFail("Expected .data state after initial emission")
            return
        }
        XCTAssertEqual(initialState.name, "Original Name")

        // Simulate: cipher is updated (e.g., user edits while still offline)
        let updatedCipher = CipherView.fixture(id: tempId, name: "Updated Name")
        vaultRepository.cipherDetailsSubject.send(updatedCipher)

        waitFor {
            if case let .data(state) = subject.state.loadingState {
                return state.name == "Updated Name"
            }
            return false
        }

        task.cancel()

        guard case let .data(updatedState) = subject.state.loadingState else {
            XCTFail("Expected .data state after update emission")
            return
        }
        XCTAssertEqual(updatedState.name, "Updated Name")
    }
}
