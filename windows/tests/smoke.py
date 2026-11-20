"""Smoke test: makes sample images, converts them to every output format and checks the results.

    python tests/smoke.py                 # run the test against the source
    python tests/smoke.py --make-only DIR # only write the sample images (used to test the built .exe)
"""
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from PIL import Image  # noqa: E402

from pixelpress import cli, converter as cv  # noqa: E402


def make_samples(folder: Path) -> None:
    (folder / "sub").mkdir(parents=True, exist_ok=True)
    photo = Image.radial_gradient("L").resize((1600, 1000)).convert("RGB")
    photo.save(folder / "photo.png")
    exif = Image.Exif()
    exif[0x0112] = 6        # rotate 90° on display
    exif[0x010F] = "TestCam"
    photo.save(folder / "rotated.jpg", exif=exif.tobytes())
    Image.new("RGBA", (600, 400), (255, 0, 0, 128)).save(folder / "alpha.png")
    frames = [Image.new("RGB", (160, 120), (i * 25, 80, 200 - i * 20)) for i in range(8)]
    frames[0].save(folder / "sub" / "anim.gif", save_all=True, append_images=frames[1:], duration=80, loop=0)


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--make-only":
        make_samples(Path(sys.argv[2]))
        return 0
    work = Path(tempfile.mkdtemp())
    make_samples(work / "in")
    failures = []
    for key, fmt in cv.FORMATS.items():
        out = work / "out" / key
        code = cli.run(["-f", key, "-q", "70", "--resize", "long", "--size", "800", "-o", str(out), str(work / "in")])
        produced = sorted(out.rglob(f"*.{fmt.ext}"))
        if code != 0 or len(produced) != 4:
            failures.append(f"{key}: exit {code}, {len(produced)} files")
    with Image.open(work / "out" / "jpeg" / "in" / "rotated.jpg") as im:
        if im.size != (500, 800):
            failures.append(f"rotation: got {im.size}, expected (500, 800)")
    with Image.open(work / "out" / "gif" / "in" / "sub" / "anim.gif") as im:
        if getattr(im, "n_frames", 1) != 8:
            failures.append("animation: frames lost")
    print("\n".join(failures) or "All formats OK")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
