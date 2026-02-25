import Foundation
import Photos
import CoreLocation

/// Reverse-geocode helper with:
/// - in-memory cache (rounded coordinate key)
/// - in-flight de-duplication ("single flight")
/// - sliding-window rate limit + throttle backoff
///
/// This avoids Apple reverse-geocoding throttles like:
/// "Tried to make more than 50 requests in 60 seconds".
actor GeoIndex {
    private let geocoder = CLGeocoder()

    /// Keep some headroom under Apple's 50/60s limit.
    var maxRequestsPerMinute: Int = 40

    /// Sliding-window request timestamps.
    private var requestTimes: [Date] = []

    /// In-memory cache keyed by rounded coordinates to avoid repeated geocoding.
    private var cache: [String: (countryCode: String, countryName: String, city: String?)] = [:]

    /// De-dupe identical in-flight requests so 20 callers don't trigger 20 geocodes.
    private var inFlight: [String: Task<(countryCode: String, countryName: String, city: String?)?, Never>] = [:]

    func resolve(_ location: CLLocation) async -> (countryCode: String, countryName: String, city: String?)? {
        let key = Self.key(for: location.coordinate)
        if let hit = cache[key] { return hit }
        if let task = inFlight[key] { return await task.value }

        let task = Task { [geocoder] () -> (countryCode: String, countryName: String, city: String?)? in
            await self.acquireRateLimitSlot()

            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                guard let pm = placemarks.first else { return nil }

                let countryCode = pm.isoCountryCode ?? "??"
                let countryName = pm.country ?? countryCode
                let city = pm.locality ?? pm.subAdministrativeArea

                return (countryCode: countryCode, countryName: countryName, city: city)
            } catch {
                // If we were throttled, wait the reset window and retry once.
                if let resetSeconds = self.timeUntilResetSeconds(from: error) {
                    let waitSeconds = ceil(resetSeconds) + 0.15
                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))

                    do {
                        let placemarks = try await geocoder.reverseGeocodeLocation(location)
                        guard let pm = placemarks.first else { return nil }

                        let countryCode = pm.isoCountryCode ?? "??"
                        let countryName = pm.country ?? countryCode
                        let city = pm.locality ?? pm.subAdministrativeArea

                        return (countryCode: countryCode, countryName: countryName, city: city)
                    } catch {
                        return nil
                    }
                }

                return nil
            }
        }

        inFlight[key] = task
        let resolved = await task.value
        inFlight[key] = nil

        if let resolved = resolved {
            cache[key] = resolved
        }

        return resolved
    }

    private func acquireRateLimitSlot() async {
        let windowSeconds: TimeInterval = 60

        while true {
            let now = Date()
            requestTimes.removeAll { now.timeIntervalSince($0) >= windowSeconds }

            if requestTimes.count < maxRequestsPerMinute {
                requestTimes.append(now)
                return
            }

            if let oldest = requestTimes.first {
                let age = now.timeIntervalSince(oldest)
                let waitSeconds = max(0, windowSeconds - age + 0.10)
                try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            } else {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    static func key(for coord: CLLocationCoordinate2D) -> String {
        // Round to ~1km-ish at equator; reduces cache fragmentation.
        let lat = (coord.latitude * 100).rounded() / 100
        let lon = (coord.longitude * 100).rounded() / 100
        return "\(lat),\(lon)"
    }

    private func timeUntilResetSeconds(from error: Error) -> Double? {
        let ns = error as NSError
        if let details = ns.userInfo["details"] as? [[String: Any]] {
            for d in details {
                if let t = d["timeUntilReset"] as? Double { return t }
                if let t = d["timeUntilReset"] as? Int { return Double(t) }
            }
        }
        return nil
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

    /// Full wipe + rebuild.
    /// Use only for initial bootstrap / debugging.
    func fullReindex() async throws -> IndexResult {
        try await store.resetAll()
        return try await index(fetchOptions: nil)
    }

    /// Incremental index: fetch only assets created/modified since the given date.
    func incrementalIndex(since date: Date) async throws -> IndexResult {
        let opts = PHFetchOptions()
        // Include edits (location metadata can change) as well as new photos.
        opts.predicate = NSPredicate(format: "(creationDate > %@) OR (modificationDate > %@)", date as NSDate, date as NSDate)
        // Deterministic order (oldest first) so our rate limiter behaves smoothly.
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return try await index(fetchOptions: opts)
    }

    // MARK: - Shared implementation

    private func index(fetchOptions: PHFetchOptions?) async throws -> IndexResult {
        let fetchResult = PHAsset.fetchAssets(with: PHAssetMediaType.image, options: fetchOptions)

        var indexed = 0
        var withLocation = 0

        // Enumerate directly; no need to materialize an array (keeps memory down on large libraries).
        for i in 0..<fetchResult.count {
            let asset = fetchResult.object(at: i)
            indexed += 1

            let localId = asset.localIdentifier
            let creationTs = asset.creationDate?.timeIntervalSince1970

            guard let loc = asset.location else {
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
