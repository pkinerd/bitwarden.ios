import BitwardenSdk
import Foundation

// MARK: - Cipher + OfflineSync

extension Cipher {
    /// Returns a copy of the cipher with a temporary client-generated ID.
    ///
    /// Used when persisting a newly created cipher locally during offline mode.
    /// The temporary ID allows Core Data storage; the server will assign
    /// the real ID when the pending change is resolved.
    ///
    /// - Parameter id: The temporary ID to assign.
    /// - Returns: A copy of the cipher with the specified ID.
    ///
    func withTemporaryId(_ id: String) -> Cipher {
        Cipher(
            id: id,
            organizationId: organizationId,
            folderId: folderId,
            collectionIds: collectionIds,
            key: key,
            name: name,
            notes: notes,
            type: type,
            login: login,
            identity: identity,
            card: card,
            secureNote: secureNote,
            sshKey: sshKey,
            favorite: favorite,
            reprompt: reprompt,
            organizationUseTotp: organizationUseTotp,
            edit: edit,
            permissions: permissions,
            viewPassword: viewPassword,
            localData: localData,
            attachments: attachments,
            fields: fields,
            passwordHistory: passwordHistory,
            creationDate: creationDate,
            deletedDate: deletedDate,
            revisionDate: revisionDate,
            archivedDate: archivedDate,
            data: nil
        )
    }
}

// MARK: - CipherView + OfflineSync

extension CipherView {
    /// Returns a copy of the cipher view with the specified ID.
    ///
    /// Used to ensure the decrypted `CipherView` retains the cipher's ID after
    /// SDK decryption. The ID is not an encrypted field, but may not be populated
    /// by the SDK's `decrypt(cipher:)` output. This preserves the ID from the
    /// encrypted `Cipher` so that downstream consumers (e.g., `CipherItemState`)
    /// can rely on a non-nil ID.
    ///
    /// - Parameter id: The ID to assign.
    /// - Returns: A copy of the cipher view with the specified ID.
    ///
    func withId(_ id: String) -> CipherView {
        CipherView(
            id: id,
            organizationId: organizationId,
            folderId: folderId,
            collectionIds: collectionIds,
            key: key,
            name: name,
            notes: notes,
            type: type,
            login: login,
            identity: identity,
            card: card,
            secureNote: secureNote,
            sshKey: sshKey,
            favorite: favorite,
            reprompt: reprompt,
            organizationUseTotp: organizationUseTotp,
            edit: edit,
            permissions: permissions,
            viewPassword: viewPassword,
            localData: localData,
            attachments: attachments,
            attachmentDecryptionFailures: attachmentDecryptionFailures,
            fields: fields,
            passwordHistory: passwordHistory,
            creationDate: creationDate,
            deletedDate: deletedDate,
            revisionDate: revisionDate,
            archivedDate: archivedDate
        )
    }

    /// Returns a copy of the cipher with updated name and folder ID.
    ///
    /// Used by the offline sync resolver to create backup copies of conflicting ciphers
    /// with a modified name and assigned to the conflict folder.
    ///
    /// - Parameters:
    ///   - name: The new name for the cipher.
    ///   - folderId: The folder ID to assign the cipher to.
    /// - Returns: A copy of the cipher with the updated name and folder ID.
    ///
    func update(name: String, folderId: String?) -> CipherView {
        CipherView(
            id: nil, // New cipher, no ID
            organizationId: organizationId,
            folderId: folderId,
            collectionIds: collectionIds,
            key: nil, // New cipher gets its own key from the SDK
            name: name,
            notes: notes,
            type: type,
            login: login,
            identity: identity,
            card: card,
            secureNote: secureNote,
            sshKey: sshKey,
            favorite: favorite,
            reprompt: reprompt,
            organizationUseTotp: organizationUseTotp,
            edit: edit,
            permissions: permissions,
            viewPassword: viewPassword,
            localData: localData,
            attachments: nil, // Attachments are not duplicated to backup copies
            attachmentDecryptionFailures: nil,
            fields: fields,
            passwordHistory: passwordHistory,
            creationDate: creationDate,
            deletedDate: deletedDate,
            revisionDate: revisionDate,
            archivedDate: archivedDate
        )
    }
}
