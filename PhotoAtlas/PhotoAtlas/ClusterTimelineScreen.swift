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

private struct ShareToolbarLabel: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("Share")
                .font(.footnote.weight(.semibold))

            if count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
            }
        }
    }
}

private struct TimelineRow: View {
    @EnvironmentObject private var loader: PhotoImageLoader

    let item: TimelineItem
    let isShared: Bool
    let onOpen: () -> Void
    let onToggleShare: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PhotoThumbnailView(localId: item.id)
                .environmentObject(loader)

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

                    if isShared {
                        Image(systemName: "square.and.arrow.up.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }

                Text(item.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                guard !isShared else { return }
                onToggleShare()
            } label: {
                Text("Share")
            }
            .tint(.blue)
            .disabled(isShared)
        }
    }

    private func formatTimestamp(_ ts: Double?) -> String {
        guard let ts = ts else { return "(no date)" }
        let d = Date(timeIntervalSince1970: ts)
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct SwipeHintOverlay: View {
    @State private var nudge: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw")
                .foregroundStyle(.secondary)

            Text("Swipe left on a photo to share")
                .font(.footnote.weight(.semibold))

            Image(systemName: "chevron.left")
                .font(.footnote.weight(.semibold))
                .offset(x: nudge ? -4 : 0)
                .opacity(nudge ? 1.0 : 0.55)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                nudge = true
            }
        }
        .accessibilityLabel("Swipe left on a photo row to see sharing options")
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

    @State private var isFootprintDiaryPresented: Bool = false

    @State private var showSwipeHint: Bool = false

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
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    isFootprintDiaryPresented = true
                } label: {
                    ShareToolbarLabel(count: model.footprintDiaryCartIds.count)
                }
                .disabled(model.footprintDiaryCartIds.isEmpty)
            }
        }
        .task {
            await load()
            await maybeShowSwipeHint()
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoUserDataDidChange)) { note in
            guard let localId = note.object as? String else { return }
            Task { await refreshUserBadges(for: localId) }
        }
        .overlay(alignment: .bottom) {
            if showSwipeHint {
                SwipeHintOverlay()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showSwipeHint)
        .sheet(item: $pagerSelection) { sel in
            PhotoPagerScreen(ids: flatItems.map(\.id), selectedIndex: sel.index)
                .environmentObject(model)
        }
        .sheet(isPresented: $isFootprintDiaryPresented) {
            FootprintDiaryComposerScreen(initialSelectedAssetIds: model.footprintDiaryCartIds)
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

    private func maybeShowSwipeHint() async {
        // One-time per screen appearance.
        guard !flatItems.isEmpty else { return }

        // If there are already items selected, the affordance is already obvious.
        guard model.footprintDiaryCartIds.isEmpty else { return }

        showSwipeHint = true
        try? await Task.sleep(nanoseconds: 2_800_000_000)
        showSwipeHint = false
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
        TimelineRow(
            item: item,
            isShared: model.isInFootprintDiaryCart(item.id),
            onOpen: {
                if let idx = flatItems.firstIndex(where: { $0.id == item.id }) {
                    pagerSelection = PagerSelection(index: idx)
                }
            },
            onToggleShare: {
                _ = model.toggleFootprintDiaryCart(item.id)
            }
        )
        .environmentObject(imageLoader)
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

// MARK: - Swipe left/right within the current cluster (moved to PhotoPagerScreen.swift)

