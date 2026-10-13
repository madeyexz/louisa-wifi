import CoreLocation
import CoreWLAN
import Foundation
import os

let louisaSSID = "LouisaCoffee"

enum Status {
    case idle
    case connecting(String)
    case connected(String?)
    case failed(String)

    var text: String {
        switch self {
        case .idle: return "附近沒有路易莎 Wi-Fi"
        case .connecting(let what): return "連線中：\(what)…"
        case .connected(let store): return store.map { "已連上：\($0)" } ?? "已連上路易莎"
        case .failed(let why): return why
        }
    }
}

/// Finds the right password for the Louisa you're at and joins it.
/// All Wi-Fi work happens on one serial queue because scanning and joining block.
final class Joiner {
    static let shared = Joiner()
    var onStatus: ((Status) -> Void)?

    private let queue = DispatchQueue(label: "louisawifi.join")
    private var autoQueued = false                  // main thread only
    private var snoozed: [String: Date] = [:]       // BSSIDs we recently failed on
    private var quietUntil = Date.distantPast       // our own joins fire link events; ignore them
    private var learned: [String: Learned]          // BSSID → what worked there; guarded by lock
    private var epoch = 0                           // bumped by user actions to stop a running attempt; guarded by lock
    private let lock = NSLock()

    private struct Learned: Codable { let store: String; let password: String }

    private static let learnedURL = supportDir.appendingPathComponent("learned.json")
    private static let statusURL = supportDir.appendingPathComponent("status.json")

    private init() {
        let data = try? Data(contentsOf: Self.learnedURL)
        learned = data.flatMap { try? JSONDecoder().decode([String: Learned].self, from: $0) } ?? [:]
    }

    private var iface: CWInterface? { CWWiFiClient.shared().interface() }

    /// Associated to any network. ssid()/bssid() are nil without Location
    /// permission, but RSSI is not redacted.
    private func associated(_ i: CWInterface) -> Bool { i.rssiValue() != 0 }

    /// Store name for the network we're on, if we've learned it.
    func currentStore() -> String? {
        guard let b = iface?.bssid() else { return nil }
        return lookup(norm(b))?.store
    }

    /// Names of stores we've successfully joined at least once.
    func knownStores() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(learned.values.map { $0.store })
    }

    private func lookup(_ bssid: String) -> Learned? {
        lock.lock(); defer { lock.unlock() }
        return learned[bssid]
    }

    func currentStatus() -> Status {
        guard let i = iface, i.powerOn(), associated(i) else { return .idle }
        if i.ssid() == louisaSSID { return .connected(currentStore()) }
        return .idle
    }

    // MARK: - Entry points

    /// Called on Wi-Fi changes, location changes and a timer. Coalesces bursts.
    func autoConnect() {
        DispatchQueue.main.async {
            guard !self.autoQueued, UserDefaults.standard.bool(forKey: "autoConnect") else { return }
            self.autoQueued = true
            let here = Locator.shared.location
            let e = self.currentEpoch()
            self.queue.async {
                self.runAuto(near: here, epoch: e)
                DispatchQueue.main.async { self.autoQueued = false }
            }
        }
    }

    /// User picked a store from the menu or Raycast, optionally with the exact password.
    func connect(to store: Store, password: String? = nil) {
        let e = interrupt()
        queue.async {
            // Trying passwords drops the current connection, so don't if it already works.
            // ssid() is nil until Location is authorized; then fall back to "is it online?".
            if let i = self.iface, self.associated(i) {
                if i.ssid() == louisaSSID { return self.report(.connected(self.currentStore()), notify: true) }
                if i.ssid() == nil && online() { return self.report(.failed("目前已可上網，保留現有連線"), notify: true) }
            }
            self.report(.connecting(store.name))
            guard let i = self.iface, let nets = self.scan(i) else {
                return self.report(.failed("附近找不到路易莎 Wi-Fi"), notify: true)
            }
            let tried = password.map { [$0] } ?? self.learnedPasswords(nets.bssids, store: store.name) + store.passwords
            for pw in unique(tried) {
                guard self.current(e) else { return }
                if self.join(i, nets.best, pw) {
                    self.remember(nets, store: store.name, password: pw)
                    return self.report(.connected(store.name), notify: true)
                }
            }
            let why = password.map { "密碼 \($0) 無法連上\(store.name)" } ?? "無法連上\(store.name)，請確認門市與密碼"
            self.report(.failed(why), notify: true)
        }
    }

    /// Connect to the nearest store, ignoring auto-connect setting and snoozes.
    func connectNearest() {
        let here = Locator.shared.location
        let e = interrupt()
        queue.async {
            self.snoozed.removeAll()
            self.runAuto(near: here, manual: true, epoch: e)
        }
    }

    // MARK: - Auto

    private func runAuto(near here: CLLocation?, manual: Bool = false, epoch e: Int) {
        guard let i = iface, i.powerOn() else {
            if manual { report(.failed("請先開啟 Wi-Fi"), notify: true) }
            return
        }
        if !manual && Date() < quietUntil { return }
        if associated(i) {
            if manual { report(currentStatus(), notify: true) }
            return
        }
        guard let nets = scan(i) else {
            if manual { report(.idle, notify: true) }
            return
        }
        let key = nets.bssids.first ?? "?"
        if let until = snoozed[key], until > Date() { return }

        // 1. Routers we've joined before. 2. The 3 nearest stores, best guess of each first.
        var tries: [(store: String, password: String)] = []
        for b in nets.bssids { if let l = lookup(b) { tries.append((l.store, l.password)) } }
        if let here {
            let near = Stores.nearest(to: here, limit: 3).filter { $0.meters < 5000 }.map { $0.store }
            for n in 0..<3 { for s in near where n < s.passwords.count { tries.append((s.name, s.passwords[n])) } }
        }
        var seen = Set<String>()
        tries = tries.filter { seen.insert($0.password).inserted }

        guard !tries.isEmpty else {
            snoozed[key] = Date().addingTimeInterval(600)
            let why = Locator.shared.authorized ? "無法辨識門市，請從選單選擇" : "請允許定位，以自動尋找附近門市"
            return report(.failed(why), notify: true)
        }

        report(.connecting(tries[0].store))
        for t in tries {
            guard current(e) else { return }
            if join(i, nets.best, t.password) {
                remember(nets, store: t.store, password: t.password)
                return report(.connected(t.store), notify: true)
            }
        }
        snoozed[key] = Date().addingTimeInterval(600)
        report(.failed("自動連線失敗，請從選單選擇門市"), notify: true)
    }

    // MARK: - Interrupting

    /// A user action supersedes whatever is running; it stops before its next password.
    private func interrupt() -> Int {
        lock.lock(); defer { lock.unlock() }
        epoch += 1
        return epoch
    }

    private func currentEpoch() -> Int {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    private func current(_ e: Int) -> Bool { currentEpoch() == e }

    // MARK: - Wi-Fi

    private struct Scan { let best: CWNetwork; let bssids: [String]; let nearby: [String] }

    private func scan(_ i: CWInterface) -> Scan? {
        guard let found = try? i.scanForNetworks(withName: louisaSSID), !found.isEmpty else { return nil }
        let nets = found.sorted { $0.rssiValue > $1.rssiValue }
        return Scan(best: nets[0],
                    bssids: nets.compactMap { $0.bssid.map(norm) },
                    nearby: nets.filter { $0.rssiValue > -75 }.compactMap { $0.bssid.map(norm) })
    }

    private func join(_ i: CWInterface, _ net: CWNetwork, _ password: String) -> Bool {
        let start = Date()
        do {
            try i.associate(to: net, password: password)
            quietUntil = Date().addingTimeInterval(15)
            debugLog("joined in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            return true
        } catch {
            debugLog("failed in \(String(format: "%.1f", Date().timeIntervalSince(start)))s: \(error.localizedDescription)")
            return false
        }
    }

    private func learnedPasswords(_ bssids: [String], store: String) -> [String] {
        bssids.compactMap(lookup).filter { $0.store == store }.map { $0.password }
    }

    private func remember(_ nets: Scan, store: String, password: String) {
        lock.lock()
        for b in Set(nets.nearby + nets.bssids.prefix(1)) { learned[b] = Learned(store: store, password: password) }
        let data = try? JSONEncoder().encode(learned)
        lock.unlock()
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? data?.write(to: Self.learnedURL)
    }

    private func report(_ status: Status, notify: Bool = false) {
        debugLog(status.text)
        writeStatus(status)
        DispatchQueue.main.async {
            self.onStatus?(status)
            if notify { Notifier.post(status.text) }
        }
    }

    /// For the Raycast script, which can't talk to us directly.
    private func writeStatus(_ status: Status) {
        let state: String
        switch status {
        case .idle: state = "idle"
        case .connecting: state = "connecting"
        case .connected: state = "connected"
        case .failed: state = "failed"
        }
        let json: [String: Any] = ["state": state, "message": status.text, "time": Date().timeIntervalSince1970]
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: json).write(to: Self.statusURL)
    }
}

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("LouisaWiFi")

/// Same check macOS uses for captive portals.
func online() -> Bool {
    var request = URLRequest(url: URL(string: "http://captive.apple.com/hotspot-detect.html")!)
    request.timeoutInterval = 3
    request.cachePolicy = .reloadIgnoringLocalCacheData
    final class Result: @unchecked Sendable { var ok = false }
    let result = Result()
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, _, _ in
        result.ok = data.map { String(decoding: $0, as: UTF8.self).contains("Success") } ?? false
        done.signal()
    }.resume()
    done.wait()
    return result.ok
}

func norm(_ bssid: String) -> String {
    bssid.lowercased().split(separator: ":").map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
}

func unique(_ xs: [String]) -> [String] {
    var seen = Set<String>()
    return xs.filter { seen.insert($0).inserted }
}

private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LouisaWiFi.log")

private let logger = Logger(subsystem: "io.github.louisawifi", category: "wifi")

/// Unified log plus ~/Library/Logs/LouisaWiFi.log, which is easier to share.
func debugLog(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    let line = Data("\(Date().formatted(.iso8601)) \(message)\n".utf8)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line)
        try? h.close()
    } else {
        try? line.write(to: logURL)
    }
}
