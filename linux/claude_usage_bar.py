import os
import sys

import gi
gi.require_version('Gtk', '3.0')

try:
    gi.require_version('AyatanaAppIndicator3', '0.1')
    from gi.repository import AyatanaAppIndicator3 as AppIndicator3
except ValueError:
    try:
        gi.require_version('AppIndicator3', '0.1')
        from gi.repository import AppIndicator3
    except ValueError:
        print("Error: libayatana-appindicator3 or libappindicator3 is required.")
        sys.exit(1)

from gi.repository import Gtk, GLib

from usage_manager import UsageManager
from popover_window import PopoverWindow

class TrayApp:
    def __init__(self):
        self.manager = UsageManager()
        self.popover = PopoverWindow(self.manager)
        
        # Icon: prefer the themed name (installed by packages into hicolor);
        # fall back to the bundled assets dir so `swift run`-style local runs work.
        script_dir = os.path.dirname(os.path.abspath(__file__))
        assets_dir = os.path.join(script_dir, "assets")

        self.indicator = AppIndicator3.Indicator.new(
            "claude-usage-bar",
            "claude-usage-bar",
            AppIndicator3.IndicatorCategory.APPLICATION_STATUS
        )
        # Let the indicator resolve the bundled icon by name ("icon.png" -> "icon").
        if os.path.exists(os.path.join(assets_dir, "icon.png")):
            self.indicator.set_icon_theme_path(assets_dir)
            self.indicator.set_icon_full("icon", "Claude Usage")
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        
        # Guide string for width estimation
        self.indicator.set_label("◌ …", "🟠 100% · 99h 99m")
        self.indicator.set_menu(self._build_menu())
        
        self.manager.on_update = self._on_update
        self.manager.start()

    def _on_update(self, title: str):
        GLib.idle_add(self.indicator.set_label, title, "🟠 100% · 99h 99m")
    
    def _build_menu(self) -> Gtk.Menu:
        menu = Gtk.Menu()
        
        show_item = Gtk.MenuItem(label="Show Usage")
        show_item.connect("activate", lambda _: self.popover.toggle())
        
        refresh_item = Gtk.MenuItem(label="Refresh")
        refresh_item.connect("activate", lambda _: self.manager.fetch_async())
        
        sep = Gtk.SeparatorMenuItem()
        
        quit_item = Gtk.MenuItem(label="Quit Claude Usage")
        quit_item.connect("activate", lambda _: self.quit())
        
        for item in [show_item, sep, refresh_item, Gtk.SeparatorMenuItem(), quit_item]:
            menu.append(item)
            
        menu.show_all()
        return menu

    def quit(self):
        self.manager.stop()
        Gtk.main_quit()

def main():
    app = TrayApp()
    Gtk.main()

if __name__ == "__main__":
    main()
