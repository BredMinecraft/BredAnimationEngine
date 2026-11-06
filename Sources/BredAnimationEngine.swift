import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

struct AnimationItem: Codable, Identifiable {
    var id = UUID()
    var file: String
    var name: String
    var scale = 0.5
    var rotation: Double? = nil
    var flipX: Bool? = nil
    var flipY: Bool? = nil
    var opacity: Double? = nil
    var locked: Bool? = nil
    var hideOnHover: Bool? = nil
    var audioFile: String? = nil
    var volume: Double? = nil
    var audioLoop: Bool? = nil
    var fps: Int? = nil
    var speed = 1.0
    var topmost = true
    var clickThrough = false
}

final class Clip {
    struct Metadata: Codable {
        let width: Int
        let height: Int
        let originalWidth: Double
        let originalHeight: Double
        let delays: [Double]
    }
    let delays: [Double]
    let size: CGSize
    let count: Int
    private let width: Int
    private let height: Int
    private let pixels: Data
    private let lock = NSLock()
    private let cache = NSCache<NSNumber, CGImage>()
    static func cacheURLs(_ url: URL) -> [URL] {
        [url.appendingPathExtension("rgba-v1"), url.appendingPathExtension("frames-v1.json")]
    }
    init(url: URL, progress: @escaping (Double) -> Void) throws {
        let paths = Self.cacheURLs(url)
        let rawURL = paths[0], metadataURL = paths[1]
        let fm = FileManager.default
        let metadata: Metadata
        if let data = try? Data(contentsOf: metadataURL),
            let saved = try? JSONDecoder().decode(Metadata.self, from: data),
            saved.width > 0, saved.height > 0, !saved.delays.isEmpty,
            let attributes = try? fm.attributesOfItem(atPath: rawURL.path),
            (attributes[.size] as? NSNumber)?.int64Value == Int64(saved.width * saved.height * 4) * Int64(saved.delays.count) {
            metadata = saved
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetCount(source) > 0,
                let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                let originalWidth = first[kCGImagePropertyPixelWidth as String] as? NSNumber,
                let originalHeight = first[kCGImagePropertyPixelHeight as String] as? NSNumber else { throw ClipError.invalid }
            let count = CGImageSourceGetCount(source)
            let ratio = min(1.0, 768.0 / max(originalWidth.doubleValue, originalHeight.doubleValue))
            let w = max(1, Int(originalWidth.doubleValue * ratio))
            let h = max(1, Int(originalHeight.doubleValue * ratio))
            let bytesPerFrame = w * h * 4
            let required = Int64(bytesPerFrame) * Int64(count)
            let attributes = try fm.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)
            if let free = attributes[.systemFreeSize] as? NSNumber, required + 512 * 1024 * 1024 > free.int64Value { throw ClipError.disk }
            let temporary = rawURL.appendingPathExtension(UUID().uuidString)
            guard fm.createFile(atPath: temporary.path, contents: nil) else { throw ClipError.disk }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close(); try? fm.removeItem(at: temporary) }
            var times: [Double] = []
            for index in 0..<count {
                try autoreleasepool {
                    guard let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ClipError.invalid }
                    var bytes = Data(count: bytesPerFrame)
                    try bytes.withUnsafeMutableBytes { buffer in
                        guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ClipError.invalid }
                        context.interpolationQuality = .high
                        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                    }
                    try output.write(contentsOf: bytes)
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
                    let png = properties?[kCGImagePropertyPNGDictionary as String] as? [String: Any]
                    let delay = (png?["UnclampedDelayTime"] as? NSNumber)?.doubleValue ?? (png?["DelayTime"] as? NSNumber)?.doubleValue ?? 1.0 / 30.0
                    times.append(delay > 0 ? max(0.001, delay) : 1.0 / 30.0)
                }
                if index % max(1, count / 100) == 0 || index == count - 1 { progress(Double(index + 1) / Double(count)) }
            }
            try output.synchronize()
            try output.close()
            if fm.fileExists(atPath: rawURL.path) { try fm.removeItem(at: rawURL) }
            try fm.moveItem(at: temporary, to: rawURL)
            metadata = Metadata(width: w, height: h, originalWidth: originalWidth.doubleValue, originalHeight: originalHeight.doubleValue, delays: times)
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        }
        width = metadata.width; height = metadata.height
        size = CGSize(width: metadata.originalWidth, height: metadata.originalHeight)
        delays = metadata.delays; count = delays.count
        pixels = try Data(contentsOf: rawURL, options: .alwaysMapped)
        cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 8
        guard frame(0) != nil else { throw ClipError.invalid }
    }
    func frame(_ index: Int) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        let key = NSNumber(value: index)
        if let image = cache.object(forKey: key) { return image }
        let length = width * height * 4
        let offset = index * length
        guard index >= 0, index < count, offset + length <= pixels.count,
            let provider = CGDataProvider(data: pixels.subdata(in: offset..<(offset + length)) as CFData),
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        cache.setObject(image, forKey: key, cost: length)
        return image
    }
    enum ClipError: LocalizedError {
        case invalid, disk
        var errorDescription: String? {
            switch self {
            case .invalid: return "Unable to read this image/APNG."
            case .disk: return "Not enough disk space for the prepared animation frames."
            }
        }
    }
}

final class PlayerView: NSView {
    private let imageLayer = CALayer()
    private var clip: Clip?
    private var timer: Timer?
    private var generation = UUID()
    private let decoder = DispatchQueue(label: "pl.bredmc.animation-decoder", qos: .userInitiated)
    var fps: Int? = nil
    var speed = 1.0
    var paused = false
    var onRightClick: (() -> Void)?
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
    func setOrientation(angle: Double, flipX: Bool, flipY: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let rotation = CATransform3DMakeRotation(CGFloat(angle), 0, 0, 1)
        imageLayer.transform = CATransform3DScale(rotation, flipX ? -1 : 1, flipY ? -1 : 1, 1)
        CATransaction.commit()
        needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func load(_ clip: Clip) {
        stop(); self.clip = clip
        prepare(0, deadline: ProcessInfo.processInfo.systemUptime, token: generation)
    }
    func stop() { generation = UUID(); timer?.invalidate(); timer = nil; clip = nil }
    private func prepare(_ index: Int, deadline: Double, token: UUID) {
        guard token == generation, let clip else { return }
        decoder.async { [weak self] in
            guard let image = clip.frame(index) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                let display = { [weak self] in
                    guard let self, self.generation == token else { return }
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.imageLayer.contents = image; CATransaction.commit()
                    let next = self.paused ? index : (index + 1) % clip.count
                    let duration = self.fps.map { 1.0 / Double(max(1, $0)) } ?? clip.delays[index]
                    let nextDeadline = ProcessInfo.processInfo.systemUptime + duration / max(0.1, self.speed)
                    self.prepare(next, deadline: nextDeadline, token: token)
                }
                let wait = deadline - ProcessInfo.processInfo.systemUptime
                if wait <= 0 { display() }
                else {
                    let timer = Timer(timeInterval: wait, repeats: false) { _ in display() }
                    self.timer = timer; RunLoop.main.add(timer, forMode: .common)
                }
            }
        }
    }
    deinit { timer?.invalidate() }
}

final class DesktopPanel: NSPanel {
    let player = PlayerView(frame: .zero)
    var audio: AVAudioPlayer?
    var hoverTimer: Timer?
    var currentItem: AnimationItem?
    init(clip: Clip, item: AnimationItem) {
        super.init(contentRect: NSRect(x: 100, y: 70, width: 300, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        isMovableByWindowBackground = true; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSView(frame: frame); contentView?.addSubview(player); player.load(clip); apply(item, size: clip.size)
    }
    func apply(_ item: AnimationItem, size: CGSize) {
        currentItem = item
        isMovableByWindowBackground = !(item.locked ?? false)
        alphaValue = item.opacity ?? 1

        audio?.volume = Float(item.volume ?? 0.75)
        audio?.numberOfLoops = item.audioLoop == true ? -1 : 0
        if hoverTimer == nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                guard let self, let item = self.currentItem else { return }
                self.alphaValue = item.hideOnHover == true && self.frame.contains(NSEvent.mouseLocation) ? 0 : (item.opacity ?? 1)
            }
        }
        level = item.topmost ? .floating : .normal
        ignoresMouseEvents = item.clickThrough; player.speed = item.speed; player.fps = item.fps
        let w = max(32, size.width * item.scale), h = max(32, size.height * item.scale)
        let angle = (item.rotation ?? 0) * .pi / 180
        let boundsWidth = abs(w * cos(angle)) + abs(h * sin(angle))
        let boundsHeight = abs(w * sin(angle)) + abs(h * cos(angle))
        setContentSize(NSSize(width: boundsWidth, height: boundsHeight))
        player.frame = NSRect(x: (boundsWidth - w) / 2, y: (boundsHeight - h) / 2, width: w, height: h)
        player.setOrientation(angle: angle, flipX: item.flipX == true, flipY: item.flipY == true)
    }
    override func close() { hoverTimer?.invalidate(); hoverTimer = nil; audio?.stop(); player.stop(); super.close() }
}

final class Engine: ObservableObject {
    @Published var items: [AnimationItem] = []
    @Published var selected: UUID?
    @Published var search = ""
    @Published var error: String?
    @Published var loading = Set<UUID>()
    @Published var preparation: [UUID: Double] = [:]
    @Published var revision = 0
    @Published var tab = "Library"
    @Published var panelMode = "main"
    @Published var editorID: UUID?
    var controlPanel: NSPanel?
    var commandMonitor: Any?
    var hidden = false
    func startMonitoring() {
        guard commandMonitor == nil else { return }
        commandMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard event.modifierFlags.contains(.command), let self else { return }
            if let entry = self.panels.first(where: { $0.value.frame.contains(NSEvent.mouseLocation) }) { self.showControls(entry.key) }
        }
    }
    func showControls(_ id: UUID) {
        selected = id
        controlPanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 500, width: 370, height: 530), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Animation controls"; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ControlsView(engine: self, id: id))
        panel.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true); controlPanel = panel
    }
    func toggleHidden() {
        hidden.toggle()
        for panel in panels.values { if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() } }
        revision += 1
    }
    func clearCache() {
        guard loading.isEmpty else { error = "Please wait until animation preparation is complete."; return }
        stopAll(); cache.removeAll()
        do { for item in items { for path in Clip.cacheURLs(root.appendingPathComponent(item.file)) { if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) } } } }
        catch { self.error = error.localizedDescription }
        revision += 1
    }
    func chooseAudio(_ id: UUID) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url, var item = items.first(where: { $0.id == id }) else { return }
        let name = UUID().uuidString + "." + url.pathExtension
        do { try FileManager.default.copyItem(at: url, to: root.appendingPathComponent(name)); item.audioFile = name; update(item); restartAudio(id) }
        catch { self.error = error.localizedDescription }
    }
    func restartAudio(_ id: UUID) {
        guard let panel = panels[id], let item = items.first(where: { $0.id == id }) else { return }
        panel.audio?.stop(); panel.audio = nil
        guard let file = item.audioFile else { return }
        do { let audio = try AVAudioPlayer(contentsOf: root.appendingPathComponent(file)); audio.volume = Float(item.volume ?? 0.75); audio.numberOfLoops = item.audioLoop == true ? -1 : 0; panel.audio = audio; audio.play() }
        catch { self.error = error.localizedDescription }
    }
    func configuration(_ exporting: Bool) {
        if exporting {
            let dialog = NSSavePanel(); dialog.nameFieldStringValue = "Bred-settings.json"
            if dialog.runModal() == .OK, let url = dialog.url {
                do { try JSONEncoder().encode(items).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
            }
        } else {
            let dialog = NSOpenPanel(); dialog.allowedContentTypes = [.json]
            if dialog.runModal() == .OK, let url = dialog.url {
                do {
                    let imported = try JSONDecoder().decode([AnimationItem].self, from: Data(contentsOf: url))
                    for var item in imported where items.contains(where: { $0.id == item.id }) {
                        guard let existing = items.first(where: { $0.id == item.id }) else { continue }
                        item.file = existing.file; item.audioFile = existing.audioFile; update(item)
                    }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    private var cache: [UUID: Clip] = [:]
    private var panels: [UUID: DesktopPanel] = [:]
    private var pending: [UUID: [(Clip) -> Void]] = [:]
    let root: URL
    var manifest: URL { root.appendingPathComponent("library.json") }
    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BredAnimationEngine")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) { items = try JSONDecoder().decode([AnimationItem].self, from: Data(contentsOf: manifest)) }
        } catch { self.error = error.localizedDescription }
        selected = items.first?.id
    }
    func save() {
        do { try JSONEncoder().encode(items).write(to: manifest, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
    func add() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.gif, .png, UTType(filenameExtension: "apng") ?? .png]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            var item = AnimationItem(file: "", name: url.lastPathComponent)
            item.file = item.id.uuidString + ".png"
            do { try FileManager.default.copyItem(at: url, to: root.appendingPathComponent(item.file)); items.append(item); selected = item.id }
            catch { self.error = error.localizedDescription }
        }
        save()
    }
    func clip(_ id: UUID, done: @escaping (Clip) -> Void) {
        if let value = cache[id] { done(value); return }
        if pending[id] != nil { pending[id]?.append(done); return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        pending[id] = [done]; loading.insert(id)
        let url = root.appendingPathComponent(item.file)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Clip(url: url) { value in
                DispatchQueue.main.async { self.preparation[id] = value }
            } }
            DispatchQueue.main.async {
                self.loading.remove(id)
                self.preparation.removeValue(forKey: id)
                let callbacks = self.pending.removeValue(forKey: id) ?? []
                guard self.items.contains(where: { $0.id == id }) else { return }
                switch result {
                case .success(let clip):
                    self.cache[id] = clip; callbacks.forEach { $0(clip) }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
    func launch(_ id: UUID) {
        clip(id) { clip in
            guard let item = self.items.first(where: { $0.id == id }) else { return }
            if let panel = self.panels[id] { panel.orderFrontRegardless(); return }
            let panel = DesktopPanel(clip: clip, item: item)
            panel.player.onRightClick = { [weak self] in self?.showControls(id) }
            self.panels[id] = panel; panel.orderFrontRegardless(); self.restartAudio(id); self.startMonitoring(); self.revision += 1
        }
    }
    func stop(_ id: UUID) { panels.removeValue(forKey: id)?.close(); revision += 1 }
    func stopAll() { Array(panels.keys).forEach { stop($0) } }
    func active(_ id: UUID) -> Bool { panels[id] != nil }
    func update(_ item: AnimationItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        if let clip = cache[item.id] { panels[item.id]?.apply(item, size: clip.size) }
        save()
    }
    func deleteSelected() {
        guard let id = selected, let item = items.first(where: { $0.id == id }) else { return }
        stop(id); cache.removeValue(forKey: id)
        do { try FileManager.default.removeItem(at: root.appendingPathComponent(item.file))
            for url in Clip.cacheURLs(root.appendingPathComponent(item.file)) { try? FileManager.default.removeItem(at: url) } }
        catch { self.error = error.localizedDescription; return }
        items.removeAll { $0.id == id }; selected = items.first?.id; save()
    }
}

struct Preview: NSViewRepresentable {
    @ObservedObject var engine: Engine
    let id: UUID
    var fps: Int? = nil
    var speed: Double = 1
    final class Coordinator { var id: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PlayerView { PlayerView(frame: .zero) }
    func updateNSView(_ view: PlayerView, context: Context) {
        view.speed = speed; view.fps = fps
        guard context.coordinator.id != id else { return }
        context.coordinator.id = id
        engine.clip(id) { [weak view, weak coordinator = context.coordinator] clip in
            guard coordinator?.id == id else { return }; view?.load(clip)
        }
    }
    static func dismantleNSView(_ view: PlayerView, coordinator: Coordinator) { view.stop() }
}
struct Thumbnail: NSViewRepresentable {
    let url: URL
    final class Coordinator { var url: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.image = nil
        let requestedURL = url
        let coordinator = context.coordinator
        DispatchQueue.global(qos: .utility).async { [weak view, weak coordinator] in
            guard let source = CGImageSourceCreateWithURL(requestedURL as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 420] as CFDictionary) else { return }
            DispatchQueue.main.async {
                guard coordinator?.url == requestedURL else { return }
                view?.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }
}

enum Theme {
    static let background = Color(red: 0.035, green: 0.05, blue: 0.065)
    static let panel = Color(red: 0.06, green: 0.08, blue: 0.105)
    static let border = Color(red: 0.15, green: 0.20, blue: 0.26)
    static let blue = Color(red: 0.36, green: 0.63, blue: 1)
}
struct EngineButton: ButtonStyle {
    var primary = false
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .foregroundColor(primary ? .black : .white)
            .background(primary ? Theme.blue : danger ? Color.red.opacity(0.12) : Theme.panel)
            .cornerRadius(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(danger ? Color.red.opacity(0.4) : Theme.border))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
struct LibraryView: View {
    @ObservedObject var engine: Engine
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let url = Bundle.main.url(forResource: "BrandIcon", withExtension: "png"), let icon = NSImage(contentsOf: url) {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 36, height: 36)
                } else {
                    Image(systemName: "sparkles.rectangle.stack.fill").font(.system(size: 26)).foregroundColor(.purple)
                }
                VStack(alignment: .leading, spacing: 5) { Text("Bred Animation Engine").bold(); Text("Desktop animation engine").font(.system(size: 10)).foregroundColor(.secondary) }
                Spacer()
                Button { engine.toggleHidden() } label: { Image(systemName: "eye") }.buttonStyle(.plain)
            }.padding(.horizontal, 20).padding(.vertical, 12).background(Theme.panel)
            Divider()
            HStack(spacing: 16) {
                ForEach(["Library", "Tools", "Settings"], id: \.self) { name in
                    Button { engine.tab = name } label: {
                        Label(name, systemImage: name == "Library" ? "square.grid.2x2" : name == "Tools" ? "wrench" : "gearshape")
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(engine.tab == name ? Theme.blue.opacity(0.14) : .clear).cornerRadius(9)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(engine.tab == name ? Theme.blue.opacity(0.4) : .clear))
                    }.buttonStyle(.plain)
                }
                Spacer(); Text("Desktop animation workspace").font(.caption).foregroundColor(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 8).background(Theme.panel.opacity(0.6))
            Divider()
            if engine.tab == "Library" { library }
            else if engine.tab == "Tools" { tools }
            else { settings }
        }.background(Theme.background).preferredColorScheme(.dark).font(.system(size: 12))
            .frame(minWidth: 1000, minHeight: 700)
            .alert("Bred Animation Engine", isPresented: Binding(get: { engine.error != nil }, set: { if !$0 { engine.error = nil } })) { Button("OK") { engine.error = nil } } message: { Text(engine.error ?? "") }
            .sheet(item: Binding(get: { engine.items.first(where: { $0.id == engine.editorID }) }, set: { _ in engine.editorID = nil })) { item in
                VStack(alignment: .leading, spacing: 20) {
                    Text("Edit while the animation is running").font(.title2.bold())
                    Text("Changes are applied immediately.").foregroundColor(.secondary)
                    AnimationFields(engine: engine, id: item.id)
                    Button("Close") { engine.editorID = nil }.buttonStyle(EngineButton())
                }.padding(24).frame(width: 390).background(Theme.panel).preferredColorScheme(.dark)
            }
    }
    var library: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Library").font(.system(size: 25, weight: .bold))
            Text("Your desktop animations. Select one to preview it, or double-click to launch it.").foregroundColor(.secondary)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 20) {
                    HStack {
                        Button("Add animation", action: engine.add).buttonStyle(EngineButton(primary: true)).fixedSize()
                        Button("Delete selected", action: engine.deleteSelected).buttonStyle(EngineButton(danger: true)).fixedSize().disabled(engine.selected == nil)
                        TextField("Search in your library…", text: $engine.search).textFieldStyle(.plain).padding(11).background(Theme.panel).cornerRadius(9).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                    }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 18)], spacing: 20) {
                            ForEach(engine.items.filter { engine.search.isEmpty || $0.name.localizedCaseInsensitiveContains(engine.search) }) { item in
                                VStack(alignment: .leading, spacing: 8) {
                                    Thumbnail(url: engine.root.appendingPathComponent(item.file)).frame(height: 145).frame(maxWidth: .infinity).background(Theme.background).cornerRadius(9)
                                    HStack { Text(item.name).font(.system(size: 11)).lineLimit(2); Spacer(); Image(systemName: engine.active(item.id) ? "checkmark.square.fill" : "square").foregroundColor(engine.active(item.id) ? Theme.blue : Theme.border) }
                                }.padding(10).background(engine.selected == item.id ? Theme.blue.opacity(0.12) : Theme.panel).cornerRadius(13)
                                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(engine.selected == item.id ? Theme.blue : Theme.border, lineWidth: engine.selected == item.id ? 2 : 1))
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { engine.selected = item.id; engine.launch(item.id) }
                                    .onTapGesture { engine.selected = item.id; engine.panelMode = "main" }
                                    .contextMenu { Button("Launch") { engine.launch(item.id) }; Button("Controls") { engine.showControls(item.id) }; Button("Edit live") { engine.editorID = item.id } }
                            }
                        }.padding(3)
                        if engine.items.isEmpty { Text("Add an APNG or GIF to get started.").foregroundColor(.secondary).padding(60) }
                    }
                }
                if let item = engine.items.first(where: { $0.id == engine.selected }) { inspector(item).frame(width: 310) }
            }
        }.padding(24)
    }
    func inspector(_ item: AnimationItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Preview(engine: engine, id: item.id, fps: item.fps, speed: item.speed)
                    .rotationEffect(.degrees(item.rotation ?? 0)).scaleEffect(x: item.flipX == true ? -1 : 1, y: item.flipY == true ? -1 : 1)
                    .frame(height: 250).frame(maxWidth: .infinity).background(Theme.background).cornerRadius(14)
                if engine.loading.contains(item.id) { ProgressView(value: engine.preparation[item.id] ?? 0); Text("Preparing: \(Int((engine.preparation[item.id] ?? 0) * 100))%") }
                Text(engine.panelMode == "audio" ? "Animation audio" : "Selected animation").font(.system(size: 16, weight: .bold))
                Text(item.name).font(.caption).textSelection(.enabled)
                if engine.panelMode == "audio" {
                    Button("← Back") { engine.panelMode = "main" }
                    Text(item.audioFile ?? "No audio selected").font(.caption).lineLimit(2)
                    Button("Choose audio…") { engine.chooseAudio(item.id) }.buttonStyle(EngineButton())
                    Button("Remove audio") { var copy = item; copy.audioFile = nil; engine.update(copy); engine.restartAudio(item.id) }.buttonStyle(EngineButton(danger: true))
                    Text("Volume")
                    Slider(value: optionalBinding(engine, item.id, \.volume, 0.75), in: 0...1)
                    Toggle("Loop audio", isOn: optionalBinding(engine, item.id, \.audioLoop, false))
                    Text("Audio starts with the character. It does not restart on every APNG loop.").font(.caption).foregroundColor(.secondary)
                } else {
                    AnimationFields(engine: engine, id: item.id)
                    Button(engine.active(item.id) ? "Stop animation" : "Launch animation") { if engine.active(item.id) { engine.stop(item.id) } else { engine.launch(item.id) } }.buttonStyle(EngineButton())
                    Text("Quick actions").foregroundColor(.secondary)
                    Button("Edit animation live…") { engine.editorID = item.id }.buttonStyle(EngineButton())
                    Button("Animation controls") { engine.showControls(item.id) }.buttonStyle(EngineButton())
                    Button("Audio") { engine.panelMode = "audio" }.buttonStyle(EngineButton())
                    Button("Open file location") { NSWorkspace.shared.activateFileViewerSelecting([engine.root.appendingPathComponent(item.file)]) }.buttonStyle(EngineButton())
                    Button("Delete") { engine.deleteSelected() }.buttonStyle(EngineButton(danger: true))
                }
            }.padding(18)
        }.background(Theme.panel).cornerRadius(18).overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border))
    }
    func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) { Text(title).font(.headline); content() }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel).cornerRadius(14).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }
    var tools: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tools").font(.title.bold())
            card("Library and files") {
                Button("Add APNG / GIF…", action: engine.add).buttonStyle(EngineButton())
                Button("Open library folder") { NSWorkspace.shared.open(engine.root) }.buttonStyle(EngineButton())
                Button("Export animation settings") { engine.configuration(true) }.buttonStyle(EngineButton())
                Button("Import animation settings") { engine.configuration(false) }.buttonStyle(EngineButton())
                Text("Import restores settings for matching files in this library. Export does not include media.").foregroundColor(.secondary)
            }
            Spacer()
        }.padding(30)
    }
    var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title.bold())
            ScrollView {
                VStack(spacing: 14) {
                    card("Animation controls") {
                        Text("Right-click a character to open its controls. Command + right-click also works in click-through mode when macOS allows the app to observe mouse events.")
                        Button("Hide / show all animations", action: engine.toggleHidden).buttonStyle(EngineButton())
                        Button("Stop all animations", action: engine.stopAll).buttonStyle(EngineButton(danger: true))
                    }
                    card("Animation cache") {
                        Text("Prepared RGBA frames improve playback. Maximum longest edge: 768 px. Image cache target: 32 MB per file, excluding mapped data and displayed frames.")
                        Button("Clear animation cache", action: engine.clearCache).buttonStyle(EngineButton())
                        Text("Stops all characters. Frames will be prepared again the next time you open an animation.").foregroundColor(.secondary)
                    }
                    card("Settings backup and restore") {
                        HStack { Button("Export") { engine.configuration(true) }; Button("Import") { engine.configuration(false) } }.buttonStyle(EngineButton())
                    }
                    card("Launch at login") {
                        Text("Add the built app in System Settings → General → Login Items.")
                        Button("Open Login Items settings") { if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) } }.buttonStyle(EngineButton())
                    }
                    Text("Bred Animation Engine · 1.0.2 · macOS").foregroundColor(.secondary).padding()
                }.frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
        }.padding(26)
    }
}
func optionalBinding<T>(_ engine: Engine, _ id: UUID, _ key: WritableKeyPath<AnimationItem, T?>, _ fallback: T) -> Binding<T> {
    Binding(get: { engine.items.first(where: { $0.id == id })?[keyPath: key] ?? fallback }, set: { value in
        guard var item = engine.items.first(where: { $0.id == id }) else { return }
        item[keyPath: key] = value; engine.update(item)
    })
}
struct AnimationFields: View {
    @ObservedObject var engine: Engine
    let id: UUID
    var body: some View {
        if let item = engine.items.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Playback FPS", selection: Binding(get: { item.fps ?? 0 }, set: { value in var copy = item; copy.fps = value == 0 ? nil : value; engine.update(copy) })) {
                    Text("Original").tag(0)
                    ForEach([15, 24, 30, 60, 120], id: \.self) { Text("\($0)").tag($0) }
                }
                Text("Size: \(Int(item.scale * 100))%")
                Slider(value: Binding(get: { item.scale }, set: { value in var copy = item; copy.scale = value; engine.update(copy) }), in: 0.05...2)
                Text("Rotation: \(Int(item.rotation ?? 0))°")
                Slider(value: optionalBinding(engine, id, \.rotation, 0), in: -180...180)
                Toggle("Flip horizontally", isOn: optionalBinding(engine, id, \.flipX, false))
                Toggle("Flip vertically", isOn: optionalBinding(engine, id, \.flipY, false))
            }
        }
    }
}
struct ControlsView: View {
    @ObservedObject var engine: Engine
    let id: UUID
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let item = engine.items.first(where: { $0.id == id }) {
                    Text("Animation controls").font(.title2.bold())
                    Text("Opacity: \(Int((item.opacity ?? 1) * 100))%")
                    Slider(value: optionalBinding(engine, id, \.opacity, 1), in: 0.05...1)
                    Toggle("Always on top", isOn: Binding(get: { item.topmost }, set: { value in var copy = item; copy.topmost = value; engine.update(copy) }))
                    Toggle("Lock position", isOn: optionalBinding(engine, id, \.locked, false))
                    Toggle("Click through", isOn: Binding(get: { item.clickThrough }, set: { value in var copy = item; copy.clickThrough = value; engine.update(copy) }))
                    Toggle("Hide under cursor", isOn: optionalBinding(engine, id, \.hideOnHover, false))
                    Divider()
                    AnimationFields(engine: engine, id: id)
                    Text("In click-through mode: Command + right-click, or Controls in the library.").font(.caption).foregroundColor(.secondary)
                    Button("Reset controls") {
                        var copy = item; copy.opacity = 1; copy.topmost = true; copy.clickThrough = false; copy.locked = false; copy.hideOnHover = false; engine.update(copy)
                    }.buttonStyle(EngineButton(primary: true))
                    Button("Close animation") { engine.stop(id); engine.controlPanel?.close() }.buttonStyle(EngineButton(danger: true))
                }
            }.padding(20)
        }.background(Theme.panel).preferredColorScheme(.dark)
    }
}

struct EngineMenu: View {
    @ObservedObject var engine: Engine
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Add APNG…") { NSApp.activate(ignoringOtherApps: true); engine.add() }
        Button("Show library") {
            openWindow(id: "library")
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
        Divider()
        Button("Hide / show animations", action: engine.toggleHidden)
        Button("Stop all animations", action: engine.stopAll)
        Button("Quit") { NSApp.terminate(nil) }
    }
}

@main
struct BredAnimationApp: App {
    @StateObject private var engine = Engine()
    var body: some Scene {
        Window("Bred Animation Engine", id: "library") {
            LibraryView(engine: engine).onAppear { engine.startMonitoring() }
        }.defaultSize(width: 1200, height: 790)
        MenuBarExtra("Bred Animation Engine", systemImage: "sparkles") {
            EngineMenu(engine: engine)
        }
    }
}
