import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Intentionally minimal/clean.
                Text("MVP scaffold. Next: photo indexing + offline map clusters.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .navigationTitle("")
        }
    }
}
