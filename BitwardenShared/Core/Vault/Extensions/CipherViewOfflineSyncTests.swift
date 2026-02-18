import BitwardenSdk
import XCTest

@testable import BitwardenShared

// MARK: - CipherViewOfflineSyncTests

class CipherViewOfflineSyncTests: BitwardenTestCase {
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
            folderId: "folder-1",
            id: nil,
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

    // MARK: Tests - CipherView.update(name:)

    /// `update(name:)` sets the new name and preserves the original folder ID.
    func test_update_setsNameAndPreservesFolderId() {
        let original = CipherView.fixture(
            folderId: "original-folder",
            name: "Old Name"
        )

        let updated = original.update(name: "Conflict Copy")

        XCTAssertEqual(updated.name, "Conflict Copy")
        XCTAssertEqual(updated.folderId, "original-folder")
    }

    /// `update(name:)` sets the `id` to `nil` since it represents a new cipher.
    func test_update_setsIdToNil() {
        let original = CipherView.fixture(id: "existing-id")

        let updated = original.update(name: "Copy")

        XCTAssertNil(updated.id)
    }

    /// `update(name:)` sets the `key` to `nil` so the SDK assigns a new key.
    func test_update_setsKeyToNil() {
        let original = CipherView.fixture(key: "existing-key")

        let updated = original.update(name: "Copy")

        XCTAssertNil(updated.key)
    }

    /// `update(name:)` sets `attachments` to `nil` since attachments
    /// are not duplicated to backup copies.
    func test_update_setsAttachmentsToNil() {
        let original = CipherView.fixture(
            attachments: [AttachmentView.fixture(id: "att-1")]
        )

        let updated = original.update(name: "Copy")

        XCTAssertNil(updated.attachments)
    }

    /// `update(name:)` preserves the password history from the original cipher.
    func test_update_preservesPasswordHistory() {
        let history = [
            PasswordHistoryView.fixture(password: "old-pass-1"),
            PasswordHistoryView.fixture(password: "old-pass-2"),
        ]
        let original = CipherView.fixture(passwordHistory: history)

        let updated = original.update(name: "Copy")

        XCTAssertEqual(updated.passwordHistory?.count, 2)
        XCTAssertEqual(updated.passwordHistory?[0].password, "old-pass-1")
        XCTAssertEqual(updated.passwordHistory?[1].password, "old-pass-2")
    }
}
