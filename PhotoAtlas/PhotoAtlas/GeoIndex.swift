import Foundation
import CoreLocation

actor GeoIndex {
    private let geocoder = CLGeocoder()

    /// In-memory cache keyed by rounded coordinates to avoid repeated geocoding.
    private var cache: [String: (countryCode: String, countryName: String, city: String?)] = [:]

    func resolve(_ location: CLLocation) async -> (countryCode: String, countryName: String, city: String?)? {
        let key = Self.key(for: location.coordinate)
        if let hit = cache[key] { return hit }

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let pm = placemarks.first else { return nil }

            let countryCode = pm.isoCountryCode ?? "??"
            let countryName = pm.country ?? countryCode
            let city = pm.locality ?? pm.subAdministrativeArea

            let value = (countryCode: countryCode, countryName: countryName, city: city)
            cache[key] = value
            return value
        } catch {
            return nil
        }
    }

    static func key(for coord: CLLocationCoordinate2D) -> String {
        // Round to ~1km-ish at equator; reduces cache fragmentation.
        let lat = (coord.latitude * 100).rounded() / 100
        let lon = (coord.longitude * 100).rounded() / 100
        return "\(lat),\(lon)"
    }
}
