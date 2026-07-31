# Espresso — Build via Swift Package Manager (kein Xcode nötig)

APP_NAME    := Espresso
BUNDLE      := $(APP_NAME).app
BIN         := .build/release/$(APP_NAME)
CONTENTS    := $(BUNDLE)/Contents
MACOS_DIR   := $(CONTENTS)/MacOS
RESOURCES_DIR := $(CONTENTS)/Resources
INSTALL_DIR := /Applications/$(BUNDLE)

.PHONY: app install clean install-helper uninstall-helper

# Baut die Release-Binary und schnürt daraus ein .app-Bundle, das anschließend
# ad-hoc signiert wird. Die Helfer-Skripte für den Zuklapp-Modus werden mit
# ausführbaren Rechten nach Contents/Resources gebündelt.
app:
	swift build -c release
	rm -rf $(BUNDLE)
	mkdir -p $(MACOS_DIR)
	mkdir -p $(RESOURCES_DIR)
	cp $(BIN) $(MACOS_DIR)/$(APP_NAME)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	install -m 0755 scripts/install-helper.sh $(RESOURCES_DIR)/install-helper.sh
	install -m 0755 scripts/uninstall-helper.sh $(RESOURCES_DIR)/uninstall-helper.sh
	codesign --force --sign - $(BUNDLE)
	@echo "==> $(BUNDLE) gebaut und signiert."

# Baut die App und installiert sie nach /Applications (alte Version wird entfernt).
install: app
	-killall $(APP_NAME) 2>/dev/null && sleep 1 || true
	rm -rf $(INSTALL_DIR)
	ditto $(BUNDLE) $(INSTALL_DIR)
	open $(INSTALL_DIR)
	@echo "==> $(INSTALL_DIR) installiert und gestartet."

# Richtet die enge sudoers-Regel für den Zuklapp-Modus ein (fragt nach dem
# Admin-Passwort). Alternative zum Menü-Eintrag „Zuklapp-Modus einrichten…“.
install-helper:
	sudo bash scripts/install-helper.sh

# Entfernt die sudoers-Regel wieder und setzt disablesleep zurück.
uninstall-helper:
	sudo bash scripts/uninstall-helper.sh

# Entfernt Build-Artefakte und das lokale App-Bundle.
clean:
	swift package clean
	rm -rf .build
	rm -rf $(BUNDLE)
	@echo "==> Aufgeräumt."
