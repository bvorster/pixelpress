# Third-party software

Pixelpress's own code is MIT licensed. The release builds include these libraries, each under its own licence.

| Component | Used for | Licence |
|---|---|---|
| Apple ImageIO, SwiftUI | macOS app (part of macOS, not bundled) | Apple SDK |
| cwebp / libwebp (optional, not bundled) | WebP output on macOS | BSD-3-Clause |
| [Qt 6](https://www.qt.io) via [PySide6](https://pypi.org/project/PySide6-Essentials/) | Windows interface | LGPL-3.0 |
| [Pillow](https://python-pillow.org) and its bundled codecs (libjpeg-turbo, libpng, libwebp, libavif, dav1d, aom, OpenJPEG, libtiff, zlib, FreeType) | Windows image reading and writing | MIT-CMU and the codecs' own BSD-style licences |
| [pi-heif](https://pypi.org/project/pi-heif/) (libheif, libde265) | Reading HEIC/HEIF on Windows | BSD-3-Clause, LGPL-3.0 |
| [rawpy](https://pypi.org/project/rawpy/) (LibRaw) | Reading camera RAW on Windows | MIT, LGPL-2.1 / CDDL-1.0 |
| [NumPy](https://numpy.org) | Used by rawpy | BSD-3-Clause |
| [Python](https://www.python.org) | Windows runtime | PSF License |
| [PyInstaller](https://pyinstaller.org) bootloader | Packaging the .exe | GPL-2.0 with a bootloader exception that permits this use |

The LGPL libraries are loaded dynamically from the unpacked bundle. To use your own build of any of them,
run Pixelpress from source (see "Building from source" in the README) with your version installed.
