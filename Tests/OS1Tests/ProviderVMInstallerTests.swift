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

    @Test
    func fallbackParsesSimpleConfigWithoutPyYAML() throws {
        let openai = try #require(ProviderCatalog.entry(for: "openai"))
        let initialConfig = """
        model:
          provider: anthropic
          default: claude-opus-4.6
          temperature: 0.2
          enabled: true
          tags:
            - fast
            - stable
        custom_providers:
          - name: existing
            base_url: https://example.test/v1
            key_env: EXISTING_API_KEY
        metadata:
          retries: 3
          nested:
            enabled: false
        """

        let outcome = try runInstallerScript(
            provider: openai,
            action: .install(apiKey: "sk-test-openai", activateModel: "gpt-5.2-codex"),
            initialConfig: initialConfig,
            blockPyYAML: true
        )

        #expect(outcome.result["success"] as? Bool == true)
        #expect((outcome.result["errors"] as? [String])?.isEmpty == true)
        #expect(outcome.configText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))

        let model = try #require(outcome.config["model"] as? [String: Any])
        #expect(model["provider"] as? String == "openai")
        #expect(model["default"] as? String == "gpt-5.2-codex")
        #expect(model["base_url"] as? String == "https://api.openai.com/v1")
        #expect((model["temperature"] as? NSNumber)?.doubleValue == 0.2)
        #expect((model["enabled"] as? NSNumber)?.boolValue == true)
        #expect(model["tags"] as? [String] == ["fast", "stable"])

        let providers = try #require(outcome.config["custom_providers"] as? [[String: Any]])
        #expect(providers.contains { ($0["name"] as? String) == "existing" })
        #expect(providers.contains { ($0["name"] as? String) == "openai" })

        let metadata = try #require(outcome.config["metadata"] as? [String: Any])
        #expect((metadata["retries"] as? NSNumber)?.intValue == 3)
        let nested = try #require(metadata["nested"] as? [String: Any])
        #expect((nested["enabled"] as? NSNumber)?.boolValue == false)
    }

    @Test
    func pyYAMLPathStillHandlesRicherYAML() throws {
        let openai = try #require(ProviderCatalog.entry(for: "openai"))
        let initialConfig = """
        custom_providers:
          - &existing
            name: existing
            base_url: https://example.test/v1
            key_env: EXISTING_API_KEY
        provider_alias: *existing
        """

        let outcome = try runInstallerScript(
            provider: openai,
            action: .install(apiKey: "sk-test-openai", activateModel: nil),
            initialConfig: initialConfig
        )

        #expect(outcome.result["success"] as? Bool == true)
        #expect((outcome.result["errors"] as? [String])?.isEmpty == true)

        let providers = try #require(outcome.config["custom_providers"] as? [[String: Any]])
        #expect(providers.contains { ($0["name"] as? String) == "existing" })
        #expect(providers.contains { ($0["name"] as? String) == "openai" })
        let alias = try #require(outcome.config["provider_alias"] as? [String: Any])
        #expect(alias["name"] as? String == "existing")
    }

    @Test
    func statusReadsSimpleConfigWithoutPyYAML() throws {
        let openai = try #require(ProviderCatalog.entry(for: "openai"))
        let initialConfig = """
        model:
          provider: openai
          default: gpt-5.2-codex
        custom_providers:
          - name: openai
            base_url: https://api.openai.com/v1
            key_env: OPENAI_API_KEY
        """

        let outcome = try runInstallerScript(
            provider: openai,
            action: .status,
            initialConfig: initialConfig,
            initialEnv: #"OPENAI_API_KEY="sk-test-openai""# + "\n",
            blockPyYAML: true
        )

        #expect(outcome.result["success"] as? Bool == true)
        #expect((outcome.result["errors"] as? [String])?.isEmpty == true)
        #expect(outcome.result["active_model"] as? String == "gpt-5.2-codex")
        let steps = try #require(outcome.result["steps_done"] as? [String])
        #expect(steps.contains("env_present"))
        #expect(steps.contains("custom_provider_present"))
        #expect(steps.contains("model_provider_active"))
    }

    @Test
    func malformedConfigWithoutPyYAMLFailsClearlyAfterPartialInstall() throws {
        let openai = try #require(ProviderCatalog.entry(for: "openai"))
        let malformedConfig = """
        model:
          provider: anthropic
            default: claude-opus-4.6
        """

        let outcome = try runInstallerScript(
            provider: openai,
            action: .install(apiKey: "sk-test-openai", activateModel: "gpt-5.2-codex"),
            initialConfig: malformedConfig,
            blockPyYAML: true,
            expectSuccess: false
        )

        #expect(outcome.result["success"] as? Bool == false)
        let errors = try #require(outcome.result["errors"] as? [String])
        #expect(errors.contains { $0.contains("Couldn't parse existing config.yaml without PyYAML") })
        let steps = try #require(outcome.result["steps_done"] as? [String])
        #expect(steps.contains("env_written"))
        #expect(!steps.contains("custom_provider_written"))
        #expect(!steps.contains("activated"))
        #expect(outcome.envContent.contains("OPENAI_API_KEY"))
        #expect(outcome.configText == malformedConfig)
    }

    private struct InstallerOutcome {
        let result: [String: Any]
        let config: [String: Any]
        let configText: String
        let authJSON: [String: Any]
        let envContent: String
    }

    /// Runs the generated Python under a tmp HOME so the script's writes
    /// land in `<tmp>/.hermes/`. Returns the parsed config / auth files.
    private func runInstallerScript(
        provider: ProviderCatalogEntry,
        action: ProviderVMInstallAction,
        initialConfig: String? = nil,
        initialEnv: String? = nil,
        blockPyYAML: Bool = false,
        expectSuccess: Bool = true
    ) throws -> InstallerOutcome {
        let script = ProviderVMInstaller.makeScript(provider: provider, action: action)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("os1-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let hermesDir = tmp.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: hermesDir, withIntermediateDirectories: true)
        if let initialConfig {
            try Data(initialConfig.utf8).write(to: hermesDir.appendingPathComponent("config.yaml"))
        }
        if let initialEnv {
            try Data(initialEnv.utf8).write(to: hermesDir.appendingPathComponent(".env"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let wrapper = blockPyYAML ? """
        import builtins
        import subprocess
        import sys

        real_import = builtins.__import__
        def blocked_import(name, globals=None, locals=None, fromlist=(), level=0):
            if name == "yaml" or name.startswith("yaml."):
                raise ImportError("blocked yaml for test")
            return real_import(name, globals, locals, fromlist, level)

        def blocked_run(*args, **kwargs):
            raise RuntimeError("pip disabled for test")

        builtins.__import__ = blocked_import
        subprocess.run = blocked_run
        exec(compile(sys.stdin.read(), "<installer>", "exec"))
        """ : """
        import sys
        exec(compile(sys.stdin.read(), "<installer>", "exec"))
        """
        process.arguments = ["python3", "-c", wrapper]
        // HOME drives os.path.expanduser("~") inside the script; sandbox
        // the writes here so we don't touch the developer's real .hermes.
        process.environment = ["HOME": tmp.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdoutText = String(
            data: (try? stdout.fileHandleForReading.readToEnd()) ?? Data(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrText = String(
            data: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(process.terminationStatus == 0, "installer exited \(process.terminationStatus): \(stderrText)")
        let result = try (JSONSerialization.jsonObject(with: Data(stdoutText.utf8)) as? [String: Any]) ?? [:]
        #expect(result["success"] as? Bool == expectSuccess, "installer stdout: \(stdoutText)")

        let configData = (try? Data(contentsOf: hermesDir.appendingPathComponent("config.yaml"))) ?? Data()
        let configText = String(data: configData, encoding: .utf8) ?? ""
        let parsed = (configText.isEmpty || !expectSuccess) ? [:] : try parseYAML(configText)

        let authData = (try? Data(contentsOf: hermesDir.appendingPathComponent("auth.json"))) ?? Data()
        let auth = authData.isEmpty ? [:] : try (JSONSerialization.jsonObject(with: authData) as? [String: Any]) ?? [:]

        let envContent: String
        let envURL = hermesDir.appendingPathComponent(".env")
        if let envData = try? Data(contentsOf: envURL) {
            envContent = String(data: envData, encoding: .utf8) ?? ""
        } else {
            envContent = ""
        }

        return InstallerOutcome(result: result, config: parsed, configText: configText, authJSON: auth, envContent: envContent)
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
