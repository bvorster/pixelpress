"""Pixelpress desktop window (Qt). Built for Windows 11; also runs on Linux and macOS."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QObject, QRect, QRunnable, QSettings, QSize, Qt, QThreadPool, QTimer, Signal
from PySide6.QtGui import (QAction, QColor, QFont, QFontMetrics, QIcon, QImage, QKeySequence, QPainter, QPainterPath,
                           QPalette, QPen, QPixmap, QShortcut)
from PySide6.QtWidgets import (
    QAbstractItemView, QApplication, QButtonGroup, QCheckBox, QComboBox, QDialog, QFileDialog, QFormLayout,
    QFrame, QGroupBox, QHBoxLayout, QLabel, QListWidget, QListWidgetItem, QMainWindow, QMenu, QMessageBox,
    QProgressBar, QPushButton, QRadioButton, QScrollArea, QSlider, QSpinBox, QStackedWidget, QStyle,
    QStyledItemDelegate, QToolBar, QVBoxLayout, QWidget,
)

from . import converter as cv

APP_NAME = "Pixelpress"
VERSION = "1.0.0"


def resource(name: str) -> Path:
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent.parent))
    return base / "assets" / name


def pil_to_qimage(im) -> QImage:
    im = im.convert("RGBA")
    data = im.tobytes("raw", "RGBA")
    return QImage(data, im.width, im.height, im.width * 4, QImage.Format.Format_RGBA8888).copy()


def reveal(path: Path) -> None:
    if sys.platform == "win32":
        subprocess.Popen(["explorer", "/select,", str(path)])
    elif sys.platform == "darwin":
        subprocess.Popen(["open", "-R", str(path)])
    else:
        subprocess.Popen(["xdg-open", str(path.parent)])


def open_folder(path: Path) -> None:
    if sys.platform == "win32":
        os.startfile(str(path))  # type: ignore[attr-defined]
    elif sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])
    else:
        subprocess.Popen(["xdg-open", str(path)])


def play_done_sound(ok: bool) -> None:
    if sys.platform == "win32":
        try:
            import winsound

            winsound.MessageBeep(winsound.MB_OK if ok else winsound.MB_ICONHAND)
            return
        except Exception:
            pass
    QApplication.beep()


# ---------------------------------------------------------------- model

@dataclass
class Item:
    path: Path
    relative_dir: str | None
    width: int
    height: int
    frames: int
    size: int
    id: str = field(default_factory=lambda: uuid.uuid4().hex)
    status: str = "pending"          # pending | working | done | failed
    output: Path | None = None
    output_size: int = 0
    error: str = ""


class Signals(QObject):
    scanned = Signal(list)
    thumbnail = Signal(str, QImage)
    status = Signal(str, str, object, int, str)   # id, status, output, size, error
    preview = Signal(int, object, object)          # token, QImage | None, (size, w, h) | error str


class Task(QRunnable):
    def __init__(self, fn):
        super().__init__()
        self.fn = fn

    def run(self):
        self.fn()


# ---------------------------------------------------------------- settings persistence

class Prefs:
    def __init__(self):
        self.q = QSettings(APP_NAME, APP_NAME)
        d = cv.Settings()
        self.settings = cv.Settings(
            format=str(self.q.value("format", d.format)),
            quality=float(self.q.value("quality", d.quality)),
            resize_mode=str(self.q.value("resize_mode", d.resize_mode)),
            resize_value=int(self.q.value("resize_value", d.resize_value)),
            allow_upscale=self._bool("allow_upscale", d.allow_upscale),
            keep_metadata=self._bool("keep_metadata", d.keep_metadata),
        )
        if self.settings.format not in cv.FORMATS:
            self.settings.format = "jpeg"
        downloads = Path.home() / "Downloads"
        self.next_to_source = self._bool("next_to_source", False)
        self.destination = Path(str(self.q.value("destination", str(downloads if downloads.exists() else Path.home()))))
        self.preserve = self._bool("preserve", True)
        self.open_when_done = self._bool("open_when_done", False)
        self.sound = self._bool("sound", True)

    def _bool(self, key, default):
        v = self.q.value(key, default)
        return v if isinstance(v, bool) else str(v).lower() in ("1", "true", "yes")

    def save(self):
        for k, v in self.settings.to_dict().items():
            self.q.setValue(k, v)
        self.q.setValue("next_to_source", self.next_to_source)
        self.q.setValue("destination", str(self.destination))
        self.q.setValue("preserve", self.preserve)
        self.q.setValue("open_when_done", self.open_when_done)
        self.q.setValue("sound", self.sound)


# ---------------------------------------------------------------- compare dialog

class SplitView(QWidget):
    def __init__(self):
        super().__init__()
        self.before: QPixmap | None = None
        self.after: QPixmap | None = None
        self.split = 0.5
        self.zoom = 1.0
        self.setMinimumSize(400, 300)
        self.setCursor(Qt.CursorShape.SplitHCursor)

    def set_zoom(self, zoom: float, viewport: QSize):
        self.zoom = zoom
        self.setFixedSize(QSize(int(viewport.width() * zoom), int(viewport.height() * zoom)))
        self.update()

    def _rect(self, pm: QPixmap) -> QRect:
        s = pm.size().scaled(self.size(), Qt.AspectRatioMode.KeepAspectRatio)
        return QRect((self.width() - s.width()) // 2, (self.height() - s.height()) // 2, s.width(), s.height())

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, self.zoom < 2)
        ref = self.before or self.after
        if ref is None:
            return
        target = self._rect(ref)
        x = int(self.width() * self.split)
        if self.after:
            p.drawPixmap(target, self.after)
        if self.before:
            p.save()
            p.setClipRect(QRect(0, 0, x, self.height()))
            p.drawPixmap(target, self.before)
            p.restore()
        p.setPen(QPen(QColor("white"), 2))
        p.drawLine(x, 0, x, self.height())
        for text, left in (("Before", True), ("After", False)):
            r = QRect(12 if left else self.width() - 80, 12, 68, 22)
            p.fillRect(r, QColor(0, 0, 0, 140))
            p.setPen(QColor("white"))
            p.drawText(r, Qt.AlignmentFlag.AlignCenter, text)

    def mousePressEvent(self, e):
        self.mouseMoveEvent(e)

    def mouseMoveEvent(self, e):
        self.split = max(0.0, min(1.0, e.position().x() / max(1, self.width())))
        self.update()


class CompareDialog(QDialog):
    def __init__(self, window: "MainWindow", item: Item):
        super().__init__(window)
        self.window_ = window
        self.item = item
        self.token = 0
        self.setWindowTitle(f"Compare – {item.path.name}")
        self.resize(1100, 760)

        self.before_label = QLabel(f"Before: {cv.byte_string(item.size)} · {item.width}×{item.height}")
        self.after_label = QLabel("After: rendering…")
        header = QHBoxLayout()
        name = QLabel(item.path.name)
        name.setStyleSheet("font-weight: 600; font-size: 14px")
        header.addWidget(name)
        header.addStretch()
        header.addWidget(self.before_label)
        header.addSpacing(24)
        header.addWidget(self.after_label)

        self.view = SplitView()
        self.scroll = QScrollArea()
        self.scroll.setWidget(self.view)
        self.scroll.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.scroll.setStyleSheet("QScrollArea { background: #1e1e1e; border: none }")

        self.zoom = QSlider(Qt.Orientation.Horizontal)
        self.zoom.setRange(100, 800)
        self.zoom.setFixedWidth(220)
        self.zoom_label = QLabel("1×")
        self.zoom.valueChanged.connect(self._apply_zoom)
        done = QPushButton("Done")
        done.setDefault(True)
        done.clicked.connect(self.accept)
        footer = QHBoxLayout()
        footer.addWidget(QLabel("Zoom"))
        footer.addWidget(self.zoom)
        footer.addWidget(self.zoom_label)
        footer.addStretch()
        footer.addWidget(QLabel("Drag across the image to move the divider."))
        footer.addWidget(done)

        layout = QVBoxLayout(self)
        layout.addLayout(header)
        layout.addWidget(self.scroll, 1)
        layout.addLayout(footer)

        window.signals.preview.connect(self._on_preview)
        window.settings_changed.connect(self.render)
        path = item.path
        sig = window.signals

        def load_before():
            im = cv.thumbnail(path, 4096)
            sig.preview.emit(-1, pil_to_qimage(im) if im else None, None)

        window.pool.start(Task(load_before))
        self.render()

    def showEvent(self, e):
        super().showEvent(e)
        QTimer.singleShot(0, lambda: self._apply_zoom(self.zoom.value()))

    def resizeEvent(self, e):
        super().resizeEvent(e)
        self._apply_zoom(self.zoom.value())

    def _apply_zoom(self, value: int):
        self.zoom_label.setText(f"{value / 100:.0f}×")
        self.view.set_zoom(value / 100, self.scroll.viewport().size())

    def render(self):
        self.token += 1
        token, settings, path, sig = self.token, cv.Settings(**self.window_.prefs.settings.to_dict()), self.item.path, self.window_.signals
        self.after_label.setText(f"After · {cv.FORMATS[settings.format].label}: rendering…")

        def work():
            try:
                out = cv.preview(path, settings)
                try:
                    size = out.stat().st_size
                    from PIL import Image

                    with Image.open(out) as im:
                        w, h = im.size
                        q = pil_to_qimage(im)
                finally:
                    out.unlink(missing_ok=True)
                sig.preview.emit(token, q, (size, w, h))
            except Exception as exc:
                sig.preview.emit(token, None, str(exc))

        QTimer.singleShot(250, lambda: token == self.token and self.window_.pool.start(Task(work)))

    def _on_preview(self, token, image, meta):
        if token == -1:
            if image is not None and self.view.before is None:
                self.view.before = QPixmap.fromImage(image)
                self.view.update()
            return
        if token != self.token:
            return
        label = cv.FORMATS[self.window_.prefs.settings.format].label
        if isinstance(meta, tuple):
            size, w, h = meta
            self.view.after = QPixmap.fromImage(image) if image is not None else None
            colour = "#2fa84f" if size <= self.item.size else "#d9822b"
            self.after_label.setText(f"After · {label}: {cv.byte_string(size)} · {w}×{h} "
                                     f"<b style='color:{colour}'>{cv.savings(self.item.size, size)}</b>")
        else:
            self.view.after = None
            self.after_label.setText(f"<span style='color:#d9822b'>{meta}</span>")
        self.view.update()

    def done(self, r):
        try:
            self.window_.signals.preview.disconnect(self._on_preview)
            self.window_.settings_changed.disconnect(self.render)
        except (RuntimeError, TypeError):
            pass
        super().done(r)


# ---------------------------------------------------------------- settings panel

class SettingsPanel(QScrollArea):
    def __init__(self, window: "MainWindow"):
        super().__init__()
        self.w = window
        s = window.prefs.settings
        self.setWidgetResizable(True)
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setFixedWidth(320)
        body = QWidget()
        col = QVBoxLayout(body)
        col.setContentsMargins(12, 12, 12, 12)
        col.setSpacing(12)

        # Output
        out = QGroupBox("Output")
        f = QFormLayout(out)
        self.format = QComboBox()
        for fmt in cv.FORMATS.values():
            self.format.addItem(fmt.label, fmt.key)
        self.format.setCurrentIndex(max(0, self.format.findData(s.format)))
        self.format.currentIndexChanged.connect(self._changed)
        f.addRow("Format", self.format)
        self.quality = QSlider(Qt.Orientation.Horizontal)
        self.quality.setRange(5, 100)
        self.quality.setValue(round(s.quality * 100))
        self.quality_label = QLabel()
        self.quality.valueChanged.connect(self._changed)
        qrow = QHBoxLayout()
        qrow.addWidget(self.quality)
        qrow.addWidget(self.quality_label)
        self.quality_row = QWidget()
        self.quality_row.setLayout(qrow)
        qrow.setContentsMargins(0, 0, 0, 0)
        f.addRow("Quality", self.quality_row)
        self.format_note = QLabel()
        self.format_note.setWordWrap(True)
        self.format_note.setStyleSheet("color: gray; font-size: 11px")
        f.addRow(self.format_note)
        col.addWidget(out)

        # Size
        size = QGroupBox("Size")
        f = QFormLayout(size)
        self.mode = QComboBox()
        for key, label in cv.RESIZE_MODES.items():
            self.mode.addItem(label, key)
        self.mode.setCurrentIndex(max(0, self.mode.findData(s.resize_mode)))
        self.mode.currentIndexChanged.connect(self._changed)
        f.addRow("Resize", self.mode)
        self.pixels = QSpinBox()
        self.pixels.setRange(1, 65535)
        self.pixels.setSuffix(" px")
        self.pixels.setValue(s.resize_value)
        self.pixels.valueChanged.connect(self._changed)
        self.presets = QComboBox()
        self.presets.addItem("Presets")
        for p in (256, 512, 1024, 1280, 1600, 1920, 2048, 2560, 3840):
            self.presets.addItem(f"{p} px", p)
        self.presets.activated.connect(self._preset)
        prow = QHBoxLayout()
        prow.setContentsMargins(0, 0, 0, 0)
        prow.addWidget(self.pixels, 1)
        prow.addWidget(self.presets)
        self.pixel_row = QWidget()
        self.pixel_row.setLayout(prow)
        f.addRow("Pixels", self.pixel_row)
        self.upscale = QCheckBox("Allow upscaling")
        self.upscale.setChecked(s.allow_upscale)
        self.upscale.toggled.connect(self._changed)
        f.addRow(self.upscale)
        col.addWidget(size)

        # Metadata
        meta = QGroupBox("Metadata")
        v = QVBoxLayout(meta)
        mrow = QHBoxLayout()
        mrow.addWidget(QLabel("EXIF & location"))
        mrow.addStretch()
        self.keep = QRadioButton("Keep")
        self.remove = QRadioButton("Remove")
        (self.keep if s.keep_metadata else self.remove).setChecked(True)
        group = QButtonGroup(self)
        group.addButton(self.keep)
        group.addButton(self.remove)
        self.keep.toggled.connect(self._changed)
        mrow.addWidget(self.keep)
        mrow.addWidget(self.remove)
        v.addLayout(mrow)
        self.meta_note = QLabel()
        self.meta_note.setWordWrap(True)
        self.meta_note.setStyleSheet("color: gray; font-size: 11px")
        v.addWidget(self.meta_note)
        col.addWidget(meta)

        # Destination
        dest = QGroupBox("Destination")
        v = QVBoxLayout(dest)
        self.to_folder = QRadioButton("Save to a folder")
        self.to_source = QRadioButton("Save next to the originals")
        (self.to_source if window.prefs.next_to_source else self.to_folder).setChecked(True)
        g2 = QButtonGroup(self)
        g2.addButton(self.to_folder)
        g2.addButton(self.to_source)
        self.to_folder.toggled.connect(self._changed)
        v.addWidget(self.to_folder)
        drow = QHBoxLayout()
        self.folder_label = QLabel()
        self.folder_label.setStyleSheet("font-weight: 600")
        choose = QPushButton("Choose…")
        choose.clicked.connect(self._choose)
        drow.addSpacing(22)
        drow.addWidget(self.folder_label, 1)
        drow.addWidget(choose)
        self.folder_row = QWidget()
        self.folder_row.setLayout(drow)
        drow.setContentsMargins(0, 0, 0, 0)
        v.addWidget(self.folder_row)
        self.preserve = QCheckBox("Keep folder structure")
        self.preserve.setChecked(window.prefs.preserve)
        self.preserve.toggled.connect(self._changed)
        v.addWidget(self.preserve)
        v.addWidget(self.to_source)
        self.open_done = QCheckBox("Open the folder when done")
        self.open_done.setChecked(window.prefs.open_when_done)
        self.open_done.toggled.connect(self._changed)
        self.sound = QCheckBox("Play a sound when done")
        self.sound.setChecked(window.prefs.sound)
        self.sound.toggled.connect(self._changed)
        v.addWidget(self.open_done)
        v.addWidget(self.sound)
        col.addWidget(dest)
        col.addStretch()

        about = QLabel(f"{APP_NAME} {VERSION} · free and open source")
        about.setStyleSheet("color: gray; font-size: 11px")
        col.addWidget(about)
        self.setWidget(body)
        self.setAcceptDrops(True)
        self._sync()

    def _preset(self, index):
        value = self.presets.itemData(index)
        if value:
            self.pixels.setValue(value)
        self.presets.setCurrentIndex(0)

    def _choose(self):
        folder = QFileDialog.getExistingDirectory(self, "Choose destination", str(self.w.prefs.destination))
        if folder:
            self.w.prefs.destination = Path(folder)
            self.to_folder.setChecked(True)
            self._changed()

    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e):
        """Dropping a folder on the settings panel makes it the destination."""
        for url in e.mimeData().urls():
            p = Path(url.toLocalFile())
            if p.is_dir():
                self.w.prefs.destination = p
                self.to_folder.setChecked(True)
                self._changed()
                return
        self.w.add_paths([Path(u.toLocalFile()) for u in e.mimeData().urls()])

    def _changed(self, *_):
        prefs = self.w.prefs
        s = prefs.settings
        s.format = self.format.currentData()
        s.quality = self.quality.value() / 100
        s.resize_mode = self.mode.currentData()
        s.resize_value = self.pixels.value()
        s.allow_upscale = self.upscale.isChecked()
        s.keep_metadata = self.keep.isChecked()
        prefs.next_to_source = self.to_source.isChecked()
        prefs.preserve = self.preserve.isChecked()
        prefs.open_when_done = self.open_done.isChecked()
        prefs.sound = self.sound.isChecked()
        prefs.save()
        self._sync()
        self.w.settings_changed.emit()

    def _sync(self):
        prefs = self.w.prefs
        fmt = cv.FORMATS[prefs.settings.format]
        self.quality_row.setEnabled(fmt.quality)
        self.quality_label.setText(f"{self.quality.value()}%" if fmt.quality else "n/a")
        notes = []
        if fmt.animation:
            notes.append("Animated images keep every frame.")
        if fmt.icon:
            notes.append("Icons get every standard size up to the largest that fits, padded to a square.")
        self.format_note.setText(" ".join(notes))
        self.format_note.setVisible(bool(notes))
        resizing = prefs.settings.resize_mode != "original"
        self.pixel_row.setEnabled(resizing)
        self.upscale.setEnabled(resizing)
        self.keep.setEnabled(fmt.metadata)
        self.remove.setEnabled(fmt.metadata)
        self.meta_note.setText("Remove strips camera, date and GPS data. Colour profiles are always kept."
                               if fmt.metadata else f"{fmt.label} files don't carry EXIF data.")
        self.folder_label.setText(prefs.destination.name or str(prefs.destination))
        self.folder_label.setToolTip(str(prefs.destination))
        self.folder_row.setEnabled(not prefs.next_to_source)
        self.preserve.setEnabled(not prefs.next_to_source)


# ---------------------------------------------------------------- main window

TILE_ROLE = Qt.ItemDataRole.UserRole + 1


class TileDelegate(QStyledItemDelegate):
    """Draws each image as a card: thumbnail, status badge, name, dimensions and sizes."""

    SIZE = QSize(196, 212)

    def sizeHint(self, option, index):
        return self.SIZE

    def paint(self, p: QPainter, option, index):
        tile = index.data(TILE_ROLE)
        if not tile:
            return
        name, dims, sizes, status, frames = tile
        pal = option.palette
        dark = pal.color(QPalette.ColorRole.Window).lightness() < 128
        r = option.rect.adjusted(5, 5, -5, -5)
        p.save()
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        card = QPainterPath()
        card.addRoundedRect(r, 10, 10)
        p.fillPath(card, QColor(255, 255, 255, 14) if dark else QColor(0, 0, 0, 8))
        selected = bool(option.state & QStyle.StateFlag.State_Selected)
        p.setPen(QPen(pal.color(QPalette.ColorRole.Highlight), 2) if selected else QPen(QColor(128, 128, 128, 70), 1))
        p.drawPath(card)

        thumb = QRect(r.x() + 8, r.y() + 8, r.width() - 16, 124)
        well = QPainterPath()
        well.addRoundedRect(thumb, 7, 7)
        p.fillPath(well, QColor(128, 128, 128, 40))
        pix = index.data(Qt.ItemDataRole.DecorationRole)
        if isinstance(pix, QPixmap) and not pix.isNull():
            scaled = pix.scaled(thumb.size(), Qt.AspectRatioMode.KeepAspectRatio, Qt.TransformationMode.SmoothTransformation)
            p.save()
            p.setClipPath(well)
            p.drawPixmap(thumb.x() + (thumb.width() - scaled.width()) // 2,
                         thumb.y() + (thumb.height() - scaled.height()) // 2, scaled)
            p.restore()

        badge = {"done": ("#2fa84f", "✓"), "failed": ("#d9822b", "!"), "working": ("#808080", "…")}.get(status)
        if badge:
            b = QRect(thumb.right() - 26, thumb.y() + 6, 20, 20)
            p.setBrush(QColor(badge[0]))
            p.setPen(Qt.PenStyle.NoPen)
            p.drawEllipse(b)
            p.setPen(QColor("white"))
            f = QFont(option.font)
            f.setBold(True)
            p.setFont(f)
            p.drawText(b, Qt.AlignmentFlag.AlignCenter, badge[1])
        if frames > 1:
            f = QFont(option.font)
            f.setPointSizeF(max(7.0, f.pointSizeF() - 2))
            f.setBold(True)
            p.setFont(f)
            text = f"{frames} frames"
            w = QFontMetrics(f).horizontalAdvance(text) + 12
            tag = QRect(thumb.x() + 6, thumb.bottom() - 24, w, 18)
            p.setBrush(QColor(0, 0, 0, 150))
            p.setPen(Qt.PenStyle.NoPen)
            p.drawRoundedRect(tag, 9, 9)
            p.setPen(QColor("white"))
            p.drawText(tag, Qt.AlignmentFlag.AlignCenter, text)

        x, y, w = r.x() + 8, thumb.bottom() + 8, r.width() - 16
        text_color = pal.color(QPalette.ColorRole.Text)
        bold = QFont(option.font)
        bold.setBold(True)
        small = QFont(option.font)
        small.setPointSizeF(max(7.0, small.pointSizeF() - 1))
        lines = [
            (bold, text_color, QFontMetrics(bold).elidedText(name, Qt.TextElideMode.ElideMiddle, w)),
            (small, QColor(140, 140, 140), QFontMetrics(small).elidedText(dims, Qt.TextElideMode.ElideRight, w)),
            (small, QColor({"done": "#2fa84f", "failed": "#d9822b"}.get(status, "#8c8c8c")),
             QFontMetrics(small).elidedText(sizes, Qt.TextElideMode.ElideRight, w)),
        ]
        for font, color, text in lines:
            p.setFont(font)
            p.setPen(color)
            h = QFontMetrics(font).height()
            p.drawText(QRect(x, y, w, h), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, text)
            y += h + 3
        p.restore()


class ImageList(QListWidget):
    def __init__(self, window: "MainWindow"):
        super().__init__()
        self.w = window
        self.setViewMode(QListWidget.ViewMode.IconMode)
        self.setItemDelegate(TileDelegate(self))
        self.setGridSize(TileDelegate.SIZE)
        self.setResizeMode(QListWidget.ResizeMode.Adjust)
        self.setMovement(QListWidget.Movement.Static)
        self.setUniformItemSizes(True)
        self.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.setAcceptDrops(True)
        self.setDragEnabled(False)
        self.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.setStyleSheet("QListWidget { border: none; padding: 8px }")

    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dragMoveEvent(self, e):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e):
        self.w.add_paths([Path(u.toLocalFile()) for u in e.mimeData().urls() if u.isLocalFile()])
        e.acceptProposedAction()


class EmptyView(QWidget):
    def __init__(self, window: "MainWindow"):
        super().__init__()
        self.w = window
        self.setAcceptDrops(True)
        v = QVBoxLayout(self)
        v.addStretch()
        title = QLabel("Drop images or folders here")
        title.setStyleSheet("font-size: 22px; font-weight: 500")
        sub = QLabel("Or press Ctrl+O to choose them, or Ctrl+V to paste.")
        sub.setStyleSheet("color: gray")
        button = QPushButton("Choose Images…")
        button.clicked.connect(window.open_dialog)
        for widget in (title, sub, button):
            v.addWidget(widget, 0, Qt.AlignmentFlag.AlignHCenter)
        v.addStretch()

    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e):
        self.w.add_paths([Path(u.toLocalFile()) for u in e.mimeData().urls() if u.isLocalFile()])


class MainWindow(QMainWindow):
    settings_changed = Signal()

    def __init__(self):
        super().__init__()
        self.setWindowTitle(APP_NAME)
        self.resize(1120, 700)
        self.setMinimumSize(880, 560)
        self.prefs = Prefs()
        self.items: dict[str, Item] = {}
        self.order: list[str] = []
        self.list_items: dict[str, QListWidgetItem] = {}
        self.pool = QThreadPool.globalInstance()
        self.signals = Signals()
        self.signals.scanned.connect(self._on_scanned)
        self.signals.thumbnail.connect(self._on_thumbnail)
        self.signals.status.connect(self._on_status)
        self.converting: set[str] = set()
        self.batch: list[str] = []
        self.scanning = 0

        # toolbar
        tb = QToolBar()
        tb.setMovable(False)
        tb.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextOnly)
        self.addToolBar(tb)
        add = QAction("Add Images…", self, shortcut=QKeySequence.StandardKey.Open, triggered=self.open_dialog)
        self.clear_action = QAction("Clear", self, triggered=self.clear)
        self.remove_done_action = QAction("Remove Finished", self, triggered=self.remove_finished)
        tb.addAction(add)
        tb.addAction(self.clear_action)
        tb.addAction(self.remove_done_action)
        spacer = QWidget()
        spacer.setSizePolicy(spacer.sizePolicy().horizontalPolicy().Expanding, spacer.sizePolicy().verticalPolicy())
        tb.addWidget(spacer)
        self.convert_button = QPushButton("Convert")
        self.convert_button.setMinimumWidth(110)
        self.convert_button.setStyleSheet(
            "QPushButton { background: #e0426a; color: white; border-radius: 6px; padding: 6px 16px; font-weight: 600 }"
            "QPushButton:disabled { background: #8a8a8a }")
        self.convert_button.clicked.connect(self.convert_all)
        tb.addWidget(self.convert_button)

        # body
        self.grid = ImageList(self)
        self.grid.itemDoubleClicked.connect(lambda it: self.compare(it.data(Qt.ItemDataRole.UserRole)))
        self.grid.customContextMenuRequested.connect(self._context_menu)
        self.stack = QStackedWidget()
        self.stack.addWidget(EmptyView(self))
        self.stack.addWidget(self.grid)
        self.panel = SettingsPanel(self)
        central = QWidget()
        row = QHBoxLayout(central)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(0)
        row.addWidget(self.stack, 1)
        line = QFrame()
        line.setFrameShape(QFrame.Shape.VLine)
        line.setStyleSheet("color: palette(mid)")
        row.addWidget(line)
        row.addWidget(self.panel)
        self.setCentralWidget(central)

        # status bar
        self.summary = QLabel()
        self.progress = QProgressBar()
        self.progress.setFixedWidth(160)
        self.progress.setTextVisible(False)
        self.progress.hide()
        self.statusBar().addWidget(self.summary, 1)
        self.statusBar().addPermanentWidget(self.progress)

        # shortcuts
        QShortcut(QKeySequence.StandardKey.Paste, self, activated=self.paste)
        QShortcut(QKeySequence("Ctrl+Return"), self, activated=self.convert_all)
        QShortcut(QKeySequence("Ctrl+Enter"), self, activated=self.convert_all)
        QShortcut(QKeySequence.StandardKey.Delete, self.grid, activated=self.remove_selected)
        self.settings_changed.connect(self._refresh_all)
        self.setAcceptDrops(True)
        self._update_ui()

    # ---------- adding
    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e):
        self.add_paths([Path(u.toLocalFile()) for u in e.mimeData().urls() if u.isLocalFile()])

    def open_dialog(self):
        files, _ = QFileDialog.getOpenFileNames(
            self, "Add images", str(Path.home()),
            "Images (" + " ".join(f"*{e}" for e in sorted(cv.IMAGE_EXTENSIONS)) + ");;All files (*)")
        if files:
            self.add_paths([Path(f) for f in files])

    def paste(self):
        focus = QApplication.focusWidget()
        if isinstance(focus, QSpinBox) or (focus is not None and focus.inherits("QLineEdit")):
            focus.paste() if hasattr(focus, "paste") else None
            return
        mime = QApplication.clipboard().mimeData()
        if mime.hasUrls():
            self.add_paths([Path(u.toLocalFile()) for u in mime.urls() if u.isLocalFile()])
        elif mime.hasImage():
            image = QApplication.clipboard().image()
            folder = Path(tempfile.gettempdir()) / "Pixelpress-pasted"
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / f"Pasted Image {datetime.now():%Y-%m-%d at %H.%M.%S}.png"
            if image.save(str(path), "PNG"):
                self.add_paths([path])
        else:
            QApplication.beep()

    def add_paths(self, paths: list[Path]):
        if not paths:
            return
        self.scanning += 1
        self._update_ui()
        sig = self.signals

        def work():
            found = []
            for f in cv.collect(paths):
                meta = cv.info(f.path)
                if meta:
                    found.append(Item(f.path, f.relative_dir, meta.width, meta.height, meta.frames, f.path.stat().st_size))
            sig.scanned.emit(found)

        self.pool.start(Task(work))

    def _on_scanned(self, found: list[Item]):
        self.scanning -= 1
        known = {str(self.items[i].path.resolve()).lower() for i in self.order}
        for item in found:
            key = str(item.path.resolve()).lower()
            if key in known:
                continue
            known.add(key)
            self.items[item.id] = item
            self.order.append(item.id)
            li = QListWidgetItem()
            li.setData(Qt.ItemDataRole.UserRole, item.id)
            self.list_items[item.id] = li
            self.grid.addItem(li)
            self._refresh(item)
            path, sig, iid = item.path, self.signals, item.id

            def thumb(path=path, iid=iid):
                im = cv.thumbnail(path, 352)
                if im is not None:
                    sig.thumbnail.emit(iid, pil_to_qimage(im))

            self.pool.start(Task(thumb))
        self._update_ui()

    def _on_thumbnail(self, iid: str, image: QImage):
        if iid in self.list_items:
            self.list_items[iid].setData(Qt.ItemDataRole.DecorationRole, QPixmap.fromImage(image))

    # ---------- display
    def _refresh_all(self):
        for iid in self.order:
            self._refresh(self.items[iid])

    def _refresh(self, item: Item):
        li = self.list_items.get(item.id)
        if li is None:
            return
        s = self.prefs.settings
        fmt = cv.FORMATS[s.format]
        dims = f"{item.width}×{item.height}"
        if fmt.icon:
            dims += f" → icon ≤{cv.icon_sizes(fmt, max(item.width, item.height))[-1]}px"
        else:
            tw, th = cv.target_size(item.width, item.height, s)
            if (tw, th) != (item.width, item.height):
                dims += f" → {tw}×{th}"
        if item.status == "done":
            sizes = f"{cv.byte_string(item.size)} → {cv.byte_string(item.output_size)}  {cv.savings(item.size, item.output_size)}"
        elif item.status == "failed":
            sizes = item.error
        else:
            sizes = cv.byte_string(item.size)
        li.setData(TILE_ROLE, (item.path.name, dims, sizes, item.status, item.frames))
        li.setToolTip(f"{item.path}\n{item.error}" if item.error else str(item.path))

    def _update_ui(self):
        self.stack.setCurrentIndex(1 if self.order else 0)
        busy = bool(self.converting)
        self.convert_button.setEnabled(bool(self.order) and not busy)
        self.convert_button.setText("Converting…" if busy else "Convert")
        self.clear_action.setEnabled(bool(self.order) and not busy)
        done = [self.items[i] for i in self.order if self.items[i].status == "done"]
        self.remove_done_action.setEnabled(bool(done) and not busy)
        if not self.order:
            text = "Scanning…" if self.scanning else "No images"
        else:
            n = len(self.order)
            text = f"{n} image{'s' if n != 1 else ''} · {cv.byte_string(sum(self.items[i].size for i in self.order))}"
            if done:
                a, b = sum(i.size for i in done), sum(i.output_size for i in done)
                text = f"{n} images · {len(done)} converted · {cv.byte_string(a)} → {cv.byte_string(b)} ({cv.savings(a, b)})"
            if self.scanning:
                text += " · scanning…"
        self.summary.setText(text)
        self.progress.setVisible(busy)
        if busy:
            self.progress.setMaximum(len(self.batch))
            self.progress.setValue(len(self.batch) - len(self.converting))

    # ---------- list actions
    def _context_menu(self, pos):
        li = self.grid.itemAt(pos)
        if li is None:
            return
        item = self.items[li.data(Qt.ItemDataRole.UserRole)]
        menu = QMenu(self)
        menu.addAction("Compare Before && After…", lambda: self.compare(item.id))
        menu.addAction("Show Original in Folder", lambda: reveal(item.path))
        if item.output:
            menu.addAction("Show Converted in Folder", lambda: reveal(item.output))
        menu.addSeparator()
        remove = menu.addAction("Remove from List", self.remove_selected)
        remove.setEnabled(not self.converting)
        menu.exec(self.grid.viewport().mapToGlobal(pos))

    def compare(self, iid: str):
        if iid in self.items:
            CompareDialog(self, self.items[iid]).exec()

    def _remove(self, ids):
        for iid in ids:
            li = self.list_items.pop(iid, None)
            if li is not None:
                self.grid.takeItem(self.grid.row(li))
            self.items.pop(iid, None)
            if iid in self.order:
                self.order.remove(iid)
        self._update_ui()

    def remove_selected(self):
        if not self.converting:
            self._remove([li.data(Qt.ItemDataRole.UserRole) for li in self.grid.selectedItems()])

    def remove_finished(self):
        self._remove([i for i in self.order if self.items[i].status == "done"])

    def clear(self):
        if not self.converting:
            self._remove(list(self.order))

    # ---------- converting
    def convert_all(self):
        if self.converting or not self.order:
            return
        targets = [self.items[i] for i in self.order if self.items[i].status != "done"] or [self.items[i] for i in self.order]
        s = cv.Settings(**self.prefs.settings.to_dict())
        dest = None if self.prefs.next_to_source else self.prefs.destination
        outputs = cv.output_paths([cv.FoundFile(t.path, t.relative_dir) for t in targets], cv.FORMATS[s.format],
                                  dest, self.prefs.preserve)
        self.batch = [t.id for t in targets]
        self.converting = set(self.batch)
        sig = self.signals
        for item, out in zip(targets, outputs):
            item.status, item.error, item.output = "pending", "", None
            self._refresh(item)

            def work(iid=item.id, src=item.path, out=out):
                sig.status.emit(iid, "working", None, 0, "")
                try:
                    cv.convert(src, out, s)
                    sig.status.emit(iid, "done", out, out.stat().st_size, "")
                except Exception as exc:
                    sig.status.emit(iid, "failed", None, 0, str(exc) or exc.__class__.__name__)

            self.pool.start(Task(work))
        self._update_ui()

    def _on_status(self, iid, status, output, size, error):
        item = self.items.get(iid)
        if item is not None:
            item.status, item.output, item.output_size, item.error = status, output, size, error
            self._refresh(item)
        if status in ("done", "failed"):
            self.converting.discard(iid)
            if not self.converting:
                self._finish()
        self._update_ui()

    def _finish(self):
        done = [self.items[i] for i in self.batch if i in self.items and self.items[i].status == "done"]
        if self.prefs.sound:
            play_done_sound(bool(done))
        if self.prefs.open_when_done and done:
            folder = done[0].output.parent if self.prefs.next_to_source else self.prefs.destination
            open_folder(folder)


def run(argv: list[str]) -> int:
    if sys.platform == "win32":
        try:
            import ctypes

            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("Pixelpress.Pixelpress")
        except Exception:
            pass
    app = QApplication(argv)
    app.setApplicationName(APP_NAME)
    app.setApplicationVersion(VERSION)
    icon = resource("pixelpress.png")
    if icon.exists():
        app.setWindowIcon(QIcon(str(icon)))
    window = MainWindow()
    window.show()
    files = [Path(a) for a in argv[1:] if not a.startswith("-") and Path(a).exists()]
    if files:   # "Open with Pixelpress" / dropping files on the .exe
        window.add_paths(files)
    return app.exec()
