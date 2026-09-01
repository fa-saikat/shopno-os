#!/usr/bin/env python3
# JaduPc Mode Selector - Version 8.8 (Seamless black overlay)
# No gradients, no shadows, no CSS transitions, no slide animations.
#
# Changes from 8.7:
#   [feat] Black overlay page: when launching external apps the window switches
#          to a solid black page immediately, stays fullscreen, and only hides
#          after a per‑target delay. This masks the desktop during app startup.
#   [feat] Reverse transition (app → selector) also uses the black page for a
#          single‑frame black‑to‑main cut, hiding the desktop behind.
#   [refactor] ModeButton and AppShortcut now accept `hide_delay`.
#          Desktop = 0s (instant hide), Gaming = 2s, Kodi = 4s, browsers = 3s.

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib, Gio
import datetime
import os
import signal
import subprocess
import sys
from pathlib import Path

ASSETS_DIR   = Path(__file__).resolve().parent / "assets" / "icons"
_DBUS_NAME   = "org.jadupc.ModeSelector"

# session and state control
_JADUPC_DIR  = Path(f"/run/user/{os.getuid()}/jadupc")
_PID_FILE    = _JADUPC_DIR / "mode-selector.pid"
_STATE_FILE  = _JADUPC_DIR / "mode-selector.state"

# mode state definition that is written to _STATE_FILE
MODE_SELECTOR = 0
MODE_DESKTOP  = 1
MODE_GAMING   = 2
MODE_TV       = 3

# mode selection window visuals
_LOGO_PATH   = Path(__file__).resolve().parent / "assets" / "jadupc-logo.png"
_HINTS_DIR   = Path(__file__).resolve().parent / "assets" / "icons" / "hints"
_LEGEND_PATH = Path(__file__).resolve().parent / "assets" / "icons" / "hints" / "controller-legend.png"

# misc. top right status
_SYS_POWER = Path("/sys/class/power_supply")

# chromium flags
_CHROMIUM_FLAGS = (
    "--kiosk "
    "--noerrdialogs "
    "--disable-infobars "
    "--disable-session-crashed-bubble "
    "--disable-restore-session-state "
    "--overscroll-history-navigation=0 "
    "--disable-pinch "
    "--disable-translate "
    "--disable-features=TranslateUI "
    "--no-first-run "
    "--fast "
    "--fast-start "
    "--disable-component-update"
)

# screen-aware ui scaling
# reference resolution is 1920x1080
# Hard cap is 1920x1080 prevents UI from overflowing on 2K/4K displays.
_REF_W, _REF_H = 1920, 1080
_MAX_W, _MAX_H = 1920, 1080

def _compute_scale() -> float:
    display = Gdk.Display.get_default()
    if display is None:
        return 1.0
    monitor = display.get_primary_monitor()
    if monitor is None:
        if display.get_n_monitors() > 0:
            monitor = display.get_monitor(0)
        else:
            return 1.0
    geo = monitor.get_geometry()
    w = min(geo.width,  _MAX_W)
    h = min(geo.height, _MAX_H)
    scale = min(w / _REF_W, h / _REF_H)
    return max(0.3, min(scale, 1.0))

_SCALE: float = _compute_scale()

def px(value: int) -> int:
    return max(1, round(value * _SCALE))

# shared css providers
def _make_provider(css: str) -> Gtk.CssProvider:
    p = Gtk.CssProvider()
    p.load_from_data(css.encode())
    return p

_WINDOW_CSS = _make_provider("window { background: #0f1419; }")

_APP_SHORTCUT_CSS = _make_provider("""
button {
    background: #1e2330;
    border: 2px solid #555570;
    border-radius: 15px;
    color: white;
}
button:hover, button:focus {
    background: #13192a;
    border: 2px solid #8888aa;
    outline: none;
}
""")

_HINT_BADGE_CSS = _make_provider("""
.hint-badge {
    background: #13192a;
    border: 2px solid #6666aa;
    border-radius: 8px;
    color: #ccccee;
    font-weight: bold;
    padding: 2px 8px;
}
""")

_HINT_SEP_CSS = _make_provider("""
separator {
    background: #333355;
    min-width: 1px;
    margin-top: 4px;
    margin-bottom: 4px;
}
""")

_STATUS_CSS = _make_provider("""
.status-time {
    color: #FFFDFA;
    font-weight: bold;
    font-size: 2em;
}
.status-date {
    color: #9999bb;
    font-size: 2.3em;
}
.status-battery {
    color: #9999bb;
}
""")

_LEGEND_POPUP_CSS = _make_provider("""
window.legend-window {
    background: #FFFDFA;
}
.legend-title {
    color: #13192a;
    font-weight: bold;
}
.legend-close-btn {
    background: #13192a;
    border: 2px solid #555570;
    border-radius: 6px;
    color: #ccccee;
    font-weight: bold;
    padding: 10px 30px;
}
.legend-close-btn:hover, .legend-close-btn:focus {
    background: #1a1f2e;
    border: 2px solid #8888aa;
    outline: none;
}
""")

_GAMEPAD_BTN_CSS = _make_provider("""
button {
    background: transparent;
    border: 2px solid #8686a8;
    border-radius: 24px;
    padding: 0px 20px;
    margin: 10px;
    box-shadow: none;
    outline: none;
}
button:hover, button:focus, button:active {
    background: transparent;
    border: 2px solid #adadd8;
    border-radius: 12px;
    margin: 10px;
    outline: none;
    box-shadow: 0 0 30px #adadd8;
    transition: all 0.3s ease;
}
""")

_MODE_BTN_PROVIDERS: dict = {}

def _mode_btn_provider(border_color: str) -> Gtk.CssProvider:
    if border_color not in _MODE_BTN_PROVIDERS:
        _MODE_BTN_PROVIDERS[border_color] = _make_provider(f"""
        button {{
            background: #1a1f2e;
            border: 4px solid {border_color};
            border-radius: 25px;
            color: white;
        }}
        button:hover {{
            background: #252a3a;
            border: 4px solid #5ec773;
            outline: none;
            box-shadow: 0 0 30px {border_color};
            transition: all 0.7s ease;
        }}
        button:focus {{
            background: #252a3a;
            border: 4px solid rgba(255,255,255,.8);
            outline: none;
            box-shadow: 0 0 30px {border_color};
            transition: all 0.7s ease;
        }}
        """)
    return _MODE_BTN_PROVIDERS[border_color]

_POWER_BTN_PROVIDERS: dict = {}

def _power_btn_provider(border_color: str) -> Gtk.CssProvider:
    if border_color not in _POWER_BTN_PROVIDERS:
        _POWER_BTN_PROVIDERS[border_color] = _make_provider(f"""
        button {{
            background: #1a1f2e;
            border: 2px solid {border_color};
            border-radius: 12px;
            color: white;
        }}
        button:hover, button:focus {{
            background: #252a3a;
            border: 2px solid {border_color};
            outline: none;
        }}
        """)
    return _POWER_BTN_PROVIDERS[border_color]

# ---------------------------------------------------------------------------
# Power button factory — icon (PNG or GTK fallback) stacked above a label
# ---------------------------------------------------------------------------

def _make_power_button(
    label_text: str,
    png_file: str,
    gtk_icon: str,
    border_color: str,
) -> Gtk.Button:
    btn = Gtk.Button()
    btn.set_valign(Gtk.Align.CENTER)
    btn.set_can_focus(True)

    inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(6))
    inner.set_halign(Gtk.Align.CENTER)
    inner.set_valign(Gtk.Align.CENTER)

    icon = Gtk.Image()
    icon_path = ASSETS_DIR / png_file
    loaded = False
    if icon_path.exists():
        try:
            pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                str(icon_path), px(36), px(36), preserve_aspect_ratio=True
            )
            icon.set_from_pixbuf(pb)
            loaded = True
        except Exception:
            pass
    if not loaded:
        icon.set_from_icon_name(gtk_icon, Gtk.IconSize.LARGE_TOOLBAR)
        icon.set_pixel_size(px(36))

    lbl = Gtk.Label()
    lbl.set_markup(f'<span size="medium" weight="bold">{label_text}</span>')

    inner.pack_start(icon, False, False, 0)
    inner.pack_start(lbl,  False, False, 0)

    btn.add(inner)
    btn.set_size_request(px(130), px(90))
    btn.get_style_context().add_provider(
        _power_btn_provider(border_color), Gtk.STYLE_PROVIDER_PRIORITY_USER
    )
    return btn

# ---------------------------------------------------------------------------
# Controller hints (bottom‑left strip)
# ---------------------------------------------------------------------------

class ControllerHintItem(Gtk.Box):
    def __init__(self, badge_parts: list, icon_file, description: str):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=px(8))
        self.set_valign(Gtk.Align.CENTER)

        loaded = False

        if icon_file:
            icon_path = _HINTS_DIR / icon_file
            if icon_path.exists():
                try:
                    pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                        str(icon_path), px(32), px(32), preserve_aspect_ratio=True
                    )
                    img = Gtk.Image.new_from_pixbuf(pb)
                    img.set_valign(Gtk.Align.CENTER)
                    self.pack_start(img, False, False, 0)
                    loaded = True
                except Exception:
                    pass

        desc_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=px(4))
        desc_box.set_valign(Gtk.Align.CENTER)

        import re
        parts = re.split(r'\{chip\}(.*?)\{/chip\}', description)

        for i, part in enumerate(parts):
            if not part:
                continue

            if i % 2 == 1:
                badge = Gtk.Label(label=part)
                badge.get_style_context().add_class("hint-badge")
                badge.get_style_context().add_provider(
                    _HINT_BADGE_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
                )
                desc_box.pack_start(badge, False, False, 0)
            else:
                lbl = Gtk.Label()
                lbl.set_markup(f'<span size="large" foreground="#9999bb">{part}</span>')
                desc_box.pack_start(lbl, False, False, 0)

        self.pack_start(desc_box, False, False, 0)

class ControllerHintStrip(Gtk.Box):
    _HINTS = [
        (["LS"],          "", "{chip}Thumb L{/chip}to move cursor"),
        (["L1"],          "", "{chip}LB{/chip} to select/ confirm"),
        (["L2", "Home"],  "", "{chip}LT + Home{/chip} to go to home"),
    ]

    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=px(16))
        self.set_valign(Gtk.Align.CENTER)

        for i, (badge_parts, icon_file, description) in enumerate(self._HINTS):
            if i > 0:
                sep = Gtk.Separator(orientation=Gtk.Orientation.VERTICAL)
                sep.get_style_context().add_provider(
                   _HINT_SEP_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
                )
                self.pack_start(sep, False, False, 0)

            self.pack_start(
                ControllerHintItem(badge_parts, icon_file, description),
                False, False, 0
            )

# ---------------------------------------------------------------------------
# Status widget (clock, date, battery)
# ---------------------------------------------------------------------------

def _find_battery_dir() -> Path | None:
    if not _SYS_POWER.exists():
        return None
    for entry in sorted(_SYS_POWER.iterdir()):
        type_file = entry / "type"
        try:
            if type_file.read_text().strip().lower() == "battery":
                return entry
        except OSError:
            continue
    return None

def _read_battery(bat_dir: Path) -> str | None:
    try:
        capacity = int((bat_dir / "capacity").read_text().strip())
        status   = (bat_dir / "status").read_text().strip().lower()
    except (OSError, ValueError):
        return None

    if status == "charging":
        indicator = "↑"
    elif status == "discharging":
        indicator = "↓"
    else:
        indicator = "✓"

    return f"🔋 {capacity}% {indicator}"

class StatusWidget(Gtk.Box):
    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=px(2))
        self.set_halign(Gtk.Align.END)
        self.set_valign(Gtk.Align.CENTER)

        self._bat_dir = _find_battery_dir()

        self._time_label = Gtk.Label()
        self._time_label.set_halign(Gtk.Align.END)
        self._time_label.get_style_context().add_class("status-date")
        self._time_label.get_style_context().add_provider(
            _STATUS_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )

        self._date_label = Gtk.Label()
        self._date_label.set_halign(Gtk.Align.END)
        self._date_label.get_style_context().add_class("status-time")
        self._date_label.get_style_context().add_provider(
            _STATUS_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )

        self.pack_start(self._date_label, False, False, 0)
        self.pack_start(self._time_label, False, False, 0)

        if self._bat_dir is not None:
            self._bat_label = Gtk.Label()
            self._bat_label.set_halign(Gtk.Align.END)
            self._bat_label.get_style_context().add_class("status-battery")
            self._bat_label.get_style_context().add_provider(
                _STATUS_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
            )
            self.pack_start(self._bat_label, False, False, 0)
        else:
            self._bat_label = None

        self._refresh()
        GLib.timeout_add_seconds(30, self._on_tick)

    def _refresh(self) -> None:
        now = datetime.datetime.now()
        self._date_label.set_markup(
            f'<span size="small">{now.strftime("%A, %d %b %Y")}</span>'
        )
        self._time_label.set_markup(
            f'<span size="x-large" weight="bold">{now.strftime("%I:%M %p")}</span>'
        )

        if self._bat_label is not None:
            bat_text = _read_battery(self._bat_dir) or ""
            self._bat_label.set_markup(
                f'<span size="small">{bat_text}</span>'
            )

    def _on_tick(self) -> bool:
        self._refresh()
        return True

# ---------------------------------------------------------------------------
# Mode selection buttons
# ---------------------------------------------------------------------------

class ModeButton(Gtk.Button):
    def __init__(self, label, icon_name, border_color, command="", exit_on_click=False,
                 callback=None, mode_state=None, logo_file=None, hide_delay=2.0):
        super().__init__()
        self.command       = command
        self.border_color  = border_color
        self.exit_on_click = exit_on_click
        self.callback      = callback
        self.mode_state    = mode_state
        self.hide_delay    = hide_delay    # [new]
        self.is_focused    = False

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(15))
        box.set_halign(Gtk.Align.CENTER)
        box.set_valign(Gtk.Align.CENTER)

        icon = Gtk.Image()
        loaded = False
        if logo_file:
            logo_path = ASSETS_DIR / logo_file
            if logo_path.exists():
                try:
                    pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                        str(logo_path), px(256), px(256), preserve_aspect_ratio=True
                    )
                    icon.set_from_pixbuf(pixbuf)
                    loaded = True
                except Exception:
                    pass
        if not loaded:
            icon.set_from_icon_name(icon_name, Gtk.IconSize.DIALOG)
            icon.set_pixel_size(px(100))

        label_widget = Gtk.Label(label=label)
        label_widget.set_markup(f'<span size="x-large" weight="bold">{label}</span>')

        box.pack_start(icon, True, True, 0)
        box.pack_start(label_widget, False, False, 0)

        self.add(box)
        self.set_size_request(px(420), px(380))
        self.set_can_focus(True)

        self.get_style_context().add_provider(
            _mode_btn_provider(border_color), Gtk.STYLE_PROVIDER_PRIORITY_USER
        )

        self.connect("clicked",            self.on_button_clicked)
        self.connect("focus-in-event",     self.on_focus_in)
        self.connect("focus-out-event",    self.on_focus_out)
        self.connect("enter-notify-event", self.on_mouse_enter)
        self.connect("leave-notify-event", self.on_mouse_leave)

    def on_focus_in(self, widget, event):
        self.is_focused = True
        self.queue_draw()
        return False

    def on_focus_out(self, widget, event):
        self.is_focused = False
        self.queue_draw()
        return False

    def on_mouse_enter(self, widget, event):
        if not self.is_focused:
            self.grab_focus()
        return False

    def on_mouse_leave(self, widget, event):
        return False

    def on_button_clicked(self, button):
        if self.callback:
            self.callback()                     # TV page – stay inside window
            return

        # Launch an external app or drop to desktop → show black overlay first
        window = self.get_toplevel()
        if hasattr(window, 'show_black_and_hide_after'):
            window.show_black_and_hide_after(self.hide_delay)

        if self.command:
            try:
                subprocess.Popen(self.command, shell=True)
                print(f"Executing: {self.command}")
                if self.mode_state is not None:
                    write_mode_state(self.mode_state)
            except Exception as e:
                print(f"Error executing command: {e}", file=sys.stderr)

        elif self.exit_on_click:
            # Desktop mode: no subprocess, just hide after the black screen
            print("Desktop mode selected - Exiting selector")
            if self.mode_state is not None:
                write_mode_state(self.mode_state)
            # The hide is handled by the timeout in show_black_and_hide_after

# ---------------------------------------------------------------------------
# TV app shortcuts
# ---------------------------------------------------------------------------

class AppShortcut(Gtk.Button):
    def __init__(self, label, logo_file, icon_name, command="", w=320, h=200, hide_delay=3.0):
        super().__init__()
        self.command    = command
        self.hide_delay = hide_delay    # [new]

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(10))
        box.set_halign(Gtk.Align.CENTER)
        box.set_valign(Gtk.Align.CENTER)

        icon = Gtk.Image()
        logo_path = ASSETS_DIR / logo_file
        loaded = False
        if logo_path.exists():
            try:
                pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                    str(logo_path), px(128), px(128), preserve_aspect_ratio=True
                )
                icon.set_from_pixbuf(pixbuf)
                loaded = True
            except Exception:
                pass
        if not loaded:
            icon.set_from_icon_name(icon_name, Gtk.IconSize.DIALOG)
            icon.set_pixel_size(px(80))

        label_widget = Gtk.Label(label=label)
        label_widget.set_markup(f'<span size="medium">{label}</span>')

        box.pack_start(icon, False, False, 0)
        box.pack_start(label_widget, False, False, 0)

        self.add(box)
        self.set_size_request(px(w), px(h))
        self.set_can_focus(True)

        self.get_style_context().add_provider(
            _APP_SHORTCUT_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
        self.connect("clicked", self.on_clicked)

    def on_clicked(self, button):
        if self.command:
            window = self.get_toplevel()
            if hasattr(window, 'show_black_and_hide_after'):
                window.show_black_and_hide_after(self.hide_delay)
            try:
                subprocess.Popen(self.command, shell=True)
                print(f"Launching: {self.command}")
                write_mode_state(MODE_TV)
            except Exception as e:
                print(f"Error: {e}", file=sys.stderr)

# ---------------------------------------------------------------------------
# WebAppInterface (Smart TV page)
# ---------------------------------------------------------------------------

class WebAppInterface(Gtk.Box):
    def __init__(self, parent_window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.parent_window = parent_window

        outer_scroll = Gtk.ScrolledWindow()
        outer_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.pack_start(outer_scroll, True, True, 0)

        content_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(30))
        content_box.set_margin_top(px(40))
        content_box.set_margin_bottom(px(40))
        content_box.set_margin_start(px(50))
        content_box.set_margin_end(px(50))
        outer_scroll.add(content_box)

        streaming_label = Gtk.Label()
        streaming_label.set_markup('<span size="xx-large" weight="bold" foreground="#FFFDFA">Streaming</span>')
        streaming_label.set_halign(Gtk.Align.START)
        content_box.pack_start(streaming_label, False, False, 0)

        apps_grid = Gtk.FlowBox()
        apps_grid.set_valign(Gtk.Align.START)
        apps_grid.set_max_children_per_line(6)
        apps_grid.set_selection_mode(Gtk.SelectionMode.NONE)
        apps_grid.set_column_spacing(px(20))
        apps_grid.set_row_spacing(px(20))

        # TV app shortcuts with per‑target delays
        streaming_apps = [
            ("YouTube",     "youtube.png", "applications-multimedia",
             "https://youtube.com", 3.0),
            ("Netflix",     "netflix.png", "applications-multimedia",
             "https://netflix.com", 3.0),
            ("Prime Video", "prime.png",   "applications-multimedia",
             "https://primevideo.com/region/eu/storefront", 3.0),
            ("Bongo",       "bongo.png",   "applications-multimedia",
             "https://bongobd.com", 3.0),
            ("Chorki",      "chorki.png",  "applications-multimedia",
             "https://chorki.com", 3.0),
            ("Toffee",      "toffee.png",  "applications-multimedia",
             "https://toffeelive.com", 3.0),
        ]

        for app_name, logo_file, gtk_icon, url, delay in streaming_apps:
            cmd = f"google-chrome-stable {_CHROMIUM_FLAGS} --app={url} {url}"
            apps_grid.add(AppShortcut(
                app_name, logo_file, gtk_icon, cmd, hide_delay=delay
            ))

        content_box.pack_start(apps_grid, False, False, 0)

        local_label = Gtk.Label()
        local_label.set_markup('<span size="xx-large" weight="bold" foreground="#FFFDFA">Local Media</span>')
        local_label.set_halign(Gtk.Align.START)
        content_box.pack_start(local_label, False, False, 0)

        local_grid = Gtk.FlowBox()
        local_grid.set_valign(Gtk.Align.START)
        local_grid.set_max_children_per_line(10)
        local_grid.set_selection_mode(Gtk.SelectionMode.NONE)
        local_grid.set_column_spacing(px(20))
        local_grid.set_row_spacing(px(20))

        # Kodi with 4s delay
        local_grid.add(AppShortcut(
            "Media Player", "local-media.png", "applications-multimedia",
            "env -u LIBVA_DRIVER_NAME kodi; dbus-send --session --type=method_call "
            "--dest=org.jadupc.ModeSelector /org/jadupc/ModeSelector "
            "org.jadupc.ModeSelector.Show",
            w=200, h=140, hide_delay=4.0
        ))

        content_box.pack_start(local_grid, False, False, 0)

        back_btn = Gtk.Button(label="󰌍  Go Back to Home")
        back_btn.set_halign(Gtk.Align.START)
        back_btn.connect("clicked", lambda b: self.parent_window.show_main())
        back_btn.set_size_request(px(200), px(80))
        back_btn.set_margin_start(px(50))
        back_btn.set_margin_top(px(10))
        back_btn.set_margin_bottom(px(50))
        back_btn.get_style_context().add_provider(
            _power_btn_provider("#cc7700"), Gtk.STYLE_PROVIDER_PRIORITY_USER
        )

        self.pack_start(back_btn, False, False, 0)

# ---------------------------------------------------------------------------
# Controller legend popup (in‑process overlay)
# ---------------------------------------------------------------------------

class ControllerLegendPopup(Gtk.Box):
    _FULL_HINTS = [
        (["LS"],          "", "Use {chip}LThumb{/chip} to move cursor"),
        (["L1"],          "", "Use {chip}LB{/chip} to select / confirm"),
        (["L2", "Home"],  "", "Use {chip}LT + Home{/chip} to go to home"),
    ]

    _SCRIM_CSS = _make_provider(".legend-scrim { background: rgba(0,0,0,0.72); }")
    _CARD_CSS  = _make_provider("""
    .legend-card {
        background: #1a1f2e;
        border: 2px solid #555570;
        border-radius: 16px;
    }
    """)

    def __init__(self, on_close):
        super().__init__()
        self.set_halign(Gtk.Align.FILL)
        self.set_valign(Gtk.Align.FILL)
        self.set_hexpand(True)
        self.set_vexpand(True)

        self.get_style_context().add_class("legend-scrim")
        self.get_style_context().add_provider(
            self._SCRIM_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )

        popup_w = max(px(720), int(_REF_W * _SCALE * 0.80))
        popup_h = max(px(480), int(_REF_H * _SCALE * 0.85))

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        card.set_halign(Gtk.Align.CENTER)
        card.set_valign(Gtk.Align.CENTER)
        card.set_size_request(popup_w, popup_h)
        card.get_style_context().add_class("legend-card")
        card.get_style_context().add_provider(
            self._CARD_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=px(12))
        header.get_style_context().add_class("legend-header")
        header.set_margin_start(px(24))
        header.set_margin_end(px(16))
        header.set_margin_top(px(14))
        header.set_margin_bottom(px(14))

        title_lbl = Gtk.Label()
        title_lbl.set_markup(
            '<span size="x-large" weight="bold" foreground="#FFFDFA">Controller Legend</span>'
        )
        title_lbl.set_halign(Gtk.Align.START)
        title_lbl.get_style_context().add_class("legend-title")
        header.pack_start(title_lbl, True, True, 0)

        close_btn = Gtk.Button(label="X")
        close_btn.get_style_context().add_class("legend-close-btn")
        close_btn.get_style_context().add_provider(
            _LEGEND_POPUP_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )
        close_btn.set_valign(Gtk.Align.CENTER)
        close_btn.connect("clicked", lambda _: on_close())
        header.pack_end(close_btn, False, False, 0)

        card.pack_start(header, False, False, 0)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=px(20))
        body.set_margin_top(px(30))
        body.set_margin_bottom(px(30))
        body.set_margin_start(px(40))
        body.set_margin_end(px(40))
        body.set_valign(Gtk.Align.CENTER)
        body.set_hexpand(True)
        body.set_vexpand(True)

        if _LEGEND_PATH.exists():
            self._build_image_body(body, popup_w, popup_h)
        else:
            self._build_text_body(body)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(body)
        card.pack_start(scroll, True, True, 0)

        self.pack_start(card, True, True, 0)

    def _build_image_body(self, body: Gtk.Box, popup_w: int, popup_h: int) -> None:
        try:
            available_h = popup_h - px(80)
            pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                str(_LEGEND_PATH),
                popup_w - px(80),
                available_h,
                preserve_aspect_ratio=True,
            )
            img = Gtk.Image.new_from_pixbuf(pb)
            img.set_halign(Gtk.Align.CENTER)
            img.set_valign(Gtk.Align.CENTER)
            body.pack_start(img, True, True, 0)
        except Exception:
            self._build_text_body(body)

    def _build_text_body(self, body: Gtk.Box) -> None:
        sep_css = _make_provider("""
        separator {
            background: #2a2f45;
            min-height: 1px;
            margin-start: 8px;
            margin-end: 8px;
        }
        """)
        for i, (badge_parts, icon_file, description) in enumerate(self._FULL_HINTS):
            if i > 0:
                sep = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
                sep.get_style_context().add_provider(
                    sep_css, Gtk.STYLE_PROVIDER_PRIORITY_USER
                )
                body.pack_start(sep, False, False, 0)
            body.pack_start(
                _LargeHintItem(badge_parts, icon_file, description), False, False, 0
            )

class _LargeHintItem(Gtk.Box):
    def __init__(self, badge_parts: list, icon_file, description: str):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=px(20))
        self.set_valign(Gtk.Align.CENTER)
        self.set_margin_top(px(8))
        self.set_margin_bottom(px(8))

        loaded = False
        if icon_file:
            icon_path = _HINTS_DIR / icon_file
            if icon_path.exists():
                try:
                    pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                        str(icon_path), px(96), px(96), preserve_aspect_ratio=True
                    )
                    img = Gtk.Image.new_from_pixbuf(pb)
                    img.set_valign(Gtk.Align.CENTER)
                    self.pack_start(img, False, False, 0)
                    loaded = True
                except Exception:
                    pass

        if not loaded:
            badge_label = " + ".join(badge_parts)
            badge = Gtk.Label(label=badge_label)
            badge.get_style_context().add_class("hint-badge")
            badge.get_style_context().add_provider(
                _HINT_BADGE_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
            )
            self.pack_start(badge, False, False, 0)

        import re
        desc_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=px(6))
        desc_box.set_valign(Gtk.Align.CENTER)
        parts = re.split(r'\{chip\}(.*?)\{/chip\}', description)
        for i, part in enumerate(parts):
            if not part:
                continue
            if i % 2 == 1:
                badge = Gtk.Label(label=part)
                badge.get_style_context().add_class("hint-badge")
                badge.get_style_context().add_provider(
                    _HINT_BADGE_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
                )
                desc_box.pack_start(badge, False, False, 0)
            else:
                lbl = Gtk.Label()
                lbl.set_markup(f'<span size="large" foreground="#ccccee">{part}</span>')
                desc_box.pack_start(lbl, False, False, 0)

        self.pack_start(desc_box, False, False, 0)

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

class MainWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="JaduPc")

        self.fullscreen()
        self.set_default_size(px(1100), px(700))
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)

        self.connect("delete-event", self._on_delete)

        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), _WINDOW_CSS,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        # Stack with three pages: main, tv, black (solid #000000)
        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.NONE)

        self.main_page = self.create_main_page()
        self.stack.add_named(self.main_page, "main")

        # Lazy‑built TV page
        self._tv_page = None

        # Black overlay page for seamless transitions
        black_box = Gtk.Box()
        black_box.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0,0,0,1))
        self.stack.add_named(black_box, "black")

        self.overlay = Gtk.Overlay()
        self.overlay.add(self.stack)
        self._legend_widget = None

        self.add(self.overlay)

        # Timeout id for hiding after black screen (forward transitions)
        self._hide_timeout_id = None   # [new]

        self.connect("key-press-event", self._on_key_press)

    # ------------------------------------------------------------------
    # Black overlay & delayed hide (forward: selector → app)
    # ------------------------------------------------------------------

    def show_black_and_hide_after(self, delay: float):
        """Switch to the solid black page, then hide the window after `delay` seconds."""
        # Cancel any previous hide timeout
        if self._hide_timeout_id:
            GLib.source_remove(self._hide_timeout_id)
            self._hide_timeout_id = None

        self.stack.set_visible_child_name("black")
        self.show_all()

        if delay > 0:
            self._hide_timeout_id = GLib.timeout_add(int(delay * 1000), self._on_black_hide)
        else:
            # Instant hide – no black screen
            self.hide()

    def _on_black_hide(self):
        self.hide()
        self._hide_timeout_id = None
        return False  # stop the timer

    # ------------------------------------------------------------------
    # Reverse transition: app → selector
    # ------------------------------------------------------------------

    def surface(self):
        # Cancel any pending forward‑hide timeout
        if self._hide_timeout_id:
            GLib.source_remove(self._hide_timeout_id)
            self._hide_timeout_id = None

        # Immediately show the black page, then reveal the real UI after mapping
        self.stack.set_visible_child_name("black")
        self.show_all()
        self.fullscreen()
        self.present()

        GLib.idle_add(self._on_surface_show_main)
        write_mode_state(MODE_SELECTOR)

    def _on_surface_show_main(self):
        self.stack.set_visible_child_name("main")
        return False

    # ------------------------------------------------------------------
    # Keyboard / legend handling
    # ------------------------------------------------------------------

    def _on_key_press(self, widget, event) -> bool:
        if event.keyval == Gdk.KEY_Escape:
            self._close_legend()
            return True
        return False

    def _close_legend(self) -> None:
        if self._legend_widget is not None:
            self._legend_widget.destroy()
            self._legend_widget = None

    def _on_delete(self, window, event):
        self.hide()
        return True

    # ------------------------------------------------------------------
    # Page construction
    # ------------------------------------------------------------------

    def create_main_page(self):
        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        main_box.set_margin_top(px(30))
        main_box.set_margin_bottom(px(50))
        main_box.set_margin_start(px(30))
        main_box.set_margin_end(px(30))

        # Header
        header_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=px(16))
        header_box.set_margin_bottom(px(50))

        if _LOGO_PATH.exists():
            try:
                logo_pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                    str(_LOGO_PATH), -1, px(64), preserve_aspect_ratio=True
                )
                logo_img = Gtk.Image.new_from_pixbuf(logo_pb)
                logo_img.set_valign(Gtk.Align.CENTER)
                header_box.pack_start(logo_img, False, False, 0)
            except Exception:
                pass

        title = Gtk.Label()
        title.set_markup('<span size="36864" weight="bold" foreground="#8B7BC8">3-in-1</span> <span size="36864" weight="bold" foreground="#FFFDFA"> HOME</span>')
        title.set_halign(Gtk.Align.START)
        title.set_valign(Gtk.Align.CENTER)
        header_box.pack_start(title, False, False, 0)

        header_box.pack_end(StatusWidget(), False, False, 0)
        main_box.pack_start(header_box, False, False, 0)

        buttons_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=px(180))
        buttons_box.set_halign(Gtk.Align.CENTER)
        buttons_box.set_valign(Gtk.Align.CENTER)
        buttons_box.set_hexpand(True)
        buttons_box.set_vexpand(True)

        # Desktop: hide_delay=0 → instant hide, no black overlay
        desktop_btn = ModeButton(
            "Desktop",
            "computer",
            "#00BFFF",
            exit_on_click=True,
            mode_state=MODE_DESKTOP,
            logo_file="desktop-computer.png",
            hide_delay=0.0,
        )

        # Gaming (EmulationStation): 2 seconds delay
        gaming_btn = ModeButton(
            "Retro Gaming",
            "applications-games",
            "#6B4FBB",
            command="xfce4-terminal --disable-server --maximize --hide-menubar --hide-borders --hide-scrollbar  --execute emulationstation; dbus-send --session --type=method_call --dest=org.jadupc.ModeSelector /org/jadupc/ModeSelector org.jadupc.ModeSelector.Show",
            mode_state=MODE_GAMING,
            logo_file="game.png",
            hide_delay=2.0,
        )

        # TV: no hide delay (just switches to TV page)
        tv_btn = ModeButton(
            "Smart TV",
            "video-display",
            "#B946D1",
            callback=self.show_tv,
            logo_file="smart-tv.png",
        )

        gaming_btn.grab_focus()

        buttons_box.pack_start(desktop_btn, False, False, 0)
        buttons_box.pack_start(gaming_btn,  False, False, 0)
        buttons_box.pack_start(tv_btn,      False, False, 0)

        main_box.pack_start(buttons_box, True, True, 0)

        # Bottom bar
        bottom_bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=px(10))
        bottom_bar.set_margin_top(px(40))

        left_bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        left_bar.set_valign(Gtk.Align.CENTER)

        gamepad_btn = Gtk.Button()
        gamepad_btn.set_valign(Gtk.Align.CENTER)
        gamepad_btn.set_can_focus(True)
        gamepad_btn.set_tooltip_text("Controller Legend")
        gamepad_btn.get_style_context().add_provider(
            _GAMEPAD_BTN_CSS, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )

        _gamepad_icon_path = _HINTS_DIR / "gamepad.png"
        _gamepad_icon = Gtk.Image()
        if _gamepad_icon_path.exists():
            try:
                _gpb = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                    str(_gamepad_icon_path), px(132), px(132), preserve_aspect_ratio=True
                )
                _gamepad_icon.set_from_pixbuf(_gpb)
            except Exception:
                _gamepad_icon.set_from_icon_name("input-gaming", Gtk.IconSize.LARGE_TOOLBAR)
                _gamepad_icon.set_pixel_size(px(48))
        else:
            _gamepad_icon.set_from_icon_name("input-gaming", Gtk.IconSize.LARGE_TOOLBAR)
            _gamepad_icon.set_pixel_size(px(48))

        gamepad_btn.add(_gamepad_icon)
        gamepad_btn.set_size_request(px(60), px(60))

        def _open_legend(_btn):
            if self._legend_widget is not None:
                return
            widget = ControllerLegendPopup(on_close=self._close_legend)
            self._legend_widget = widget
            self.overlay.add_overlay(widget)
            self.overlay.set_overlay_pass_through(widget, False)
            widget.show_all()

        gamepad_btn.connect("clicked", _open_legend)
        left_bar.pack_start(gamepad_btn, False, False, 0)

        hint_strip = ControllerHintStrip()
        hint_strip.set_halign(Gtk.Align.START)
        hint_strip.set_valign(Gtk.Align.CENTER)
        left_bar.pack_start(hint_strip, False, False, 0)

        bottom_bar.pack_start(left_bar, False, False, 0)

        shutdown_btn = _make_power_button(
            "Shutdown", "shutdown.png", "system-shutdown", "#cc3333"
        )
        shutdown_btn.connect("clicked", lambda b: subprocess.Popen(["systemctl", "poweroff"]))

        restart_btn = _make_power_button(
            "Restart", "restart.png", "system-reboot", "#cc7700"
        )
        restart_btn.connect("clicked", lambda b: subprocess.Popen(["systemctl", "reboot"]))

        bottom_bar.pack_end(shutdown_btn, False, False, 0)
        bottom_bar.pack_end(restart_btn,  False, False, px(10))
        main_box.pack_start(bottom_bar, False, False, 0)

        return main_box

    # ------------------------------------------------------------------
    # Stack navigation
    # ------------------------------------------------------------------

    def show_tv(self):
        if self._tv_page is None:
            self._tv_page = WebAppInterface(self)
            self.stack.add_named(self._tv_page, "tv")
            self._tv_page.show_all()
        self.stack.set_visible_child_name("tv")

    def show_main(self):
        self.stack.set_visible_child_name("main")

# ---------------------------------------------------------------------------
# DBus
# ---------------------------------------------------------------------------

_DBUS_XML = """
<node>
  <interface name='org.jadupc.ModeSelector'>
    <method name='Show'/>
    <method name='Quit'/>
  </interface>
</node>
"""

def _setup_dbus(window: MainWindow) -> None:
    def on_method_call(conn, sender, path, iface, method, params, invocation):
        if method == "Show":
            GLib.idle_add(window.surface)
            invocation.return_value(None)
        elif method == "Quit":
            invocation.return_value(None)
            GLib.idle_add(Gtk.main_quit)

    def on_bus_acquired(conn, name):
        node_info = Gio.DBusNodeInfo.new_for_xml(_DBUS_XML)
        conn.register_object(
            "/org/jadupc/ModeSelector",
            node_info.interfaces[0],
            on_method_call,
            None, None
        )
        conn.signal_subscribe(
            None,
            "org.jadupc.Session",
            "HotkeyTriggered",
            "/org/jadupc/Session",
            None,
            Gio.DBusSignalFlags.NONE,
            lambda *_: GLib.idle_add(window.surface)
        )

    def on_name_lost(conn, name):
        print(f"DBus name lost: {name} — another instance running?", file=sys.stderr)

    Gio.bus_own_name(
        Gio.BusType.SESSION,
        _DBUS_NAME,
        Gio.BusNameOwnerFlags.NONE,
        on_bus_acquired,
        None,
        on_name_lost,
    )

# ---------------------------------------------------------------------------
# SIGUSR1 fallback
# ---------------------------------------------------------------------------

def _setup_sigusr1(window: MainWindow) -> None:
    def _handler(sig, frame):
        GLib.idle_add(window.surface)
    signal.signal(signal.SIGUSR1, _handler)

# ---------------------------------------------------------------------------
# PID file
# ---------------------------------------------------------------------------

def _write_pid() -> None:
    try:
        _PID_FILE.parent.mkdir(parents=True, exist_ok=True)
        _PID_FILE.write_text(str(os.getpid()))
    except OSError as e:
        print(f"Could not write PID file {_PID_FILE}: {e}", file=sys.stderr)

def _remove_pid() -> None:
    try:
        _PID_FILE.unlink(missing_ok=True)
    except OSError:
        pass

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------

def write_mode_state(state: int) -> None:
    try:
        _STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = _STATE_FILE.with_suffix(".tmp")
        tmp.write_text(str(state))
        tmp.rename(_STATE_FILE)
    except OSError as e:
        print(f"Could not write state file {_STATE_FILE}: {e}", file=sys.stderr)

def _remove_state() -> None:
    try:
        _STATE_FILE.unlink(missing_ok=True)
    except OSError:
        pass

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    print(f"[jadupc-mode-selector] scale={_SCALE:.3f} (screen capped at {_MAX_W}x{_MAX_H})", file=sys.stderr)
    win = MainWindow()
    win.show_all()

    _setup_dbus(win)
    _setup_sigusr1(win)
    _write_pid()
    write_mode_state(MODE_SELECTOR)

    Gtk.main()

    _remove_pid()
    _remove_state()

if __name__ == "__main__":
    main()
