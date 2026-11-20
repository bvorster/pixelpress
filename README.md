<p align="center"><img src="windows/assets/pixelpress.png" width="128" alt="Pixelpress icon"></p>

<h1 align="center">Pixelpress</h1>

<p align="center">Convert, compress and resize a folder of photos in one go, on Mac or Windows.<br>
Free, open source, offline, and no cap on how many images you convert.</p>

## Download

Get the latest build from the [Releases page](https://github.com/bvorster/pixelpress/releases/latest):

- **macOS 13 or later:** `Pixelpress-macOS.dmg`. Open it and drag Pixelpress into Applications.
- **Windows 10 and 11:** `Pixelpress-Windows.exe`. It's a single file; no installer.

Neither build is signed with a paid developer certificate yet, so your computer asks you to confirm the first launch:

- **Mac:** right-click Pixelpress in Applications and choose **Open**. If macOS only offers to move it to the Bin,
  go to System Settings → Privacy & Security and click **Open Anyway**.
- **Windows:** if SmartScreen says "Windows protected your PC", click **More info**, then **Run anyway**.

## What it does

Drop in files or whole folders, pick a format, press **Convert**. Each tile shows the size before and after, and
double-clicking one opens a before/after view with a draggable divider and zoom, which updates as you change settings.

| | macOS | Windows |
|---|---|---|
| Reads | Everything macOS can open: JPEG, PNG, HEIC, AVIF, WebP, TIFF, GIF, PSD, DNG, camera RAW, OpenEXR, JPEG 2000 and more | JPEG, PNG, HEIC, AVIF, WebP, TIFF, GIF, PSD, DNG, camera RAW (via LibRaw), JPEG 2000, BMP, ICO, TGA, DDS and more |
| Writes | JPEG, PNG, HEIC, AVIF, WebP, TIFF, GIF, PDF, JPEG 2000, HEIF sequence, OpenEXR, PSD, BMP, TGA, PBM, ICO, ICNS, DDS, KTX, ASTC, PVRTC | JPEG, PNG, AVIF, WebP, TIFF, GIF, PDF, JPEG 2000, BMP, TGA, PBM, ICO, ICNS, DDS |

Both versions also give you:

- a quality slider for the lossy formats
- resizing by max width, max height, long edge or short edge, with presets and optional upscaling
- keep or remove EXIF and GPS data (colour profiles always stay, so colours don't shift)
- save to a folder, keeping the folder structure you dropped in, or save next to the originals
- photos turned the right way up
- animations keep every frame: GIF, PNG and HEIF sequence on the Mac; GIF, PNG, WebP and AVIF on Windows
- existing files are never overwritten: a clash gets a number added (`photo 2.jpg`)

Some limits you might hit:

- **Windows can't write HEIC.** The free HEIC encoders are GPL-licensed, so the Windows build only reads HEIC.
  It can read your iPhone photos and convert them to anything else.
- **HDR is lost when resizing.** HDR photos are saved as standard range once you resize them.
- **WebP on the Mac needs `cwebp`.** macOS can't write WebP on its own, so Pixelpress uses
  `cwebp` if you have it: `brew install webp`.
- **TIFF metadata on Windows is partial.** TIFFs keep camera and date tags, but not GPS.

## Command line

Both apps have a `convert` mode for scripts, with the same options as the window:

```sh
# macOS
/Applications/Pixelpress.app/Contents/MacOS/Pixelpress convert -f webp -q 75 --resize long --size 2048 -o ~/Desktop/web ~/Pictures/Trip

# Windows
Pixelpress-Windows.exe convert -f jpeg -q 85 --keep-metadata -o C:\Users\you\Pictures\out C:\Users\you\Pictures\Phone
```

Run `convert --help` for every option and `convert --list-formats` for the formats.

## Building from source

- **macOS** (needs Xcode): `macos/make-dmg.sh` builds `macos/dist/Pixelpress.app` and `Pixelpress.dmg`.
- **Windows** (needs Python 3.12): run `windows\build.ps1` in PowerShell to get `windows\dist\Pixelpress.exe`. To run it
  without building, use `pip install -r windows/requirements.txt` then `python windows/run.py`. That also works on
  Linux and macOS.

Every push to `main` builds both apps on GitHub Actions. Pushing a `v*` tag publishes them as a release.

The two apps are separate code: Swift on the Mac, so it can use Apple's image engine, and Python with Qt on Windows.
[CLEANROOM.md](CLEANROOM.md) explains where the feature set came from, and [THIRD-PARTY.md](THIRD-PARTY.md) lists
the libraries inside the builds.

## Licence

[MIT](LICENSE). Pull requests and bug reports are welcome; if a file won't convert, attach it to the issue if you can.
