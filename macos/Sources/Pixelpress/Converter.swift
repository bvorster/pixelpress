import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ConvertError: LocalizedError {
    case unreadable
    case noImage
    case destination(String)
    case writeFailed(String)
    case webpEncoderMissing
    case encoderFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file isn't an image macOS can read."
        case .noImage: "The file has no image in it that could be decoded."
        case .destination(let format): "macOS couldn't create a \(format) file."
        case .writeFailed(let format): "Writing the \(format) file failed."
        case .webpEncoderMissing: "WebP needs the cwebp encoder. Install it with: brew install webp"
        case .encoderFailed(let message): "The WebP encoder failed: \(message)"
        }
    }
}

struct ImageInfo {
    let pixelSize: CGSize   // after EXIF orientation is applied
    let frameCount: Int
}

enum Converter {
    // MARK: - Inspecting

    static func info(for url: URL) -> ImageInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(src) != nil
        else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let size = (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        return ImageInfo(pixelSize: size, frameCount: count)
    }

    static func targetSize(for size: CGSize, settings: ConversionSettings) -> CGSize {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return size }
        let v = CGFloat(max(1, settings.resizeValue))
        var scale: CGFloat
        switch settings.resizeMode {
        case .original: scale = 1
        case .maxWidth: scale = v / w
        case .maxHeight: scale = v / h
        case .maxLongEdge: scale = v / max(w, h)
        case .maxShortEdge: scale = v / min(w, h)
        }
        if !settings.allowUpscale { scale = min(scale, 1) }
        return CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
    }

    static func iconSizes(for format: OutputFormat, longEdge: Int) -> [Int] {
        // ImageIO's ICO writer takes at most a few images, so ICO uses the standard Windows set.
        let all = format == .icns ? [16, 32, 64, 128, 256, 512, 1024] : [16, 32, 48, 256]
        let fit = all.filter { $0 <= longEdge }
        return fit.isEmpty ? [all[0]] : fit
    }

    // MARK: - Converting

    static func convert(_ input: URL, to output: URL, settings: ConversionSettings) throws {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw ConvertError.unreadable }
        guard let info = info(for: input) else { throw ConvertError.noImage }
        let format = settings.format
        let target = targetSize(for: info.pixelSize, settings: settings)

        let indices: [Int] = (format.supportsAnimation && info.frameCount > 1)
            ? Array(0..<info.frameCount)
            : [CGImageSourceGetPrimaryImageIndex(src)]

        var frames: [(CGImage, [CFString: Any])] = []
        for index in indices {
            guard var image = decode(src, index: index, target: target) else { throw ConvertError.noImage }
            if !format.supportsAlpha, hasAlpha(image), let flat = redraw(image, size: target, background: .white) {
                image = flat
            }
            frames.append((image, frameProperties(src, index: index, settings: settings)))
        }

        if format.isIcon, let base = frames.first?.0 {
            let sizes = iconSizes(for: format, longEdge: Int(max(target.width, target.height)))
            frames = sizes.compactMap { size in squareIcon(base, size: size).map { ($0, [:]) } }
        } else if format == .pvr, let base = frames.first?.0 {
            // PVRTC only stores square, power-of-two textures: fit the image onto one.
            let edge = max(8, Int(max(target.width, target.height)))
            var pot = 8
            while pot * 2 <= edge { pot *= 2 }
            frames = squareIcon(base, size: pot).map { [($0, [:])] } ?? frames
        }

        do {
            if format == .webp {
                guard let first = frames.first else { throw ConvertError.noImage }
                try writeWebP(first.0, properties: first.1, to: output, settings: settings)
            } else {
                try write(frames, to: output, format: format, settings: settings)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Converts to a temporary file, for previews.
    static func preview(_ input: URL, settings: ConversionSettings) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Pixelpress-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(settings.format.fileExtension)
        try convert(input, to: url, settings: settings)
        return url
    }

    // MARK: - Decoding

    private static func decode(_ src: CGImageSource, index: Int, target: CGSize) -> CGImage? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0

        // Untouched size and orientation: decode at full fidelity (keeps 16-bit and wide colour).
        if orientation == 1, CGFloat(w) == target.width, CGFloat(h) == target.height,
           let full = CGImageSourceCreateImageAtIndex(src, index, nil) {
            return full
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(target.width, target.height)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, index, options as CFDictionary) else { return nil }
        if abs(CGFloat(image.width) - target.width) > 1 || abs(CGFloat(image.height) - target.height) > 1 {
            return redraw(image, size: target) ?? image   // upscaling, or a rounding difference
        }
        return image
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    private static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

    private static func makeContext(width: Int, height: Int, preferred: CGColorSpace?) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        if let cs = preferred, cs.model == .rgb,
           let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) {
            return ctx
        }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: info)
    }

    private static func redraw(_ image: CGImage, size: CGSize, background: CGColor? = nil) -> CGImage? {
        guard let ctx = makeContext(width: Int(size.width), height: Int(size.height), preferred: image.colorSpace) else { return nil }
        ctx.interpolationQuality = .high
        let rect = CGRect(origin: .zero, size: size)
        if let background {
            ctx.setFillColor(background)
            ctx.fill(rect)
        }
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    private static func squareIcon(_ image: CGImage, size: Int) -> CGImage? {
        guard let ctx = makeContext(width: size, height: size, preferred: sRGB) else { return nil }
        ctx.interpolationQuality = .high
        let s = CGFloat(size)
        let scale = min(s / CGFloat(image.width), s / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Properties

    private static func frameDelay(_ props: [CFString: Any]) -> Double? {
        let pairs: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictKey, unclamped, clamped) in pairs {
            if let dict = props[dictKey] as? [CFString: Any] {
                if let d = dict[unclamped] as? Double, d > 0 { return d }
                if let d = dict[clamped] as? Double, d > 0 { return d }
            }
        }
        return nil
    }

    private static func frameProperties(_ src: CGImageSource, index: Int, settings: ConversionSettings) -> [CFString: Any] {
        let format = settings.format
        let source = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        var out: [CFString: Any] = [:]

        if settings.keepMetadata && format.supportsMetadata {
            let keys = [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerAppleDictionary,
                        kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight]
            for key in keys { if let value = source[key] { out[key] = value } }
            // Pixels are already rotated upright, so the stored orientation must say so.
            out[kCGImagePropertyOrientation] = 1
            if var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                out[kCGImagePropertyTIFFDictionary] = tiff
            }
        }

        if format.supportsAnimation, let delay = frameDelay(source) {
            switch format {
            case .gif: out[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delay]
            case .png: out[kCGImagePropertyPNGDictionary] = [kCGImagePropertyAPNGDelayTime: delay]
            case .heics: out[kCGImagePropertyHEICSDictionary] = [kCGImagePropertyHEICSDelayTime: delay]
            default: break
            }
        }

        if format.supportsQuality { out[kCGImageDestinationLossyCompressionQuality] = settings.quality }
        return out
    }

    // MARK: - Writing

    private static func write(_ frames: [(CGImage, [CFString: Any])], to output: URL, format: OutputFormat, settings: ConversionSettings) throws {
        guard let type = format.imageIOType,
              let dest = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, frames.count, nil)
        else { throw ConvertError.destination(format.label) }

        var fileProps: [CFString: Any] = [:]
        if frames.count > 1 {
            switch format {
            case .gif: fileProps[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFLoopCount: 0]
            case .png: fileProps[kCGImagePropertyPNGDictionary] = [kCGImagePropertyAPNGLoopCount: 0]
            case .heics: fileProps[kCGImagePropertyHEICSDictionary] = [kCGImagePropertyHEICSLoopCount: 0]
            default: break
            }
        }
        if format.supportsQuality { fileProps[kCGImageDestinationLossyCompressionQuality] = settings.quality }
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        for (image, props) in frames { CGImageDestinationAddImage(dest, image, props as CFDictionary) }
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.writeFailed(format.label) }
    }

    private static func writeWebP(_ image: CGImage, properties: [CFString: Any], to output: URL, settings: ConversionSettings) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temp) }

        var pngProps = properties
        pngProps.removeValue(forKey: kCGImageDestinationLossyCompressionQuality)
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, "public.png" as CFString, 1, nil) else {
            throw ConvertError.destination("PNG")
        }
        CGImageDestinationAddImage(dest, image, pngProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.writeFailed("PNG") }

        let quality = Int((settings.quality * 100).rounded())
        if let cwebp = findTool("cwebp") {
            try run(cwebp, ["-quiet", "-q", "\(quality)", "-alpha_q", "100",
                            "-metadata", settings.keepMetadata ? "all" : "icc",
                            temp.path, "-o", output.path])
        } else if let ffmpeg = findTool("ffmpeg") {
            try run(ffmpeg, ["-nostdin", "-y", "-loglevel", "error", "-i", temp.path,
                             "-c:v", "libwebp", "-quality", "\(quality)",
                             "-map_metadata", settings.keepMetadata ? "0" : "-1", output.path])
        } else {
            throw ConvertError.webpEncoderMissing
        }
    }

    static var webpEncoderAvailable: Bool { findTool("cwebp") != nil || findTool("ffmpeg") != nil }

    static func findTool(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)") { candidates.append(bundled) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        // Only absolute PATH entries: a "." or relative entry would run whatever "cwebp" sits in the current folder.
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
            + path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        candidates += dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ConvertError.encoderFailed(message.isEmpty ? "exit code \(process.terminationStatus)" : message)
        }
    }
}
