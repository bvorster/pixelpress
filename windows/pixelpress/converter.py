"""Image conversion engine for the Windows (and Linux) build of Pixelpress.

Uses Pillow for most formats, pi-heif to read HEIC/HEIF and rawpy (LibRaw) to read camera RAW files.
"""
from __future__ import annotations

import os
import tempfile
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path

from PIL import Image, ImageOps, ImageSequence

try:
    import pi_heif

    pi_heif.register_heif_opener()
except Exception:  # pragma: no cover - optional
    pi_heif = None

try:
    import rawpy
except Exception:  # pragma: no cover - optional
    rawpy = None

# Large photos and scans are normal input, so the cap sits far above any camera (about 22,000 × 22,000),
# but a crafted "decompression bomb" file still can't make Pixelpress allocate unlimited memory.
Image.MAX_IMAGE_PIXELS = 500_000_000

RAW_EXTENSIONS = {
    ".3fr", ".arw", ".cr2", ".cr3", ".crw", ".dcr", ".dng", ".erf", ".fff", ".iiq", ".mos", ".mrw",
    ".nef", ".nrw", ".orf", ".pef", ".raf", ".raw", ".rw2", ".rwl", ".sr2", ".srf", ".srw", ".x3f",
}
IMAGE_EXTENSIONS = RAW_EXTENSIONS | {
    ".jpg", ".jpeg", ".jpe", ".jfif", ".png", ".apng", ".gif", ".webp", ".avif", ".heic", ".heif", ".hif",
    ".tif", ".tiff", ".bmp", ".dib", ".ico", ".icns", ".tga", ".pbm", ".pgm", ".ppm", ".pnm", ".psd",
    ".jp2", ".j2k", ".jpf", ".jpx", ".dds", ".qoi", ".pcx", ".sgi", ".rgb", ".im", ".msp", ".xbm",
    ".blp", ".ftex", ".mpo", ".eps", ".wmf", ".emf", ".dcx", ".fits", ".ras",
}


@dataclass(frozen=True)
class Format:
    key: str
    label: str
    ext: str
    pil: str
    quality: bool = False
    metadata: bool = False
    alpha: bool = True
    animation: bool = False
    icon: bool = False


FORMATS: dict[str, Format] = {f.key: f for f in [
    Format("jpeg", "JPEG", "jpg", "JPEG", quality=True, metadata=True, alpha=False),
    Format("png", "PNG", "png", "PNG", metadata=True, animation=True),
    Format("avif", "AVIF", "avif", "AVIF", quality=True, metadata=True, animation=True),
    Format("webp", "WebP", "webp", "WEBP", quality=True, metadata=True, animation=True),
    Format("tiff", "TIFF", "tiff", "TIFF", metadata=True),
    Format("gif", "GIF", "gif", "GIF", animation=True),
    Format("pdf", "PDF", "pdf", "PDF", alpha=False),
    Format("jp2", "JPEG 2000", "jp2", "JPEG2000", quality=True),
    Format("bmp", "BMP", "bmp", "BMP"),
    Format("tga", "TGA", "tga", "TGA"),
    Format("pbm", "PBM", "pbm", "PPM", alpha=False),
    Format("ico", "ICO (Windows icon)", "ico", "ICO", icon=True),
    Format("icns", "ICNS (Mac icon)", "icns", "ICNS", icon=True),
    Format("dds", "DDS texture", "dds", "DDS"),
]}

RESIZE_MODES = {
    "original": "Original size",
    "maxWidth": "Max width",
    "maxHeight": "Max height",
    "maxLongEdge": "Max long edge",
    "maxShortEdge": "Max short edge",
}


@dataclass
class Settings:
    format: str = "jpeg"
    quality: float = 0.8
    resize_mode: str = "original"
    resize_value: int = 2048
    allow_upscale: bool = False
    keep_metadata: bool = False

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class ImageInfo:
    width: int
    height: int
    frames: int = 1


# ---------------------------------------------------------------- reading

def is_image_path(path: Path) -> bool:
    return path.suffix.lower() in IMAGE_EXTENSIONS


def _open_raw(path: Path) -> Image.Image:
    if rawpy is None:
        raise ValueError("Camera RAW support isn't installed (rawpy).")
    with rawpy.imread(str(path)) as raw:
        rgb = raw.postprocess(use_camera_wb=True, output_bps=8)
    return Image.fromarray(rgb)


def open_image(path: Path) -> Image.Image:
    if path.suffix.lower() in RAW_EXTENSIONS:
        try:
            return _open_raw(path)
        except Exception:
            if path.suffix.lower() not in {".dng", ".tif", ".tiff"}:
                raise
    try:
        return Image.open(path)
    except Exception as exc:
        raise ValueError("This file isn't an image Pixelpress can read.") from exc


def info(path: Path) -> ImageInfo | None:
    try:
        if path.suffix.lower() in RAW_EXTENSIONS and rawpy is not None:
            try:
                with rawpy.imread(str(path)) as raw:
                    w, h = raw.sizes.width, raw.sizes.height
                    if raw.sizes.flip in (5, 6):
                        w, h = h, w
                    return ImageInfo(w, h, 1)
            except Exception:
                pass
        with Image.open(path) as im:
            w, h = im.size
            if im.getexif().get(0x0112, 1) in (5, 6, 7, 8):
                w, h = h, w
            return ImageInfo(w, h, getattr(im, "n_frames", 1))
    except Exception:
        return None


def thumbnail(path: Path, edge: int = 320) -> Image.Image | None:
    try:
        im = open_image(path)
        im.draft("RGB", (edge, edge))
        im = ImageOps.exif_transpose(im)
        im.thumbnail((edge, edge))
        return im.convert("RGBA")
    except Exception:
        return None


# ---------------------------------------------------------------- sizing

def target_size(width: int, height: int, s: Settings) -> tuple[int, int]:
    if width <= 0 or height <= 0:
        return width, height
    v = max(1, int(s.resize_value))
    scale = {
        "original": 1.0,
        "maxWidth": v / width,
        "maxHeight": v / height,
        "maxLongEdge": v / max(width, height),
        "maxShortEdge": v / min(width, height),
    }.get(s.resize_mode, 1.0)
    if not s.allow_upscale:
        scale = min(scale, 1.0)
    return max(1, round(width * scale)), max(1, round(height * scale))


def icon_sizes(fmt: Format, long_edge: int) -> list[int]:
    sizes = [16, 32, 64, 128, 256, 512, 1024] if fmt.key == "icns" else [16, 24, 32, 48, 64, 128, 256]
    fit = [s for s in sizes if s <= long_edge]
    return fit or sizes[:1]


# ---------------------------------------------------------------- converting

def _normalise(im: Image.Image) -> Image.Image:
    if im.mode in ("RGB", "RGBA"):
        return im
    if im.mode in ("I;16", "I;16B", "I;16L", "I"):
        im = im.point(lambda p: p / 256).convert("L")
    has_alpha = im.mode in ("RGBA", "LA", "PA", "La", "RGBa") or (im.mode == "P" and "transparency" in im.info)
    return im.convert("RGBA" if has_alpha else "RGB")


def _flatten(im: Image.Image) -> Image.Image:
    if im.mode != "RGBA":
        return im.convert("RGB")
    bg = Image.new("RGB", im.size, (255, 255, 255))
    bg.paste(im, mask=im.getchannel("A"))
    return bg


def _square(im: Image.Image, size: int) -> Image.Image:
    im = im.convert("RGBA")
    scale = min(size / im.width, size / im.height)
    w, h = max(1, round(im.width * scale)), max(1, round(im.height * scale))
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(im.resize((w, h), Image.Resampling.LANCZOS), ((size - w) // 2, (size - h) // 2))
    return canvas


# Keys in Image.info that some Pillow writers copy into the output. Only these survive "remove metadata";
# everything else (comments, XMP, EXIF, text chunks) is dropped so it can't leak into the converted file.
_INFO_KEEP = {"transparency", "duration", "loop", "background", "dpi", "icc_profile"}


def _prepare(frame: Image.Image, size: tuple[int, int], fmt: Format, keep_metadata: bool = False) -> Image.Image:
    im = _normalise(frame)
    if not keep_metadata:
        im = im if im is not frame else im.copy()
        im.info = {k: v for k, v in im.info.items() if k in _INFO_KEEP}
    if im.size != size:
        im = im.resize(size, Image.Resampling.LANCZOS)
    if not fmt.alpha:
        im = _flatten(im)
    if fmt.key == "pbm":
        im = im.convert("1")
    return im


def convert(src: Path, dst: Path, s: Settings) -> None:
    fmt = FORMATS[s.format]
    source = open_image(src)
    icc = source.info.get("icc_profile")
    animated = fmt.animation and getattr(source, "n_frames", 1) > 1
    if animated:
        size = target_size(*source.size, s)
        frames, durations = [], []
        for frame in ImageSequence.Iterator(source):
            frames.append(_prepare(frame.copy(), size, fmt, s.keep_metadata))
            durations.append(int(frame.info.get("duration", 100)) or 100)
    else:
        upright = ImageOps.exif_transpose(source)
        size = target_size(*upright.size, s)
        frames, durations = [_prepare(upright, size, fmt, s.keep_metadata)], []

    exif = None
    if s.keep_metadata and fmt.metadata:
        # Read only after rotating: the pixels are upright now, so the stored orientation must say so.
        exif = Image.Exif()
        exif.load(source.getexif().tobytes())
        exif[0x0112] = 1

    options: dict = {}
    q = max(1, min(100, round(s.quality * 100)))
    if fmt.key == "jpeg":
        options.update(quality=q, optimize=True, progressive=True)
    elif fmt.key in ("webp", "avif"):
        options.update(quality=q)
        if fmt.key == "webp":
            options.update(method=5)
    elif fmt.key == "jp2":
        options.update(quality_mode="dB", quality_layers=[20 + q * 0.4])
    elif fmt.key == "tiff":
        options.update(compression="tiff_lzw")
    elif fmt.key == "png":
        options.update(optimize=False)

    if icc and fmt.key in ("jpeg", "png", "webp", "avif", "tiff"):
        options["icc_profile"] = icc
    if exif is not None and fmt.key == "tiff":
        # Pillow's TIFF writer can't carry the EXIF/GPS sub-blocks, so keep the main tags (camera, date, etc.).
        options["tiffinfo"] = {k: v for k, v in exif.items() if k not in (0x8769, 0x8825)}
    elif exif is not None:
        options["exif"] = exif.tobytes()

    if fmt.icon:
        sizes = icon_sizes(fmt, max(size))
        base = _square(frames[0], sizes[-1])
        if fmt.key == "ico":
            options["sizes"] = [(n, n) for n in sizes]
        frames = [base]
    if animated and len(frames) > 1:
        options.update(save_all=True, append_images=frames[1:], duration=durations, loop=0)

    dst.parent.mkdir(parents=True, exist_ok=True)
    # "x" mode fails instead of replacing a file that appeared after the output name was picked.
    with open(dst, "xb") as fh:
        try:
            frames[0].save(fh, fmt.pil, **options)
        except Exception:
            fh.close()
            try:
                dst.unlink()
            except OSError:
                pass
            raise


_private_temp: Path | None = None


def private_temp_dir() -> Path:
    """A temp folder only this user can read, made fresh for each run (shared /tmp on Linux isn't safe)."""
    global _private_temp
    if _private_temp is None or not _private_temp.is_dir():
        _private_temp = Path(tempfile.mkdtemp(prefix="Pixelpress-"))
    return _private_temp


def preview(src: Path, s: Settings) -> Path:
    out = private_temp_dir() / f"{uuid.uuid4().hex}.{FORMATS[s.format].ext}"
    convert(src, out, s)
    return out


# ---------------------------------------------------------------- files

@dataclass
class FoundFile:
    path: Path
    relative_dir: str | None = None


def collect(paths: list[Path]) -> list[FoundFile]:
    """Expands folders recursively. relative_dir includes the dropped folder's own name."""
    found: list[FoundFile] = []
    for p in paths:
        if p.is_file():
            if is_image_path(p):
                found.append(FoundFile(p))
        elif p.is_dir():
            base = p.parent
            for root, dirs, files in os.walk(p):
                dirs[:] = sorted(d for d in dirs if not d.startswith("."))
                for name in sorted(files):
                    f = Path(root) / name
                    if not name.startswith(".") and is_image_path(f):
                        found.append(FoundFile(f, str(Path(root).relative_to(base))))
    return found


def output_paths(inputs: list[FoundFile], fmt: Format, destination: Path | None, preserve: bool) -> list[Path]:
    """Never overwrites an existing file or another file in the same batch."""
    reserved: set[str] = set()
    result = []
    for item in inputs:
        folder = destination if destination is not None else item.path.parent
        if destination is not None and preserve and item.relative_dir:
            folder = folder / item.relative_dir
        stem = item.path.stem
        candidate = folder / f"{stem}.{fmt.ext}"
        n = 2
        while str(candidate).lower() in reserved or candidate.exists():
            candidate = folder / f"{stem} {n}.{fmt.ext}"
            n += 1
        reserved.add(str(candidate).lower())
        result.append(candidate)
    return result


def byte_string(n: int) -> str:
    size = float(n)
    for unit in ("bytes", "KB", "MB", "GB"):
        if size < 1000 or unit == "GB":
            return f"{int(size)} {unit}" if unit == "bytes" else f"{size:.1f} {unit}".replace(".0 ", " ")
        size /= 1000
    return f"{n} bytes"


def savings(original: int, converted: int) -> str:
    if original <= 0:
        return ""
    change = (converted - original) / original * 100
    return f"−{-change:.0f}%" if change <= 0 else f"+{change:.0f}%"
