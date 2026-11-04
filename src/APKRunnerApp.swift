import AppKit
import CoreServices
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Helpers

struct CmdResult {
    let code: Int32
    let out: String
    let err: String
    let timedOut: Bool
    var ok: Bool { code == 0 && !timedOut }
    var combined: String { (out + err).trimmingCharacters(in: .whitespacesAndNewlines) }
}

final class DataBox { var data = Data() }

struct XapkSplit: Decodable {
    let file: String?
    let id: String?
}

struct XapkManifest: Decodable {
    let package_name: String?
    let name: String?
    let split_apks: [XapkSplit]?
}

func sdkRoot() -> URL {
    let env = ProcessInfo.processInfo.environment
    for key in ["ANDROID_SDK_ROOT", "ANDROID_HOME"] {
        if let v = env[key], !v.isEmpty, FileManager.default.fileExists(atPath: v) {
            return URL(fileURLWithPath: v)
        }
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Android/sdk")
}

func tool(_ rel: String) -> URL { sdkRoot().appendingPathComponent(rel) }



func aapt2() -> URL? {
    let dir = tool("build-tools")
    guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
    for d in items.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
        let exe = d.appendingPathComponent("aapt2")
        if FileManager.default.isExecutableFile(atPath: exe.path) { return exe }
    }
    return nil
}

func runProcess(_ exe: URL, _ args: [String], timeout: TimeInterval = 90) -> CmdResult {
    guard FileManager.default.isExecutableFile(atPath: exe.path) else {
        return CmdResult(code: -1, out: "", err: "Не найден: \(exe.path)", timedOut: false)
    }
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["ANDROID_HOME"] = sdkRoot().path
    env["ANDROID_SDK_ROOT"] = sdkRoot().path
    env["PATH"] = "\(tool("platform-tools").path):\(env["PATH"] ?? "/usr/bin:/bin")"
    p.environment = env
    p.currentDirectoryURL = sdkRoot()

    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    p.standardInput = FileHandle.nullDevice

    do { try p.run() } catch {
        return CmdResult(code: -1, out: "", err: "\(error.localizedDescription)", timedOut: false)
    }

    let outBox = DataBox(), errBox = DataBox()
    let group = DispatchGroup()
    DispatchQueue.global(qos: .userInitiated).async(group: group) {
        outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
    }
    DispatchQueue.global(qos: .userInitiated).async(group: group) {
        errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(40_000) }
    var timedOut = false
    if p.isRunning {
        timedOut = true
        p.terminate()
        usleep(250_000)
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
    group.wait()
    p.waitUntilExit()
    return CmdResult(code: p.terminationStatus,
                     out: String(decoding: outBox.data, as: UTF8.self),
                     err: String(decoding: errBox.data, as: UTF8.self),
                     timedOut: timedOut)
}

let knownNames: [String: String] = [
    "com.whatsapp": "WhatsApp",
    "org.telegram.messenger": "Telegram",
    "org.telegram.messenger.web": "Telegram X",
    "com.instagram.android": "Instagram",
    "com.vkontakte.android": "VK",
    "com.google.android.youtube": "YouTube",
    "com.spotify.music": "Spotify",
    "com.netflix.mediaclient": "Netflix",
    "com.supercell.clashofclans": "Clash of Clans",
    "com.mojang.minecraftpe": "Minecraft",
    "com.zhiliaoapp.musically": "TikTok",
    "com.discord": "Discord",
    "org.mozilla.firefox": "Firefox",
    "com.android.chrome": "Chrome",
    "ru.sberbankmobile": "СберБанк",
    "com.idamob.tinkoff.android": "Т-Банк",
    "ru.tinkoff.investing": "Т-Инвестиции",
    "com.vk.mail": "VK Почта",
    "ru.yandex.taxi": "Яндекс Go",
    "ru.yandex.market": "Яндекс Маркет",
    "com.alfamobile.alfa": "Альфа-Банк",
    "ru.vtb24.mobilebanking.android": "ВТБ",
    "com.gosuslugi.gosuslugi": "Госуслуги",
    "ru.mts.mymts": "Мой МТС",
    "org.fdroid.fdroid": "F-Droid",
    "com.aurora.store": "Aurora Store",
]

func prettyName(for package: String) -> String {
    if let n = knownNames[package.lowercased()] { return n }
    let generic: Set<String> = ["com", "org", "net", "ru", "io", "app", "android",
                                "mobile", "client", "main", "core", "free", "pro", "release"]
    let parts = package.split(separator: ".").map(String.init)
    let meaningful = parts.filter { !generic.contains($0.lowercased()) }
    var core = meaningful.last ?? parts.last ?? package
    core = core.replacingOccurrences(of: "_", with: " ")
    for suffix in ["android", "mobile", "client"] where core.lowercased().hasSuffix(suffix) && core.count > suffix.count + 3 {
        core = String(core.dropLast(suffix.count))
    }
    guard !core.isEmpty else { return package }
    return core.prefix(1).uppercased() + core.dropFirst()
}

enum NameStore {
    private static let key = "apkrunner.displaynames"

    static func saved(for package: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[package]
    }

    static func save(_ name: String?, for package: String) {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[package] = name
        UserDefaults.standard.set(all, forKey: key)
    }
}

// MARK: - Controller

enum EmuState {
    case unknown, stopped, booting, running, error
}

final class AndroidController: ObservableObject {
    static let shared = AndroidController()

    @Published var state: EmuState = .unknown
    @Published var busy = false
    @Published var message = "Проверяю Android…"
    @Published var apps: [AppInfo] = []
    @Published var lastLog = ""
    @Published var showLog = false
    @Published var autoQuit = true
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var lastErrorText: String?
    private var messageAt = Date.distantPast

    struct AppInfo: Identifiable, Hashable {
        let id: String
        let label: String
    }

    private var emulatorProcess: Process?
    private var emulatorPID: pid_t?
    private let queue = DispatchQueue(label: "apkrunner.work")
    private var currentSerial: String?

    var isReady: Bool { state == .running }

    /// Отметить активность: пока она свежая, помощник не закрывается сам.
    func touch() {
        DispatchQueue.main.async { self.lastActivity = Date() }
    }

    func startIdleWatch() {
        DispatchQueue.main.async {
            self.lastActivity = Date()
            self.idleTimer?.invalidate()
            self.idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.autoQuit, !self.busy, self.state != .booting else { return }
                if Date().timeIntervalSince(self.lastActivity) > 180 {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func setBusy(_ value: Bool) {
        DispatchQueue.main.async { self.busy = value }
    }

    // MARK: lifecycle

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            guard FileManager.default.isExecutableFile(atPath: tool("platform-tools/adb").path) else {
                self.publish(state: .error, message: "Не найден adb. Установи Android SDK.")
                return
            }
            _ = runProcess(tool("platform-tools/adb"), ["start-server"], timeout: 20)
            let serial = self.detectSerial()
            if let serial {
                let boot = runProcess(tool("platform-tools/adb"), ["-s", serial, "shell", "getprop", "sys.boot_completed"], timeout: 15)
                if boot.combined.contains("1") {
                    self.publish(state: .running, message: "Android запущен", soft: true)
                    self.reloadApps()
                    return
                }
                self.publish(state: .booting, message: "Android загружается…", soft: true)
                self.waitForBoot(serial: serial)
                return
            }
            self.publish(state: .stopped, message: "Android выключен", soft: true)
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.detectSerial() != nil {
                self.state = .running
                self.reloadApps()
                return
            }
            let avds = self.availableAVDs()
            guard let avd = avds.first else {
                self.publish(state: .error, message: "Нет созданного виртуального устройства (AVD)")
                return
            }
            self.publish(state: .booting, message: "Запускаю Android…", soft: true)
            let p = Process()
            p.executableURL = tool("emulator/emulator")
            p.arguments = ["-avd", avd, "-netdelay", "none", "-netspeed", "full", "-no-boot-anim"]
            var env = ProcessInfo.processInfo.environment
            env["ANDROID_HOME"] = sdkRoot().path
            env["ANDROID_SDK_ROOT"] = sdkRoot().path
            p.environment = env
            let logURL = URL(fileURLWithPath: "/tmp/apkrunner-emulator.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            if let fh = try? FileHandle(forWritingTo: logURL) { p.standardOutput = fh; p.standardError = fh }
            do { try p.run() } catch {
                self.publish(state: .error, message: "Не удалось запустить эмулятор: \(error.localizedDescription)")
                return
            }
            self.emulatorProcess = p
            self.emulatorPID = p.processIdentifier
            self.waitForBoot(serial: nil)
        }
    }

    func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            if let serial = self.detectSerial() {
                _ = runProcess(tool("platform-tools/adb"), ["-s", serial, "emu", "kill"], timeout: 20)
            }
            self.emulatorProcess?.terminate()
            self.emulatorProcess = nil
            self.currentSerial = nil
            self.publish(state: .stopped, message: "Android выключен", soft: true)
            self.publishApps([])
        }
    }

    private func waitForBoot(serial: String?) {
        let adb = tool("platform-tools/adb")
        _ = runProcess(adb, ["wait-for-device"], timeout: 240)
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            let s = serial ?? detectSerial()
            if let s {
                let boot = runProcess(adb, ["-s", s, "shell", "getprop", "sys.boot_completed"], timeout: 15)
                if boot.combined.contains("1") {
                    _ = runProcess(adb, ["-s", s, "shell", "settings", "put", "global", "window_animation_scale", "0"], timeout: 15)
                    _ = runProcess(adb, ["-s", s, "shell", "settings", "put", "global", "transition_animation_scale", "0"], timeout: 15)
                    _ = runProcess(adb, ["-s", s, "shell", "settings", "put", "global", "animator_duration_scale", "0"], timeout: 15)
                    self.currentSerial = s
                    self.publish(state: .running, message: "Android запущен", soft: true)
                    self.reloadApps()
                    return
                }
            }
            usleep(2_000_000)
        }
        self.publish(state: .error, message: "Android не загрузился за 5 минут. Смотри /tmp/apkrunner-emulator.log")
    }

    private func availableAVDs() -> [String] {
        let r = runProcess(tool("emulator/emulator"), ["-list-avds"], timeout: 30)
        let all = r.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let wanted = ProcessInfo.processInfo.environment["APK_RUNNER_AVD"], all.contains(wanted) {
            return [wanted] + all.filter { $0 != wanted }
        }
        if let tablet = all.first(where: { $0.lowercased().contains("tablet") }) {
            return [tablet] + all.filter { $0 != tablet }
        }
        return all
    }

    private func detectSerial() -> String? {
        let r = runProcess(tool("platform-tools/adb"), ["devices"], timeout: 20)
        for line in r.out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2, parts[0].hasPrefix("emulator-"), parts[1] == "device" {
                return parts[0]
            }
        }
        return nil
    }

    // MARK: apps

    func reloadApps() {
        guard let serial = currentSerial ?? detectSerial() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let r = runProcess(tool("platform-tools/adb"), ["-s", serial, "shell", "pm", "list", "packages", "-3"], timeout: 40)
            var list: [AppInfo] = []
            for line in r.out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("package:") else { continue }
                let pkg = String(t.dropFirst("package:".count))
                let systemPrefixes = ["com.android.", "com.google.android.", "com.qualcomm.", "android."]
                if systemPrefixes.contains(where: { pkg.hasPrefix($0) }) { continue }
                let label = NameStore.saved(for: pkg) ?? prettyName(for: pkg)
                list.append(AppInfo(id: pkg, label: label))
            }
            self.publishApps(list.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })
        }
    }

    func launch(package: String) {
        guard let serial = currentSerial ?? detectSerial() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.publish(message: "Открываю \(prettyName(for: package))…")
            let r = runProcess(tool("platform-tools/adb"),
                               ["-s", serial, "shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1"],
                               timeout: 30)
            if !r.ok { self.publish(message: "Не удалось открыть: \(r.combined.suffix(120))") }
            else { self.publish(message: "Открыто: \(prettyName(for: package))") }
        }
    }

    func uninstall(package: String) {
        guard let serial = currentSerial ?? detectSerial() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            _ = runProcess(tool("platform-tools/adb"), ["-s", serial, "uninstall", package], timeout: 60)
            self.reloadApps()
        }
    }

    func openPlayStore() {
        guard let serial = currentSerial ?? detectSerial() else { return }
        queue.async {
            _ = runProcess(tool("platform-tools/adb"), ["-s", serial, "shell", "am", "start", "-n", "com.android.vending/.AssetBrowserActivity"], timeout: 30)
        }
    }

    // MARK: install

    func install(urls: [URL]) {
        guard !urls.isEmpty else { return }
        lastErrorText = nil
        publish(message: "Готовлю установку…")
        queue.async { [weak self] in
            guard let self else { return }
            if self.detectSerial() == nil {
                self.publish(message: "Сначала запускаю Android…")
                self.startSync()
            }
            guard let serial = self.waitForSerial(timeout: 300) else {
                self.publish(state: .error, message: "Android не запустился — установка отменена")
                return
            }
            self.setBusy(true)
            self.touch()
            defer { self.setBusy(false); self.touch() }
            var failed = false
            for url in urls {
                if !self.installOne(url: url, serial: serial) { failed = true }
            }
            self.reloadApps()
            if failed {
                if let err = self.lastErrorText { self.publish(message: err) }
            } else {
                self.publish(message: "Готово")
            }
        }
    }

    private func startSync() {
        guard detectSerial() == nil else { return }
        let avds = availableAVDs()
        guard let avd = avds.first else { return }
        let p = Process()
        p.executableURL = tool("emulator/emulator")
        p.arguments = ["-avd", avd, "-netdelay", "none", "-netspeed", "full", "-no-boot-anim"]
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_HOME"] = sdkRoot().path
        env["ANDROID_SDK_ROOT"] = sdkRoot().path
        p.environment = env
        let logURL = URL(fileURLWithPath: "/tmp/apkrunner-emulator.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: logURL) { p.standardOutput = fh; p.standardError = fh }
        try? p.run()
        emulatorProcess = p
        emulatorPID = p.processIdentifier
        publish(state: .booting, message: "Запускаю Android…")
    }

    private func waitForSerial(timeout: TimeInterval) -> String? {
        let adb = tool("platform-tools/adb")
        _ = runProcess(adb, ["wait-for-device"], timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = detectSerial() {
                let boot = runProcess(adb, ["-s", s, "shell", "getprop", "sys.boot_completed"], timeout: 15)
                if boot.combined.contains("1") {
                    currentSerial = s
                    publish(state: .running, message: "Android запущен")
                    return s
                }
            }
            usleep(2_000_000)
        }
        return nil
    }

    private func installOne(url: URL, serial: String) -> Bool {
        let ext = url.pathExtension.lowercased()
        publish(message: "Устанавливаю \(url.lastPathComponent)…")
        if ext == "apk" {
            return installPlain(apk: url, serial: serial)
        }
        return installBundle(bundle: url, serial: serial)
    }

    private func installPlain(apk: URL, serial: String) -> Bool {
        let adb = tool("platform-tools/adb")
        let pkgId = packageId(of: apk)
        let before = installedPackages(serial: serial)
        let r = runProcess(adb, ["-s", serial, "install", "-r", "-g", apk.path], timeout: 600)
        guard r.ok else { fail(r); return false }
        var target = pkgId
        if target == nil {
            target = installedPackages(serial: serial).subtracting(before).first
        }
        if let pkg = target { NameStore.save(appLabel(of: apk), for: pkg) }
        finish(target: target, serial: serial)
        return true
    }

    /// XAPK / APKS / APKM: zip с base.apk, config-сплитами и иногда OBB-данными.
    private func installBundle(bundle: URL, serial: String) -> Bool {
        let adb = tool("platform-tools/adb")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apkrunner-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let extract = runProcess(URL(fileURLWithPath: "/usr/bin/unzip"),
                                 ["-o", "-q", bundle.path, "-d", tmp.path], timeout: 600)
        guard extract.ok else { fail(extract); return false }

        let manifest = readXapkManifest(in: tmp)
        var apks: [URL] = (manifest?.split_apks ?? []).compactMap { split -> URL? in
            guard let file = split.file else { return nil }
            let u = tmp.appendingPathComponent(file)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        if apks.isEmpty { apks = allFiles(in: tmp, ext: "apk") }
        guard !apks.isEmpty else {
            let msg = "В файле \(bundle.lastPathComponent) не нашлось APK"
            lastErrorText = msg
            publish(message: msg)
            return false
        }
        apks.sort { a, b in
            let aIsConfig = a.lastPathComponent.lowercased().contains("config.")
            let bIsConfig = b.lastPathComponent.lowercased().contains("config.")
            if aIsConfig != bIsConfig { return !aIsConfig }
            return fileSize(a) > fileSize(b)
        }

        publish(message: "Ставлю \(bundle.lastPathComponent) (\(apks.count) \(apks.count == 1 ? "часть" : "частей"))…")
        let before = installedPackages(serial: serial)
        var r = runProcess(adb, ["-s", serial, "install-multiple", "-r", "-g"] + apks.map { $0.path }, timeout: 1200)
        if !r.ok, apks.count > 1 {
            let base = apks.first { !$0.lastPathComponent.lowercased().contains("config.") } ?? apks[0]
            r = runProcess(adb, ["-s", serial, "install", "-r", "-g", base.path], timeout: 900)
        }
        guard r.ok else { fail(r); return false }

        var target = manifest?.package_name
        if target == nil { target = packageId(of: apks[0]) }
        if target == nil { target = installedPackages(serial: serial).subtracting(before).first }

        if let pkg = target {
            let baseApk = apks.first { !$0.lastPathComponent.lowercased().contains("config.") } ?? apks[0]
            NameStore.save(manifest?.name ?? appLabel(of: baseApk), for: pkg)
            let obbs = allFiles(in: tmp, ext: "obb")
            if !obbs.isEmpty {
                publish(message: "Копирую данные игры/приложения…")
                _ = runProcess(adb, ["-s", serial, "shell", "mkdir", "-p", "/sdcard/Android/obb/\(pkg)"], timeout: 30)
                for obb in obbs {
                    _ = runProcess(adb, ["-s", serial, "push", obb.path,
                                         "/sdcard/Android/obb/\(pkg)/\(obb.lastPathComponent)"], timeout: 600)
                }
            }
        }
        finish(target: target, serial: serial)
        return true
    }

    private func finish(target: String?, serial: String) {
        guard let pkg = target else {
            publish(message: "Установлено, но пакет не определён — открой его в списке ниже")
            return
        }
        publish(message: "Установлено: \(prettyName(for: pkg))")
        let launch = runProcess(tool("platform-tools/adb"),
                                ["-s", serial, "shell", "monkey", "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1"],
                                timeout: 60)
        if launch.ok {
            publish(message: "Запущено: \(prettyName(for: pkg))")
            focusEmulator()
        } else {
            publish(message: "Установлено: \(prettyName(for: pkg)) (запуск не удался)")
        }
    }

    func focusEmulator() {
        let pid = emulatorPID
        DispatchQueue.main.async {
            if let pid, let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [.activateAllWindows])
                return
            }
            // Эмулятор мог быть запущен не нами — ищем окно qemu среди процессов.
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.executableURL?.lastPathComponent.hasPrefix("qemu-system") == true
            }) {
                app.activate(options: [.activateAllWindows])
            }
        }
    }

    private func fail(_ r: CmdResult) {
        let full = r.out + r.err
        lastLog = full
        let reason = full.split(separator: "\n").last.map(String.init) ?? "неизвестная ошибка"
        let msg: String
        if full.contains("INSTALL_FAILED_MISSING_SPLIT") {
            msg = "В файле не хватает сплитов для установленной версии — удали приложение в списке и поставь заново"
        } else if full.contains("INSTALL_FAILED_NO_MATCHING_ABIS") {
            msg = "Приложение собрано под другую архитектуру (не arm64) — на Apple Silicon оно не запустится"
        } else if full.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") || full.contains("INSTALL_FAILED_ALREADY_EXISTS") {
            msg = "Подпись не совпадает с установленной версией — удали старое приложение и поставь это"
        } else if full.contains("INSTALL_PARSE_FAILED_NO_CERTIFICATES") || full.contains("INSTALL_PARSE_FAILED_NOT_APK") {
            msg = "Файл повреждён или это не APK: \(reason)"
        } else if full.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") {
            msg = "На виртуальном устройстве кончилось место — удали лишние приложения"
        } else {
            msg = "Ошибка установки: \(reason)"
        }
        lastErrorText = msg
        publish(message: msg)
    }

    private func readXapkManifest(in dir: URL) -> XapkManifest? {
        let url = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(XapkManifest.self, from: data)
    }

    private func allFiles(in dir: URL, ext: String) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let u as URL in e where u.pathExtension.lowercased() == ext { out.append(u) }
        return out
    }

    private func fileSize(_ url: URL) -> Int {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int { return size }
        return 0
    }

    private func installedPackages(serial: String) -> Set<String> {
        let r = runProcess(tool("platform-tools/adb"), ["-s", serial, "shell", "pm", "list", "packages", "-3"], timeout: 40)
        return Set(r.out.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("package:") else { return nil }
            return String(t.dropFirst("package:".count))
        })
    }

    private func packageId(of apk: URL) -> String? {
        if let a = aapt2() {
            let r = runProcess(a, ["dump", "packagename", apk.path], timeout: 60)
            if let id = firstPackageLine(r.combined) { return id }
        }
        let analyzer = tool("cmdline-tools/latest/bin/apkanalyzer")
        if FileManager.default.isExecutableFile(atPath: analyzer.path) {
            let r = runProcess(analyzer, ["manifest", "application-id", apk.path], timeout: 60)
            if let id = firstPackageLine(r.combined) { return id }
        }
        return nil
    }

    private func firstPackageLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil })
    }

    private func appLabel(of apk: URL) -> String? {
        guard let a = aapt2() else { return nil }
        let r = runProcess(a, ["dump", "badging", apk.path], timeout: 90)
        var fallback: String?
        for line in r.out.split(separator: "\n") {
            guard line.hasPrefix("application-label") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let raw = line[line.index(after: colon)...]
            let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("application-label:") { return name }
            if fallback == nil, !name.isEmpty { fallback = name }
        }
        return fallback
    }

    // MARK: publishing

    private func publish(state: EmuState? = nil, message: String? = nil, soft: Bool = false) {
        DispatchQueue.main.async {
            if let state { self.state = state }
            if let message {
                // Фоновый статус не должен затирать свежий результат действия пользователя.
                if soft && Date().timeIntervalSince(self.messageAt) < 6 { return }
                self.message = message
                self.messageAt = Date()
            }
        }
    }

    private func publishApps(_ list: [AppInfo]) {
        DispatchQueue.main.async { self.apps = list }
    }
}

// MARK: - App entry

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { ["apk", "apks", "xapk", "apkm"].contains($0.pathExtension.lowercased()) }
        guard !files.isEmpty else { return }
        AndroidController.shared.touch()
        AndroidController.shared.install(urls: files)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Живём только в строке меню: ни Dock-иконки, ни окон помощника.
        NSApp.setActivationPolicy(.accessory)

        // Сами назначаем себя обработчиком .apk/.xapk: архиваторы вроде Keka
        // любят перехватывать этот тип.
        if let id = Bundle.main.bundleIdentifier {
            LSSetDefaultRoleHandlerForContentType("public.archive.apk" as CFString, .all, id as CFString)
        }
        AndroidController.shared.startIdleWatch()
        AndroidController.shared.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

// MARK: - Menu bar

struct MenuView: View {
    @ObservedObject var ctl = AndroidController.shared

    var body: some View {
        Text(ctl.message)

        Divider()

        Button("Play Маркет") { ctl.touch(); ctl.openPlayStore() }
            .disabled(!ctl.isReady)

        Button("Открыть APK…") { pickFile() }

        Button("Показать Android") { ctl.touch(); ctl.focusEmulator() }
            .disabled(ctl.state != .running)

        Divider()

        if ctl.isReady {
            Button("Выключить Android") { ctl.touch(); ctl.shutdown() }
        } else if ctl.state == .booting {
            Text("Android загружается…")
        } else {
            Button("Запустить Android") { ctl.touch(); ctl.start() }
        }

        Divider()

        Toggle("Закрывать автоматически", isOn: $ctl.autoQuit)
        Button("Лог эмулятора") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/apkrunner-emulator.log"))
        }
        Button("Выход") { NSApp.terminate(nil) }
    }

    private func pickFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["apk", "apks", "xapk", "apkm"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Выбери APK-файл"
        guard panel.runModal() == .OK else { return }
        ctl.touch()
        ctl.install(urls: panel.urls)
    }
}

@main
struct APKRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var ctl = AndroidController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
        } label: {
            Image(systemName: "ipad")
        }
        .menuBarExtraStyle(.menu)
    }
}
