#!/bin/bash
# Remove a local (~/.local) install created by build_local.sh.
set -euo pipefail

rm -rf "$HOME/.local/share/claude-usage-bar"
rm -f  "$HOME/.local/bin/claude-usage-bar"
rm -f  "$HOME/.local/share/icons/hicolor/512x512/apps/claude-usage-bar.png"
rm -f  "$HOME/.local/share/applications/claude-usage-bar.desktop"
rm -f  "$HOME/.config/autostart/claude-usage-bar.desktop"

command -v gtk-update-icon-cache >/dev/null 2>&1 && \
    gtk-update-icon-cache -q -t -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true

echo "✅ Claude Usage Bar removed."
