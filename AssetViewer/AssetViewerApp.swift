import SwiftUI
import AppKit

@main
struct AssetViewerApp: App {
    var body: some Scene {
        WindowGroup { ContentView().frame(minWidth: 950, minHeight: 600) }
    }
}
@MainActor
final class BrowserModel: ObservableObject {
    @Published var servers: [Server] = []
    @Published var selected: Asset?
    @Published var selectedServer: Server?
    @Published var scanning = false
    @Published var diagnostics = "No scan completed yet."
    @Published var status = "Discover servers to begin."
    @Published var errors: [String] = []
    @Published var connecting = false
    @Published var connectionError: String?
    init() {
        // Remove history saved by earlier versions; this version stores no recents.
        UserDefaults.standard.removeObject(forKey: "AssetViewer.recentServers.v1")
    }
    private func accept(_ server: Server) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            if servers[index] != server { folders.removeValue(forKey: server.id) }
            servers[index] = server
        } else { servers.append(server) }
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func connect(_ text: String) async -> Bool {
        guard !connecting else { return false }
        connecting = true; connectionError = nil
        defer { connecting = false }
        do {
            let server = try await UPnP.resolve(text)
            accept(server)
            select(nil, server: server)
            status = "Connected to \(server.name)"
            return true
        } catch {
            connectionError = error.localizedDescription
            return false
        }
    }
    private var folders: [String: [String: FolderLoader]] = [:]
    func folder(server: Server, objectID: String) -> FolderLoader {
        if let existing = folders[server.id]?[objectID] { return existing }
        let loader = FolderLoader(server: server, objectID: objectID)
        folders[server.id, default: [:]][objectID] = loader
        return loader
    }
    func add(_ url: URL) async {
        do {
            let server = try await UPnP.describe(url)
            accept(server)
        } catch { errors.append("\(url): \(error.localizedDescription)") }
    }
    func scan() async {
        guard !scanning else { return }
        scanning = true
        errors = []
        status = "Searching the local network…"
        defer { scanning = false }
        do {
            let result = try await UPnP.discover()
            diagnostics = result.diagnostics.joined(separator: "\n")
            for url in result.locations { await add(url) }
            status = "\(servers.count) devices found · \(servers.filter { $0.control != nil }.count) browsable media servers"
        } catch { status = error.localizedDescription }
    }
    func select(_ asset: Asset?, server: Server) {
        selected = asset; selectedServer = server

    }
}
struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @State private var manual = ""
    @State private var showAdd = false
    var body: some View {
        NavigationSplitView {
            List {
                ForEach(model.servers) { server in
                    ServerRow(server: server).environmentObject(model)
                }
            }
            .navigationTitle("UPnP Servers")
            .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 650)
            VStack(alignment: .leading, spacing: 6) {
                if model.scanning { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Discovery diagnostics") {
                    ScrollView {
                        Text(model.diagnostics).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180)
                    Button("Copy diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.diagnostics, forType: .string)
                    }
                }
                if !model.errors.isEmpty {
                    DisclosureGroup("Connection issues (\(model.errors.count))") {
                        ScrollView { Text(model.errors.joined(separator: "\n\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 120)
                    }
                }
            }.padding(12)
        } detail: {
            if let asset = model.selected {
                Inspector(title: asset.title, fields: asset.fields, xml: asset.xml)
            } else if let server = model.selectedServer {
                Inspector(title: server.name, fields: [Field(name: "Description URL", value: server.location.absoluteString), Field(name: "ContentDirectory", value: server.control?.absoluteString ?? "Not available"), Field(name: "Service type", value: server.serviceType)], xml: server.xml)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("Explore your media library").font(.title2)
                    Text("Expand a server on the left, then select a folder or asset to inspect its data.").foregroundStyle(.secondary)
                }.padding()
            }
        }
        .toolbar {
            Button { Task { await model.scan() } } label: { Label("Discover", systemImage: "arrow.clockwise") }.disabled(model.scanning)
            Button { model.connectionError = nil; showAdd = true } label: { Label("Add Server", systemImage: "plus") }
        }
        .sheet(isPresented: $showAdd) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add a UPnP device").font(.headline)
                Text("Enter a hostname or IP address, optionally with a port. Full device-description URLs also work.")
                TextField("192.168.3.6 or althjofr.local", text: $manual).textFieldStyle(.roundedBorder).disabled(model.connecting)
                Text("Tries common UPnP locations, including AssetUPnP. Custom server locations may need the full URL.").font(.caption).foregroundStyle(.secondary)
                if model.connecting { ProgressView("Connecting…") }
                if let error = model.connectionError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Button("Cancel") { showAdd = false }.disabled(model.connecting)
                    Spacer()
                    Button("Connect") {
                        Task { if await model.connect(manual) { showAdd = false } }
                    }.disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.connecting)
                }
            }.padding(24).frame(width: 510)
            .interactiveDismissDisabled(model.connecting)
        }
        .task { await model.scan() }
    }
}
struct ServerRow: View {
    let server: Server
    @EnvironmentObject var model: BrowserModel
    @State private var expanded = false
    var body: some View {
        if server.control != nil {
            DisclosureGroup(isExpanded: $expanded) {
                ChildrenView(server: server, objectID: "0", ancestors: ["0"])
            } label: {
                Button { model.select(nil, server: server) } label: { Label(server.name, systemImage: "server.rack") }.buttonStyle(.plain)
            }
        } else {
            Button { model.select(nil, server: server) } label: { Label(server.name + " (no media directory)", systemImage: "network") }.buttonStyle(.plain)
        }
    }
}
// Folder requests belong to a cached model, not a transient List/DisclosureGroup view.
@MainActor
final class FolderLoader: ObservableObject {
    let server: Server
    let objectID: String
    @Published var assets: [Asset] = []
    @Published var offset = 0
    @Published var total = 1
    @Published var busy = false
    @Published var error: String?
    @Published var loaded = false
    private var request: Task<Void, Never>?
    init(server: Server, objectID: String) {
        self.server = server
        self.objectID = objectID
    }
    func ensureLoaded() {
        if !loaded && !busy { load() }
    }
    func reload() {
        guard !busy else { return }
        assets = []; offset = 0; total = 1; loaded = false
        load()
    }
    func load() {
        guard !busy else { return }
        busy = true
        error = nil
        // An unstructured task survives SwiftUI cancelling a row's appearance task.
        request = Task { [self] in
            defer { busy = false; request = nil }
            do {
                let page = try await UPnP.browse(server, object: objectID, start: offset)
                if page.returned == 0 && offset < page.total {
                    throw ViewerError(message: "Server returned an empty page before the end of this folder. Reload to retry.")
                }
                var seen = Set(assets.map(\.id))
                assets.append(contentsOf: page.assets.filter { seen.insert($0.id).inserted })
                offset += page.returned
                total = page.total
                loaded = true
            } catch is CancellationError {
                // Cancellation is not a server error, and does not mark the folder loaded.
            } catch let failure as URLError where failure.code == .cancelled {
                // URLSession uses URLError.cancelled for cancelled HTTP requests.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
struct ChildrenView: View {
    let server: Server
    let objectID: String
    let ancestors: Set<String>
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        FolderContents(loader: model.folder(server: server, objectID: objectID), ancestors: ancestors)
    }
}
struct FolderContents: View {
    @ObservedObject var loader: FolderLoader
    let ancestors: Set<String>
    var body: some View {
        Group {
            ForEach(loader.assets) { asset in
                AssetRow(asset: asset, server: loader.server, ancestors: ancestors)
            }
            if loader.busy { ProgressView().controlSize(.small) }
            if let error = loader.error { Text(error).font(.caption).foregroundStyle(.red) }
            if !loader.busy && (loader.offset < loader.total || loader.error != nil) {
                Button(loader.error == nil ? "Load more…" : "Retry") { loader.load() }
            }
            if loader.loaded && loader.assets.isEmpty && loader.error == nil && !loader.busy {
                Text("Empty folder").foregroundStyle(.secondary)
            }
            if loader.loaded && !loader.busy {
                Button("Reload folder") { loader.reload() }.font(.caption)
            }
        }.onAppear { loader.ensureLoaded() }
    }
}
struct AssetRow: View {
    let asset: Asset
    let server: Server
    let ancestors: Set<String>
    @EnvironmentObject var model: BrowserModel
    @State private var expanded = false
    var body: some View {
        if asset.container && !ancestors.contains(asset.id) {
            DisclosureGroup(isExpanded: $expanded) {
                // AnyView breaks the recursive opaque View type.
                AnyView(ChildrenView(server: server, objectID: asset.id, ancestors: ancestors.union([asset.id])))
            } label: { row }
        } else { row }
    }
    private var row: some View {
        Button { model.select(asset, server: server) } label: {
            Label(asset.title.isEmpty ? asset.id : asset.title, systemImage: asset.container ? "folder" : "doc.richtext")
                .foregroundStyle(model.selected?.id == asset.id && model.selectedServer?.id == server.id ? Color.accentColor : Color.primary)
        }.buttonStyle(.plain).help(asset.id)
    }
}
struct Inspector: View {
    let title: String
    let fields: [Field]
    let xml: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.title2).textSelection(.enabled)
                Spacer()
                Button("Copy XML") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(xml, forType: .string) }
            }
            TabView {
                ScrollView {
                    Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 12) {
                        ForEach(fields) { field in
                            GridRow {
                                Text(field.name).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                                Text(field.value).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                        }
                    }.padding().textSelection(.enabled)
                }.tabItem { Text("Metadata") }
                ScrollView([.horizontal, .vertical]) {
                    Text(xml).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .topLeading)
                }.tabItem { Text("Raw XML") }
            }
        }.padding(20)
    }
}
