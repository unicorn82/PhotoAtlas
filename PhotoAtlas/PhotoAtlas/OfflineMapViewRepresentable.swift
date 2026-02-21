import SwiftUI
import MapKit

/// NOTE: Despite the filename, this now uses Apple MapKit (online tiles) to show a real earth map.
/// We kept the file name to avoid having to edit the Xcode project’s file list.
struct OfflineMapViewRepresentable: UIViewRepresentable {
    var clusters: [ClusterBubble]
    @Binding var selectedClusterId: String?

    /// If set, the map will move to this region (once) and then call `onAppliedDesiredRegion`.
    var desiredRegion: MKCoordinateRegion?
    var onAppliedDesiredRegion: () -> Void

    /// `didUserGesture` is true when the region change was triggered by user interaction (pan/zoom).
    var onViewportChanged: (_ region: MKCoordinateRegion, _ didUserGesture: Bool) -> Void
    var onClusterTapped: (String) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = .hybridFlyover
        map.showsCompass = true
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
        )
        map.setRegion(region, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self

        if let desiredRegion = desiredRegion {
            // Apply once (MapScreen clears it via callback to avoid repeated animations).
            map.setRegion(desiredRegion, animated: true)
            onAppliedDesiredRegion()
        }

        // PERFORMANCE:
        // Avoid removing/re-adding all annotations every update. That creates visible lag (pins "pop in")
        // and triggers lots of view churn while panning/zooming.
        //
        // Instead, diff by `key` and only add/remove/update what changed.
        context.coordinator.applyClusters(clusters, to: map)
        context.coordinator.updateAnnotationColors(in: map)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: OfflineMapViewRepresentable
        private var debounce: DispatchWorkItem?

        /// Tracks whether the latest region change is user-driven (pan/zoom) vs programmatic.
        private var lastChangeWasUserGesture: Bool = false

        /// Keep a stable set of annotations keyed by cluster id.
        private var clusterAnnotationsByKey: [String: ClusterAnnotation] = [:]

        init(parent: OfflineMapViewRepresentable) {
            self.parent = parent
        }

        func applyClusters(_ clusters: [ClusterBubble], to map: MKMapView) {
            // Remove annotations that are no longer present.
            let nextKeys = Set(clusters.map { $0.id })
            let existingKeys = Set(clusterAnnotationsByKey.keys)
            let removedKeys = existingKeys.subtracting(nextKeys)
            if !removedKeys.isEmpty {
                let removed = removedKeys.compactMap { clusterAnnotationsByKey[$0] }
                removed.forEach { clusterAnnotationsByKey[$0.key] = nil }
                map.removeAnnotations(removed)
            }

            // Add/update present annotations.
            for bubble in clusters {
                let coord = CLLocationCoordinate2D(latitude: bubble.centerLat, longitude: bubble.centerLon)

                if let ann = clusterAnnotationsByKey[bubble.id] {
                    // Update in place (keeps the annotation view alive).
                    let didMove = ann.coordinate.latitude != coord.latitude || ann.coordinate.longitude != coord.longitude
                    ann.title = bubble.title
                    ann.count = bubble.count
                    if didMove {
                        ann.coordinate = coord
                    }

                    // Update existing view glyph immediately if it already exists.
                    if let v = map.view(for: ann) as? MKMarkerAnnotationView {
                        v.glyphText = formatCount(ann.count)
                    }
                } else {
                    let ann = ClusterAnnotation(key: bubble.id, title: bubble.title, count: bubble.count, coordinate: coord)
                    clusterAnnotationsByKey[bubble.id] = ann
                    map.addAnnotation(ann)
                }
            }
        }

        func updateAnnotationColors(in map: MKMapView) {
            for annotation in map.annotations {
                if let ann = annotation as? ClusterAnnotation,
                   let view = map.view(for: ann) as? MKMarkerAnnotationView {
                    let isSelected = ann.key == parent.selectedClusterId
                    view.markerTintColor = isSelected ? .systemOrange : .systemBlue
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Heuristic: if any gesture recognizer is active, treat as user gesture.
            let isGestureActive = mapView.gestureRecognizers?.contains(where: {
                $0.state == .began || $0.state == .changed
            }) ?? false
            lastChangeWasUserGesture = isGestureActive
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let didUserGesture = lastChangeWasUserGesture
            debounce?.cancel()
            let item = DispatchWorkItem { [weak self, weak mapView] in
                guard let self = self else { return }
                guard let mapView = mapView else { return }
                self.parent.onViewportChanged(mapView.region, didUserGesture)
            }
            debounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let ann = annotation as? ClusterAnnotation else { return nil }

            let reuseId = "cluster"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseId) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: ann, reuseIdentifier: reuseId)

            view.annotation = ann
            view.canShowCallout = true
            view.glyphText = formatCount(ann.count)
            
            let isSelected = ann.key == parent.selectedClusterId
            view.markerTintColor = isSelected ? .systemOrange : .systemBlue
            
            view.displayPriority = .defaultHigh
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let ann = view.annotation as? ClusterAnnotation else { return }
            parent.selectedClusterId = ann.key
            updateAnnotationColors(in: mapView)
            parent.onClusterTapped(ann.key)
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard let ann = view.annotation as? ClusterAnnotation else { return }
            if parent.selectedClusterId == ann.key {
                parent.selectedClusterId = nil
            }
            updateAnnotationColors(in: mapView)
        }

        private func formatCount(_ c: Int) -> String {
            if c >= 1_000_000 { return String(format: "%.1fm", Double(c) / 1_000_000) }
            if c >= 10_000 { return String(format: "%.1fk", Double(c) / 1_000) }
            if c >= 1_000 { return String(format: "%.0fk", Double(c) / 1_000) }
            return "\(c)"
        }
    }
}

final class ClusterAnnotation: NSObject, MKAnnotation {
    let key: String
    dynamic var title: String?
    dynamic var count: Int
    dynamic var coordinate: CLLocationCoordinate2D

    init(key: String, title: String?, count: Int, coordinate: CLLocationCoordinate2D) {
        self.key = key
        self.title = title
        self.count = count
        self.coordinate = coordinate
    }
}
