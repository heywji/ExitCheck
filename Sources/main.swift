import Cocoa
import UserNotifications

// Menu-bar check of this app's own public exit.
// Green means both sources agree the exit country is US.

private let defaults = UserDefaults.standard
private let keyPinnedIP = "pinnedIP"
private let keyLastLevel = "lastLevel"
private let keyLastIP = "lastIP"
private let keyAuto = "autoRefresh"
private let keyNotify = "notify"
private let refreshSeconds: TimeInterval = 300

private func flag(_ key: String, default fallback: Bool) -> Bool {
    if defaults.object(forKey: key) == nil { return fallback }
    return defaults.bool(forKey: key)
}

private enum Level: String {
    case pass, weak, fail, unknown
}

private struct Observation {
    var source: String
    var ip: String?
    var country: String?
    var place: String?
    var org: String?
    var note: String?
    var error: String?
}

private struct Verdict {
    var level: Level
    var title: String
    var rows: [(String, String)]
    var summary: String
    var alert: String?
}

private func isIPv4(_ ip: String) -> Bool { ip.contains(".") && !ip.contains(":") }

private func parseTrace(_ text: String) -> Observation {
    var fields: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { fields[parts[0]] = parts[1] }
    }
    var note: String?
    if fields["warp"] == "on" { note = "Cloudflare WARP is on" }
    return Observation(
        source: "Cloudflare",
        ip: fields["ip"],
        country: fields["loc"],
        place: nil,
        org: nil,
        note: note,
        error: fields["ip"] == nil ? "no IP returned" : nil
    )
}

private func parseIPInfo(_ data: Data) -> Observation {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return Observation(source: "ipinfo", ip: nil, country: nil, place: nil, org: nil, note: nil, error: "response was not JSON")
    }
    let city = obj["city"] as? String
    let region = obj["region"] as? String
    let place = [city, region].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    let ip = obj["ip"] as? String
    return Observation(
        source: "ipinfo",
        ip: ip,
        country: obj["country"] as? String,
        place: place.isEmpty ? nil : place,
        org: obj["org"] as? String,
        note: nil,
        error: ip == nil ? "no IP returned" : nil
    )
}

private func judge(_ items: [Observation], pinned: String?) -> Verdict {
    let ok = items.filter { $0.ip != nil && $0.error == nil }
    var rows: [(String, String)] = []

    if ok.isEmpty {
        let why = items.compactMap { obs -> String? in
            guard let err = obs.error else { return nil }
            return "\(obs.source)：\(err)"
        }.joined(separator: "；")
        return Verdict(
            level: .unknown,
            title: "Exit not detected",
            rows: [("Reason", why.isEmpty ? "both sources failed" : why)],
            summary: "Exit not detected. \(why)",
            alert: nil
        )
    }

    let countries = Set(ok.compactMap(\.country))
    let v4 = Set(ok.compactMap(\.ip).filter(isIPv4))
    let v6 = Set(ok.compactMap(\.ip).filter { !isIPv4($0) })
    let allUS = !countries.isEmpty && countries.allSatisfy { $0 == "US" }
    let countryConflict = countries.count > 1
    let ipConflict = v4.count > 1 || v6.count > 1
    let singleSource = ok.count < 2

    let primary = ok.first(where: { $0.source == "ipinfo" }) ?? ok[0]
    let ip = primary.ip ?? ok[0].ip ?? "—"
    rows.append(("IP", ip))
    if v4.count == 1, v6.count == 1, let a = v4.first, let b = v6.first, a != ip || b != ip {
        rows.append(("Other address", a == ip ? b : a))
    }

    if let code = primary.country {
        let place = primary.place.map { " · \($0)" } ?? ""
        rows.append(("Country", "\(code)\(place)"))
    } else if let code = ok.compactMap(\.country).first {
        rows.append(("Country", code))
    }
    if let org = ok.compactMap(\.org).first {
        rows.append(("Network", org))
    }
    let sourceLine = items.map { obs -> String in
        if let err = obs.error { return "\(obs.source) failed (\(err))" }
        let loc = obs.country ?? "no country"
        return "\(obs.source) \(obs.ip ?? "—") \(loc)"
    }.joined(separator: "; ")
    rows.append(("Sources", sourceLine))
    if let note = ok.compactMap(\.note).first {
        rows.append(("Note", note))
    }

    var level: Level = .pass
    var title = "Exit is in the US"
    if countryConflict || !allUS {
        level = .fail
        let shown = countries.sorted().joined(separator: " / ")
        title = countries.isEmpty ? "Exit country unknown" : "Exit is not in the US (\(shown))"
        if countryConflict { title = "Sources disagree on country (\(shown))" }
    } else if ipConflict {
        level = .fail
        title = "Sources disagree on IP"
    } else if singleSource {
        level = .weak
        title = "Looks like the US, only one source"
    }

    if let pinned, !pinned.isEmpty {
        let currentIPs = Set(ok.compactMap(\.ip))
        if currentIPs.contains(pinned) {
            rows.append(("Expected IP", "\(pinned), matches"))
        } else {
            rows.append(("Expected IP", "\(pinned), current IP differs"))
            if level == .pass {
                level = .weak
                title = "In the US, but not the expected IP"
            }
        }
    } else {
        rows.append(("Expected IP", "not set"))
    }

    let summary = ([title] + rows.map { "\($0.0): \($0.1)" }).joined(separator: "\n")
    let alert: String? = (level == .fail) ? title : nil
    return Verdict(level: level, title: title, rows: rows, summary: summary, alert: alert)
}

private func makeRequest(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.setValue("us-exit-check/1.0", forHTTPHeaderField: "User-Agent")
    return request
}

private func fetch(_ url: URL) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: makeRequest(url))
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
    }
    return data
}

private func fetchSync(_ url: URL) throws -> Data {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<Data, Error> = .failure(URLError(.unknown))
    let task = URLSession.shared.dataTask(with: makeRequest(url)) { data, response, error in
        if let error {
            result = .failure(error)
        } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(URLError(.badServerResponse))
        } else if let data {
            result = .success(data)
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + 10) == .timedOut {
        task.cancel()
        throw URLError(.timedOut)
    }
    return try result.get()
}

private func probe() async -> [Observation] {
    async let traceTask: Observation = {
        do {
            let data = try await fetch(URL(string: "https://1.1.1.1/cdn-cgi/trace")!)
            let text = String(data: data, encoding: .utf8) ?? ""
            var obs = parseTrace(text)
            if obs.ip == nil { obs.error = "no IP returned" }
            return obs
        } catch {
            return Observation(source: "Cloudflare", ip: nil, country: nil, place: nil, org: nil, note: nil, error: error.localizedDescription)
        }
    }()
    async let infoTask: Observation = {
        do {
            let data = try await fetch(URL(string: "https://ipinfo.io/json")!)
            return parseIPInfo(data)
        } catch {
            return Observation(source: "ipinfo", ip: nil, country: nil, place: nil, org: nil, note: nil, error: error.localizedDescription)
        }
    }()
    return await [traceTask, infoTask]
}

private func runCheck() async -> Verdict {
    let items = await probe()
    return judge(items, pinned: defaults.string(forKey: keyPinnedIP))
}

private func observeSync(_ source: String, _ url: String, _ parse: (Data) -> Observation) -> Observation {
    do {
        let data = try fetchSync(URL(string: url)!)
        var obs = parse(data)
        if obs.ip == nil && obs.error == nil { obs.error = "no IP returned" }
        return obs
    } catch {
        return Observation(source: source, ip: nil, country: nil, place: nil, org: nil, note: nil, error: error.localizedDescription)
    }
}

private func runCheckSync() -> Verdict {
    let group = DispatchGroup()
    var trace = Observation(source: "Cloudflare", ip: nil, country: nil, place: nil, org: nil, note: nil, error: "incomplete")
    var info = Observation(source: "ipinfo", ip: nil, country: nil, place: nil, org: nil, note: nil, error: "incomplete")
    group.enter()
    DispatchQueue.global().async {
        trace = observeSync("Cloudflare", "https://1.1.1.1/cdn-cgi/trace") { data in
            parseTrace(String(data: data, encoding: .utf8) ?? "")
        }
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        info = observeSync("ipinfo", "https://ipinfo.io/json", parseIPInfo)
        group.leave()
    }
    group.wait()
    return judge([trace, info], pinned: defaults.string(forKey: keyPinnedIP))
}

private enum SelfTest {
    static func run() -> Bool {
        var passed = true
        func check(_ name: String, _ ok: Bool) {
            if !ok {
                fputs("FAIL \(name)\n", stderr)
                passed = false
            }
        }
        let trace = parseTrace("ip=8.8.8.8\nloc=US\ncolo=LAX\nwarp=off\n")
        check("trace ip", trace.ip == "8.8.8.8" && trace.country == "US" && trace.note == nil)
        let warp = parseTrace("ip=1.1.1.1\nloc=JP\nwarp=on\n")
        check("warp note", warp.note == "Cloudflare WARP is on" && warp.country == "JP")

        let infoJSON = #"{"ip":"8.8.8.8","city":"Los Angeles","region":"California","country":"US","org":"AS15169 Google LLC"}"#.data(using: .utf8)!
        let info = parseIPInfo(infoJSON)
        check("ipinfo", info.ip == "8.8.8.8" && info.country == "US" && info.org == "AS15169 Google LLC" && info.place == "Los Angeles · California")

        let us = Observation(source: "Cloudflare", ip: "8.8.8.8", country: "US", place: nil, org: nil, note: nil, error: nil)
        let usInfo = Observation(source: "ipinfo", ip: "8.8.8.8", country: "US", place: "Los Angeles · California", org: "AS15169 Google LLC", note: nil, error: nil)
        check("agree", judge([us, usInfo], pinned: nil).level == .pass)

        let jp = Observation(source: "ipinfo", ip: "1.2.3.4", country: "JP", place: nil, org: nil, note: nil, error: nil)
        check("country split", judge([us, jp], pinned: nil).level == .fail)

        let otherUS = Observation(source: "ipinfo", ip: "9.9.9.9", country: "US", place: nil, org: nil, note: nil, error: nil)
        check("ip split", judge([us, otherUS], pinned: nil).level == .fail)

        let v6 = Observation(source: "ipinfo", ip: "2001:db8::1", country: "US", place: nil, org: nil, note: nil, error: nil)
        check("v4v6", judge([us, v6], pinned: nil).level == .pass)

        let down = Observation(source: "ipinfo", ip: nil, country: nil, place: nil, org: nil, note: nil, error: "timed out")
        check("one source", judge([us, down], pinned: nil).level == .weak)

        let pinned = judge([us, usInfo], pinned: "9.9.9.9")
        check("pin mismatch", pinned.level == .weak && pinned.title.contains("expected"))
        check("pin match", judge([us, usInfo], pinned: "8.8.8.8").level == .pass)

        let none = Observation(source: "Cloudflare", ip: nil, country: nil, place: nil, org: nil, note: nil, error: "offline")
        check("offline", judge([none, down], pinned: nil).level == .unknown)
        return passed
    }
}

private let positionKey = "NSStatusItem Preferred Position ExitCheck"

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var busy = false
    private var lastVerdict: Verdict?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if defaults.object(forKey: keyAuto) == nil { defaults.set(true, forKey: keyAuto) }
        if defaults.object(forKey: keyNotify) == nil { defaults.set(true, forKey: keyNotify) }
        placeBesideWiFiIfUnset()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ExitCheck"
        statusItem.behavior = .removalAllowed
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showMenu(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        apply(level: .unknown, title: "Checking")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        scheduleTimer()
        Task { await self.refresh(notify: true) }
    }

    private func placeBesideWiFiIfUnset() {
        guard defaults.object(forKey: positionKey) == nil else { return }
        let controlCenter = UserDefaults.standard.persistentDomain(forName: "com.apple.controlcenter")
        guard let wifi = (controlCenter?["NSStatusItem Preferred Position WiFi"] as? NSNumber)?.doubleValue else { return }
        defaults.set(wifi + 16, forKey: positionKey)
    }

    @objc private func showMenu(_ sender: Any?) {
        guard statusItem.menu == nil else { return }
        let menu = makeMenu(verdict: lastVerdict, checking: busy)
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard flag(keyAuto, default: true) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(notify: true) }
        }
    }

    private func statusImage(color: NSColor) -> NSImage {
        let points: CGFloat = 18
        let pixels = 36
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = points
        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: s * 0.50, y: s * 0.06))
        shield.line(to: NSPoint(x: s * 0.90, y: s * 0.26))
        shield.line(to: NSPoint(x: s * 0.90, y: s * 0.56))
        shield.curve(
            to: NSPoint(x: s * 0.50, y: s * 0.94),
            controlPoint1: NSPoint(x: s * 0.90, y: s * 0.78),
            controlPoint2: NSPoint(x: s * 0.70, y: s * 0.94)
        )
        shield.curve(
            to: NSPoint(x: s * 0.10, y: s * 0.56),
            controlPoint1: NSPoint(x: s * 0.30, y: s * 0.94),
            controlPoint2: NSPoint(x: s * 0.10, y: s * 0.78)
        )
        shield.line(to: NSPoint(x: s * 0.10, y: s * 0.26))
        shield.close()
        color.setFill()
        shield.fill()
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: s * 0.39, y: s * 0.40, width: s * 0.22, height: s * 0.22)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    private func apply(level: Level, title: String) {
        let color: NSColor
        switch level {
        case .pass: color = .systemGreen
        case .weak: color = .systemYellow
        case .fail: color = .systemRed
        case .unknown: color = .systemGray
        }
        statusItem.button?.image = statusImage(color: color)
        statusItem.button?.imagePosition = .imageLeading
        let label: String
        switch level {
        case .pass: label = "US"
        case .weak: label = "US?"
        case .fail: label = "NO"
        case .unknown: label = "…"
        }
        statusItem.button?.title = " " + label
        statusItem.button?.toolTip = title
    }

    private func makeMenu(verdict: Verdict?, checking: Bool) -> NSMenu {
        let menu = NSMenu()
        let head = NSMenuItem(title: checking ? "Checking…" : (verdict?.title ?? "Not checked yet"), action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        if let verdict {
            for row in verdict.rows {
                let item = NSMenuItem(title: "\(row.0): \(row.1)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let now = NSMenuItem(title: "Check Now", action: #selector(checkNow), keyEquivalent: "r")
        now.target = self
        menu.addItem(now)

        let pinned = defaults.string(forKey: keyPinnedIP)
        let hasPin = pinned?.isEmpty == false
        let pin = NSMenuItem(title: hasPin ? "Unpin" : "Pin Current IP", action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        pin.state = hasPin ? .on : .off
        let hasIP = lastVerdict?.rows.contains { $0.0 == "IP" && $0.1 != "—" } ?? false
        pin.isEnabled = hasPin || hasIP
        menu.addItem(pin)

        let auto = NSMenuItem(title: "Check Every 5 Minutes", action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = flag(keyAuto, default: true) ? .on : .off
        menu.addItem(auto)

        let notify = NSMenuItem(title: "Notify When Exit Is Not US", action: #selector(toggleNotify), keyEquivalent: "")
        notify.target = self
        notify.state = flag(keyNotify, default: true) ? .on : .off
        menu.addItem(notify)

        let copy = NSMenuItem(title: "Copy Diagnostics", action: #selector(copySummary), keyEquivalent: "c")
        copy.target = self
        copy.isEnabled = lastVerdict != nil
        menu.addItem(copy)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func refresh(notify: Bool) async {
        if busy { return }
        busy = true
        let verdict = await runCheck()
        lastVerdict = verdict
        apply(level: verdict.level, title: verdict.title)
        if notify { maybeNotify(verdict) }
        defaults.set(verdict.level.rawValue, forKey: keyLastLevel)
        if let ip = verdict.rows.first(where: { $0.0 == "IP" })?.1, ip != "—" {
            defaults.set(ip, forKey: keyLastIP)
        }
        busy = false
    }

    private func maybeNotify(_ verdict: Verdict) {
        guard flag(keyNotify, default: true) else { return }
        let previous = defaults.string(forKey: keyLastLevel)
        guard verdict.level == .fail, previous != Level.fail.rawValue, let text = verdict.alert else { return }
        let content = UNMutableNotificationContent()
        content.title = "ExitCheck"
        content.body = text
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    @objc private func checkNow() { Task { await refresh(notify: true) } }

    @objc private func togglePin() {
        if let pinned = defaults.string(forKey: keyPinnedIP), !pinned.isEmpty {
            defaults.removeObject(forKey: keyPinnedIP)
        } else if let ip = lastVerdict?.rows.first(where: { $0.0 == "IP" })?.1, ip != "—" {
            defaults.set(ip, forKey: keyPinnedIP)
        }
        Task { await refresh(notify: false) }
    }

    @objc private func toggleAuto(_ sender: NSMenuItem) {
        let on = sender.state != .on
        defaults.set(on, forKey: keyAuto)
        scheduleTimer()
    }

    @objc private func toggleNotify(_ sender: NSMenuItem) {
        defaults.set(sender.state != .on, forKey: keyNotify)
    }

    @objc private func copySummary() {
        guard let text = lastVerdict?.summary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

@main
private enum ExitCheckMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--once") {
            let verdict = runCheckSync()
            print(verdict.summary)
            exit(verdict.level == .pass || verdict.level == .weak ? 0 : 2)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
