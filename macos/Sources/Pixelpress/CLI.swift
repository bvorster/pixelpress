import Foundation

enum CLI {
    static let usage = """
    Usage: Pixelpress convert [options] <files or folders…>

      -f, --format <name>       Output format (default jpeg). See --list-formats.
      -q, --quality <0-100>     Quality for lossy formats (default 80).
      --resize <mode>           original | width | height | long | short (default original)
      --size <pixels>           Target pixels for --resize (default 2048)
      --upscale                 Allow making images larger
      --keep-metadata           Keep EXIF, GPS and IPTC (default: remove)
      -o, --output <folder>     Destination folder (default: next to each original)
      --flat                    Don't recreate dropped folders' structure under --output
      --list-formats            Print output formats and exit
    """

    static func run(_ args: [String]) -> Int32 {
        var settings = ConversionSettings()
        var output: URL?
        var preserve = true
        var inputs: [URL] = []
        var i = 0

        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help":
                print(usage); return 0
            case "--list-formats":
                for f in OutputFormat.allCases { print("\(f.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(f.label)") }
                return 0
            case "-f", "--format":
                guard let v = value(), let f = OutputFormat(rawValue: v.lowercased() == "jpg" ? "jpeg" : v.lowercased()) else {
                    fail("unknown format; try --list-formats"); return 2
                }
                settings.format = f
            case "-q", "--quality":
                guard let v = value(), let q = Double(v), (0...100).contains(q) else { fail("quality must be 0-100"); return 2 }
                settings.quality = q / 100
            case "--resize":
                let modes: [String: ResizeMode] = ["original": .original, "width": .maxWidth, "height": .maxHeight,
                                                   "long": .maxLongEdge, "short": .maxShortEdge]
                guard let v = value(), let m = modes[v] else { fail("resize must be original|width|height|long|short"); return 2 }
                settings.resizeMode = m
            case "--size":
                guard let v = value(), let s = Int(v), s > 0 else { fail("size must be a positive number"); return 2 }
                settings.resizeValue = s
            case "--upscale": settings.allowUpscale = true
            case "--keep-metadata": settings.keepMetadata = true
            case "--flat": preserve = false
            case "-o", "--output":
                guard let v = value() else { fail("missing folder after --output"); return 2 }
                output = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
            default:
                if arg.hasPrefix("-") { fail("unknown option \(arg)"); return 2 }
                inputs.append(URL(fileURLWithPath: (arg as NSString).expandingTildeInPath))
            }
            i += 1
        }

        let files = FileScanner.collect(inputs)
        guard !files.isEmpty else { fail("no images found\n\n\(usage)"); return 2 }
        let outputs = FileScanner.outputURLs(for: files, format: settings.format, destination: output, preserveStructure: preserve)

        let lock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: files.count) { n in
            let input = files[n].url, out = outputs[n]
            let line: String
            do {
                try FileScanner.ensureParent(of: out)
                try Converter.convert(input, to: out, settings: settings)
                let a = FileScanner.size(of: input), b = FileScanner.size(of: out)
                line = "ok    \(input.lastPathComponent) → \(out.path)  \(a.byteString) → \(b.byteString) (\(savingsText(from: a, to: b)))"
            } catch {
                lock.lock(); failures += 1; lock.unlock()
                line = "FAIL  \(input.lastPathComponent): \(error.localizedDescription)"
            }
            lock.lock(); print(line); lock.unlock()
        }
        print("\(files.count - failures) converted, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("Pixelpress: \(message)\n".utf8))
    }
}
