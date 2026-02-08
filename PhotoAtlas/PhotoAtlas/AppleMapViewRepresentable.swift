import SwiftUI
import MapKit

struct AppleMapViewRepresentable: UIViewRepresentable {
    var clusters: [ClusterBubble]

    var onViewportChanged: (MKCoordinateRegion) -> Void
    var onClusterTapped: (String) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = .hybridFlyover
        map.showsCompass = true
        map.pointOfInterestFilter = .excludingAll

        // World-ish starting view
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
        )
        map.setRegion(region, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self

        // Replace annotations (good enough for MVP; later diff for smoother updates)
        let existing = map.annotations.filter { !($0 is MKUserLocation) }
        map.removeAnnotations(existing)

        let anns: [ClusterAnnotation] = clusters.map {
            ClusterAnnotation(
                key: $0.id,
                title: $0.title,
                count: $0.count,
                coordinate: CLLocationCoordinate2D(latitude: $0.centerLat, longitude: $0.centerLon)
            )
        }
        map.addAnnotations(anns)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: AppleMapViewRepresentable
        private var debounce: DispatchWorkItem?

        init(parent: AppleMapViewRepresentable) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            debounce?.cancel()
            let item = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.parent.onViewportChanged(mapView.region)
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

            // Show the count as glyph text (simple, clean)
            view.glyphText = formatCount(ann.count)
            view.markerTintColor = .systemBlue

            // Optional: keep pin smaller
            view.displayPriority = .defaultHigh

            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let ann = view.annotation as? ClusterAnnotation else { return }
            parent.onClusterTapped(ann.key)
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
    let title: String?
    let count: Int
    dynamic var coordinate: CLLocationCoordinate2D

    init(key: String, title: String?, count: Int, coordinate: CLLocationCoordinate2D) {
        self.key = key
        self.title = title
        self.count = count
        self.coordinate = coordinate
    }
}
