import UIKit

final class OfflineMapUIView: UIView {
    struct Model {
        var clusters: [ClusterBubble] = []
        var precision: ClusterPrecision = .country
    }

    var model: Model = .init() {
        didSet { setNeedsDisplay() }
    }

    // Transform from world-normalized [0,1] coords to view coords
    private var scale: CGFloat = 1.0
    private var translation: CGPoint = .zero

    var onViewportChanged: ((BBox, CGFloat) -> Void)?
    var onClusterTapped: ((String, ClusterPrecision) -> Void)?

    private var viewportDebounce: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .systemBackground

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        // Start centered with a pleasant zoom.
        scale = 1.2
        translation = .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleViewportCallback()
    }

    // MARK: - Gestures

    @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
        let delta = gr.translation(in: self)
        gr.setTranslation(.zero, in: self)

        translation.x += delta.x
        translation.y += delta.y
        setNeedsDisplay()

        if gr.state == .ended || gr.state == .cancelled {
            scheduleViewportCallback()
        }
    }

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        let location = gr.location(in: self)
        let factor = gr.scale
        gr.scale = 1.0

        let oldScale = scale
        let newScale = (scale * factor).clamped(to: 0.6...40)
        scale = newScale

        // Zoom around pinch center.
        let before = (location - translation) / oldScale
        let after = before * newScale
        translation = location - after

        setNeedsDisplay()

        if gr.state == .ended || gr.state == .cancelled {
            scheduleViewportCallback()
        }
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        let p = gr.location(in: self)
        if let hit = hitTestCluster(at: p) {
            onClusterTapped?(hit, model.precision)
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // Clear
        ctx.setFillColor(UIColor.systemBackground.cgColor)
        ctx.fill(bounds)

        // Draw simple world graticule (offline base layer)
        drawGraticule(ctx: ctx)

        // Draw clusters
        drawClusters(ctx: ctx)

        // Border
        ctx.setStrokeColor(UIColor.separator.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
    }

    private func drawGraticule(ctx: CGContext) {
        ctx.saveGState()

        // Transform setup: world [0,1] -> view
        let t = worldToViewTransform()
        ctx.concatenate(t)

        ctx.setStrokeColor(UIColor.secondaryLabel.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(0.002) // in world units

        // Vertical lines (lon)
        for i in 0...18 {
            let x = CGFloat(i) / 18.0
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: 1))
        }

        // Horizontal lines (lat)
        for i in 0...10 {
            let y = CGFloat(i) / 10.0
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: 1, y: y))
        }

        ctx.strokePath()

        // World outline box
        ctx.setStrokeColor(UIColor.secondaryLabel.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(0.004)
        ctx.stroke(CGRect(x: 0, y: 0, width: 1, height: 1))

        ctx.restoreGState()
    }

    private func drawClusters(ctx: CGContext) {
        let t = worldToViewTransform()

        for bubble in model.clusters {
            let worldPoint = Geo.project(lat: bubble.centerLat, lon: bubble.centerLon)
            let p = worldPoint.applying(t)

            let radius = bubbleRadius(count: bubble.count)
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)

            // circle
            ctx.setFillColor(UIColor.systemBlue.withAlphaComponent(0.85).cgColor)
            ctx.fillEllipse(in: rect)

            // label
            let text = formatCount(bubble.count)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: max(10, radius * 0.9), weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            let textRect = CGRect(x: p.x - size.width/2, y: p.y - size.height/2, width: size.width, height: size.height)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }

    private func bubbleRadius(count: Int) -> CGFloat {
        // Log scale to keep things sane.
        let c = max(1, count)
        let r = 10 + 6 * log10(CGFloat(c))
        return r.clamped(to: 12...44)
    }

    private func formatCount(_ c: Int) -> String {
        if c >= 1_000_000 { return String(format: "%.1fm", Double(c) / 1_000_000) }
        if c >= 10_000 { return String(format: "%.1fk", Double(c) / 1_000) }
        if c >= 1_000 { return String(format: "%.0fk", Double(c) / 1_000) }
        return "\(c)"
    }

    // MARK: - Hit testing clusters

    private func hitTestCluster(at point: CGPoint) -> String? {
        let t = worldToViewTransform()
        // Iterate in descending count so big bubbles win.
        for bubble in model.clusters.sorted(by: { $0.count > $1.count }) {
            let wp = Geo.project(lat: bubble.centerLat, lon: bubble.centerLon)
            let p = wp.applying(t)
            let r = bubbleRadius(count: bubble.count)
            if hypot(point.x - p.x, point.y - p.y) <= r {
                return bubble.id
            }
        }
        return nil
    }

    // MARK: - Viewport

    private func scheduleViewportCallback() {
        viewportDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let bbox = self.currentBBox()
            self.onViewportChanged?(bbox, self.scale)
        }
        viewportDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func currentBBox() -> BBox {
        // Map visible rect corners back to world [0,1], then unproject.
        let inv = worldToViewTransform().inverted()
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: bounds.maxX, y: 0),
            CGPoint(x: 0, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY)
        ].map { $0.applying(inv) }

        var lats: [Double] = []
        var lons: [Double] = []
        for c in corners {
            let (lat, lon) = Geo.unproject(c)
            lats.append(lat)
            lons.append(lon)
        }

        return BBox(
            minLat: max(-85, lats.min() ?? -85),
            maxLat: min(85, lats.max() ?? 85),
            minLon: max(-180, lons.min() ?? -180),
            maxLon: min(180, lons.max() ?? 180)
        )
    }

    private func worldToViewTransform() -> CGAffineTransform {
        // Scale world to fit view, then apply user zoom and translation.
        // World is [0,1]x[0,1]. Fit to view by using min dimension.
        let fit = min(bounds.width, bounds.height)
        let baseScale = fit

        var t = CGAffineTransform.identity
        t = t.translatedBy(x: bounds.midX, y: bounds.midY)
        t = t.translatedBy(x: translation.x, y: translation.y)
        t = t.scaledBy(x: baseScale * scale, y: baseScale * scale)
        t = t.translatedBy(x: -0.5, y: -0.5)
        return t
    }
}

// MARK: - Small helpers

private extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

private extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func / (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x / rhs, y: lhs.y / rhs)
    }

    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}
