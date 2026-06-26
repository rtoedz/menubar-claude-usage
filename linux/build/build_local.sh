#!/bin/bash
# Install Claude Usage Bar into the user's ~/.local tree — no root, no packaging
# tools. Registers a launcher, an application-menu entry, and a themed icon.
set -euo pipefail

cd "$(dirname "$0")/.."

INSTALL_DIR="$HOME/.local/share/claude-usage-bar"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/claude-usage-bar"
ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
APP_DIR="$HOME/.local/share/applications"

mkdir -p "$INSTALL_DIR/assets" "$BIN_DIR" "$ICON_DIR" "$APP_DIR"

# Program files + bundled assets
cp claude_usage_bar.py usage_manager.py popover_window.py "$INSTALL_DIR/"
cp assets/icon.png "$INSTALL_DIR/assets/"

# Themed icon (resolved by name "claude-usage-bar" in .desktop files)
cp assets/icon.png "$ICON_DIR/claude-usage-bar.png"

# Launcher
cat > "$BIN" << EOF
#!/bin/bash
exec python3 "$INSTALL_DIR/claude_usage_bar.py" "\$@"
EOF
chmod +x "$BIN"

# Application-menu entry
cat > "$APP_DIR/claude-usage-bar.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Claude Usage Bar
Comment=Claude Pro/Max usage in your system tray
Exec=claude-usage-bar
Icon=claude-usage-bar
Categories=Utility;
Terminal=false
EOF

# Refresh caches (best effort; harmless if the tools are missing)
command -v gtk-update-icon-cache >/dev/null 2>&1 && \
    gtk-update-icon-cache -q -t -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database -q "$APP_DIR" 2>/dev/null || true

echo "✅ Installed."
echo "   Run now:        claude-usage-bar"
echo "   Or find it in your application menu as 'Claude Usage Bar'."

# PATH sanity check
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo
        echo "⚠️  $BIN_DIR is not in your PATH. Add this to ~/.bashrc (or ~/.profile):"
        echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
esac
