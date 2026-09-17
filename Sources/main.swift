import AppKit
import AVFoundation
import ServiceManagement
import ApplicationServices
import IOKit.hidsystem

// MARK: - Sound scheme (Cherry G80-3494)

enum Scheme {
    /// Randomly picked for any key without a dedicated sample.
    static let generic = ["G80-3494", "G80-3494_fast1", "G80-3494_slow1"]

    /// Virtual keycode -> dedicated sample. Matches Tickeys' schemes.json.
    static let byKeyCode: [UInt16: String] = [
        36: "G80-3494_enter",      // Return
        49: "G80-3494_space",      // Space
        51: "G80-3494_backspace",  // Delete
    ]

    static var allSamples: [String] { generic + byKeyCode.values }
}

// MARK: - Low-latency player

/// Round-robin pool of player nodes fed from preloaded PCM buffers.
/// Buffers are decoded once at launch so a keystroke costs only a schedule call.
final class ClickPlayer {
    private let engine = AVAudioEngine()
    private var nodes: [AVAudioPlayerNode] = []
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var cursor = 0
    private let format: AVAudioFormat
    private var observer: NSObjectProtocol?

    /// Mirrors mainMixerNode.outputVolume, which does not survive the engine
    /// being rebuilt after a configuration change.
    private var storedVolume: Float = 1

    /// Throttles the fallback restart in play() so a device that refuses to
    /// start cannot stutter typing with an engine start on every keystroke.
    private var lastRestart = Date.distantPast

    private static let poolSize = 16

    init?(samples: [String]) {
        var loaded: AVAudioFormat?

        for name in samples {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
                  let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil
            else {
                NSLog("Keyclick: failed to load sample \(name)")
                return nil
            }
            buffers[name] = buffer
            loaded = file.processingFormat
        }

        guard let loaded else { return nil }
        format = loaded

        for _ in 0..<Self.poolSize {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes.append(node)
        }

        // AVAudioEngine stops itself when the audio route changes — headphones
        // plugged in, a Bluetooth device dropping, a virtual driver taking over
        // the default output. It only posts this notification; nothing restarts
        // it for us, and scheduleBuffer() on a stopped engine then fails
        // silently, which reads exactly like a permission problem.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            NSLog("Keyclick: audio configuration changed — restarting engine")
            self?.restart()
        }

        guard start() else { return nil }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var volume: Float {
        get { storedVolume }
        set {
            storedVolume = max(0, min(1, newValue))
            engine.mainMixerNode.outputVolume = storedVolume
        }
    }

    /// True while the engine is actually rendering — the honest signal, the
    /// audio-side counterpart to the event tap existing.
    var isRunning: Bool { engine.isRunning }

    @discardableResult
    private func start() -> Bool {
        lastRestart = Date()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("Keyclick: audio engine failed to start: \(error)")
            return false
        }
        engine.mainMixerNode.outputVolume = storedVolume
        nodes.forEach { $0.play() }
        return true
    }

    /// The node connections are torn down with the old I/O unit, so they are
    /// rebuilt before the engine goes again.
    @discardableResult
    private func restart() -> Bool {
        engine.stop()
        for node in nodes {
            node.stop()
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        return start()
    }

    func play(_ name: String) {
        guard let buffer = buffers[name] else { return }

        // Belt and braces for a missed notification: a stopped engine would
        // swallow the buffer without a sound and without an error.
        if !engine.isRunning {
            guard Date().timeIntervalSince(lastRestart) > 1, restart() else { return }
        }

        let node = nodes[cursor]
        cursor = (cursor + 1) % nodes.count
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var player: ClickPlayer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trustTimer: Timer?
    private var lastGeneric: String?

    private let defaults = UserDefaults.standard

    /// True only when the tap actually exists — the honest signal, unlike
    /// AXIsProcessTrusted(), which can read true while the tap still fails.
    private var isListening: Bool { eventTap != nil }

    private var isEnabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    private var volume: Float {
        get { defaults.object(forKey: "volume") as? Float ?? 0.7 }
        set { defaults.set(newValue, forKey: "volume") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        player = ClickPlayer(samples: Scheme.allSamples)
        player?.volume = volume

        buildStatusItem()
        registerLoginItemOnFirstLaunch()

        if !installTap() {
            requestPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeTap()
    }

    /// Opt in to launch-at-login once, on first run only, so a later
    /// unregister from the menu is not undone on the next launch.
    private func registerLoginItemOnFirstLaunch() {
        guard !defaults.bool(forKey: "didSetupLoginItem") else { return }
        defaults.set(true, forKey: "didSetupLoginItem")
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Keyclick: login item registration failed: \(error)")
        }
    }

    // MARK: Input Monitoring permission

    /// A listen-only keyboard tap needs Input Monitoring (kTCCServiceListenEvent),
    /// NOT Accessibility. Accessibility covers posting and modifying events; it
    /// does not authorise passively reading keystrokes on macOS 10.15+.
    private var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private func requestPermission() {
        if !hasInputMonitoring {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        refreshStatusIcon()

        // The prompt only opens Settings; it never reports back. Retry creating
        // the tap itself — that is the only test matching what we actually need.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self, self.installTap() else { return }
            timer.invalidate()
            self.trustTimer = nil
            self.refreshStatusIcon()
        }
    }

    // MARK: Key events

    @discardableResult
    private func installTap() -> Bool {
        guard eventTap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<AppDelegate>.fromOpaque(refcon)
                    .takeUnretainedValue()
                    .handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Keyclick: tapCreate failed — Input Monitoring not granted to this binary")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        NSLog("Keyclick: event tap installed")
        return true
    }

    private func removeTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard type == .keyDown, isEnabled else { return }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if let dedicated = Scheme.byKeyCode[keyCode] {
            player?.play(dedicated)
            return
        }

        // Avoid playing the same generic sample twice running — the repeat is
        // the most audible giveaway that this is a three-sample loop.
        var pick = Scheme.generic.randomElement()!
        if Scheme.generic.count > 1, pick == lastGeneric {
            pick = Scheme.generic.filter { $0 != lastGeneric }.randomElement()!
        }
        lastGeneric = pick
        player?.play(pick)
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshStatusIcon()

        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = 4
        menu.addItem(status)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "소리 켜기", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.tag = 1
        menu.addItem(toggle)

        menu.addItem(.separator())

        let label = NSMenuItem(title: "볼륨", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
        menu.addItem(volumeItem())

        menu.addItem(.separator())

        let test = NSMenuItem(title: "소리 테스트", action: #selector(testSound), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.tag = 2
        menu.addItem(login)

        let access = NSMenuItem(title: "입력 모니터링 설정 열기", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        access.target = self
        access.tag = 3
        menu.addItem(access)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func volumeItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        let slider = NSSlider(frame: NSRect(x: 20, y: 4, width: 160, height: 20))
        slider.minValue = 0
        slider.maxValue = 1
        slider.floatValue = volume
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(volumeChanged(_:))
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyclick")
        button.appearsDisabled = !isEnabled || !isListening
        button.toolTip = isListening
            ? (isEnabled ? "Keyclick — 켜짐" : "Keyclick — 꺼짐")
            : "Keyclick — 입력 모니터링 권한 필요"
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        refreshStatusIcon()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        volume = sender.floatValue
        player?.volume = sender.floatValue
    }

    @objc private func testSound() {
        player?.play(Scheme.generic[0])
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Keyclick: login item toggle failed: \(error)")
        }
    }

    @objc private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 1)?.state = isEnabled ? .on : .off
        menu.item(withTag: 1)?.isEnabled = isListening
        menu.item(withTag: 2)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.item(withTag: 3)?.isHidden = isListening
        // The tap being alive is only half the story: the engine can be stopped
        // while keys still arrive, which is silent in exactly the same way.
        if !isListening {
            menu.item(withTag: 4)?.title = "입력 모니터링 권한 없음 — 소리 안 남"
        } else if player?.isRunning == false {
            menu.item(withTag: 4)?.title = "오디오 엔진 정지 — 소리 안 남"
        } else {
            menu.item(withTag: 4)?.title = "키 입력 수신 중"
        }
        refreshStatusIcon()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
