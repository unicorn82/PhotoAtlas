import SwiftUI
import MapKit
import Photos
import CoreLocation

struct MapScreen: View {
    @EnvironmentObject private var model: AppModel

    @State private var clusters: [ClusterBubble] = []
    @State private var precision: ClusterPrecision = .country

    @State private var lastRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
    )

    @State private var navCluster: NavCluster?
    @State private var isMenuPresented: Bool = false

    @State private var desiredRegion: MKCoordinateRegion? = nil
    @StateObject private var userLocation = UserLocationManager()

    @State private var canFocusPhotos: Bool = false

    var body: some View {
        NavigationView {
            ZStack {
                OfflineMapViewRepresentable(
                    clusters: clusters,
                    desiredRegion: desiredRegion,
                    onAppliedDesiredRegion: {
                        // Clear so we don’t re-apply every updateUIView.
                        desiredRegion = nil
                    },
                    onViewportChanged: { region in
                        lastRegion = region
                        let p = precisionForRegion(region)
                        if p != precision { precision = p }
                        Task { await refreshClusters(region: region) }
                    },
                    onClusterTapped: { key in
                        navCluster = NavCluster(key: key, precision: precision)
                    }
                )
                // full screen map
                .ignoresSafeArea()

                deniedOverlay
            }
            .navigationTitle("PhotoAtlas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        isMenuPresented = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Text(labelForPrecision(precision))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $isMenuPresented) {
                MapActionsSheet(
                    isIndexing: model.isIndexing,
                    summary: model.lastIndexSummary,
                    canFocusPhotos: canFocusPhotos,
                    onIndex: {
                        Task {
                            await model.indexNow()
                            await refreshClusters(region: lastRegion)
                        }
                    },
                    onRefresh: {
                        Task { await refreshClusters(region: lastRegion) }
                    },
                    onFocusMe: {
                        Task { await focusMe() }
                    },
                    onFocusPhotos: {
                        Task { await focusPhotos() }
                    },
                    onOpenSettings: {
                        model.openSettings()
                    },
                    auth: model.authorization
                )
            }
            .background(
                NavigationLink(
                    destination: Group {
                        if let item = navCluster {
                            ClusterTimelineScreen(clusterKey: item.key, precision: item.precision)
                        } else {
                            EmptyView()
                        }
                    },
                    isActive: Binding(
                        get: { navCluster != nil },
                        set: { if !$0 { navCluster = nil } }
                    ),
                    label: { EmptyView() }
                )
                .hidden()
            )
            .task {
                model.refreshAuthorization()
                await refreshClusters(region: lastRegion)

                // Ask for user location early; if denied, we’ll fall back to “photos centroid”.
                await requestInitialFocusIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var deniedOverlay: some View {
        switch model.authorization {
        case .denied, .restricted:
            VStack(spacing: 10) {
                Text("Photos access is off")
                    .font(.headline)
                Text("Grant access to index photo locations and show pins on the map.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Grant Access") {
                    model.openSettings()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding()

        default:
            EmptyView()
        }
    }

    private func refreshClusters(region: MKCoordinateRegion) async {
        // IMPORTANT:
        // - For city-level, we filter to the current viewport for performance and relevance.
        // - For country-level, we *don’t* filter by viewport bbox; otherwise the count can look wrong
        //   when you’re partially zoomed into a country (pin shows only “in-view” photos but timeline shows all).
        let bbox: BBox = (precision == .country) ? .world : bboxForRegion(region)

        do {
            clusters = try await model.db.clusters(in: bbox, precision: precision)
        } catch {
            clusters = []
        }

        // Update whether we can focus on photos (any GPS data indexed).
        do {
            canFocusPhotos = (try await model.db.photosCentroid()) != nil
        } catch {
            canFocusPhotos = false
        }
    }

    private func precisionForRegion(_ r: MKCoordinateRegion) -> ClusterPrecision {
        if r.span.latitudeDelta > 8 || r.span.longitudeDelta > 8 {
            return .country
        } else {
            return .city
        }
    }

    private func labelForPrecision(_ p: ClusterPrecision) -> String {
        switch p {
        case .country: return "Pins: Countries"
        case .city: return "Pins: Cities"
        }
    }

    private func bboxForRegion(_ r: MKCoordinateRegion) -> BBox {
        let minLat = max(-85, r.center.latitude - r.span.latitudeDelta / 2)
        let maxLat = min(85, r.center.latitude + r.span.latitudeDelta / 2)
        let minLon = max(-180, r.center.longitude - r.span.longitudeDelta / 2)
        let maxLon = min(180, r.center.longitude + r.span.longitudeDelta / 2)
        return BBox(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
    }

    // MARK: - Initial focus

    private func requestInitialFocusIfNeeded() async {
        // Ask location permission early; if user denies, fall back.
        if await focusMe() { return }
        await focusPhotos()
    }

    @discardableResult
    private func focusMe() async -> Bool {
        let coord = await userLocation.requestOneShotLocation()
        if let coord = coord {
            setDesiredRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0))
            model.lastIndexSummary = String(format: "Focused on you: %.4f, %.4f", coord.latitude, coord.longitude)
            return true
        }

        model.lastIndexSummary = "Couldn’t get your location. On Simulator: Features → Location → choose a location (e.g., Apple)."
        return false
    }

    private func focusPhotos() async {
        do {
            if let centroid = try await model.db.photosCentroid() {
                setDesiredRegion(
                    center: centroid,
                    span: MKCoordinateSpan(latitudeDelta: 20.0, longitudeDelta: 20.0)
                )
                model.lastIndexSummary = String(format: "Focused on photos: %.4f, %.4f", centroid.latitude, centroid.longitude)
            } else {
                model.lastIndexSummary = "No GPS photos indexed yet — can’t Focus Photos. Import photos with location and run Indexing."
            }
        } catch {
            model.lastIndexSummary = "Focus Photos failed: \(error.localizedDescription)"
        }
    }

    private func setDesiredRegion(center: CLLocationCoordinate2D, span: MKCoordinateSpan) {
        desiredRegion = MKCoordinateRegion(center: center, span: span)
        lastRegion = desiredRegion ?? lastRegion
    }
}

@MainActor
final class UserLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestOneShotLocation() async -> CLLocationCoordinate2D? {
        guard CLLocationManager.locationServicesEnabled() else { return nil }

        return await withCheckedContinuation { cont in
            self.continuation = cont

            let status = CLLocationManager.authorizationStatus()

            switch status {
            case .notDetermined:
                // Wait for the user’s response, then request location in `locationManagerDidChangeAuthorization`.
                manager.requestWhenInUseAuthorization()

            case .authorizedWhenInUse, .authorizedAlways:
                manager.desiredAccuracy = kCLLocationAccuracyKilometer
                manager.requestLocation()

            case .denied, .restricted:
                cont.resume(returning: nil)
                self.continuation = nil

            @unknown default:
                cont.resume(returning: nil)
                self.continuation = nil
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        continuation?.resume(returning: locations.last?.coordinate)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // If user just granted permission (incl. “Allow Once”), kick off the one-shot request.
        guard continuation != nil else { return }

        let status = CLLocationManager.authorizationStatus()
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            manager.requestLocation()
        case .denied, .restricted:
            continuation?.resume(returning: nil)
            continuation = nil
        case .notDetermined:
            break
        @unknown default:
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
}

struct NavCluster: Identifiable {
    let key: String
    let precision: ClusterPrecision

    var id: String { "\(key)|\(precision)" }
}

private struct MapActionsSheet: View {
    let isIndexing: Bool
    let summary: String?

    /// Whether there are any indexed GPS photos we can focus on.
    let canFocusPhotos: Bool

    let onIndex: () -> Void
    let onRefresh: () -> Void
    let onFocusMe: () -> Void
    let onFocusPhotos: () -> Void
    let onOpenSettings: () -> Void

    let auth: PHAuthorizationStatus

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        onIndex()
                        dismiss()
                    } label: {
                        HStack {
                            Text(isIndexing ? "Indexing…" : "Start Indexing")
                            Spacer()
                            if isIndexing {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(isIndexing)

                    Button("Refresh Pins") {
                        onRefresh()
                        dismiss()
                    }

                    let locAuth = CLLocationManager.authorizationStatus()
                    let canFocusMe = CLLocationManager.locationServicesEnabled() && (locAuth == .notDetermined || locAuth == .authorizedWhenInUse || locAuth == .authorizedAlways)

                    Button("Focus Me") {
                        onFocusMe()
                        dismiss()
                    }
                    .disabled(!canFocusMe)

                    Button("Focus Photos") {
                        onFocusPhotos()
                        dismiss()
                    }
                    .disabled(!canFocusPhotos)

                    if auth == .denied || auth == .restricted {
                        Button("Grant Access (Settings)") {
                            onOpenSettings()
                        }
                    }
                }

                Section("Status") {
                    if let summary = summary {
                        Text(summary)
                    } else {
                        Text("Index photos to populate the map.")
                            .foregroundStyle(.secondary)
                    }

                    Text("Photos permission: \(authLabel(auth))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func authLabel(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }
}