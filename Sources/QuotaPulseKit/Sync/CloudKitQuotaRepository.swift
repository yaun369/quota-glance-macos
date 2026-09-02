#if canImport(CloudKit)
import CloudKit
import Foundation

/// Friendly, already-localized descriptions for the CloudKit failures a
/// user can actually do something about. Anything else falls back to
/// CloudKit's own `localizedDescription`.
public enum QuotaSyncError: Error, CustomStringConvertible, Sendable {
    case disabled
    case iCloudAccountUnavailable
    case networkUnavailable
    case underlying(String)

    public var description: String {
        switch self {
        case .disabled:
            return QuotaL10n.string(
                "sync.disabled",
                "iCloud sync is disabled for this build. Local quota collection is still available."
            )
        case .iCloudAccountUnavailable:
            return QuotaL10n.string(
                "sync.iCloudUnavailable",
                "iCloud is unavailable. Sign in to iCloud in System Settings and allow QuotaGlance to use it."
            )
        case .networkUnavailable:
            return QuotaL10n.string("sync.networkUnavailable", "The network is unavailable. QuotaGlance will retry automatically.")
        case .underlying(let message):
            return message
        }
    }

    static func from(_ error: Error) -> QuotaSyncError {
        guard let ckError = error as? CKError else { return .underlying(error.localizedDescription) }
        switch ckError.code {
        case .notAuthenticated:
            return .iCloudAccountUnavailable
        case .networkUnavailable, .networkFailure, .accountTemporarilyUnavailable:
            return .networkUnavailable
        default:
            return .underlying(ckError.localizedDescription)
        }
    }
}

/// Stores exactly one record per provider in the user's private CloudKit
/// database, overwritten in place on every push. Per the plan, QuotaPulse
/// deliberately keeps no history in CloudKit for v1 — only "latest state
/// wins" — so this never needs a query, just a well-known record ID.
public actor CloudKitQuotaRepository: QuotaSyncRepository {
    private static let recordType = "QuotaSnapshot"

    /// The Mac target injects these values from its build configuration.
    /// Other Apple targets omit them and use their entitlement's default
    /// container, which keeps the shared package independent of an app ID.
    public static var containerIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "QuotaCloudKitContainerIdentifier") as? String,
              !value.isEmpty else { return nil }
        return value
    }

    public static var isEnabled: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "QuotaCloudKitEnabled") else {
            return true
        }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }

    private let database: CKDatabase?

    /// Set once the server has told us this container's production schema has
    /// no `sourceVersion` field. See ``push(_:)``.
    private var omitsSourceVersion = false

    public init(
        containerIdentifier: String? = CloudKitQuotaRepository.containerIdentifier,
        isEnabled: Bool = CloudKitQuotaRepository.isEnabled
    ) {
        guard isEnabled else {
            self.database = nil
            return
        }
        let container = containerIdentifier.map(CKContainer.init(identifier:)) ?? CKContainer.default()
        self.database = container.privateCloudDatabase
    }

    public func push(_ snapshot: QuotaSnapshot) async throws {
        guard database != nil else { throw QuotaSyncError.disabled }
        do {
            try await pushOnce(snapshot)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // There are two legitimate writers now — the Mac collector and a
            // signed-in iPhone — so another device can save between this
            // push's fetch and save. Re-fetch (picking up the fresh change
            // tag) and re-apply once; `applyIfNotOlder` then keeps whichever
            // reading is newer, so "losing" the race is also a success.
            do {
                try await pushOnce(snapshot)
            } catch {
                throw QuotaSyncError.from(error)
            }
        } catch let error as CKError where !omitsSourceVersion && Self.isSchemaRejection(error) {
            // A production schema only gains a field when someone deploys it
            // from the CloudKit Console; a container whose schema predates
            // `sourceVersion` rejects the *entire* save. That would take the
            // user's quota sync down over a field they never see — it is an
            // activation-attribution tag, not part of the reading. Drop it
            // and try once more.
            //
            // The latch is set only after the retry succeeds, so a rejection
            // that was really about something else still surfaces as itself
            // and does not quietly cost us the tag for the rest of the run.
            do {
                try await pushOnce(snapshot, includingSourceVersion: false)
                omitsSourceVersion = true
            } catch {
                throw QuotaSyncError.from(error)
            }
        } catch {
            throw QuotaSyncError.from(error)
        }
    }

    /// True for the server's "your schema does not have this field" refusal.
    ///
    /// Matched by code rather than by the message text: the message names the
    /// field, but it is English-only server prose and not something to parse.
    static func isSchemaRejection(_ error: CKError) -> Bool {
        error.code == .invalidArguments || error.code == .serverRejectedRequest
    }

    private func pushOnce(
        _ snapshot: QuotaSnapshot,
        includingSourceVersion: Bool = true
    ) async throws {
        guard let database else { throw QuotaSyncError.disabled }
        let recordID = CKRecord.ID(recordName: Self.recordName(for: snapshot.provider))
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: Self.recordType, recordID: recordID)
        }

        // The Mac app's in-memory freshness guard resets when the process
        // restarts. Protect the durable record as well so an older-but-valid
        // StatusLine reading can never replace a newer OAuth snapshot that is
        // already in CloudKit.
        guard Self.applyIfNotOlder(
            snapshot,
            to: record,
            includingSourceVersion: includingSourceVersion && !omitsSourceVersion
        ) else { return }

        _ = try await database.save(record)
    }

    public func fetchAll() async throws -> [Provider: QuotaSnapshot] {
        guard let database else { throw QuotaSyncError.disabled }
        var result: [Provider: QuotaSnapshot] = [:]
        for provider in Provider.allCases {
            let recordID = CKRecord.ID(recordName: Self.recordName(for: provider))
            do {
                let record = try await database.record(for: recordID)
                if let snapshot = Self.snapshot(from: record) {
                    result[provider] = snapshot
                }
            } catch let error as CKError where error.code == .unknownItem {
                continue // this provider hasn't synced from the Mac yet
            } catch {
                throw QuotaSyncError.from(error)
            }
        }
        return result
    }

    private static func recordName(for provider: Provider) -> String {
        "\(provider.rawValue)-latest"
    }

    static func apply(
        _ snapshot: QuotaSnapshot,
        to record: CKRecord,
        includingSourceVersion: Bool = true
    ) {
        record["provider"] = snapshot.provider.rawValue
        record["sessionUsedPercent"] = snapshot.session.usedPercent
        record["sessionResetAt"] = snapshot.session.resetAt
        record["weeklyUsedPercent"] = snapshot.weekly.usedPercent
        record["weeklyResetAt"] = snapshot.weekly.resetAt
        record["capturedAt"] = snapshot.capturedAt
        // Left untouched, not cleared, when excluded: assigning `nil` is
        // itself a modification of the field the server is refusing.
        if includingSourceVersion {
            record["sourceVersion"] = snapshot.sourceVersion
        }
    }

    @discardableResult
    static func applyIfNotOlder(
        _ snapshot: QuotaSnapshot,
        to record: CKRecord,
        includingSourceVersion: Bool = true
    ) -> Bool {
        if let existingCapturedAt = record["capturedAt"] as? Date,
           existingCapturedAt > snapshot.capturedAt {
            return false
        }
        apply(snapshot, to: record, includingSourceVersion: includingSourceVersion)
        return true
    }

    static func snapshot(from record: CKRecord) -> QuotaSnapshot? {
        guard
            let providerRaw = record["provider"] as? String,
            let provider = Provider(rawValue: providerRaw),
            let capturedAt = record["capturedAt"] as? Date
        else { return nil }

        return QuotaSnapshot(
            provider: provider,
            session: QuotaWindow(
                usedPercent: record["sessionUsedPercent"] as? Double,
                resetAt: record["sessionResetAt"] as? Date
            ),
            weekly: QuotaWindow(
                usedPercent: record["weeklyUsedPercent"] as? Double,
                resetAt: record["weeklyResetAt"] as? Date
            ),
            capturedAt: capturedAt,
            sourceVersion: record["sourceVersion"] as? String
        )
    }
}
#endif
