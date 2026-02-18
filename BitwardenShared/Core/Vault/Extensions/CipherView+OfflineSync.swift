import BitwardenSdk
import Foundation

// MARK: - CipherView + OfflineSync

extension CipherView {
    /// Returns a copy of the cipher view with the specified ID.
    ///
    /// Used to assign a temporary client-generated ID to a new cipher view before
    /// encryption for offline support. The ID is baked into the encrypted content
    /// so it survives the decrypt round-trip without special handling.
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

    /// Returns a copy of the cipher with an updated name.
    ///
    /// Used by the offline sync resolver to create backup copies of conflicting ciphers
    /// with a modified name. The backup retains the original cipher's folder assignment.
    ///
    /// - Parameter name: The new name for the cipher.
    /// - Returns: A copy of the cipher with the updated name.
    ///
    func update(name: String) -> CipherView {
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
