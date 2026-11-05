import SwiftUI
import UniformTypeIdentifiers

/// Sections of the assets panel: dummies are images, but get their own section.
enum AssetGroup: Hashable {
    case video, image, dummy, audio, lyrics
    init(_ a: Asset) {
        switch a.kind {
        case .video: self = .video
        case .image: self = a.isDummy ? .dummy : .image
        case .audio: self = .audio
        case .lyrics: self = .lyrics
        }
    }
}

struct AssetsPanelView: View {
    @EnvironmentObject var editor: EditorModel
    @State private var errorText: String?
    @State private var lastClicked: UUID?
    @State private var collapsed: Set<AssetGroup> = []

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]
    private static let groups: [(AssetGroup, String, String)] = [
        (.video, "Videos", "film"), (.image, "Images", "photo"), (.dummy, "Dummies", "rectangle.dashed"),
        (.audio, "Audio", "waveform"), (.lyrics, "Lyrics", "text.quote"),
    ]

    private var selection: Set<UUID> { editor.selectedAssets }
    private var selectedVideos: [Asset] { editor.project.assets.filter { selection.contains($0.id) && $0.kind == .video } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    // Not lazy: a lazy stack keeps stale heights after a section collapses.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Self.groups, id: \.0) { kind, title, icon in
                            let items = editor.project.assets.filter { AssetGroup($0) == kind }
                            if !items.isEmpty { section(kind, title, icon, items) }
                        }
                        if editor.project.assets.isEmpty { emptyState }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: editor.selectedAssets) { _, ids in
                    if let id = ids.first, ids.count == 1 { withAnimation { reader.scrollTo(id, anchor: .center) } }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { editor.selectedAssets = [] }
            .onDrop(of: [.fileURL], isTargeted: nil, perform: dropFiles)
            .onDeleteCommand { confirmDelete(selection) }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).padding(8)
            }
            footer
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 6) {
            Text("Assets").font(.headline)
            Spacer()
            Button { AssetImporter.presentOpenPanel(for: editor, window: NSApp.keyWindow) } label: { Image(systemName: "plus") }
                .help("Import media (⌘I)")
            Menu {
                ForEach(ProxyScale.allCases) { s in Button("Create \(s.label) proxy") { makeProxies(selectedVideos, s) } }
                Divider()
                Button("Remove proxy") { selectedVideos.forEach { editor.deleteProxy(assetID: $0.id) } }
                    .disabled(!selectedVideos.contains { $0.proxy != nil })
            } label: { Image(systemName: "bolt.horizontal") }
                .menuIndicator(.hidden)
                .help("Proxies for the selected videos")
                .disabled(selectedVideos.isEmpty)
            Button { confirmDelete(selection) } label: { Image(systemName: "trash") }
                .help("Delete selected assets (⌫)")
                .disabled(selection.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Text(selection.isEmpty ? "\(editor.project.assets.count) assets" : "\(selection.count) of \(editor.project.assets.count) selected")
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(.tertiary)
            Text("Drop videos, images, the song and the lyrics TXT here").font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: Sections

    private func section(_ kind: AssetGroup, _ title: String, _ icon: String, _ items: [Asset]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(kind, title, icon, items)
            if !collapsed.contains(kind) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { asset in tile(asset, items) }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Self.groupColor(kind).opacity(0.25)))
                .padding(.horizontal, 6)
            }
        }
    }

    private func sectionHeader(_ kind: AssetGroup, _ title: String, _ icon: String, _ items: [Asset]) -> some View {
            Button {
                if collapsed.contains(kind) { collapsed.remove(kind) } else { collapsed.insert(kind) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed.contains(kind) ? "chevron.right" : "chevron.down").font(.caption2)
                    Image(systemName: icon)
                    Text(title).font(.subheadline.bold())
                    Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 6).fill(Self.groupColor(kind)))
            .padding(.horizontal, 6)
    }

    /// Group colors match the timeline: video blue, image teal, dummy amber, audio green, lyrics purple.
    static func groupColor(_ kind: AssetGroup) -> Color {
        switch kind {
        case .video: Color(red: 0.16, green: 0.24, blue: 0.40)
        case .image: Color(red: 0.12, green: 0.30, blue: 0.32)
        case .dummy: Color(red: 0.36, green: 0.27, blue: 0.10)
        case .audio: Color(red: 0.12, green: 0.30, blue: 0.20)
        case .lyrics: Color(red: 0.28, green: 0.19, blue: 0.38)
        }
    }

    private func tile(_ asset: Asset, _ group: [Asset]) -> some View {
        AssetTile(asset: asset, thumbnails: editor.thumbnails, progress: editor.proxyProgress[asset.id],
                  selected: selection.contains(asset.id), uses: editor.project.usageCount(of: asset.id))
            .id(asset.id)
            .contentShape(Rectangle())
            .gesture(TapGesture().modifiers(.command).onEnded { toggle(asset.id) })
            .gesture(TapGesture().modifiers(.shift).onEnded { extend(to: asset.id, in: group) })
            .onTapGesture { editor.selectedAssets = [asset.id]; lastClicked = asset.id }
            .onDrag {
                // Several selected assets drop in the order they were clicked.
                let ids = selection.contains(asset.id) ? editor.assetSelectionOrder.filter { selection.contains($0) } : [asset.id]
                return NSItemProvider(object: ids.map(\.uuidString).joined(separator: ",") as NSString)
            }
            .contextMenu { menu(for: asset) }
            .task { await editor.thumbnails.ensureThumbnail(for: asset) }
    }

    private func toggle(_ id: UUID) {
        if editor.selectedAssets.contains(id) { editor.selectedAssets.remove(id) } else { editor.selectedAssets.insert(id) }
        lastClicked = id
    }

    private func extend(to id: UUID, in group: [Asset]) {
        guard let anchor = lastClicked, let a = group.firstIndex(where: { $0.id == anchor }), let b = group.firstIndex(where: { $0.id == id }) else {
            editor.selectedAssets = [id]; lastClicked = id; return
        }
        editor.selectedAssets.formUnion(group[min(a, b)...max(a, b)].map(\.id))
    }

    // MARK: Actions

    @ViewBuilder private func menu(for asset: Asset) -> some View {
        let targets = selection.contains(asset.id) ? editor.project.assets.filter { selection.contains($0.id) } : [asset]
        let videos = targets.filter { $0.kind == .video }
        if !videos.isEmpty {
            Menu(videos.count > 1 ? "Create Proxies (\(videos.count))" : (asset.proxy == nil ? "Create Proxy" : "Replace Proxy")) {
                ForEach(ProxyScale.allCases) { s in Button(s.label) { makeProxies(videos, s) } }
            }
            if videos.contains(where: { $0.proxy != nil }) {
                Button("Remove Proxy") { videos.forEach { editor.deleteProxy(assetID: $0.id) } }
            }
            Divider()
        }
        Button(targets.count > 1 ? "Delete \(targets.count) Assets…" : "Delete Asset…") { confirmDelete(Set(targets.map(\.id))) }
    }

    private func makeProxies(_ videos: [Asset], _ scale: ProxyScale) {
        for v in videos where editor.proxyProgress[v.id] == nil { editor.proxyProgress[v.id] = 0 }
        Task { @MainActor in
            for v in videos {   // one at a time: the media engine is shared
                do { try await editor.createProxy(assetID: v.id, scale: scale) } catch { errorText = error.localizedDescription }
            }
        }
    }

    private func confirmDelete(_ ids: Set<UUID>) { editor.confirmDeleteAssets(ids, window: NSApp.keyWindow) }

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
    let selected: Bool
    let uses: Int

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Group {
                    if let img = thumbnails.images[asset.id] {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: icon).font(.title).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let progress {
                    Color.black.opacity(0.5)
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                }
            }
            .frame(height: 62)
            .background(Color.black.opacity(0.35))
            .overlay(alignment: .topTrailing) {
                if let proxy = asset.proxy, progress == nil {
                    Text("PROXY \(proxy.scale.label)").font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(.orange).clipShape(Capsule()).padding(3)
                }
            }
            .overlay(alignment: .topLeading) {
                if uses > 0 {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.white, .green)
                        .padding(3).help("Used in the timeline\(uses > 1 ? " (\(uses)×)" : "")")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let d = asset.duration, asset.kind != .lyrics {
                    Text(Self.duration(d)).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 3).background(.black.opacity(0.6)).padding(3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
            Text(asset.name).font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
    }

    static func duration(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private var icon: String {
        switch asset.kind {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .lyrics: "text.quote"
        }
    }
}
