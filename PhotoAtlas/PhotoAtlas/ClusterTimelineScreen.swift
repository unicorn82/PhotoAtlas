import SwiftUI
import Photos

struct TimelineItem: Identifiable {
    let id: String // localIdentifier
    let creationTs: Double?
    let isFavorite: Bool
    let hasComment: Bool
}

struct TimelineSection: Identifiable {
    let id: String // section key
    let title: String
    var items: [TimelineItem]
}

private struct FavoriteHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)

            Text("Favorites")

            Text("\(count)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.thinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
                )

            Spacer()
        }
        .font(.headline)
        .padding(.vertical, 4)
    }
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
    @State private var favoriteItems: [TimelineItem] = []
    @State private var pagerSelection: PagerSelection?

    @StateObject private var imageLoader = PhotoImageLoader()

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        timelineRow(item)
                    }
                } header: {
                    if section.id == "favorites" {
                        FavoriteHeader(count: section.items.count)
                    } else {
                        Text(section.title)
                    }
                }
            }
        }
        .navigationTitle("Timeline")
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .photoUserDataDidChange)) { note in
            guard let localId = note.object as? String else { return }
            Task { await refreshUserBadges(for: localId) }
        }
        .sheet(item: $pagerSelection) { sel in
            PhotoPagerScreen(ids: flatItems.map(\.id), selectedIndex: sel.index)
                .environmentObject(model)
        }
    }

    private func load() async {
        do {
            let rows = try await model.db.photoIds(inCluster: clusterKey, precision: precision)
            let items = rows.map { TimelineItem(id: $0.localId, creationTs: $0.creationTs, isFavorite: $0.isFavorite, hasComment: $0.hasComment) }

            // Favorites section (duplicated at top, then the full timeline below)
            let favRows = try await model.db.favoritePhotoIds(inCluster: clusterKey, precision: precision)
            let favorites = favRows.map { TimelineItem(id: $0.localId, creationTs: $0.creationTs, isFavorite: true, hasComment: $0.hasComment) }

            flatItems = items

            var outSections: [TimelineSection] = []
            if !favorites.isEmpty {
                outSections.append(TimelineSection(id: "favorites", title: "Favorites", items: favorites))
            }
            outSections.append(contentsOf: groupByMonth(items))
            sections = outSections
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

    private func refreshUserBadges(for localId: String) async {
        // Pull latest favorite/comment flags from DB and update only the affected rows.
        do {
            let ud = try await model.db.photoUserData(localId: localId)
            let hasComment = !(ud.comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            // 1) Update flatItems (used for pager index lookup)
            if let i = flatItems.firstIndex(where: { $0.id == localId }) {
                let old = flatItems[i]
                flatItems[i] = TimelineItem(id: old.id, creationTs: old.creationTs, isFavorite: ud.isFavorite, hasComment: hasComment)
            }

            // Helper: fetch creationTs from existing data (so we can insert into favorites sorted)
            let creationTs: Double? = {
                if let i = flatItems.firstIndex(where: { $0.id == localId }) { return flatItems[i].creationTs }
                for s in sections {
                    if let it = s.items.first(where: { $0.id == localId }) { return it.creationTs }
                }
                return nil
            }()

            func updated(_ it: TimelineItem) -> TimelineItem {
                guard it.id == localId else { return it }
                return TimelineItem(id: it.id, creationTs: it.creationTs, isFavorite: ud.isFavorite, hasComment: hasComment)
            }

            // 2) Update month sections (and favorites section badges)
            var newSections: [TimelineSection] = []
            newSections.reserveCapacity(sections.count)

            for sec in sections {
                if sec.id == "favorites" {
                    // We'll rebuild favorites below to handle insert/remove.
                    continue
                }
                var copy = sec
                if copy.items.contains(where: { $0.id == localId }) {
                    copy.items = copy.items.map(updated)
                }
                newSections.append(copy)
            }

            // 3) Rebuild favorites section by patching the existing one
            var favorites: [TimelineItem] = sections.first(where: { $0.id == "favorites" })?.items ?? []
            favorites = favorites.map(updated)

            if ud.isFavorite {
                if !favorites.contains(where: { $0.id == localId }) {
                    favorites.append(
                        TimelineItem(id: localId, creationTs: creationTs, isFavorite: true, hasComment: hasComment)
                    )
                }

                favorites.sort { a, b in
                    switch (a.creationTs, b.creationTs) {
                    case let (x?, y?): return x > y
                    case (nil, nil): return a.id > b.id
                    case (_?, nil): return true
                    case (nil, _?): return false
                    }
                }

                newSections.insert(
                    TimelineSection(id: "favorites", title: "Favorites", items: favorites),
                    at: 0
                )
            } else {
                // Not favorite anymore: remove it from favorites.
                favorites.removeAll { $0.id == localId }
                if !favorites.isEmpty {
                    newSections.insert(
                        TimelineSection(id: "favorites", title: "Favorites", items: favorites),
                        at: 0
                    )
                }
            }

            sections = newSections
        } catch {
            // ignore
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: TimelineItem) -> some View {
        Button {
            if let idx = flatItems.firstIndex(where: { $0.id == item.id }) {
                pagerSelection = PagerSelection(index: idx)
            }
        } label: {
            HStack(spacing: 12) {
                PhotoThumbnailView(localId: item.id)
                    .environmentObject(imageLoader)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(formatTimestamp(item.creationTs))
                            .font(.subheadline.weight(.semibold))

                        if item.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.yellow)
                        }

                        if item.hasComment {
                            Image(systemName: "text.bubble.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(item.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
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
