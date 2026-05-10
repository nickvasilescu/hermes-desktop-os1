import Foundation

enum RealtimeOrgoMCPError: LocalizedError {
    case missingAPIKey
    case missingRuntime
    case invalidResponse(String)
    case rpcError(String)
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Orgo API key missing. Save an Orgo key in OS1 or set ORGO_API_KEY before launching."
        case .missingRuntime:
            "Orgo MCP runtime missing. Install Node.js or set OS1_ORGO_MCP_JS_PATH."
        case .invalidResponse(let message):
            "Invalid Orgo MCP response: \(message)"
        case .rpcError(let message):
            "Orgo MCP error: \(message)"
        case .processError(let message):
            "Orgo MCP process error: \(message)"
        }
    }
}

struct RealtimeOrgoMCPTool: Encodable {
    let type = "function"
    let name: String
    let description: String
    let parameters: AnyEncodable
}

struct RealtimeOrgoMCPCallResult: Encodable {
    let isError: Bool
    let content: AnyEncodable
}

final class RealtimeOrgoMCPBridge: @unchecked Sendable {
    static let defaultToolsets = "core,screen,files"
    static let defaultDisabledTools = "orgo_upload_file"
    static let defaultReadOnly = "true"
    static let defaultPackage = "@orgo-ai/mcp@3.0.0"

    private let apiKeyProvider: @Sendable () -> String?
    private let defaultComputerIDProvider: @Sendable () -> String?

    init(
        apiKeyProvider: @escaping @Sendable () -> String?,
        defaultComputerIDProvider: @escaping @Sendable () -> String?
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.defaultComputerIDProvider = defaultComputerIDProvider
    }

    var isConfigured: Bool {
        resolvedAPIKey() != nil && Self.resolveCommand() != nil
    }

    func listRealtimeTools() async throws -> [RealtimeOrgoMCPTool] {
        let session = try makeSession()
        defer { session.close() }

        try session.initialize()
        let result = try session.request(method: "tools/list")
        guard let tools = result["tools"] as? [[String: Any]] else {
            throw RealtimeOrgoMCPError.invalidResponse("Missing tools array.")
        }

        return tools.compactMap { tool -> RealtimeOrgoMCPTool? in
            guard let name = tool["name"] as? String else { return nil }
            let description = tool["description"] as? String ?? "Orgo MCP tool \(name)"
            let schema = tool["inputSchema"] as? [String: Any] ?? [
                "type": "object",
                "additionalProperties": true,
                "properties": [:],
            ]
            return RealtimeOrgoMCPTool(
                name: name,
                description: description,
                parameters: AnyEncodable(schema)
            )
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> RealtimeOrgoMCPCallResult {
        let session = try makeSession()
        defer { session.close() }

        try session.initialize()
        let result = try session.request(
            method: "tools/call",
            params: [
                "name": name,
                "arguments": arguments,
            ]
        )

        return RealtimeOrgoMCPCallResult(
            isError: result["isError"] as? Bool ?? false,
            content: AnyEncodable(result["content"] ?? result)
        )
    }

    private func makeSession() throws -> RealtimeMCPStdioSession {
        guard let apiKey = resolvedAPIKey() else {
            throw RealtimeOrgoMCPError.missingAPIKey
        }

        guard let command = Self.resolveCommand() else {
            throw RealtimeOrgoMCPError.missingRuntime
        }

        var environment = Self.baseEnvironment()
        environment["ORGO_API_KEY"] = apiKey
        if let defaultComputerID = defaultComputerIDProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !defaultComputerID.isEmpty {
            environment["ORGO_DEFAULT_COMPUTER_ID"] = defaultComputerID
        }

        // Public builds start with a bounded voice surface. Shell/admin tools
        // are available only when explicitly enabled through environment
        // configuration.
        environment["ORGO_TOOLSETS"] = ProcessInfo.processInfo.environment["OS1_REALTIME_ORGO_TOOLSETS"] ?? Self.defaultToolsets
        environment["ORGO_DISABLED_TOOLS"] = ProcessInfo.processInfo.environment["OS1_REALTIME_ORGO_DISABLED_TOOLS"] ?? Self.defaultDisabledTools
        environment["ORGO_READ_ONLY"] = ProcessInfo.processInfo.environment["OS1_REALTIME_ORGO_READ_ONLY"] ?? Self.defaultReadOnly

        return try RealtimeMCPStdioSession(command: command.path, arguments: command.arguments, environment: environment)
    }

    private func resolvedAPIKey() -> String? {
        if let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        if let key = ProcessInfo.processInfo.environment["ORGO_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        return nil
    }

    private struct MCPCommand {
        let path: String
        let arguments: [String]
    }

    private static func resolveCommand() -> MCPCommand? {
        let env = ProcessInfo.processInfo.environment
        if let configuredPath = env["OS1_ORGO_MCP_JS_PATH"], FileManager.default.fileExists(atPath: configuredPath),
           let node = firstExecutable(named: "node", fallbackPaths: [
               "/usr/local/bin/node",
               "/opt/homebrew/bin/node",
               "/run/current-system/sw/bin/node",
               "/usr/bin/node",
           ]) {
            return MCPCommand(path: node, arguments: [configuredPath])
        }

        if let npx = firstExecutable(named: "npx", fallbackPaths: [
            "/usr/local/bin/npx",
            "/opt/homebrew/bin/npx",
            "/run/current-system/sw/bin/npx",
            "/usr/bin/npx",
        ]) {
            let package = env["OS1_ORGO_MCP_PACKAGE"] ?? Self.defaultPackage
            guard isPinnedNPMPackage(package) else { return nil }
            return MCPCommand(path: npx, arguments: ["-y", package])
        }

        return nil
    }

    private static func isPinnedNPMPackage(_ package: String) -> Bool {
        let trimmed = package.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else {
            return false
        }

        if trimmed.hasPrefix("@") {
            guard let slash = trimmed.firstIndex(of: "/") else { return false }
            let afterPackageName = trimmed.index(after: slash)
            guard let versionSeparator = trimmed[afterPackageName...].lastIndex(of: "@") else {
                return false
            }
            let versionStart = trimmed.index(after: versionSeparator)
            return versionStart < trimmed.endIndex && trimmed[versionStart].isNumber
        }

        guard let versionSeparator = trimmed.lastIndex(of: "@") else {
            return false
        }
        let versionStart = trimmed.index(after: versionSeparator)
        return versionStart < trimmed.endIndex && trimmed[versionStart].isNumber
    }

    private static func firstExecutable(named name: String, fallbackPaths: [String]) -> String? {
        var paths = fallbackPaths
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        for entry in pathEntries {
            paths.append(URL(fileURLWithPath: entry, isDirectory: true).appendingPathComponent(name).path)
        }

        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func baseEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let keys = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "NPM_CONFIG_PREFIX"]
        var environment: [String: String] = [:]
        for key in keys {
            if let value = source[key], !value.isEmpty {
                environment[key] = value
            }
        }
        if environment["PATH"] == nil {
            environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return environment
    }
}

final class RealtimeMCPStdioSession {
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private var buffer = Data()
    private var nextID = 1

    init(command: String, arguments: [String], environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw RealtimeOrgoMCPError.processError(error.localizedDescription)
        }
    }

    func initialize() throws {
        _ = try request(
            method: "initialize",
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": [
                    "name": "OS1 Realtime Voice",
                    "version": "0.1.0",
                ],
            ]
        )
        try notify(method: "notifications/initialized")
    }

    func request(method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        let id = nextID
        nextID += 1

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            payload["params"] = params
        }
        try write(payload)

        while true {
            let message = try readMessage()
            guard Self.id(message["id"], matches: id) else { continue }

            if let error = message["error"] as? [String: Any] {
                let message = error["message"] as? String ?? String(describing: error)
                throw RealtimeOrgoMCPError.rpcError(message)
            }

            return message["result"] as? [String: Any] ?? [:]
        }
    }

    func notify(method: String, params: [String: Any]? = nil) throws {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params {
            payload["params"] = params
        }
        try write(payload)
    }

    func close() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func write(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw RealtimeOrgoMCPError.invalidResponse("Attempted to send invalid JSON-RPC payload.")
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        inputPipe.fileHandleForWriting.write(data)
        inputPipe.fileHandleForWriting.write(Data("\n".utf8))
    }

    private func readMessage() throws -> [String: Any] {
        while true {
            if let line = nextBufferedLine() {
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                guard let data = line.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                return object
            }

            let chunk = outputPipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                let errorOutput = String(data: errorPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                throw RealtimeOrgoMCPError.processError(errorOutput.isEmpty ? "Process closed stdout." : errorOutput)
            }
            buffer.append(chunk)
        }
    }

    private func nextBufferedLine() -> String? {
        guard let newlineRange = buffer.firstRange(of: Data("\n".utf8)) else { return nil }
        let lineData = buffer[..<newlineRange.lowerBound]
        buffer.removeSubrange(..<newlineRange.upperBound)
        return String(data: lineData, encoding: .utf8)
    }

    private static func id(_ value: Any?, matches expected: Int) -> Bool {
        if let intValue = value as? Int {
            return intValue == expected
        }
        if let number = value as? NSNumber {
            return number.intValue == expected
        }
        return false
    }
}

struct AnyEncodable: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try Self.encode(value, into: &container)
    }

    private static func encode(_ value: Any, into container: inout SingleValueEncodingContainer) throws {
        switch value {
        case let string as String:
            try container.encode(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                try container.encode(number.boolValue)
            } else if number.doubleValue.rounded(.towardZero) == number.doubleValue {
                try container.encode(number.int64Value)
            } else {
                try container.encode(number.doubleValue)
            }
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let int64 as Int64:
            try container.encode(int64)
        case let double as Double:
            try container.encode(double)
        case let array as [Any]:
            try container.encode(array.map(AnyEncodable.init))
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues(AnyEncodable.init))
        case _ as NSNull:
            try container.encodeNil()
        default:
            try container.encode(String(describing: value))
        }
    }
}

extension RealtimeOrgoMCPTool: @unchecked Sendable {}
extension RealtimeOrgoMCPCallResult: @unchecked Sendable {}
extension AnyEncodable: @unchecked Sendable {}
