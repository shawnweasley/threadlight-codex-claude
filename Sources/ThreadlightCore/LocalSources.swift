import Foundation
import CryptoKit
import SQLite3
import Darwin

public struct MonitorPaths {
    public let codex: URL
    public let claude: URL
    public let desktop: URL
    public let storage: URL
    public init(codex: URL, claude: URL, desktop: URL, storage: URL) {
        self.codex = codex; self.claude = claude; self.desktop = desktop; self.storage = storage
    }
    public static var local: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        return Self(codex: env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex"),
                    claude: env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude"),
                    desktop: home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions"),
                    storage: home.appendingPathComponent("Library/Application Support/Threadlight"))
    }
}

/// Small metadata objects are cached by inode, size, and modification date.
final class MetadataFiles {
    private struct Signature: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date
        init?(_ attributes: [FileAttributeKey: Any]) {
            guard let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else { return nil }
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            self.size = size.uint64Value; self.modified = modified
        }
    }
    private struct Cached { let signature: Signature; let value: [String: Any] }
    private var cached: [String: Cached] = [:]
    private(set) var bytes = 0
    func begin() { bytes = 0 }
    func json(_ url: URL, limit: Int = 1_048_576) -> [String: Any]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= limit else { return nil }
        guard let signature = Signature(attrs) else { return nil }
        if let old = cached[url.path], old.signature == signature { return old.value }
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: limit), data.count <= limit else { return nil }
        bytes += data.count
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        cached[url.path] = Cached(signature: signature, value: value)
        return value
    }

    func prefixNumber(_ field: String, at url: URL, limit: Int) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        guard let signature = Signature(attrs) else { return nil }
        let key = url.path + ":prefix:" + field
        if let old = cached[key], old.signature == signature { return old.value[field] as? Double }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        bytes += data.count
        let text = String(decoding: data, as: UTF8.self)
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: field) + #""\s*:\s*(\d+(?:\.\d+)?)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let value = Double(text[range]) else { return nil }
        cached[key] = Cached(signature: signature, value: [field: value])
        return value
    }
}

struct ThreadRow {
    var id: String
    var name: String
    var path: String
    var archived: Bool
}

enum ThreadDatabase {
    static func locate(in directory: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }.first.map { directory.appendingPathComponent($0) }
    }

    static func rows(at location: URL, watched: Set<String>) throws -> [ThreadRow] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(location.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; throw SourceError.database
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 75)
        var columns = Set<String>()
        var pragma: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &pragma, nil) == SQLITE_OK {
            while sqlite3_step(pragma) == SQLITE_ROW {
                if let text = sqlite3_column_text(pragma, 1) { columns.insert(String(cString: text)) }
            }
        }
        sqlite3_finalize(pragma)
        guard columns.isSuperset(of: ["id", "rollout_path", "title", "updated_at", "archived", "originator"]) else { throw SourceError.schema }
        let name = columns.contains("name") ? "COALESCE(NULLIF(name,''),title)" : "title"
        // An agent-created chat is an independent desktop conversation, unlike
        // an internal subagent. Filter before LIMIT so children cannot crowd out chats.
        let sourceFilter = columns.contains("thread_source") ? " AND (thread_source IN ('user','agent_created_thread') OR thread_source IS NULL)" : ""
        let ids = Array(watched).sorted()
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let tracked = ids.isEmpty ? "" : " OR id IN (\(placeholders))"
        let query = """
        SELECT id, \(name), rollout_path, archived FROM threads
        WHERE (id IN (SELECT id FROM threads WHERE archived=0 AND originator='Codex Desktop'\(sourceFilter) ORDER BY updated_at DESC LIMIT 32)\(tracked))
          AND originator='Codex Desktop'\(sourceFilter)
        ORDER BY id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw SourceError.database }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, id) in ids.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), id, -1, transient) }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        var result: [ThreadRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            result.append(ThreadRow(id: text(0), name: text(1), path: text(2), archived: sqlite3_column_int(statement, 3) != 0))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw SourceError.database }
        return result
    }
}

enum SourceError: Error { case database, schema }

final class DesktopReadMarks {
    private let files: MetadataFiles
    private let home: URL
    private var configDate: Date?
    private var storageIdentity = false
    init(home: URL, files: MetadataFiles) { self.home = home; self.files = files }

    func unreadIDs() -> Set<String>? {
        guard let state = files.json(home.appendingPathComponent(".codex-global-state.json"), limit: 8_388_608) else { return nil }
        if let modern = state["electron-thread-read-state-v1"] as? [String: Any] {
            guard let all = modern["unreadByIdentity"] as? [String: Any], let identity = identityKey(),
                  let hosts = all[identity] as? [String: Any] else { return nil }
            return localIDs(hosts)
        }
        if let atoms = state["electron-persisted-atom-state"] as? [String: Any],
           let hosts = atoms["unread-thread-ids-by-host-v1"] as? [String: Any] { return localIDs(hosts) }
        return nil
    }

    private func localIDs(_ hosts: [String: Any]) -> Set<String> {
        Set(hosts.filter { $0.key == "local" || $0.key.hasPrefix("local:") }.flatMap { $0.value as? [String] ?? [] })
    }

    private func identityKey() -> String? {
        let config = home.appendingPathComponent("config.toml")
        let modified = (try? config.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if modified != configDate {
            configDate = modified; storageIdentity = false
            // Only recognize an explicit provider declaration, never execute TOML.
            if let size = (try? config.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 262_144,
               let text = try? String(contentsOf: config, encoding: .utf8) {
                var provider: String?, section = ""
                for line in text.components(separatedBy: .newlines) {
                    let line = line.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("[") { section = line }
                    if section.isEmpty, line.hasPrefix("model_provider"),
                       let value = line.split(separator: "=", maxSplits: 1).last { provider = value.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
                    if let provider, section == "[model_providers.\(provider)]", line.hasPrefix("requires_openai_auth"),
                       let value = line.split(separator: "=", maxSplits: 1).last {
                        storageIdentity = value.split(separator: "#").first?.trimmingCharacters(in: .whitespaces) == "false"
                    }
                }
            }
        }
        var parts: [String]
        if storageIdentity { parts = ["execution-storage", "none"] }
        else {
            guard let auth = files.json(home.appendingPathComponent("auth.json")) else { return nil }
            let mode = auth["auth_mode"] as? String ?? (auth["OPENAI_API_KEY"] == nil ? "none" : "apikey")
            if mode == "chatgpt" || mode == "chatgptAuthTokens" {
                guard let tokens = auth["tokens"] as? [String: Any] else { return nil }
                var accountParts: [String]?
                for key in ["id_token", "access_token"] {
                    guard let token = tokens[key] as? String else { continue }
                    let segments = token.split(separator: ".")
                    guard segments.count >= 2 else { continue }
                    var base64 = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
                    guard let data = Data(base64Encoded: base64),
                          let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let info = claims["https://api.openai.com/auth"] as? [String: Any],
                          let account = info["chatgpt_account_id"] as? String, let user = info["chatgpt_user_id"] as? String else { continue }
                    accountParts = ["chatgpt", account, user]; break
                }
                guard let found = accountParts else { return nil }; parts = found
            } else { parts = ["execution-storage", mode] }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: parts, options: .withoutEscapingSlashes) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PollReport: Sendable {
    public var readings: [Reading]
    public var notices: [String]
    public var logBytes: Int
    public var metadataBytes: Int
    public var cacheHits: Int
    public var milliseconds: Int
}

/// One serial owner; this object performs no network or UI operations.
public final class LocalMonitor {
    private let paths: MonitorPaths
    private let files = MetadataFiles()
    private let tails: TailStore
    private lazy var readMarks = DesktopReadMarks(home: paths.codex, files: files)
    private var claudeKnown: [ChatID: Reading] = [:]
    private var claudeProcesses: [ChatID: Set<Int32>] = [:]
    private let processIsAlive: (Int32) -> Bool
    private var focusLocations: [String: URL] = [:]
    private var focusIndexTime = Date.distantPast
    public init(paths: MonitorPaths = .local, persistentCache: Bool = true,
                processIsAlive: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        self.paths = paths
        self.processIsAlive = processIsAlive
        tails = TailStore(cache: persistentCache ? paths.storage.appendingPathComponent("tails-v1.json") : nil)
    }

    public func poll(watched: Set<ChatID> = []) -> PollReport {
        let start = Date(); tails.begin(); files.begin()
        var readings: [Reading] = [], notices: [String] = []
        if let db = ThreadDatabase.locate(in: paths.codex) {
            do {
                let ids = Set(watched.filter { $0.client == .codex }.map(\.rawValue))
                let unread = readMarks.unreadIDs()
                for row in try ThreadDatabase.rows(at: db, watched: ids) {
                    let stamp = row.archived ? nil : tails.read(row.path)
                    readings.append(Reading(id: ChatID(.codex, row.id), title: displayTitle(row.name, fallback: "Codex 对话"),
                                            phase: stamp?.phase, eventTime: stamp?.time, unread: unread.map { $0.contains(row.id) }, archived: row.archived))
                }
            } catch SourceError.schema { notices.append("Codex 本地状态格式暂不兼容") }
              catch { notices.append("Codex 状态暂时不可读，保留上次结果") }
        } else { notices.append("未发现 Codex 本地状态库") }
        readings += claudeReadings(watched: watched, now: start)
        tails.flush()
        return PollReport(readings: readings, notices: notices, logBytes: tails.bytesRead, metadataBytes: files.bytes,
                          cacheHits: tails.hits, milliseconds: Int(Date().timeIntervalSince(start) * 1000))
    }

    private func claudeReadings(watched: Set<ChatID>, now: Date) -> [Reading] {
        let folder = paths.claude.appendingPathComponent("sessions")
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var current: [ChatID: Reading] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let object = files.json(url, limit: 4096), object["entrypoint"] as? String == "claude-desktop",
                  object["kind"] as? String == "interactive", let host = object["hostSessionId"] as? String,
                  let pid = object["pid"] as? Int, pid > 0, pid <= Int32.max,
                  let status = object["status"] as? String else { continue }
            let id = ChatID(.claude, host)
            let alive = processIsAlive(Int32(pid))
            guard alive || watched.contains(id) || claudeKnown[id] != nil else { continue }
            guard ["busy", "idle", "waiting", "waiting_for_permission", "waiting_for_input"].contains(status) else { continue }
            claudeProcesses[id, default: []].insert(Int32(pid))
            let phase: Phase = alive && status != "idle" ? .working : .finished
            let stamp = (object["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            let title = displayTitle(object["name"] as? String ?? "", fallback: "Claude Code 对话")
            let next = Reading(id: id, title: title, phase: phase, eventTime: stamp)
            if let old = current[id], (old.eventTime ?? .distantPast) > (stamp ?? .distantPast) { continue }
            current[id] = next
        }
        for id in watched where id.client == .claude && current[id] == nil {
            // Missing or partially written state is not evidence of completion.
            // Only a confirmed exit of all observed processes closes this task.
            if var old = claudeKnown[id] {
                let hasLiveProcess = claudeProcesses[id]?.contains(where: processIsAlive) ?? true
                if !hasLiveProcess && old.phase != .finished { old.phase = .finished; old.eventTime = now }
                current[id] = old
            }
        }
        for (id, var value) in current {
            if value.phase == .finished, watched.contains(id), let finished = value.eventTime,
               let focus = lastFocus(id.rawValue, now: now) { value.unread = focus <= finished }
            current[id] = value
        }
        claudeKnown.merge(current) { _, newer in newer }
        return Array(current.values)
    }

    private func lastFocus(_ host: String, now: Date) -> Date? {
        // Directory-only lookup, at most once per 30 s, only when a finished task
        // needs acknowledgement. Never walk project transcripts or debug logs.
        if focusLocations[host] == nil, now.timeIntervalSince(focusIndexTime) > 30 {
            focusIndexTime = now
            let manager = FileManager.default
            for account in (try? manager.contentsOfDirectory(at: paths.desktop, includingPropertiesForKeys: nil)) ?? [] {
                for project in (try? manager.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                    for item in (try? manager.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? [] where item.pathExtension == "json" {
                        focusLocations[item.deletingPathExtension().lastPathComponent] = item
                    }
                }
            }
        }
        guard let path = focusLocations[host], let ms = files.prefixNumber("lastFocusedAt", at: path, limit: 8192) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private func displayTitle(_ text: String, fallback: String) -> String {
        let compact = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return compact.isEmpty ? fallback : String(compact.prefix(180))
    }
}
