import Foundation
import Photos
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var authorization: PHAuthorizationStatus = .notDetermined
    @Published var lastIndexSummary: String? = nil

    // MARK: - Footprint Diary cart (ordered)

    /// Ordered list of selected photo asset ids (PHAsset.localIdentifier).
    /// Used as a lightweight "cart" for building a Footprint Diary share card.
    @Published var footprintDiaryCartIds: [String] = []
    let footprintDiaryCartLimit: Int = 9

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

    // MARK: - Footprint Diary cart helpers

    func isInFootprintDiaryCart(_ localId: String) -> Bool {
        footprintDiaryCartIds.contains(localId)
    }

    /// Toggles the given asset id in the cart.
    /// - Returns: whether the id is now in the cart.
    @discardableResult
    func toggleFootprintDiaryCart(_ localId: String) -> Bool {
        if let idx = footprintDiaryCartIds.firstIndex(of: localId) {
            footprintDiaryCartIds.remove(at: idx)
            return false
        }

        guard footprintDiaryCartIds.count < footprintDiaryCartLimit else {
            // silently ignore if we're at the limit
            return false
        }

        footprintDiaryCartIds.append(localId)
        return true
    }

    func removeFromFootprintDiaryCart(_ localId: String) {
        footprintDiaryCartIds.removeAll { $0 == localId }
    }

    func moveFootprintDiaryCart(fromOffsets: IndexSet, toOffset: Int) {
        footprintDiaryCartIds.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func clearFootprintDiaryCart() {
        footprintDiaryCartIds.removeAll()
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
