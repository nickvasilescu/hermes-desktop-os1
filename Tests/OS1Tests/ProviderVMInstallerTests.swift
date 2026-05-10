import Foundation
import Testing
@testable import OS1

struct ProviderVMInstallerTests {
    /// Smokes the generated Python through `python3 -c "ast.parse(...)"`
    /// for every catalog entry × every action. Catches quoting bugs in
    /// the base64 substitution before they ship.
    @Test
    func everyActionAndProviderProducesValidPython() throws {
        let actions: [(String, ProviderVMInstallAction)] = [
            ("install-no-activate", .install(apiKey: "sk-test", activateModel: nil)),
            ("install-with-activate", .install(apiKey: "sk-test", activateModel: "gpt-5.2")),
            ("activate", .activate(model: "anthropic/claude-opus-4.6")),
            ("uninstall", .uninstall),
            ("status", .status)
        ]

        for entry in ProviderCatalog.entries {
            for (label, action) in actions {
                let script = ProviderVMInstaller.makeScript(provider: entry, action: action)
                try assertPythonParses(script, comment: "\(entry.slug)/\(label)")
            }
        }
    }

    /// Spot-check that base64 encoding survives weird API key payloads.
    /// We've seen keys with embedded quotes, hashes, and slashes —
    /// base64 should cleanly normalize all of it.
    @Test
    func unusualAPIKeysRoundtripCleanly() throws {
        guard let openai = ProviderCatalog.entry(for: "openai") else {
            Issue.record("openai entry missing")
            return
        }

        let weirdKeys = [
            #"sk-with"quote-inside"#,
            "sk-with'apostrophe",
            "sk-with$dollar/sign",
            "sk-with`backtick`",
            "sk-with\\backslash",
            "" // empty — install should still parse; runtime branch errors out
        ]

        for key in weirdKeys {
            let script = ProviderVMInstaller.makeScript(
                provider: openai,
                action: .install(apiKey: key, activateModel: nil)
            )
            try assertPythonParses(script, comment: "key bytes=\(Array(key.utf8))")
        }
    }

    @Test
    func generatedScriptReferencesCorrectEnvVar() {
        let openrouter = ProviderCatalog.entry(for: "openrouter")!
        let script = ProviderVMInstaller.makeScript(
            provider: openrouter,
            action: .install(apiKey: "sk-or-test", activateModel: nil)
        )
        // Env var name is base64-encoded, but the literal string
        // "OPENROUTER_API_KEY" should appear exactly once via b64decode
        // — we assert by including a marker comment we generate. Here
        // we just sanity-check that the script contains the b64 of the
        // env var.
        let expectedB64 = Data("OPENROUTER_API_KEY".utf8).base64EncodedString()
        #expect(script.contains(expectedB64), "Generated script missing env var b64")
    }

    /// Executes the install+activate script for a built-in provider
    /// against a tmp HOME and asserts the resulting `config.yaml` /
    /// `auth.json` match Hermes' canonical schema. This catches the
    /// class of bug the parse-only test misses (e.g. writing to a field
    /// Hermes ignores, or setting `model.base_url` to a value that
    /// would double-route).
    @Test
    func builtinInstallProducesHermesCompatibleConfig() throws {
        let anthropic = try #require(ProviderCatalog.entry(for: "anthropic"))
        let outcome = try runInstallerScript(
            provider: anthropic,
            action: .install(apiKey: "sk-ant-test", activateModel: "claude-opus-4.6")
        )

        let model = try #require(outcome.config["model"] as? [String: Any])
        #expect(model["provider"] as? String == "anthropic")
        #expect(model["default"] as? String == "claude-opus-4.6")
        // CRITICAL: built-ins must NOT carry a model.base_url — Hermes'
        // PROVIDER_REGISTRY default wins. Our catalog stores the
        // /v1-suffixed validation URL which would double-route to
        // /v1/v1/messages if leaked into config.yaml.
        #expect(model["base_url"] == nil, "built-in providers must not write model.base_url")
        // No phantom field — Hermes has no `model.custom_provider`.
        #expect(model["custom_provider"] == nil)
        // Stale fields cleared — mirrors Hermes' own _update_config_for_provider.
        #expect(model["api_key"] == nil)
        #expect(model["api_mode"] == nil)

        // auth.json gets the canonical `active_provider` hook.
        #expect(outcome.authJSON["active_provider"] as? String == "anthropic")
    }

    /// Same shape as the built-in test, but for a `customProvider`
    /// catalog kind (OpenAI). Custom providers MUST carry a base_url
    /// because Hermes resolves them via `_get_named_custom_provider`,
    /// which reads `custom_providers[].base_url` — and the model
    /// section's base_url is honored as a fallback.
    @Test
    func customProviderInstallWritesCustomProvidersEntryAndModelBaseURL() throws {
        let openai = try #require(ProviderCatalog.entry(for: "openai"))
        let outcome = try runInstallerScript(
            provider: openai,
            action: .install(apiKey: "sk-test-openai", activateModel: "gpt-5.2-codex")
        )

        let model = try #require(outcome.config["model"] as? [String: Any])
        #expect(model["provider"] as? String == "openai")
        #expect(model["default"] as? String == "gpt-5.2-codex")
        #expect(model["base_url"] as? String == "https://api.openai.com/v1")
        #expect(model["custom_provider"] == nil)
        #expect(model["api_key"] == nil)
        #expect(model["api_mode"] == nil)

        let providers = try #require(outcome.config["custom_providers"] as? [[String: Any]])
        let entry = try #require(providers.first(where: { ($0["name"] as? String) == "openai" }))
        #expect(entry["base_url"] as? String == "https://api.openai.com/v1")
        #expect(entry["key_env"] as? String == "OPENAI_API_KEY")

        #expect(outcome.authJSON["active_provider"] as? String == "openai")
    }

    private struct InstallerOutcome {
        let config: [String: Any]
        let authJSON: [String: Any]
        let envContent: String
    }

    /// Runs the generated Python under a tmp HOME so the script's writes
    /// land in `<tmp>/.hermes/`. Returns the parsed config / auth files.
    private func runInstallerScript(
        provider: ProviderCatalogEntry,
        action: ProviderVMInstallAction
    ) throws -> InstallerOutcome {
        let script = ProviderVMInstaller.makeScript(provider: provider, action: action)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("os1-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        // HOME drives os.path.expanduser("~") inside the script; sandbox
        // the writes here so we don't touch the developer's real .hermes.
        process.environment = ["HOME": tmp.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stderrText = String(
            data: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(process.terminationStatus == 0, "installer exited \(process.terminationStatus): \(stderrText)")

        let hermesDir = tmp.appendingPathComponent(".hermes")
        let configData = try Data(contentsOf: hermesDir.appendingPathComponent("config.yaml"))
        let configText = String(data: configData, encoding: .utf8) ?? ""
        let parsed = try parseYAML(configText)

        let authData = try Data(contentsOf: hermesDir.appendingPathComponent("auth.json"))
        let auth = try (JSONSerialization.jsonObject(with: authData) as? [String: Any]) ?? [:]

        let envContent: String
        let envURL = hermesDir.appendingPathComponent(".env")
        if let envData = try? Data(contentsOf: envURL) {
            envContent = String(data: envData, encoding: .utf8) ?? ""
        } else {
            envContent = ""
        }

        return InstallerOutcome(config: parsed, authJSON: auth, envContent: envContent)
    }

    /// Round-trips config.yaml into a dictionary without taking a Swift
    /// YAML dependency. The installer may write JSON as its no-PyYAML
    /// fallback because JSON is valid YAML.
    private func parseYAML(_ text: String) throws -> [String: Any] {
        if let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-c",
            "import sys, json, yaml; print(json.dumps(yaml.safe_load(sys.stdin.read()) or {}))"
        ]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(text.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func assertPythonParses(
        _ script: String,
        comment: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import ast, sys; ast.parse(sys.stdin.read())"]

        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let stderrData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let label = comment.map { "[\($0)] " } ?? ""
        #expect(
            process.terminationStatus == 0,
            "\(label)Python parse failed: \(stderrText)",
            sourceLocation: sourceLocation
        )
    }
}
