import BitwardenSdk
import XCTest

@testable import BitwardenShared

// MARK: - CipherViewOfflineSyncTests

class CipherViewOfflineSyncTests: BitwardenTestCase {
    // MARK: Tests - Cipher.withTemporaryId

    /// `withTemporaryId(_:)` returns a cipher with the new temporary ID set.
    func test_withTemporaryId_setsNewId() {
        let cipher = Cipher.fixture(id: "original-id", name: "Test Cipher")
        let result = cipher.withTemporaryId("temp-id-123")
        XCTAssertEqual(result.id, "temp-id-123")
    }

    /// `withTemporaryId(_:)` preserves all other properties of the cipher.
    func test_withTemporaryId_preservesOtherProperties() {
        let cipher = Cipher.fixture(
            attachments: nil,
            card: nil,
            collectionIds: ["col-1", "col-2"],
            creationDate: Date(year: 2024, month: 3, day: 15),
            edit: true,
            favorite: true,
            folderId: "folder-1",
            id: "original-id",
            key: "encryption-key",
            login: Login(
                username: "user@example.com",
                password: nil,
                passwordRevisionDate: nil,
                uris: nil,
                totp: "totp-secret",
                autofillOnPageLoad: nil,
                fido2Credentials: nil
            ),
            name: "My Login",
            notes: "Some notes",
            organizationId: "org-1",
            organizationUseTotp: true,
            passwordHistory: [PasswordHistory(password: "old-pw", lastUsedDate: Date())],
            reprompt: .password,
            revisionDate: Date(year: 2024, month: 6, day: 1),
            type: .login,
            viewPassword: false
        )

        let result = cipher.withTemporaryId("temp-id")

        XCTAssertEqual(result.id, "temp-id")
        XCTAssertEqual(result.organizationId, cipher.organizationId)
        XCTAssertEqual(result.folderId, cipher.folderId)
        XCTAssertEqual(result.collectionIds, cipher.collectionIds)
        XCTAssertEqual(result.key, cipher.key)
        XCTAssertEqual(result.name, cipher.name)
        XCTAssertEqual(result.notes, cipher.notes)
        XCTAssertEqual(result.type, cipher.type)
        XCTAssertEqual(result.favorite, cipher.favorite)
        XCTAssertEqual(result.reprompt, cipher.reprompt)
        XCTAssertEqual(result.organizationUseTotp, cipher.organizationUseTotp)
        XCTAssertEqual(result.edit, cipher.edit)
        XCTAssertEqual(result.viewPassword, cipher.viewPassword)
        XCTAssertEqual(result.creationDate, cipher.creationDate)
        XCTAssertEqual(result.revisionDate, cipher.revisionDate)
    }

    // MARK: Tests - CipherView.withId

    /// `withId(_:)` returns a cipher view with the specified ID.
    func test_withId_setsId() {
        let original = CipherView.fixture(id: nil, name: "No ID Cipher")

        let result = original.withId("temp-id-123")

        XCTAssertEqual(result.id, "temp-id-123")
    }

    /// `withId(_:)` preserves all other properties of the cipher view.
    func test_withId_preservesOtherProperties() {
        let original = CipherView.fixture(
            id: nil,
            folderId: "folder-1",
            login: LoginView(
                username: "user@example.com",
                password: "password123",
                passwordRevisionDate: nil,
                uris: nil,
                totp: "totp-secret",
                autofillOnPageLoad: nil,
                fido2Credentials: nil
            ),
            name: "My Login",
            notes: "Notes here",
            organizationId: "org-1"
        )

        let result = original.withId("assigned-id")

        XCTAssertEqual(result.id, "assigned-id")
        XCTAssertEqual(result.name, original.name)
        XCTAssertEqual(result.notes, original.notes)
        XCTAssertEqual(result.folderId, original.folderId)
        XCTAssertEqual(result.organizationId, original.organizationId)
        XCTAssertEqual(result.login?.username, "user@example.com")
        XCTAssertEqual(result.login?.password, "password123")
        XCTAssertEqual(result.login?.totp, "totp-secret")
    }

    /// `withId(_:)` can replace an existing ID.
    func test_withId_replacesExistingId() {
        let original = CipherView.fixture(id: "old-id", name: "Cipher")

        let result = original.withId("new-id")

        XCTAssertEqual(result.id, "new-id")
    }

    // MARK: Tests - CipherView.update(name:folderId:)

    /// `update(name:folderId:)` sets the new name and folder ID on the returned cipher view.
    func test_update_setsNameAndFolderId() {
        let original = CipherView.fixture(
            folderId: "old-folder",
            name: "Old Name"
        )

        let updated = original.update(name: "Conflict Copy", folderId: "conflict-folder")

        XCTAssertEqual(updated.name, "Conflict Copy")
        XCTAssertEqual(updated.folderId, "conflict-folder")
    }

    /// `update(name:folderId:)` sets the `id` to `nil` since it represents a new cipher.
    func test_update_setsIdToNil() {
        let original = CipherView.fixture(id: "existing-id")

        let updated = original.update(name: "Copy", folderId: nil)

        XCTAssertNil(updated.id)
    }

    /// `update(name:folderId:)` sets the `key` to `nil` so the SDK assigns a new key.
    func test_update_setsKeyToNil() {
        let original = CipherView.fixture(key: "existing-key")

        let updated = original.update(name: "Copy", folderId: nil)

        XCTAssertNil(updated.key)
    }

    /// `update(name:folderId:)` sets `attachments` to `nil` since attachments
    /// are not duplicated to backup copies.
    func test_update_setsAttachmentsToNil() {
        let original = CipherView.fixture(
            attachments: [AttachmentView.fixture(id: "att-1")]
        )

        let updated = original.update(name: "Copy", folderId: nil)

        XCTAssertNil(updated.attachments)
    }

    /// `update(name:folderId:)` preserves the password history from the original cipher.
    func test_update_preservesPasswordHistory() {
        let history = [
            PasswordHistoryView.fixture(password: "old-pass-1"),
            PasswordHistoryView.fixture(password: "old-pass-2"),
        ]
        let original = CipherView.fixture(passwordHistory: history)

        let updated = original.update(name: "Copy", folderId: nil)

        XCTAssertEqual(updated.passwordHistory?.count, 2)
        XCTAssertEqual(updated.passwordHistory?[0].password, "old-pass-1")
        XCTAssertEqual(updated.passwordHistory?[1].password, "old-pass-2")
    }
}
