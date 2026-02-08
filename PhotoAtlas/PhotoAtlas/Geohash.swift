import Foundation

/// Minimal geohash encoder (base32) for clustering.
/// Precision 4/5/6 is enough for MVP.
enum Geohash {
    private static let base32: [Character] = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    static func encode(lat: Double, lon: Double, precision: Int) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)

        var hash = ""
        var bit = 0
        var ch = 0
        var even = true

        while hash.count < precision {
            if even {
                let mid = (lonRange.0 + lonRange.1) / 2
                if lon >= mid {
                    ch |= (1 << (4 - bit))
                    lonRange.0 = mid
                } else {
                    lonRange.1 = mid
                }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if lat >= mid {
                    ch |= (1 << (4 - bit))
                    latRange.0 = mid
                } else {
                    latRange.1 = mid
                }
            }

            even.toggle()
            if bit < 4 {
                bit += 1
            } else {
                hash.append(base32[ch])
                bit = 0
                ch = 0
            }
        }

        return hash
    }
}
