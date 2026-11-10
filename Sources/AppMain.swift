import AppKit
import ApplicationServices
import CoreHaptics
import GameController

final class HIDIdentity {}

enum VSCodeTarget {
    static let bundles: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.vscodium",
        "com.microsoft.VSCodeExploration"
    ]

    static func matches(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return false }
        if let identifier = application.bundleIdentifier {
            if bundles.contains(identifier) || identifier.localizedCaseInsensitiveContains("vscode") || identifier.localizedCaseInsensitiveContains("vscodium") {
                return true
            }
        }
        switch application.localizedName {
        case "Code", "Visual Studio Code", "Code - Insiders", "VSCodium":
            return true
        default:
            return false
        }
    }
}

struct KeyBinding {
    let label: String
    let key: CGKeyCode
    let flags: CGEventFlags
}

final class LightPlayer {
    let hid = DualSenseLight()
    private(set) var hidActive = false
    private var pattern: LightPattern = CodexLights.pattern(phase: .idle, dictating: false)
    private var patternStart = Date()
    private var timer: DispatchSourceTimer?

    func start() {
        hid.start()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(8))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func set(_ pattern: LightPattern) {
        guard pattern != self.pattern else { return }
        self.pattern = pattern
        patternStart = Date()
        tick()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        hid.stop()
    }

    private func tick() {
        let color = pattern.color(at: Date().timeIntervalSince(patternStart))
        hidActive = hid.set(color)
        guard !hidActive else { return }
        let fallback = GCColor(red: color.red, green: color.green, blue: color.blue)
        for controller in GCController.controllers() where controller.extendedGamepad is GCDualSenseGamepad {
            controller.light?.color = fallback
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let diagnostic = CommandLine.arguments.contains("--diagnose")
    var enabled = true
    var remindersEnabled = UserDefaults.standard.object(forKey: "remindersEnabled") as? Bool ?? true
    var lightState = CodexLightState()
    var menuNavigation = false

    let lights = LightPlayer()
    let server = StatusServer()
    let sessions = SessionWatch()
    let speech = SpeechDictation()
    let locator = ConversationLocator()
    var activity: NSObjectProtocol?

    var statusItem: NSStatusItem!
    var deviceItem: NSMenuItem!
    var permissionItem: NSMenuItem!
    var phaseItem: NSMenuItem!
    var listenItem: NSMenuItem!
    var lastItem: NSMenuItem!
    var tunnelItem: NSMenuItem!
    var toggleItem: NSMenuItem!
    var reminderItem: NSMenuItem!
    var languageItem: NSMenuItem!

    var attached = Set<ObjectIdentifier>()
    var triggers: [ObjectIdentifier: TriggerGesture] = [:]
    var sticks: [ObjectIdentifier: (Float, Float)] = [:]
    var dictationHold = HoldState<ObjectIdentifier, NSRunningApplication>()
    var nextStickKeyTime = Date.distantPast
    var stickTimer: DispatchSourceTimer?
    var housekeepingTimer: DispatchSourceTimer?
    var pollTimer: DispatchSourceTimer?
    var lastPad: [ObjectIdentifier: DualSenseInput] = [:]
    var lastPulseTime = Date.distantPast
    var activeEngines: [CHHapticEngine] = []
    var activePlayers: [CHHapticPatternPlayer] = []
    var listenerStatus = "正在监听"
    let hidIdentity = HIDIdentity()
    var hidInputLive = false
    var lastHIDButtons: Set<DualSenseInput.Button> = []
    var lastR2Bucket = 0
    var banner: String?
    var askedAccessibility = false
    let launchedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep the DualSense light bar updating for Codex")
        if !diagnostic { makeMenu() }
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(self, selector: #selector(refreshDevices), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshDevices), name: .GCControllerDidDisconnect, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontmostChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        lights.hid.onInput = { [weak self] input in
            self?.handleHID(input)
        }
        lights.hid.onConnection = { [weak self] connected in
            guard let self, !connected else { return }
            self.hidInputLive = false
            self.lastHIDButtons = []
            self.lastR2Bucket = 0
            self.sticks[ObjectIdentifier(self.hidIdentity)] = (0, 0)
            self.endDictation(owner: ObjectIdentifier(self.hidIdentity))
        }
        lights.start()
        DualSenseLight.requestInputMonitoring()
        AppLog.write("launch monitor=\(DualSenseLight.inputMonitoringGranted)")
        server.onStatus = { [weak self] text in
            self?.listenerStatus = text
            self?.updateMenu()
        }
        server.onEvent = { [weak self] body in
            self?.receiveHook(body)
        }
        sessions.onEvent = { [weak self] cue, live in
            self?.applySignal(cue.signal, haptic: live)
        }
        sessions.poll()
        server.start()
        speech.preparePermissions()
        applyLight()
        if !diagnostic && !AXIsProcessTrusted() { requestAccessibilityPrompt() }
        startTimers()
        refreshDevices()
        if diagnostic {
            fputs("Diagnostic mode: no keyboard events. Listening for 15 seconds.\n", stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { NSApp.terminate(nil) }
        }
    }

    func startTimers() {
        let stick = DispatchSource.makeTimerSource(queue: .main)
        stick.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(10))
        stick.setEventHandler { [weak self] in self?.moveStick() }
        stick.resume()
        stickTimer = stick
        let housekeeping = DispatchSource.makeTimerSource(queue: .main)
        housekeeping.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        housekeeping.setEventHandler { [weak self] in
            guard let self else { return }
            if self.lightState.expire(now: Date()) { self.applyLight() }
            self.sessions.poll()
            self.refreshDevices()
            let square = GCController.controllers().contains { $0.extendedGamepad?.buttonX.isPressed == true }
            let front = NSWorkspace.shared.frontmostApplication
            AppLog.write("beat hid=\(self.hidInputLive) monitor=\(DualSenseLight.inputMonitoringGranted) gcSquare=\(square) front=\(front?.bundleIdentifier ?? front?.localizedName ?? "-")")
        }
        housekeeping.resume()
        housekeepingTimer = housekeeping
        let poll = DispatchSource.makeTimerSource(queue: .main)
        poll.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(4))
        poll.setEventHandler { [weak self] in self?.pollGamepads() }
        poll.resume()
        pollTimer = poll
    }

    func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎮"
        let menu = NSMenu()
        menu.delegate = self
        deviceItem = menu.addItem(withTitle: "等待手柄…", action: nil, keyEquivalent: "")
        permissionItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        phaseItem = menu.addItem(withTitle: "Codex：空闲", action: nil, keyEquivalent: "")
        listenItem = menu.addItem(withTitle: "听写：中文", action: nil, keyEquivalent: "")
        tunnelItem = menu.addItem(withTitle: "正在监听", action: nil, keyEquivalent: "")
        lastItem = menu.addItem(withTitle: "最近动作：无", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        statusItem.menu = menu
        toggleItem = item("启用按键映射", #selector(toggleEnabled))
        toggleItem.state = .on
        languageItem = item("听写语言：中文（△ 切换 English）", #selector(toggleLanguage))
        reminderItem = item("状态变化时震动", #selector(toggleReminders))
        reminderItem.state = remindersEnabled ? .on : .off
        menu.addItem(.separator())
        _ = item("测试灯效：编写中", #selector(previewWorking))
        _ = item("测试灯效：等待确认", #selector(previewNeedsInput))
        _ = item("测试灯效：本轮结束", #selector(previewCompleted))
        _ = item("测试灯效：出错", #selector(previewError))
        _ = item("测试：两次短震动", #selector(testRumble))
        menu.addItem(.separator())
        _ = item("复制 SSH 反向转发", #selector(copyTunnel))
        _ = item("重置辅助功能授权…", #selector(resetPermissions))
        _ = item("打开辅助功能设置…", #selector(openAccessibility))
        menu.addItem(.separator())
        for title in [
            "仅在 VS Code 位于前台时发送按键",
            "□  按住听写，松开后把文字粘贴进 Codex 输入框",
            "△  切换听写语言：中文 / English",
            "×  回车：发送或确认",
            "○  Esc",
            "Options  命令面板（⌘⇧P）",
            "L1 / R1  上一个 / 下一个编辑器",
            "R2  轻按松开为回车，深按为 ⌘⇧回车",
            "方向键  ↑ ↓ ← →",
            "左摇杆  滚动；命令面板里选择",
            "灯：蓝呼吸编写中，黄常亮等待确认",
            "灯：绿呼吸本轮结束，持续 1 小时；红闪为出错",
            "听写时灯条改为青色呼吸"
        ] {
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        _ = item("退出 DS Codex SSH", #selector(quitApp))
        statusItem.menu = menu
        updateMenu()
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = statusItem.menu!.addItem(withTitle: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }

    func updateMenu() {
        guard !diagnostic, statusItem != nil else { return }
        let controllers = GCController.controllers().filter { $0.extendedGamepad is GCDualSenseGamepad }
        deviceItem.title = (controllers.isEmpty ? "未连接 DualSense" : "已连接：\(controllers.first?.vendorName ?? "DualSense")")
            + (hidInputLive ? " · 按键 HID" : (DualSenseLight.inputMonitoringGranted ? " · 等待按键" : " · 未授权输入监控"))
        let trusted = AXIsProcessTrusted()
        permissionItem.title = trusted
            ? "辅助功能：已授权"
            : (askedAccessibility
                ? "辅助功能：已经允许的话，请退出本程序再打开一次"
                : "辅助功能：未授权")
        let route = lights.hidActive || lights.hid.isConnected ? "HID" : (controllers.contains { $0.light != nil } ? "系统灯光" : "未接通")
        phaseItem.title = "Codex：\(lightState.phase.title) · 灯条 \(route)"
        if speech.listening {
            let preview = speech.currentPartial()
            let clipped = preview.count > 24 ? String(preview.prefix(24)) + "…" : preview
            listenItem.title = clipped.isEmpty ? "正在听（\(speech.language.title)）…" : "正在听：\(clipped)"
        } else if let blocked = speech.authorizationMessage() {
            listenItem.title = "听写：\(blocked)"
        } else {
            listenItem.title = "听写：\(speech.language.title)，松开后粘贴进 Codex 输入框"
        }
        tunnelItem.title = listenerStatus
        languageItem?.title = "听写语言：\(speech.language.title)（△ 切换）"
        statusItem.button?.title = banner.map { "🎮 \($0)" } ?? (enabled ? "🎮" : "🎮 ⏸")
        statusItem.button?.toolTip = "DS Codex SSH · \(lightState.phase.title)"
    }

    @objc func refreshDevices() {
        let controllers = GCController.controllers().filter { $0.extendedGamepad is GCDualSenseGamepad }
        let ids = Set(controllers.map { ObjectIdentifier($0) })
        for controller in controllers where !attached.contains(ObjectIdentifier(controller)) {
            bind(controller)
        }
        if let hold = dictationHold.active, hold.owner != ObjectIdentifier(hidIdentity), !ids.contains(hold.owner) {
            endDictation()
        }
        let hid = ObjectIdentifier(hidIdentity)
        triggers = triggers.filter { ids.contains($0.key) || $0.key == hid }
        sticks = sticks.filter { ids.contains($0.key) || $0.key == hid }
        attached = ids
        if !hidInputLive, !controllers.isEmpty, Date().timeIntervalSince(launchedAt) > 2, banner == nil {
            banner = DualSenseLight.inputMonitoringGranted ? "未收到按键" : "需要输入监控"
        }
        if hidInputLive, banner == "需要输入监控" || banner == "未收到按键" {
            banner = nil
        }
        updateMenu()
    }

    func bind(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        controller.handlerQueue = .main
        let owner = ObjectIdentifier(controller)
        var trigger = TriggerGesture()
        _ = trigger.update(pad.rightTrigger.value, allowed: true)
        triggers[owner] = trigger
        sticks[owner] = (0, 0)
        pad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            guard let self, !self.hidInputLive else { return }
            self.handleTrigger(owner: owner, value: value)
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            guard let self, !self.hidInputLive else { return }
            self.sticks[owner] = (x, y)
        }
        pad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            guard let self, !self.hidInputLive else { return }
            if self.diagnostic { self.note(pressed ? "□ 按下" : "□ 松开"); return }
            if pressed { self.beginDictation(owner: owner) } else { self.endDictation(owner: owner) }
        }
        pad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed, let self, !self.hidInputLive else { return }
            if self.diagnostic { self.note("△ 切换语言"); return }
            self.toggleLanguage()
        }
        connect(pad.buttonA, KeyBinding(label: "× 回车", key: 36, flags: []))
        connect(pad.buttonB, KeyBinding(label: "○ Esc", key: 53, flags: []))
        connect(pad.leftShoulder, KeyBinding(label: "L1 上一个编辑器", key: 33, flags: [.maskCommand, .maskShift]))
        connect(pad.rightShoulder, KeyBinding(label: "R1 下一个编辑器", key: 30, flags: [.maskCommand, .maskShift]))
        connect(pad.dpad.up, KeyBinding(label: "↑", key: 126, flags: []))
        connect(pad.dpad.down, KeyBinding(label: "↓", key: 125, flags: []))
        connect(pad.dpad.left, KeyBinding(label: "←", key: 123, flags: []))
        connect(pad.dpad.right, KeyBinding(label: "→", key: 124, flags: []))
        connect(pad.buttonMenu, KeyBinding(label: "Options 命令面板", key: 35, flags: [.maskCommand, .maskShift]))
    }

    func connect(_ button: GCControllerButtonInput, _ binding: KeyBinding) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed, let self, !self.hidInputLive else { return }
            self.perform(binding)
        }
    }

    func perform(_ binding: KeyBinding) {
        if diagnostic { note(binding.label); return }
        note(binding.label)
        guard enabled else { note("\(binding.label)（已暂停）"); return }
        guard let target = NSWorkspace.shared.frontmostApplication, VSCodeTarget.matches(target) else {
            note("\(binding.label)（VS Code 不在前台）")
            return
        }
        guard AXIsProcessTrusted() else { note("\(binding.label)（需要辅助功能授权）"); return }
        if binding.key == 35 && binding.flags.contains(.maskCommand) {
            menuNavigation = true
            cancelTriggers()
        } else if binding.key == 36 || binding.key == 53 {
            menuNavigation = false
        }
        guard postKey(binding, to: target.processIdentifier) else {
            note("\(binding.label)（创建键盘事件失败）")
            return
        }
    }

    func handleTrigger(owner: ObjectIdentifier, value: Float) {
        let target = NSWorkspace.shared.frontmostApplication
        let isTarget = VSCodeTarget.matches(target)
        let snapshot = isTarget && AXIsProcessTrusted() ? target.flatMap(focusSnapshot) : nil
        let allowed = diagnostic || SendPolicy.allows(
            enabled: enabled,
            trusted: AXIsProcessTrusted(),
            dictating: dictationHold.active != nil,
            roles: snapshot?.roles ?? [],
            focused: snapshot?.focused,
            window: snapshot?.window)
        guard let action = triggers[owner]?.update(value, allowed: allowed && isTarget) else {
            if !diagnostic && value >= 0.18 && !allowed {
                note("R2：请先点进 Codex 输入框，并结束听写")
            }
            return
        }
        let binding = KeyBinding(
            label: action == .queue ? "R2 轻按：回车" : "R2 深按：⌘⇧回车",
            key: 36,
            flags: action == .queue ? [] : [.maskCommand, .maskShift])
        perform(binding)
    }

    func moveStick() {
        guard enabled, !diagnostic, let target = NSWorkspace.shared.frontmostApplication,
              VSCodeTarget.matches(target), AXIsProcessTrusted(),
              let stick = sticks.values.max(by: { max(abs($0.0), abs($0.1)) < max(abs($1.0), abs($1.1)) }) else { return }
        let (x, y) = stick
        let amount = max(abs(x), abs(y))
        guard amount > 0.22 else { nextStickKeyTime = .distantPast; return }
        let roles = focusSnapshot(target)?.roles ?? []
        let inMenu = StickNavigation.mode(roles: roles, openedWithOptions: menuNavigation) == .menu
        if !inMenu { menuNavigation = false }
        if inMenu {
            guard Date() >= nextStickKeyTime else { return }
            let first = nextStickKeyTime == .distantPast
            nextStickKeyTime = Date().addingTimeInterval(first ? 0.32 : 0.16)
            let key: CGKeyCode = abs(y) >= abs(x) ? (y > 0 ? 126 : 125) : (x > 0 ? 124 : 123)
            perform(KeyBinding(label: "左摇杆：菜单选择", key: key, flags: []))
            return
        }
        func pixels(_ value: Float) -> Int32 {
            guard abs(value) > 0.22 else { return 0 }
            let speed = pow((Double(abs(value)) - 0.22) / 0.78, 1.5) * 42
            return Int32(max(1, speed)) * (value > 0 ? 1 : -1)
        }
        guard let source = CGEventSource(stateID: .privateState),
              let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                   wheel1: pixels(y), wheel2: -pixels(x), wheel3: 0) else { return }
        guard let point = locator.point(in: target) else {
            note("左摇杆：请先点击 Codex 输入框，以定位聊天区域")
            return
        }
        scroll.location = point
        guard VSCodeTarget.matches(NSWorkspace.shared.frontmostApplication) else { return }
        scroll.post(tap: .cghidEventTap)
    }

    /// Reads the live GameController state. Button callbacks stop arriving once VS Code is in front.
    func pollGamepads() {
        guard !hidInputLive else { return }
        let controllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        var seen = Set<ObjectIdentifier>()
        for controller in controllers {
            guard let pad = controller.extendedGamepad else { continue }
            let owner = ObjectIdentifier(controller)
            seen.insert(owner)
            var input = DualSenseInput()
            if pad.buttonX.isPressed { input.buttons.insert(.square) }
            if pad.buttonY.isPressed { input.buttons.insert(.triangle) }
            if pad.buttonA.isPressed { input.buttons.insert(.cross) }
            if pad.buttonB.isPressed { input.buttons.insert(.circle) }
            if pad.leftShoulder.isPressed { input.buttons.insert(.l1) }
            if pad.rightShoulder.isPressed { input.buttons.insert(.r1) }
            if pad.dpad.up.isPressed { input.buttons.insert(.dpadUp) }
            if pad.dpad.down.isPressed { input.buttons.insert(.dpadDown) }
            if pad.dpad.left.isPressed { input.buttons.insert(.dpadLeft) }
            if pad.dpad.right.isPressed { input.buttons.insert(.dpadRight) }
            if pad.buttonMenu.isPressed { input.buttons.insert(.options) }
            input.leftX = pad.leftThumbstick.xAxis.value
            input.leftY = pad.leftThumbstick.yAxis.value
            input.rightTrigger = pad.rightTrigger.value
            guard let previous = lastPad[owner] else {
                lastPad[owner] = input
                continue
            }
            lastPad[owner] = input
            guard previous != input else { continue }
            if input.buttons != previous.buttons {
                AppLog.write("poll buttons \(input.buttons)")
            }
            applyPadEdges(owner: owner, previous: previous, input: input)
        }
        for owner in lastPad.keys where !seen.contains(owner) {
            lastPad[owner] = nil
        }
    }

    func applyPadEdges(owner: ObjectIdentifier, previous: DualSenseInput, input: DualSenseInput) {
        let pressed = input.buttons.subtracting(previous.buttons)
        let released = previous.buttons.subtracting(input.buttons)
        sticks[owner] = (input.leftX, input.leftY)
        if pressed.contains(.square) { beginDictation(owner: owner) }
        if released.contains(.square) { endDictation(owner: owner) }
        if pressed.contains(.triangle) { toggleLanguage() }
        let keys: [(DualSenseInput.Button, KeyBinding)] = [
            (.cross, KeyBinding(label: "× 回车", key: 36, flags: [])),
            (.circle, KeyBinding(label: "○ Esc", key: 53, flags: [])),
            (.l1, KeyBinding(label: "L1 上一个编辑器", key: 33, flags: [.maskCommand, .maskShift])),
            (.r1, KeyBinding(label: "R1 下一个编辑器", key: 30, flags: [.maskCommand, .maskShift])),
            (.dpadUp, KeyBinding(label: "↑", key: 126, flags: [])),
            (.dpadDown, KeyBinding(label: "↓", key: 125, flags: [])),
            (.dpadLeft, KeyBinding(label: "←", key: 123, flags: [])),
            (.dpadRight, KeyBinding(label: "→", key: 124, flags: [])),
            (.options, KeyBinding(label: "Options 命令面板", key: 35, flags: [.maskCommand, .maskShift]))
        ]
        for (button, binding) in keys where pressed.contains(button) {
            perform(binding)
        }
        if abs(input.rightTrigger - previous.rightTrigger) > 0.02 {
            handleTrigger(owner: owner, value: input.rightTrigger)
        }
    }

    func handleHID(_ input: DualSenseInput) {
        if !hidInputLive {
            hidInputLive = true
            if banner == "需要输入监控" || banner == "未收到按键" { banner = nil }
            updateMenu()
        }
        let owner = ObjectIdentifier(hidIdentity)
        if triggers[owner] == nil {
            var gesture = TriggerGesture()
            _ = gesture.update(0, allowed: true)
            triggers[owner] = gesture
        }
        sticks[owner] = (input.leftX, input.leftY)

        let pressed = input.buttons.subtracting(lastHIDButtons)
        let released = lastHIDButtons.subtracting(input.buttons)
        lastHIDButtons = input.buttons
        if pressed.contains(.square) {
            AppLog.write("hid square down")
            if diagnostic { note("□ 按下") } else { beginDictation(owner: owner) }
        }
        if released.contains(.square) {
            if diagnostic { note("□ 松开") } else { endDictation(owner: owner) }
        }
        if pressed.contains(.triangle) {
            if diagnostic { note("△ 切换语言") } else { toggleLanguage() }
        }
        let keys: [(DualSenseInput.Button, KeyBinding)] = [
            (.cross, KeyBinding(label: "× 回车", key: 36, flags: [])),
            (.circle, KeyBinding(label: "○ Esc", key: 53, flags: [])),
            (.l1, KeyBinding(label: "L1 上一个编辑器", key: 33, flags: [.maskCommand, .maskShift])),
            (.r1, KeyBinding(label: "R1 下一个编辑器", key: 30, flags: [.maskCommand, .maskShift])),
            (.dpadUp, KeyBinding(label: "↑", key: 126, flags: [])),
            (.dpadDown, KeyBinding(label: "↓", key: 125, flags: [])),
            (.dpadLeft, KeyBinding(label: "←", key: 123, flags: [])),
            (.dpadRight, KeyBinding(label: "→", key: 124, flags: [])),
            (.options, KeyBinding(label: "Options 命令面板", key: 35, flags: [.maskCommand, .maskShift]))
        ]
        for (button, binding) in keys where pressed.contains(button) {
            perform(binding)
        }
        let bucket = Int((input.rightTrigger * 50).rounded())
        if bucket != lastR2Bucket {
            lastR2Bucket = bucket
            handleTrigger(owner: owner, value: input.rightTrigger)
        }
    }

    func beginDictation(owner: ObjectIdentifier) {
        lights.set(CodexLights.pattern(phase: lightState.phase, dictating: true))
        guard dictationHold.active == nil else { return }
        guard enabled else { rejectDictation("□（已暂停）"); return }
        guard let target = NSWorkspace.shared.frontmostApplication, VSCodeTarget.matches(target) else {
            let front = NSWorkspace.shared.frontmostApplication
            let name = front?.localizedName ?? front?.bundleIdentifier ?? "未知"
            AppLog.write("square ignored, front=\(front?.bundleIdentifier ?? name)")
            rejectDictation("□（前台是 \(name)，不是 VS Code）")
            return
        }
        guard AXIsProcessTrusted() else {
            AppLog.write("square ignored, accessibility denied")
            rejectDictation("□（辅助功能未授权，打开菜单选「重置辅助功能授权」）")
            return
        }
        guard dictationHold.begin(owner: owner, destination: target) else { return }
        let failure = speech.start()
        if !failure.isEmpty {
            _ = dictationHold.end(owner: owner)
            AppLog.write("dictation failed: \(failure)")
            rejectDictation(failure)
            return
        }
        AppLog.write("dictation started \(speech.language.rawValue)")
        note("□ 正在听（\(speech.language.title)）")
        applyLight()
    }

    func rejectDictation(_ text: String) {
        note(text)
        lights.set(.flash(CodexLights.error, period: 0.4))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.applyLight()
        }
    }

    func endDictation(owner: ObjectIdentifier? = nil) {
        guard let target = dictationHold.end(owner: owner) else { return }
        speech.finish { [weak self] text in
            self?.insertDictation(text, into: target)
            self?.applyLight()
        }
        applyLight()
    }

    func insertDictation(_ text: String, into target: NSRunningApplication) {
        let cleaned = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { note("听写结束，没有识别到文字"); return }
        guard !target.isTerminated,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == target.processIdentifier,
              VSCodeTarget.matches(front) else {
            note("听写结束，VS Code 已不在前台，未输入")
            return
        }
        // The Codex composer is a web view. System dictation draws its own bar
        // instead of typing into it. Paste lands in whichever field is focused.
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(cleaned, forType: .string)
        let pasted = postKey(KeyBinding(label: "粘贴", key: 9, flags: [.maskCommand]), to: front.processIdentifier)
        AppLog.write("dictation paste \(pasted) chars=\(cleaned.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
        note(pasted ? "已把\(speech.language.title)听写粘贴进 VS Code，按 × 或轻按 R2 发送" : "听写完成，但粘贴失败")
    }

    func receiveHook(_ body: Data) {
        guard let signal = HookSignal.decode(body) else { return }
        applySignal(signal, haptic: true)
    }

    func applySignal(_ signal: HookSignal, haptic: Bool) {
        let changed = lightState.receive(signal, now: Date())
        guard changed else { return }
        AppLog.write("phase \(lightState.phase) turn=\(signal.turnID.prefix(8))")
        applyLight()
        note("Codex：\(lightState.phase.title)")
        if haptic && remindersEnabled {
            if signal.kind == .stop { pulse(long: false) }
            if signal.kind == .permissionRequest { pulse(long: true) }
        }
    }

    func applyLight() {
        lights.set(CodexLights.pattern(phase: lightState.phase, dictating: speech.listening || dictationHold.active != nil))
        updateMenu()
    }

    func note(_ text: String) {
        if diagnostic { fputs(text + "\n", stdout); fflush(stdout) }
        lastItem?.title = "最近动作：\(text)"
        if text.contains("辅助功能") { banner = "辅助功能" }
        else if text.contains("不是 VS Code") || text.contains("不在前台") { banner = "切到 VS Code" }
        else if text.contains("麦克风") || text.contains("语音") || text.contains("识别") { banner = "麦克风" }
        else if text.contains("正在听") { banner = "听" }
        else if text.contains("已把") { banner = nil }
        updateMenu()
    }

    func cancelTriggers() {
        for owner in Array(triggers.keys) { triggers[owner]?.cancel() }
    }

    @objc func toggleEnabled() {
        endDictation()
        cancelTriggers()
        menuNavigation = false
        enabled.toggle()
        toggleItem?.state = enabled ? .on : .off
        updateMenu()
    }

    @objc func toggleLanguage() {
        speech.toggleLanguage()
        note("听写语言：\(speech.language.title)")
        updateMenu()
    }

    func requestAccessibilityPrompt() {
        askedAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        AppLog.write("accessibility prompt trusted=\(AXIsProcessTrusted())")
        updateMenu()
    }

    @objc func resetPermissions() {
        for service in ["Accessibility", "ListenEvent"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, "local.ds.vscode-ssh-codex"]
            try? process.run()
            process.waitUntilExit()
        }
        AppLog.write("tcc reset")
        requestAccessibilityPrompt()
        note("已重置授权。允许后请退出再打开")
    }

    @objc func toggleReminders() {
        remindersEnabled.toggle()
        UserDefaults.standard.set(remindersEnabled, forKey: "remindersEnabled")
        reminderItem?.state = remindersEnabled ? .on : .off
    }

    @objc func previewWorking() { preview(.working) }
    @objc func previewNeedsInput() { preview(.needsInput) }
    @objc func previewCompleted() { preview(.completed) }
    @objc func previewError() { preview(.error) }

    func preview(_ phase: CodexPhase) {
        lightState.preview(phase, now: Date())
        applyLight()
        if remindersEnabled && (phase == .completed || phase == .needsInput) {
            pulse(long: phase == .needsInput)
        }
    }

    @objc func testRumble() { pulse(long: false) }

    func pulse(long: Bool) {
        guard Date().timeIntervalSince(lastPulseTime) >= 2 else { return }
        lastPulseTime = Date()
        let controllers = GCController.controllers().filter { $0.extendedGamepad is GCDualSenseGamepad }
        for controller in controllers {
            guard let haptics = controller.haptics, !haptics.supportedLocalities.isEmpty else { continue }
            let locality: GCHapticsLocality = haptics.supportedLocalities.contains(.handles) ? .handles : .default
            guard haptics.supportedLocalities.contains(locality),
                  let engine = haptics.createEngine(withLocality: locality) else { continue }
            do {
                try engine.start()
                let times = long ? [0.0] : [0.0, 0.35]
                let duration = long ? 0.4 : 0.18
                let events = times.map { time in
                    CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.65)],
                                  relativeTime: time, duration: duration)
                }
                let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
                try player.start(atTime: CHHapticTimeImmediate)
                activeEngines.append(engine)
                activePlayers.append(player)
            } catch {
                engine.stop()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            for engine in self.activeEngines { engine.stop() }
            self.activePlayers.removeAll()
            self.activeEngines.removeAll()
        }
    }

    @objc func copyTunnel() {
        let text = "RemoteForward 127.0.0.1:\(server.port) 127.0.0.1:\(server.port)\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note("已复制 SSH RemoteForward")
    }

    @objc func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func frontmostChanged() {
        if !VSCodeTarget.matches(NSWorkspace.shared.frontmostApplication) {
            endDictation()
            cancelTriggers()
            menuNavigation = false
            sticks = sticks.mapValues { _ in (0, 0) }
            locator.reset()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        endDictation()
        stickTimer?.cancel()
        housekeepingTimer?.cancel()
        pollTimer?.cancel()
        lights.stop()
        server.stop()
        for engine in activeEngines { engine.stop() }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}

private func postKey(_ binding: KeyBinding, to pid: pid_t) -> Bool {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: binding.key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: binding.key, keyDown: false) else { return false }
    down.flags = binding.flags
    up.flags = binding.flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    _ = pid
    return true
}

private func postText(_ text: String, to pid: pid_t) {
    _ = pid
    let scalars = Array(text)
    var index = 0
    while index < scalars.count {
        let end = min(index + 16, scalars.count)
        let chunk = String(scalars[index..<end])
        index = end
        let units = Array(chunk.utf16)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private func focusSnapshot(_ target: NSRunningApplication) -> (roles: [String], focused: CGRect?, window: CGRect?)? {
    let application = AXUIElementCreateApplication(target.processIdentifier)
    let window = axElement(application, kAXFocusedWindowAttribute as CFString)
    var element = axElement(application, kAXFocusedUIElementAttribute as CFString)
    var roles: [String] = []
    var focused: CGRect?
    for index in 0..<12 {
        guard let current = element else { break }
        if index == 0 { focused = axFrame(current) }
        if let role = axString(current, kAXRoleAttribute as CFString) { roles.append(role) }
        element = axElement(current, kAXParentAttribute as CFString)
    }
    return (roles, focused, window.flatMap(axFrame))
}

private func axElement(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &result) == .success,
          let result, CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
    return (result as! AXUIElement)
}

private func axString(_ element: AXUIElement, _ name: CFString) -> String? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &result) == .success else { return nil }
    return result as? String
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let positionValue, let sizeValue,
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

@main
enum DSCodexSSHMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
