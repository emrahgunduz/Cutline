import SwiftUI
import UniformTypeIdentifiers

struct AssetsPanelView: View {
    @EnvironmentObject var editor: EditorModel
    @State private var proxyProgress: [UUID: Double] = [:]
    @State private var errorText: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Assets").font(.headline)
                Spacer()
                Button("Import…") { AssetImporter.presentOpenPanel(for: editor, window: NSApp.keyWindow) }
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(editor.project.assets) { asset in
                        AssetTile(asset: asset, thumbnails: editor.thumbnails, progress: proxyProgress[asset.id])
                            .onDrag { NSItemProvider(object: asset.id.uuidString as NSString) }
                            .contextMenu { menu(for: asset) }
                            .task { await editor.thumbnails.ensureThumbnail(for: asset) }
                    }
                }
                .padding(8)
            }
            .onDrop(of: [.fileURL], isTargeted: nil, perform: dropFiles)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
    }

    @ViewBuilder private func menu(for asset: Asset) -> some View {
        if asset.kind == .video {
            Menu(asset.proxy == nil ? "Create Proxy" : "Replace Proxy") {
                ForEach(ProxyScale.allCases) { scale in
                    Button(scale.label) { makeProxy(asset, scale) }
                }
            }
            if asset.proxy != nil {
                Button("Delete Proxy") { editor.deleteProxy(assetID: asset.id) }
            }
        }
    }

    private func makeProxy(_ asset: Asset, _ scale: ProxyScale) {
        proxyProgress[asset.id] = 0
        Task { @MainActor in
            do {
                try await editor.createProxy(assetID: asset.id, scale: scale) { p in
                    Task { @MainActor in proxyProgress[asset.id] = p }
                }
            } catch { errorText = error.localizedDescription }
            proxyProgress[asset.id] = nil
        }
    }

    private func dropFiles(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
            }
            let errors = await editor.importFiles(urls)
            errorText = errors.first?.localizedDescription
        }
        return true
    }
}

private struct AssetTile: View {
    let asset: Asset
    @ObservedObject var thumbnails: ThumbnailGenerator
    let progress: Double?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = thumbnails.images[asset.id] {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                if let proxy = asset.proxy {
                    Text("P \(proxy.scale.label)").font(.caption2.bold())
                        .padding(.horizontal, 4).background(.orange).clipShape(Capsule()).padding(3)
                }
            }
            if let progress { ProgressView(value: progress).controlSize(.small) }
            Text(asset.name).font(.caption).lineLimit(1).truncationMode(.middle)
        }
    }

    private var icon: String {
        switch asset.kind {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .lyrics: "text.quote"
        }
    }
}
