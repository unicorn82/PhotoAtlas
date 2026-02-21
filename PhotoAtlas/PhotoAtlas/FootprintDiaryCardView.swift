import SwiftUI
import CoreLocation

enum FootprintDiaryCardFormat: String, CaseIterable, Identifiable {
    case portrait
    case square
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait: return "Portrait"
        case .square: return "Square"
        case .landscape: return "Landscape"
        }
    }

    /// Render size (share-friendly).
    var size: CGSize {
        switch self {
        case .portrait: return CGSize(width: 1080, height: 1350)
        case .square: return CGSize(width: 1080, height: 1080)
        case .landscape: return CGSize(width: 1350, height: 1080)
        }
    }
}

struct FootprintDiaryCardModel: Identifiable {
    let id = UUID()
    struct Highlight: Identifiable {
        enum Kind: String {
            case mostPhotographed
            case firstStamp
            case latestStamp

            var label: String {
                switch self {
                case .mostPhotographed: return "Most photographed"
                case .firstStamp: return "First stamp"
                case .latestStamp: return "Latest stamp"
                }
            }
        }

        let id: String
        let kind: Kind
        let countryName: String
        let count: Int?
        let yearsLine: String?
    }

    let title: String
    let dateRange: String
    let countriesCount: Int
    let citiesCount: Int?
    let topCountries: [CountryDiarySummary.TopCountry]?
    let highlights: [Highlight]

    // New: World Footprint map data
    var visitedCities: [ClusterBubble] = []
    var visitedContinents: [String] = []

    // Snapshot image + projection closure (passed from Composer)
    var mapSnapshot: UIImage?
    var mapOverlaySize: CGSize = .zero
    var mapPointForCoord: ((CLLocationCoordinate2D) -> CGPoint)?

    /// User-selected images (1...9 recommended).
    var pickedImages: [UIImage]

    /// Optional user-provided captions for the picked images (same count or empty).
    let pickedCaptions: [String]

    /// Metadata visibility toggles
    var showYears: Bool = true
    var showCountries: Bool = true
    var showCities: Bool = true

    /// Privacy line to display.
    let privacyLine: String
}

/// A shareable, diary-style card.
///
/// Design goals:
/// - countries-first
/// - feels like a travel log/diary
/// - no exact pins
struct FootprintDiaryCardView: View {
    let format: FootprintDiaryCardFormat
    let model: FootprintDiaryCardModel

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 24) {
                header

                if model.showCountries && !model.highlights.isEmpty {
                    highlights
                }

                pickedPhotos

                footer
            }
            .padding(48)
        }
        .frame(width: format.size.width, height: format.size.height)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.03, green: 0.03, blue: 0.05),
                Color(red: 0.04, green: 0.07, blue: 0.15)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(colors: [Color(red: 0.10, green: 0.18, blue: 0.36), .clear], center: .topLeading, startRadius: 10, endRadius: 600)
                .opacity(0.7)
        )
        .overlay(
            RadialGradient(colors: [Color(red: 0.30, green: 0.12, blue: 0.40), .clear], center: .topTrailing, startRadius: 20, endRadius: 700)
                .opacity(0.6)
        )
        .overlay(
            RadialGradient(colors: [Color(red: 0.06, green: 0.25, blue: 0.21), .clear], center: .bottomLeading, startRadius: 20, endRadius: 700)
                .opacity(0.55)
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.title)
                .font(.system(size: 82, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))

            HStack(spacing: 12) {
                let showY = model.showYears && !model.dateRange.isEmpty
                
                if showY {
                    Text(model.dateRange)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private var mapGrid: some View {
        Canvas { context, size in
            // vertical lines
            let step: CGFloat = 96
            var x: CGFloat = 0
            while x <= size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 1)
                x += step
            }

            // horizontal lines
            var y: CGFloat = 0
            while y <= size.height {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(p, with: .color(.white.opacity(0.10)), lineWidth: 1)
                y += step
            }
        }
    }

    private var highlights: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(model.highlights.prefix(5)) { h in
                    HStack(spacing: 10) {
                        Text(h.countryName)
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        
                        if let count = h.count {
                            Text("\(count)")
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
        }
    }

    private func highlightRow(_ h: FootprintDiaryCardModel.Highlight) -> some View {
        HStack(spacing: 12) {
            Text(h.kind.label)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.20))
                .overlay(
                    Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .clipShape(Capsule())

            Text(h.countryName)
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let count = h.count {
                    Text(NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal))
                        .font(.system(size: 24, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                }
                if let years = h.yearsLine {
                    Text(years)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.56))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.white.opacity(0.055))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var pickedPhotos: some View {
        VStack(alignment: .leading, spacing: 20) {
            let imgs = model.pickedImages
            if imgs.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 80))
                        .foregroundStyle(.white.opacity(0.15))
                    Text("Select up to 9 photos to showcase your footprint.")
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 400)
                .background(.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
            } else {
                photoLayout(imgs: imgs)
            }
        }
    }

    @ViewBuilder
    private func photoLayout(imgs: [UIImage]) -> some View {
        let count = imgs.count
        if count == 1 {
            singleImageLayout(img: imgs[0], index: 0)
        } else if count == 2 {
            HStack(spacing: 16) {
                ForEach(0..<2) { i in
                    imageTile(img: imgs[i], index: i)
                }
            }
            .frame(height: 850)
        } else if count == 3 {
            HStack(spacing: 16) {
                imageTile(img: imgs[0], index: 0)
                VStack(spacing: 16) {
                    imageTile(img: imgs[1], index: 1)
                    imageTile(img: imgs[2], index: 2)
                }
            }
            .frame(height: 900)
        } else {
            // Grid for 4-9 images
            let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: count <= 4 ? 2 : 3)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(0..<count, id: \.self) { i in
                    imageTile(img: imgs[i], index: i)
                        .frame(height: count <= 6 ? 440 : 340)
                }
            }
        }
    }

    private func singleImageLayout(img: UIImage, index: Int) -> some View {
        imageTile(img: img, index: index)
            .frame(height: 1000)
    }

    private func imageTile(img: UIImage, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(minHeight: 0, maxHeight: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )

            if index < model.pickedCaptions.count, !model.pickedCaptions[index].isEmpty {
                Text(model.pickedCaptions[index])
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .padding(.horizontal, 8)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            
            Text("photoatlas.app")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))
        }
    }
}

// MARK: - World Footprint (Infographic Style)

struct WorldFootprintCardView: View {
    let format: FootprintDiaryCardFormat
    let model: FootprintDiaryCardModel

    var body: some View {
        ZStack {
            // Paper texture background
            Color(red: 0.97, green: 0.96, blue: 0.93).ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "airplane")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(Color(red: 0.2, green: 0.4, blue: 0.6))
                    Text("My Travel Footprint")
                        .font(.system(size: 42, weight: .heavy, design: .serif))
                        .foregroundStyle(Color(red: 0.1, green: 0.25, blue: 0.45))
                }
                .padding(.top, 32)
                .padding(.bottom, 24)

                // Main Card Container
                VStack(spacing: 0) {
                    // Top Stats Bar
                    HStack {
                        statItem(icon: "flag.fill", label: "Countries Visited", value: "\(model.countriesCount)", color: .red)

                        Divider().frame(height: 24)

                        statItem(icon: "building.2.fill", label: "Cities Explored", value: "\(model.citiesCount ?? 0)", color: .blue)

                        Divider().frame(height: 24)

                        // Top Country
                        statItem(icon: "mappin.and.ellipse", label: "Most Visited", value: model.topCountries?.first?.countryName ?? "Unknown", color: .green)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                    .background(Color.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    
                    Divider()

                    // Map Area
                    ZStack {
                        if let snap = model.mapSnapshot {
                            Image(uiImage: snap)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Color(red: 0.85, green: 0.92, blue: 0.97))
                                .overlay(Text("Loading Map...").foregroundStyle(.secondary))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    Divider()

                    // Bottom Stats
                    HStack(spacing: 16) {
                        Text("Continents:")
                            .font(.system(size: 18, weight: .bold, design: .serif))
                            .foregroundStyle(.secondary)
                        
                        // Fallback continents if empty
                        let continents = model.visitedContinents.isEmpty ? ["North America", "Europe", "Asia"] : model.visitedContinents
                        
                        ForEach(continents, id: \.self) { cont in
                            HStack(spacing: 4) {
                                Image(systemName: continentIcon(cont))
                                    .foregroundStyle(continentColor(cont))
                                Text(cont)
                                    .font(.system(size: 16, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.8))
                            }
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(Color.white.opacity(0.6))
                }
                .background(Color(red: 0.99, green: 0.99, blue: 0.98)) // Card white
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color(red: 0.85, green: 0.82, blue: 0.75), lineWidth: 4)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity) // Ensure card fills 1080 width
            }
        }
        .frame(width: format.size.width, height: format.size.height)
    }

    private func statItem(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(color)
            
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(.black.opacity(0.85))
                Text(label)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(maxWidth: .infinity)
    }


    private func continentIcon(_ name: String) -> String {
        switch name {
        case "North America": return "globe.americas.fill"
        case "South America": return "globe.americas.fill"
        case "Europe": return "globe.europe.africa.fill"
        case "Asia": return "globe.asia.australia.fill"
        case "Africa": return "globe.europe.africa.fill"
        case "Oceania": return "globe.asia.australia.fill"
        default: return "globe"
        }
    }
    
    private func continentColor(_ name: String) -> Color {
        switch name {
        case "North America": return .green
        case "South America": return .orange
        case "Europe": return .blue
        case "Asia": return .red
        case "Africa": return .yellow
        case "Oceania": return .purple
        default: return .gray
        }
    }
}
