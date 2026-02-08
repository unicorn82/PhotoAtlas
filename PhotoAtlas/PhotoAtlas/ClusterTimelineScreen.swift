import SwiftUI
import Photos

struct TimelineItem: Identifiable {
    let id: String // localIdentifier
    let creationTs: Double?
}

struct TimelineSection: Identifiable {
    let id: String // section key
    let title: String
    var items: [TimelineItem]
}

struct PagerSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

struct ClusterTimelineScreen: View {
    @EnvironmentObject private var model: AppModel

    let clusterKey: String
    let precision: ClusterPrecision

    @State private var sections: [TimelineSection] = []
    @State private var flatItems: [TimelineItem] = []
    @State private var pagerSelection: PagerSelection?

    @StateObject private var imageLoader = PhotoImageLoader()

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        Button {
                            if let idx = flatItems.firstIndex(where: { $0.id == item.id }) {
                                pagerSelection = PagerSelection(index: idx)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                PhotoThumbnailView(localId: item.id)
                                    .environmentObject(imageLoader)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(formatTimestamp(item.creationTs))
                                        .font(.subheadline.weight(.semibold))
                                    Text(item.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Timeline")
        .task { await load() }
        .sheet(item: $pagerSelection) { sel in
            PhotoPagerScreen(ids: flatItems.map(\.id), selectedIndex: sel.index)
        }
    }

    private func load() async {
        do {
            let rows = try await model.db.photoIds(inCluster: clusterKey, precision: precision)
            let items = rows.map { TimelineItem(id: $0.localId, creationTs: $0.creationTs) }
            flatItems = items
            sections = groupByMonth(items)
        } catch {
            flatItems = []
            sections = []
        }
    }

    private func groupByMonth(_ items: [TimelineItem]) -> [TimelineSection] {
        var grouped: [String: [TimelineItem]] = [:]
        for it in items {
            let key = monthKey(it.creationTs)
            grouped[key, default: []].append(it)
        }

        let sortedKeys = grouped.keys.sorted(by: >)
        return sortedKeys.map { key in
            let title = key
            let its = grouped[key] ?? []
            return TimelineSection(id: key, title: title, items: its)
        }
    }

    private func monthKey(_ ts: Double?) -> String {
        guard let ts = ts else { return "Unknown date" }
        let d = Date(timeIntervalSince1970: ts)
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: d)
        let y = comps.year ?? 0
        let m = comps.month ?? 0
        return String(format: "%04d-%02d", y, m)
    }

    private func formatTimestamp(_ ts: Double?) -> String {
        guard let ts = ts else { return "(no date)" }
        let d = Date(timeIntervalSince1970: ts)
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Thumbnail support

@MainActor
final class PhotoImageLoader: ObservableObject {
    private let manager = PHCachingImageManager()
    private var cache: [String: UIImage] = [:]

    func thumbnail(for localId: String) async -> UIImage? {
        if let img = cache[localId] { return img }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let target = CGSize(width: 120, height: 120)
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .fastFormat
        opts.isNetworkAccessAllowed = true

        return await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: opts) { img, _ in
                if let img = img {
                    self.cache[localId] = img
                }
                cont.resume(returning: img)
            }
        }
    }
}

struct PhotoThumbnailView: View {
    @EnvironmentObject var loader: PhotoImageLoader
    let localId: String

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: localId) {
            image = await loader.thumbnail(for: localId)
        }
    }
}

// MARK: - Swipe left/right within the current cluster

struct PhotoPagerScreen: View {
    @Environment(\.dismiss) private var dismiss

    let ids: [String]
    @State var selectedIndex: Int

    var body: some View {
        NavigationView {
            TabView(selection: $selectedIndex) {
                ForEach(ids.indices, id: \.self) { i in
                    PhotoDetailScreen(localId: ids[i])
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .navigationTitle("\(selectedIndex + 1) / \(ids.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
