import SwiftUI

struct SelectedPhotosCartSheet: View {
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var model: AppModel
    @StateObject private var imageLoader = PhotoImageLoader()

    let onAlbumFootprintDiary: () -> Void

    var body: some View {
        NavigationView {
            List {
                if model.footprintDiaryCartIds.isEmpty {
                    Text("No photos selected yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(model.footprintDiaryCartIds, id: \.self) { id in
                            HStack(spacing: 12) {
                                PhotoThumbnailView(localId: id)
                                    .environmentObject(imageLoader)

                                Text(id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                Spacer()

                                Button {
                                    model.removeFromFootprintDiaryCart(id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .tint(.red)
                            }
                        }
                        .onMove { from, to in
                            model.moveFootprintDiaryCart(fromOffsets: from, toOffset: to)
                        }
                        .onDelete { offsets in
                            model.footprintDiaryCartIds.remove(atOffsets: offsets)
                        }
                    } header: {
                        Text("Selected (\(model.footprintDiaryCartIds.count))")
                    }
                }
            }
            .navigationTitle("Cart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") { model.clearFootprintDiaryCart() }
                        .disabled(model.footprintDiaryCartIds.isEmpty)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                        .disabled(model.footprintDiaryCartIds.isEmpty)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Album") {
                        dismiss()
                        onAlbumFootprintDiary()
                    }
                }
            }
        }
    }
}
