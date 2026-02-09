import Foundation
import CoreLocation

/// Reverse-geocode helper with:
/// - in-memory cache (rounded coordinate key)
/// - in-flight de-duplication ("single flight")
/// - sliding-window rate limit + throttle backoff
///
/// This avoids Apple reverse-geocoding throttles like:
/// "Tried to make more than 50 requests in 60 seconds".
// NOTE: This file is currently NOT part of the Xcode target sources.
// The active GeoIndex implementation lives in PhotosIndexer.swift.
// If you add this file to the target in the future, avoid name collisions.
actor GeoIndexService { 
    private let geocoder = CLGeocoder()

    /// Keep some headroom under Apple's 50/60s limit.
    var maxRequestsPerMinute: Int = 40

    /// Sliding-window request timestamps.
    private let clock = ContinuousClock()
    private var requestTimes: [ContinuousClock.Instant] = []

    /// In-memory cache keyed by rounded coordinates to avoid repeated geocoding.
    private var cache: [String: (countryCode: String, countryName: String, city: String?)] = [:]

    /// De-dupe identical in-flight requests so 20 callers don't trigger 20 geocodes.
    private var inFlight: [String: Task<(countryCode: String, countryName: String, city: String?)?, Never>] = [:]

    func resolve(_ location: CLLocation) async -> (countryCode: String, countryName: String, city: String?)? {
        let key = Self.key(for: location.coordinate)
        if let hit = cache[key] { return hit }
        if let task = inFlight[key] { return await task.value }

        let task = Task { [geocoder] () -> (countryCode: String, countryName: String, city: String?)? in
            // Rate limit before calling into GEO services.
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
                    let wait = Duration.seconds(Int(resetSeconds.rounded(.up))) + .milliseconds(150)
                    try? await Task.sleep(for: wait)

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
        let value = await task.value
        inFlight[key] = nil

        if let value {
            cache[key] = value
        }

        return value
    }

    // MARK: - Rate limiting

    private func acquireRateLimitSlot() async {
        let window: Duration = .seconds(60)

        while true {
            let now = clock.now
            requestTimes.removeAll { now - $0 >= window }

            if requestTimes.count < maxRequestsPerMinute {
                requestTimes.append(now)
                return
            }

            if let oldest = requestTimes.first {
                let wait = (window - (now - oldest)) + .milliseconds(100)
                try? await Task.sleep(for: wait)
            } else {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: - Keying

    static func key(for coord: CLLocationCoordinate2D) -> String {
        // Round to ~1km-ish at equator; reduces cache fragmentation.
        let lat = (coord.latitude * 100).rounded() / 100
        let lon = (coord.longitude * 100).rounded() / 100
        return "\(lat),\(lon)"
    }

    // MARK: - Throttle parsing

    private func timeUntilResetSeconds(from error: Error) -> Double? {
        let ns = error as NSError

        // Example payload (from user's error):
        // UserInfo={details=( { ... timeUntilReset = 52; ... } ), ...}
        if let details = ns.userInfo["details"] as? [[String: Any]] {
            for d in details {
                if let t = d["timeUntilReset"] as? Double { return t }
                if let t = d["timeUntilReset"] as? Int { return Double(t) }
            }
        }

        return nil
    }
}
