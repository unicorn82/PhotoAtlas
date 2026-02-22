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

    // Pin navigation (ordered by photo count, within current zoom/precision)
    @State private var selectedClusterId: String? = nil

    @State private var desiredRegion: MKCoordinateRegion? = nil
    @StateObject private var userLocation = UserLocationManager()

    @State private var canFocusPhotos: Bool = false

    /// Cancels previous cluster queries while the user is actively panning/zooming.
    @State private var refreshTask: Task<Void, Never>? = nil

    @State private var showPhotosPermissionPrimer: Bool = false
    @State private var showFootprintDiary: Bool = false
    @State private var composerRequestedStyle: FootprintDiaryStyle = .classic

    /// Prevent automatic re-focusing after the user has manually navigated the map.
    @State private var didInitialAutoFocus: Bool = false
    @State private var userHasManuallyFocused: Bool = false

    var body: some View {
        NavigationView {
            ZStack {
                OfflineMapViewRepresentable(
                    clusters: clusters,
                    selectedClusterId: $selectedClusterId,
                    desiredRegion: desiredRegion,
                    onAppliedDesiredRegion: {
                        // Clear so we don’t re-apply every updateUIView.
                        desiredRegion = nil
                    },
                    onViewportChanged: { region, didUserGesture in
                        lastRegion = region

                        if didUserGesture {
                            userHasManuallyFocused = true
                        }

                        let p = precisionForRegion(region)
                        if p != precision { precision = p }

                        // Cancel any in-flight refresh so we don't build a backlog while the user pans/zooms.
                        refreshTask?.cancel()
                        refreshTask = Task { await refreshClusters(region: region) }
                    },
                    onClusterTapped: { key in
                        // User intent: keep map where they are.
                        userHasManuallyFocused = true
                        selectedClusterId = key
                        navCluster = NavCluster(key: key, precision: precision)
                    }
                )
                // full screen map
                .ignoresSafeArea()

                // Pin navigation overlay (prev/next)
                pinNavigator

                deniedOverlay
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(NotificationCenter.default.publisher(for: .openFootprintDiaryComposer)) { note in
                if let requestedStyle = note.object as? FootprintDiaryStyle {
                    composerRequestedStyle = requestedStyle
                } else {
                    composerRequestedStyle = .classic
                }
                showFootprintDiary = true
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            switchPrecision(to: .country)
                        } label: {
                            Label("Countries", systemImage: "globe")
                        }
                        
                        Button {
                            switchPrecision(to: .city)
                        } label: {
                            Label("Cities", systemImage: "building.2")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(labelForPrecision(precision))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.footnote.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                    }
                }
            }
            .sheet(isPresented: $isMenuPresented) {
                MapActionsSheet(
                    summary: model.lastIndexSummary,
                    canFocusPhotos: canFocusPhotos,
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
            .sheet(isPresented: $showPhotosPermissionPrimer) {
                PhotosPermissionPrimerSheet(
                    onContinue: {
                        Task {
                            await model.requestPhotosAccess()
                            await model.autoIndexIfPossible()
                            await refreshClusters(region: lastRegion)
                        }
                    },
                    onNotNow: {
                        // User can still explore the map; pins may be empty until access granted.
                    }
                )
            }
            .sheet(isPresented: $showFootprintDiary) {
                FootprintDiaryComposerScreen(initialStyle: composerRequestedStyle)
                    .environmentObject(model)
            }
            .task {
                model.refreshAuthorization()

                // Show primer BEFORE we prompt for Photos permission.
                if model.authorization == .notDetermined {
                    showPhotosPermissionPrimer = true
                } else {
                    await model.autoIndexIfPossible()
                }

                await refreshClusters(region: lastRegion)

                // Ask for user location early; if denied, we’ll fall back to “photos centroid”.
                // But:
                // - only do this once
                // - never override a user-chosen focus
                // - never prompt for Location permission while we're still asking for Photos permission
                if !didInitialAutoFocus && !userHasManuallyFocused && model.authorization != .notDetermined {
                    didInitialAutoFocus = true
                    await requestInitialFocusIfNeeded()
                }
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

    private var pinNavigator: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Spacer()

            HStack(spacing: 12) {
                // Action Group
                HStack(spacing: 10) {
                    Button {
                        NotificationCenter.default.post(name: .openFootprintDiaryComposer, object: FootprintDiaryStyle.worldFootprint)
                    } label: {
                        Image(systemName: "airplane")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial)
                    .clipShape(Circle())
                    .accessibilityLabel("World Footprint")

                    Button {
                        Task {
                            userHasManuallyFocused = true
                            await focusMeCityLevel()
                        }
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial)
                    .clipShape(Circle())
                    .accessibilityLabel("Focus Me")
                }

                // Navigation Group
                HStack(spacing: 10) {
                    Button {
                        userHasManuallyFocused = true
                        navigatePins(step: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial)
                    .clipShape(Circle())
                    .disabled(clusters.isEmpty)

                    Button {
                        userHasManuallyFocused = true
                        navigatePins(step: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial)
                    .clipShape(Circle())
                    .disabled(clusters.isEmpty)
                }
            }
            .padding(.horizontal, 14)

            // Current Selection Label
            if let selectedId = selectedClusterId,
               let cluster = clusters.first(where: { $0.id == selectedId }) {
                Text(cluster.title)
                    .font(.footnote.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .padding(.trailing, 14)
            }
        }
        .padding(.bottom, 30)
        .allowsHitTesting(true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map controls")
    }

    private func refreshClusters(region: MKCoordinateRegion) async {
        // If a newer pan/zoom event came in, bail early.
        if Task.isCancelled { return }

        // IMPORTANT:
        // - For city-level, we filter to the current viewport for performance and relevance.
        // - For country-level, we *don’t* filter by viewport bbox; otherwise the count can look wrong
        //   when you’re partially zoomed into a country (pin shows only “in-view” photos but timeline shows all).
        let bbox: BBox = (precision == .country) ? .world : bboxForRegion(region)

        do {
            let next = try await model.db.clusters(in: bbox, precision: precision)
            if Task.isCancelled { return }
            clusters = next
        } catch {
            if Task.isCancelled { return }
            clusters = []
        }

        // Keep selection stable if possible; otherwise pick the first (highest-count) cluster.
        if !clusters.isEmpty {
            if let selectedId = selectedClusterId,
               clusters.contains(where: { $0.id == selectedId }) {
                // keep
            } else {
                selectedClusterId = clusters.first?.id
            }
        } else {
            selectedClusterId = nil
        }

        // NOTE: Don't recompute `photosCentroid()` on every viewport tick.
        // That extra DB query can be noticeable while panning.
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
        case .country: return "Countries"
        case .city: return "Cities"
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
        let loc = await userLocation.requestOneShotLocation()
        if let loc = loc {
            let coord = loc.coordinate
            setDesiredRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0))
            model.lastIndexSummary = String(format: "Focused on you: %.4f, %.4f", coord.latitude, coord.longitude)
            return true
        }

        model.lastIndexSummary = "Couldn’t get your location. On Simulator: Features → Location → choose a location (e.g., Apple)."
        return false
    }

    private func focusMeCityLevel() async {
        let locOpt = await userLocation.requestOneShotLocation()
        guard let loc = locOpt else {
            model.lastIndexSummary = "Couldn’t get your location."
            return
        }

        let coord = loc.coordinate
        let accuracy = max(0, loc.horizontalAccuracy)

        // Accuracy-based zoom heuristic.
        // (If accuracy is invalid/negative, treat as low confidence and zoom wider.)
        let delta: Double = {
            if accuracy > 0 && accuracy <= 50 { return 0.08 }      // neighborhood
            if accuracy > 0 && accuracy <= 200 { return 0.18 }     // city
            if accuracy > 0 && accuracy <= 1000 { return 0.35 }    // metro
            return 0.60                                           // wide fallback
        }()

        setDesiredRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta))
        precision = .city
        model.lastIndexSummary = String(format: "Focused on you: %.4f, %.4f (±%.0fm)", coord.latitude, coord.longitude, accuracy)

        await refreshClusters(region: lastRegion)
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
                model.lastIndexSummary = "No GPS photos indexed yet — can’t Focus Photos. Import photos with location and reopen the app."
            }
        } catch {
            model.lastIndexSummary = "Focus Photos failed: \(error.localizedDescription)"
        }
    }

    private func setDesiredRegion(center: CLLocationCoordinate2D, span: MKCoordinateSpan) {
        desiredRegion = MKCoordinateRegion(center: center, span: span)
        lastRegion = desiredRegion ?? lastRegion
    }

    // MARK: - Pin navigation

    /// Navigate pins in descending photo-count order for the *current* precision/viewport.
    /// Keeps the user's current zoom (span) and just pans the center.
    private func navigatePins(step: Int) {
        guard !clusters.isEmpty else { return }

        let currentIndex: Int = {
            if let selectedId = selectedClusterId,
               let idx = clusters.firstIndex(where: { $0.id == selectedId }) {
                return idx
            }
            return 0
        }()

        let nextIndex: Int = {
            let n = clusters.count
            guard n > 0 else { return 0 }
            // Wrap around (handles negative step too)
            return (currentIndex + step % n + n) % n
        }()

        let next = clusters[nextIndex]
        selectedClusterId = next.id

        let center = CLLocationCoordinate2D(latitude: next.centerLat, longitude: next.centerLon)
        
        // If we are at city level, ensure we zoom in enough to make the city visible
        var targetSpan = lastRegion.span
        if precision == .city {
            let cityZoomThreshold: Double = 1.0
            if targetSpan.latitudeDelta > cityZoomThreshold {
                targetSpan = MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
            }
        }
        
        setDesiredRegion(center: center, span: targetSpan)

        model.lastIndexSummary = "\(next.title) · \(next.count) photos"
    }

    // When we programmatically set region due to user intent (pin nav), treat as manual focus.

    private func switchPrecision(to p: ClusterPrecision) {
        guard p != precision else { return }
        
        // Update precision immediately
        precision = p
        
        // Adjust zoom level to reflect the new precision
        let span = p == .country ? 
            MKCoordinateSpan(latitudeDelta: 40.0, longitudeDelta: 40.0) : 
            MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
            
        setDesiredRegion(center: lastRegion.center, span: span)
        
        Task {
            await refreshClusters(region: desiredRegion ?? lastRegion)
        }
    }
}


@MainActor
final class UserLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestOneShotLocation() async -> CLLocation? {
        guard CLLocationManager.locationServicesEnabled() else { return nil }

        return await withCheckedContinuation { cont in
            self.continuation = cont

            let status = manager.authorizationStatus

            switch status {
            case .notDetermined:
                // Wait for the user’s response, then request location in `locationManagerDidChangeAuthorization`.
                manager.requestWhenInUseAuthorization()

            case .authorizedWhenInUse, .authorizedAlways:
                manager.desiredAccuracy = kCLLocationAccuracyBest
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

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            continuation?.resume(returning: locations.last)
            continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            // If user just granted permission (incl. “Allow Once”), kick off the one-shot request.
            guard continuation != nil else { return }

            let status = manager.authorizationStatus
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
}

struct NavCluster: Identifiable {
    let key: String
    let precision: ClusterPrecision

    var id: String { "\(key)|\(precision)" }
}

private struct PhotosPermissionPrimerSheet: View {
    let onContinue: () -> Void
    let onNotNow: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Allow Photos Access")
                    .font(.title2.bold())

                Text("Footprint Atlas builds your personal photo map by reading photo date + embedded GPS.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Label("On-device only. We do not upload your photo library.", systemImage: "iphone")
                    Label("No account. No cloud. No selling or sharing of your photos.", systemImage: "lock.fill")
                    Label("You can change this anytime in Settings.", systemImage: "gearshape")
                }
                .font(.subheadline)

                Divider().padding(.vertical, 2)

                Text("Recommended: Full Access")
                    .font(.headline)

                Text("Choosing Full Access lets us index all photos with locations. If you choose Limited Access, pins may be missing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onContinue()
                    dismiss()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onNotNow()
                    dismiss()
                } label: {
                    Text("Not Now")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension Notification.Name {
    static let openFootprintDiaryComposer = Notification.Name("openFootprintDiaryComposer")
}

private struct MapActionsSheet: View {
    let summary: String?

    /// Whether there are any indexed GPS photos we can focus on.
    let canFocusPhotos: Bool

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
                    Button("Refresh Pins") {
                        onRefresh()
                        dismiss()
                    }

                    Button("Album Footprint Diary") {
                        // Keep the sheet open/close behavior consistent.
                        NotificationCenter.default.post(name: .openFootprintDiaryComposer, object: nil)
                        dismiss()
                    }

                    // Avoid deprecated `CLLocationManager.authorizationStatus()` (iOS 14+).
                    let locAuth = CLLocationManager().authorizationStatus
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
                        Text("Photos with GPS will appear automatically after access is granted.")
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