#!/bin/bash
#
# install-helper.sh — richtet die enge sudoers-Regel für Espressos Zuklapp-Modus ein.
#
# Der Zuklapp-Modus hält den Mac bei geschlossenem Deckel wach über
# "pmset -a disablesleep 1", was root-Rechte verlangt. Damit die App das ohne
# ständige Passwortabfrage darf, wird EINMALIG eine sehr enge sudoers-Regel nach
# /etc/sudoers.d/espresso geschrieben: nur exakt die beiden pmset-Aufrufe, ohne
# Wildcards, ohne Passwort. Alles andere bleibt passwortpflichtig.
#
# Muss als root laufen (per sudo bzw. "with administrator privileges").

set -euo pipefail

# --- Root-Prüfung -----------------------------------------------------------
# Ohne root lässt sich nichts nach /etc/sudoers.d schreiben — sofort abbrechen.
if [ "$(id -u)" -ne 0 ]; then
    echo "Fehler: install-helper.sh muss als root laufen (z. B. via sudo)." >&2
    exit 1
fi

# --- Zielbenutzer ermitteln -------------------------------------------------
# Wer bekommt die Regel? Bevorzugt der über sudo aufrufende Nutzer ($SUDO_USER),
# sonst der aktuell an der Konsole angemeldete Nutzer. root/leer ist kein
# gültiges Ziel — die Regel soll einem normalen Benutzer gehören.
TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(stat -f %Su /dev/console 2>/dev/null || true)"
fi

if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "Fehler: konnte keinen gültigen Zielbenutzer ermitteln (weder \$SUDO_USER noch Konsolen-Nutzer)." >&2
    exit 1
fi

# --- Benutzername validieren ------------------------------------------------
# WICHTIG: $TARGET_USER wird gleich in eine sudoers-Zeile interpoliert. Nur
# harmlose Unix-Benutzernamen zulassen ([a-z_] gefolgt von [a-z0-9_-]), damit
# keine Sonderzeichen die Regel manipulieren können. Alles andere: Abbruch.
# bash-eigenes [[ =~ ]] prüft den GESAMTEN String (nicht zeilenweise wie grep) —
# ^/$ ankern an Anfang/Ende des kompletten Werts, ein enthaltenes Newline führt
# damit zwingend zum Abbruch (grep hätte bei mehrzeiligem Wert schon Erfolg
# gemeldet, sobald EINE Zeile passt).
if [[ ! "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Fehler: Benutzername '$TARGET_USER' enthält unerlaubte Zeichen — Abbruch." >&2
    exit 1
fi

# --- Sudoers-Inhalt ---------------------------------------------------------
# EXAKT diese beiden Kommandos, keine Wildcards. Genau "disablesleep 1" zum
# Aktivieren und "disablesleep 0" zum Ausschalten — mehr kann die App nicht.
SUDOERS_LINE="$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"

DEST="/etc/sudoers.d/espresso"

# --- In Temp-Datei schreiben und mit visudo prüfen --------------------------
# Erst in eine temporäre Datei schreiben, syntaktisch mit "visudo -c" prüfen und
# nur bei fehlerfreier Prüfung atomar an den Zielort installieren. So kann eine
# fehlerhafte Regel niemals das sudoers-System beschädigen.
TMP_FILE="$(mktemp /tmp/espresso-sudoers.XXXXXX)"
# Temp-Datei in jedem Fall (auch bei Fehler) wieder entfernen.
trap 'rm -f "$TMP_FILE"' EXIT

printf '%s\n' "$SUDOERS_LINE" > "$TMP_FILE"

if ! visudo -c -f "$TMP_FILE" >/dev/null 2>&1; then
    echo "Fehler: visudo hat die erzeugte Regel abgelehnt — es wird nichts geändert." >&2
    exit 1
fi

# --- Atomar installieren ----------------------------------------------------
# 0440, root:wheel — genau das, was sudo für Dateien in sudoers.d erwartet.
install -m 0440 -o root -g wheel "$TMP_FILE" "$DEST"

echo "Espresso-Zuklapp-Regel installiert für Benutzer '$TARGET_USER' ($DEST)."
