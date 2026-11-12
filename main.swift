// EkranOdak — imleç başka bir ekrana geçtiğinde o ekrandaki pencereyi tıklamadan aktif eder.
//
// Çalışma mantığı:
//   1. Saniyede ~25 kez imlecin hangi ekranda olduğuna bakar (çok ucuz bir çağrı).
//   2. Ekran değiştiyse ve imleç kısa bir süre (varsayılan 100 ms) orada kaldıysa,
//      o ekranda imlecin altındaki en üst pencereyi bulur; altında pencere yoksa
//      o ekrandaki en üst pencereyi seçer.
//   3. Bu pencereyi Erişilebilirlik (Accessibility) API'siyle ana pencere yapar,
//      öne alır ve uygulamasını aktif eder.

import Cocoa
import ApplicationServices
import ServiceManagement

// Belgelenmemiş ama yıllardır kararlı bir API (Rectangle, AltTab, Hammerspoon da kullanır):
// bir AX pencere öğesinin CoreGraphics pencere numarasını verir.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Ayarlar ve günlük

enum Keys {
    static let enabled = "enabled"
    static let delayMs = "delayMs"
    static let debug = "debug"
}

enum Log {
    nonisolated(unsafe) static var enabled = false
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/EkranOdak.log")

    static func write(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(Date()) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Pencere bulma (CoreGraphics; koordinatlar sol-üst köşe orijinli, global)

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let bounds: CGRect
}

enum Windows {
    static let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// Ekranda görünen normal pencereler (önden arkaya sıralı) ve açık bir menü olup olmadığı.
    static func visible() -> (windows: [WindowInfo], menuOpen: Bool) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return ([], false)
        }
        let me = getpid()
        var result: [WindowInfo] = []
        var menuOpen = false
        for w in list {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if layer == popUpMenuLayer { menuOpen = true }
            guard layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width >= 60, rect.height >= 60,
                  let id = w[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            result.append(WindowInfo(id: id, pid: pid,
                                     owner: w[kCGWindowOwnerName as String] as? String ?? "?",
                                     bounds: rect))
        }
        return (result, menuOpen)
    }

    /// İmlecin altındaki en üst pencere; yoksa o ekrandaki en üst pencere.
    static func target(at point: CGPoint, display: CGDirectDisplayID, in windows: [WindowInfo]) -> WindowInfo? {
        if let w = windows.first(where: { $0.bounds.contains(point) }) { return w }
        let screen = CGDisplayBounds(display)
        return windows.first(where: { screen.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) })
    }
}

func display(at point: CGPoint) -> CGDirectDisplayID? {
    var id: CGDirectDisplayID = 0
    var count: UInt32 = 0
    guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
    return id
}

func mouseLocation() -> CGPoint? {
    CGEvent(source: nil)?.location
}

// MARK: - Odaklama (Accessibility API)

enum Focuser {
    static func axApp(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)  // cevap vermeyen bir uygulama bizi kilitlemesin
        return app
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success ? id : nil
    }

    static func axWindow(of app: AXUIElement, id: CGWindowID) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first(where: { windowID(of: $0) == id })
    }

    /// Hedef pencere zaten klavye odağına sahip mi?
    static func isFocused(_ target: WindowInfo) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp(target.pid), kAXFocusedWindowAttribute as CFString,
                                            &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        return windowID(of: value as! AXUIElement) == target.id
    }

    static func focus(_ target: WindowInfo) {
        let app = axApp(target.pid)
        if let window = axWindow(of: app, id: target.id) {
            // Önce doğru pencereyi ana pencere yap ki uygulama öne gelince
            // (ör. iki ekranda da Chrome penceresi varken) bu pencere odak alsın.
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        } else {
            Log.write("AX penceresi bulunamadı: \(target.owner) #\(target.id)")
        }
        let result = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if result != .success {
            Log.write("AXFrontmost başarısız (\(result.rawValue)), NSRunningApplication deneniyor")
            NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
        }
    }
}

// MARK: - İmleç izleyici

@MainActor
final class Watcher {
    var enabled = true
    var delay: TimeInterval = 0.1

    private var timer: Timer?
    private var current: CGDirectDisplayID?
    private var pending: (display: CGDirectDisplayID, since: Date)?

    func start() {
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)  // menüler açıkken de çalışsın
        self.timer = timer
    }

    private func tick() {
        guard let point = mouseLocation(), let screen = display(at: point) else { return }
        guard let current else { self.current = screen; return }
        if screen == current { pending = nil; return }

        // Kapalıyken ya da izin yokken sadece hangi ekranda olduğumuzu takip et.
        guard enabled, AXIsProcessTrusted() else { self.current = screen; pending = nil; return }

        if pending?.display != screen { pending = (screen, Date()) }
        guard let pending, Date().timeIntervalSince(pending.since) >= delay else { return }

        // Bir şey sürükleniyorsa bırakılana kadar bekle.
        guard NSEvent.pressedMouseButtons == 0 else { return }

        let (windows, menuOpen) = Windows.visible()
        guard !menuOpen else { return }  // açık menü kapanana kadar bekle

        self.current = screen
        self.pending = nil

        guard let target = Windows.target(at: point, display: screen, in: windows) else {
            Log.write("Ekran \(screen): pencere yok")
            return
        }
        if Focuser.isFocused(target) { return }
        Log.write("Ekran \(screen): odak → \(target.owner) #\(target.id)")
        Focuser.focus(target)
    }
}

// MARK: - Menü çubuğu uygulaması

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let watcher = Watcher()
    private var statusItem: NSStatusItem!
    private let defaults = UserDefaults.standard
    private let delayOptions = [0, 100, 200, 300, 500]

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [Keys.enabled: true, Keys.delayMs: 100, Keys.debug: false])
        watcher.enabled = defaults.bool(forKey: Keys.enabled)
        watcher.delay = Double(defaults.integer(forKey: Keys.delayMs)) / 1000
        Log.enabled = defaults.bool(forKey: Keys.debug)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        // İzin yoksa sistem izin penceresini göster.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        watcher.start()
        Log.write("Başladı (izin: \(AXIsProcessTrusted()))")
    }

    private func updateIcon() {
        let name = watcher.enabled ? "display.2" : "display"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "EkranOdak")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !watcher.enabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠︎ Erişilebilirlik izni gerekli…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }

        let enabledItem = item("Etkin", #selector(toggleEnabled))
        enabledItem.state = watcher.enabled ? .on : .off
        menu.addItem(enabledItem)

        let delayMenu = NSMenu()
        let currentDelay = defaults.integer(forKey: Keys.delayMs)
        for ms in delayOptions {
            let option = item(ms == 0 ? "Yok" : "\(ms) ms", #selector(setDelay(_:)))
            option.tag = ms
            option.state = ms == currentDelay ? .on : .off
            delayMenu.addItem(option)
        }
        let delayItem = NSMenuItem(title: "Gecikme", action: nil, keyEquivalent: "")
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)

        let loginItem = item("Girişte başlat", #selector(toggleLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let debugItem = item("Günlük tut (hata ayıklama)", #selector(toggleDebug))
        debugItem.state = Log.enabled ? .on : .off
        menu.addItem(debugItem)

        menu.addItem(.separator())
        menu.addItem(item("Çık", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleEnabled() {
        watcher.enabled.toggle()
        defaults.set(watcher.enabled, forKey: Keys.enabled)
        updateIcon()
    }

    @objc private func setDelay(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: Keys.delayMs)
        watcher.delay = Double(sender.tag) / 1000
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Girişte başlatma ayarlanamadı"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func toggleDebug() {
        Log.enabled.toggle()
        defaults.set(Log.enabled, forKey: Keys.debug)
    }

    @objc private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Teşhis modu: `EkranOdak --probe` ekranları ve hedef pencereleri yazdırır

func probe() {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)

    let point = mouseLocation() ?? .zero
    let (windows, menuOpen) = Windows.visible()
    print("Erişilebilirlik izni: \(AXIsProcessTrusted())")
    print("İmleç: \(point) → ekran \(display(at: point).map(String.init) ?? "?")")
    print("Ön plandaki uygulama: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    print("Görünür pencere sayısı: \(windows.count), açık menü: \(menuOpen)")
    for id in ids {
        let bounds = CGDisplayBounds(id)
        let fallback = Windows.target(at: CGPoint(x: -99999, y: -99999), display: id, in: windows)
        print("Ekran \(id)\(CGDisplayIsMain(id) != 0 ? " (ana)" : ""): \(bounds)")
        print("  imleç altında yoksa seçilecek: \(fallback.map { "\($0.owner) #\($0.id) \($0.bounds)" } ?? "pencere yok")")
    }
    if let screen = display(at: point), let t = Windows.target(at: point, display: screen, in: windows) {
        print("İmlecin altındaki hedef: \(t.owner) #\(t.id) \(t.bounds)")
    }
}

// MARK: - Giriş noktası

if CommandLine.arguments.contains("--probe") {
    probe()
    exit(0)
}

// Test modu: `EkranOdak --focus <ekranNo>` o ekranın hedef penceresini odaklar ve sonucu yazar.
if let i = CommandLine.arguments.firstIndex(of: "--focus"), i + 1 < CommandLine.arguments.count,
   let screen = CGDirectDisplayID(CommandLine.arguments[i + 1]) {
    let (windows, _) = Windows.visible()
    guard let target = Windows.target(at: CGPoint(x: -99999, y: -99999), display: screen, in: windows) else {
        print("Ekran \(screen): pencere yok"); exit(1)
    }
    print("Önce: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"), hedef: \(target.owner) #\(target.id)")
    Focuser.focus(target)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    print("Sonra: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"), hedef odakta: \(Focuser.isFocused(target))")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
