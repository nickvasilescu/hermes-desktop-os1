import Foundation

/// One LLM provider that the Hermes agent on a remote host can be
/// pointed at. The Mac app's job is to manage the user's API key
/// (locally, in Keychain) and push it onto the host's
/// `~/.hermes/.env` + a matching entry in `~/.hermes/config.yaml`.
///
/// Two integration shapes:
///  - `.builtin(typeKey:)` — Hermes already knows this provider, so
///    setting the env var is enough (`hermes config set …`).
///  - `.customProvider(name:keyEnv:)` — Hermes treats it as an
///    OpenAI-compatible endpoint, so we also write a `custom_providers`
///    entry to `config.yaml` with `name`, `base_url`, `key_env`.
struct ProviderCatalogEntry: Identifiable, Equatable, Sendable {
    let slug: String
    let displayName: String
    let tagline: String
    let symbolName: String
    let keyPrefixHint: String
    let dashboardURL: URL
    let docsURL: URL?
    let envVar: String
    let baseURL: URL
    let kind: Kind
    let validation: Validation
    let supportsOAuth: Bool

    var id: String { slug }

    enum Kind: Equatable, Sendable {
        case builtin(typeKey: String)
        case customProvider(configName: String)
    }

    enum Validation: Equatable, Sendable {
        case modelsEndpoint(path: String)
        case skip(reason: String)
    }
}

/// Curated list of providers shipped with the app. Power users who want
/// something exotic can `hermes model` on the host directly — this UI
/// covers the common cases users have asked for.
enum ProviderCatalog {
    static let entries: [ProviderCatalogEntry] = [
        ProviderCatalogEntry(
            slug: "anthropic",
            displayName: "Anthropic",
            tagline: "Claude Opus, Sonnet, Haiku — Hermes' default home.",
            symbolName: "sparkle",
            keyPrefixHint: "sk-ant-…",
            dashboardURL: URL(string: "https://console.anthropic.com/settings/keys")!,
            docsURL: URL(string: "https://docs.anthropic.com/en/api/getting-started"),
            envVar: "ANTHROPIC_API_KEY",
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            kind: .builtin(typeKey: "anthropic"),
            // Anthropic doesn't expose a public list-models endpoint
            // unauthenticated — and the authenticated /v1/models exists
            // but isn't a good "is this key valid" probe because billing
            // can fail it independently. We rely on saving + reading-back.
            validation: .skip(reason: "Anthropic has no cheap key-probe endpoint."),
            supportsOAuth: false
        ),
        ProviderCatalogEntry(
            slug: "openrouter",
            displayName: "OpenRouter",
            tagline: "Sign in once and reach hundreds of models with cost-aware routing.",
            symbolName: "arrow.triangle.branch",
            keyPrefixHint: "sk-or-v1-…",
            dashboardURL: URL(string: "https://openrouter.ai/keys")!,
            docsURL: URL(string: "https://openrouter.ai/docs"),
            envVar: "OPENROUTER_API_KEY",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            kind: .builtin(typeKey: "openrouter"),
            validation: .modelsEndpoint(path: "/models"),
            supportsOAuth: true
        ),
        ProviderCatalogEntry(
            slug: "openai",
            displayName: "OpenAI",
            tagline: "GPT-5.2 family, including the Codex coding-tuned variants.",
            symbolName: "circle.hexagongrid",
            keyPrefixHint: "sk-…",
            dashboardURL: URL(string: "https://platform.openai.com/api-keys")!,
            docsURL: URL(string: "https://platform.openai.com/docs/api-reference/chat"),
            envVar: "OPENAI_API_KEY",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            kind: .customProvider(configName: "openai"),
            validation: .modelsEndpoint(path: "/models"),
            supportsOAuth: false
        ),
        ProviderCatalogEntry(
            slug: "fireworks",
            displayName: "Fireworks AI",
            tagline: "Fast hosted inference for open-weight models.",
            symbolName: "flame",
            keyPrefixHint: "fw-…",
            dashboardURL: URL(string: "https://app.fireworks.ai/users")!,
            docsURL: URL(string: "https://docs.fireworks.ai/api-reference/post-chatcompletions"),
            envVar: "FIREWORKS_API_KEY",
            baseURL: URL(string: "https://api.fireworks.ai/inference/v1")!,
            kind: .customProvider(configName: "fireworks"),
            validation: .modelsEndpoint(path: "/models"),
            supportsOAuth: false
        ),
        ProviderCatalogEntry(
            slug: "kimi",
            displayName: "Moonshot · Kimi",
            tagline: "Kimi K2.5 with up to 256K context, OpenAI-compatible.",
            symbolName: "moon.stars",
            keyPrefixHint: "sk-…",
            dashboardURL: URL(string: "https://platform.moonshot.ai/console/api-keys")!,
            docsURL: URL(string: "https://platform.kimi.ai/docs/api/overview"),
            envVar: "KIMI_API_KEY",
            baseURL: URL(string: "https://api.moonshot.ai/v1")!,
            kind: .builtin(typeKey: "kimi-coding"),
            validation: .modelsEndpoint(path: "/models"),
            supportsOAuth: false
        ),
        ProviderCatalogEntry(
            slug: "zai",
            displayName: "Z.AI · Zhipu",
            tagline: "GLM-4.6 / GLM-5 with thinking and multimodal modes.",
            symbolName: "atom",
            keyPrefixHint: "…",
            dashboardURL: URL(string: "https://z.ai/manage-apikey/apikey-list")!,
            docsURL: URL(string: "https://docs.z.ai/guides/overview/quick-start"),
            envVar: "ZAI_API_KEY",
            baseURL: URL(string: "https://api.z.ai/api/paas/v4")!,
            kind: .builtin(typeKey: "zai"),
            // Z.AI has /paas/v4/models per docs; we hit it relative to
            // the base URL so the path is "/models" (the suffix appends
            // to baseURL.path).
            validation: .modelsEndpoint(path: "/models"),
            supportsOAuth: false
        ),
        ProviderCatalogEntry(
            slug: "MiniMax",
            displayName: "MiniMax",
            tagline: "MiniMax-M2.7 — peak performance and ultimate value, 204K context.",
            symbolName: "bolt",
            keyPrefixHint: "eyJ…",
            dashboardURL: URL(string: "https://platform.minimax.io/user-center/basic-information/interface-key")!,
            docsURL: URL(string: "https://platform.minimax.io/docs/api-reference/text-openai-api"),
            envVar: "MINIMAX_API_KEY",
            baseURL: URL(string: "https://api.minimax.io/v1")!,
            kind: .customProvider(configName: "MiniMax"),
            validation: .modelsEndpoint(path: "/models"),
            supportsOAuth: false
        )
    ]

    static func entry(for slug: String) -> ProviderCatalogEntry? {
        entries.first(where: { $0.slug == slug })
    }
}

/// One model returned from a provider's `/models` endpoint after the
/// user connects. Catalogs vary widely across providers; we normalize
/// to id + display name so the picker can render uniformly.
struct ProviderModelSummary: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let displayName: String?
    let contextLength: Int?

    /// Provider-agnostic decoder. Different providers use different
    /// field names for "human label" — we try the most common ones
    /// (`name`, `display_name`) and fall back to `id`. Likewise for
    /// context length (`context_length`, `context_window`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try container.decode(String.self, forKey: .id)
        self.id = rawId

        let displayCandidate = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .displayName)
        self.displayName = displayCandidate

        self.contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
            ?? container.decodeIfPresent(Int.self, forKey: .contextWindow)
    }

    init(id: String, displayName: String? = nil, contextLength: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.contextLength = contextLength
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case displayName = "display_name"
        case contextLength = "context_length"
        case contextWindow = "context_window"
    }
}

/// Wire shape returned by every provider's `/models` endpoint we hit.
/// All five OpenAI-compatible providers wrap the list in `{ data: [...] }`
/// so we can share one decoder.
struct ProviderModelListResponse: Decodable, Equatable {
    let data: [ProviderModelSummary]
}
