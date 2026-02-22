import MapKit

let options = MKMapSnapshotter.Options()
options.mapRect = MKMapRect.world
options.size = CGSize(width: 400, height: 400)
options.mapType = .standard

let snapshotter = MKMapSnapshotter(options: options)
let sem = DispatchSemaphore(value: 0)
snapshotter.start { snapshot, error in
    if let error = error {
        print("error: \(error)")
    } else {
        print("success")
    }
    sem.signal()
}
sem.wait()
