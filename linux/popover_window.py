import gi
import subprocess
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gtk, Gdk, GLib

class PopoverWindow(Gtk.Window):
    def __init__(self, manager):
        super().__init__(title="Claude Usage")
        self.manager = manager
        
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_default_size(280, 460)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.POPUP_MENU)
        
        self._apply_css()
        
        self.connect("focus-out-event", self._on_focus_out)
        self.connect("key-press-event", self._on_key_press)
        
        self._build_ui()
        self.manager.on_state_change = self._refresh_ui
        self._refresh_ui()

    def _apply_css(self):
        css = b"""
        window {
            background-color: #141417;
        }
        .card {
            background-color: #242428;
            border-radius: 12px;
            padding: 14px;
        }
        label { color: white; }
        .caption { color: rgba(255,255,255,0.35); font-size: 11px; }
        .header-label { font-size: 15px; font-weight: bold; }
        .section-title { font-size: 11px; font-weight: 600; color: rgba(255,255,255,0.4); letter-spacing: 1.2px; }
        .pct-label { font-size: 22px; font-weight: bold; }
        .pct-green  { color: #33D649; }
        .pct-orange { color: #FF9E0A; }
        .pct-red    { color: #FF4540; }
        .footer-label { font-size: 10px; color: rgba(255,255,255,0.28); }
        .error-label { font-size: 10px; color: rgba(255,69,64,0.8); }
        .quit-button {
            font-size: 11px; color: rgba(255,255,255,0.55);
            background-color: rgba(255,255,255,0.08);
            border-radius: 6px; border: none; padding: 5px 10px;
        }
        progressbar trough { background-color: rgba(255,255,255,0.07); border-radius: 3px; min-height: 6px; }
        progressbar progress { border-radius: 3px; min-height: 6px; }
        .progress-green  progress { background-color: #33D649; }
        .progress-orange progress { background-color: #FF9E0A; }
        .progress-red    progress { background-color: #FF4540; }
        switch:checked { background-color: #33D649; }
        .icon-circle {
            background-color: rgba(255, 158, 10, 0.12);
            border-radius: 32px;
        }
        """
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

    def _build_ui(self):
        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        
        self.main_box = self._build_main_screen()
        self.setup_box = self._build_setup_screen()
        self.expired_box = self._build_expired_screen()
        
        self.stack.add_named(self.main_box, "main")
        self.stack.add_named(self.setup_box, "setup")
        self.stack.add_named(self.expired_box, "expired")
        
        self.add(self.stack)

    def _build_main_screen(self) -> Gtk.Widget:
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        vbox.set_margin_start(16)
        vbox.set_margin_end(16)
        vbox.set_margin_top(20)
        vbox.set_margin_bottom(16)

        # Header
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        title = Gtk.Label(label="Claude Usage")
        title.get_style_context().add_class("header-label")
        
        self.refresh_btn = Gtk.Button()
        self.refresh_btn.set_relief(Gtk.ReliefStyle.NONE)
        self.refresh_icon = Gtk.Image.new_from_icon_name("view-refresh-symbolic", Gtk.IconSize.MENU)
        self.refresh_spinner = Gtk.Spinner()
        
        self.refresh_stack = Gtk.Stack()
        self.refresh_stack.add_named(self.refresh_icon, "icon")
        self.refresh_stack.add_named(self.refresh_spinner, "spinner")
        self.refresh_btn.add(self.refresh_stack)
        self.refresh_btn.connect("clicked", lambda _: self.manager.fetch_async())
        
        header.pack_start(title, False, False, 0)
        header.pack_end(self.refresh_btn, False, False, 0)
        vbox.pack_start(header, False, False, 4)

        # Session Card
        self.session_title = Gtk.Label(label="SESSION")
        self.session_title.set_halign(Gtk.Align.START)
        self.session_title.get_style_context().add_class("section-title")
        self.session_pct = Gtk.Label(label="0%")
        self.session_pct.get_style_context().add_class("pct-label")
        
        hbox_session = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        hbox_session.pack_start(self.session_title, False, False, 0)
        hbox_session.pack_end(self.session_pct, False, False, 0)
        
        self.session_bar = Gtk.ProgressBar()
        
        self.session_caption_icon = Gtk.Image.new_from_icon_name("dialog-information-symbolic", Gtk.IconSize.MENU)
        self.session_caption = Gtk.Label(label="Resets in —")
        self.session_caption.get_style_context().add_class("caption")
        
        hbox_session_cap = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        hbox_session_cap.pack_start(self.session_caption_icon, False, False, 0)
        hbox_session_cap.pack_start(self.session_caption, False, False, 0)
        
        card_session = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        card_session.get_style_context().add_class("card")
        card_session.pack_start(hbox_session, False, False, 0)
        card_session.pack_start(self.session_bar, False, False, 0)
        card_session.pack_start(hbox_session_cap, False, False, 0)
        vbox.pack_start(card_session, False, False, 0)

        # Weekly Card
        self.weekly_title = Gtk.Label(label="WEEKLY")
        self.weekly_title.set_halign(Gtk.Align.START)
        self.weekly_title.get_style_context().add_class("section-title")
        self.weekly_pct = Gtk.Label(label="0%")
        self.weekly_pct.get_style_context().add_class("pct-label")
        
        hbox_weekly = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        hbox_weekly.pack_start(self.weekly_title, False, False, 0)
        hbox_weekly.pack_end(self.weekly_pct, False, False, 0)
        
        self.weekly_bar = Gtk.ProgressBar()
        
        self.weekly_caption_icon = Gtk.Image.new_from_icon_name("dialog-information-symbolic", Gtk.IconSize.MENU)
        self.weekly_caption = Gtk.Label(label="Resets —")
        self.weekly_caption.get_style_context().add_class("caption")
        
        hbox_weekly_cap = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        hbox_weekly_cap.pack_start(self.weekly_caption_icon, False, False, 0)
        hbox_weekly_cap.pack_start(self.weekly_caption, False, False, 0)
        
        card_weekly = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        card_weekly.get_style_context().add_class("card")
        card_weekly.pack_start(hbox_weekly, False, False, 0)
        card_weekly.pack_start(self.weekly_bar, False, False, 0)
        card_weekly.pack_start(hbox_weekly_cap, False, False, 0)
        vbox.pack_start(card_weekly, False, False, 0)

        # Stats row
        stats_hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        stats_hbox.set_homogeneous(True)
        
        # Daily routines
        dr_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        dr_box.get_style_context().add_class("card")
        dr_label = Gtk.Label(label="DAILY ROUTINES")
        dr_label.set_halign(Gtk.Align.START)
        dr_label.get_style_context().add_class("caption")
        self.dr_val = Gtk.Label(label="0 / 5")
        self.dr_val.set_halign(Gtk.Align.START)
        dr_box.pack_start(dr_label, False, False, 0)
        dr_box.pack_start(self.dr_val, False, False, 0)
        stats_hbox.pack_start(dr_box, True, True, 0)

        # Usage credits
        uc_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        uc_box.get_style_context().add_class("card")
        uc_label = Gtk.Label(label="USAGE CREDITS")
        uc_label.set_halign(Gtk.Align.START)
        uc_label.get_style_context().add_class("caption")
        self.uc_val = Gtk.Label(label="OFF")
        self.uc_val.set_halign(Gtk.Align.START)
        uc_box.pack_start(uc_label, False, False, 0)
        uc_box.pack_start(self.uc_val, False, False, 0)
        stats_hbox.pack_start(uc_box, True, True, 0)

        vbox.pack_start(stats_hbox, False, False, 0)

        # Launch at login
        login_hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        login_label = Gtk.Label(label="LAUNCH AT LOGIN")
        login_label.get_style_context().add_class("section-title")
        self.login_switch = Gtk.Switch()
        self.login_switch.set_active(self.manager.get_launch_at_login())
        self.login_switch.connect("notify::active", self._on_login_switch_changed)
        
        login_hbox.pack_start(login_label, False, False, 0)
        login_hbox.pack_end(self.login_switch, False, False, 0)
        login_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        login_card.get_style_context().add_class("card")
        login_card.pack_start(login_hbox, False, False, 0)
        vbox.pack_start(login_card, False, False, 0)

        vbox.pack_start(Gtk.Label(""), True, True, 0)  # Spacer

        # Error
        self.error_label = Gtk.Label()
        self.error_label.get_style_context().add_class("error-label")
        self.error_label.set_line_wrap(True)
        self.error_label.set_no_show_all(True)
        vbox.pack_start(self.error_label, False, False, 0)

        # Footer
        footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        self.footer_label = Gtk.Label(label="Updated just now")
        self.footer_label.get_style_context().add_class("footer-label")
        
        quit_btn = Gtk.Button(label="Quit")
        quit_btn.get_style_context().add_class("quit-button")
        quit_btn.connect("clicked", lambda _: Gtk.main_quit())
        
        footer.pack_start(self.footer_label, False, False, 0)
        footer.pack_end(quit_btn, False, False, 0)
        vbox.pack_start(footer, False, False, 0)

        return vbox

    def _build_setup_screen(self) -> Gtk.Widget:
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        
        vbox.pack_start(Gtk.Label(""), True, True, 12)  # Spacer
        
        # Icon
        icon_box = Gtk.Box()
        icon_box.set_size_request(64, 64)
        icon_box.set_halign(Gtk.Align.CENTER)
        icon_box.get_style_context().add_class("icon-circle")
        icon = Gtk.Image.new_from_icon_name("utilities-terminal-symbolic", Gtk.IconSize.DIALOG)
        icon_box.pack_start(icon, True, True, 0)
        vbox.pack_start(icon_box, False, False, 8)
        
        title = Gtk.Label(label="Connect Claude Code")
        title.get_style_context().add_class("header-label")
        vbox.pack_start(title, False, False, 3)
        
        desc = Gtk.Label(label="Usage is read from Claude Code. Install it — or the VS Code extension — and sign in to start tracking.")
        desc.set_line_wrap(True)
        desc.set_justify(Gtk.Justification.CENTER)
        desc.get_style_context().add_class("caption")
        desc.set_margin_start(22)
        desc.set_margin_end(22)
        vbox.pack_start(desc, False, False, 9)
        
        # Steps
        steps_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        steps_card.get_style_context().add_class("card")
        steps_card.set_margin_start(20)
        steps_card.set_margin_end(20)
        
        def add_step(num, text):
            hb = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            nl = Gtk.Label(label=str(num))
            nl.get_style_context().add_class("pct-orange")
            tl = Gtk.Label(label=text)
            tl.set_line_wrap(True)
            tl.set_xalign(0)
            hb.pack_start(nl, False, False, 0)
            hb.pack_start(tl, True, True, 0)
            steps_card.pack_start(hb, False, False, 0)
            
        add_step(1, "Install Claude Code or the VS Code extension")
        add_step(2, "Sign in with your Claude account")
        add_step(3, "Click Try Again below")
        vbox.pack_start(steps_card, False, False, 8)
        
        # Buttons
        btn_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        btn_box.set_margin_start(20)
        btn_box.set_margin_end(20)
        
        def open_url(url):
            subprocess.Popen(["xdg-open", url])
            
        btn1 = Gtk.Button(label="Install Claude Code")
        btn1.connect("clicked", lambda _: open_url("https://claude.com/claude-code"))
        btn_box.pack_start(btn1, False, False, 0)
        
        btn2 = Gtk.Button(label="Get VS Code Extension")
        btn2.connect("clicked", lambda _: open_url("https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code"))
        btn_box.pack_start(btn2, False, False, 0)
        vbox.pack_start(btn_box, False, False, 7)
        
        retry_btn = Gtk.Button(label="Try Again")
        retry_btn.set_relief(Gtk.ReliefStyle.NONE)
        retry_btn.connect("clicked", lambda _: self.manager.fetch_async())
        vbox.pack_start(retry_btn, False, False, 0)
        
        vbox.pack_start(Gtk.Label(""), True, True, 12)  # Spacer
        return vbox

    def _build_expired_screen(self) -> Gtk.Widget:
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        vbox.pack_start(Gtk.Label(""), True, True, 12)
        
        icon_box = Gtk.Box()
        icon_box.set_size_request(64, 64)
        icon_box.set_halign(Gtk.Align.CENTER)
        icon_box.get_style_context().add_class("icon-circle")
        icon = Gtk.Image.new_from_icon_name("appointment-missed-symbolic", Gtk.IconSize.DIALOG)
        icon_box.pack_start(icon, True, True, 0)
        vbox.pack_start(icon_box, False, False, 8)
        
        title = Gtk.Label(label="Session expired")
        title.get_style_context().add_class("header-label")
        vbox.pack_start(title, False, False, 3)
        
        desc = Gtk.Label(label="Your Claude Code token expired. Run any Claude Code command to refresh it, then try again.")
        desc.set_line_wrap(True)
        desc.set_justify(Gtk.Justification.CENTER)
        desc.get_style_context().add_class("caption")
        desc.set_margin_start(24)
        desc.set_margin_end(24)
        vbox.pack_start(desc, False, False, 11)
        
        btn_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        btn_box.set_margin_start(24)
        btn_box.set_margin_end(24)
        retry_btn = Gtk.Button(label="Try Again")
        retry_btn.connect("clicked", lambda _: self.manager.fetch_async())
        btn_box.pack_start(retry_btn, False, False, 0)
        vbox.pack_start(btn_box, False, False, 0)
        
        vbox.pack_start(Gtk.Label(""), True, True, 12)
        return vbox

    def _on_login_switch_changed(self, switch, gparam):
        self.manager.set_launch_at_login(switch.get_active())

    def _refresh_ui(self):
        # Update stack based on state
        if self.manager.token_missing:
            self.stack.set_visible_child_name("setup")
            return
        if self.manager.token_expired:
            self.stack.set_visible_child_name("expired")
            return
            
        self.stack.set_visible_child_name("main")

        usage = self.manager.usage
        
        # Header spinner
        if self.manager.is_loading:
            self.refresh_spinner.start()
            self.refresh_stack.set_visible_child_name("spinner")
        else:
            self.refresh_spinner.stop()
            self.refresh_stack.set_visible_child_name("icon")

        # Session
        self.session_pct.set_text(f"{int(round(usage.session_percent))}%" if usage.session_active else "0%")
        self.session_bar.set_fraction(min(usage.session_percent / 100.0, 1.0) if usage.session_active else 0.0)
        self.session_caption.set_text(f"Resets in {usage.session_reset_in}" if usage.session_active else "Start a conversation to begin tracking")
        self.session_caption_icon.set_visible(not usage.session_active)
        
        ctx = self.session_bar.get_style_context()
        ctx.remove_class("progress-green")
        ctx.remove_class("progress-orange")
        ctx.remove_class("progress-red")
        if not usage.session_active:
            pass
        elif usage.session_percent >= 86: ctx.add_class("progress-red")
        elif usage.session_percent >= 61: ctx.add_class("progress-orange")
        else: ctx.add_class("progress-green")

        # Weekly
        self.weekly_pct.set_text(f"{int(round(usage.weekly_percent))}%" if usage.weekly_active else "0%")
        self.weekly_bar.set_fraction(min(usage.weekly_percent / 100.0, 1.0) if usage.weekly_active else 0.0)
        self.weekly_caption.set_text(f"Resets {usage.weekly_resets_at}" if usage.weekly_active else "No weekly usage recorded yet")
        self.weekly_caption_icon.set_visible(not usage.weekly_active)
        
        ctx = self.weekly_bar.get_style_context()
        ctx.remove_class("progress-green")
        ctx.remove_class("progress-orange")
        ctx.remove_class("progress-red")
        if not usage.weekly_active:
            pass
        elif usage.weekly_percent >= 86: ctx.add_class("progress-red")
        elif usage.weekly_percent >= 61: ctx.add_class("progress-orange")
        else: ctx.add_class("progress-green")

        # Stats
        self.dr_val.set_text(f"{usage.daily_routines} / {usage.daily_routines_max}")
        self.uc_val.set_text("ON" if usage.usage_credits else "OFF")

        # Sync launch-at-login switch (autostart file may change externally)
        self.login_switch.handler_block_by_func(self._on_login_switch_changed)
        self.login_switch.set_active(self.manager.get_launch_at_login())
        self.login_switch.handler_unblock_by_func(self._on_login_switch_changed)

        # Footer
        if self.manager.error_message:
            self.error_label.set_text(self.manager.error_message)
            self.error_label.show()
        else:
            self.error_label.hide()
            
        self.footer_label.set_text(f"Updated {usage.last_updated}")

    def toggle(self):
        if self.is_visible():
            self.hide()
        else:
            self._position_window()
            self.show_all()
            self.present()
            self._refresh_ui()

    def _position_window(self):
        screen = Gdk.Screen.get_default()
        display = screen.get_display()
        mon = display.get_primary_monitor()
        if not mon:
            return
            
        # Try to get usable workarea
        workarea = mon.get_workarea()
        full_geom = mon.get_geometry()
        
        win_w, win_h = 280, 460
        
        if workarea.y > full_geom.y:
            # Taskbar at top
            x = workarea.x + workarea.width - win_w - 10
            y = workarea.y + 5
        else:
            # Taskbar at bottom (or left/right)
            x = workarea.x + workarea.width - win_w - 10
            y = workarea.y + workarea.height - win_h - 5
            
        self.move(x, y)

    def _on_focus_out(self, widget, event):
        self.hide()
        return False

    def _on_key_press(self, widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.hide()
            return True
        return False
