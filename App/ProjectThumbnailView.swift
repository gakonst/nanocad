import SwiftUI

/// Render one saved revision once; scrolling never creates a live CAD viewport.
struct ProjectThumbnailView: View {
    let root: URL
    var refresh: Int
    @State private var image: UIImage?
    private struct LoadID: Equatable { let root: URL; let refresh: Int }
    private struct Cached: Codable { let revision: String; let image: Data }
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .accessibilityLabel("Model thumbnail").accessibilityIdentifier("project-thumbnail")
            } else {
                Image(systemName: "cube.transparent").font(.title2).foregroundStyle(.teal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityHidden(true)
            }
        }
        .frame(width: 72, height: 60).background(.white.opacity(0.04))
        .clipShape(.rect(cornerRadius: 12))
        .task(id: LoadID(root: root, refresh: refresh)) {
            // Do not show the previous project/revision while its replacement loads.
            image = nil
            let root = root
            let loaded = await Task.detached(priority: .utility) { () -> (CADDocument?, Data?) in
                guard let document = try? WorkspacePersistence(root: root).loadDocument() else { return (nil, nil) }
                let cached = try? JSONDecoder().decode(Cached.self, from: Data(contentsOf: root.appending(path: "thumbnail.json")))
                return (document, cached?.revision == document.revision ? cached?.image : nil)
            }.value
            // An older cancelled load must never clear a newer task's image.
            guard !Task.isCancelled else { return }
            guard let document = loaded.0 else { return }
            if let cached = loaded.1, let decoded = UIImage(data: cached) { image = decoded; return }
            let thumbnail = CADViewport.thumbnail(document: document)
            guard !Task.isCancelled else { return }
            image = thumbnail
            if let data = thumbnail.jpegData(compressionQuality: 0.78),
               let encoded = try? JSONEncoder().encode(Cached(revision: document.revision, image: data)) {
                _ = await Task.detached(priority: .utility) {
                    try? encoded.write(to: root.appending(path: "thumbnail.json"), options: .atomic)
                }.value
            }
        }
    }
}
