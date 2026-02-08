import Foundation
import Photos
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var authorization: PHAuthorizationStatus = .notDetermined
    @Published var isIndexing: Bool = false
    @Published var lastIndexSummary: String? = nil

    let db: SQLiteStore
    let indexer: PhotosIndexer

    init() {
        self.db = SQLiteStore()
        self.indexer = PhotosIndexer(store: db)
        self.authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestPhotosAccessIfNeeded() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            authorization = newStatus
        } else {
            authorization = status
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// One-time background-ish index. For MVP, we do a full wipe+reindex when you press the button.
    /// (We can switch to resumable incremental later.)
    func indexNow() async {
        isIndexing = true
        defer { isIndexing = false }

        do {
            await requestPhotosAccessIfNeeded()
            guard authorization == .authorized || authorization == .limited else {
                lastIndexSummary = "Photos access not granted. Tap Grant Access to enable indexing."
                return
            }

            let result = try await indexer.fullReindex()
            lastIndexSummary = "Indexed \(result.assetsIndexed) assets (\(result.withLocation) with GPS)."
        } catch {
            lastIndexSummary = "Index failed: \(error.localizedDescription)"
        }
    }
}
