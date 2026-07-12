#!/bin/bash
# 拖放式 DMG：背景圖 + Applications 捷徑 + 圖標佈局。
# 只用系統工具（hdiutil + osascript + Finder），不依賴 create-dmg。
# 用法：make-dmg.sh <app-bundle> <out-dmg> <background-tiff>
set -euo pipefail

APP="$1"; DMG="$2"; BG="$3"
VOL="Sense"
APP_NAME="$(basename "$APP")"
STAGE="$(mktemp -d)"
TMPDMG="$(mktemp -u).dmg"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  rm -rf "$STAGE" "$TMPDMG" 2>/dev/null || true
}
trap cleanup EXIT

# 清殘留掛載（前次失敗可能留著）
for v in /Volumes/$VOL /Volumes/$VOL\ *; do
  [ -d "$v" ] && hdiutil detach "$v" -force >/dev/null 2>&1 || true
done

# 內容：app + Applications symlink + 隱藏背景圖
mkdir -p "$STAGE/.background"
cp "$BG" "$STAGE/.background/bg.tiff"
cp -R "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

# 可寫 DMG（佈局完再轉壓縮唯讀）
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$TMPDMG" >/dev/null
MOUNT="$(hdiutil attach "$TMPDMG" -nobrowse -noautoopen | grep -o '/Volumes/.*' | head -1)"
sleep 2

# Finder 佈局（背景圖、視窗大小、圖標位置；背景圖 600×400 對齊內容區）
osascript - "$VOL" "$MOUNT" "$APP_NAME" <<'APPLESCRIPT'
on run argv
  set vol to item 1 of argv
  set mountPath to item 2 of argv
  set appName to item 3 of argv
  tell application "Finder"
    tell disk vol
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {300, 140, 900, 562}
      set opts to the icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 96
      set background picture of opts to POSIX file (mountPath & "/.background/bg.tiff")
      set position of item appName of container window to {150, 210}
      set position of item "Applications" of container window to {450, 210}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT
sleep 2
sync

hdiutil detach "$MOUNT" -quiet
rm -f "$DMG"
hdiutil convert "$TMPDMG" -format UDZO -o "$DMG" >/dev/null
echo "[OK] ${DMG} (拖放佈局)"
