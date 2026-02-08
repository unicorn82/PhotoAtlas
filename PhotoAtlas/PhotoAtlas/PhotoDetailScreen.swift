import SwiftUI
import Photos

struct PhotoDetailScreen: View {
    let localId: String

    @State private var image: UIImage?
    @State private var meta: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let image = image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .task(id: localId) { await load() }
    }

    private func load() async {
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
}
