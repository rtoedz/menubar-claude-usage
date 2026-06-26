# Claude Usage Bar — Linux

System-tray port of the macOS menu-bar app. Python 3 + GTK3 + AppIndicator.
Same behavior: tray label like `🟠 61% · 2h 8m`, click → usage popover, polls
the Anthropic usage endpoint every 2 min, 60 s local countdown.

## 1. Install runtime dependencies

The app uses only the Python standard library plus GObject bindings for
GTK3 and AppIndicator. No `pip install` needed to run.

| Distro | Command |
|--------|---------|
| Ubuntu / Debian | `sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1` |
| Fedora / RHEL | `sudo dnf install python3-gobject gtk3 libayatana-appindicator-gtk3` |
| Arch | `sudo pacman -S python-gobject gtk3 libayatana-appindicator` |
| openSUSE | `sudo zypper install python3-gobject gtk3 libayatana-appindicator3-1` |

> On systems that still ship the older Unity indicator
> (`gir1.2-appindicator3-0.1`), the app falls back to it automatically.
>
> **GNOME 45+** hides AppIndicator icons unless the
> [AppIndicator/KStatusNotifierItem Support](https://extensions.gnome.org/extension/615/appindicator-support/)
> shell extension is installed.

## 2. Install the app

### Local (no root)

```bash
./build/build_local.sh        # installs into ~/.local
claude-usage-bar              # run it (also appears in your app menu)
./build/uninstall_local.sh    # remove
```

### System packages

```bash
./build/build_deb.sh          # .deb   (needs: fpm)
./build/build_rpm.sh          # .rpm   (needs: fpm)
./build/build_appimage.sh     # AppImage (needs: pyinstaller, wget)
```

## 3. Credentials

Reads the Claude Code OAuth token, same priority as macOS:

1. `$CLAUDE_CONFIG_DIR/.credentials.json`
2. `~/.claude/.credentials.json`

No file → **Connect Claude Code** screen. Token expired / 401 →
**Session expired** screen. There is no separate web login.

## Notes

- **Launch at login** writes `~/.config/autostart/claude-usage-bar.desktop`.
- **Wayland:** the tray works via XWayland; exact popover position is chosen by
  the compositor (the `move()` hint is honored only on X11).
- Run from a normal terminal — VS Code's *snap* terminal pollutes `GTK_PATH`
  and can break GTK library loading.
