import AppKit
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement
import os

// MARK: - Wachhalten (Power-Assertion)

/// Kapselt die IOKit-Power-Assertion, die den Display-/Idle-Sleep verhindert.
/// `isActive` ist genau dann true, wenn wirklich eine Assertion erzeugt wurde.
final class WakeGuard {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private(set) var isActive = false

    func activate() {
        guard !isActive else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Espresso hält den Mac wach" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            isActive = true
        } else {
            // Fehlschlag nicht verschlucken — sonst klickt der Nutzer ins Leere,
            // ohne zu merken, dass der Mac gar nicht wachgehalten wird.
            os_log("IOPMAssertionCreateWithName fehlgeschlagen: 0x%08x", type: .error, result)
        }
    }

    func deactivate() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isActive = false
    }

    func toggle() {
        if isActive { deactivate() } else { activate() }
    }
}

// MARK: - Zuklapp-Modus (Deckel zu, bleibt wach)

/// Kapselt den „Zuklapp-Modus“: Der Mac bleibt bei geschlossenem Deckel wach,
/// realisiert über `pmset -a disablesleep 1` (root). Autorisiert wird das nicht
/// über ein eingebettetes root-Helferprogramm, sondern über eine einmalig
/// installierte, sehr enge sudoers-Regel (siehe scripts/install-helper.sh), die
/// exakt zwei Kommandos ohne Passwort erlaubt:
///   /usr/bin/pmset -a disablesleep 1   (aktivieren)
///   /usr/bin/pmset -a disablesleep 0   (ausschalten)
///
/// Aus Sicherheitsgründen werden **ausschließlich feste Argument-Arrays** an
/// `Process` übergeben — niemals ein zusammengesetzter Shell-String. `isActive`
/// ist analog zu `WakeGuard` genau dann true, wenn das Kommando erfolgreich lief.
final class LidGuard {
    private(set) var isActive = false

    /// Prüft, ob die enge sudoers-Regel installiert ist. `sudo -n -l <cmd>` gibt
    /// Exit 0 zurück, wenn der Nutzer genau dieses Kommando ohne Passwort
    /// ausführen darf — sonst ungleich 0. `-n` verhindert jede Passwortabfrage.
    static func helperInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]
        // Ausgabe verwerfen — es zählt allein der Exit-Code.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return runWithWatchdog(process)
    }

    func activate() {
        guard !isActive else { return }
        // isActive nur bei tatsächlichem Erfolg setzen — sonst glaubt die App,
        // der Deckel-zu-Modus laufe, obwohl pmset gar nicht durchkam.
        if LidGuard.runPmset(disableSleep: true) {
            isActive = true
        } else {
            os_log("Zuklapp-Modus konnte nicht aktiviert werden (pmset disablesleep 1 fehlgeschlagen).", type: .error)
        }
    }

    func deactivate() {
        guard isActive else { return }
        // Zustand nur bei Erfolg zurücksetzen: Schlägt das Ausschalten fehl, bleibt
        // der Deckel-zu-Modus real aktiv — dann darf isActive nicht auf false lügen.
        if LidGuard.runPmset(disableSleep: false) {
            isActive = false
        } else {
            os_log("Zuklapp-Modus konnte nicht deaktiviert werden (pmset disablesleep 0 fehlgeschlagen).", type: .error)
        }
    }

    /// Räumt einen möglichen „disablesleep 1“-Rest best effort auf, ohne den
    /// internen Zustand zu berühren. Wird beim App-Start genutzt, damit der Modus
    /// niemals einen App-Neustart (etwa nach einem Absturz) überlebt.
    static func bestEffortReset() {
        _ = runPmset(disableSleep: false)
    }

    /// Führt genau `sudo -n /usr/bin/pmset -a disablesleep <0|1>` aus. Nur ein
    /// festes Argument-Array, kein Shell-String. Rückgabe: Exit-Code == 0.
    @discardableResult
    private static func runPmset(disableSleep: Bool) -> Bool {
        let value = disableSleep ? "1" : "0"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]
        return runWithWatchdog(process)
    }

    /// Startet den Prozess und wartet höchstens `timeout` Sekunden auf sein Ende.
    /// Kehrt `sudo` nicht rechtzeitig zurück (z. B. weil es auf einem verzeichnis-
    /// gebundenen/verwalteten Mac auf einen Netzwerk-Lookup wartet), wird der Prozess
    /// abgebrochen und `false` geliefert — so kann ein hängendes sudo die Menüleisten-
    /// App nicht unbegrenzt blockieren (Beachball). Rückgabe: true genau dann, wenn der
    /// Prozess mit Exit-Code 0 endete.
    private static func runWithWatchdog(_ process: Process, timeout: TimeInterval = 5) -> Bool {
        do {
            try process.run()
        } catch {
            os_log("sudo-Prozess konnte nicht gestartet werden.", type: .error)
            return false
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            os_log("sudo-Prozess überschritt das Zeitlimit und wurde abgebrochen.", type: .error)
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!          // starke Referenz — sonst verschwindet das Icon
    private let wakeGuard = WakeGuard()
    private let lidGuard = LidGuard()
    private var batteryTimer: Timer?               // läuft nur, solange der Zuklapp-Modus aktiv ist
    private var lidActivity: NSObjectProtocol?     // unterdrückt App Nap, solange der Akku-Wächter läuft
    private let firstLaunchKey = "io.github.vwincenzo.espresso.didAttemptLoginItemRegistration"
    private let lidWarningShownKey = "io.github.vwincenzo.espresso.didShowLidModeWarning"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()

        // Der Zuklapp-Modus darf einen App-Neustart niemals überleben. Falls der
        // Helper installiert ist, beim Start einmal best effort auf „aus“ setzen —
        // so werden Reste nach einem Absturz (App weg, disablesleep aber noch 1)
        // zuverlässig geräumt. Bewusst auf einer Hintergrund-Queue: die beiden
        // sudo-Aufrufe (helperInstalled + bestEffortReset) dürfen die Menüleiste beim
        // Start nicht blockieren. Es wird keine UI berührt, daher kein Main-Thread-Hop nötig.
        DispatchQueue.global(qos: .utility).async {
            if LidGuard.helperInstalled() {
                LidGuard.bestEffortReset()
            }
        }

        // Erststart: einmalig versuchen, den Autostart zu registrieren (Fehler nicht fatal).
        attemptInitialLoginItemRegistration()
    }

    func applicationWillTerminate(_ notification: Notification) {
        wakeGuard.deactivate()
        // Sicherheitsnetz: Zuklapp-Modus beim Beenden ausschalten, damit der Mac
        // nicht mit geschlossenem Deckel wach zurückbleibt.
        lidGuard.deactivate()
        stopBatteryWatcher()
    }

    // MARK: Icon-Status

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        // Der Zuklapp-Modus dominiert die Anzeige: sobald „Deckel zu, bleibt wach“
        // aktiv ist, signalisiert ein oranges, gefülltes Tassensymbol den
        // Sonderzustand — unabhängig davon, ob der normale Wachhalte-Toggle an ist.
        if lidGuard.isActive {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            if let base = NSImage(systemSymbolName: "cup.and.saucer.fill",
                                  accessibilityDescription: "Espresso Zuklapp-Modus aktiv"),
               let colored = base.withSymbolConfiguration(config) {
                colored.isTemplate = false          // Farbe soll erhalten bleiben, nicht eingefärbt werden
                button.image = colored
                button.title = ""
            } else {
                // Fallback, falls Symbol oder Palette-Konfiguration nichts liefern:
                // gewöhnliches Template-Bild plus ein kleiner Punkt als Zuklapp-Marker.
                if let base = NSImage(systemSymbolName: "cup.and.saucer.fill",
                                      accessibilityDescription: "Espresso Zuklapp-Modus aktiv") {
                    base.isTemplate = true
                    button.image = base
                }
                button.title = " •"
            }
            return
        }

        // Normalzustand: gefüllte Tasse = wach, leere Tasse = aus (beide Template).
        let symbolName = wakeGuard.isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
        let description = wakeGuard.isActive ? "Espresso aktiv" : "Espresso aus"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) {
            image.isTemplate = true
            button.image = image
        }
        button.title = ""
    }

    // MARK: Klick-Handling

    @objc private func handleClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let isControlClick = event?.type == .leftMouseUp
            && event?.modifierFlags.contains(.control) == true

        if isRightClick || isControlClick {
            showMenu()
        } else {
            wakeGuard.toggle()
            updateIcon()
        }
    }

    // MARK: Menü (on demand)

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let statusLine = NSMenuItem(title: statusLineText(), action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(.separator())

        // Zuklapp-Modus: entweder der Einrichtungs-Eintrag (Helper fehlt) oder die
        // Umschalt-Checkbox (Helper installiert).
        if LidGuard.helperInstalled() {
            let lidItem = NSMenuItem(
                title: "Zuklapp-Modus (Deckel zu, bleibt wach)",
                action: #selector(toggleLidMode(_:)),
                keyEquivalent: ""
            )
            lidItem.target = self
            lidItem.state = lidGuard.isActive ? .on : .off
            menu.addItem(lidItem)
        } else {
            let setupItem = NSMenuItem(
                title: "Zuklapp-Modus einrichten…",
                action: #selector(setupLidHelper(_:)),
                keyEquivalent: ""
            )
            setupItem.target = self
            menu.addItem(setupItem)
        }

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: "Bei Anmeldung starten",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = isLoginItemActive() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Espresso beenden",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // Klassisches Menü-Anzeige-Pattern:
        // Menü zuweisen, programmatisch klicken — und in menuDidClose wieder entfernen.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Zurücksetzen, sonst feuert der Linksklick nie wieder die Action.
        // Aber erst im nächsten Runloop-Tick: menuDidClose läuft noch innerhalb
        // des Menü-Tracking-Teardowns (Menü wurde via performClick geöffnet). Ein
        // synchrones Nullen hier lässt macOS auf manchen Versionen den unmittelbar
        // folgenden Linksklick verschlucken — genau das Symptom, das die App vermeiden will.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    // MARK: Zuklapp-Modus (Menü-Aktionen & Akku-Wächter)

    /// Baut die Statuszeile aus beiden unabhängigen Zuständen zusammen, z. B.
    /// „Espresso: aktiv · Zuklapp an“ oder schlicht „Espresso: aus“.
    private func statusLineText() -> String {
        let base = wakeGuard.isActive ? "Espresso: aktiv" : "Espresso: aus"
        return lidGuard.isActive ? base + " · Zuklapp an" : base
    }

    /// Menü-Eintrag „Zuklapp-Modus einrichten…“: erklärt den Zweck und startet
    /// nach Bestätigung die einmalige, per Admin-Passwort autorisierte Installation
    /// der engen sudoers-Regel.
    @objc private func setupLidHelper(_ sender: Any?) {
        let intro = NSAlert()
        intro.messageText = "Zuklapp-Modus einrichten"
        intro.informativeText = """
            Damit der Mac bei geschlossenem Deckel wach bleibt, richtet Espresso einmalig \
            eine sehr enge Systemregel ein, die genau zwei pmset-Befehle ohne Passwort erlaubt.

            Dafür ist einmalig dein Admin-Passwort nötig.

            Achtung: Bei geschlossenem Deckel (z. B. im Rucksack) kann der Mac heiß werden, \
            und der Akku wird auch zugeklappt verbraucht.
            """
        intro.alertStyle = .informational
        intro.addButton(withTitle: "Einrichten…")
        intro.addButton(withTitle: "Abbrechen")
        // Accessory-App (LSUIElement): ohne vorherige Aktivierung kann der modale
        // Dialog hinter der Vordergrund-App und ohne Tastaturfokus erscheinen.
        NSApp.activate(ignoringOtherApps: true)
        guard intro.runModal() == .alertFirstButtonReturn else { return }

        // Pfad zum gebündelten Installations-Skript. Kommt ausschließlich aus dem
        // App-Bundle — es werden keinerlei Benutzereingaben in den Skript-String
        // interpoliert.
        guard let scriptPath = Bundle.main.path(forResource: "install-helper", ofType: "sh") else {
            showInfoAlert(title: "Einrichtung nicht möglich",
                          text: "Das Installations-Skript wurde im App-Bundle nicht gefunden.")
            return
        }

        // AppleScript mit „with administrator privileges“ löst den System-Passwort-
        // dialog aus. Der Installationsort der App (und damit scriptPath) ist frei
        // wählbar und kann Shell-/AppleScript-Metazeichen enthalten ($, `, ", \, …).
        // `do shell script` führt den Text über /bin/sh aus, das in doppelten
        // Anführungszeichen weiterhin $, Backticks und \ expandiert — ein naiv
        // eingesetzter Pfad ermöglichte damit Root-Command-Injection. Deshalb zwei
        // Ebenen absichern: fürs AppleScript-Literal \ und " maskieren, und den Pfad
        // über `quoted form of` in einen single-quoted, shell-sicheren String wandeln.
        let literal = scriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"/bin/bash \" & quoted form of \"\(literal)\" with administrator privileges"

        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)

        if let errorInfo = errorInfo {
            // -128 = Nutzer hat den Passwort-Dialog abgebrochen → keine Fehlermeldung.
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            if code != -128 {
                showInfoAlert(title: "Einrichtung fehlgeschlagen",
                              text: "Die Systemregel konnte nicht installiert werden.")
            }
            return
        }

        // Ergebnis prüfen und den Nutzer informieren. Der Menü-Zustand wird beim
        // nächsten Öffnen ohnehin neu bewertet (Menü ist on demand).
        if LidGuard.helperInstalled() {
            showInfoAlert(title: "Zuklapp-Modus eingerichtet",
                          text: "Du kannst den Zuklapp-Modus jetzt über das Menü aktivieren.")
        } else {
            showInfoAlert(title: "Einrichtung unvollständig",
                          text: "Die Systemregel scheint nicht aktiv zu sein. Bitte erneut versuchen.")
        }
        updateIcon()
    }

    /// Checkbox „Zuklapp-Modus“: schaltet den Deckel-zu-wach-Modus um. Beim
    /// allerersten Aktivieren zeigt Espresso einmalig eine Warnung.
    @objc private func toggleLidMode(_ sender: NSMenuItem) {
        if lidGuard.isActive {
            lidGuard.deactivate()
            // stopBatteryWatcher() nur, wenn das Ausschalten wirklich griff. Schlug
            // pmset fehl (deactivate lässt isActive dann bewusst true), läuft der Modus
            // real weiter — dann muss das Sicherheitsnetz (Akku-Wächter) weiterlaufen,
            // damit es im nächsten Minutentakt erneut abzuschalten versucht.
            if !lidGuard.isActive {
                stopBatteryWatcher()
            }
            updateIcon()
            return
        }

        // Erste Aktivierung überhaupt: einmalige Warnung (Hitze, Akku, Auto-Aus).
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: lidWarningShownKey) {
            let alert = NSAlert()
            alert.messageText = "Zuklapp-Modus aktivieren?"
            alert.informativeText = """
                Der Mac bleibt bei geschlossenem Deckel wach.

                • Im Rucksack oder geschlossen kann er spürbar heiß werden.
                • Der Akku wird auch mit zugeklapptem Deckel verbraucht.

                Espresso schaltet den Modus automatisch aus, sobald der Akku 10 % \
                oder weniger erreicht und der Mac nicht am Netz hängt.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Aktivieren")
            alert.addButton(withTitle: "Abbrechen")
            NSApp.activate(ignoringOtherApps: true)   // Accessory-App: Dialog nach vorn holen
            guard alert.runModal() == .alertFirstButtonReturn else {
                return  // Abgebrochen — Flag nicht setzen, damit die Warnung erneut erscheint.
            }
            defaults.set(true, forKey: lidWarningShownKey)
        }

        lidGuard.activate()
        if lidGuard.isActive {
            startBatteryWatcher()
        }
        updateIcon()
    }

    /// Startet den Akku-Wächter: prüft im Minutentakt, ob bei niedrigem Akku und
    /// ohne Netzteil abgeschaltet werden muss. Ein evtl. laufender Timer wird zuvor
    /// beendet, damit nie zwei Timer parallel laufen.
    private func startBatteryWatcher() {
        stopBatteryWatcher()
        // Als Accessory-App ohne Fenster (setActivationPolicy(.accessory)) unterliegt
        // Espresso App Nap, das den 60-Sekunden-Wächter koalesziert/verzögert — und
        // ist der normale Wachhalte-Toggle aus, hält keine Power-Assertion die App
        // sonst wach. .userInitiated (nicht .background) unterdrückt App Nap für die
        // Laufzeit, damit das Sicherheitsnetz zuverlässig im Minutentakt feuert.
        lidActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                            reason: "Akku-Wächter Zuklapp-Modus")
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkBatteryAndMaybeDisable()
        }
        batteryTimer = timer
    }

    private func stopBatteryWatcher() {
        batteryTimer?.invalidate()
        batteryTimer = nil
        // Die App-Nap-Unterdrückung wieder freigeben, sobald der Wächter endet.
        if let activity = lidActivity {
            ProcessInfo.processInfo.endActivity(activity)
            lidActivity = nil
        }
    }

    /// Sicherheitsnetz: Ist der Zuklapp-Modus aktiv und fällt der Akku auf ≤ 10 %,
    /// ohne dass der Mac am Netz hängt, wird der Modus automatisch deaktiviert.
    private func checkBatteryAndMaybeDisable() {
        guard lidGuard.isActive else {
            stopBatteryWatcher()   // Timer sollte hier gar nicht mehr laufen — aufräumen.
            return
        }
        guard let status = currentBatteryStatus() else { return }
        if status.capacityPercent <= 10 && !status.onAC {
            lidGuard.deactivate()
            // Nur bei tatsächlichem Aus aufräumen und melden. Schlägt pmset fehl
            // (transienter sudo-Fehler, Regel zwischenzeitlich entfernt, System unter
            // Last), bleibt der Modus aktiv — dann den Timer bewusst weiterlaufen
            // lassen, damit die nächste Minute erneut versucht, statt das Sicherheitsnetz
            // genau im kritischen Moment abzuschalten und fälschlich Erfolg zu loggen.
            if !lidGuard.isActive {
                stopBatteryWatcher()
                updateIcon()
                os_log("Zuklapp-Modus wegen niedrigem Akku (%d %%, nicht am Netz) automatisch deaktiviert.",
                       type: .info, status.capacityPercent)
            }
        }
    }

    /// Liest über IOKit den Zustand der internen Batterie: Ladestand in Prozent und
    /// ob der Mac am Netz hängt. Gibt nil zurück, wenn keine interne Batterie
    /// gefunden wird (z. B. Desktop-Mac) — dann greift der Wächter nicht.
    private func currentBatteryStatus() -> (capacityPercent: Int, onAC: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            // Nur die interne Batterie betrachten, keine USV/externe Quellen.
            guard let type = desc[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType else { continue }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum)) * 100.0) : current

            // „AC Power“ = am Netz; alles andere gilt als Akkubetrieb.
            let state = desc[kIOPSPowerSourceStateKey] as? String
            let onAC = (state == kIOPSACPowerValue)

            return (percent, onAC)
        }
        return nil
    }

    /// Kleiner Helfer für einfache Hinweis-Dialoge.
    private func showInfoAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        // Accessory-App: Dialog zuverlässig nach vorn holen und fokussieren.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Autostart (Login Item)

    private func attemptInitialLoginItemRegistration() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: firstLaunchKey) else { return }
        defaults.set(true, forKey: firstLaunchKey)
        try? SMAppService.mainApp.register()
    }

    /// Login-Item gilt als aktiv, sobald es registriert ist — auch im Zustand
    /// `.requiresApproval` (registriert, aber vom Nutzer noch nicht in den
    /// Systemeinstellungen bestätigt). Sonst ließe sich ein `.requiresApproval`-Item
    /// über das Menü nie abschalten.
    private func isLoginItemActive() -> Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        let wasActive = isLoginItemActive()
        do {
            if wasActive {
                try service.unregister()   // entfernt die Registrierung auch aus .requiresApproval
            } else {
                try service.register()
            }
            // Haken aus der ausgeführten Aktion ableiten — service.status
            // aktualisiert sich nach register()/unregister() nicht garantiert sofort.
            sender.state = wasActive ? .off : .on
        } catch {
            // Aktion fehlgeschlagen — Haken auf den tatsächlichen (unveränderten) Zustand setzen.
            sender.state = isLoginItemActive() ? .on : .off
        }
    }

    // MARK: Beenden

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

// MARK: - Einstiegspunkt

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()      // starke Referenz halten
app.delegate = delegate
app.run()
