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

    /// Organization items cannot be edited offline.
    case organizationCipherOfflineEditNotSupported

    var errorDescription: String? {
        switch self {
        case .missingCipherData:
            "The pending change record is missing cipher data."
        case .missingCipherId:
            "The pending change record is missing a cipher ID."
        case .vaultLocked:
            "The vault is locked. Please unlock to sync offline changes."
        case .organizationCipherOfflineEditNotSupported:
            "Organization items cannot be edited while offline. Please try again when connected."
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
class DefaultOfflineSyncResolver: OfflineSyncResolver {
    // MARK: Constants

    /// The minimum number of offline password changes that triggers a server backup
    /// even when no conflict is detected (soft conflict threshold).
    static let softConflictPasswordChangeThreshold: Int16 = 4

    // MARK: Properties

    /// The service for making cipher API requests.
    private let cipherAPIService: CipherAPIService

    /// The service for managing ciphers.
    private let cipherService: CipherService

    /// The client service for encryption/decryption.
    private let clientService: ClientService

    /// The service for managing folders.
    private let folderService: FolderService

    /// The data store for pending cipher changes.
    private let pendingCipherChangeDataStore: PendingCipherChangeDataStore

    /// The service for managing account state.
    private let stateService: StateService

    /// The time provider.
    private let timeProvider: TimeProvider

    /// Cached folder ID for the "Offline Sync Conflicts" folder during a sync batch.
    private var conflictFolderId: String?

    // MARK: Initialization

    /// Initializes a `DefaultOfflineSyncResolver`.
    ///
    /// - Parameters:
    ///   - cipherAPIService: The service for making cipher API requests.
    ///   - cipherService: The service for managing ciphers.
    ///   - clientService: The client service for encryption/decryption.
    ///   - folderService: The service for managing folders.
    ///   - pendingCipherChangeDataStore: The data store for pending cipher changes.
    ///   - stateService: The service for managing account state.
    ///   - timeProvider: The time provider.
    ///
    init(
        cipherAPIService: CipherAPIService,
        cipherService: CipherService,
        clientService: ClientService,
        folderService: FolderService,
        pendingCipherChangeDataStore: PendingCipherChangeDataStore,
        stateService: StateService,
        timeProvider: TimeProvider
    ) {
        self.cipherAPIService = cipherAPIService
        self.cipherService = cipherService
        self.clientService = clientService
        self.folderService = folderService
        self.pendingCipherChangeDataStore = pendingCipherChangeDataStore
        self.stateService = stateService
        self.timeProvider = timeProvider
    }

    // MARK: OfflineSyncResolver

    func processPendingChanges(userId: String) async throws {
        let pendingChanges = try await pendingCipherChangeDataStore.fetchPendingChanges(userId: userId)
        guard !pendingChanges.isEmpty else { return }

        // Reset cached conflict folder ID for this batch
        conflictFolderId = nil

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
            try await resolveSoftDelete(pendingChange: pendingChange, cipherId: cipherId, userId: userId)
        }
    }

    /// Resolves a pending create (new item created offline).
    private func resolveCreate(pendingChange: PendingCipherChangeData, userId: String) async throws {
        guard let cipherData = pendingChange.cipherData else {
            throw OfflineSyncError.missingCipherData
        }

        let responseModel = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: cipherData)
        let cipher = Cipher(responseModel: responseModel)

        try await cipherService.addCipherWithServer(cipher, encryptedFor: userId)

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

        // Fetch the current server version
        let serverResponseModel = try await cipherAPIService.getCipher(withId: cipherId)
        let serverCipher = Cipher(responseModel: serverResponseModel)

        let localResponseModel = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: localCipherData)
        let localCipher = Cipher(responseModel: localResponseModel)

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
            // No server-side changes, but 4+ offline password changes - create backup of server version
            try await cipherService.updateCipherWithServer(localCipher, encryptedFor: userId)
            try await createBackupCipher(
                from: serverCipher,
                timestamp: serverRevisionDate,
                userId: userId
            )
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
            // Local is newer - push local, backup server
            try await cipherService.updateCipherWithServer(localCipher, encryptedFor: userId)
            try await createBackupCipher(
                from: serverCipher,
                timestamp: serverTimestamp,
                userId: userId
            )
        } else {
            // Server is newer - server stays, backup local
            // Server version is already on the server, just update local storage
            try await cipherService.updateCipherWithLocalStorage(serverCipher)
            try await createBackupCipher(
                from: localCipher,
                timestamp: localTimestamp,
                userId: userId
            )
        }
    }

    /// Resolves a pending soft delete against the server state.
    private func resolveSoftDelete(
        pendingChange: PendingCipherChangeData,
        cipherId: String,
        userId: String
    ) async throws {
        // Check if the server version was modified while we were offline
        let serverResponseModel = try await cipherAPIService.getCipher(withId: cipherId)
        let serverCipher = Cipher(responseModel: serverResponseModel)

        let originalRevisionDate = pendingChange.originalRevisionDate
        let hasConflict = originalRevisionDate != nil && serverCipher.revisionDate != originalRevisionDate

        if hasConflict {
            // Create backup of the server version before deleting
            try await createBackupCipher(
                from: serverCipher,
                timestamp: serverCipher.revisionDate,
                userId: userId
            )
        }

        // Complete the soft delete on the server
        guard let cipherData = pendingChange.cipherData else {
            throw OfflineSyncError.missingCipherData
        }
        let localResponseModel = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: cipherData)
        let localCipher = Cipher(responseModel: localResponseModel)
        try await cipherService.softDeleteCipherWithServer(id: cipherId, localCipher)

        if let recordId = pendingChange.id {
            try await pendingCipherChangeDataStore.deletePendingChange(id: recordId)
        }
    }

    /// Creates a backup copy of a cipher in the "Offline Sync Conflicts" folder.
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
        // Ensure the conflict folder exists
        let folderId = try await getOrCreateConflictFolder()

        // Decrypt the cipher to modify its name
        let decryptedCipher = try await clientService.vault().ciphers().decrypt(cipher: cipher)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HHmmss"
        let timestampString = dateFormatter.string(from: timestamp)

        let backupName = "\(decryptedCipher.name) - offline conflict \(timestampString)"

        // Create the backup cipher view with modified name and folder
        let backupCipherView = decryptedCipher.update(
            name: backupName,
            folderId: folderId
        )

        // Encrypt and push to server as a new cipher
        let encryptionContext = try await clientService.vault().ciphers().encrypt(cipherView: backupCipherView)
        try await cipherService.addCipherWithServer(
            encryptionContext.cipher,
            encryptedFor: encryptionContext.encryptedFor
        )
    }

    /// Gets or creates the "Offline Sync Conflicts" folder.
    ///
    /// - Returns: The folder ID.
    ///
    private func getOrCreateConflictFolder() async throws -> String {
        // Return cached ID if available
        if let conflictFolderId {
            return conflictFolderId
        }

        let folderName = "Offline Sync Conflicts"

        // Check if folder already exists
        let existingFolders = try await folderService.fetchAllFolders()
        for folder in existingFolders {
            let decryptedFolder = try await clientService.vault().folders().decrypt(folder: folder)
            if decryptedFolder.name == folderName, let folderId = folder.id {
                conflictFolderId = folderId
                return folderId
            }
        }

        // Create the folder
        let newFolder = try await folderService.addFolderWithServer(name: folderName)
        guard let id = newFolder.id else {
            throw DataMappingError.missingId
        }
        conflictFolderId = id
        return id
    }
}
