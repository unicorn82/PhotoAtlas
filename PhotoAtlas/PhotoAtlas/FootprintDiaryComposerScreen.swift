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

    @State private var pickedPhotos: [SelectedPhoto] = []
    @State private var pickedCaptions: [String] = []

    @State private var isLoadingSummary: Bool = false
    @State private var summary: CountryDiarySummary? = nil
    @State private var errorText: String? = nil

    @State private var renderedShareURL: URL? = nil
    @State private var renderedShareImage: UIImage? = nil
    @State private var isRendering: Bool = false

    @State private var isShareSheetPresented: Bool = false

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
    @State private var mapPointForCoord: ((CLLocationCoordinate2D) -> CGPoint)?

    var body: some View {
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
                    Text("Preview")
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
            .navigationTitle("Footprint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await prepareShare()
                            isShareSheetPresented = true
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
            .sheet(isPresented: $isShareSheetPresented) {
                let items: [Any] = {
                    if let url = renderedShareURL { return [url] }
                    if let img = renderedShareImage { return [img] }
                    return []
                }()
                ActivityShareSheet(items: items)
            }
            .fullScreenCover(item: $fullPreviewModel) { model in
                FullScreenCardPreview(format: format, model: model, style: style)
            }
            .task {
                if let f = FootprintDiaryCardFormat(rawValue: storedFormat) {
                    format = f
                } else {
                    format = .portrait
                }

                // Preload from the timeline cart if provided.
                if !initialSelectedAssetIds.isEmpty, pickedPhotos.isEmpty {
                    let photos = await loadPhotos(localIds: initialSelectedAssetIds)
                    pickedPhotos = photos
                    // Transfer comments from photos to captions
                    pickedCaptions = photos.map { $0.comment ?? "" }
                }

                await loadSummaryIfNeeded()
                updateCardModel()
            }
            .onChange(of: style) { newStyle in
                cardTitle = newStyle.rawValue
                if newStyle == .worldFootprint {
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
                storedFormat = newValue.rawValue
                renderedShareURL = nil
                renderedShareImage = nil
                if style == .worldFootprint {
                    generateMapSnapshot()
                }
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Style")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Style", selection: $style) {
                    ForEach(FootprintDiaryStyle.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }

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
        }
    }

    private var preview: some View {
        VStack(alignment: .center, spacing: 10) {
            ResponsivePreviewCard(format: format) {
                if let cardModel = currentCardModel {
                    AnyView(
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
                    AnyView(ProgressView().frame(width: format.size.width, height: format.size.height))
                }
            }
            .padding(.vertical, 8)

            if format == .landscape {
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
                            renderedShareURL = nil
                            renderedShareImage = nil
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
            model.mapPointForCoord = mapPointForCoord
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
            
            // 1) Countries as badges
            if showCountries {
                let pickedCountries = pickedPhotos.compactMap { $0.countryName }
                let countryCounts = pickedCountries.reduce(into: [:]) { counts, name in
                    counts[name, default: 0] += 1
                }
                let uniqueCountries = countryCounts.keys.sorted { countryCounts[$0]! > countryCounts[$1]! }
                
                highlights.append(contentsOf: uniqueCountries.map { name in
                    FootprintDiaryCardModel.Highlight(
                        id: "country:\(name)",
                        kind: .mostPhotographed,
                        countryName: name,
                        count: countryCounts[name],
                        yearsLine: nil
                    )
                })
            }
            
            // 2) Cities as badges
            if showCities {
                let pickedCities = pickedPhotos.compactMap { $0.cityName }
                let cityCounts = pickedCities.reduce(into: [:]) { counts, name in
                    counts[name, default: 0] += 1
                }
                let uniqueCities = cityCounts.keys.sorted { cityCounts[$0]! > cityCounts[$1]! }
                
                highlights.append(contentsOf: uniqueCities.map { name in
                    FootprintDiaryCardModel.Highlight(
                        id: "city:\(name)",
                        kind: .mostPhotographed,
                        countryName: name, // Reuse field for city name display
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
            return model
        }
    }

    @MainActor
    private func prepareShare() async {
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
            let image = try renderCardImage(format: format, model: cardModel)
            renderedShareImage = image

            // Also write a PNG for apps that prefer URLs.
            let url = try writePNGToTemporaryFile(image: image, fileName: "FootprintDiary-\(format.rawValue).png")
            renderedShareURL = url
        } catch {
            errorText = "Couldn’t prepare share: \(error.localizedDescription)"
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
        let originalSize = format.size
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
            if visitedCities.isEmpty {
                let clusters = try await model.db.clusters(in: .world, precision: .city)
                let top20 = clusters.sorted { $0.count > $1.count }.prefix(20)
                await MainActor.run {
                    self.visitedCities = Array(top20)
                }
            }
            
            if mapSnapshot == nil {
                generateMapSnapshot()
            }

            // Infer continents from cities if needed
            if visitedContinents.isEmpty && !visitedCities.isEmpty {
                let calculatedContinents = Set(visitedCities.map { city -> String in
                    let lat = city.centerLat
                    let lon = city.centerLon
                    
                    if lat > 12 && lon < -30 { return "North America" }
                    if lat <= 12 && lon < -30 { return "South America" }
                    if lat > 35 && lon >= -30 && lon < 45 { return "Europe" }
                    if lat <= 35 && lon >= -20 && lon < 60 { return "Africa" }
                    if lat <= -10 && lon > 100 { return "Oceania" }
                    if lon >= 45 { return "Asia" }
                    return "Unknown"
                })
                let finalContinents = Array(calculatedContinents.filter { $0 != "Unknown" }).sorted()
                await MainActor.run {
                    self.visitedContinents = finalContinents
                }
            }
        } catch {
            print("Failed to load world footprint: \(error)")
        }
    }

    private func generateMapSnapshot() {
        let options = MKMapSnapshotter.Options()
        // World region
        options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 20, longitude: 0), span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 360))
        // Match the card format size for accurate pin projection
        options.size = format.size
        options.mapType = .mutedStandard
        // options.pointOfInterestFilter = .excludingAll 

        let cities = self.visitedCities // Capture
        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start { snapshot, error in
            guard let snapshot = snapshot else { return }
            
            // Draw pins directly into the image to ensure perfect alignment forever
            let renderer = UIGraphicsImageRenderer(size: options.size)
            let resultImage = renderer.image { ctx in
                snapshot.image.draw(at: .zero)
                
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 32), // Increased size for high-res card
                    .foregroundColor: UIColor.black
                ]
                
                for city in cities {
                    let point = snapshot.point(for: CLLocationCoordinate2D(latitude: city.centerLat, longitude: city.centerLon))
                    
                    // Draw a robust red pin dot with larger shadow/outline
                    let dotSize: CGFloat = 24
                    let dotRect = CGRect(x: point.x - dotSize/2, y: point.y - dotSize/2, width: dotSize, height: dotSize)
                    
                    ctx.cgContext.setFillColor(UIColor.white.cgColor)
                    ctx.cgContext.fillEllipse(in: dotRect.insetBy(dx: -6, dy: -6))
                    ctx.cgContext.setFillColor(UIColor.systemRed.cgColor)
                    ctx.cgContext.fillEllipse(in: dotRect)
                    
                    // Draw city label
                    let label = city.title as NSString
                    let size = label.size(withAttributes: attributes)
                    
                    // Label background (pill style)
                    let labelRect = CGRect(x: point.x - size.width/2 - 12, y: point.y + 20, width: size.width + 24, height: size.height + 8)
                    ctx.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
                    let path = UIBezierPath(roundedRect: labelRect, cornerRadius: 10)
                    ctx.cgContext.addPath(path.cgPath)
                    ctx.cgContext.fillPath()
                    
                    // Label stroke
                    ctx.cgContext.setStrokeColor(UIColor.black.withAlphaComponent(0.1).cgColor)
                    ctx.cgContext.setLineWidth(1)
                    ctx.cgContext.addPath(path.cgPath)
                    ctx.cgContext.strokePath()
                    
                    label.draw(at: CGPoint(x: point.x - size.width/2, y: point.y + 24), withAttributes: attributes)
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
    let content: () -> AnyView

    @State private var availableWidth: CGFloat = 0

    var body: some View {
        VStack {
            GeometryReader { geo in
                let outerWidth = geo.size.width
                // Use the *actual* available width for layout so the preview fills the page.
                // (Using a larger "previewWidth" than the container can cause odd sizing/clipping.)
                let previewWidth = outerWidth
                let previewHeight = previewWidth * (format.size.height / format.size.width)
                let scale = previewWidth / format.size.width

                content()
                    .frame(width: format.size.width, height: format.size.height)
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
            .frame(height: max(220, max(240, availableWidth) * (format.size.height / format.size.width)))
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
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                // Calculate fit scale
                let sW = geo.size.width / format.size.width
                let fitScale = min(geo.size.width / format.size.width, geo.size.height / format.size.height) * 0.95
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
                        .frame(width: format.size.width, height: format.size.height)
                        .scaleEffect(currentScale, anchor: .center)
                        .frame(width: max(geo.size.width, format.size.width * currentScale), 
                               height: max(geo.size.height, format.size.height * currentScale))
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
