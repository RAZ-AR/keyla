import Cocoa
import CryptoKit
import Security

/// Checks GitHub Releases for a newer Keyla and installs it in place.
/// Safety: the DMG must match the SHA-256 published in the release notes, and the new app
/// must satisfy the running app's designated requirement (same bundle id + same signing certificate).
final class Updater {
    static let shared = Updater()
    static let repo = "RAZ-AR/keyla"

    struct Release { let version: String; let dmgURL: URL; let sha256: String?; let page: URL }

    enum State: Equatable { case idle, checking, downloading, installing, failed(String) }

    private(set) var available: Release?
    private(set) var state: State = .idle { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Check now and then every 12 hours (if automatic checks are on).
    func startAutomaticChecks() {
        guard Settings.d.bool(forKey: "autoUpdateCheck") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { [weak self] _ in self?.check(manual: false) }
    }

    func check(manual: Bool) {
        guard state != .checking, state != .downloading, state != .installing else { return }
        state = .checking
        Task { @MainActor in
            do {
                let rel = try await fetchLatest()
                if Self.isNewer(rel.version, than: Self.currentVersion) {
                    available = rel
                    state = .idle
                    HUD.shared.show("Доступна Keyla \(rel.version)", "Откройте меню Keyla, чтобы обновить", duration: 4, force: manual)
                } else {
                    available = nil
                    state = .idle
                    if manual { HUD.shared.show("У вас последняя версия", "Keyla \(Self.currentVersion)", force: true) }
                }
            } catch {
                state = manual ? .failed(error.localizedDescription) : .idle
                if manual { HUD.shared.show("Не удалось проверить обновления", error.localizedDescription, duration: 4, force: true) }
            }
        }
    }

    func install() {
        guard let rel = available, state != .downloading, state != .installing else { return }
        state = .downloading
        HUD.shared.show("Скачиваю Keyla \(rel.version)…", nil, duration: nil, force: true)
        Task { @MainActor in
            do {
                let (tmp, _) = try await URLSession.shared.download(from: rel.dmgURL)
                let data = try Data(contentsOf: tmp)
                if let expected = rel.sha256 {
                    let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard got == expected.lowercased() else { throw UpdateError("Контрольная сумма не совпала — файл повреждён или подменён") }
                }
                state = .installing
                HUD.shared.show("Устанавливаю Keyla \(rel.version)…", nil, duration: nil, force: true)
                try await Task.detached { try Self.installDMG(at: tmp, into: Bundle.main.bundleURL) }.value
                HUD.shared.show("Keyla обновлена", "Перезапускаю…", force: true)
                Self.relaunch()
            } catch {
                state = .failed(error.localizedDescription)
                HUD.shared.show("Обновление не удалось", error.localizedDescription, duration: 5, force: true)
            }
        }
    }

    // MARK: - Steps

    func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        req.setValue("Keyla-Updater", forHTTPHeaderField: "user-agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let urlStr = dmg["browser_download_url"] as? String, let url = URL(string: urlStr) else {
            throw UpdateError("GitHub вернул неожиданный ответ")
        }
        let body = json["body"] as? String ?? ""
        // Prefer GitHub's own asset digest; fall back to the SHA-256 printed in the release notes.
        var sha = (dmg["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        if sha == nil, let r = body.range(of: #"[0-9a-f]{64}"#, options: .regularExpression) { sha = String(body[r]) }
        let page = URL(string: json["html_url"] as? String ?? "https://github.com/\(Self.repo)/releases")!
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), dmgURL: url, sha256: sha, page: page)
    }

    static func installDMG(at dmg: URL, into target: URL) throws {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("keyla-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let newApp = mount.appendingPathComponent("Keyla.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdateError("В образе нет Keyla.app") }
        try verifySameSigner(newApp)

        let staged = target.deletingLastPathComponent().appendingPathComponent(".Keyla-update.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
    }

    /// The new build must satisfy the running app's designated requirement (same id + same certificate).
    private static func verifySameSigner(_ app: URL) throws {
        var selfCode: SecCode?
        var req: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyDesignatedRequirement(selfCode as! SecStaticCode, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError("Не удалось проверить подпись")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        if SecStaticCodeCheckValidity(newCode, flags, req) == errSecSuccess { return }
        // Moving to an Apple Developer ID: this build may name the team it trusts for the next signer.
        if let team = Bundle.main.object(forInfoDictionaryKey: "KeylaTrustedTeamID") as? String,
           team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil {
            var devReq: SecRequirement?
            let text = "anchor apple generic and identifier \"app.keyla.Keyla\" and certificate leaf[subject.OU] = \"\(team)\""
            if SecRequirementCreateWithString(text as CFString, [], &devReq) == errSecSuccess, let devReq,
               SecStaticCodeCheckValidity(newCode, flags, devReq) == errSecSuccess { return }
        }
        throw UpdateError("Подпись новой версии не совпадает с установленной — обновление отменено")
    }

    /// `Keyla --update-dry-run`: full pipeline against the real latest release, installed into a temp copy.
    static func dryRun() async -> Int32 {
        do {
            let rel = try await shared.fetchLatest()
            print("Последний релиз:", rel.version, "| SHA-256 из релиза:", rel.sha256 ?? "нет")
            let (tmp, _) = try await URLSession.shared.download(from: rel.dmgURL)
            let got = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
            print("Контрольная сумма:", got == rel.sha256?.lowercased() ? "совпадает" : "НЕ совпадает (\(got))")
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keyla-dryrun-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("Keyla.app")
            try run("/usr/bin/ditto", [Bundle.main.bundlePath, target.path])
            try installDMG(at: tmp, into: target)
            let v = (NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "?"
            print("Подпись проверена, копия заменена → версия во временной копии:", v)
            try? FileManager.default.removeItem(at: dir)
            return 0
        } catch {
            print("Ошибка:", error.localizedDescription)
            return 1
        }
    }

    private static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw UpdateError("\((exe as NSString).lastPathComponent): \(text.prefix(200))") }
        return text
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
