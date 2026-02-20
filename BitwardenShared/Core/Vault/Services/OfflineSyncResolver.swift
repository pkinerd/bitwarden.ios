import BitwardenSdk
import Foundation
import OSLog

// MARK: - OfflineSyncError

/// Errors that can occur during offline sync resolution.
///
enum OfflineSyncError: LocalizedError, Equatable {
    /// The pending change record has no cipher data.
    case missingCipherData

    /// The pending change record has no cipher ID.
    case missingCipherId

    /// The vault is locked; sync resolution cannot proceed without an active crypto context.
    case vaultLocked

    /// The cipher was not found on the server (HTTP 404).
    case cipherNotFound

    var errorDescription: String? {
        switch self {
        case .missingCipherData:
            "The pending change record is missing cipher data."
        case .missingCipherId:
            "The pending change record is missing a cipher ID."
        case .vaultLocked:
            "The vault is locked. Please unlock to sync offline changes."
        case .cipherNotFound:
            "The cipher was not found on the server."
        }
    }
}

// MARK: - OfflineSyncResolver

/// A protocol for a service that resolves pending offline cipher changes against server state.
///
protocol OfflineSyncResolver {
    /// Processes all pending changes for the active user.
    ///
    /// This method fetches all pending changes, resolves each one against the server state,
    /// and cleans up resolved records.
    ///
    /// - Parameter userId: The user ID whose pending changes should be processed.
    ///
    func processPendingChanges(userId: String) async throws
}

// MARK: - DefaultOfflineSyncResolver

/// A default implementation of `OfflineSyncResolver` that resolves pending cipher changes.
///
actor DefaultOfflineSyncResolver: OfflineSyncResolver {
    // MARK: Constants

    /// The minimum number of offline password changes that triggers a server backup
    /// even when no conflict is detected (soft conflict threshold).
    static let softConflictPasswordChangeThreshold: Int = 4

    // MARK: Properties

    /// The service for making cipher API requests.
    private let cipherAPIService: CipherAPIService

    /// The service for managing ciphers.
    private let cipherService: CipherService

    /// The client service for encryption/decryption.
    private let clientService: ClientService

    /// The data store for pending cipher changes.
    private let pendingCipherChangeDataStore: PendingCipherChangeDataStore

    // MARK: Initialization

    /// Initializes a `DefaultOfflineSyncResolver`.
    ///
    /// - Parameters:
    ///   - cipherAPIService: The service for making cipher API requests.
    ///   - cipherService: The service for managing ciphers.
    ///   - clientService: The client service for encryption/decryption.
    ///   - pendingCipherChangeDataStore: The data store for pending cipher changes.
    ///
    init(
        cipherAPIService: CipherAPIService,
        cipherService: CipherService,
        clientService: ClientService,
        pendingCipherChangeDataStore: PendingCipherChangeDataStore
    ) {
        self.cipherAPIService = cipherAPIService
        self.cipherService = cipherService
        self.clientService = clientService
        self.pendingCipherChangeDataStore = pendingCipherChangeDataStore
    }

    // MARK: OfflineSyncResolver

    func processPendingChanges(userId: String) async throws {
        let pendingChanges = try await pendingCipherChangeDataStore.fetchPendingChanges(userId: userId)
        guard !pendingChanges.isEmpty else { return }

        for pendingChange in pendingChanges {
            do {
                try await resolve(pendingChange: pendingChange, userId: userId)
            } catch {
                Logger.application.error(
                    "Failed to resolve pending change for cipher \(pendingChange.cipherId ?? "nil"): \(error)"
                )
            }
        }
    }

    // MARK: Private

    /// Resolves a single pending change against the server state.
    ///
    /// - Parameters:
    ///   - pendingChange: The pending change to resolve.
    ///   - userId: The user ID.
    ///
    private func resolve(pendingChange: PendingCipherChangeData, userId: String) async throws {
        guard let cipherId = pendingChange.cipherId else {
            throw OfflineSyncError.missingCipherId
        }

        switch pendingChange.changeType {
        case .create:
            try await resolveCreate(pendingChange: pendingChange, userId: userId)
        case .update:
            try await resolveUpdate(pendingChange: pendingChange, cipherId: cipherId, userId: userId)
        case .softDelete:
            try await resolveDelete(pendingChange: pendingChange, cipherId: cipherId, userId: userId, permanent: false)
        case .hardDelete:
            try await resolveDelete(pendingChange: pendingChange, cipherId: cipherId, userId: userId, permanent: true)
        }
    }

    /// Resolves a pending create (new item created offline).
    ///
    /// After successfully uploading the cipher to the server, this method deletes
    /// the old cipher record that used a temporary client-side ID. The server
    /// assigns a new ID, so `addCipherWithServer` creates a new `CipherData`
    /// record with the server ID. Without this cleanup step, the old temp-ID
    /// record would persist in Core Data until the next full sync.
    private func resolveCreate(pendingChange: PendingCipherChangeData, userId: String) async throws {
        guard let cipherData = pendingChange.cipherData else {
            throw OfflineSyncError.missingCipherData
        }

        let responseModel = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: cipherData)
        let cipher = Cipher(responseModel: responseModel)
        let tempId = cipher.id

        try await cipherService.addCipherWithServer(cipher, encryptedFor: userId)

        // Remove the old cipher record that used the temporary client-side ID.
        // `addCipherWithServer` upserts a new record with the server-assigned ID,
        // so the temp-ID record is now orphaned.
        if let tempId {
            try await cipherService.deleteCipherWithLocalStorage(id: tempId)
        }

        if let recordId = pendingChange.id {
            try await pendingCipherChangeDataStore.deletePendingChange(id: recordId)
        }
    }

    /// Resolves a pending update against the server state.
    private func resolveUpdate(
        pendingChange: PendingCipherChangeData,
        cipherId: String,
        userId: String
    ) async throws {
        guard let localCipherData = pendingChange.cipherData else {
            throw OfflineSyncError.missingCipherData
        }

        // Decode the local cipher first so it's available for the not-found fallback.
        let localResponseModel = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: localCipherData)
        let localCipher = Cipher(responseModel: localResponseModel)

        // Fetch the current server version.
        let serverCipher: Cipher
        do {
            let serverResponseModel = try await cipherAPIService.getCipher(withId: cipherId)
            serverCipher = Cipher(responseModel: serverResponseModel)
        } catch OfflineSyncError.cipherNotFound {
            // The cipher was deleted on the server while offline. Re-create it
            // to preserve the user's offline edits.
            try await cipherService.addCipherWithServer(localCipher, encryptedFor: userId)
            if let recordId = pendingChange.id {
                try await pendingCipherChangeDataStore.deletePendingChange(id: recordId)
            }
            return
        }

        let serverRevisionDate = serverCipher.revisionDate
        let originalRevisionDate = pendingChange.originalRevisionDate

        let hasConflict = originalRevisionDate != nil && serverRevisionDate != originalRevisionDate
        let hasSoftConflict = pendingChange.offlinePasswordChangeCount
            >= Self.softConflictPasswordChangeThreshold

        if hasConflict {
            try await resolveConflict(
                localCipher: localCipher,
                serverCipher: serverCipher,
                pendingChange: pendingChange,
                userId: userId
            )
        } else if hasSoftConflict {
            // No server-side changes, but 4+ offline password changes - backup server version
            // first to ensure it is preserved before pushing the local version.
            try await createBackupCipher(
                from: serverCipher,
                timestamp: serverRevisionDate,
                userId: userId
            )
            try await cipherService.updateCipherWithServer(localCipher, encryptedFor: userId)
        } else {
            // No conflict, 0-3 password changes - just push local version
            try await cipherService.updateCipherWithServer(localCipher, encryptedFor: userId)
        }

        if let recordId = pendingChange.id {
            try await pendingCipherChangeDataStore.deletePendingChange(id: recordId)
        }
    }

    /// Resolves a conflict between local and server versions.
    private func resolveConflict(
        localCipher: Cipher,
        serverCipher: Cipher,
        pendingChange: PendingCipherChangeData,
        userId: String
    ) async throws {
        let localTimestamp = pendingChange.updatedDate ?? pendingChange.createdDate ?? Date.distantPast
        let serverTimestamp = serverCipher.revisionDate

        if localTimestamp > serverTimestamp {
            // Local is newer - backup server version first, then push local.
            // Creating the backup before the push ensures the server's previous
            // version is preserved even if the push succeeds but a later step fails.
            try await createBackupCipher(
                from: serverCipher,
                timestamp: serverTimestamp,
                userId: userId
            )
            try await cipherService.updateCipherWithServer(localCipher, encryptedFor: userId)
        } else {
            // Server is newer - backup local version first, then update local storage.
            // Creating the backup before overwriting local storage ensures the local
            // version is preserved even if the local write succeeds but cleanup fails.
            try await createBackupCipher(
                from: localCipher,
                timestamp: localTimestamp,
                userId: userId
            )
            try await cipherService.updateCipherWithLocalStorage(serverCipher)
        }
    }

    /// Resolves a pending delete (soft or hard) against the server state.
    ///
    /// - Parameters:
    ///   - pendingChange: The pending change to resolve.
    ///   - cipherId: The cipher ID.
    ///   - userId: The user ID.
    ///   - permanent: Whether to permanently delete (`true`) or soft-delete (`false`).
    ///
    private func resolveDelete(
        pendingChange: PendingCipherChangeData,
        cipherId: String,
        userId: String,
        permanent: Bool
    ) async throws {
        // Check if the server version was modified while we were offline.
        let serverCipher: Cipher
        do {
            let serverResponseModel = try await cipherAPIService.getCipher(withId: cipherId)
            serverCipher = Cipher(responseModel: serverResponseModel)
        } catch OfflineSyncError.cipherNotFound {
            // The cipher is already gone on the server — the user's intent (delete)
            // is satisfied. Clean up the local record and pending change.
            try await cipherService.deleteCipherWithLocalStorage(id: cipherId)
            if let recordId = pendingChange.id {
                try await pendingCipherChangeDataStore.deletePendingChange(id: recordId)
            }
            return
        }

        let originalRevisionDate = pendingChange.originalRevisionDate
        let hasConflict = originalRevisionDate != nil && serverCipher.revisionDate != originalRevisionDate

        if hasConflict {
            // Server was modified while offline — restore the server version locally
            // and drop the pending delete so the user can review and re-decide.
            try await cipherService.updateCipherWithLocalStorage(serverCipher)
        } else {
            // No conflict — honor the original delete intent.
            if permanent {
                _ = try await cipherAPIService.deleteCipher(withID: cipherId)
            } else {
                _ = try await cipherAPIService.softDeleteCipher(withID: cipherId)
            }
        }

        if let recordId = pendingChange.id {
            try await pendingCipherChangeDataStore.deletePendingChange(id: recordId)
        }
    }

    /// Creates a backup copy of a cipher with a conflict-suffixed name.
    ///
    /// The backup retains the original cipher's folder assignment and all fields
    /// except attachments (which are not duplicated).
    ///
    /// - Parameters:
    ///   - cipher: The cipher to create a backup of.
    ///   - timestamp: The timestamp to include in the backup name.
    ///   - userId: The user ID.
    ///
    private func createBackupCipher(
        from cipher: Cipher,
        timestamp: Date,
        userId: String
    ) async throws {
        // Decrypt the cipher to modify its name
        let decryptedCipher = try await clientService.vault().ciphers().decrypt(cipher: cipher)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestampString = dateFormatter.string(from: timestamp)

        let backupName = "\(decryptedCipher.name) - \(timestampString)"

        // Create the backup cipher view with the modified name
        let backupCipherView = decryptedCipher.update(name: backupName)

        // Encrypt and push to server as a new cipher
        let encryptionContext = try await clientService.vault().ciphers().encrypt(cipherView: backupCipherView)
        try await cipherService.addCipherWithServer(
            encryptionContext.cipher,
            encryptedFor: encryptionContext.encryptedFor
        )
    }
}
