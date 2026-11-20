import Foundation
import UniformTypeIdentifiers

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case jpeg, png, heic, avif, webp, tiff, gif, pdf, jp2, heics, exr, psd, bmp, tga, pbm, ico, icns, dds, ktx, astc, pvr

    var id: String { rawValue }

    var label: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .webp: "WebP"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .pdf: "PDF"
        case .jp2: "JPEG 2000"
        case .heics: "HEIF Sequence"
        case .exr: "OpenEXR"
        case .psd: "Photoshop (PSD)"
        case .bmp: "BMP"
        case .tga: "TGA"
        case .pbm: "PBM"
        case .ico: "ICO (Windows icon)"
        case .icns: "ICNS (Mac icon)"
        case .dds: "DDS texture"
        case .ktx: "KTX texture"
        case .astc: "ASTC texture"
        case .pvr: "PVRTC texture"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    /// ImageIO type identifier. `nil` means ImageIO cannot write it (WebP) and an encoder is used.
    var imageIOType: String? {
        switch self {
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .heic: "public.heic"
        case .avif: "public.avif"
        case .webp: nil
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        case .pdf: "com.adobe.pdf"
        case .jp2: "public.jpeg-2000"
        case .heics: "public.heics"
        case .exr: "com.ilm.openexr-image"
        case .psd: "com.adobe.photoshop-image"
        case .bmp: "com.microsoft.bmp"
        case .tga: "com.truevision.tga-image"
        case .pbm: "public.pbm"
        case .ico: "com.microsoft.ico"
        case .icns: "com.apple.icns"
        case .dds: "com.microsoft.dds"
        case .ktx: "org.khronos.ktx"
        case .astc: "org.khronos.astc"
        case .pvr: "public.pvr"
        }
    }

    var supportsQuality: Bool { [.jpeg, .heic, .avif, .webp, .jp2, .heics].contains(self) }
    var supportsMetadata: Bool { [.jpeg, .png, .heic, .avif, .webp, .tiff, .heics, .jp2].contains(self) }
    var supportsAlpha: Bool { ![.jpeg, .pbm].contains(self) }
    var supportsAnimation: Bool { [.gif, .png, .heics].contains(self) }
    var isIcon: Bool { self == .ico || self == .icns }
}

enum ResizeMode: String, CaseIterable, Identifiable, Codable {
    case original, maxWidth, maxHeight, maxLongEdge, maxShortEdge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: "Original size"
        case .maxWidth: "Max width"
        case .maxHeight: "Max height"
        case .maxLongEdge: "Max long edge"
        case .maxShortEdge: "Max short edge"
        }
    }
}

struct ConversionSettings: Codable, Equatable, Hashable {
    var format: OutputFormat = .jpeg
    var quality: Double = 0.8
    var resizeMode: ResizeMode = .original
    var resizeValue: Int = 2048
    var allowUpscale: Bool = false
    var keepMetadata: Bool = false
}

/// Everything the window remembers between launches.
struct Preferences: Codable, Equatable {
    var settings = ConversionSettings()
    var saveNextToSource = false
    var destinationPath: String = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    var preserveStructure = true
    var revealWhenDone = false
    var playSound = true

    private static let key = "Pixelpress.preferences"

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

func savingsText(from original: Int64, to converted: Int64) -> String {
    guard original > 0 else { return "" }
    let change = (Double(converted) - Double(original)) / Double(original) * 100
    return change <= 0 ? String(format: "−%.0f%%", -change) : String(format: "+%.0f%%", change)
}
