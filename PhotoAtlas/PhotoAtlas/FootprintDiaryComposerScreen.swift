import SwiftUI
import UIKit
import Photos
import MapKit
import CoreLocation

enum FootprintDiaryStyle: String, CaseIterable, Identifiable {
    case classic = "Footprint"
    case worldFootprint = "World Footprint"
    var id: String { rawValue }
}

struct FootprintDiaryComposerScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let initialSelectedAssetIds: [String]
    private let initialStyle: FootprintDiaryStyle

    init(initialSelectedAssetIds: [String] = [], initialStyle: FootprintDiaryStyle = .classic) {
        self.initialSelectedAssetIds = initialSelectedAssetIds
        self.initialStyle = initialStyle
        self._style = State(initialValue: initialStyle)
    }

    struct SelectedPhoto: Identifiable {
        let id: String
        let asset: PHAsset
        let previewImage: UIImage // High-quality image for composer UI
        var comment: String?
        var countryName: String?
        var cityName: String?
        var date: Date?

        var year: Int? {
            guard let date = date else { return nil }
            return Calendar.current.component(.year, from: date)
        }
    }

    @AppStorage("footprintDiary.format") private var storedFormat: String = FootprintDiaryCardFormat.portrait.rawValue
    @State private var format: FootprintDiaryCardFormat = .portrait

    /// World Footprint should always be rendered in landscape to avoid cropping the world map.
    private var effectiveFormat: FootprintDiaryCardFormat {
        style == .worldFootprint ? .landscape : format
    }

    /// When launched from the airplane button, we want a dedicated World Footprint UI (no tabs/options).
    private var isWorldFootprintOnly: Bool {
        initialStyle == .worldFootprint
    }
    @State private var layout: FootprintDiaryLayout = .casual

    @State private var pickedPhotos: [SelectedPhoto] = []
    @State private var pickedCaptions: [String] = []

    @State private var isLoadingSummary: Bool = false
    @State private var summary: CountryDiarySummary? = nil
    @State private var errorText: String? = nil

    @State private var renderedAlbumURL: URL? = nil
    @State private var renderedAlbumImage: UIImage? = nil
    @State private var isRendering = false

    @State private var isAlbumSheetPresented: Bool = false
    @State private var isSlideshowPresented: Bool = false

    @State private var fullPreviewModel: FootprintDiaryCardModel? = nil

    @State private var style: FootprintDiaryStyle
    @State private var currentCardModel: FootprintDiaryCardModel? = nil

    @State private var cardTitle: String = "Footprint"
    @State private var showYears: Bool = true
    @State private var showCountries: Bool = true
    @State private var showCities: Bool = true

    // Data for World Footprint
    @State private var visitedCities: [ClusterBubble] = []
    @State private var visitedContinents: [String] = [] // Populated from summary/clusters
    @State private var mapSnapshot: UIImage?
    @State private var mapOverlaySize: CGSize = .zero
    @State private var mapPointForCoord: ((CLLocationCoordinate2D) -> CGPoint)?
    @State private var activeSnapshotter: MKMapSnapshotter? = nil

    var body: some View {
        if isWorldFootprintOnly {
            worldFootprintOnlyView
        } else {
            classicComposerView
        }
    }

    private var classicComposerView: some View {
        NavigationView {
            List {
                Section {
                    configPanel
                } header: {
                    Text("Content & Style")
                }

                Section {
                    preview
                } header: {
                    previewHeader
                }

                if style == .classic {
                    Section {
                        pickedPhotosSection
                    } header: {
                        Text("Edit Memos")
                    } footer: {
                        Text("Drag to reorder photos in your footprint card.")
                    }
                }

                if let err = errorText {
                    Section {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(style == .worldFootprint ? "World Footprint" : "Footprint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $isAlbumSheetPresented) {
                let items: [Any] = {
                    if let url = renderedAlbumURL { return [url] }
                    if let img = renderedAlbumImage { return [img] }
                    return []
                }()
                ActivityShareSheet(items: items)
            }
            .fullScreenCover(item: $fullPreviewModel) { model in
                FullScreenCardPreview(format: effectiveFormat, model: model, style: style)
            }
            .fullScreenCover(isPresented: $isSlideshowPresented) {
                SlideshowScreen(images: pickedPhotos.map { $0.previewImage }, captions: pickedCaptions)
            }
            .task {
                // Classic composer is Footprint-only.
                style = .classic
                await initialLoad()
            }
            .onChange(of: style) { newStyle in
                cardTitle = newStyle.rawValue
                if newStyle == .worldFootprint {
                    format = .landscape
                    Task { await loadWorldFootprintData() }
                }
                updateCardModel()
            }
            .task(id: style) {
                if style == .worldFootprint {
                    await loadWorldFootprintData()
                }
                updateCardModel()
            }
            .onChange(of: format) { newValue in
                if style != .worldFootprint {
                    storedFormat = newValue.rawValue
                }
                renderedAlbumURL = nil
                renderedAlbumImage = nil
                if style == .worldFootprint { generateMapSnapshot() }
                updateCardModel()
            }
            .onChange(of: pickedPhotos.count) { _ in updateCardModel() }
            .onChange(of: pickedCaptions) { _ in updateCardModel() }
            .onChange(of: cardTitle) { _ in updateCardModel() }
            .onChange(of: showYears) { _ in updateCardModel() }
            .onChange(of: showCountries) { _ in updateCardModel() }
            .onChange(of: showCities) { _ in updateCardModel() }
            .onChange(of: mapSnapshot) { _ in updateCardModel() }
            .onChange(of: visitedCities.count) { _ in updateCardModel() }
            .onChange(of: layout) { _ in updateCardModel() }
        }
    }

    private var worldFootprintOnlyView: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Use the existing preview card (already landscape-only via effectiveFormat).
                preview
                    .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .navigationTitle("World Footprint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $isAlbumSheetPresented) {
                let items: [Any] = {
                    if let url = renderedAlbumURL { return [url] }
                    if let img = renderedAlbumImage { return [img] }
                    return []
                }()
                ActivityShareSheet(items: items)
            }
            .fullScreenCover(item: $fullPreviewModel) { model in
                FullScreenCardPreview(format: effectiveFormat, model: model, style: style)
            }
            .task {
                // Hard lock this screen to World Footprint.
                style = .worldFootprint
                format = .landscape
                cardTitle = "My Travel Footprint"
                showYears = false
                showCountries = false
                showCities = false

                await initialLoad()
                await loadWorldFootprintData()
                updateCardModel()
            }
        }
    }

    @MainActor
    private func initialLoad() async {
        if let f = FootprintDiaryCardFormat(rawValue: storedFormat) {
            format = f
        } else {
            format = .portrait
        }

        if style == .worldFootprint {
            format = .landscape
        }

        if !initialSelectedAssetIds.isEmpty, pickedPhotos.isEmpty {
            let photos = await loadPhotos(localIds: initialSelectedAssetIds)
            pickedPhotos = photos
            pickedCaptions = photos.map { $0.comment ?? "" }
        }

        await loadSummaryIfNeeded()
        updateCardModel()
    }

    private var previewHeader: some View {
        HStack {
            Text("Preview")
            Spacer()
            if !pickedPhotos.isEmpty {
                Button {
                    isSlideshowPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                        Text("Slideshow")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }

        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task {
                    await prepareAlbum()
                    isAlbumSheetPresented = true
                }
            } label: {
                if isRendering {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(isRendering || summary == nil)
        }
    }

    private func updateCardModel() {
        self.currentCardModel = makeCardModel()
    }

    private func movePhotos(from source: IndexSet, to destination: Int) {
        pickedPhotos.move(fromOffsets: source, toOffset: destination)
        pickedCaptions.move(fromOffsets: source, toOffset: destination)
        model.moveFootprintDiaryCart(fromOffsets: source, toOffset: destination)
        updateCardModel()
    }

    private var configPanel: some View {
        Group {
            // Dedicated World Footprint UI (airplane entry): no title/format/style/toggles.
            if style == .worldFootprint && isWorldFootprintOnly {
                Text("Your travel footprint, rendered as a single landscape card.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Card Title", text: $cardTitle)

                HStack {
                    Text("Show")
                    Spacer()
                    HStack(spacing: 8) {
                        Toggle("Years", isOn: $showYears)
                        Toggle("Countries", isOn: $showCountries)
                        Toggle("Cities", isOn: $showCities)
                    }
                    .toggleStyle(.button)
                    .controlSize(.mini)
                }

                // Style picker removed: Footprint and World Footprint are separate screens.

                VStack(alignment: .leading, spacing: 8) {
                    Text("Format")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Format", selection: $format) {
                        ForEach(FootprintDiaryCardFormat.allCases) { f in
                            Text(f.title).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if style == .classic {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Layout")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Layout", selection: $layout) {
                            ForEach(FootprintDiaryLayout.allCases) { l in
                                Text(l.rawValue).tag(l)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(layout.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .center, spacing: 10) {
            ResponsivePreviewCard(format: effectiveFormat, photoCount: pickedPhotos.count, layout: layout, style: style) {
                if let cardModel = currentCardModel {
                    let cardSize = (style == .classic) ? effectiveFormat.size(photoCount: cardModel.pickedImages.count, layout: cardModel.layout) : effectiveFormat.size
                    return AnyView(
                        Group {
                            if style == .classic {
                                FootprintDiaryCardView(format: format, model: cardModel)
                            } else {
                                WorldFootprintCardView(format: format, model: cardModel)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            fullPreviewModel = cardModel
                        }
                        .accessibilityLabel("Open full-screen preview")
                        .accessibilityAddTraits(.isButton)
                    )
                } else {
                    let cardSize = format.size
                    return AnyView(ProgressView().frame(width: cardSize.width, height: cardSize.height))
                }
            }
            .padding(.vertical, 8)

            if format == .landscape && style != .worldFootprint {
                Text("Tip: rotate your phone to landscape to preview this format.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
        .listRowBackground(Color.clear)
    }

    private var pickedPhotosSection: some View {
        Group {
            ForEach(pickedPhotos.indices, id: \.self) { idx in
                HStack(spacing: 12) {
                    Image(uiImage: pickedPhotos[idx].previewImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    TextField("Add a memo...", text: Binding(
                        get: { idx < pickedCaptions.count ? pickedCaptions[idx] : "" },
                        set: { newValue in
                            ensureCaptionsCapacity()
                            pickedCaptions[idx] = newValue
                            renderedAlbumURL = nil
                            renderedAlbumImage = nil
                            updateCardModel()
                        }
                    ))
                    .textFieldStyle(.plain)
                }
            }
            .onMove(perform: movePhotos)

            if isLoadingSummary {
                ProgressView("Loading summary…")
            }
        }
    }

    private func ensureCaptionsCapacity() {
        if pickedCaptions.count < pickedPhotos.count {
            pickedCaptions.append(contentsOf: Array(repeating: "", count: pickedPhotos.count - pickedCaptions.count))
        }
    }

    private func loadPhotos(localIds: [String]) async -> [SelectedPhoto] {
        var out: [SelectedPhoto] = []
        out.reserveCapacity(localIds.count)

        // 1) Fetch metadata from DB in one go
        var recordsMap: [String: DetailedPhotoRecord] = [:]
        do {
            let records = try await model.db.fetchDetailedRecords(localIds: localIds)
            for r in records {
                recordsMap[r.localId] = r
            }
        } catch {
            print("DB metadata fetch failed: \(error)")
        }

        // 2) Load images and build objects
        for id in localIds {
            if Task.isCancelled { break }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            guard let asset = assets.firstObject else { continue }
            
            if let img = await requestPreviewImage(asset: asset) {
                let rec = recordsMap[id]
                out.append(SelectedPhoto(
                    id: id,
                    asset: asset,
                    previewImage: img,
                    comment: rec?.comment,
                    countryName: rec?.countryName,
                    cityName: rec?.cityName,
                    date: asset.creationDate ?? (rec?.creationTs != nil ? Date(timeIntervalSince1970: rec!.creationTs!) : nil)
                ))
            }
        }
        return out
    }

    private func requestPreviewImage(asset: PHAsset) async -> UIImage? {
        let manager = PHImageManager.default()
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false

        // High resolution for clear preview
        let target = CGSize(width: 1600, height: 1600)

        return await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: opts) { img, _ in
                cont.resume(returning: img)
            }
        }
    }

    private func loadSummaryIfNeeded() async {
        guard summary == nil else { return }
        isLoadingSummary = true
        defer { isLoadingSummary = false }

        do {
            let s = try await model.db.countryDiarySummary()
            await MainActor.run {
                self.summary = s
                self.errorText = nil
            }
        } catch {
            await MainActor.run {
                self.summary = nil
                self.errorText = "Couldn’t load country summary: \(error.localizedDescription)"
            }
        }
    }

    private func makeCardModel() -> FootprintDiaryCardModel {
        if style == .worldFootprint {
            let s = summary
            let highlights: [FootprintDiaryCardModel.Highlight] = {
                guard let s = s else { return [] }
                return s.highlights.map {
                    FootprintDiaryCardModel.Highlight(
                        id: $0.id,
                        kind: FootprintDiaryCardModel.Highlight.Kind(rawValue: $0.kindRaw) ?? .mostPhotographed,
                        countryName: $0.countryName,
                        cityNames: [], // No cities in summary highlights yet
                        count: $0.count,
                        yearsLine: $0.yearsLine
                    )
                }
            }()

            var model = FootprintDiaryCardModel(
                title: cardTitle,
                dateRange: s?.dateRange ?? "All time",
                countriesCount: s?.countriesCount ?? 0,
                citiesCount: s?.citiesCount,
                topCountries: s?.topCountries,
                highlights: highlights,
                pickedImages: pickedPhotos.map { $0.previewImage },
                pickedCaptions: pickedCaptions,
                privacyLine: "Privacy: map visualization with city markers"
            )
            model.showYears = showYears
            model.showCountries = showCountries
            model.showCities = showCities
            
            model.visitedCities = visitedCities
            model.visitedContinents = visitedContinents
            model.mapSnapshot = mapSnapshot
            model.mapOverlaySize = mapOverlaySize
            model.mapPointForCoord = mapPointForCoord
            model.layout = layout
            return model
        } else {
            // style == .classic ("Footprint")
            // Calculate stats from pickedPhotos
            let dates = pickedPhotos.compactMap { $0.date }.sorted()
            let dateRange: String = {
                guard let first = dates.first, let last = dates.last else { return "All time" }
                let y1 = Calendar.current.component(.year, from: first)
                let y2 = Calendar.current.component(.year, from: last)
                return y1 == y2 ? "\(y1)" : "\(y1)–\(y2)"
            }()
            
            var highlights: [FootprintDiaryCardModel.Highlight] = []
            
            // Group cities by country
            let photosByCountry = Dictionary(grouping: pickedPhotos) { $0.countryName ?? "Unknown" }
            let sortedCountries = photosByCountry.keys.sorted { (lhs, rhs) -> Bool in
                (photosByCountry[lhs]?.count ?? 0) > (photosByCountry[rhs]?.count ?? 0)
            }

            if showCountries {
                for country in sortedCountries {
                    let photos = photosByCountry[country] ?? []
                    let cities = Set(photos.compactMap { $0.cityName }).sorted()
                    
                    highlights.append(FootprintDiaryCardModel.Highlight(
                        id: "country:\(country)",
                        kind: .mostPhotographed,
                        countryName: country,
                        cityNames: showCities ? cities : [],
                        count: photos.count,
                        yearsLine: nil
                    ))
                }
            } else if showCities {
                // If only cities, show them as top level
                let pickedCities = pickedPhotos.compactMap { $0.cityName }
                let cityCounts = pickedCities.reduce(into: [:]) { counts, name in
                    counts[name, default: 0] += 1
                }
                let uniqueCities = cityCounts.keys.sorted { cityCounts[$0]! > cityCounts[$1]! }
                
                highlights.append(contentsOf: uniqueCities.map { name in
                    FootprintDiaryCardModel.Highlight(
                        id: "city:\(name)",
                        kind: .mostPhotographed,
                        countryName: name, 
                        cityNames: [],
                        count: cityCounts[name],
                        yearsLine: nil
                    )
                })
            }
            
            var model = FootprintDiaryCardModel(
                title: cardTitle,
                dateRange: dateRange,
                countriesCount: Set(pickedPhotos.compactMap { $0.countryName }).count,
                citiesCount: Set(pickedPhotos.compactMap { $0.cityName }).count,
                topCountries: [],
                highlights: highlights,
                pickedImages: pickedPhotos.map { $0.previewImage },
                pickedCaptions: pickedCaptions,
                privacyLine: "Privacy: country-level (no cities, no exact pins)"
            )
            model.showYears = showYears
            model.showCountries = showCountries
            model.showCities = showCities
            model.layout = layout
            return model
        }
    }

    @MainActor
    private func prepareAlbum() async {
        guard summary != nil else { return }
        isRendering = true
        defer { isRendering = false }

        // Fetch FULL images just for export
        var fullImages: [UIImage] = []
        for photo in pickedPhotos {
            if let full = await requestFullImage(asset: photo.asset) {
                fullImages.append(full)
            } else {
                fullImages.append(photo.previewImage) // fallback
            }
        }

        var cardModel = makeCardModel()
        cardModel.pickedImages = fullImages

        do {
            let image = try renderCardImage(format: effectiveFormat, model: cardModel)
            renderedAlbumImage = image

            // Also write a PNG for apps that prefer URLs.
            let url = try writePNGToTemporaryFile(image: image, fileName: "FootprintAlbum-\(format.rawValue).png")
            renderedAlbumURL = url
        } catch {
            errorText = "Couldn’t prepare album: \(error.localizedDescription)"
        }
    }

    private func requestFullImage(asset: PHAsset) async -> UIImage? {
        let manager = PHImageManager.default()
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false

        // Export size
        let target = CGSize(width: 1800, height: 1800)

        return await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: opts) { img, _ in
                cont.resume(returning: img)
            }
        }
    }

    private func renderCardImage(format: FootprintDiaryCardFormat, model: FootprintDiaryCardModel, scale: CGFloat = 1) throws -> UIImage {
        let clampedScale = max(0.1, min(1, scale))
        let originalSize = (style == .classic) ? format.size(photoCount: model.pickedImages.count, layout: model.layout) : format.size
        let targetSize = CGSize(width: floor(originalSize.width * clampedScale), height: floor(originalSize.height * clampedScale))

        // Render smaller for interactive preview to keep taps snappy.
        // We still layout at the original "design" size, then scale down into the target bounds.
        let root = AnyView(
            style == .classic
                ? AnyView(FootprintDiaryCardView(format: format, model: model))
                : AnyView(WorldFootprintCardView(format: format, model: model))
        )
        .frame(width: originalSize.width, height: originalSize.height)
        .scaleEffect(clampedScale, anchor: .topLeading)
        .frame(width: targetSize.width, height: targetSize.height, alignment: .topLeading)

        // iOS 15-compatible render path: snapshot a UIHostingController.
        // (ImageRenderer is iOS 16+, and this project is currently building against iOS 15.2 SDK.)
        let controller = UIHostingController(rootView: root)
        controller.view.bounds = CGRect(origin: .zero, size: targetSize)
        controller.view.backgroundColor = .clear

        // Ensure layout happens before snapshotting; avoid waiting for a full screen update.
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { ctx in
            // Use layer.render to avoid "has not been rendered" warnings from drawHierarchy.
            // This is also typically faster for offscreen snapshotting.
            controller.view.layer.render(in: ctx.cgContext)
        }
    }

    private func writePNGToTemporaryFile(image: UIImage, fileName: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(fileName)

        guard let data = image.pngData() else {
            throw NSError(domain: "FootprintDiary", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }

        try data.write(to: url, options: [.atomic])
        return url
    }

    private func loadWorldFootprintData() async {
        do {
            // 1. Get global clusters from DB (Country level)
            let globalCountryClusters = try await model.db.clusters(in: .world, precision: .country)
            
            // 2. Get countries from currently picked photos
            var pickedCountries: [ClusterBubble] = []
            var seenCountries = Set<String>()
            
            for photo in pickedPhotos {
                if let loc = photo.asset.location, let name = photo.countryName {
                    if !seenCountries.contains(name) {
                        pickedCountries.append(ClusterBubble(
                            id: "picked_country:\(name)",
                            title: name,
                            count: 1,
                            centerLat: loc.coordinate.latitude,
                            centerLon: loc.coordinate.longitude
                        ))
                        seenCountries.insert(name)
                    }
                }
            }
            
            // 3. Merge: prioritize picked countries, then add top global ones
            let combined = (pickedCountries + globalCountryClusters.filter { !seenCountries.contains($0.title) })
                .sorted { $0.count > $1.count }
                .prefix(30)
            
            await MainActor.run {
                self.visitedCities = Array(combined) // We reuse visitedCities property for "Locations to Pin"
            }
            


            // After updating pinned locations, ensure the map reflects the latest state.
            // Even if there are *no* photos (and thus no pins), we still want to show a full-world map.
            await MainActor.run {
                self.mapSnapshot = nil
            }
            generateMapSnapshot()
        } catch {
            print("Failed to load world footprint: \(error)")
        }
    }

    private func generateMapSnapshot() {
        // World Footprint now uses a static full-world rectangular equirectangular image
        // (asset: WorldMapBorderRect). We compute a lat/lon -> pixel projection closure.
        // IMPORTANT: projection assumes a 2:1 map (width = 2 * height).
        if style == .worldFootprint {
            let baseSize = CGSize(width: 2048, height: 1024)

            func projectEquirectangular(_ coord: CLLocationCoordinate2D) -> CGPoint {
                let lon = coord.longitude
                let lat = coord.latitude
                let x = (lon + 180.0) / 360.0 * baseSize.width
                let y = (90.0 - lat) / 180.0 * baseSize.height
                return CGPoint(x: x, y: y)
            }

            // For World Footprint we don't need MapKit snapshots anymore; just populate the projection.
            // Also store the "base" overlay size so the view can scale points into its GeometryReader.
            self.mapOverlaySize = baseSize
            self.mapPointForCoord = projectEquirectangular
            self.mapSnapshot = nil
            return
        }

        // Cancel any pending snapshot to avoid concurrent Metal operations
        activeSnapshotter?.cancel()
        
        let options = MKMapSnapshotter.Options()
        
        let locations = self.visitedCities

        // Helpers for handling longitudes across the dateline.
        func normalizeLon(_ lon: CLLocationDegrees) -> CLLocationDegrees {
            var x = lon.truncatingRemainder(dividingBy: 360)
            if x < -180 { x += 360 }
            if x > 180 { x -= 360 }
            return x
        }

        /// Pick a center longitude that minimizes the wrap discontinuity for a set of longitudes.
        func bestCenterLongitude(for lons: [CLLocationDegrees]) -> CLLocationDegrees {
            guard !lons.isEmpty else { return 0 }
            let sorted = lons.sorted()
            if sorted.count == 1 { return sorted[0] }

            // Consider the largest gap in the circular list; the opposite side of that gap is a good window.
            var bestGap: CLLocationDegrees = -1
            var bestIndex: Int = 0
            for i in 0..<sorted.count {
                let a = sorted[i]
                let b = (i == sorted.count - 1) ? (sorted[0] + 360) : sorted[i + 1]
                let gap = b - a
                if gap > bestGap {
                    bestGap = gap
                    bestIndex = i
                }
            }

            let start = sorted[(bestIndex + 1) % sorted.count]
            let end = sorted[bestIndex] + 360
            let center = (start + end) / 2
            return normalizeLon(center)
        }

        /// Minimal covering longitudinal span in degrees (0...360) for a set of longitudes.
        func minimalCoveringLonSpan(for lons: [CLLocationDegrees]) -> CLLocationDegrees {
            guard !lons.isEmpty else { return 0 }
            let sorted = lons.sorted()
            if sorted.count == 1 { return 0 }

            var bestGap: CLLocationDegrees = -1
            for i in 0..<sorted.count {
                let a = sorted[i]
                let b = (i == sorted.count - 1) ? (sorted[0] + 360) : sorted[i + 1]
                bestGap = max(bestGap, b - a)
            }
            // If best gap is large, the minimal covering span is the remainder of the circle.
            let span = max(0, 360 - bestGap)
            return min(360, span)
        }

        // Option B: Keep MapKit styling but "show as much as possible" by centering the map
        // around the user’s pins (handles dateline wrap) and choosing an aspect-aware span.
        // Note: MapKit snapshots are not guaranteed to show a true 360° wrap in one image.
        let centerLon: CLLocationDegrees = {
            let lons = locations.map { normalizeLon($0.centerLon) }
            guard !lons.isEmpty else { return 0 }
            return bestCenterLongitude(for: lons)
        }()

        // Always render the world map snapshot in landscape.
        options.size = FootprintDiaryCardFormat.landscape.size
        options.mapType = .standard

        let aspect = options.size.width / max(options.size.height, 1)

        // Compute the smallest longitudinal window covering all points (with padding),
        // then clamp to a reasonable maximum because MapKit will clamp anyway.
        let lonDelta: CLLocationDegrees = {
            let lons = locations.map { normalizeLon($0.centerLon) }
            guard !lons.isEmpty else { return 200 }
            let window = minimalCoveringLonSpan(for: lons) // 0...360
            let padded = min(360, window + 40)
            return max(120, min(220, padded))
        }()

        // Aspect-aware latitude delta so we don’t crop longitudes too aggressively.
        let latDelta: CLLocationDegrees = max(90, min(170, lonDelta / max(aspect, 0.1)))

        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
        
        let snapshotter = MKMapSnapshotter(options: options)
        self.activeSnapshotter = snapshotter
        
        snapshotter.start { snapshot, error in
            defer { 
                if self.activeSnapshotter === snapshotter {
                    self.activeSnapshotter = nil 
                }
            }
            
            guard let snapshot = snapshot else { return }
            
            
            let renderer = UIGraphicsImageRenderer(size: options.size)
            let resultImage = renderer.image { ctx in
                // Use the CGImage to help avoid Metal/GPU resource lifetime issues
                if let cgImage = snapshot.image.cgImage {
                    let rect = CGRect(origin: .zero, size: options.size)
                    ctx.cgContext.saveGState()
                    ctx.cgContext.translateBy(x: 0, y: options.size.height)
                    ctx.cgContext.scaleBy(x: 1, y: -1)
                    ctx.cgContext.draw(cgImage, in: rect)
                    ctx.cgContext.restoreGState()
                } else {
                    snapshot.image.draw(at: .zero)
                }
                
                let titleAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 28, weight: .bold),
                    .foregroundColor: UIColor.black
                ]
                
                for loc in locations {
                    let point = snapshot.point(for: CLLocationCoordinate2D(latitude: loc.centerLat, longitude: loc.centerLon))
                    
                    // Pin shadow
                    ctx.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.2).cgColor)
                    ctx.cgContext.fillEllipse(in: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24).offsetBy(dx: 2, dy: 4))
                    
                    // Pin body (white outline)
                    ctx.cgContext.setFillColor(UIColor.white.cgColor)
                    ctx.cgContext.fillEllipse(in: CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36))
                    
                    // Pin center (vibrant orange/red)
                    ctx.cgContext.setFillColor(UIColor.systemOrange.cgColor)
                    ctx.cgContext.fillEllipse(in: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24))
                    
                    // Label
                    let label = loc.title as NSString
                    let size = label.size(withAttributes: titleAttr)
                    let labelRect = CGRect(x: point.x - size.width/2 - 12, y: point.y + 24, width: size.width + 24, height: size.height + 10)
                    
                    // Label background
                    ctx.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.95).cgColor)
                    let labelPath = UIBezierPath(roundedRect: labelRect, cornerRadius: 8)
                    ctx.cgContext.addPath(labelPath.cgPath)
                    ctx.cgContext.fillPath()
                    
                    // Label border
                    ctx.cgContext.setStrokeColor(UIColor.black.withAlphaComponent(0.15).cgColor)
                    ctx.cgContext.setLineWidth(1.5)
                    ctx.cgContext.addPath(labelPath.cgPath)
                    ctx.cgContext.strokePath()
                    
                    label.draw(at: CGPoint(x: point.x - size.width/2, y: point.y + 28), withAttributes: titleAttr)
                }
            }

            DispatchQueue.main.async {
                self.mapSnapshot = resultImage
                self.mapPointForCoord = { coord in
                    snapshot.point(for: coord)
                }
            }
        }
    }
}

private struct ResponsivePreviewCard: View {
    let format: FootprintDiaryCardFormat
    let photoCount: Int
    let layout: FootprintDiaryLayout
    let style: FootprintDiaryStyle
    let content: () -> AnyView

    @State private var availableWidth: CGFloat = 0

    private var cardSize: CGSize {
        (style == .classic) ? format.size(photoCount: photoCount, layout: layout) : format.size
    }

    var body: some View {
        VStack {
            GeometryReader { geo in
                let outerWidth = geo.size.width
                // Use the *actual* available width for layout so the preview fills the page.
                // (Using a larger "previewWidth" than the container can cause odd sizing/clipping.)
                let previewWidth = outerWidth
                let previewHeight = previewWidth * (cardSize.height / cardSize.width)
                let scale = previewWidth / cardSize.width

                content()
                    .frame(width: cardSize.width, height: cardSize.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: previewWidth, height: previewHeight, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
                    .onAppear { availableWidth = outerWidth }
                    .onChange(of: outerWidth) { newValue in
                        availableWidth = newValue
                    }
            }
            .frame(height: max(220, max(240, availableWidth) * (cardSize.height / cardSize.width)))
        }
        .frame(maxWidth: .infinity)
    }
}



private struct FullScreenCardPreview: View {
    @Environment(\.dismiss) private var dismiss

    let format: FootprintDiaryCardFormat
    let model: FootprintDiaryCardModel
    let style: FootprintDiaryStyle

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        let cardSize = (style == .classic) ? format.size(photoCount: model.pickedImages.count, layout: model.layout) : format.size
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                // Calculate fit scale
                let sW = geo.size.width / cardSize.width
                let fitScale = min(geo.size.width / cardSize.width, geo.size.height / cardSize.height) * 0.95
                let currentScale = fitScale * scale

                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    ZStack {
                        Group {
                            if style == .classic {
                                FootprintDiaryCardView(format: format, model: model)
                            } else {
                                WorldFootprintCardView(format: format, model: model)
                            }
                        }
                        .frame(width: cardSize.width, height: cardSize.height)
                        .scaleEffect(currentScale, anchor: .center)
                        .frame(width: max(geo.size.width, cardSize.width * currentScale), 
                               height: max(geo.size.height, cardSize.height * currentScale))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value / lastScale
                            lastScale = value
                            scale *= delta
                        }
                        .onEnded { _ in
                            lastScale = 1.0
                            if scale < 1.0 {
                                withAnimation(.spring()) {
                                    scale = 1.0
                                }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        scale = scale > 1.1 ? 1.0 : 2.5
                    }
                }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .padding(16)
        }
    }
}

struct SlideshowScreen: View {
    @Environment(\.dismiss) private var dismiss
    
    let images: [UIImage]
    let captions: [String]
    
    @State private var currentIndex = 0
    @State private var isPlaying = true
    @State private var timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            TabView(selection: $currentIndex) {
                ForEach(0..<images.count, id: \.self) { i in
                    ZStack {
                        Image(uiImage: images[i])
                            .resizable()
                            .scaledToFit()
                            .tag(i)
                        
                        VStack {
                            Spacer()
                            if i < captions.count && !captions[i].isEmpty {
                                Text(captions[i])
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 12)
                                    .background(.black.opacity(0.6))
                                    .clipShape(Capsule())
                                    .padding(.bottom, 60)
                            }
                        }
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onReceive(timer) { _ in
                if isPlaying {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        currentIndex = (currentIndex + 1) % images.count
                    }
                }
            }
            .onTapGesture {
                isPlaying.toggle()
            }
            
            // Progress Bar
            VStack {
                HStack(spacing: 4) {
                    ForEach(0..<images.count, id: \.self) { i in
                        Rectangle()
                            .fill(i == currentIndex ? Color.white : Color.white.opacity(0.3))
                            .frame(height: 3)
                            .animation(.spring(), value: currentIndex)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .bold))
                            .padding(12)
                            .background(.black.opacity(0.5))
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                    .padding()
                    
                    Spacer()
                    
                    Button {
                        isPlaying.toggle()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .padding(12)
                            .background(.black.opacity(0.5))
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                    .padding()
                }
                
                Spacer()
            }
        }
    }
}
