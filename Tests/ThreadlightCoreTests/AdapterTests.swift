import Foundation
import SQLite3
import CryptoKit
import Darwin
import Testing
@testable import ThreadlightCore

@Suite struct AdapterTests {
    @Test func equalSizeMetadataChangesWithinOneSecondInvalidateBothCaches() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let path = scratch.file("same-size.json"), files = MetadataFiles()
        let second = Date(timeIntervalSince1970: 1_800_000_000)
        try Data("{\"status\":\"busy\",\"lastFocusedAt\":1000}".utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: second.addingTimeInterval(0.1)], ofItemAtPath: path.path)
        #expect(files.json(path)?["status"] as? String == "busy")
        #expect(files.prefixNumber("lastFocusedAt", at: path, limit: 8192) == 1000)
        let oldInode = try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber
        try Data("{\"status\":\"idle\",\"lastFocusedAt\":2000}".utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: second.addingTimeInterval(0.8)], ofItemAtPath: path.path)
        #expect(try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber == oldInode)
        #expect(files.json(path)?["status"] as? String == "idle")
        #expect(files.prefixNumber("lastFocusedAt", at: path, limit: 8192) == 2000)
        files.begin(); _ = files.json(path); _ = files.prefixNumber("lastFocusedAt", at: path, limit: 8192)
        #expect(files.bytes == 0)
    }

    @Test func missingOrPartialClaudeMetadataPreservesWorkingUntilProcessExit() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let dir = scratch.file("sessions"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("one.json")
        let state: [String: Any] = ["pid": 1234, "entrypoint": "claude-desktop", "kind": "interactive", "hostSessionId": "local_sample", "status": "busy"]
        try JSONSerialization.data(withJSONObject: state).write(to: file)
        let paths = MonitorPaths(codex: scratch.file("none"), claude: scratch.url, desktop: scratch.file("none"), storage: scratch.file("cache"))
        var alive = true
        let monitor = LocalMonitor(paths: paths, persistentCache: false, processIsAlive: { _ in alive })
        let id = ChatID(.claude, "local_sample")
        #expect(monitor.poll().readings.first?.phase == .working)
        try Data("{\"pid\":".utf8).write(to: file)
        #expect(monitor.poll(watched: [id]).readings.first?.phase == .working)
        try FileManager.default.removeItem(at: file)
        #expect(monitor.poll(watched: [id]).readings.first?.phase == .working)
        alive = false
        let ended = monitor.poll(watched: [id])
        #expect(ended.readings.first?.phase == .finished)
        #expect(monitor.poll(watched: [id]).readings.first?.eventTime == ended.readings.first?.eventTime)
    }

    @Test func invalidProcessIdentifiersAreIgnoredWithoutSignallingProcessGroups() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let dir = scratch.file("sessions"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, pid) in [0, -1, Int.max].enumerated() {
            let state: [String: Any] = ["pid": pid, "entrypoint": "claude-desktop", "kind": "interactive", "hostSessionId": "bad\(index)", "status": "busy"]
            try JSONSerialization.data(withJSONObject: state).write(to: dir.appendingPathComponent("\(index).json"))
        }
        var calls = 0
        let paths = MonitorPaths(codex: scratch.file("none"), claude: scratch.url, desktop: scratch.file("none"), storage: scratch.file("cache"))
        let monitor = LocalMonitor(paths: paths, persistentCache: false, processIsAlive: { _ in calls += 1; return true })
        #expect(monitor.poll().readings.isEmpty)
        #expect(calls == 0)
    }

    @Test func databaseSelectsDesktopTopLevelMetadataOnlyAndTracksArchivedRows() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let path = scratch.file("state_5.sqlite")
        var db: OpaquePointer?; #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE threads(id TEXT, title TEXT, name TEXT, rollout_path TEXT, originator TEXT, thread_source TEXT, archived INTEGER, updated_at INTEGER);
        INSERT INTO threads VALUES('a','fallback','显示名称','/synthetic/a','Codex Desktop','user',0,1);
        INSERT INTO threads VALUES('b','hidden',NULL,'/synthetic/b','Codex CLI','user',0,2);
        INSERT INTO threads VALUES('c','child',NULL,'/synthetic/c','Codex Desktop','subagent',0,3);
        INSERT INTO threads VALUES('d','archive',NULL,'/synthetic/d','Codex Desktop','user',1,4);
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let ordinary = try ThreadDatabase.rows(at: path, watched: [])
        #expect(ordinary.map(\.id) == ["a"])
        #expect(ordinary.first?.name == "显示名称")
        let tracked = try ThreadDatabase.rows(at: path, watched: ["d"])
        #expect(tracked.map(\.id) == ["a", "d"])
        #expect(tracked.last?.archived == true)
        #expect(sqlite3_exec(db, "INSERT INTO threads SELECT 'new',title,name,rollout_path,originator,thread_source,0,20 FROM threads WHERE id='a'", nil, nil, nil) == SQLITE_OK)
        #expect(try ThreadDatabase.rows(at: path, watched: []).map(\.id) == ["a", "new"])
    }

    @Test func independentAgentCreatedChatsCountAlongsideUserChatsAndKeepTheirLifecycle() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let path = scratch.file("state_5.sqlite")
        var db: OpaquePointer?; #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
        CREATE TABLE threads(id TEXT, title TEXT, rollout_path TEXT, originator TEXT, thread_source TEXT, archived INTEGER, updated_at INTEGER);
        """, nil, nil, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func insert(_ id: String, source: String, updated: Int, originator: String = "Codex Desktop") throws {
            let log = scratch.file(id + ".jsonl")
            try event("task_started").write(to: log)
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "INSERT INTO threads VALUES(?, 'Synthetic chat', ?, ?, ?, 0, ?)", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            for (i, value) in [id, log.path, originator, source].enumerated() {
                sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient)
            }
            sqlite3_bind_int(statement, 5, Int32(updated))
            #expect(sqlite3_step(statement) == SQLITE_DONE)
        }
        for id in ["user-a", "user-b"] { try insert(id, source: "user", updated: 1) }
        for id in ["agent-a", "agent-b"] { try insert(id, source: "agent_created_thread", updated: 1) }
        // More than a discovery page of newer children must not displace their parents.
        for i in 0..<40 { try insert("child-\(i)", source: "subagent", updated: 100) }
        try insert("cli", source: "agent_created_thread", updated: 100, originator: "Codex CLI")
        try insert("future", source: "unknown_source", updated: 100)
        let paths = MonitorPaths(codex: scratch.url, claude: scratch.file("none"), desktop: scratch.file("none"), storage: scratch.file("cache"))
        let monitor = LocalMonitor(paths: paths, persistentCache: false)
        let first = monitor.poll()
        #expect(first.readings.map(\.id.rawValue) == ["agent-a", "agent-b", "user-a", "user-b"])
        #expect(first.readings.allSatisfy { $0.phase == .working })
        #expect(first.logBytes == 4 * event("task_started").count)
        var ledger = ActivityLedger()
        let now = Date()
        ledger.apply(first.readings, at: now)
        #expect(ledger.visible.count == 4)
        #expect(monitor.poll(watched: ledger.watched).logBytes == 0)

        let log = scratch.file("agent-a.jsonl")
        let writer = try FileHandle(forWritingTo: log)
        defer { try? writer.close() }
        try writer.seekToEnd()
        let completion = event("task_complete", at: 2)
        try writer.write(contentsOf: completion.dropLast())
        ledger.apply(monitor.poll(watched: ledger.watched).readings, at: now.addingTimeInterval(1))
        #expect(ledger.visible.allSatisfy { $0.phase == .working })
        try writer.write(contentsOf: Data("\n".utf8))
        ledger.apply(monitor.poll(watched: ledger.watched).readings, at: now.addingTimeInterval(2))
        #expect(ledger.visible.filter { $0.phase == .working }.count == 3)
        #expect(ledger.visible.first { $0.id.rawValue == "agent-a" }?.phase == .finished)
        try writer.write(contentsOf: event("task_started", at: 3))
        ledger.apply(monitor.poll(watched: ledger.watched).readings, at: now.addingTimeInterval(3))
        #expect(ledger.visible.filter { $0.phase == .working }.count == 4)
        #expect(sqlite3_exec(db, "UPDATE threads SET archived=1 WHERE id='agent-a'", nil, nil, nil) == SQLITE_OK)
        ledger.apply(monitor.poll(watched: ledger.watched).readings, at: now.addingTimeInterval(4))
        #expect(ledger.visible.count == 3)
        #expect(!ledger.visible.contains { $0.id.rawValue == "agent-a" })
    }

    @Test func modernReadMarksAreScopedToCurrentIdentity() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let config = "model_provider = \"synthetic\"\n[model_providers.synthetic]\nrequires_openai_auth = false\n"
        try config.write(to: scratch.file("config.toml"), atomically: true, encoding: .utf8)
        let data = try JSONSerialization.data(withJSONObject: ["execution-storage", "none"], options: .withoutEscapingSlashes)
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let state: [String: Any] = ["electron-thread-read-state-v1": ["unreadByIdentity": [key: ["local:host": ["mine"], "remote:host": ["remote"]], "someone-else": ["local:host": ["other"]]]]]
        try JSONSerialization.data(withJSONObject: state).write(to: scratch.file(".codex-global-state.json"))
        let files = MetadataFiles(), marks = DesktopReadMarks(home: scratch.url, files: files)
        #expect(marks.unreadIDs() == ["mine"])
        files.begin(); #expect(marks.unreadIDs() == ["mine"])
        #expect(files.bytes == 0)
    }

    @Test func unknownReadIdentityNeverMarksFinishedTasksRead() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let state: [String: Any] = ["electron-thread-read-state-v1": ["unreadByIdentity": ["other": ["local": ["id"]]]]]
        try JSONSerialization.data(withJSONObject: state).write(to: scratch.file(".codex-global-state.json"))
        #expect(DesktopReadMarks(home: scratch.url, files: MetadataFiles()).unreadIDs() == nil)
    }

    @Test func claudeCodeLifecycleDeduplicationFocusAndWarmReadBudget() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let sessionDir = scratch.file("sessions")
        let desktop = scratch.file("desktop"), project = desktop.appendingPathComponent("account/project")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = MonitorPaths(codex: scratch.file("missing"), claude: scratch.url, desktop: desktop, storage: scratch.file("cache"))
        let state: [String: Any] = ["pid": Int(getpid()), "entrypoint": "claude-desktop", "kind": "interactive", "hostSessionId": "local_sample", "name": "合成测试任务", "status": "busy", "statusUpdatedAt": 1_800_000_000_000.0]
        let path = sessionDir.appendingPathComponent("one.json")
        try JSONSerialization.data(withJSONObject: state).write(to: path)
        try JSONSerialization.data(withJSONObject: state).write(to: sessionDir.appendingPathComponent("two.json"))
        let monitor = LocalMonitor(paths: paths, persistentCache: false)
        let id = ChatID(.claude, "local_sample")
        let first = monitor.poll()
        #expect(first.readings.count == 1 && first.readings.first?.phase == .working)
        #expect(first.metadataBytes < 4096)
        #expect(monitor.poll().metadataBytes == 0)
        var idle = state; idle["status"] = "idle"; idle["statusUpdatedAt"] = 1_800_000_001_000.0
        try JSONSerialization.data(withJSONObject: idle).write(to: path, options: .atomic)
        try Data("{\"lastFocusedAt\":1800000002000,\"padding\":\"\(String(repeating: "x", count: 20_000))\"}".utf8).write(to: project.appendingPathComponent("local_sample.json"))
        let done = monitor.poll(watched: [id])
        #expect(done.readings.first?.phase == .finished)
        #expect(done.readings.first?.unread == false)
        #expect(done.metadataBytes < 10_000)
        #expect(monitor.poll(watched: [id]).metadataBytes == 0)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.removeItem(at: sessionDir.appendingPathComponent("two.json"))
        let missing = monitor.poll(watched: [id])
        let again = monitor.poll(watched: [id])
        #expect(missing.readings.first?.eventTime == again.readings.first?.eventTime)
    }

    @Test func fourIndependentClaudeChatsAreCountedAndDuplicateFilesDoNotInflateCount() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let dir = scratch.file("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, status) in ["busy", "waiting", "waiting_for_permission", "waiting_for_input"].enumerated() {
            let state: [String: Any] = ["pid": 1234 + index, "entrypoint": "claude-desktop", "kind": "interactive",
                                        "hostSessionId": "synthetic-\(index)", "status": status, "statusUpdatedAt": 1000]
            let data = try JSONSerialization.data(withJSONObject: state)
            try data.write(to: dir.appendingPathComponent("\(index).json"))
            try data.write(to: dir.appendingPathComponent("\(index)-duplicate.json"))
        }
        let paths = MonitorPaths(codex: scratch.file("none"), claude: scratch.url, desktop: scratch.file("none"), storage: scratch.file("cache"))
        let monitor = LocalMonitor(paths: paths, persistentCache: false, processIsAlive: { _ in true })
        let report = monitor.poll()
        var ledger = ActivityLedger()
        ledger.apply(report.readings)
        #expect(ledger.visible.count == 4)
        #expect(ledger.visible.allSatisfy { $0.phase == .working && $0.id.client == .claude })
        #expect(report.metadataBytes <= 8 * 4096 && report.logBytes == 0)
        #expect(monitor.poll(watched: ledger.watched).metadataBytes == 0)
    }

    @Test func ignoresNonDesktopAndDeadHistoricalSessions() throws {
        let scratch = try Scratch(); defer { scratch.remove() }
        let dir = scratch.file("sessions"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, entry, pid) in [(0, "cli", Int(getpid())), (1, "claude-desktop", 2_000_000_000)] {
            let state: [String: Any] = ["pid": pid, "entrypoint": entry, "kind": "interactive", "hostSessionId": "excluded\(i)", "status": "busy"]
            try JSONSerialization.data(withJSONObject: state).write(to: dir.appendingPathComponent("\(i).json"))
        }
        let paths = MonitorPaths(codex: scratch.file("none"), claude: scratch.url, desktop: scratch.file("none"), storage: scratch.file("cache"))
        #expect(LocalMonitor(paths: paths, persistentCache: false).poll().readings.isEmpty)
    }
}
