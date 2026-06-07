APP_NAME   := kilo
BUNDLE_ID  := tw.zyx.kilo
BIN_PATH   := .build/release/$(APP_NAME)
APP_BUNDLE := build/$(APP_NAME).app
CONTENTS   := $(APP_BUNDLE)/Contents
VERSION    := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG        := build/$(APP_NAME)-$(VERSION).dmg

# 日常開發簽名 — 預設 ad-hoc；Apple Development cert hash 放 Makefile.local（gitignored）覆蓋
SIGN_ID ?= -
# 分發用 — Developer ID Application cert + notarytool keychain profile，都放 Makefile.local
DEV_ID_APP ?=
NOTARY_PROFILE ?= kilo-notary
-include Makefile.local

.PHONY: all build locales bundle run clean rebuild logs install dmg release

all: bundle

build:
	swift build -c release

# 純 CLI 跑，dump SpeechTranscriber.supportedLocales（不需打包/權限）
locales: build
	@$(BIN_PATH) --locales

# 組 .app + 簽名（開發態：Apple Development / ad-hoc）
bundle: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(BIN_PATH) $(CONTENTS)/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	@codesign --force --options runtime --sign $(SIGN_ID) $(APP_BUNDLE)
	@echo "[OK] $(APP_BUNDLE) signed with $(SIGN_ID)"

run: bundle
	open $(APP_BUNDLE)

rebuild: clean bundle

# 安裝到 /Applications（開機自啟與穩定 TCC 都需要 app 在這裡）
install: bundle
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "[OK] installed to /Applications/$(APP_NAME).app"

# 打 DMG（開發態 app；分發用走 release）
dmg: bundle
	@rm -f $(DMG)
	@hdiutil create -volname "$(APP_NAME)" -srcfolder $(APP_BUNDLE) -ov -format UDZO $(DMG) >/dev/null
	@echo "[OK] $(DMG)"

# 完整分發：Developer ID 簽 + notarize + staple + DMG。
# 前置（一次性）：① Apple Developer Program 簽發 Developer ID Application cert 並安裝
#   ② xcrun notarytool store-credentials "$(NOTARY_PROFILE)" --apple-id <id> --team-id <team> --password <app-specific-pw>
#   ③ Makefile.local 設 DEV_ID_APP="Developer ID Application: <Name> (<TEAMID>)"
release: build
	@test -n "$(DEV_ID_APP)" || { echo "✗ 需在 Makefile.local 設 DEV_ID_APP（見 Makefile release 註解）"; exit 1; }
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(BIN_PATH) $(CONTENTS)/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	@codesign --force --options runtime --timestamp --sign "$(DEV_ID_APP)" $(APP_BUNDLE)
	@codesign --verify --strict --verbose=2 $(APP_BUNDLE)
	@rm -f $(DMG)
	@hdiutil create -volname "$(APP_NAME)" -srcfolder $(APP_BUNDLE) -ov -format UDZO $(DMG) >/dev/null
	@echo "→ notarizing $(DMG)（首次數分鐘）…"
	@xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	@xcrun stapler staple $(DMG)
	@echo "[OK] notarized + stapled $(DMG)"

# 即時 Telemetry（asr / polish / agent / shake）
logs:
	log stream --info --predicate 'subsystem == "tw.zyx.kilo"' --style compact

clean:
	rm -rf .build build
