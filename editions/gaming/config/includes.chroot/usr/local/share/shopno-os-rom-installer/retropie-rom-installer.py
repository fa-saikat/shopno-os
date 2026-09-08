#!/usr/bin/env python3
# RetroPie ROM Installer - Version 2.1
#
# Design constraints (matches JaduPc house style):
#   - GTK3, no CSS transitions/gradients/shadows, flat UI
#   - Single file, no external deps beyond GTK3 + stdlib
#
# Changes from 2.0:
#   [fix] Uninstall game list background was system-theme-dependent (white
#         background + white row text on light themes = invisible list).
#         Root cause: the CSS provider for "row" was attached only to the
#         GtkListBox's own style context, whose CSS node type is "list", not
#         "row" — so the rule never matched anything and rows silently fell
#         back to the GTK theme. Fixed by attaching the row provider to each
#         row's own style context (_add_row_style()) and giving the listbox
#         itself an explicit "list" background rule (_GAME_LIST_CSS).
#
# Changes from 1.1:
#   [feat] Uninstall page: Install/Uninstall toggle buttons in the header
#          switch between pages via Gtk.Stack. Uninstall page shows a system
#          card grid; selecting a system loads a game list (Gtk.ListBox, one
#          row per rom stem found in roms/<system>/). Selecting a game shows
#          a confirmation dialog then deletes all files in the rom dir whose
#          stem matches (covers .cue+.bin pairs, etc.). Back button returns
#          to the system grid.
#   [feat] --uninstall CLI flag: opens directly to the uninstall page.
#   [feat] Activity log is now toggleable via a Hide/Show button inline
#          next to the "Activity" label.
#   [feat] Result popup (Gtk.MessageDialog) after each install or uninstall:
#          INFO on success, ERROR on failure.
#   [fix]  Zip extraction chain: Python zipfile -> unzip -> 7z. 7z is tried
#          unconditionally as stage 3 — handles split archives, multi-part
#          archives, and any format the first two reject.
#   [fix]  Arrow-key double-step in FlowBox: FlowBoxChild wrapper focus
#          disabled so arrow keys land on the card button directly.
#   [fix]  Removed dead ROM_EXTS module-level set (was computed, never used).
#   [fix]  Removed fragile glob fallback inside _extract_with_7z that could
#          match segments from a different game in the same folder.
#   [change] File chooser is single-selection only.
#   [feat]  Card icons 128px (_CARD_ICON_PX), card size 260x220, grid 4 cols.

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
SAVES_ROOT = Path.home() / "RetroPie" / "saves"

_CARD_ICON_PX = 128

# system_id -> (display name, roms subfolder, accepted extensions, icon filename, accent color)
# Folder names and extensions per https://retropie.org.uk/docs/
SYSTEMS = {
    "arcade":    ("Arcade (MAME)",  "arcade",     [".zip", ".chd"],                         "mame.png",       "#ff6644"),
    "dreamcast": ("Dreamcast",      "dreamcast",  [".cue", ".bin", ".gdi", ".zip"],          "dreamcast.png",  "#cc3333"),
    "gba":       ("Gameboy Advance","gba",         [".gba", ".zip"],                         "gba.png",        "#B946D1"),
    "megadrive": ("Sega Genesis/MD","megadrive",   [".md", ".bin", ".gen", ".zip"],          "megadrive.png",  "#3388cc"),
    "psx":       ("PlayStation",    "psx",         [".cue", ".bin", ".pbp", ".chd", ".zip"], "psx.png",        "#444466"),
    "n64":       ("Nintendo 64",    "n64",         [".n64", ".z64", ".v64", ".zip"],         "n64.png",        "#00BFFF"),
}


# ---------------------------------------------------------------------------
# File logic — install
# ---------------------------------------------------------------------------

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


def zip_contains_roms(zf: zipfile.ZipFile, valid_exts: set) -> bool:
    for name in zf.namelist():
        if name.endswith("/"):
            continue
        if Path(name).suffix.lower() in valid_exts:
            return True
    return False


def _check_zip_contents(src: Path, rom_exts: set) -> bool:
    """
    Quick listing to decide if extraction is needed.
    Falls back to True if Python can't parse the zip (split archive, etc.)
    so that the extraction chain still runs.
    """
    try:
        with zipfile.ZipFile(src) as zf:
            return zip_contains_roms(zf, rom_exts)
    except (zipfile.BadZipFile, OSError):
        return True


def _extract_with_python(src: Path, tmp_dir: Path) -> None:
    """Extract via stdlib zipfile. Raises BadZipFile if not parseable."""
    with zipfile.ZipFile(src) as zf:
        bad = zf.testzip()
        if bad is not None:
            raise zipfile.BadZipFile(f"corrupt entry: {bad}")
        zf.extractall(tmp_dir)


def _extract_with_unzip(src: Path, tmp_dir: Path) -> tuple[bool, str]:
    """
    Fallback using system unzip binary.
    Exit 0 = ok, exit 1 = warnings but usable, exit 9 = not a zip / split.
    Returns (success, error_message).
    """
    try:
        result = subprocess.run(
            ["unzip", "-q", "-o", str(src), "-d", str(tmp_dir)],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode == 0 or result.returncode == 1:
            return True, ""
        return False, f"exit {result.returncode}"
    except FileNotFoundError:
        return False, "unzip not found"
    except subprocess.TimeoutExpired:
        return False, "timed out"


def _extract_with_7z(src: Path, tmp_dir: Path) -> tuple[bool, str]:
    """
    Final fallback using 7z (p7zip-full). Handles split archives,
    multi-part archives, and formats the other two extractors reject.
    7z auto-discovers all segments when given any part of the archive.
    Returns (success, error_message).
    """
    try:
        result = subprocess.run(
            ["7z", "x", str(src), f"-o{tmp_dir}", "-y"],
            capture_output=True,
            text=True,
            timeout=300,
        )
        # 7z exit codes: 0=ok, 1=warning (non-fatal), 2+=fatal
        if result.returncode <= 1:
            return True, ""
        return False, f"7z exit {result.returncode}: {result.stderr.strip()}"
    except FileNotFoundError:
        return False, "7z not found — install it with: sudo apt install p7zip-full"
    except subprocess.TimeoutExpired:
        return False, "extraction timed out after 300 s"


def install_zip(src: Path, target_dir: Path, valid_exts: set) -> tuple[bool, str]:
    """
    Extraction chain:
      1. Python stdlib zipfile  (fast, zero deps, handles standard zips)
      2. system unzip           (handles self-extracting stubs, Zip64 quirks)
      3. 7z                     (handles split archives and everything else)

    The extracted tree is scanned recursively; matching files are moved
    into target_dir (flattened). Temp dir is always cleaned up.
    """
    rom_exts = {e for e in valid_exts if e != ".zip"}

    # If no rom extensions exist for this system (arcade: zip IS the rom),
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
                # Stage 3: 7z — tried unconditionally, handles all edge cases
                ok, err = _extract_with_7z(src, tmp_dir)
                if not ok:
                    return False, err

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


def install_file(src: Path, system_folder: str, valid_exts: list) -> tuple[bool, str]:
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
# File logic — uninstall
# ---------------------------------------------------------------------------

def list_installed_games(system_folder: str) -> list[str]:
    """
    Return a sorted list of unique rom stems found in roms/<system>/.
    A stem is the filename without extension, e.g. "Sonic The Hedgehog (USA)".
    Multiple files with the same stem (e.g. .cue + .bin) appear as one entry.
    Returns an empty list if the directory doesn't exist or is empty.
    """
    rom_dir = ROMS_ROOT / system_folder
    if not rom_dir.exists():
        return []

    stems = set()
    for f in rom_dir.iterdir():
        if f.is_file():
            stems.add(f.stem)

    return sorted(stems)


def uninstall_game(system_folder: str, game_stem: str) -> tuple[bool, str]:
    """
    Delete all files in roms/<system>/ whose stem matches game_stem exactly.
    This covers multi-file roms (e.g. Gran Turismo 2.cue + Gran Turismo 2.bin).
    Returns (success, detail_message).
    """
    rom_dir = ROMS_ROOT / system_folder
    if not rom_dir.exists():
        return False, f"rom directory not found: {rom_dir}"

    deleted = []
    errors = []

    for f in rom_dir.iterdir():
        if not f.is_file():
            continue
        if f.stem != game_stem:
            continue
        try:
            f.unlink()
            deleted.append(f.name)
        except OSError as e:
            errors.append(f"{f.name}: {e}")

    if errors:
        return False, "errors during deletion: " + ", ".join(errors)

    if not deleted:
        return False, f"no files found for '{game_stem}' in {rom_dir}"

    return True, f"deleted {len(deleted)} file(s): {', '.join(deleted)}"


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

# Active nav button (current page)
_NAV_ACTIVE_CSS = _make_provider("""
button {
    background: #8B7BC8;
    border: 2px solid #8B7BC8;
    border-radius: 8px;
    color: #ffffff;
    font-weight: bold;
    padding: 6px 20px;
}
button:hover, button:focus {
    background: #7a6ab5;
    border: 2px solid #7a6ab5;
    outline: none;
}
""")

# Inactive nav button (other page)
_NAV_INACTIVE_CSS = _make_provider("""
button {
    background: transparent;
    border: 2px solid #3a4060;
    border-radius: 8px;
    color: #9999bb;
    padding: 6px 20px;
}
button:hover, button:focus {
    background: #1a1f2e;
    border: 2px solid #6666aa;
    color: #ccccee;
    outline: none;
}
""")

# Back button on the game list page
_BACK_BTN_CSS = _make_provider("""
button {
    background: transparent;
    border: 2px solid #3a4060;
    border-radius: 8px;
    color: #9999bb;
    padding: 4px 14px;
}
button:hover, button:focus {
    background: #1a1f2e;
    border: 2px solid #6666aa;
    color: #ccccee;
    outline: none;
}
""")

# Game list container (GtkListBox's own CSS node is "list") — must be styled
# explicitly or it falls back to the system theme background (white on light
# themes), making white row text unreadable.
_GAME_LIST_CSS = _make_provider("""
list {
    background: #13192a;
}
""")

# Individual game row in the uninstall list.
# NOTE: a GtkStyleContext provider only matches the node type of the widget
# it is attached to. Adding this to the listbox itself does NOT style child
# rows (listbox node type is "list", not "row") — it must be attached to
# each row's own style context. See _add_row_style() below.
_GAME_ROW_CSS = _make_provider("""
row {
    background: #1a1f2e;
    border-radius: 8px;
    padding: 10px 16px;
    color: #FFFDFA;
}
row:hover, row:focus {
    background: #252a3a;
    outline: none;
}
row:selected {
    background: #2a1f3a;
    outline: none;
}
""")


def _add_row_style(row: Gtk.ListBoxRow) -> None:
    """Attach the own-color row background/selection styling to a single row.
    Must be called per-row — see note on _GAME_ROW_CSS above."""
    row.get_style_context().add_provider(
        _GAME_ROW_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
    )

# Confirm delete button inside the confirmation dialog
_DELETE_BTN_CSS = _make_provider("""
button {
    background: #8B3333;
    border: 2px solid #8B3333;
    border-radius: 8px;
    color: #ffffff;
    padding: 6px 20px;
}
button:hover, button:focus {
    background: #a03a3a;
    border: 2px solid #a03a3a;
    outline: none;
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
                        str(icon_path), _CARD_ICON_PX, _CARD_ICON_PX,
                        preserve_aspect_ratio=True
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


# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

class MainWindow(Gtk.Window):
    def __init__(self, start_page: str = "install"):
        super().__init__(title="JaduPc 3 in 1 GAMING ROM Installer")
        self.set_default_size(1152, 864)
        self.set_position(Gtk.WindowPosition.CENTER)

        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), _WINDOW_CSS,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        # Root layout
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        root.set_margin_top(20)
        root.set_margin_bottom(20)
        root.set_margin_start(20)
        root.set_margin_end(20)

        # ── Header ───────────────────────────────────────────────────────────
        header_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        header_box.set_margin_bottom(16)

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

        title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        title_box.set_valign(Gtk.Align.CENTER)

        title = Gtk.Label()
        title.set_markup('<span size="x-large" weight="bold" foreground="#FFFDFA">ROM Manager</span>')
        title.set_halign(Gtk.Align.START)

        subtitle = Gtk.Label()
        subtitle.set_markup(f'<span foreground="#9999bb">ROMs stored in {ROMS_ROOT}</span>')
        subtitle.set_halign(Gtk.Align.START)

        title_box.pack_start(title, False, False, 0)
        title_box.pack_start(subtitle, False, False, 0)
        header_box.pack_start(title_box, False, False, 0)

        # Nav buttons — Install | Uninstall, pinned to the right of the header
        nav_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        nav_box.set_valign(Gtk.Align.CENTER)

        self._install_nav_btn = Gtk.Button(label="Install")
        self._install_nav_btn.set_can_focus(True)
        self._install_nav_btn.connect("clicked", lambda _: self._switch_to("install"))

        self._uninstall_nav_btn = Gtk.Button(label="Uninstall")
        self._uninstall_nav_btn.set_can_focus(True)
        self._uninstall_nav_btn.connect("clicked", lambda _: self._switch_to("uninstall"))

        nav_box.pack_start(self._install_nav_btn, False, False, 0)
        nav_box.pack_start(self._uninstall_nav_btn, False, False, 0)
        header_box.pack_end(nav_box, False, False, 0)

        root.pack_start(header_box, False, False, 0)

        # ── Page stack ───────────────────────────────────────────────────────
        self._stack = Gtk.Stack()
        self._stack.set_transition_type(Gtk.StackTransitionType.NONE)
        self._stack.set_hexpand(True)
        self._stack.set_vexpand(True)

        self._stack.add_named(self._build_install_page(), "install")
        self._stack.add_named(self._build_uninstall_page(), "uninstall")

        root.pack_start(self._stack, True, True, 0)

        # ── Activity log ─────────────────────────────────────────────────────
        log_header_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        log_header_box.set_margin_top(16)

        log_label = Gtk.Label()
        log_label.set_markup('<span foreground="#9999bb">Activity</span>')
        log_label.set_halign(Gtk.Align.START)
        log_label.set_valign(Gtk.Align.CENTER)
        log_header_box.pack_start(log_label, False, False, 0)

        self._log_toggle_btn = Gtk.Button(label="Hide")
        self._log_toggle_btn.set_valign(Gtk.Align.CENTER)
        self._log_toggle_btn.set_can_focus(True)
        self._log_toggle_btn.get_style_context().add_provider(
            _LOG_TOGGLE_BTN_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
        self._log_toggle_btn.connect("clicked", self._on_log_toggle)
        log_header_box.pack_start(self._log_toggle_btn, False, False, 0)

        root.pack_start(log_header_box, False, False, 0)

        self._log_scroll = Gtk.ScrolledWindow()
        self._log_scroll.set_size_request(-1, 140)
        self._log_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        self._log_view = Gtk.TextView()
        self._log_view.set_editable(False)
        self._log_view.set_cursor_visible(False)
        self._log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self._log_view.get_style_context().add_provider(
            _LOG_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
        self._log_buffer = self._log_view.get_buffer()

        self._log_scroll.add(self._log_view)
        root.pack_start(self._log_scroll, False, False, 0)

        self.add(root)

        # Apply starting page and nav button styles
        self._switch_to(start_page)

    # ── Page builders ─────────────────────────────────────────────────────────

    def _build_install_page(self) -> Gtk.Box:
        """Install page: scrollable system card grid."""
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        grid = Gtk.FlowBox()
        grid.set_valign(Gtk.Align.START)
        grid.set_max_children_per_line(4)
        grid.set_selection_mode(Gtk.SelectionMode.NONE)
        grid.set_column_spacing(16)
        grid.set_row_spacing(16)

        for system_id, (display_name, _folder, _exts, icon_file, _accent) in SYSTEMS.items():
            card = SystemCard(system_id, display_name, icon_file, self._on_install_system_picked)
            grid.add(card)
            # Disable focus on the FlowBoxChild wrapper so arrow-key navigation
            # lands directly on the card button, not the invisible wrapper first.
            card.get_parent().set_can_focus(False)

        scroll.add(grid)
        page.pack_start(scroll, True, True, 0)
        return page

    def _build_uninstall_page(self) -> Gtk.Stack:
        """
        Uninstall page: inner Gtk.Stack with two children:
          'systems' — system card grid (same style as install)
          'games'   — game list for a selected system + back button
        """
        self._uninstall_stack = Gtk.Stack()
        self._uninstall_stack.set_transition_type(Gtk.StackTransitionType.NONE)

        # ── Systems view ──────────────────────────────────────────────────────
        systems_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)

        sys_scroll = Gtk.ScrolledWindow()
        sys_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        sys_grid = Gtk.FlowBox()
        sys_grid.set_valign(Gtk.Align.START)
        sys_grid.set_max_children_per_line(4)
        sys_grid.set_selection_mode(Gtk.SelectionMode.NONE)
        sys_grid.set_column_spacing(16)
        sys_grid.set_row_spacing(16)

        for system_id, (display_name, _folder, _exts, icon_file, _accent) in SYSTEMS.items():
            card = SystemCard(system_id, display_name, icon_file, self._on_uninstall_system_picked)
            sys_grid.add(card)
            card.get_parent().set_can_focus(False)

        sys_scroll.add(sys_grid)
        systems_page.pack_start(sys_scroll, True, True, 0)
        self._uninstall_stack.add_named(systems_page, "systems")

        # ── Games view ────────────────────────────────────────────────────────
        games_page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)

        # Top bar: back button + system name label
        games_topbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        games_topbar.set_margin_bottom(12)

        back_btn = Gtk.Button(label="← Back")
        back_btn.set_valign(Gtk.Align.CENTER)
        back_btn.set_can_focus(True)
        back_btn.get_style_context().add_provider(
            _BACK_BTN_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
        back_btn.connect("clicked", lambda _: self._uninstall_stack.set_visible_child_name("systems"))
        games_topbar.pack_start(back_btn, False, False, 0)

        self._games_system_label = Gtk.Label()
        self._games_system_label.set_halign(Gtk.Align.START)
        self._games_system_label.set_valign(Gtk.Align.CENTER)
        games_topbar.pack_start(self._games_system_label, False, False, 0)

        games_page.pack_start(games_topbar, False, False, 0)

        # Game list
        games_scroll = Gtk.ScrolledWindow()
        games_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        self._games_listbox = Gtk.ListBox()
        self._games_listbox.set_selection_mode(Gtk.SelectionMode.SINGLE)
        self._games_listbox.get_style_context().add_provider(
            _GAME_LIST_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
        self._games_listbox.connect("row-activated", self._on_game_row_activated)

        games_scroll.add(self._games_listbox)
        games_page.pack_start(games_scroll, True, True, 0)

        self._uninstall_stack.add_named(games_page, "games")

        return self._uninstall_stack

    # ── Navigation ────────────────────────────────────────────────────────────

    def _switch_to(self, page: str) -> None:
        """Switch the main stack page and update nav button styles."""
        self._stack.set_visible_child_name(page)

        if page == "install":
            self._install_nav_btn.get_style_context().remove_provider(_NAV_INACTIVE_CSS)
            self._install_nav_btn.get_style_context().add_provider(
                _NAV_ACTIVE_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
            )
            self._uninstall_nav_btn.get_style_context().remove_provider(_NAV_ACTIVE_CSS)
            self._uninstall_nav_btn.get_style_context().add_provider(
                _NAV_INACTIVE_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
            )
        else:
            self._uninstall_nav_btn.get_style_context().remove_provider(_NAV_INACTIVE_CSS)
            self._uninstall_nav_btn.get_style_context().add_provider(
                _NAV_ACTIVE_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
            )
            self._install_nav_btn.get_style_context().remove_provider(_NAV_ACTIVE_CSS)
            self._install_nav_btn.get_style_context().add_provider(
                _NAV_INACTIVE_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
            )

    # ── Install handlers ──────────────────────────────────────────────────────

    def _on_install_system_picked(self, system_id: str, display_name: str) -> None:
        _name, folder, exts, _icon_file, _accent = SYSTEMS[system_id]

        dialog = Gtk.FileChooserDialog(
            title=f"Select ROM for {display_name}",
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
        self._log(f"--- {display_name}: {src.name} ---")
        ok, detail = install_file(src, folder, exts)
        self._log(f"[{'OK' if ok else 'FAIL'}] {detail}")

        if ok:
            self._show_result_popup(ok, f"{src.name} installed", detail)
        else:
            self._show_result_popup(ok, f"Failed to install {src.name}", detail)

    # ── Uninstall handlers ────────────────────────────────────────────────────

    def _on_uninstall_system_picked(self, system_id: str, display_name: str) -> None:
        """Load the game list for the selected system and switch to the games view."""
        _name, folder, _exts, _icon, _accent = SYSTEMS[system_id]

        games = list_installed_games(folder)

        # Update the system label in the games topbar
        self._games_system_label.set_markup(
            f'<span size="large" weight="bold" foreground="#FFFDFA">{display_name}</span>'
        )

        # Clear existing rows
        for child in self._games_listbox.get_children():
            self._games_listbox.remove(child)

        if not games:
            # Show a placeholder row when no roms are found
            empty_row = Gtk.ListBoxRow()
            empty_row.set_activatable(False)
            _add_row_style(empty_row)
            empty_label = Gtk.Label()
            empty_label.set_markup('<span foreground="#555570">No ROMs installed for this system.</span>')
            empty_label.set_margin_top(16)
            empty_label.set_margin_bottom(16)
            empty_label.set_margin_start(16)
            empty_row.add(empty_label)
            self._games_listbox.add(empty_row)
        else:
            for game_stem in games:
                row = Gtk.ListBoxRow()
                _add_row_style(row)
                # Store both the stem and the folder on the row for the delete handler
                row.system_folder = folder
                row.game_stem = game_stem
                row.display_name = display_name

                row_label = Gtk.Label(label=game_stem)
                row_label.set_halign(Gtk.Align.START)
                row_label.set_margin_top(10)
                row_label.set_margin_bottom(10)
                row_label.set_margin_start(16)
                row_label.set_markup(f'<span foreground="#FFFDFA">{GLib.markup_escape_text(game_stem)}</span>')
                row.add(row_label)
                self._games_listbox.add(row)

        self._games_listbox.show_all()
        self._uninstall_stack.set_visible_child_name("games")

    def _on_game_row_activated(self, listbox, row) -> None:
        """Confirmation dialog → delete → refresh list."""
        # Rows without system_folder are the 'no roms' placeholder
        if not hasattr(row, "system_folder"):
            return

        game_stem = row.game_stem
        display_name = row.display_name
        system_folder = row.system_folder

        confirmed = self._show_confirm_dialog(
            title=f"Delete {game_stem}?",
            message=(
                f"This will delete all files for\n"
                f"<b>{GLib.markup_escape_text(game_stem)}</b>\n"
                f"from {display_name}.\n\n"
                f"This cannot be undone."
            ),
        )

        if not confirmed:
            return

        self._log(f"--- Uninstall [{display_name}] {game_stem} ---")
        ok, detail = uninstall_game(system_folder, game_stem)
        self._log(f"[{'OK' if ok else 'FAIL'}] {detail}")

        if ok:
            self._show_result_popup(ok, f"{game_stem} removed", detail)
            # Refresh the game list so the deleted entry disappears
            self._on_uninstall_system_picked(
                # find the system_id from the folder name
                next(sid for sid, v in SYSTEMS.items() if v[1] == system_folder),
                display_name,
            )
        else:
            self._show_result_popup(ok, f"Failed to remove {game_stem}", detail)

    # ── Log ───────────────────────────────────────────────────────────────────

    def _log(self, message: str) -> None:
        end_iter = self._log_buffer.get_end_iter()
        self._log_buffer.insert(end_iter, message + "\n")
        GLib.idle_add(self._scroll_log_to_end)

    def _scroll_log_to_end(self) -> bool:
        mark = self._log_buffer.get_insert()
        self._log_view.scroll_mark_onscreen(mark)
        return False

    def _on_log_toggle(self, _button) -> None:
        if self._log_scroll.get_visible():
            self._log_scroll.hide()
            self._log_toggle_btn.set_label("Show")
        else:
            self._log_scroll.show()
            self._log_toggle_btn.set_label("Hide")

    # ── Dialogs ───────────────────────────────────────────────────────────────

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

    def _show_confirm_dialog(self, title: str, message: str) -> bool:
        """
        Show a confirmation dialog with a styled Delete button and a Cancel button.
        Returns True if the user confirms, False otherwise.
        """
        dialog = Gtk.Dialog(title=title, transient_for=self, modal=True)
        dialog.set_default_size(380, -1)

        content = dialog.get_content_area()
        content.set_margin_top(20)
        content.set_margin_bottom(10)
        content.set_margin_start(20)
        content.set_margin_end(20)
        content.set_spacing(12)

        msg_label = Gtk.Label()
        msg_label.set_markup(message)
        msg_label.set_halign(Gtk.Align.START)
        msg_label.set_justify(Gtk.Justification.LEFT)
        msg_label.set_line_wrap(True)
        content.pack_start(msg_label, False, False, 0)

        # Button row
        btn_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        btn_row.set_halign(Gtk.Align.END)
        btn_row.set_margin_top(8)
        btn_row.set_margin_bottom(10)

        cancel_btn = Gtk.Button(label="Cancel")
        cancel_btn.get_style_context().add_provider(
            _LOG_TOGGLE_BTN_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
        cancel_btn.connect("clicked", lambda _: dialog.response(Gtk.ResponseType.CANCEL))
        btn_row.pack_start(cancel_btn, False, False, 0)

        delete_btn = Gtk.Button(label="Delete")
        delete_btn.get_style_context().add_provider(
            _DELETE_BTN_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
        delete_btn.connect("clicked", lambda _: dialog.response(Gtk.ResponseType.OK))
        btn_row.pack_start(delete_btn, False, False, 0)

        content.pack_start(btn_row, False, False, 0)
        content.show_all()

        response = dialog.run()
        dialog.destroy()
        return response == Gtk.ResponseType.OK


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    # --uninstall flag: open directly to the uninstall page
    start_page = "install"
    if "--uninstall" in sys.argv:
        start_page = "uninstall"

    win = MainWindow(start_page=start_page)
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
