import Foundation
import CoreGraphics

enum Geo {
    // Web Mercator projection constants
    static let maxLat: Double = 85.05112878

    static func clampLat(_ lat: Double) -> Double {
        min(max(lat, -maxLat), maxLat)
    }

    /// Project lat/lon to normalized mercator world coordinates in [0,1]x[0,1]
    static func project(lat: Double, lon: Double) -> CGPoint {
        let clampedLat = clampLat(lat)
        let x = (lon + 180.0) / 360.0

        let latRad = clampedLat * Double.pi / 180.0
        let y = (1.0 - log(tan(Double.pi / 4.0 + latRad / 2.0)) / Double.pi) / 2.0
        return CGPoint(x: x, y: y)
    }

    /// Unproject normalized mercator world coordinates back to lat/lon
    static func unproject(_ p: CGPoint) -> (lat: Double, lon: Double) {
        let lon = Double(p.x) * 360.0 - 180.0
        let y = Double(p.y)
        let n = Double.pi - 2.0 * Double.pi * y
        let lat = (180.0 / Double.pi) * atan(0.5 * (exp(n) - exp(-n)))
        return (lat: lat, lon: lon)
    }
}

struct BBox: Sendable {
    var minLat: Double
    var maxLat: Double
    var minLon: Double
    var maxLon: Double

    static let world = BBox(minLat: -85, maxLat: 85, minLon: -180, maxLon: 180)
}
