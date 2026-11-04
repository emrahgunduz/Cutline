import SwiftUI
import UniformTypeIdentifiers

struct AssetsPanelView: View {
    @EnvironmentObject var editor: EditorModel
    @State private var proxyProgress: [UUID: Double] = [:]
    @State private var errorText: String?
    @State private var lastClicked: UUID?
    @State private var collapsed: Set<AssetKind> = []

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]
    private static let groups: [(AssetKind, String, String)] = [
        (.video, "Videos", "film"), (.image, "Images", "photo"), (.audio, "Audio", "waveform"), (.lyrics, "Lyrics", "text.quote"),
    ]

    private var selection: Set<UUID> { editor.selectedAssets }
    private var selectedVideos: [Asset] { editor.project.assets.filter { selection.contains($0.id) && $0.kind == .video } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                        ForEach(Self.groups, id: \.0) { kind, title, icon in
                            let items = editor.project.assets.filter { $0.kind == kind }
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

    private func section(_ kind: AssetKind, _ title: String, _ icon: String, _ items: [Asset]) -> some View {
        Section {
            if !collapsed.contains(kind) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { asset in tile(asset, items) }
                }
                .padding(.horizontal, 8)
            }
        } header: {
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
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.background.opacity(0.95))
        }
    }

    private func tile(_ asset: Asset, _ group: [Asset]) -> some View {
        AssetTile(asset: asset, thumbnails: editor.thumbnails, progress: proxyProgress[asset.id],
                  selected: selection.contains(asset.id), uses: editor.project.usageCount(of: asset.id))
            .id(asset.id)
            .contentShape(Rectangle())
            .gesture(TapGesture().modifiers(.command).onEnded { toggle(asset.id) })
            .gesture(TapGesture().modifiers(.shift).onEnded { extend(to: asset.id, in: group) })
            .onTapGesture { editor.selectedAssets = [asset.id]; lastClicked = asset.id }
            .onDrag {
                let ids = selection.contains(asset.id) ? editor.project.assets.filter { selection.contains($0.id) }.map(\.id) : [asset.id]
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
        for v in videos { proxyProgress[v.id] = 0 }
        Task { @MainActor in
            for v in videos {   // one at a time: the media engine is shared
                do {
                    try await editor.createProxy(assetID: v.id, scale: scale) { p in
                        Task { @MainActor in proxyProgress[v.id] = p }
                    }
                } catch { errorText = error.localizedDescription }
                proxyProgress[v.id] = nil
            }
        }
    }

    private func confirmDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let used = ids.filter { editor.project.usageCount(of: $0) > 0 }
        guard !used.isEmpty else { editor.deleteAssets(ids); return }
        let uses = used.map { editor.project.usageCount(of: $0) }.reduce(0, +)
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "Delete this asset?" : "Delete \(ids.count) assets?"
        alert.informativeText = "\(used.count == ids.count && ids.count == 1 ? "It is" : "\(used.count) of them are") used in the timeline (\(uses) placement\(uses == 1 ? "" : "s")). Their clips will be removed too. You can undo this."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { editor.deleteAssets(ids) } }
        if let w = NSApp.keyWindow { alert.beginSheetModal(for: w, completionHandler: handle) } else { handle(alert.runModal()) }
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
                if let proxy = asset.proxy {
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
