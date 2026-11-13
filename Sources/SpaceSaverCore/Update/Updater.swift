import CryptoKit
import Darwin
import Foundation

// In-app updates without third-party frameworks.
//
// A release is a GitHub release with two assets: SpaceSaver.dmg and SpaceSaver.dmg.sig. The
// .sig file is an Ed25519 signature over the DMG's SHA-256, made with a private key that never
// leaves the maintainer's Mac. The app ships the matching public key in its Info.plist
// (SSUpdatePublicKey) and refuses any download whose signature doesn't verify, so a compromised
// GitHub account or download host can't push a malicious update.

public struct UpdateRelease: Codable, Equatable, Sendable {
    public var version: String
    public var tag: String
    public var title: String
    public var notes: String
    public var publishedAt: Date?
    public var dmgURL: URL
    public var signatureURL: URL
    public var size: Int64
    public var pageURL: URL?

    public init(version: String, tag: String, title: String, notes: String, publishedAt: Date?,
                dmgURL: URL, signatureURL: URL, size: Int64, pageURL: URL?) {
        self.version = version
        self.tag = tag
        self.title = title
        self.notes = notes
        self.publishedAt = publishedAt
        self.dmgURL = dmgURL
        self.signatureURL = signatureURL
        self.size = size
        self.pageURL = pageURL
    }

    /// First paragraph of the release notes, without markdown emphasis, for banners.
    public var summary: String {
        let firstBlock = notes.components(separatedBy: "\n\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return firstBlock.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case noPublicKey
    case badFeed(String)
    case missingAsset(String)
    case download(String)
    case badSignature
    case mount(String)
    case invalidBundle(String)
    case codeSignature(String)
    case translocated
    case notWritable(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noPublicKey: return "This build has no update key, so it can't verify updates."
        case .badFeed(let s): return "Couldn't read the release information: \(s)"
        case .missingAsset(let s): return "The release is missing \(s)."
        case .download(let s): return "Download failed: \(s)"
        case .badSignature: return "The download's signature didn't match, so it wasn't installed."
        case .mount(let s): return "Couldn't open the disk image: \(s)"
        case .invalidBundle(let s): return "The downloaded app looks wrong: \(s)"
        case .codeSignature(let s): return "The downloaded app's code signature is invalid: \(s)"
        case .translocated: return "Move SpaceSaver to your Applications folder first, then update."
        case .notWritable(let p): return "SpaceSaver can't replace itself at \(p). Download the new version from the website instead."
        case .installFailed(let s): return "Installing the update failed: \(s)"
        }
    }
}

// MARK: - Signing

public enum UpdateSigner {
    public static func digest(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }

    public static func generateKeyPair() -> (privateKey: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
    }

    public static func publicKey(forPrivateKey privateKey: String) throws -> String {
        guard let raw = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UpdateError.badSignature
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw).publicKey.rawRepresentation.base64EncodedString()
    }

    public static func sign(file: URL, privateKey: String) throws -> String {
        guard let raw = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UpdateError.badSignature
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        return try key.signature(for: digest(of: file)).base64EncodedString()
    }

    public static func verify(file: URL, signature: String, publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              let sigData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let digest = try? digest(of: file) else { return false }
        return key.isValidSignature(sigData, for: digest)
    }
}

// MARK: - Checking

public struct UpdateConfig: Sendable, Equatable {
    public static let defaultFeed = URL(string: "https://api.github.com/repos/rushabh05/SpaceSaver/releases/latest")!

    public var feedURL: URL
    public var publicKey: String?
    public var dmgName = "SpaceSaver.dmg"

    public init(feedURL: URL = UpdateConfig.defaultFeed, publicKey: String?) {
        self.feedURL = feedURL
        self.publicKey = publicKey
    }

    /// Reads SSUpdateFeedURL and SSUpdatePublicKey from the app's Info.plist.
    /// SPACESAVER_UPDATE_FEED overrides the feed (used by tests and for staging).
    public static func forInstalledApp(_ app: InstalledApp?,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) -> UpdateConfig {
        let feed = environment["SPACESAVER_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? app?.info["SSUpdateFeedURL"].flatMap(URL.init(string:))
            ?? defaultFeed
        let key = app?.info["SSUpdatePublicKey"].flatMap { $0.isEmpty ? nil : $0 }
        return UpdateConfig(feedURL: feed, publicKey: key)
    }
}

public enum UpdateChecker {
    /// Parses a GitHub "release" object (the /releases/latest response).
    public static func parseGitHubRelease(_ data: Data, dmgName: String = "SpaceSaver.dmg") throws -> UpdateRelease {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let size: Int64 }
        struct Release: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: URL?
            let published_at: String?
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let release: Release
        do { release = try JSONDecoder().decode(Release.self, from: data) } catch {
            throw UpdateError.badFeed(error.localizedDescription)
        }
        guard let version = SemanticVersion(release.tag_name) else { throw UpdateError.badFeed("unrecognised tag \(release.tag_name)") }
        guard let dmg = release.assets.first(where: { $0.name == dmgName }) else { throw UpdateError.missingAsset(dmgName) }
        guard let sig = release.assets.first(where: { $0.name == dmgName + ".sig" }) else {
            throw UpdateError.missingAsset(dmgName + ".sig")
        }
        let date = release.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        return UpdateRelease(version: version.description, tag: release.tag_name, title: release.name ?? release.tag_name,
                             notes: release.body ?? "", publishedAt: date, dmgURL: dmg.browser_download_url,
                             signatureURL: sig.browser_download_url, size: dmg.size, pageURL: release.html_url)
    }

    public static func fetchLatest(_ config: UpdateConfig) async throws -> UpdateRelease {
        var request = URLRequest(url: config.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SpaceSaver/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.badFeed(http.statusCode == 404 ? "no published release" : "HTTP \(http.statusCode)")
        }
        return try parseGitHubRelease(data, dmgName: config.dmgName)
    }

    /// The latest release if it's newer than `current`, otherwise nil.
    public static func check(current: String, config: UpdateConfig) async throws -> UpdateRelease? {
        let latest = try await fetchLatest(config)
        guard let new = SemanticVersion(latest.version), let old = SemanticVersion(current) else { return nil }
        return new > old ? latest : nil
    }
}

// MARK: - Installing

/// Downloads, verifies, stages and installs an update. Every step is checked before the running
/// app is touched, and the old bundle is restored if copying the new one fails.
public struct UpdateInstaller: Sendable {
    public var publicKey: String
    public var expectedBundleID: String
    public var workDir: URL

    public init(publicKey: String, expectedBundleID: String = "com.spacesaver.app", workDir: URL? = nil) {
        self.publicKey = publicKey
        self.expectedBundleID = expectedBundleID
        self.workDir = workDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceSaverUpdate-\(UUID().uuidString.prefix(8))")
    }

    /// Downloads the DMG and its signature and verifies them. Returns the local DMG.
    public func download(_ release: UpdateRelease) async throws -> URL {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let dmg = workDir.appendingPathComponent("SpaceSaver.dmg")
        let sig = try await fetch(release.signatureURL)
        let signature = String(decoding: sig, as: UTF8.self)
        try? FileManager.default.removeItem(at: dmg)
        do {
            let (tmp, response) = try await URLSession.shared.download(from: release.dmgURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.download("HTTP \(http.statusCode)")
            }
            try FileManager.default.moveItem(at: tmp, to: dmg)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
        guard UpdateSigner.verify(file: dmg, signature: signature, publicKey: publicKey) else {
            try? FileManager.default.removeItem(at: dmg)
            throw UpdateError.badSignature
        }
        return dmg
    }

    private func fetch(_ url: URL) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.download("HTTP \(http.statusCode) for \(url.lastPathComponent)")
            }
            return data
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
    }

    /// Mounts the verified DMG read-only, copies the app out, and checks its identity, version
    /// and code signature. Returns the staged .app.
    public func stage(dmg: URL, expectedVersion: String) throws -> URL {
        let mount = workDir.appendingPathComponent("mount")
        let staged = workDir.appendingPathComponent("staged/SpaceSaver.app")
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)

        let attach = Shell.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                                    "-mountpoint", mount.path], timeout: 120)
        guard attach.ok else { throw UpdateError.mount(attach.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        defer { Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60) }

        let source = mount.appendingPathComponent("SpaceSaver.app")
        guard FileManager.default.fileExists(atPath: source.path) else { throw UpdateError.invalidBundle("no SpaceSaver.app in the disk image") }
        let copy = Shell.run("/usr/bin/ditto", [source.path, staged.path], timeout: 300)
        guard copy.ok else { throw UpdateError.invalidBundle("couldn't copy the app: \(copy.stderr)") }

        guard let app = InstalledApp(bundleURL: staged) else { throw UpdateError.invalidBundle("unreadable Info.plist") }
        guard app.bundleID == expectedBundleID else { throw UpdateError.invalidBundle("bundle ID \(app.bundleID)") }
        guard let have = SemanticVersion(app.version), let want = SemanticVersion(expectedVersion), have == want else {
            throw UpdateError.invalidBundle("version \(app.version), expected \(expectedVersion)")
        }
        let codesign = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path], timeout: 120)
        guard codesign.ok else { throw UpdateError.codeSignature(codesign.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return staged
    }

    /// Checks that `target` can be replaced in place.
    public func preflight(target: InstalledApp) throws {
        if target.isTranslocated { throw UpdateError.translocated }
        let fm = FileManager.default
        let parent = target.url.deletingLastPathComponent().path
        guard fm.isWritableFile(atPath: parent), fm.isWritableFile(atPath: target.url.path) else {
            throw UpdateError.notWritable(Paths.abbreviate(target.url.path))
        }
    }

    /// Swaps `staged` into `target`'s place. The old bundle is kept in the work folder and put
    /// back if the copy fails.
    ///
    /// - waitForPID: wait for this process (the running app) to quit first. The swap then runs
    ///   in its own session so it survives the app quitting, and this returns immediately.
    /// - relaunch: open the app again afterwards.
    public func install(staged: URL, over target: InstalledApp, waitForPID: pid_t?, relaunch: Bool) throws {
        try preflight(target: target)
        let targetPath = target.url.path
        guard targetPath.hasSuffix(".app"), targetPath.count > 5 else { throw UpdateError.installFailed("unexpected target \(targetPath)") }
        let backup = workDir.appendingPathComponent("previous-\(target.version).app").path
        try? FileManager.default.removeItem(atPath: backup)

        let script = """
        set -u
        if [ -n "$SS_PID" ]; then
          i=0
          while kill -0 "$SS_PID" 2>/dev/null; do sleep 0.2; i=$((i+1)); [ $i -gt 600 ] && exit 3; done
        fi
        mv "$SS_TARGET" "$SS_BACKUP" || exit 4
        if /usr/bin/ditto "$SS_STAGED" "$SS_TARGET"; then
          [ "$SS_RELAUNCH" = "1" ] && /usr/bin/open "$SS_TARGET"
          exit 0
        fi
        rm -rf "$SS_TARGET"
        mv "$SS_BACKUP" "$SS_TARGET"
        [ "$SS_RELAUNCH" = "1" ] && /usr/bin/open "$SS_TARGET"
        exit 5
        """
        var env = ProcessInfo.processInfo.environment
        env["SS_PID"] = waitForPID.map { String($0) } ?? ""
        env["SS_TARGET"] = targetPath
        env["SS_BACKUP"] = backup
        env["SS_STAGED"] = staged.path
        env["SS_RELAUNCH"] = relaunch ? "1" : "0"

        if waitForPID != nil {
            try spawnDetached("/bin/sh", ["-c", script], environment: env)
        } else {
            let result = Shell.run("/bin/sh", ["-c", script], timeout: 600, environment: env)
            guard result.ok else {
                throw UpdateError.installFailed("swap exited with status \(result.status) \(result.stderr)")
            }
        }
    }

    /// Starts a process in a new session so it outlives this one (launchd ends an app's
    /// process group when the app quits).
    private func spawnDetached(_ path: String, _ args: [String], environment: [String: String]) throws {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, nil, &attr, argv, envp)
        guard rc == 0 else { throw UpdateError.installFailed("couldn't start the installer (\(rc))") }
    }
}
