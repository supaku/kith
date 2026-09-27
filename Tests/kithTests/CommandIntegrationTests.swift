import Foundation
import Testing

/// Spawn the built `kith` binary against a fixture DB via the `KITH_DB_PATH`
/// env variable. These tests don't exercise commands that need TCC contacts
/// access; only the FDA-substitute flow is covered here.
@Suite("kith CLI — integration via KITH_DB_PATH")
struct CommandIntegrationTests {
    /// Resolve the build-output `kith` binary. SwiftPM sets `BUILT_PRODUCTS_DIR`
    /// during test runs; if unset, look adjacent to the test bundle.
    static func binaryURL() -> URL {
        if let dir = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("kith")
        }
        // Test bundles live at .build/<arch>-apple-macosx/debug/<bundle>.xctest;
        // the binary is a sibling.
        let bundlePath = Bundle.allBundles.compactMap { b -> URL? in
            guard b.bundlePath.hasSuffix(".xctest") else { return nil }
            return b.bundleURL
        }.first
        let dir = bundlePath?.deletingLastPathComponent() ?? URL(fileURLWithPath: ".build/debug")
        return dir.appendingPathComponent("kith")
    }

    func run(_ args: [String], env: [String: String] = [:]) throws -> (stdout: String, stderr: String, code: Int32) {
        let binary = Self.binaryURL()
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw RuntimeError("kith binary not built at \(binary.path) — run `swift build` first")
        }
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        proc.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        try proc.run()
        proc.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self),
            proc.terminationStatus
        )
    }

    @Test("kith version --json contains version + name fields")
    func versionJSON() throws {
        let result = try run(["version", "--json"])
        #expect(result.code == 0)
        guard let data = result.stdout.data(using: .utf8) else {
            Issue.record("no stdout"); return
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["name"] as? String == "kith")
        #expect(obj?["version"] is String)
    }

    @Test("kith tools manifest --style kith decodes as JSON with commands array")
    func manifestKith() throws {
        let result = try run(["tools", "manifest", "--style", "kith"])
        #expect(result.code == 0)
        let obj = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        #expect((obj?["commands"] as? [Any])?.count ?? 0 >= 7)
    }

    @Test("kith tools schema --type Message includes attachments anyOf")
    func messageSchema() throws {
        let result = try run(["tools", "schema", "--type", "Message"])
        #expect(result.code == 0)
        #expect(result.stdout.contains("attachments"))
        #expect(result.stdout.contains("anyOf"))
    }

    @Test("--color flag overrides env on a missing local DB error")
    func colorFlagOverride() throws {
        let fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kith-color-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureDir) }
        let missingDB = fixtureDir.appendingPathComponent("missing.db").path
        let env = ["KITH_DB_PATH": missingDB, "KITH_COLOR": "auto", "NO_COLOR": "1"]
        #expect(!FileManager.default.fileExists(atPath: missingDB))

        // A read-only open fails before the local pipeline constructs ContactsStore.
        let plain = try run(["chats"], env: env)
        #expect(plain.code == 6)
        #expect(plain.stderr.contains("kith: error:"))
        #expect(!plain.stderr.contains("\u{1B}["))

        let forced = try run(["chats", "--color", "always"], env: env)
        #expect(forced.code == 6)
        #expect(forced.stderr.contains("\u{1B}[1;31m"))

        let machine = try run(["chats", "--jsonl"], env: env)
        #expect(machine.code == 6)
        let error = try JSONSerialization.jsonObject(with: Data(machine.stderr.utf8)) as? [String: Any]
        #expect(error?["code"] as? String == "DB_UNAVAILABLE")
        #expect(error?["exit"] as? Int == 6)
        #expect(!FileManager.default.fileExists(atPath: missingDB))
    }

    @Test("kith tools help dumps every command's help in one stream")
    func toolsHelpDump() throws {
        let result = try run(["tools", "help"])
        #expect(result.code == 0)
        // Each top-level subcommand and the nested groups/tools must appear
        // as a section header so an agent can grep the dump.
        let stdout = result.stdout
        for header in [
            "===== kith =====",
            "===== kith find =====",
            "===== kith history =====",
            "===== kith chats =====",
            "===== kith doctor =====",
            "===== kith groups list =====",
            "===== kith groups members =====",
            "===== kith tools manifest =====",
            "===== kith tools schema =====",
            "===== kith tools help =====",
            "===== kith version =====",
        ] {
            #expect(stdout.contains(header), Comment(rawValue: "missing header: \(header)"))
        }
        // Spot-check that a few key option flags survive into the dump.
        #expect(stdout.contains("--with"))
        #expect(stdout.contains("--inline"))
        #expect(stdout.contains("--raw-text"))
        #expect(stdout.contains("--jsonl"))
    }

    @Test("kith history with non-existent KITH_DB_PATH fails with exit 6 (DB unavailable)")
    func historyMissingDB() throws {
        let bogus = "/tmp/this-file-does-not-exist-\(UUID().uuidString).db"
        let result = try run(["history", "--with", "+14155551234"], env: ["KITH_DB_PATH": bogus])
        #expect(result.code == 6 || result.code == 5)
    }

    @Test("kith chats over fixture DB lists seeded chats")
    func chatsOverFixture() throws {
        let dbPath = try makeFixtureDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let result = try run(["chats", "--jsonl", "--limit", "10"], env: ["KITH_DB_PATH": dbPath])
        #expect(result.code == 0, Comment(rawValue: "stderr: \(result.stderr)"))
        let lines = result.stdout.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count >= 1)
    }

    @Test("history --with <phone> auto-prefers the 1:1 over group chats (--jsonl: stderr is silent)")
    func historyAutoPrefersOneToOneJSONL() throws {
        let dbPath = try makeAutoSelectFixtureDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let result = try run(
            ["history", "--with", "+14155551111", "--jsonl", "--limit", "50"],
            env: ["KITH_DB_PATH": dbPath, "NO_COLOR": "1"]
        )
        #expect(result.code == 0, Comment(rawValue: "stderr: \(result.stderr)"))
        let lines = result.stdout.split(separator: "\n").filter { !$0.isEmpty }
        // The 1:1 has 2 messages: 'one-to-one-A', 'one-to-one-B'. Group chat
        // has 'group-msg' which must NOT appear.
        #expect(lines.count == 2)
        #expect(result.stdout.contains("one-to-one"))
        #expect(!result.stdout.contains("group-msg"))
        // --jsonl mode is stderr-silent on the audit note (clean stream
        // contract). Agents can run `kith chats --with X` to see candidates.
        #expect(!result.stderr.contains("auto-selected"))
    }

    @Test("history --with <phone> auto-prefers the 1:1 over group chats (human: emits note)")
    func historyAutoPrefersOneToOneHuman() throws {
        let dbPath = try makeAutoSelectFixtureDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let result = try run(
            ["history", "--with", "+14155551111", "--limit", "50"],
            env: ["KITH_DB_PATH": dbPath, "NO_COLOR": "1"]
        )
        #expect(result.code == 0, Comment(rawValue: "stderr: \(result.stderr)"))
        // Human stderr carries the audit-trail note.
        #expect(result.stderr.contains("auto-selected 1:1"))
        #expect(result.stderr.contains("group/named chat"))
    }

    @Test("history --with <phone> exits 4 when only group chats match")
    func historyOnlyGroupsExitsAmbiguous() throws {
        let dbPath = try makeOnlyGroupChatFixtureDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let result = try run(
            ["history", "--with", "+14155551111", "--jsonl", "--limit", "50"],
            env: ["KITH_DB_PATH": dbPath]
        )
        #expect(result.code == 4, Comment(rawValue: "stderr: \(result.stderr)"))
        // Error envelope mentions "no canonical 1:1"
        #expect(result.stderr.contains("no canonical 1:1"))
        // Envelope candidates should carry the enriched metadata + reason.
        // The stderr line is one JSON object on stdout's stderr stream.
        // Find the JSON envelope (last non-empty stderr line).
        let lines = result.stderr
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let last = lines.last,
              let data = last.data(using: .utf8),
              let env = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Issue.record("could not parse error envelope from stderr")
            return
        }
        guard let candidates = env["candidates"] as? [[String: Any]],
              let first = candidates.first
        else {
            Issue.record("no candidates in envelope")
            return
        }
        #expect(first["mergeRejectionReason"] as? String == "groupChat")
        #expect(first["handleCount"] as? Int == 2)
        #expect(first["chatIdentifier"] as? String == "+14155551111")
        #expect(first["service"] as? String == "iMessage")
    }

    @Test("history human-mode ambiguity prints the candidate list under hint")
    func historyHumanCandidatesRendered() throws {
        let dbPath = try makeOnlyGroupChatFixtureDB()
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let result = try run(
            ["history", "--with", "+14155551111", "--limit", "50"],
            env: ["KITH_DB_PATH": dbPath]
        )
        #expect(result.code == 4, Comment(rawValue: "stderr: \(result.stderr)"))
        #expect(result.stderr.contains("kith: error:"))
        #expect(result.stderr.contains("hint:"))
        #expect(result.stderr.contains("candidates:"))
        #expect(result.stderr.contains("group chat"))
        #expect(result.stderr.contains("chat-id:"))
    }

    /// Fixture: one canonical 1:1 with +14155551111 + one group chat that
    /// also includes them. Used by historyAutoPrefersOneToOne.
    func makeAutoSelectFixtureDB() throws -> String {
        let path = NSTemporaryDirectory() + "kith-autoselect-\(UUID().uuidString).db"
        let appleNS = Int64((Date().timeIntervalSince1970 - 978_307_200) * 1_000_000_000)
        let sql = """
            \(commonSchema())
            -- 1:1
            INSERT INTO chat (chat_identifier, guid, display_name, service_name) VALUES ('+14155551111', 'iMessage;-;+14155551111', NULL, 'iMessage');
            INSERT INTO handle (id) VALUES ('+14155551111');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message (handle_id, text, date, is_from_me, service, guid) VALUES (1, 'one-to-one-A', \(appleNS - 1000), 0, 'iMessage', 'GUID-1A');
            INSERT INTO chat_message_join VALUES (1, 1);
            INSERT INTO message (handle_id, text, date, is_from_me, service, guid) VALUES (1, 'one-to-one-B', \(appleNS), 0, 'iMessage', 'GUID-1B');
            INSERT INTO chat_message_join VALUES (1, 2);
            -- Group chat (contains the same handle + a second one)
            INSERT INTO chat (chat_identifier, guid, display_name, service_name) VALUES ('+14155551111', 'iMessage;-;group', NULL, 'iMessage');
            INSERT INTO handle (id) VALUES ('+14155552222');
            INSERT INTO chat_handle_join VALUES (2, 1);
            INSERT INTO chat_handle_join VALUES (2, 2);
            INSERT INTO message (handle_id, text, date, is_from_me, service, guid) VALUES (1, 'group-msg', \(appleNS), 0, 'iMessage', 'GUID-G');
            INSERT INTO chat_message_join VALUES (2, 3);
            .quit
            """
        try runSQLite(path: path, sql: sql)
        return path
    }

    /// Fixture: only group chats include +14155551111 — no canonical 1:1.
    func makeOnlyGroupChatFixtureDB() throws -> String {
        let path = NSTemporaryDirectory() + "kith-onlygroup-\(UUID().uuidString).db"
        let appleNS = Int64((Date().timeIntervalSince1970 - 978_307_200) * 1_000_000_000)
        let sql = """
            \(commonSchema())
            INSERT INTO chat (chat_identifier, guid, display_name, service_name) VALUES ('+14155551111', 'iMessage;-;group-only', NULL, 'iMessage');
            INSERT INTO handle (id) VALUES ('+14155551111');
            INSERT INTO handle (id) VALUES ('+14155552222');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO chat_handle_join VALUES (1, 2);
            INSERT INTO message (handle_id, text, date, is_from_me, service, guid) VALUES (1, 'group-only', \(appleNS), 0, 'iMessage', 'GUID-X');
            INSERT INTO chat_message_join VALUES (1, 1);
            .quit
            """
        try runSQLite(path: path, sql: sql)
        return path
    }

    private func commonSchema() -> String {
        return """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, chat_identifier TEXT, guid TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, handle_id INTEGER, text TEXT, date INTEGER, is_from_me INTEGER, service TEXT, guid TEXT, associated_message_guid TEXT, associated_message_type INTEGER, attributedBody BLOB, thread_originator_guid TEXT, destination_caller_id TEXT, is_audio_message INTEGER, balloon_bundle_id TEXT);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT, total_bytes INTEGER, is_sticker INTEGER, user_info BLOB);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            """
    }

    private func runSQLite(path: String, sql: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [path]
        let stdin = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        stdin.fileHandleForWriting.write(Data(sql.utf8))
        try stdin.fileHandleForWriting.close()
        proc.waitUntilExit()
    }

    /// Build a tiny on-disk SQLite that mimics the chat.db schema enough for
    /// `kith chats` to enumerate.
    func makeFixtureDB() throws -> String {
        let path = NSTemporaryDirectory() + "kith-fixture-\(UUID().uuidString).db"
        // Use sqlite3 CLI to create the DB to avoid pulling SQLite as a test dep.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [path]
        let stdin = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        let appleNS = Int64((Date().timeIntervalSince1970 - 978_307_200) * 1_000_000_000)
        let sql = """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, chat_identifier TEXT, guid TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, handle_id INTEGER, text TEXT, date INTEGER, is_from_me INTEGER, service TEXT, guid TEXT, associated_message_guid TEXT, associated_message_type INTEGER, attributedBody BLOB, thread_originator_guid TEXT, destination_caller_id TEXT, is_audio_message INTEGER, balloon_bundle_id TEXT);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT, total_bytes INTEGER, is_sticker INTEGER, user_info BLOB);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            INSERT INTO chat (chat_identifier, guid, display_name, service_name) VALUES ('+14155551111', 'iMessage;-;+14155551111', NULL, 'iMessage');
            INSERT INTO handle (id) VALUES ('+14155551111');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message (handle_id, text, date, is_from_me, service, guid) VALUES (1, 'hi', \(appleNS), 0, 'iMessage', 'GUID-A');
            INSERT INTO chat_message_join VALUES (1, 1);
            .quit
            """
        stdin.fileHandleForWriting.write(Data(sql.utf8))
        try stdin.fileHandleForWriting.close()
        proc.waitUntilExit()
        return path
    }
}

private struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ m: String) { self.description = m }
}
