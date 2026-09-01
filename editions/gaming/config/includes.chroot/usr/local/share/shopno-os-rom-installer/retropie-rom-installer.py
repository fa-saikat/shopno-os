#!/usr/bin/env python3
# RetroPie ROM Installer - Version 1.6
#
# Design constraints (matches JaduPc house style):
#   - GTK3, no CSS transitions/gradients/shadows, flat UI
#   - Single file, no external deps beyond GTK3 + stdlib
#
# Changes from 1.5:
#   [feat] Activity log is now toggleable. A "Hide"/"Show" button sits
#          inline next to the "Activity" label. Clicking it hides or
#          reveals the log panel without losing its contents.
#   [feat] Result popup after each install. A Gtk.MessageDialog appears
#          with INFO type on success and ERROR type on failure, showing
#          the filename and detail string. The activity log still receives
#          the same entry as before — the popup is additive.

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib

import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ASSETS_DIR = Path(__file__).resolve().parent / "assets" / "icons"
_LOGO_PATH = Path(__file__).resolve().parent / "assets" / "retropie-installer-logo.png"

ROMS_ROOT = Path.home() / "RetroPie" / "roms"

_CARD_ICON_PX = 128

# system_id -> (display name, roms subfolder, accepted extensions, icon filename, accent color)
# Folder names and extensions per https://retropie.org.uk/docs/
# "system_id":      ("display name",         "rom dir",      ["accepted", "extensions"],                "icon filename",   "accent color")
SYSTEMS = {
    "arcade":       ("Arcade (MAME)",        "arcade",       [".zip", ".chd"],                          "mame.png",        "#ff6644"),
    "dreamcast":    ("Dreamcast",            "dreamcast",    [".cue", ".bin", ".gdi", ".zip", ".7z"],           "dreamcast.png",   "#cc3333"),
    "gba":          ("Gameboy Advance",      "gba",          [".gba", ".zip"],                          "gba.png",         "#B946D1"),
    "megadrive":    ("Sega Genesis/MD",      "megadrive",    [".md", ".bin", ".gen", ".zip"],           "megadrive.png",   "#3388cc"),
    "psx":          ("PlayStation",          "psx",          [".cue", ".bin", ".pbp", ".chd", ".zip"],  "psx.png",         "#444466"),
    "n64":          ("Nintendo 64",          "n64",          [".n64", ".z64", ".v64", ".zip"],          "n64.png",         "#00BFFF"),
}


# File extension from each system's extension list, exclude if it's .zip
ROM_EXTS = set()
for _, _, exts, _, _, in SYSTEMS.values():
    for ext in exts:
        if ext != ".zip":
            ROM_EXTS.add(ext)
# ROM_EXTS = {ext for _, _, exts, _, _ in SYSTEMS.values() for ext in exts if ext != ".zip"}

# Create rom directory if it doesn't exist
def ensure_roms_dir(system_folder: str) -> Path:
    target = ROMS_ROOT / system_folder
    target.mkdir(parents=True, exist_ok=True)
    return target


def unique_dest(target_dir: Path, filename: str) -> Path:
    """Avoid clobbering an existing file with the same name."""
    dest = target_dir / filename
    if not dest.exists():
        return dest
    stem, suffix = dest.stem, dest.suffix
    i = 1
    while True:
        candidate = target_dir / f"{stem}_{i}{suffix}"
        if not candidate.exists():
            return candidate
        i += 1


def zip_contains_roms(zf: zipfile.ZipFile, valid_exts) -> bool:
    for name in zf.namelist():
        if name.endswith("/"):
            continue
        if Path(name).suffix.lower() in valid_exts:
            return True
    return False


def _extract_with_python(src: Path, tmp_dir: Path) -> None:
    """Extract via stdlib zipfile. Raises BadZipFile if not parseable."""
    with zipfile.ZipFile(src) as zf:
        bad = zf.testzip()
        if bad is not None:
            raise zipfile.BadZipFile(f"corrupt entry: {bad}")
        zf.extractall(tmp_dir)


def _extract_with_unzip(src: Path, tmp_dir: Path) -> tuple[bool, str]:
    """
    Fallback extractor using the system `unzip` binary.
    Handles self-extracting stubs, Zip64 quirks, etc.
    Returns (success, error_message).
    """
    try:
        result = subprocess.run(
            ["unzip", "-q", "-o", str(src), "-d", str(tmp_dir)],
            capture_output=True, text=True, timeout=120,
        )
        # unzip exits 1 for warnings but still extracts usable files.
        # Exit 9 = "not a zip / split archive" — do not treat as partial success.
        if result.returncode == 0 or result.returncode == 1:
            return True, ""
        return False, f"exit {result.returncode}"
    except FileNotFoundError:
        return False, "unzip not found"
    except subprocess.TimeoutExpired:
        return False, "timed out"


def _extract_with_7z(src: Path, tmp_dir: Path) -> tuple[bool, str]:
    """
    Extract using 7z (p7zip-full). Handles:
    - Standard zip files
    - Split zip archives (.z01, .z02, ... .zip)
    - Multi-part archives with various naming patterns (.001, .zip.001, etc.)
    - Corrupted/incomplete zips that other tools can't handle

    7z auto-discovers all segments when given any part of the archive.
    Returns (success, error_message).
    """
    try:
        result = subprocess.run(
            ["7z", "x", str(src), f"-o{tmp_dir}", "-y"],
            capture_output=True, text=True, timeout=300,
        )
        # 7z exit codes: 0=ok, 1=warning (non-fatal), 2=fatal, 7=bad args, 8=OOM, 255=stopped
        if result.returncode <= 1:
            return True, ""
        # Check if it's a split archive error - 7z might still extract partial content
        if result.returncode == 2 and "Can not open file as archive" in result.stderr:
            # Try to find if there are any other segments
            for pattern in ["*.z01", "*.001", "*.zip.001", "*.part1.*"]:
                segments = list(src.parent.glob(pattern))
                if segments:
                    # Try with the first segment
                    result2 = subprocess.run(
                        ["7z", "x", str(segments[0]), f"-o{tmp_dir}", "-y"],
                        capture_output=True, text=True, timeout=300,
                    )
                    if result2.returncode <= 1:
                        return True, ""
        return False, f"7z exit {result.returncode}: {result.stderr.strip()}"
    except FileNotFoundError:
        return False, "7z not found — install it with: sudo apt install p7zip-full"
    except subprocess.TimeoutExpired:
        return False, "extraction timed out after 300 s"


def _check_zip_contents(src: Path, rom_exts: set) -> bool:
    """
    Returns True if the archive appears to contain rom-extension files.
    Falls back to True if Python can't parse it (split archive, etc.) —
    extraction will be attempted and the scan will decide.
    """
    try:
        with zipfile.ZipFile(src) as zf:
            return zip_contains_roms(zf, rom_exts)
    except (zipfile.BadZipFile, OSError):
        return True  # can't inspect — optimistically attempt extraction


def install_zip(src: Path, target_dir: Path, valid_exts) -> tuple[bool, str]:
    """
    Extract the full archive to a throwaway dir under /tmp, scan recursively
    for files matching the system's rom extensions, move matches into
    target_dir (flattened). Temp dir is always cleaned up.

    Extraction chain:
      1. Python stdlib zipfile  — fast, handles standard zips
      2. system unzip           — handles self-extracting stubs, Zip64 quirks
      3. 7z (p7zip-full)        — UNIVERSAL FALLBACK: handles split archives,
                                  multi-part archives, corrupt zips, and
                                  any archive that Python/unzip can't handle

    Stage 3 is now attempted whenever both Python and unzip fail, regardless
    of filename patterns. 7z automatically detects split archives and
    multi-part archives using various naming conventions.
    """
    rom_exts = {e for e in valid_exts if e != ".zip"}

    # If no rom extensions exist for this system (arcade-style: zip IS the rom),
    # or a quick listing shows no matching contents, copy the zip as-is.
    if not rom_exts or not _check_zip_contents(src, rom_exts):
        dest = unique_dest(target_dir, src.name)
        try:
            shutil.copy2(src, dest)
            return True, f"copied as-is -> {dest.name}"
        except OSError as e:
            return False, f"I/O error: {e}"

    tmp_dir = None
    try:
        tmp_dir = Path(tempfile.mkdtemp(prefix="jadupc-rom-"))

        # Stage 1: Python zipfile
        try:
            _extract_with_python(src, tmp_dir)
        except (zipfile.BadZipFile, OSError):
            # Stage 2: unzip
            ok, _ = _extract_with_unzip(src, tmp_dir)
            if not ok:
                # Stage 3: 7z — UNIVERSAL FALLBACK
                # Always try 7z regardless of filename patterns
                ok, err = _extract_with_7z(src, tmp_dir)
                if not ok:
                    return False, (
                        f"could not extract '{src.name}' — "
                        f"all extraction methods failed. Last error: {err}"
                    )

        # Scan extracted tree and move matching files into target_dir
        moved = []
        for path in sorted(tmp_dir.rglob("*")):
            if not path.is_file():
                continue
            if path.suffix.lower() not in rom_exts:
                continue
            dest = unique_dest(target_dir, path.name)
            shutil.move(str(path), str(dest))
            moved.append(dest.name)

        if not moved:
            dest = unique_dest(target_dir, src.name)
            shutil.copy2(src, dest)
            return True, f"no matching roms inside, copied as-is -> {dest.name}"

        if len(moved) == 1:
            return True, f"extracted -> {moved[0]}"
        return True, f"extracted {len(moved)} file(s) -> {', '.join(moved)}"

    except OSError as e:
        return False, f"I/O error: {e}"
    finally:
        if tmp_dir is not None:
            shutil.rmtree(tmp_dir, ignore_errors=True)


def install_file(src: Path, system_folder: str, valid_exts) -> tuple[bool, str]:
    target_dir = ensure_roms_dir(system_folder)
    suffix = src.suffix.lower()

    if suffix == ".zip" and ".zip" in set(valid_exts):
        return install_zip(src, target_dir, set(valid_exts))

    if suffix not in valid_exts:
        return False, f"unsupported extension '{suffix}' for this system"

    dest = unique_dest(target_dir, src.name)
    try:
        shutil.copy2(src, dest)
        return True, f"copied -> {dest.name}"
    except OSError as e:
        return False, f"I/O error: {e}"


# ---------------------------------------------------------------------------
# CSS
# ---------------------------------------------------------------------------

def _make_provider(css: str) -> Gtk.CssProvider:
    p = Gtk.CssProvider()
    p.load_from_data(css.encode())
    return p

_WINDOW_CSS = _make_provider("window { background: #0f1419; }")

_HEADER_CSS = _make_provider("""
.title { color: #FFFDFA; }
.subtitle { color: #9999bb; }
""")

_LOG_CSS = _make_provider("""
textview { background: #13192a; color: #ccccee; }
textview text { background: #13192a; color: #ccccee; }
""")

_LOG_TOGGLE_BTN_CSS = _make_provider("""
button {
    background: transparent;
    border: 1px solid #3a4060;
    border-radius: 6px;
    color: #9999bb;
    padding: 2px 10px;
}
button:hover, button:focus {
    background: #1a1f2e;
    border: 1px solid #6666aa;
    color: #ccccee;
    outline: none;
}
""")

_CARD_CSS = _make_provider("""
button {
    background: #1a1f2e;
    border: 2px solid #2a2f45;
    border-radius: 14px;
    color: white;
}
button:hover, button:focus {
    background: #1e2436;
    border: 2px solid #ffffff;
    outline: none;
    box-shadow: 0 0 18px rgba(139, 123, 200, 0.55);
}
""")


# ---------------------------------------------------------------------------
# Widgets
# ---------------------------------------------------------------------------

class SystemCard(Gtk.Button):
    def __init__(self, system_id: str, display_name: str, icon_file: str, on_pick):
        super().__init__()
        self.system_id = system_id
        self.on_pick = on_pick

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_halign(Gtk.Align.CENTER)
        box.set_valign(Gtk.Align.CENTER)
        box.set_margin_top(20)
        box.set_margin_bottom(20)

        icon = Gtk.Image()
        loaded = False
        if icon_file:
            icon_path = ASSETS_DIR / icon_file
            if icon_path.exists():
                try:
                    pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                        str(icon_path), _CARD_ICON_PX, _CARD_ICON_PX, preserve_aspect_ratio=True
                    )
                    icon.set_from_pixbuf(pixbuf)
                    loaded = True
                except Exception:
                    pass  # fall through to GTK icon
        if not loaded:
            icon.set_from_icon_name("applications-games", Gtk.IconSize.DIALOG)
            icon.set_pixel_size(_CARD_ICON_PX)

        label = Gtk.Label(label=display_name)
        label.set_line_wrap(True)
        label.set_justify(Gtk.Justification.CENTER)
        label.set_markup(f'<span weight="bold">{display_name}</span>')

        box.pack_start(icon, False, False, 0)
        box.pack_start(label, False, False, 0)
        self.add(box)

        self.set_size_request(260, 220)
        self.set_can_focus(True)
        self.get_style_context().add_provider(
            _CARD_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
        self.connect("clicked", lambda b: self.on_pick(self.system_id, display_name))


class MainWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="JaduPc 3 in 1 GAMING ROM Installer")
        self.set_default_size(1152, 864)
        self.set_position(Gtk.WindowPosition.CENTER)

        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), _WINDOW_CSS,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        root.set_margin_top(20)
        root.set_margin_bottom(20)
        root.set_margin_start(20)
        root.set_margin_end(20)

        header_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)

        if _LOGO_PATH.exists():
            try:
                logo_pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                    str(_LOGO_PATH), -1, 48, preserve_aspect_ratio=True
                )
                logo_img = Gtk.Image.new_from_pixbuf(logo_pb)
                logo_img.set_valign(Gtk.Align.CENTER)
                header_box.pack_start(logo_img, False, False, 0)
            except Exception:
                pass  # fall through to text-only header

        title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        title_box.set_valign(Gtk.Align.CENTER)

        title = Gtk.Label()
        title.set_markup('<span size="x-large" weight="bold" foreground="#FFFDFA">Install more roms</span>')
        title.set_halign(Gtk.Align.START)
        title.get_style_context().add_class("title")
        title.get_style_context().add_provider(_HEADER_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER)

        subtitle = Gtk.Label()
        subtitle.set_markup(f'<span foreground="#9999bb">Pick a system, choose files, ROMs go to {ROMS_ROOT}/&lt;system&gt;</span>')
        subtitle.set_halign(Gtk.Align.START)

        title_box.pack_start(title, False, False, 0)
        title_box.pack_start(subtitle, False, False, 0)
        header_box.pack_start(title_box, False, False, 0)
        header_box.set_margin_bottom(16)

        root.pack_start(header_box, False, False, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        self.grid = Gtk.FlowBox()
        self.grid.set_valign(Gtk.Align.START)
        self.grid.set_max_children_per_line(4)
        self.grid.set_selection_mode(Gtk.SelectionMode.NONE)
        self.grid.set_column_spacing(16)
        self.grid.set_row_spacing(16)

        for system_id, (display_name, _folder, _exts, icon_file, _accent) in SYSTEMS.items():
            card = SystemCard(system_id, display_name, icon_file, self.on_system_picked)
            self.grid.add(card)
            # Gtk.FlowBox wraps every child in an auto-generated Gtk.FlowBoxChild,
            # which is itself focusable. With SelectionMode.NONE that wrapper has
            # no visual selection state, so arrow-key navigation ends up toggling
            # focus between the wrapper and the button — one extra keypress per
            # card. Disabling focus on the wrapper sends focus straight to the
            # button inside it.
            card.get_parent().set_can_focus(False)

        scroll.add(self.grid)
        root.pack_start(scroll, True, True, 0)

        # log panel header: "Activity" label + toggle button, inline left-aligned
        log_header_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        log_header_box.set_margin_top(16)

        log_label = Gtk.Label()
        log_label.set_markup('<span foreground="#9999bb">Activity</span>')
        log_label.set_halign(Gtk.Align.START)
        log_label.set_valign(Gtk.Align.CENTER)
        log_header_box.pack_start(log_label, False, False, 0)

        self.log_toggle_btn = Gtk.Button(label="Hide")
        self.log_toggle_btn.set_valign(Gtk.Align.CENTER)
        self.log_toggle_btn.set_can_focus(True)
        self.log_toggle_btn.get_style_context().add_provider(
            _LOG_TOGGLE_BTN_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
        self.log_toggle_btn.connect("clicked", self._on_log_toggle)
        log_header_box.pack_start(self.log_toggle_btn, False, False, 0)

        root.pack_start(log_header_box, False, False, 0)

        self.log_scroll = Gtk.ScrolledWindow()
        self.log_scroll.set_size_request(-1, 140)
        self.log_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_cursor_visible(False)
        self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.log_view.get_style_context().add_provider(_LOG_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER)
        self.log_buffer = self.log_view.get_buffer()

        self.log_scroll.add(self.log_view)
        root.pack_start(self.log_scroll, False, False, 0)

        self.add(root)

    def log(self, message: str) -> None:
        end_iter = self.log_buffer.get_end_iter()
        self.log_buffer.insert(end_iter, message + "\n")
        GLib.idle_add(self._scroll_log_to_end)

    def _scroll_log_to_end(self) -> bool:
        mark = self.log_buffer.get_insert()
        self.log_view.scroll_mark_onscreen(mark)
        return False

    def _on_log_toggle(self, button) -> None:
        if self.log_scroll.get_visible():
            self.log_scroll.hide()
            self.log_toggle_btn.set_label("Show")
        else:
            self.log_scroll.show()
            self.log_toggle_btn.set_label("Hide")

    def _show_result_popup(self, ok: bool, title: str, detail: str) -> None:
        if ok:
            msg_type = Gtk.MessageType.INFO
            buttons = Gtk.ButtonsType.OK
        else:
            msg_type = Gtk.MessageType.ERROR
            buttons = Gtk.ButtonsType.CLOSE

        dialog = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=msg_type,
            buttons=buttons,
            text=title,
        )
        dialog.format_secondary_text(detail)
        dialog.run()
        dialog.destroy()

    def on_system_picked(self, system_id: str, display_name: str) -> None:
        _name, folder, exts, _icon_file, _accent = SYSTEMS[system_id]

        dialog = Gtk.FileChooserDialog(
            title=f"Select ROMs for {display_name}",
            parent=self,
            action=Gtk.FileChooserAction.OPEN,
        )
        dialog.add_buttons(
            "Cancel", Gtk.ResponseType.CANCEL,
            "Open", Gtk.ResponseType.OK,
        )
        dialog.set_select_multiple(False)

        file_filter = Gtk.FileFilter()
        file_filter.set_name("ROM files")
        for ext in exts:
            file_filter.add_pattern(f"*{ext}")
            file_filter.add_pattern(f"*{ext.upper()}")
        dialog.add_filter(file_filter)

        all_filter = Gtk.FileFilter()
        all_filter.set_name("All files")
        all_filter.add_pattern("*")
        dialog.add_filter(all_filter)

        response = dialog.run()
        path = dialog.get_filename() if response == Gtk.ResponseType.OK else None
        dialog.destroy()

        if not path:
            return

        src = Path(path)
        self.log(f"--- {display_name}: {src.name} ---")
        ok, detail = install_file(src, folder, exts)
        status = "OK" if ok else "FAIL"
        self.log(f"[{status}] {detail}")

        if ok:
            popup_title = f"{src.name} installed"
        else:
            popup_title = f"Failed to install {src.name}"
        self._show_result_popup(ok, popup_title, detail)


def main():
    win = MainWindow()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        crash_log = Path(__file__).resolve().parent / "retropie-rom-installer-crash.log"
        with open(crash_log, "a") as f:
            f.write("=" * 60 + "\n")
            traceback.print_exc(file=f)
        traceback.print_exc()
        print(f"Crash details written to {crash_log}", file=sys.stderr)
        sys.exit(1)
