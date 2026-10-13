import AppKit
import ServiceManagement
import SwiftUI

final class MenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var status: Status = .idle
    private var statsWindow: NSWindow?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        update(Joiner.shared.currentStatus())
        item.isVisible = !UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
    }

    /// Opening the app again (or louisawifi://show) brings a hidden icon back.
    func showIcon() {
        UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")
        item.isVisible = true
    }

    func update(_ status: Status) {
        self.status = status
        let symbol: String
        switch status {
        case .connected: symbol = "cup.and.saucer.fill"
        case .connecting: symbol = "ellipsis.circle"
        default: symbol = "cup.and.saucer"
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "路易莎 Wi-Fi")
        item.button?.image?.isTemplate = true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if case .connecting = status {} else { update(Joiner.shared.currentStatus().orFailure(status)) }
        menu.removeAllItems()
        if let update = Updater.shared.available {
            let item = action("更新到 \(update.version)", #selector(installUpdate))
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
            menu.addItem(item)
            menu.addItem(.separator())
        }
        menu.addItem(disabled(status.text))
        menu.addItem(passwordMenu())
        menu.addItem(.separator())

        let onlyKnown = UserDefaults.standard.bool(forKey: "onlyKnown")
        let known = Joiner.shared.knownStores()
        let stores = onlyKnown ? Stores.all.filter { known.contains($0.name) } : Stores.all

        if onlyKnown && stores.isEmpty {
            menu.addItem(disabled("還沒有連過任何門市"))
        } else if let here = Locator.shared.location {
            menu.addItem(disabled(onlyKnown ? "連過的門市" : "附近門市"))
            for (store, meters) in Stores.nearest(to: here, limit: 6, in: stores) {
                menu.addItem(storeItem(store, detail: distance(meters)))
            }
        } else {
            menu.addItem(action("連線到最近的門市", #selector(connectNearest)))
        }

        let all = NSMenuItem(title: onlyKnown ? "所有連過的門市" : "所有門市", action: nil, keyEquivalent: "")
        all.submenu = NSMenu()
        for (city, cityStores) in Stores.byCity(stores) {
            let cityItem = NSMenuItem(title: "\(city)（\(cityStores.count)）", action: nil, keyEquivalent: "")
            cityItem.submenu = NSMenu()
            cityStores.forEach { cityItem.submenu!.addItem(storeItem($0, detail: nil)) }
            all.submenu!.addItem(cityItem)
        }
        all.isEnabled = !stores.isEmpty
        menu.addItem(all)
        menu.addItem(.separator())

        menu.addItem(action("連線統計…", #selector(showStats)))
        menu.addItem(.separator())

        if !Locator.shared.authorized {
            menu.addItem(action("開啟定位權限…", #selector(openLocationSettings)))
        }
        let auto = action("自動連線", #selector(toggleAuto))
        auto.state = UserDefaults.standard.bool(forKey: "autoConnect") ? .on : .off
        menu.addItem(auto)
        let onlyKnownItem = action("只顯示連過的門市", #selector(toggleOnlyKnown))
        onlyKnownItem.state = onlyKnown ? .on : .off
        menu.addItem(onlyKnownItem)
        menu.addItem(action("不在選單列顯示…", #selector(hideIcon)))
        let login = action("登入時開啟", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action("檢查更新（目前 \(Updater.shared.current)）", #selector(checkForUpdates)))
        menu.addItem(NSMenuItem(title: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: - Items

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        i.target = self
        return i
    }

    private func storeItem(_ store: Store, detail: String?) -> NSMenuItem {
        let i = action(detail.map { "\(store.name)  ·  \($0)" } ?? store.name, #selector(connect(_:)))
        i.representedObject = store.name
        i.toolTip = "\(store.address)\n\(store.phone)"
        return i
    }

    /// For when the store's password is posted on the wall: try exactly that one.
    /// Lists the nearest store's candidates, then every store by city.
    private func passwordMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "用密碼連線", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        if let here = Locator.shared.location, let store = Stores.nearest(to: here, limit: 1).first?.store {
            menu.addItem(disabled(store.name))
            passwordItems(store).forEach { $0.indentationLevel = 1; menu.addItem($0) }
            menu.addItem(.separator())
        }
        let others = NSMenuItem(title: menu.items.isEmpty ? "選擇門市" : "其他門市", action: nil, keyEquivalent: "")
        others.submenu = NSMenu()
        for (city, cityStores) in Stores.byCity() {
            let cityItem = NSMenuItem(title: "\(city)（\(cityStores.count)）", action: nil, keyEquivalent: "")
            cityItem.submenu = NSMenu()
            for store in cityStores {
                let storeItem = NSMenuItem(title: store.name, action: nil, keyEquivalent: "")
                storeItem.submenu = NSMenu()
                passwordItems(store).forEach { storeItem.submenu!.addItem($0) }
                cityItem.submenu!.addItem(storeItem)
            }
            others.submenu!.addItem(cityItem)
        }
        menu.addItem(others)
        item.submenu = menu
        return item
    }

    /// The store's candidate passwords, then 輸入密碼… for anything else.
    private func passwordItems(_ store: Store) -> [NSMenuItem] {
        var items = store.passwords.map { pw -> NSMenuItem in
            let i = action(pw, #selector(connectWithPassword(_:)))
            i.representedObject = [store.name, pw]
            return i
        }
        let other = action("輸入密碼…", #selector(enterPassword(_:)))
        other.representedObject = store.name
        items.append(other)
        return items
    }

    private func distance(_ meters: Double) -> String {
        meters < 1000 ? "\(Int(meters / 10) * 10) m" : String(format: "%.1f km", meters / 1000)
    }

    // MARK: - Actions

    @objc private func connect(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let store = Stores.named(name) else { return }
        Joiner.shared.connect(to: store)
    }

    @objc private func connectWithPassword(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], let store = Stores.named(pair[0]) else { return }
        Joiner.shared.connect(to: store, password: pair[1])
    }

    @objc private func enterPassword(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let store = Stores.named(name) else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = store.passwords.first
        let alert = NSAlert()
        alert.messageText = "輸入\(store.name)的 Wi-Fi 密碼"
        alert.informativeText = "照店內張貼的密碼輸入。連上之後會記住，下次自動使用。"
        alert.accessoryView = field
        alert.addButton(withTitle: "連線")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { return }
        Joiner.shared.connect(to: store, password: password)
    }

    @objc func showStats() {
        if statsWindow == nil {
            let host = NSHostingController(rootView: StatsView(tracker: Tracker.shared))
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "連線統計"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            statsWindow = window
        }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        statsWindow?.makeKeyAndOrderFront(nil)
        statsWindow?.orderFrontRegardless()
    }

    @objc private func installUpdate() { Updater.shared.install() }

    @objc private func checkForUpdates() { Updater.shared.check(manual: true) }

    @objc private func connectNearest() { Joiner.shared.connectNearest() }

    @objc private func toggleAuto() {
        let on = !UserDefaults.standard.bool(forKey: "autoConnect")
        UserDefaults.standard.set(on, forKey: "autoConnect")
        if on { Joiner.shared.autoConnect() }
    }

    @objc private func toggleOnlyKnown() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "onlyKnown"), forKey: "onlyKnown")
    }

    @objc private func hideIcon() {
        let alert = NSAlert()
        alert.messageText = "不在選單列顯示 ☕？"
        alert.informativeText = "Louisa Wi-Fi 會繼續在背景自動連線、記錄時間。\n\n想再顯示時，到「應用程式」再打開一次 LouisaWiFi 就會出現。"
        alert.addButton(withTitle: "隱藏")
        alert.addButton(withTitle: "取消")
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(true, forKey: "hideMenuBarIcon")
        item.isVisible = false
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled { try? service.unregister() } else { try? service.register() }
    }

    @objc private func openLocationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}

private extension Status {
    /// Keep showing a failure until we're actually connected somewhere.
    func orFailure(_ previous: Status) -> Status {
        if case .idle = self, case .failed = previous { return previous }
        return self
    }
}
