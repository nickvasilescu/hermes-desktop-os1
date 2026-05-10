import Foundation
import Network
import Security

final class RealtimeVoiceSessionServer: ObservableObject, @unchecked Sendable {
    @Published private(set) var endpointURL: URL?
    @Published private(set) var statusText: String = "Stopped"
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.elementsoftware.os1.realtime-voice")
    private var listener: NWListener?
    private var apiKey: String?
    private let accessToken = RealtimeVoiceSessionServer.makeAccessToken()
    private let openAIAPIKeyProvider: @Sendable () -> String?
    private let orgoMCPBridge: RealtimeOrgoMCPBridge

    init(
        openAIAPIKeyProvider: @escaping @Sendable () -> String? = {
            ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        },
        orgoAPIKeyProvider: @escaping @Sendable () -> String? = {
            ProcessInfo.processInfo.environment["ORGO_API_KEY"]
        },
        orgoDefaultComputerIDProvider: @escaping @Sendable () -> String? = {
            ProcessInfo.processInfo.environment["ORGO_DEFAULT_COMPUTER_ID"]
        }
    ) {
        self.openAIAPIKeyProvider = openAIAPIKeyProvider
        self.orgoMCPBridge = RealtimeOrgoMCPBridge(
            apiKeyProvider: orgoAPIKeyProvider,
            defaultComputerIDProvider: orgoDefaultComputerIDProvider
        )
    }

    deinit {
        listener?.cancel()
    }

    func start() {
        guard listener == nil else { return }

        guard let apiKey = openAIAPIKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            endpointURL = nil
            statusText = "OPENAI_API_KEY missing"
            lastError = "Connect OpenAI on the Providers tab or set OPENAI_API_KEY before launching OS1 to use Realtime voice mode."
            return
        }

        self.apiKey = apiKey

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

            let listener = try NWListener(using: parameters)
            self.listener = listener
            statusText = "Starting local session endpoint"
            lastError = nil

            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        } catch {
            statusText = "Failed to start voice endpoint"
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        endpointURL = nil
        statusText = "Stopped"
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.endpointURL = URL(string: "http://127.0.0.1:\(port.rawValue)/?token=\(self.accessToken)")
                self.statusText = "Voice endpoint ready"
                self.lastError = nil
            }
        case .failed(let error):
            DispatchQueue.main.async { [weak self] in
                self?.endpointURL = nil
                self?.statusText = "Voice endpoint failed"
                self?.lastError = error.localizedDescription
                self?.listener?.cancel()
                self?.listener = nil
            }
        case .cancelled:
            DispatchQueue.main.async { [weak self] in
                self?.endpointURL = nil
                self?.statusText = "Stopped"
            }
        default:
            break
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(from: connection, buffered: Data())
    }

    private func receive(from connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.send(.plain(status: 400, body: "Request receive failed: \(error.localizedDescription)"), on: connection)
                return
            }

            var requestData = buffered
            if let data {
                requestData.append(data)
            }

            if requestData.count > 1_000_000 {
                self.send(.plain(status: 413, body: "Request body too large"), on: connection)
                return
            }

            if let request = HTTPRequest(data: requestData) {
                self.route(request, on: connection)
                return
            }

            if isComplete {
                self.send(.plain(status: 400, body: "Incomplete HTTP request"), on: connection)
                return
            }

            self.receive(from: connection, buffered: requestData)
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.hasAccessToken(accessToken) else {
            send(.plain(status: 403, body: "Forbidden"), on: connection)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            send(.html(status: 200, body: Self.voiceHTML), on: connection)
        case ("GET", "/tools"):
            Task { [weak self] in
                let response = await self?.listToolsResponse() ?? .plain(status: 500, body: "Voice server unavailable")
                self?.send(response, on: connection)
            }
        case ("POST", "/session"):
            guard let sdp = String(data: request.body, encoding: .utf8), !sdp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                send(.plain(status: 400, body: "Expected raw SDP body"), on: connection)
                return
            }

            guard let apiKey else {
                send(.plain(status: 500, body: "OPENAI_API_KEY is not configured"), on: connection)
                return
            }

            Task { [weak self] in
                let response = await self?.createRealtimeCall(sdp: sdp, apiKey: apiKey) ?? .plain(status: 500, body: "Voice server unavailable")
                self?.send(response, on: connection)
            }
        case ("POST", "/tool"):
            guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let name = payload["name"] as? String,
                  name.hasPrefix("orgo_") else {
                send(.plain(status: 400, body: "Expected Orgo MCP tool call JSON"), on: connection)
                return
            }

            let arguments = payload["arguments"] as? [String: Any] ?? [:]
            Task { [weak self] in
                let response = await self?.callToolResponse(name: name, arguments: arguments) ?? .plain(status: 500, body: "Voice server unavailable")
                self?.send(response, on: connection)
            }
        default:
            send(.plain(status: 404, body: "Not found"), on: connection)
        }
    }

    private func listToolsResponse() async -> HTTPResponse {
        guard orgoMCPBridge.isConfigured else {
            return Self.jsonResponse(RealtimeToolsResponse(
                tools: [],
                orgo: RealtimeOrgoStatus(enabled: false, status: "Orgo MCP unavailable: missing API key or Node runtime")
            ))
        }

        do {
            let tools = try await orgoMCPBridge.listRealtimeTools()
            return Self.jsonResponse(RealtimeToolsResponse(
                tools: tools,
                orgo: RealtimeOrgoStatus(enabled: true, status: "Orgo MCP ready: \(tools.count) tools")
            ))
        } catch {
            return Self.jsonResponse(
                RealtimeToolsResponse(
                    tools: [],
                    orgo: RealtimeOrgoStatus(enabled: false, status: error.localizedDescription)
                ),
                status: 502
            )
        }
    }

    private func callToolResponse(name: String, arguments: [String: Any]) async -> HTTPResponse {
        do {
            let result = try await orgoMCPBridge.callTool(name: name, arguments: arguments)
            return Self.jsonResponse(result)
        } catch {
            return Self.jsonResponse(
                RealtimeOrgoMCPCallResult(
                    isError: true,
                    content: AnyEncodable([["type": "text", "text": error.localizedDescription]])
                ),
                status: 502
            )
        }
    }

    private func createRealtimeCall(sdp: String, apiKey: String) async -> HTTPResponse {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/calls")!)
        let multipart = RealtimeCallsMultipartRequest.make(sdp: sdp, session: Self.sessionConfig)

        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.upload(for: request, from: multipart.body)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .plain(status: 502, body: "OpenAI returned a non-HTTP response")
            }

            if (200..<300).contains(httpResponse.statusCode) {
                return HTTPResponse(status: httpResponse.statusCode, contentType: "application/sdp", body: data)
            }

            let body = String(data: data, encoding: .utf8) ?? "OpenAI Realtime call setup failed"
            return .plain(status: httpResponse.statusCode, body: body)
        } catch {
            return .plain(status: 502, body: error.localizedDescription)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var payload = Data()
        payload.appendString("HTTP/1.1 \(response.status) \(response.reasonPhrase)\r\n")
        payload.appendString("Content-Length: \(response.body.count)\r\n")
        payload.appendString("Content-Type: \(response.contentType)\r\n")
        payload.appendString("Cache-Control: no-store\r\n")
        payload.appendString("Connection: close\r\n")
        payload.appendString("\r\n")
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func jsonResponse<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        do {
            let data = try JSONEncoder().encode(value)
            return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
        } catch {
            return .plain(status: 500, body: "Failed to encode JSON response: \(error.localizedDescription)")
        }
    }

    private static func makeAccessToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "") +
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static let sessionConfig: String = {
        let session: [String: Any] = [
            "type": "realtime",
            "model": "gpt-realtime-2",
            "audio": [
                "output": [
                    "voice": "marin",
                ],
            ],
            "instructions": """
            You are OS1 voice mode. Keep spoken replies short and operational. You can use the sample check_calendar function when the user asks whether a date and time is available. When Orgo MCP tools are registered, use them to inspect and control Orgo cloud computers.
            """,
        ]

        let data = try! JSONSerialization.data(withJSONObject: session, options: [])
        return String(data: data, encoding: .utf8)!
    }()

    private static let voiceHTML: String = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>OS1 Realtime Voice</title>
      <style>
        :root {
          color-scheme: dark;
          --bg: #c65a43;
          --panel: rgba(255,255,255,.10);
          --panel-strong: rgba(255,255,255,.18);
          --border: rgba(255,255,255,.28);
          --text: rgba(255,255,255,.95);
          --muted: rgba(255,255,255,.64);
          --ok: #b7e3ca;
          --warn: #ffd89a;
        }

        * { box-sizing: border-box; }
        body {
          margin: 0;
          min-height: 100vh;
          background: var(--bg);
          color: var(--text);
          font: 14px/1.45 -apple-system, BlinkMacSystemFont, "DM Sans", "Helvetica Neue", sans-serif;
        }

        main {
          display: grid;
          grid-template-rows: auto 1fr auto;
          gap: 14px;
          min-height: 100vh;
          padding: 18px;
        }

        header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 12px;
        }

        h1 {
          margin: 0;
          font-size: 17px;
          font-weight: 400;
          letter-spacing: 0;
        }

        .status {
          color: var(--muted);
          font-size: 12px;
          white-space: nowrap;
        }

        .orb {
          display: grid;
          place-items: center;
          width: min(52vw, 220px);
          aspect-ratio: 1;
          justify-self: center;
          align-self: center;
          border-radius: 999px;
          background: radial-gradient(circle at 50% 42%, rgba(255,255,255,.24), rgba(255,255,255,.10) 42%, rgba(255,255,255,.04) 70%);
          border: 1px solid var(--border);
          box-shadow: inset 0 0 60px rgba(255,255,255,.10);
          transition: transform .2s ease, background .2s ease;
        }

        .orb.connected {
          background: radial-gradient(circle at 50% 42%, rgba(183,227,202,.38), rgba(255,255,255,.12) 44%, rgba(255,255,255,.04) 72%);
        }

        .orb.listening {
          transform: scale(1.03);
        }

        .orb span {
          color: var(--text);
          font-size: 12px;
          text-transform: uppercase;
          letter-spacing: 1.6px;
        }

        .controls {
          display: grid;
          gap: 10px;
        }

        button {
          appearance: none;
          width: 100%;
          border: 1px solid var(--border);
          border-radius: 8px;
          background: var(--panel);
          color: var(--text);
          padding: 11px 12px;
          font: inherit;
          cursor: pointer;
        }

        button:hover { background: var(--panel-strong); }
        button:disabled { opacity: .45; cursor: default; }

        .row {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 10px;
        }

        pre {
          min-height: 86px;
          max-height: 132px;
          overflow: auto;
          margin: 0;
          padding: 10px;
          border: 1px solid var(--border);
          border-radius: 8px;
          background: rgba(40,30,24,.16);
          color: var(--muted);
          font: 11px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
          white-space: pre-wrap;
        }
      </style>
    </head>
    <body>
      <main>
        <header>
          <h1>Realtime Voice</h1>
          <div class="status" id="status">idle</div>
        </header>

        <section class="orb" id="orb" aria-live="polite">
          <span id="orb-label">offline</span>
        </section>

        <section class="controls">
          <div class="row">
            <button id="start">Start</button>
            <button id="stop" disabled>Stop</button>
          </div>
          <button id="probe" disabled>Check today at 13:30</button>
          <pre id="log"></pre>
        </section>
      </main>

      <script>
        const accessToken = new URLSearchParams(window.location.search).get("token") || "";
        const statusEl = document.getElementById("status");
        const orb = document.getElementById("orb");
        const orbLabel = document.getElementById("orb-label");
        const logEl = document.getElementById("log");
        const startButton = document.getElementById("start");
        const stopButton = document.getElementById("stop");
        const probeButton = document.getElementById("probe");

        let pc;
        let dc;
        let localStream;
        let remoteAudio;
        let greeted = false;
        const handledCalls = new Set();

        function postStatus(message) {
          statusEl.textContent = message;
          if (window.webkit?.messageHandlers?.voiceStatus) {
            window.webkit.messageHandlers.voiceStatus.postMessage({ status: message });
          }
        }

        function log(line) {
          const stamp = new Date().toLocaleTimeString();
          logEl.textContent = `[${stamp}] ${line}\\n` + logEl.textContent;
        }

        function sendEvent(event) {
          if (!dc || dc.readyState !== "open") {
            throw new Error("Realtime data channel is not open");
          }
          dc.send(JSON.stringify(event));
        }

        function localEndpoint(path) {
          return `${path}?token=${encodeURIComponent(accessToken)}`;
        }

        function calendarTool() {
          return {
            type: "function",
            name: "check_calendar",
            description: "Check whether a requested calendar date and time is available.",
            parameters: {
              type: "object",
              additionalProperties: false,
              properties: {
                date: {
                  type: "string",
                  description: "Requested date, preferably YYYY-MM-DD."
                },
                time: {
                  type: "string",
                  description: "Requested local time, for example 09:00 or 2 PM."
                }
              },
              required: ["date", "time"]
            }
          };
        }

        async function registerTools() {
          const toolPayload = await fetch(localEndpoint("/tools")).then((response) => response.json());
          const orgoTools = Array.isArray(toolPayload.tools) ? toolPayload.tools : [];
          sendEvent({
            type: "session.update",
            session: {
              type: "realtime",
              instructions: "You are OS1 voice mode. Keep replies brief. When asked about calendar availability, call check_calendar. You also have Orgo MCP tools prefixed orgo_ for inspecting and controlling Orgo cloud computers. Prefer read/observe tools before taking actions, and summarize tool results plainly.",
              tool_choice: "auto",
              tools: [calendarTool(), ...orgoTools]
            }
          });
          log(`session.update registered check_calendar + ${orgoTools.length} Orgo MCP tools`);
          if (toolPayload.orgo?.status) log(toolPayload.orgo.status);
        }

        function greetOnce() {
          if (greeted) return;
          greeted = true;
          sendEvent({
            type: "response.create",
            response: {
              instructions: "Say exactly this sentence and nothing else: hello, can you hear me?"
            }
          });
          log("sent startup greeting");
        }

        function checkCalendar(args) {
          const date = String(args.date || "").trim();
          const time = String(args.time || "").trim();
          const normalized = `${date} ${time}`.toLowerCase();
          const busy = [
            "2026-05-08 09:00",
            "2026-05-08 13:30",
            "today 13:30",
            "today 1:30 pm",
            "tomorrow 15:00"
          ];
          const available = !busy.some((slot) => normalized.includes(slot));
          return {
            date,
            time,
            available,
            source: "sample_os1_calendar",
            message: available
              ? `The sample calendar is open at ${time} on ${date}.`
              : `The sample calendar is busy at ${time} on ${date}.`
          };
        }

        async function callOrgoTool(name, args) {
          const response = await fetch(localEndpoint("/tool"), {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ name, arguments: args })
          });
          const text = await response.text();
          let payload;
          try {
            payload = JSON.parse(text);
          } catch (_) {
            payload = { isError: true, content: [{ type: "text", text }] };
          }
          if (!response.ok) {
            payload.isError = true;
          }
          return payload;
        }

        async function handleFunctionCall(item) {
          if (!item?.call_id || handledCalls.has(item.call_id)) return;
          handledCalls.add(item.call_id);

          let args = {};
          try {
            args = JSON.parse(item.arguments || "{}");
          } catch (error) {
            args = {};
          }

          let output;
          if (item.name === "check_calendar") {
            output = checkCalendar(args);
            log(`check_calendar -> ${output.available ? "available" : "busy"}`);
          } else if (item.name?.startsWith("orgo_")) {
            output = await callOrgoTool(item.name, args);
            log(`${item.name} -> ${output.isError ? "error" : "ok"}`);
          } else {
            output = { isError: true, content: [{ type: "text", text: `Unknown function: ${item.name}` }] };
            log(`unknown function: ${item.name}`);
          }

          sendEvent({
            type: "conversation.item.create",
            item: {
              type: "function_call_output",
              call_id: item.call_id,
              output: JSON.stringify(output)
            }
          });
          sendEvent({ type: "response.create" });
        }

        async function handleRealtimeEvent(event) {
          if (event.type === "session.created") {
            log("session.created");
          } else if (event.type === "error") {
            log(`error: ${event.error?.message || JSON.stringify(event.error)}`);
          } else if (event.type === "response.done") {
            for (const item of event.response?.output || []) {
              if (item.type === "function_call") await handleFunctionCall(item);
            }
          } else if (event.type === "response.output_item.done" && event.item?.type === "function_call") {
            await handleFunctionCall(event.item);
          }
        }

        async function startVoice() {
          if (pc) return;
          startButton.disabled = true;
          postStatus("requesting microphone");
          orbLabel.textContent = "starting";

          pc = new RTCPeerConnection();
          remoteAudio = document.createElement("audio");
          remoteAudio.autoplay = true;
          document.body.appendChild(remoteAudio);

          pc.ontrack = (event) => {
            remoteAudio.srcObject = event.streams[0];
            orb.classList.add("connected");
            orbLabel.textContent = "online";
          };

          pc.onconnectionstatechange = () => {
            postStatus(pc.connectionState);
            orb.classList.toggle("connected", pc.connectionState === "connected");
          };

          localStream = await navigator.mediaDevices.getUserMedia({ audio: true });
          for (const track of localStream.getTracks()) {
            pc.addTrack(track, localStream);
          }

          dc = pc.createDataChannel("oai-events");
          dc.addEventListener("open", async () => {
            await registerTools();
            postStatus("listening");
            orb.classList.add("listening");
            orbLabel.textContent = "listening";
            stopButton.disabled = false;
            probeButton.disabled = false;
            greetOnce();
          });
          dc.addEventListener("message", (event) => {
            handleRealtimeEvent(JSON.parse(event.data)).catch((error) => log(`event failed: ${error.message}`));
          });

          const offer = await pc.createOffer();
          await pc.setLocalDescription(offer);

          const sdpResponse = await fetch(localEndpoint("/session"), {
            method: "POST",
            body: offer.sdp,
            headers: { "Content-Type": "application/sdp" }
          });

          const answerSdp = await sdpResponse.text();
          if (!sdpResponse.ok) {
            throw new Error(answerSdp || `Session endpoint failed: ${sdpResponse.status}`);
          }

          await pc.setRemoteDescription({ type: "answer", sdp: answerSdp });
          log("WebRTC answer applied");
        }

        function stopVoice(status = "stopped") {
          if (dc) dc.close();
          if (pc) pc.close();
          if (localStream) localStream.getTracks().forEach((track) => track.stop());
          if (remoteAudio) remoteAudio.remove();
          dc = undefined;
          pc = undefined;
          localStream = undefined;
          remoteAudio = undefined;
          greeted = false;
          handledCalls.clear();
          orb.classList.remove("connected", "listening");
          orbLabel.textContent = "offline";
          postStatus(status);
          startButton.disabled = false;
          stopButton.disabled = true;
          probeButton.disabled = true;
        }

        async function startVoiceSafely() {
          try {
            await startVoice();
          } catch (error) {
            const message = error?.message || String(error);
            log(`start failed: ${message}`);
            stopVoice(`error: ${message}`);
          }
        }

        startButton.addEventListener("click", startVoiceSafely);

        stopButton.addEventListener("click", stopVoice);

        probeButton.addEventListener("click", () => {
          sendEvent({
            type: "conversation.item.create",
            item: {
              type: "message",
              role: "user",
              content: [
                {
                  type: "input_text",
                  text: "Use check_calendar to see whether today at 13:30 is available."
                }
              ]
            }
          });
          sendEvent({ type: "response.create" });
          log("sent sample calendar probe");
        });

        postStatus("idle");
        setTimeout(startVoiceSafely, 250);
      </script>
    </body>
    </html>
    """
}

private struct HTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let body: Data

    init?(data: Data) {
        let marker = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: marker) else { return nil }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }

        let target = requestParts[1]
        let components = URLComponents(string: target)
        method = requestParts[0].uppercased()
        if let componentPath = components?.path, !componentPath.isEmpty {
            path = componentPath
        } else {
            path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
        }
        var parsedQueryItems: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value {
                parsedQueryItems[item.name] = value
            }
        }
        queryItems = parsedQueryItems
        self.headers = headers
        body = Data(data[bodyStart..<(bodyStart + contentLength)])
    }

    func hasAccessToken(_ expected: String) -> Bool {
        queryItems["token"] == expected || headers["x-os1-voice-token"] == expected
    }
}

private struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    var reasonPhrase: String {
        switch status {
        case 200..<300:
            "OK"
        case 400:
            "Bad Request"
        case 403:
            "Forbidden"
        case 404:
            "Not Found"
        case 413:
            "Payload Too Large"
        case 500:
            "Internal Server Error"
        case 502:
            "Bad Gateway"
        default:
            "HTTP"
        }
    }

    static func html(status: Int, body: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/html; charset=utf-8", body: Data(body.utf8))
    }

    static func plain(status: Int, body: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }
}

private struct RealtimeToolsResponse: Encodable {
    let tools: [RealtimeOrgoMCPTool]
    let orgo: RealtimeOrgoStatus
}

private struct RealtimeOrgoStatus: Encodable {
    let enabled: Bool
    let status: String
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
