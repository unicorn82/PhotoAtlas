import SwiftUI
import MapKit
import Photos
import CoreLocation

struct MapScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

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
    @State private var showFootprintComposer: Bool = false
    @State private var showWorldFootprint: Bool = false
    @State private var composerRequestedStyle: FootprintDiaryStyle = .classic

    /// Prevent automatic re-focusing after the user has manually navigated the map.
    @State private var didInitialAutoFocus: Bool = false
    @State private var userHasManuallyFocused: Bool = false
    @State private var pendingInitialFocusAfterPhotosAuth: Bool = false

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

                // Bottom indexing progress (visible only while automatic indexing is active).
                indexingProgressOverlay

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

                // Split into 2 independent UIs.
                if composerRequestedStyle == .worldFootprint {
                    showWorldFootprint = true
                } else {
                    showFootprintComposer = true
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
                        // IMPORTANT: iOS won’t reliably show multiple permission prompts back-to-back.
                        // We request Photos now, and defer the initial location focus until *after*
                        // Photos authorization resolves.
                        pendingInitialFocusAfterPhotosAuth = true

                        Task { @MainActor in
                            await model.requestPhotosAccess()
                            await model.autoIndexIfPossible()
                            await refreshClusters(region: lastRegion)
                        }
                    }
                )
            }
            .sheet(isPresented: $showFootprintComposer) {
                // Classic Footprint only (no style switcher).
                FootprintDiaryComposerScreen(initialStyle: .classic)
                    .environmentObject(model)
            }
            .sheet(isPresented: $showWorldFootprint) {
                // World Footprint only (clean dedicated UI).
                FootprintDiaryComposerScreen(initialStyle: .worldFootprint)
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

                // Focus on the user's current location on ONLY the very first app launch of the session.
                if model.authorization != .notDetermined && !didInitialAutoFocus && !userHasManuallyFocused {
                    // Let the user see the world map briefly before zooming in.
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                    await requestInitialFocusIfNeeded()
                }
            }
            .onChange(of: model.authorization) { newAuth in
                // If we started with Photos permission undetermined, the primer handles requesting it.
                // After the user responds, run initial focus (which may request Location permission).
                guard pendingInitialFocusAfterPhotosAuth else { return }
                guard newAuth != .notDetermined else { return }
                guard !didInitialAutoFocus && !userHasManuallyFocused else {
                    pendingInitialFocusAfterPhotosAuth = false
                    return
                }

                pendingInitialFocusAfterPhotosAuth = false
                didInitialAutoFocus = true

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s
                    await requestInitialFocusIfNeeded()
                }
            }
            .onChange(of: scenePhase) { phase in
                // We only want the cinematic focus on the very first cold launch.
                // Subsequent resumes from background should NOT move the map if the user is already looking at something.
                guard phase == .active else { return }
                guard !didInitialAutoFocus && !userHasManuallyFocused else { return }
                guard model.authorization != .notDetermined else { return }

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
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

    private var indexingProgressOverlay: some View {
        VStack {
            Spacer()

            if model.isIndexing, let progressText = model.indexProgressText {
                let percentage = Int((model.indexProgress * 100).rounded())

                VStack(alignment: .leading, spacing: 8) {
                    Text("Indexing photos… \(percentage)%")
                        .font(.subheadline.weight(.semibold))

                    ProgressView(value: model.indexProgress)

                    Text(progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.isIndexing)
        .allowsHitTesting(false)
    }

    private var pinNavigator: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Spacer()

            HStack(spacing: 12) {
                // Action Group
                HStack(spacing: 10) {
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
                        .frame(height: 44)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                    }
                    .accessibilityLabel("Map Mode")
                    .accessibilityValue(labelForPrecision(precision))

                    Button {
                        // Open the World Footprint dedicated UI directly.
                        showWorldFootprint = true
                    } label: {
                        Image(systemName: "globe.americas.fill")
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
        guard !didInitialAutoFocus else { return }
        
        // Ask location permission early; if user denies, fall back.
        // On device, location can occasionally fail on the very first request after launch.
        // Retry once after a short delay before falling back to photos.
        if await focusMe(useCinematic: true) { 
            didInitialAutoFocus = true
            return 
        }

        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        if await focusMe(useCinematic: true) { 
            didInitialAutoFocus = true
            return 
        }

        await focusPhotos(useCinematic: true)
        didInitialAutoFocus = true
    }

    @discardableResult
    private func focusMe(useCinematic: Bool = false) async -> Bool {
        let loc = await userLocation.requestOneShotLocation()
        if let loc = loc {
            let coord = loc.coordinate
            
            if useCinematic {
                // Perform a two-stage "cinematic" zoom.
                // Stage 1: Zoom to continental level (span 30)
                setDesiredRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 30.0, longitudeDelta: 30.0))
                
                // Wait for the first stage of animation to roughly complete
                try? await Task.sleep(nanoseconds: 1_800_000_000) // 1.8s
            }
            
            // Stage 2: Final zoom (stay local if direct, or finish cinematic)
            setDesiredRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0))
            
            model.lastIndexSummary = String(format: "Focused on you: %.4f, %.4f", coord.latitude, coord.longitude)
            return true
        }

        model.lastIndexSummary = "Couldn’t get your location."
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

    private func focusPhotos(useCinematic: Bool = false) async {
        do {
            if let centroid = try await model.db.photosCentroid() {
                if useCinematic {
                    // Perform a two-stage "cinematic" zoom.
                    // Stage 1: Continental level (span 50)
                    setDesiredRegion(center: centroid, span: MKCoordinateSpan(latitudeDelta: 50.0, longitudeDelta: 50.0))
                    
                    try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
                }
                
                // Stage 2: Final photos level (span 20)
                setDesiredRegion(
                    center: centroid,
                    span: MKCoordinateSpan(latitudeDelta: 20.0, longitudeDelta: 20.0)
                )
                model.lastIndexSummary = String(format: "Focused on photos: %.4f, %.4f", centroid.latitude, centroid.longitude)
            } else {
                model.lastIndexSummary = "No GPS photos indexed yet."
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

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                // App mark
                HStack {
                    Spacer()
                    Image("AppMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
                    Spacer()
                }
                .padding(.top, 6)

                Text("Allow Photos Access")
                    .font(.title2.bold())

                Text("Photo Atlas builds your personal photo map from the locations already stored in your photos.")
                    .foregroundStyle(.secondary)

                // Privacy card
                VStack(alignment: .leading, spacing: 10) {
                    Text("Privacy")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("On-device only. Your library never leaves your phone.", systemImage: "iphone")
                        Label("No account. No cloud. No selling.", systemImage: "lock.fill")
                        Label("You can change this anytime in Settings.", systemImage: "gearshape")
                    }
                    .font(.subheadline)
                }
                .padding(12)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Divider().padding(.vertical, 2)

                Text("Recommended: Full Access")
                    .font(.headline)

                Text("Full Access lets Photo Atlas index all location photos. With Limited Access, some pins may be missing.")
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