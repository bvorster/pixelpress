import Foundation
import UniformTypeIdentifiers

struct FoundFile {
    let url: URL
    /// Folder path relative to where a dropped folder sat, including that folder's name. `nil` for loose files.
    let relativeDir: String?
}

enum FileScanner {
    static func looksLikeImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// Expands folders recursively, keeping only files that look like images.
    static func collect(_ urls: [URL]) -> [FoundFile] {
        var found: [FoundFile] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if looksLikeImage(url) { found.append(FoundFile(url: url, relativeDir: nil)) }
                continue
            }
            let base = url.deletingLastPathComponent().standardizedFileURL.path
            guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in walker where looksLikeImage(file) {
                let parent = file.deletingLastPathComponent().standardizedFileURL.path
                var relative = parent.hasPrefix(base) ? String(parent.dropFirst(base.count)) : url.lastPathComponent
                while relative.hasPrefix("/") { relative.removeFirst() }
                found.append(FoundFile(url: file, relativeDir: relative))
            }
        }
        return found
    }

    /// Picks output paths for a batch, never overwriting an existing file or another file in the batch.
    static func outputURLs(for inputs: [FoundFile], format: OutputFormat, destination: URL?, preserveStructure: Bool) -> [URL] {
        var reserved = Set<String>()
        let fm = FileManager.default
        return inputs.map { input in
            var dir = destination ?? input.url.deletingLastPathComponent()
            if destination != nil, preserveStructure, let rel = input.relativeDir, !rel.isEmpty {
                dir = dir.appendingPathComponent(rel, isDirectory: true)
            }
            let base = input.url.deletingPathExtension().lastPathComponent
            var candidate = dir.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
            var n = 2
            while reserved.contains(candidate.path) || fm.fileExists(atPath: candidate.path) {
                candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(format.fileExtension)
                n += 1
            }
            reserved.insert(candidate.path)
            return candidate
        }
    }

    static func ensureParent(of url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
