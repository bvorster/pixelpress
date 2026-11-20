import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Group {
                    if state.items.isEmpty { EmptyDropView() } else { grid }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar()
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                state.handleDrop(providers)
                return true
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(8)
                        .allowsHitTesting(false)
                }
            }
            Divider()
            SettingsPanel().frame(width: 300)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { state.openPanel() } label: { Label("Add Images", systemImage: "plus") }
                    .help("Add images or folders (⌘O)")
                Button { state.clear() } label: { Label("Clear", systemImage: "trash") }
                    .help("Remove everything from the list")
                    .disabled(state.items.isEmpty || state.isConverting)
                Button { state.convertAll() } label: {
                    if state.isConverting {
                        ProgressView().controlSize(.small).padding(.horizontal, 18)
                    } else {
                        Text("Convert").padding(.horizontal, 6)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.items.isEmpty || state.isConverting)
                .help("Convert all images (⌘↩)")
            }
        }
        .sheet(item: $state.compareItem) { item in CompareView(item: item).environmentObject(state) }
        .frame(minWidth: 880, minHeight: 560)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 14)], spacing: 14) {
                ForEach(state.items) { item in TileView(item: item) }
            }
            .padding(16)
        }
    }
}

struct EmptyDropView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack").font(.system(size: 54, weight: .light)).foregroundStyle(.secondary)
            Text("Drop images or folders here").font(.title2.weight(.medium))
            Text("Or press ⌘O to choose them, or ⌘V to paste.").foregroundStyle(.secondary)
            if state.isScanning { ProgressView().controlSize(.small) }
            Button("Choose Images…") { state.openPanel() }.controlSize(.large)
        }
        .padding(40)
    }
}

struct StatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Text(summary).foregroundStyle(.secondary)
            if state.isScanning { ProgressView().controlSize(.mini) }
            Spacer()
            if state.isConverting {
                ProgressView(value: Double(state.finishedCount), total: Double(max(1, state.items.count))).frame(width: 140)
            }
            if state.finishedCount > 0 && !state.isConverting {
                Button("Remove Finished") { state.removeFinished() }.buttonStyle(.link)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private var summary: String {
        let items = state.items
        guard !items.isEmpty else { return "No images" }
        let count = items.count == 1 ? "1 image" : "\(items.count) images"
        let done = items.compactMap { item -> (Int64, Int64)? in
            if case .done(_, let size) = item.status { return (item.fileSize, size) }
            return nil
        }
        let original = items.reduce(Int64(0)) { $0 + $1.fileSize }
        guard !done.isEmpty else { return "\(count) · \(original.byteString)" }
        let a = done.reduce(Int64(0)) { $0 + $1.0 }, b = done.reduce(Int64(0)) { $0 + $1.1 }
        return "\(count) · \(done.count) converted · \(a.byteString) → \(b.byteString) (\(savingsText(from: a, to: b)))"
    }
}

// MARK: - Tiles

struct TileView: View {
    let item: ImageItem
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ThumbnailView(url: item.url)
                .frame(height: 124)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topTrailing) { badge.padding(6) }
                .overlay(alignment: .bottomLeading) {
                    if item.frameCount > 1 {
                        Text("\(item.frameCount) frames").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule()).padding(6)
                    }
                }
            Text(item.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Text(dimensions).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            sizeLine.font(.caption).lineLimit(2)
        }
        .monospacedDigit()
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { state.compareItem = item }
        .contextMenu {
            Button("Compare Before & After…") { state.compareItem = item }
            Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            if let out = item.outputURL {
                Button("Show Converted in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }
            }
            Divider()
            Button("Remove from List") { state.remove(item) }.disabled(item.status == .working)
        }
        .help("Double-click to compare before and after")
    }

    @ViewBuilder private var badge: some View {
        switch item.status {
        case .pending: EmptyView()
        case .working: ProgressView().controlSize(.small).padding(4).background(.regularMaterial, in: Circle())
        case .done: Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, .green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.white, .orange)
        }
    }

    private var dimensions: String {
        let s = item.pixelSize
        let settings = state.prefs.settings
        let from = "\(Int(s.width))×\(Int(s.height))"
        if settings.format.isIcon {
            let sizes = Converter.iconSizes(for: settings.format, longEdge: Int(max(s.width, s.height)))
            return "\(from) → icon up to \(sizes.last ?? 16)px"
        }
        let t = Converter.targetSize(for: s, settings: settings)
        return t == s ? from : "\(from) → \(Int(t.width))×\(Int(t.height))"
    }

    @ViewBuilder private var sizeLine: some View {
        switch item.status {
        case .done(_, let size):
            HStack(spacing: 4) {
                Text("\(item.fileSize.byteString) → \(size.byteString)")
                Text(savingsText(from: item.fileSize, to: size))
                    .foregroundStyle(size <= item.fileSize ? Color.green : Color.orange).fontWeight(.semibold)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.orange)
        default:
            Text(item.fileSize.byteString).foregroundStyle(.secondary)
        }
    }
}

struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            let url = url
            image = await Task.detached(priority: .utility) { Self.thumbnail(url) }.value
        }
    }

    nonisolated static func thumbnail(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    @EnvironmentObject var state: AppState
    private let presets = [256, 512, 1024, 1280, 1600, 1920, 2048, 2560, 3840]

    var body: some View {
        let settings = state.prefs.settings
        Form {
            Section("Output") {
                Picker("Format", selection: $state.prefs.settings.format) {
                    ForEach(OutputFormat.available) { Text($0.label).tag($0) }
                }
                if settings.format.supportsQuality {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Quality")
                            Spacer()
                            Text("\(Int((settings.quality * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $state.prefs.settings.quality, in: 0.05...1)
                    }
                }
                if settings.format == .webp && !Converter.webpEncoderAvailable {
                    Label("WebP needs cwebp: brew install webp", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if settings.format.supportsAnimation {
                    Text("Animated images keep every frame.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Size") {
                Picker("Resize", selection: $state.prefs.settings.resizeMode) {
                    ForEach(ResizeMode.allCases) { Text($0.label).tag($0) }
                }
                if settings.resizeMode != .original || settings.format.isIcon {
                    HStack {
                        TextField(settings.format.isIcon && settings.resizeMode == .original ? "Pixels" : "Pixels",
                                  value: $state.prefs.settings.resizeValue, format: .number)
                            .multilineTextAlignment(.trailing)
                        Text("px").foregroundStyle(.secondary)
                        Menu {
                            ForEach(presets, id: \.self) { p in Button("\(p) px") { state.prefs.settings.resizeValue = p } }
                        } label: { Image(systemName: "list.bullet") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }
                    .disabled(settings.resizeMode == .original)
                    Toggle("Allow upscaling", isOn: $state.prefs.settings.allowUpscale)
                        .disabled(settings.resizeMode == .original)
                }
                if settings.format.isIcon {
                    Text("Icons get every standard size up to the largest that fits, padded to a square.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.format == .pvr {
                    Text("PVRTC textures must be square with a power-of-two edge, so the image is fitted onto one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Metadata") {
                Picker("EXIF & location", selection: $state.prefs.settings.keepMetadata) {
                    Text("Keep").tag(true)
                    Text("Remove").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(!settings.format.supportsMetadata)
                Text(settings.format.supportsMetadata
                     ? "Remove strips camera, date and GPS data. Colour profiles are always kept."
                     : "\(settings.format.label) files don't carry EXIF data.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Destination") {
                Picker("Save to", selection: $state.prefs.saveNextToSource) {
                    Text("Folder").tag(false)
                    Text("Next to originals").tag(true)
                }
                if !state.prefs.saveNextToSource {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        Text(URL(fileURLWithPath: state.prefs.destinationPath).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .help(state.prefs.destinationPath)
                        Spacer()
                        Button("Choose…") { state.chooseDestination() }
                    }
                    .onDrop(of: [.fileURL], isTargeted: nil) { state.setDestination(from: $0) }
                    .help("Drop a folder here to save into it")
                    Toggle("Keep folder structure", isOn: $state.prefs.preserveStructure)
                }
                Toggle("Show in Finder when done", isOn: $state.prefs.revealWhenDone)
                Toggle("Play sound when done", isOn: $state.prefs.playSound)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Compare

struct CompareView: View {
    let item: ImageItem
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var original: NSImage?
    @State private var converted: NSImage?
    @State private var convertedSize: Int64?
    @State private var convertedPixels: CGSize?
    @State private var message: String?
    @State private var split: CGFloat = 0.5
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            header.padding(14)
            Divider()
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    comparison
                        .frame(width: geo.size.width * zoom, height: geo.size.height * zoom)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 1...8).frame(width: 200)
                Image(systemName: "plus.magnifyingglass")
                Text(String(format: "%.0f×", zoom)).monospacedDigit().frame(width: 30, alignment: .leading)
                Spacer()
                Text("Drag across the image to move the divider.").foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 920, idealWidth: 1100, minHeight: 640, idealHeight: 780)
        .task {
            let url = item.url
            original = await Task.detached { NSImage(contentsOf: url) }.value
        }
        .task(id: state.prefs.settings) { await renderPreview(state.prefs.settings) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(item.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Before").font(.caption).foregroundStyle(.secondary)
                Text("\(item.fileSize.byteString) · \(Int(item.pixelSize.width))×\(Int(item.pixelSize.height))")
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("After · \(state.prefs.settings.format.label)").font(.caption).foregroundStyle(.secondary)
                if let size = convertedSize, let px = convertedPixels {
                    HStack(spacing: 4) {
                        Text("\(size.byteString) · \(Int(px.width))×\(Int(px.height))")
                        Text(savingsText(from: item.fileSize, to: size)).fontWeight(.semibold)
                            .foregroundStyle(size <= item.fileSize ? Color.green : Color.orange)
                    }
                } else {
                    Text(message ?? "Rendering…").foregroundStyle(message == nil ? Color.secondary : Color.orange)
                }
            }
        }
        .monospacedDigit()
    }

    private var comparison: some View {
        GeometryReader { geo in
            ZStack {
                if let converted {
                    Image(nsImage: converted).resizable().interpolation(.none).scaledToFit()
                }
                if let original {
                    Image(nsImage: original).resizable().interpolation(.none).scaledToFit()
                        .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * split) }
                }
                Rectangle().fill(.white).frame(width: 2).shadow(radius: 2)
                    .position(x: geo.size.width * split, y: geo.size.height / 2)
                    .frame(height: geo.size.height)
                VStack {
                    HStack {
                        tag("Before"); Spacer(); tag("After")
                    }
                    Spacer()
                }
                .padding(10)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                split = min(1, max(0, value.location.x / max(1, geo.size.width)))
            })
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
    }

    private func renderPreview(_ settings: ConversionSettings) async {
        try? await Task.sleep(nanoseconds: 250_000_000)   // let slider drags settle
        guard !Task.isCancelled else { return }
        let input = item.url
        let result: Result<(NSImage?, Int64, CGSize?), Error> = await Task.detached(priority: .userInitiated) {
            do {
                let url = try Converter.preview(input, settings: settings)
                defer { try? FileManager.default.removeItem(at: url) }
                let size = FileScanner.size(of: url)
                let px = Converter.info(for: url)?.pixelSize
                return .success((NSImage(contentsOf: url), size, px))
            } catch {
                return .failure(error)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let (image, size, px)):
            converted = image
            convertedSize = size
            convertedPixels = px ?? Converter.targetSize(for: item.pixelSize, settings: settings)
            message = image == nil ? "macOS can't display this format, so there's no preview" : nil
        case .failure(let error):
            converted = nil
            convertedSize = nil
            message = error.localizedDescription
        }
    }
}
