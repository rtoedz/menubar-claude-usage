#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Check for fpm
if ! command -v fpm &> /dev/null; then
    echo "fpm is required. Install with: gem install fpm"
    exit 1
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

INSTALL_DIR="$STAGING_DIR/usr/share/claude-usage-bar"
BIN_DIR="$STAGING_DIR/usr/bin"
ICON_DIR="$STAGING_DIR/usr/share/icons/hicolor/512x512/apps"
APP_DIR="$STAGING_DIR/usr/share/applications"

mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$ICON_DIR" "$APP_DIR"

cp claude_usage_bar.py usage_manager.py popover_window.py "$INSTALL_DIR/"
cp -r assets "$INSTALL_DIR/"
cp assets/icon.png "$ICON_DIR/claude-usage-bar.png"

cat > "$APP_DIR/claude-usage-bar.desktop" << EOF
[Desktop Entry]
Name=Claude Usage Bar
Exec=claude-usage-bar
Icon=claude-usage-bar
Type=Application
Categories=Utility;
EOF

cat > "$BIN_DIR/claude-usage-bar" << EOF
#!/bin/bash
exec python3 /usr/share/claude-usage-bar/claude_usage_bar.py "\$@"
EOF
chmod +x "$BIN_DIR/claude-usage-bar"

fpm -s dir -t rpm \
    -n claude-usage-bar \
    -v 1.0.0 \
    --depends python3 \
    --depends python3-gobject \
    --depends gtk3 \
    --depends libayatana-appindicator \
    --description "Claude Usage Bar for Linux" \
    -C "$STAGING_DIR" .
