"""Command-line mode: `Pixelpress.exe convert [options] <files or folders>`."""
from __future__ import annotations

import argparse
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import converter as cv

RESIZE = {"original": "original", "width": "maxWidth", "height": "maxHeight", "long": "maxLongEdge", "short": "maxShortEdge"}


def _attach_console() -> None:
    """A windowed .exe has no console; borrow the one it was started from so output shows up."""
    if sys.platform == "win32" and sys.stdout is None:
        try:
            import ctypes

            if ctypes.windll.kernel32.AttachConsole(-1):
                sys.stdout = open("CONOUT$", "w", encoding="utf-8")
                sys.stderr = sys.stdout
        except Exception:
            pass
    if sys.stdout is None:
        import io

        sys.stdout = sys.stderr = io.StringIO()


def run(argv: list[str]) -> int:
    _attach_console()
    p = argparse.ArgumentParser(prog="Pixelpress convert", description="Convert, compress and resize images.")
    p.add_argument("inputs", nargs="*", type=Path, help="files or folders")
    p.add_argument("-f", "--format", default="jpeg", help="output format (see --list-formats)")
    p.add_argument("-q", "--quality", type=float, default=80, help="quality 0-100 for lossy formats")
    p.add_argument("--resize", choices=RESIZE, default="original")
    p.add_argument("--size", type=int, default=2048, help="target pixels for --resize")
    p.add_argument("--upscale", action="store_true", help="allow making images larger")
    p.add_argument("--keep-metadata", action="store_true", help="keep EXIF and GPS (default: remove)")
    p.add_argument("-o", "--output", type=Path, help="destination folder (default: next to each original)")
    p.add_argument("--flat", action="store_true", help="don't recreate folder structure under --output")
    p.add_argument("--list-formats", action="store_true")
    a = p.parse_args(argv)

    if a.list_formats:
        for f in cv.FORMATS.values():
            print(f"{f.key:<6} {f.label}")
        return 0
    key = "jpeg" if a.format.lower() == "jpg" else a.format.lower()
    if key not in cv.FORMATS:
        print(f"Pixelpress: unknown format {a.format!r}; try --list-formats", file=sys.stderr)
        return 2

    s = cv.Settings(format=key, quality=max(0.0, min(100.0, a.quality)) / 100, resize_mode=RESIZE[a.resize],
                    resize_value=a.size, allow_upscale=a.upscale, keep_metadata=a.keep_metadata)
    files = cv.collect(a.inputs)
    if not files:
        print("Pixelpress: no images found", file=sys.stderr)
        return 2
    outputs = cv.output_paths(files, cv.FORMATS[key], a.output, not a.flat)

    def job(pair):
        item, out = pair
        try:
            cv.convert(item.path, out, s)
            before, after = item.path.stat().st_size, out.stat().st_size
            return True, f"ok    {item.path.name} → {out}  {cv.byte_string(before)} → {cv.byte_string(after)} ({cv.savings(before, after)})"
        except Exception as exc:
            return False, f"FAIL  {item.path.name}: {exc}"

    failures = 0
    with ThreadPoolExecutor() as pool:
        for ok, line in pool.map(job, zip(files, outputs)):
            failures += not ok
            print(line)
    print(f"{len(files) - failures} converted, {failures} failed")
    sys.stdout.flush()
    return 0 if failures == 0 else 1
