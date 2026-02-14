import SwiftUI
import UIKit
import Photos

struct FootprintDiaryComposerScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let initialSelectedAssetIds: [String]

    init(initialSelectedAssetIds: [String] = []) {
        self.initialSelectedAssetIds = initialSelectedAssetIds
    }

    @AppStorage("footprintDiary.format") private var storedFormat: String = FootprintDiaryCardFormat.portrait.rawValue
    @State private var format: FootprintDiaryCardFormat = .portrait

    @State private var pickedImages: [UIImage] = []
    @State private var pickedCaptions: [String] = []

    @State private var isLoadingSummary: Bool = false
    @State private var summary: CountryDiarySummary? = nil
    @State private var errorText: String? = nil

    @State private var renderedShareURL: URL? = nil
    @State private var renderedShareImage: UIImage? = nil
    @State private var isRendering: Bool = false

    @State private var isShareSheetPresented: Bool = false

    @State private var isFullPreviewPresented: Bool = false
    @State private var fullPreviewImage: UIImage? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    formatPicker
                    preview
                    pickedPhotosSection

                    if let err = errorText {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Footprint Diary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isRendering ? "Preparing…" : "Share") {
                        Task {
                            await prepareShare()
                            isShareSheetPresented = true
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
            .fullScreenCover(isPresented: $isFullPreviewPresented) {
                FullScreenImagePreview(image: fullPreviewImage)
            }
            .task {
                if let f = FootprintDiaryCardFormat(rawValue: storedFormat) {
                    format = f
                } else {
                    format = .portrait
                }

                // Preload from the timeline cart if provided.
                if !initialSelectedAssetIds.isEmpty, pickedImages.isEmpty {
                    let imgs = await loadImages(localIds: initialSelectedAssetIds)
                    pickedImages = imgs
                    ensureCaptionsCapacity()
                }

                await loadSummaryIfNeeded()
            }
            .onChange(of: format) { newValue in
                storedFormat = newValue.rawValue
                renderedShareURL = nil
                renderedShareImage = nil
            }
        }
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Format")
                .font(.headline)

            Picker("Format", selection: $format) {
                ForEach(FootprintDiaryCardFormat.allCases) { f in
                    Text(f.title).tag(f)
                }
            }
            .pickerStyle(.segmented)

            Text("Portrait is best for Stories. Square is good for grid posts. Landscape is best viewed with your phone rotated.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.headline)

            ResponsivePreviewCard(format: format) {
                let cardModel = makeCardModel()
                return AnyView(
                    Button {
                        // Show the full-screen UI immediately (spinner), then render.
                        fullPreviewImage = nil
                        isFullPreviewPresented = true

                        // Render a high-res preview on demand.
                        Task { @MainActor in
                            do {
                                // Half-res is plenty for full-screen interactive preview; keep 1.0x for Share.
                                fullPreviewImage = try renderCardImage(format: format, model: cardModel, scale: 0.5)
                            } catch {
                                errorText = "Couldn’t render preview: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        FootprintDiaryCardView(format: format, model: cardModel)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open full-screen preview")
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)

            if format == .landscape {
                Text("Tip: rotate your phone to landscape to preview this format.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("Privacy: this diary card is country-level only. No cities, no exact pins.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var pickedPhotosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Picked photos")
                .font(.headline)

            if pickedImages.isEmpty {
                Text("No photos selected. Go back to Timeline and swipe a photo row → Share.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Selected \(pickedImages.count) / 9")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("Optional captions")
                    .font(.subheadline.weight(.semibold))

                ForEach(pickedImages.indices, id: \.self) { idx in
                    TextField("Caption \(idx + 1)", text: Binding(
                        get: { idx < pickedCaptions.count ? pickedCaptions[idx] : "" },
                        set: { newValue in
                            ensureCaptionsCapacity()
                            pickedCaptions[idx] = newValue
                            renderedShareURL = nil
                            renderedShareImage = nil
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            if isLoadingSummary {
                ProgressView("Loading summary…")
                    .padding(.top, 8)
            }
        }
    }

    private func ensureCaptionsCapacity() {
        if pickedCaptions.count < pickedImages.count {
            pickedCaptions.append(contentsOf: Array(repeating: "", count: pickedImages.count - pickedCaptions.count))
        }
    }

    private func loadImages(localIds: [String]) async -> [UIImage] {
        var out: [UIImage] = []
        out.reserveCapacity(localIds.count)

        // Keep the cart order.
        for id in localIds {
            if Task.isCancelled { break }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            guard let asset = assets.firstObject else { continue }
            if let img = await requestShareImage(asset: asset) {
                out.append(img)
            }
        }

        return out
    }

    private func requestShareImage(asset: PHAsset) async -> UIImage? {
        let manager = PHImageManager.default()
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false

        // Render-sized images; we don't need full original.
        let target = CGSize(width: 1800, height: 1800)

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

        return FootprintDiaryCardModel(
            title: "Footprint Diary",
            dateRange: s?.dateRange ?? "All time",
            countriesCount: s?.countriesCount ?? 0,
            highlights: highlights,
            pickedImages: pickedImages,
            pickedCaptions: pickedCaptions,
            privacyLine: "Privacy: country-level (no cities, no exact pins)"
        )
    }

    @MainActor
    private func prepareShare() async {
        guard summary != nil else { return }
        isRendering = true
        defer { isRendering = false }

        let cardModel = makeCardModel()

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

    private func renderCardImage(format: FootprintDiaryCardFormat, model: FootprintDiaryCardModel, scale: CGFloat = 1) throws -> UIImage {
        let clampedScale = max(0.1, min(1, scale))
        let originalSize = format.size
        let targetSize = CGSize(width: floor(originalSize.width * clampedScale), height: floor(originalSize.height * clampedScale))

        // Render smaller for interactive preview to keep taps snappy.
        // We still layout at the original "design" size, then scale down into the target bounds.
        let root = FootprintDiaryCardView(format: format, model: model)
            .frame(width: originalSize.width, height: originalSize.height)
            .scaleEffect(clampedScale, anchor: .topLeading)
            .frame(width: targetSize.width, height: targetSize.height)

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
                    .frame(width: previewWidth, height: previewHeight)
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

private struct FullScreenImagePreview: View {
    @Environment(\.dismiss) private var dismiss

    let image: UIImage?

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Group {
                if let image = image {
                    GeometryReader { geo in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scaleEffect(scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        scale = max(1, min(4, lastScale * value))
                                    }
                                    .onEnded { _ in
                                        lastScale = scale
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                    if scale > 1 {
                                        scale = 1
                                        lastScale = 1
                                    } else {
                                        scale = 2
                                        lastScale = 2
                                    }
                                }
                            }
                    }
                } else {
                    ProgressView()
                        .tint(.white)
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
