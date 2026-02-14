import SwiftUI

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

struct FootprintDiaryCardModel {
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
    let highlights: [Highlight]

    /// User-selected images (1...9 recommended).
    let pickedImages: [UIImage]

    /// Optional user-provided captions for the picked images (same count or empty).
    let pickedCaptions: [String]

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

            VStack(alignment: .leading, spacing: 18) {
                header

                hero

                highlights

                pickedPhotos

                footer
            }
            .padding(56)
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
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            Text(model.title)
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.93))

            Text(model.dateRange)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
        }
    }

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(.white.opacity(0.075))
                .overlay(
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                )
                .overlay(mapGrid.opacity(0.18).clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous)))

            Text("TRAVEL LOG")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.black.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.24), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(26)

            VStack(alignment: .leading, spacing: 14) {
                Text("A diary of places I kept")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))

                HStack(spacing: 14) {
                    statChip(big: "\(model.countriesCount)", label: "Countries")
                }

                quote

                Spacer()

                Text(model.privacyLine)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.60))
            }
            .padding(28)
            .padding(.top, 6)
            .padding(.trailing, 90) // keep clear of stamp
        }
        .frame(height: heroHeight)
    }

    private var heroHeight: CGFloat {
        switch format {
        case .portrait: return 520
        case .square: return 440
        case .landscape: return 420
        }
    }

    private func statChip(big: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(big)
                .font(.system(size: 56, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.56))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.white.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var quote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("—")
                .foregroundStyle(.white.opacity(0.55))
                .font(.system(size: 28, weight: .black, design: .rounded))

            Text("Not a map of where I went.\nA map of what I chose to remember.")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .lineSpacing(2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(.black.opacity(0.16))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Highlights")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.93))

            VStack(spacing: 12) {
                ForEach(model.highlights.prefix(3)) { h in
                    highlightRow(h)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Picked photos")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.93))

            let imgs = model.pickedImages
            if imgs.isEmpty {
                Text("Pick up to 9 photos to make it yours.")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.60))
                    .padding(.vertical, 10)
            } else {
                photoGrid
            }
        }
    }

    private var photoGrid: some View {
        let imgs = model.pickedImages
        let captions = model.pickedCaptions

        let cols: Int = {
            if imgs.count <= 4 { return 4 }
            return 3
        }()

        let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: cols)

        return LazyVGrid(columns: columns, spacing: 14) {
            ForEach(imgs.indices, id: \ .self) { idx in
                ZStack(alignment: .bottomLeading) {
                    Image(uiImage: imgs[idx])
                        .resizable()
                        .scaledToFill()
                        .clipped()

                    if idx < captions.count, !captions[idx].isEmpty {
                        Text(captions[idx])
                            .font(.system(size: 18, weight: .black, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.40))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(.white.opacity(0.14), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .padding(14)
                    }
                }
                .frame(height: photoTileHeight(for: imgs.count))
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
            }
        }
    }

    private func photoTileHeight(for count: Int) -> CGFloat {
        // tuned for render sizes.
        switch format {
        case .portrait:
            if count <= 4 { return 250 }
            if count <= 6 { return 230 }
            return 220
        case .square:
            if count <= 4 { return 220 }
            if count <= 6 { return 205 }
            return 195
        case .landscape:
            if count <= 4 { return 200 }
            if count <= 6 { return 188 }
            return 178
        }
    }

    private var footer: some View {
        HStack {
            Text("Generated on-device · No upload")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))

            Spacer()

            Text("photoatlas.app")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))
        }
        .padding(.top, 4)
    }
}
