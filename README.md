# Espresso ☕

Minimale macOS-Menüleisten-App, die den Mac wach hält — ein schlanker Ersatz
für Amphetamine/Caffeine. Kein Fenster, kein Dock-Icon, nur ein Symbol in der
Menüleiste.

Solange Espresso aktiv ist, geht das Display nicht in den Ruhezustand
(via IOKit-Power-Assertion `PreventUserIdleDisplaySleep`).

## Bauen & Installieren

Voraussetzung: macOS 13+, Command Line Tools mit Swift (kein Xcode nötig).

```sh
make app       # baut Espresso.app im Projektordner (ad-hoc signiert)
make install   # baut + installiert nach /Applications und startet die App
make clean     # entfernt Build-Artefakte und das App-Bundle
```

## Bedienung

Das Icon in der Menüleiste zeigt den Zustand:

- **Leere Tasse** (`cup.and.saucer`) → aus, der Mac darf schlafen.
- **Volle Tasse** (`cup.and.saucer.fill`) → aktiv, der Mac bleibt wach.

Steuerung:

- **Linksklick** — Wachhalten an/aus schalten (Toggle).
- **Rechtsklick** (oder **Ctrl + Linksklick**) — Menü mit:
  - Statuszeile (aktiv / aus),
  - „Bei Anmeldung starten“ (Autostart via `SMAppService`),
  - „Espresso beenden“.

Beim allerersten Start versucht Espresso einmalig, sich selbst als
Login-Item zu registrieren (Autostart). Das lässt sich jederzeit über das
Menü umschalten.

## Zuklapp-Modus

Standardmäßig hält Espresso nur Display- und Idle-Sleep an — klappt man den
Deckel zu, schläft der Mac trotzdem. Der optionale **Zuklapp-Modus** hält den
Mac zusätzlich **bei geschlossenem Deckel** wach (z. B. am externen Monitor
oder für einen langen Download „im Rucksack“).

Technisch geschieht das über `pmset -a disablesleep 1`, was root-Rechte
verlangt. Espresso bringt dafür **kein** dauerhaft laufendes Helferprogramm mit,
sondern installiert einmalig eine sehr **enge sudoers-Regel** nach
`/etc/sudoers.d/espresso`, die exakt zwei Kommandos ohne Passwort erlaubt —
ohne Wildcards:

```
<benutzer> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

Mehr als „disablesleep an/aus“ kann die App damit nicht.

### Risiken

- **Hitze:** Bei geschlossenem Deckel (etwa im Rucksack) kann der Mac spürbar
  heiß werden, weil die Lüftung eingeschränkt ist.
- **Akku:** Der Akku wird auch mit zugeklapptem Deckel weiter verbraucht.

Espresso weist beim Einrichten und bei der ersten Aktivierung darauf hin.

### Einrichten

Zwei Wege — es reicht einer:

- **Über das Menü:** Rechtsklick → „Zuklapp-Modus einrichten…“. Ein Dialog
  erklärt den Zweck, danach fragt macOS einmalig nach dem Admin-Passwort und
  installiert die Regel.
- **Über das Terminal:**

  ```sh
  make install-helper     # entspricht: sudo bash scripts/install-helper.sh
  ```

Ist die Regel installiert, erscheint im Menü statt des Einrichtungs-Eintrags
die Checkbox **„Zuklapp-Modus (Deckel zu, bleibt wach)“**.

### Deinstallieren

```sh
make uninstall-helper     # entspricht: sudo bash scripts/uninstall-helper.sh
```

Das setzt `disablesleep` zurück und löscht `/etc/sudoers.d/espresso`.

### Verhalten

- **Icon:** Bei aktivem Zuklapp-Modus zeigt die Menüleiste eine **orange
  gefüllte Tasse** (dominiert über den normalen Wachhalte-Zustand).
- **Unabhängig vom Linksklick:** Der Zuklapp-Modus wird nur über das Menü
  geschaltet; der Linksklick-Toggle für das normale Wachhalten bleibt
  unverändert.
- **Überlebt keine App-Neustarts:** Der Modus wird beim Beenden ausgeschaltet
  und beim Start best effort zurückgesetzt — nach einem Absturz bleibt der Mac
  also nicht dauerhaft im Deckel-zu-wach-Zustand.
- **Auto-Aus bei 10 % Akku:** Solange der Modus aktiv ist, prüft Espresso jede
  Minute den Ladestand. Fällt der Akku auf **10 % oder weniger** und der Mac
  hängt **nicht am Netz**, wird der Zuklapp-Modus automatisch deaktiviert.
