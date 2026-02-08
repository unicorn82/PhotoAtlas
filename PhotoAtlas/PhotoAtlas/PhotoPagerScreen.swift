import SwiftUI

struct PhotoPagerScreen: View {
    @Environment(\.dismiss) private var dismiss

    let ids: [String]
    @State var selectedIndex: Int

    var body: some View {
        NavigationView {
            TabView(selection: $selectedIndex) {
                ForEach(ids.indices, id: \.self) { i in
                    PhotoDetailScreen(localId: ids[i])
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .navigationTitle("\(selectedIndex + 1) / \(ids.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
