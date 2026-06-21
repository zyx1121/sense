# PRODUCT = SwiftPM 產物 / binary（專案名，不變）；APP_NAME = 對外應用名（.app / 顯示名 / DMG）
PRODUCT    := kilo-sense
APP_NAME   := Kilo
BUNDLE_ID  := tw.zyx.kilo
BIN_PATH   := .build/release/$(PRODUCT)
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

.PHONY: all build locales bundle run clean rebuild logs install dmg release publish

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
	@cp Resources/MenubarIcon.pdf $(CONTENTS)/Resources/MenubarIcon.pdf
	@codesign --force --options runtime --entitlements Resources/kilo-sense.entitlements --sign $(SIGN_ID) $(APP_BUNDLE)
	@echo "[OK] $(APP_BUNDLE) signed with $(SIGN_ID)"

run: bundle
	open $(APP_BUNDLE)

rebuild: clean bundle

# 安裝到 /Applications（開機自啟與穩定 TCC 都需要 app 在這裡）
install: bundle
	@rm -rf /Applications/kilo-sense.app   # 清舊名安裝（rename 遷移）
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "[OK] installed to /Applications/$(APP_NAME).app"

# 打 DMG（拖放佈局；開發態 app，分發用走 release）
dmg: bundle
	@bash scripts/make-dmg.sh $(APP_BUNDLE) $(DMG) Resources/dmg-background.tiff

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
	@cp Resources/MenubarIcon.pdf $(CONTENTS)/Resources/MenubarIcon.pdf
	@codesign --force --options runtime --timestamp --entitlements Resources/kilo-sense.entitlements --sign "$(DEV_ID_APP)" $(APP_BUNDLE)
	@codesign --verify --strict --verbose=2 $(APP_BUNDLE)
	@echo "→ notarizing app（首次數分鐘）…"
	@ditto -c -k --keepParent $(APP_BUNDLE) build/$(APP_NAME)-notarize.zip
	@xcrun notarytool submit build/$(APP_NAME)-notarize.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	@xcrun stapler staple $(APP_BUNDLE)   # ticket 釘進 app 本身 — 離線也過 Gatekeeper
	@rm -f build/$(APP_NAME)-notarize.zip
	@bash scripts/make-dmg.sh $(APP_BUNDLE) $(DMG) Resources/dmg-background.tiff
	@echo "→ notarizing dmg…"
	@xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait   # DMG 自己也要 notarize 才能 staple
	@xcrun stapler staple $(DMG)
	@echo "[OK] notarized + stapled（app + dmg）：$(DMG)"

# 本地發版：公證好的 DMG 傳上 GitHub Release（簽名私鑰不出本機，不走 CI）
# tag = v<版本>（取自 Info.plist）；版本已存在就先 bump CFBundleShortVersionString
publish: release
	gh release create v$(VERSION) $(DMG) --title "v$(VERSION)" --generate-notes

# 即時 Telemetry（asr / polish / agent / shake）
logs:
	log stream --info --predicate 'subsystem == "tw.zyx.kilo"' --style compact

clean:
	rm -rf .build build
