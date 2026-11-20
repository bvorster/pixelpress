import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageItem: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case working
        case done(URL, Int64)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    let relativeDir: String?
    let pixelSize: CGSize
    let frameCount: Int
    let fileSize: Int64
    var status: Status = .pending

    var isDone: Bool { if case .done = status { true } else { false } }
    var outputURL: URL? { if case .done(let url, _) = status { url } else { nil } }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var items: [ImageItem] = []
    @Published var prefs = Preferences.load() { didSet { if prefs != oldValue { prefs.save() } } }
    @Published var isConverting = false
    @Published var isScanning = false
    @Published var compareItem: ImageItem?

    var finishedCount: Int { items.filter(\.isDone).count }

    // MARK: - Adding

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isScanning = true
        Task.detached(priority: .userInitiated) {
            let found = FileScanner.collect(urls)
            let new: [ImageItem] = found.compactMap { file in
                guard let info = Converter.info(for: file.url) else { return nil }
                return ImageItem(url: file.url, relativeDir: file.relativeDir, pixelSize: info.pixelSize,
                                 frameCount: info.frameCount, fileSize: FileScanner.size(of: file.url))
            }
            await MainActor.run {
                let existing = Set(self.items.map { $0.url.standardizedFileURL.path })
                self.items += new.filter { !existing.contains($0.url.standardizedFileURL.path) }
                self.isScanning = false
            }
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in self?.add(urls) }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .folder]
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func paste() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls)
            return
        }
        guard let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Pixelpress-pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = "Pasted Image \(formatter.string(from: Date()))"
        var url = dir.appendingPathComponent(stem).appendingPathExtension("png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {   // two pastes in the same second
            url = dir.appendingPathComponent("\(stem) \(n)").appendingPathExtension("png"); n += 1
        }
        if (try? png.write(to: url, options: .withoutOverwriting)) != nil { add([url]) }
    }

    func remove(_ item: ImageItem) { items.removeAll { $0.id == item.id } }
    func removeFinished() { items.removeAll(where: \.isDone) }
    func clear() { if !isConverting { items.removeAll() } }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: prefs.destinationPath)
        if panel.runModal() == .OK, let url = panel.url { prefs.destinationPath = url.path }
    }

    func setDestination(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
            Task { @MainActor in
                self.prefs.destinationPath = url.path
                self.prefs.saveNextToSource = false
            }
        }
        return true
    }

    // MARK: - Converting

    struct Job: Sendable {
        let id: UUID
        let input: URL
        let output: URL
    }

    func convertAll() {
        guard !isConverting, !items.isEmpty else { return }
        var targets = items.filter { !$0.isDone }
        if targets.isEmpty { targets = items }   // everything already done: run again with the new settings

        let settings = prefs.settings
        let destination = prefs.saveNextToSource ? nil : URL(fileURLWithPath: prefs.destinationPath, isDirectory: true)
        let outputs = FileScanner.outputURLs(for: targets.map { FoundFile(url: $0.url, relativeDir: $0.relativeDir) },
                                             format: settings.format, destination: destination,
                                             preserveStructure: prefs.preserveStructure)
        let jobs = zip(targets, outputs).map { Job(id: $0.id, input: $0.url, output: $1) }
        for job in jobs { setStatus(job.id, .pending) }
        isConverting = true

        Task {
            let width = max(1, ProcessInfo.processInfo.activeProcessorCount)
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                for _ in 0..<min(width, jobs.count) {
                    let job = jobs[next]; next += 1
                    group.addTask { await Self.process(job, settings: settings, state: self) }
                }
                while await group.next() != nil {
                    if next < jobs.count {
                        let job = jobs[next]; next += 1
                        group.addTask { await Self.process(job, settings: settings, state: self) }
                    }
                }
            }
            finish(jobs)
        }
    }

    nonisolated private static func process(_ job: Job, settings: ConversionSettings, state: AppState) async {
        await state.setStatus(job.id, .working)
        let status: ImageItem.Status
        do {
            try FileScanner.ensureParent(of: job.output)
            try Converter.convert(job.input, to: job.output, settings: settings)
            status = .done(job.output, FileScanner.size(of: job.output))
        } catch {
            status = .failed(error.localizedDescription)
        }
        await state.setStatus(job.id, status)
    }

    private func setStatus(_ id: UUID, _ status: ImageItem.Status) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = status }
    }

    private func finish(_ jobs: [Job]) {
        isConverting = false
        let ids = Set(jobs.map(\.id))
        let done = items.filter { ids.contains($0.id) }.compactMap(\.outputURL)
        if prefs.playSound { NSSound(named: done.isEmpty ? "Basso" : "Glass")?.play() }
        if prefs.revealWhenDone, !done.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(done) }
    }
}
