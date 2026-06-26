#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

pip install -r requirements-dev.txt

pyinstaller --onefile --name claude-usage-bar \
    --add-data "assets/icon.png:assets" \
    --exclude-module gi \
    claude_usage_bar.py

# Build AppDir
mkdir -p ClaudeUsageBar.AppDir/usr/bin
cp dist/claude-usage-bar ClaudeUsageBar.AppDir/usr/bin/
cp assets/icon.png ClaudeUsageBar.AppDir/
cat > ClaudeUsageBar.AppDir/claude-usage-bar.desktop << EOF
[Desktop Entry]
Name=Claude Usage Bar
Exec=claude-usage-bar
Icon=icon
Type=Application
Categories=Utility;
EOF
cat > ClaudeUsageBar.AppDir/AppRun << 'EOF'
#!/bin/bash
exec "$(dirname "$0")/usr/bin/claude-usage-bar" "$@"
EOF
chmod +x ClaudeUsageBar.AppDir/AppRun

# Download appimagetool if not present
if [ ! -f "appimagetool" ]; then
    wget -q -O appimagetool https://github.com/AppImage/AppImageKit/releases/latest/download/appimagetool-x86_64.AppImage
    chmod +x appimagetool
fi
./appimagetool ClaudeUsageBar.AppDir ClaudeUsageBar-linux-x86_64.AppImage
