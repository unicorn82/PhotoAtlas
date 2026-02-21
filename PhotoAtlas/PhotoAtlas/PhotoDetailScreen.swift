import SwiftUI
import Photos

extension Notification.Name {
    static let photoUserDataDidChange = Notification.Name("photoUserDataDidChange")
}

struct PhotoDetailScreen: View {
    @EnvironmentObject private var model: AppModel

    let localId: String

    @State private var image: UIImage?
    @State private var meta: String = ""

    // User annotations
    @State private var isFavorite: Bool = false
    @State private var comment: String = ""
    @FocusState private var commentFocused: Bool

    var body: some View {
        let inCart = model.isInFootprintDiaryCart(localId)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let uiImage = image {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Favorite + card cart
                HStack(spacing: 12) {
                    Button {
                        Task { await toggleFavorite() }
                    } label: {
                        Label(isFavorite ? "Favorited" : "Favorite", systemImage: isFavorite ? "star.fill" : "star")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .tint(isFavorite ? .yellow : .accentColor)

                    Button {
                        let ok = model.toggleFootprintDiaryCart(localId)
                        if !ok && !inCart {
                            // limit reached (9)
                        }
                    } label: {
                        Label(inCart ? "Added" : "Add to Card", systemImage: inCart ? "plus.circle.fill" : "plus.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .tint(inCart ? .green : .accentColor)

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Comment")
                        .font(.headline)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $comment)
                            .frame(minHeight: 90)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                            .focused($commentFocused)

                        if comment.isEmpty {
                            Text("Add a note…")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 6)
                                .allowsHitTesting(false)
                        }
                    }

                    HStack {
                        Button("Save") {
                            Task { await saveComment() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Clear") {
                            comment = ""
                            Task { await saveComment() }
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }
                }

                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .task(id: localId) { await load() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let uiImage = image {
                    // Use a simple share button to avoid ShareLink complex type interference
                    Button {
                        shareAction(uiImage)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private func shareAction(_ uiImage: UIImage) {
        let vc = UIActivityViewController(activityItems: [uiImage], applicationActivities: nil)
        
        // Find the top-most view controller to present the share sheet
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
           let rootVC = window.rootViewController {
            
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            
            // On iPad, we need a source point for the popover
            if let popover = vc.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            
            topVC.present(vc, animated: true)
        }
    }

    private func load() async {
        // Load user annotations from DB
        do {
            let data = try await model.db.photoUserData(localId: localId)
            isFavorite = data.isFavorite
            comment = data.comment ?? ""
        } catch {
            // ignore
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let asset = assets.firstObject else {
            meta = "Asset not found (may have been deleted or access revoked)."
            image = nil
            return
        }

        let ts: String
        if let d = asset.creationDate {
            ts = DateFormatters.shared.shortDateTime.string(from: d)
        } else {
            ts = "(no date)"
        }

        let loc: String
        if let c = asset.location?.coordinate {
            loc = String(format: "%.5f, %.5f", c.latitude, c.longitude)
        } else {
            loc = "(no location)"
        }

        meta = "id: \(localId)\ncreated: \(ts)\nlocation: \(loc)"

        let mgr = PHImageManager.default()
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true

        let target = CGSize(width: 1600, height: 1600)
        image = await withCheckedContinuation { cont in
            mgr.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: opts) { img, _ in
                cont.resume(returning: img)
            }
        }
    }

    private func toggleFavorite() async {
        let next = !isFavorite
        isFavorite = next
        do {
            try await model.db.setFavorite(localId: localId, isFavorite: next)
            NotificationCenter.default.post(name: .photoUserDataDidChange, object: localId)
        } catch {
            // revert on failure
            isFavorite.toggle()
        }
    }

    private func saveComment() async {
        do {
            try await model.db.setComment(localId: localId, comment: comment)
            NotificationCenter.default.post(name: .photoUserDataDidChange, object: localId)
            commentFocused = false
        } catch {
            // ignore
        }
    }
}
