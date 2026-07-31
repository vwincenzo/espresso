#!/bin/bash
#
# uninstall-helper.sh — entfernt die sudoers-Regel des Zuklapp-Modus wieder.
#
# Setzt zur Sicherheit zuerst "disablesleep 0" (falls der Modus noch aktiv war,
# soll der Deckel-zu-wach-Zustand nicht als root-Rest zurückbleiben) und löscht
# danach /etc/sudoers.d/espresso. Muss als root laufen.

set -euo pipefail

# --- Root-Prüfung -----------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "Fehler: uninstall-helper.sh muss als root laufen (z. B. via sudo)." >&2
    exit 1
fi

# --- Zuklapp-Zustand sicher zurücknehmen ------------------------------------
# Best effort: schlägt pmset fehl, ist das kein Grund, das Aufräumen der Regel
# abzubrechen — deshalb der Fehler-Fallback.
/usr/bin/pmset -a disablesleep 0 || true

# --- Sudoers-Regel entfernen ------------------------------------------------
rm -f /etc/sudoers.d/espresso

echo "Espresso-Zuklapp-Regel entfernt und disablesleep zurückgesetzt."
