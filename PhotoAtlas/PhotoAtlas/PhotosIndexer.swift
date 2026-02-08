import Foundation
import Photos
import CoreLocation

// Lightweight reverse-geocode cache (in-memory) to avoid spamming CLGeocoder.
actor GeoIndex {
    private let geocoder = CLGeocoder()
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
        let lat = (coord.latitude * 100).rounded() / 100
        let lon = (coord.longitude * 100).rounded() / 100
        return "\(lat),\(lon)"
    }
}

struct IndexResult: Sendable {
    let assetsIndexed: Int
    let withLocation: Int
}

final class PhotosIndexer {
    private let store: SQLiteStore
    private let geo = GeoIndex()

    init(store: SQLiteStore) {
        self.store = store
    }

    func fullReindex() async throws -> IndexResult {
        // MVP: wipe and re-index everything
        try await store.resetAll()

        let fetchResult = PHAsset.fetchAssets(with: PHAssetMediaType.image, options: nil)

        var indexed = 0
        var withLocation = 0

        // Build array to allow async/await processing.
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in assets.append(asset) }
        assets.reverse() // newest first

        for asset in assets {
            indexed += 1

            let localId = asset.localIdentifier
            let creationTs = asset.creationDate?.timeIntervalSince1970

            guard let loc = asset.location else {
                // Still store basic record (optional). For now, skip.
                continue
            }
            withLocation += 1

            let coordinate = loc.coordinate
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let place = await geo.resolve(location)

            let record = PhotoRecord(
                localId: localId,
                creationTs: creationTs,
                lat: coordinate.latitude,
                lon: coordinate.longitude,
                countryCode: place?.countryCode,
                countryName: place?.countryName,
                city: place?.city
            )

            try await store.upsert(record)
        }

        return IndexResult(assetsIndexed: indexed, withLocation: withLocation)
    }
}
