import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation
import FluidAudio
import Network

private enum EngineState: String {
    case idle
    case starting
    case recording
    case transcribing
    case diarizing
    case saving
    case complete
    case error

    var isBusy: Bool {
        switch self {
        case .starting, .recording, .transcribing, .diarizing, .saving:
            return true
        case .idle, .complete, .error:
            return false
        }
    }
}

private struct EngineStatus {
    let state: EngineState
    let message: String
    let pid: pid_t?
    let startedAt: Date?
    let notePath: String?
}

private final class ConfigStore {
    let url: URL

    init(projectDirectory: URL) {
        url = projectDirectory.appendingPathComponent("config.json")
    }

    func dictionary() -> [String: Any] {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else { return [:] }
        return dictionary
    }

    func value<T>(for key: String, fallback: T) -> T {
        dictionary()[key] as? T ?? fallback
    }

    @discardableResult
    func set(_ value: Any, for key: String) -> Bool {
        var config = dictionary()
        config[key] = value
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private lazy var projectDirectory: URL = {
        if let path = Bundle.main.object(forInfoDictionaryKey: "EchoPadProjectDirectory") as? String,
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent("Projects/echopad", isDirectory: true)
    }()
    private lazy var pythonURL: URL = {
        let virtualEnvironment = projectDirectory.appendingPathComponent(".venv/bin/python3")
        if fileManager.isExecutableFile(atPath: virtualEnvironment.path) {
            return virtualEnvironment
        }
        return URL(fileURLWithPath: "/opt/homebrew/bin/python3")
    }()
    private lazy var engineURL = projectDirectory.appendingPathComponent("echopad.py")
    private lazy var supportDirectory = home.appendingPathComponent("Library/Application Support/EchoPad", isDirectory: true)
    private lazy var statusURL = supportDirectory.appendingPathComponent("status.json")
    private lazy var pidURL = supportDirectory.appendingPathComponent("engine.pid")
    private lazy var logURL = home.appendingPathComponent("Library/Logs/echopad-recording.log")
    private var vaultURL: URL {
        let config = configStore.dictionary()
        let rawVault = config["vault_path"] as? String ?? "~/Documents/Obsidian"
        let vault = NSString(string: rawVault).expandingTildeInPath
        return URL(fileURLWithPath: vault, isDirectory: true)
    }
    private var meetingsURL: URL {
        let config = configStore.dictionary()
        let folder = config["meetings_dir"] as? String ?? "Meetings"
        return vaultURL.appendingPathComponent(folder, isDirectory: true)
    }
    private lazy var configStore = ConfigStore(projectDirectory: projectDirectory)

    private var statusItem: NSStatusItem!
    private var stateItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var vaultItem: NSMenuItem!
    private var lastNoteItem: NSMenuItem!
    private var diarizationItem: NSMenuItem!
    private var systemAudioItem: NSMenuItem!
    private var languageItem: NSMenuItem!
    private var modelTurboItem: NSMenuItem!
    private var modelSmallItem: NSMenuItem!
    private var modelParakeetItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private var engineProcess: Process?
    private var enginePID: pid_t?
    private var logHandle: FileHandle?
    private var pollingTimer: Timer?
    private var recordingStartedAt: Date?
    private var currentState: EngineState = .idle
    private var lastNotePath: String?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var parakeetServer: ParakeetServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let shouldChooseVault = configStore.dictionary()["vault_path"] == nil
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        createMenuBar()
        registerGlobalHotKey()
        let server = ParakeetServer()
        parakeetServer = server
        Task { try? await server.start() }
        recoverRunningEngine()
        installLoginItemIfNeeded()
        pollingTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(pollEngine), userInfo: nil, repeats: true)
        pollEngine()
        if shouldChooseVault {
            DispatchQueue.main.async { [weak self] in self?.chooseVault() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        logHandle?.closeFile()
    }

    private func createMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(symbol: "waveform", color: nil)

        let menu = NSMenu()
        stateItem = NSMenuItem(title: "Gotowy", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: "Rozpocznij nagrywanie", action: #selector(toggleRecording), keyEquivalent: "e")
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        toggleItem.target = self
        menu.addItem(toggleItem)

        let titledItem = NSMenuItem(title: "Nagraj z tytułem…", action: #selector(startWithTitle), keyEquivalent: "")
        titledItem.target = self
        menu.addItem(titledItem)

        menu.addItem(.separator())
        languageItem = NSMenuItem(title: "Język polski", action: #selector(toggleLanguage), keyEquivalent: "")
        languageItem.target = self
        menu.addItem(languageItem)

        let modelMenu = NSMenu()
        modelParakeetItem = NSMenuItem(title: "Parakeet v3 — bardzo szybki", action: #selector(selectParakeetModel), keyEquivalent: "")
        modelParakeetItem.target = self
        modelMenu.addItem(modelParakeetItem)
        modelTurboItem = NSMenuItem(title: "Large v3 Turbo — dokładny", action: #selector(selectTurboModel), keyEquivalent: "")
        modelTurboItem.target = self
        modelMenu.addItem(modelTurboItem)
        modelSmallItem = NSMenuItem(title: "Small — szybszy", action: #selector(selectSmallModel), keyEquivalent: "")
        modelSmallItem.target = self
        modelMenu.addItem(modelSmallItem)
        let modelItem = NSMenuItem(title: "Model transkrypcji", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        diarizationItem = NSMenuItem(title: "Rozpoznawaj mówców (wolniej)", action: #selector(toggleDiarization), keyEquivalent: "")
        diarizationItem.target = self
        menu.addItem(diarizationItem)

        systemAudioItem = NSMenuItem(title: "Nagrywaj dźwięk systemu", action: #selector(toggleSystemAudio), keyEquivalent: "")
        systemAudioItem.target = self
        menu.addItem(systemAudioItem)

        menu.addItem(.separator())
        vaultItem = NSMenuItem(title: "Vault Obsidian…", action: #selector(chooseVault), keyEquivalent: "")
        vaultItem.target = self
        menu.addItem(vaultItem)

        let openVaultItem = NSMenuItem(title: "Otwórz wybrany vault", action: #selector(openVault), keyEquivalent: "")
        openVaultItem.target = self
        menu.addItem(openVaultItem)

        lastNoteItem = NSMenuItem(title: "Otwórz ostatnią notatkę", action: #selector(openLastNote), keyEquivalent: "")
        lastNoteItem.target = self
        lastNoteItem.isEnabled = false
        menu.addItem(lastNoteItem)

        let meetingsItem = NSMenuItem(title: "Otwórz folder Meetings", action: #selector(openMeetings), keyEquivalent: "")
        meetingsItem.target = self
        menu.addItem(meetingsItem)

        let logItem = NSMenuItem(title: "Otwórz log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        loginItem = NSMenuItem(title: "Uruchamiaj po zalogowaniu", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Zakończ EchoPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshPreferences()
    }

    private func setIcon(symbol: String, color: NSColor?) {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "EchoPad")
        image?.isTemplate = color == nil
        button.image = image
        button.contentTintColor = color
    }

    private func refreshPreferences() {
        let language = configStore.dictionary()["language"] as? String
        languageItem.state = language == "pl" ? .on : .off
        languageItem.title = language == "pl" ? "Język polski" : "Automatyczne wykrywanie języka"

        diarizationItem.state = configStore.value(for: "diarization", fallback: true) ? .on : .off
        systemAudioItem.state = configStore.value(for: "capture_system_audio", fallback: true) ? .on : .off

        let backend = configStore.value(for: "transcription_backend", fallback: "parakeet")
        let model = configStore.value(for: "model", fallback: "mlx-community/whisper-large-v3-turbo")
        modelParakeetItem.state = backend == "parakeet" ? .on : .off
        modelTurboItem.state = backend == "whisper" && model == "mlx-community/whisper-large-v3-turbo" ? .on : .off
        modelSmallItem.state = backend == "whisper" && model == "mlx-community/whisper-small-mlx" ? .on : .off

        let vaultName = vaultURL.lastPathComponent.isEmpty ? vaultURL.path : vaultURL.lastPathComponent
        vaultItem.title = "Vault: \(vaultName)…"

        loginItem.state = fileManager.fileExists(atPath: loginAgentURL.path) ? .on : .off
        let canChange = !currentState.isBusy
        languageItem.isEnabled = canChange
        diarizationItem.isEnabled = canChange
        systemAudioItem.isEnabled = canChange
        modelTurboItem.isEnabled = canChange
        modelSmallItem.isEnabled = canChange
        modelParakeetItem.isEnabled = canChange
        vaultItem.isEnabled = canChange
    }

    @objc private func toggleRecording() {
        if let pid = liveEnginePID() {
            stopEngine(pid: pid)
        } else {
            startEngine(title: "Notatka głosowa")
        }
    }

    @objc private func startWithTitle() {
        guard liveEnginePID() == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Nowe nagranie EchoPad"
        alert.informativeText = "Podaj tytuł notatki w Obsidianie."
        alert.addButton(withTitle: "Rozpocznij")
        alert.addButton(withTitle: "Anuluj")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Np. Plan tygodnia"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        startEngine(title: title.isEmpty ? "Notatka głosowa" : title)
    }

    private func startEngine(title: String) {
        guard liveEnginePID() == nil else { return }
        guard fileManager.isExecutableFile(atPath: pythonURL.path), fileManager.fileExists(atPath: engineURL.path) else {
            showError("Nie znaleziono silnika", "Spodziewałem się \(engineURL.path) oraz \(pythonURL.path).")
            return
        }
        if configStore.value(for: "capture_system_audio", fallback: true), !ensureScreenCaptureAccess() {
            return
        }

        try? fileManager.removeItem(at: statusURL)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            logHandle = handle

            let process = Process()
            process.executableURL = pythonURL
            process.arguments = [engineURL.path, "--daemon", "--status-file", statusURL.path, title]
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            environment["PYTHONUNBUFFERED"] = "1"
            environment["ECHOPAD_AUDIO_CAPTURE_BIN"] = Bundle.main.executableURL?.path
            process.environment = environment
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { [weak self] finished in
                DispatchQueue.main.async { self?.engineDidExit(finished) }
            }

            try process.run()
            engineProcess = process
            enginePID = process.processIdentifier
            try String(process.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
            recordingStartedAt = Date()
            apply(state: .starting, message: "Uruchamianie mikrofonu…")
        } catch {
            logHandle?.closeFile()
            logHandle = nil
            showError("Nie udało się rozpocząć nagrywania", error.localizedDescription)
            apply(state: .error, message: "Błąd uruchamiania")
        }
    }

    private func ensureScreenCaptureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }

        showError(
            "Brak dostępu do dźwięku systemowego",
            "Włącz EchoPad w Ustawienia systemowe → Prywatność i ochrona → Nagrywanie ekranu i dźwięku systemowego, a następnie uruchom EchoPad ponownie. Nagrywanie nie zostało rozpoczęte."
        )
        return false
    }

    private func stopEngine(pid: pid_t) {
        if kill(pid, SIGTERM) == 0 {
            apply(state: .transcribing, message: "Kończenie nagrania…")
        } else {
            showError("Nie udało się zatrzymać nagrania", String(cString: strerror(errno)))
            recoverRunningEngine()
        }
    }

    private func engineDidExit(_ process: Process) {
        engineProcess = nil
        enginePID = nil
        try? fileManager.removeItem(at: pidURL)
        logHandle?.closeFile()
        logHandle = nil
        recordingStartedAt = nil
        let status = readStatus()
        if let notePath = status?.notePath {
            lastNotePath = notePath
            lastNoteItem.isEnabled = true
        }
        if process.terminationStatus == 0, status?.state == .complete {
            apply(state: .complete, message: status?.message ?? "Zapisano do Obsidiana")
        } else {
            let message = status?.message ?? "Silnik zakończył pracę (kod \(process.terminationStatus))"
            apply(state: .error, message: message)
        }
    }

    private func recoverRunningEngine() {
        guard let pid = pidFromDisk(), processIsAlive(pid) else {
            enginePID = nil
            try? fileManager.removeItem(at: pidURL)
            if currentState.isBusy { apply(state: .idle, message: "Gotowy") }
            return
        }
        enginePID = pid
        if let status = readStatus() {
            recordingStartedAt = status.startedAt
            apply(status: status)
        } else {
            apply(state: .starting, message: "EchoPad działa…")
        }
    }

    @objc private func pollEngine() {
        if let pid = enginePID, !processIsAlive(pid) {
            recoverRunningEngine()
        } else if enginePID == nil {
            recoverRunningEngine()
        }

        if let status = readStatus(), status.pid == nil || status.pid == enginePID {
            if let notePath = status.notePath {
                lastNotePath = notePath
                lastNoteItem.isEnabled = true
            }
            apply(status: status)
        }

        if currentState == .recording, let start = recordingStartedAt {
            let elapsed = Int(Date().timeIntervalSince(start))
            stateItem.title = "Nagrywanie • \(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))"
        }
    }

    private func apply(status: EngineStatus) {
        if status.startedAt != nil { recordingStartedAt = status.startedAt }
        apply(state: status.state, message: status.message)
    }

    private func apply(state: EngineState, message: String) {
        currentState = state
        switch state {
        case .recording:
            stateItem.title = message.isEmpty ? "Nagrywanie" : message
            toggleItem.title = "Zatrzymaj i zapisz"
            setIcon(symbol: "waveform.circle.fill", color: .systemRed)
        case .starting, .transcribing, .diarizing, .saving:
            stateItem.title = message.isEmpty ? "Przetwarzanie…" : message
            toggleItem.title = state == .starting ? "Zatrzymaj" : "Przetwarzanie…"
            setIcon(symbol: "waveform.badge.magnifyingglass", color: .systemOrange)
        case .complete:
            stateItem.title = message.isEmpty ? "Zapisano do Obsidiana" : message
            toggleItem.title = "Rozpocznij nagrywanie"
            setIcon(symbol: "checkmark.circle", color: .systemGreen)
        case .error:
            stateItem.title = message.isEmpty ? "Wystąpił błąd" : message
            toggleItem.title = "Rozpocznij nagrywanie"
            setIcon(symbol: "exclamationmark.triangle", color: .systemRed)
        case .idle:
            stateItem.title = "Gotowy • ⇧⌘E"
            toggleItem.title = "Rozpocznij nagrywanie"
            setIcon(symbol: "waveform", color: nil)
        }
        toggleItem.isEnabled = state == .recording || state == .starting || !state.isBusy
        refreshPreferences()
    }

    private func readStatus() -> EngineStatus? {
        guard
            let data = try? Data(contentsOf: statusURL),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let rawState = dictionary["state"] as? String,
            let state = EngineState(rawValue: rawState)
        else { return nil }

        let pid = (dictionary["pid"] as? NSNumber).map { pid_t($0.int32Value) }
        let formatter = ISO8601DateFormatter()
        let startedAt = (dictionary["started_at"] as? String).flatMap(formatter.date)
        return EngineStatus(
            state: state,
            message: dictionary["message"] as? String ?? "",
            pid: pid,
            startedAt: startedAt,
            notePath: dictionary["note_path"] as? String
        )
    }

    private func pidFromDisk() -> pid_t? {
        guard
            let contents = try? String(contentsOf: pidURL, encoding: .utf8),
            let value = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid_t(value)
    }

    private func liveEnginePID() -> pid_t? {
        if let pid = enginePID, processIsAlive(pid) { return pid }
        if let pid = pidFromDisk(), processIsAlive(pid) {
            enginePID = pid
            return pid
        }
        return nil
    }

    private func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    @objc private func toggleLanguage() {
        let isPolish = (configStore.dictionary()["language"] as? String) == "pl"
        _ = configStore.set(isPolish ? NSNull() : "pl", for: "language")
        refreshPreferences()
    }

    @objc private func toggleDiarization() {
        let current = configStore.value(for: "diarization", fallback: true)
        _ = configStore.set(!current, for: "diarization")
        refreshPreferences()
    }

    @objc private func toggleSystemAudio() {
        let current = configStore.value(for: "capture_system_audio", fallback: true)
        _ = configStore.set(!current, for: "capture_system_audio")
        refreshPreferences()
    }

    @objc private func selectTurboModel() {
        _ = configStore.set("whisper", for: "transcription_backend")
        _ = configStore.set("mlx-community/whisper-large-v3-turbo", for: "model")
        refreshPreferences()
    }

    @objc private func selectSmallModel() {
        _ = configStore.set("whisper", for: "transcription_backend")
        _ = configStore.set("mlx-community/whisper-small-mlx", for: "model")
        refreshPreferences()
    }

    @objc private func selectParakeetModel() {
        _ = configStore.set("parakeet", for: "transcription_backend")
        refreshPreferences()
    }

    @objc private func chooseVault() {
        guard !currentState.isBusy else { return }

        let panel = NSOpenPanel()
        panel.title = "Wybierz vault Obsidian"
        panel.message = "EchoPad będzie zapisywać notatki w folderze Meetings wewnątrz wybranego vaultu."
        panel.prompt = "Wybierz vault"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if fileManager.fileExists(atPath: vaultURL.path) {
            panel.directoryURL = vaultURL
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        guard configStore.set(selectedURL.path, for: "vault_path") else {
            showError("Nie udało się zapisać vaultu", "Sprawdź uprawnienia do pliku config.json.")
            return
        }

        do {
            try fileManager.createDirectory(at: meetingsURL, withIntermediateDirectories: true)
        } catch {
            showError("Nie udało się przygotować vaultu", error.localizedDescription)
            return
        }

        lastNotePath = nil
        lastNoteItem.isEnabled = false
        refreshPreferences()
    }

    @objc private func openVault() {
        NSWorkspace.shared.open(vaultURL)
    }

    @objc private func openLastNote() {
        guard let lastNotePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: lastNotePath))
    }

    @objc private func openMeetings() {
        try? fileManager.createDirectory(at: meetingsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(meetingsURL)
    }

    @objc private func openLog() {
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        NSWorkspace.shared.open(logURL)
    }

    private var loginAgentURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/com.echopad.app.plist")
    }

    private func installLoginItemIfNeeded() {
        guard Bundle.main.bundlePath.hasSuffix("/Applications/EchoPad.app") else { return }
        if !fileManager.fileExists(atPath: loginAgentURL.path) {
            _ = writeLoginAgent()
        }
        refreshPreferences()
    }

    @objc private func toggleLoginItem() {
        if fileManager.fileExists(atPath: loginAgentURL.path) {
            try? fileManager.removeItem(at: loginAgentURL)
        } else {
            _ = writeLoginAgent()
        }
        refreshPreferences()
    }

    private func writeLoginAgent() -> Bool {
        let executable = Bundle.main.executableURL?.path ?? ""
        guard !executable.isEmpty else { return false }
        let plist: [String: Any] = [
            "Label": "com.echopad.app",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "StandardOutPath": home.appendingPathComponent("Library/Logs/echopad-app.log").path,
            "StandardErrorPath": home.appendingPathComponent("Library/Logs/echopad-app.log").path,
        ]
        do {
            try fileManager.createDirectory(at: loginAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: loginAgentURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let readResult = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard readResult == noErr, hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.toggleRecording() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )

        guard result == noErr else {
            apply(state: .error, message: "Nie udało się zarejestrować ⇧⌘E")
            return
        }

        let signature = fourCharacterCode("ECHP")
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let modifiers = UInt32(cmdKey | shiftKey)
        let registration = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registration != noErr {
            apply(state: .error, message: "Skrót ⇧⌘E jest zajęty")
        }
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private func fourCharacterCode(_ string: String) -> FourCharCode {
    string.utf8.prefix(4).reduce(0) { ($0 << 8) + FourCharCode($1) }
}

private func runHealthCheck() -> Never {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let configuredPath = Bundle.main.object(forInfoDictionaryKey: "EchoPadProjectDirectory") as? String
    let project = configuredPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? home.appendingPathComponent("Projects/echopad")
    let virtualEnvironment = project.appendingPathComponent(".venv/bin/python3")
    let pythonPath = FileManager.default.isExecutableFile(atPath: virtualEnvironment.path)
        ? virtualEnvironment.path
        : "/opt/homebrew/bin/python3"
    let checks: [String: Bool] = [
        "python": FileManager.default.isExecutableFile(atPath: pythonPath),
        "engine": FileManager.default.fileExists(atPath: project.appendingPathComponent("echopad.py").path),
        "audioCapture": Bundle.main.executableURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false,
        "config": FileManager.default.fileExists(atPath: project.appendingPathComponent("config.json").path),
    ]
    let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
    exit(checks.values.allSatisfy { $0 } ? 0 : 1)
}

private struct ParakeetWord: Codable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
}

private struct ParakeetOutput: Codable {
    let text: String
    let duration: TimeInterval
    let processingTime: TimeInterval
    let confidence: Float
    let words: [ParakeetWord]
}

private func loadParakeetManager() async throws -> AsrManager {
    let version = AsrModelVersion.v3
    let models = try await AsrModels.downloadAndLoad(version: version, encoderPrecision: .int8)
    let config = ASRConfig(
        tdtConfig: TdtConfig(blankId: version.blankId),
        encoderHiddenSize: version.encoderHiddenSize,
        melChunkContext: false
    )
    let manager = AsrManager(config: config)
    try await manager.loadModels(models)
    return manager
}

private func transcribeWithParakeet(manager: AsrManager, audioPath: String) async throws -> Data {
    let layers = await manager.decoderLayerCount
    var decoderState = TdtDecoderState.make(decoderLayers: layers)
    let result = try await manager.transcribe(
        URL(fileURLWithPath: audioPath),
        decoderState: &decoderState,
        language: .polish
    )
    let words = buildWordTimings(from: result.tokenTimings ?? []).map {
        ParakeetWord(word: $0.word, start: $0.startTime, end: $0.endTime)
    }
    let output = ParakeetOutput(
        text: result.text,
        duration: result.duration,
        processingTime: result.processingTime,
        confidence: result.confidence,
        words: words
    )
    return try JSONEncoder().encode(output)
}

private final class ParakeetServer: @unchecked Sendable {
    static let port = NWEndpoint.Port(rawValue: 52_473)!
    private let queue = DispatchQueue(label: "com.echopad.parakeet-server", qos: .userInitiated)
    private var listener: NWListener?

    func start() async throws {
        let manager = try await loadParakeetManager()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Self.port)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, manager: manager)
        }
        listener.start(queue: queue)
    }

    private func handle(_ connection: NWConnection, manager: AsrManager) {
        connection.start(queue: queue)
        receiveRequest(on: connection, manager: manager, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, manager: AsrManager, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var requestData = accumulated
            if let data { requestData.append(data) }
            guard isComplete else {
                self.receiveRequest(on: connection, manager: manager, accumulated: requestData)
                return
            }
            Task {
                do {
                    guard
                        let request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                        let path = request["path"] as? String,
                        !path.isEmpty
                    else { throw NSError(domain: "EchoPad", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid request"]) }
                    let response = try await transcribeWithParakeet(manager: manager, audioPath: path)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                } catch {
                    let response = (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])) ?? Data()
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }
}

private func runParakeetCommand(audioPath: String?) -> Never {
    Task {
        do {
            let manager = try await loadParakeetManager()
            guard let audioPath else {
                print("Parakeet v3 ready")
                exit(0)
            }
            let data = try await transcribeWithParakeet(manager: manager, audioPath: audioPath)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Parakeet error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

@main
@MainActor
private enum EchoPadMain {
    static func main() {
        if CommandLine.arguments.contains("--health-check") {
            runHealthCheck()
        }

        if CommandLine.arguments.contains("--download-parakeet") {
            runParakeetCommand(audioPath: nil)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--parakeet-transcribe"), index + 1 < CommandLine.arguments.count {
            runParakeetCommand(audioPath: CommandLine.arguments[index + 1])
        }

        if CommandLine.arguments.contains("--audio-capture") {
            runSystemAudioCaptureCommand(arguments: CommandLine.arguments)
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
