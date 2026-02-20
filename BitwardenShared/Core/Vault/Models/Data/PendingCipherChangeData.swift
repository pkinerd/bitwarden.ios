import CoreData
import Foundation

// MARK: - PendingCipherChangeType

/// The type of pending offline change to a cipher.
///
enum PendingCipherChangeType: String {
    /// An update to an existing cipher.
    case update

    /// A newly created cipher.
    case create

    /// A soft delete of an existing cipher.
    case softDelete

    /// A hard (permanent) delete of an existing cipher.
    case hardDelete
}

// MARK: - PendingCipherChangeData

/// A Core Data entity for persisting pending cipher changes queued during offline editing.
///
/// The `cipherData` field stores the encrypted `CipherDetailsResponseModel` in the same
/// JSON-encoded format used by `CipherData`. All sensitive fields are encrypted by the SDK
/// before storage. Only non-sensitive metadata is stored as separate attributes.
///
class PendingCipherChangeData: NSManagedObject {
    // MARK: Properties

    /// The unique identifier for this pending change record.
    @NSManaged var id: String?

    /// The cipher's ID (or temporary client-generated ID for new items).
    @NSManaged var cipherId: String?

    /// The active user ID at the time of the offline edit.
    @NSManaged var userId: String?

    /// The type of change, stored as a string corresponding to `PendingCipherChangeType`.
    @NSManaged var changeTypeRaw: String?

    /// The JSON-encoded encrypted `CipherDetailsResponseModel` snapshot of the cipher.
    @NSManaged var cipherData: Data?

    /// The cipher's `revisionDate` before the first offline edit. Used for conflict detection.
    @NSManaged var originalRevisionDate: Date?

    /// When this pending change was first queued.
    @NSManaged var createdDate: Date?

    /// When this pending change was last updated.
    @NSManaged var updatedDate: Date?

    /// The number of password changes made across offline edits for this cipher.
    @NSManaged var offlinePasswordChangeCount: Int64

    // MARK: Computed Properties

    /// The typed change type for this pending change.
    var changeType: PendingCipherChangeType {
        get {
            changeTypeRaw.flatMap(PendingCipherChangeType.init(rawValue:)) ?? .update
        }
        set {
            changeTypeRaw = newValue.rawValue
        }
    }

    // MARK: Initialization

    /// Initializes a `PendingCipherChangeData` for insertion into the managed object context.
    ///
    /// - Parameters:
    ///   - context: The managed object context to insert the initialized object.
    ///   - id: The unique identifier for this pending change.
    ///   - cipherId: The cipher's ID.
    ///   - userId: The active user ID.
    ///   - changeType: The type of offline change.
    ///   - cipherData: The JSON-encoded encrypted cipher snapshot.
    ///   - originalRevisionDate: The cipher's revision date before the first offline edit.
    ///   - offlinePasswordChangeCount: The number of offline password changes.
    ///
    convenience init(
        context: NSManagedObjectContext,
        id: String = UUID().uuidString,
        cipherId: String,
        userId: String,
        changeType: PendingCipherChangeType,
        cipherData: Data?,
        originalRevisionDate: Date?,
        offlinePasswordChangeCount: Int = 0
    ) {
        self.init(context: context)
        self.id = id
        self.cipherId = cipherId
        self.userId = userId
        self.changeTypeRaw = changeType.rawValue
        self.cipherData = cipherData
        self.originalRevisionDate = originalRevisionDate
        self.createdDate = Date()
        self.updatedDate = Date()
        self.offlinePasswordChangeCount = Int64(offlinePasswordChangeCount)
    }
}

// MARK: - Predicates

extension PendingCipherChangeData {
    /// Returns a predicate for filtering by user ID.
    ///
    /// - Parameter userId: The user ID to filter by.
    /// - Returns: An `NSPredicate` matching the user ID.
    ///
    static func userIdPredicate(userId: String) -> NSPredicate {
        NSPredicate(format: "%K == %@", #keyPath(PendingCipherChangeData.userId), userId)
    }

    /// Returns a predicate for filtering by user ID and cipher ID.
    ///
    /// - Parameters:
    ///   - userId: The user ID to filter by.
    ///   - cipherId: The cipher ID to filter by.
    /// - Returns: An `NSPredicate` matching both the user ID and cipher ID.
    ///
    static func userIdAndCipherIdPredicate(userId: String, cipherId: String) -> NSPredicate {
        NSPredicate(
            format: "%K == %@ AND %K == %@",
            #keyPath(PendingCipherChangeData.userId),
            userId,
            #keyPath(PendingCipherChangeData.cipherId),
            cipherId
        )
    }

    /// Returns a predicate for filtering by record ID.
    ///
    /// - Parameter id: The pending change record ID.
    /// - Returns: An `NSPredicate` matching the record ID.
    ///
    static func idPredicate(id: String) -> NSPredicate {
        NSPredicate(format: "%K == %@", #keyPath(PendingCipherChangeData.id), id)
    }

    /// Returns a fetch request for pending changes belonging to a user.
    ///
    /// - Parameter userId: The user ID to fetch pending changes for.
    /// - Returns: An `NSFetchRequest` for the user's pending changes.
    ///
    static func fetchByUserIdRequest(userId: String) -> NSFetchRequest<PendingCipherChangeData> {
        let request = NSFetchRequest<PendingCipherChangeData>(entityName: "PendingCipherChangeData")
        request.predicate = userIdPredicate(userId: userId)
        return request
    }

    /// Returns a fetch request for a pending change matching a user and cipher ID.
    ///
    /// - Parameters:
    ///   - userId: The user ID.
    ///   - cipherId: The cipher ID.
    /// - Returns: An `NSFetchRequest` for the matching pending change.
    ///
    static func fetchByCipherIdRequest(
        userId: String,
        cipherId: String
    ) -> NSFetchRequest<PendingCipherChangeData> {
        let request = NSFetchRequest<PendingCipherChangeData>(entityName: "PendingCipherChangeData")
        request.predicate = userIdAndCipherIdPredicate(userId: userId, cipherId: cipherId)
        return request
    }

    /// Returns a fetch request for a pending change matching a record ID.
    ///
    /// - Parameter id: The pending change record ID.
    /// - Returns: An `NSFetchRequest` for the matching pending change.
    ///
    static func fetchByIdRequest(id: String) -> NSFetchRequest<PendingCipherChangeData> {
        let request = NSFetchRequest<PendingCipherChangeData>(entityName: "PendingCipherChangeData")
        request.predicate = idPredicate(id: id)
        return request
    }

    /// Returns a batch delete request for all pending changes belonging to a user.
    ///
    /// - Parameter userId: The user ID.
    /// - Returns: An `NSBatchDeleteRequest` for the user's pending changes.
    ///
    static func deleteByUserIdRequest(userId: String) -> NSBatchDeleteRequest {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "PendingCipherChangeData")
        fetchRequest.predicate = userIdPredicate(userId: userId)
        return NSBatchDeleteRequest(fetchRequest: fetchRequest)
    }
}
