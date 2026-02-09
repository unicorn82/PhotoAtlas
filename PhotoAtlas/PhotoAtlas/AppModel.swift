import Foundation
import Photos
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var authorization: PHAuthorizationStatus = .notDetermined
    @Published var lastIndexSummary: String? = nil

    let db: SQLiteStore
    let indexer: PhotosIndexer

    private let defaults = UserDefaults.standard
    private let didInitialIndexKey = "didInitialPhotoIndex"

    init() {
        self.db = SQLiteStore()
        self.indexer = PhotosIndexer(store: db)
        self.authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Actively prompt the user for Photos permission (shows the system dialog).
    func requestPhotosAccess() async {
        let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorization = newStatus
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Auto-run indexing:
    /// - on app launch
    /// - immediately after the user grants Photos permission
    ///
    /// Behavior:
    /// - First time (no prior index): do a full reindex.
    /// - Subsequent runs: incremental index based on DB latest imported timestamp.
    func autoIndexIfPossible() async {
        do {
            refreshAuthorization()

            // IMPORTANT: Don't trigger the system permission dialog from here.
            // We show an in-app primer first, then call `requestPhotosAccess()`.
            guard authorization != .notDetermined else {
                lastIndexSummary = "Photos access needed to show your pins."
                return
            }

            guard authorization == .authorized || authorization == .limited else {
                lastIndexSummary = "Photos access not granted."
                return
            }

            let didInitial = defaults.bool(forKey: didInitialIndexKey)

            let result: IndexResult
            if !didInitial {
                result = try await indexer.fullReindex()
                defaults.set(true, forKey: didInitialIndexKey)
                lastIndexSummary = "Indexed \(result.assetsIndexed) assets (\(result.withLocation) with GPS)."
            } else {
                if let maxImportedTs = try await db.latestImportedTs() {
                    let since = Date(timeIntervalSince1970: maxImportedTs)
                    result = try await indexer.incrementalIndex(since: since)
                    lastIndexSummary = "Indexed \(result.assetsIndexed) new/changed assets (\(result.withLocation) with GPS)."
                } else {
                    result = try await indexer.fullReindex()
                    lastIndexSummary = "Indexed \(result.assetsIndexed) assets (\(result.withLocation) with GPS)."
                }
            }
        } catch {
            lastIndexSummary = "Index failed: \(error.localizedDescription)"
        }
    }
}
