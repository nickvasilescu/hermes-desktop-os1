import AppKit
import Combine
import Foundation
import SwiftUI

/// Lock-protected snapshot of the active connection's UUID. Mirrors
/// `AppState.activeConnectionID` so `@Sendable` closures (HTTP clients,
/// etc.) can read the current host without crossing the main actor on
/// every call.
final class ActiveConnectionSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?

    func get() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: UUID?) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedSection: AppSection = .connections
    @Published var activeAlert: AppAlert?
    @Published var isBusy = false
    @Published var statusMessage: String?
    @Published var overview: RemoteDiscovery?
    @Published var overviewError: String?
    @Published var isRefreshingOverview = false
    @Published var hermesInstallStatus: HermesInstallStatus = .idle
    @Published var hermesUpdateAvailability: HermesUpdateAvailability = .unknown
    @Published var hermesUpdateStatus: HermesUpdateStatus = .idle
    @Published var activeConnectionID: UUID?
    @Published var selectedSessionID: String?
    @Published var sessions: [SessionSummary] = []
    @Published var sessionMessages: [SessionMessage] = []
    @Published var sessionMessageDisplays: [SessionMessageDisplay] = []
    @Published var sessionsError: String?
    @Published var isLoadingSessions = false
    @Published var isRefreshingSessions = false
    @Published var isDeletingSession = false
    @Published var isSendingSessionMessage = false
    @Published var sessionConversationError: String?
    @Published var pendingSessionTurn: PendingSessionTurn?
    @Published var hasMoreSessions = false
    @Published var totalSessionsCount = 0
    @Published private(set) var sessionSearchQuery = ""
    @Published private(set) var sessionPinStateVersion = 0
    @Published var usageSummary: UsageSummary?
    @Published var usageProfileBreakdown: UsageProfileBreakdown?
    @Published var usageError: String?
    @Published var isLoadingUsage = false
    @Published var isRefreshingUsage = false
    @Published var selectedSkillID: String?
    @Published var skills: [SkillSummary] = []
    @Published var selectedSkillDetail: SkillDetail?
    @Published var skillsError: String?
    @Published var isLoadingSkills = false
    @Published var isRefreshingSkills = false
    @Published var isLoadingSkillDetail = false
    @Published var isSavingSkillDraft = false
    @Published var knowledgeVault: KnowledgeVaultSummary?
    @Published var knowledgeSkillInstalled = false
    @Published var knowledgeBaseError: String?
    @Published var isLoadingKnowledgeBase = false
    @Published var isRefreshingKnowledgeBase = false
    @Published var isUploadingKnowledgeBase = false
    @Published var isRemovingKnowledgeBase = false
    @Published var cronJobs: [CronJob] = []
    @Published var selectedCronJobID: String?
    @Published var cronJobsError: String?
    @Published var isLoadingCronJobs = false
    @Published var isRefreshingCronJobs = false
    @Published var isOperatingOnCronJob = false
    @Published var operatingCronJobID: String?
    @Published var isSavingCronJobDraft = false
    @Published var kanbanBoard: KanbanBoard?
    @Published var selectedKanbanTaskID: String?
    @Published var selectedKanbanTaskDetail: KanbanTaskDetail?
    @Published var kanbanError: String?
    @Published var isLoadingKanbanBoard = false
    @Published var isRefreshingKanbanBoard = false
    @Published var isLoadingKanbanTaskDetail = false
    @Published var isOperatingOnKanbanTask = false
    @Published var operatingKanbanTaskID: String?
    @Published var isSavingKanbanTaskDraft = false
    @Published var isDispatchingKanban = false
    @Published var includeArchivedKanbanTasks = false
    @Published var selectedWorkspaceFileID: String = RemoteTrackedFile.memory.workspaceFileID
    @Published var workspaceFileDocuments: [String: FileEditorDocument] = [:]
    @Published var workspaceFileBrowserListing: RemoteDirectoryListing?
    @Published var workspaceFileBrowserError: String?
    @Published var isLoadingWorkspaceFileBrowser = false
    @Published var pendingSectionSelection: AppSection?
    @Published var showDiscardChangesAlert = false
    @Published var pendingNewConnectionEditorRequestID: UUID?
    @Published var isRealtimeVoiceEnabled = true
    @Published var realtimeVoiceStatus = "starting"

    let connectionStore: ConnectionStore
    let sshTransport: SSHTransport
    let orgoTransport: OrgoTransport
    let orgoCredentialStore: OrgoCredentialStore
    let orgoCatalogService: OrgoCatalogService
    let orgoHermesInstaller: OrgoHermesInstaller
    let hermesUpdater: HermesUpdater
    let transport: any RemoteTransport
    let remoteHermesService: RemoteHermesService
    let fileEditorService: FileEditorService
    let sessionBrowserService: SessionBrowserService
    let hermesChatService: HermesChatService
    let usageBrowserService: UsageBrowserService
    let skillBrowserService: SkillBrowserService
    let knowledgeBaseService: KnowledgeBaseService
    let cronBrowserService: CronBrowserService
    let kanbanBrowserService: KanbanBrowserService
    let terminalWorkspace: TerminalWorkspaceStore
    let agentMailCredentialStore: AgentMailCredentialStore
    let agentMailAccountStore: AgentMailAccountStore
    let agentMailVMScanner: AgentMailVMScanner
    let agentMailRealtimeService: AgentMailRealtimeService
    let mailSetupViewModel: MailSetupViewModel
    let mailInboxViewModel: MailInboxViewModel
    let composioCredentialStore: ComposioCredentialStore
    let composioVMInstaller: ComposioVMInstaller
    let composioUserIdentity: ComposioUserIdentity
    let composioToolkitService: ComposioToolkitService
    let connectorsViewModel: ConnectorsViewModel

    let providerCredentialStore: ProviderCredentialStore
    let providerVMInstaller: ProviderVMInstaller
    let openRouterOAuthService: OpenRouterOAuthService
    let providersViewModel: ProvidersViewModel

    let telegramCredentialStore: TelegramCredentialStore
    let telegramVMInstaller: TelegramVMInstaller
    let messagingViewModel: MessagingViewModel
    let doctorViewModel: DoctorViewModel

    private let activeConnectionSnapshot = ActiveConnectionSnapshot()

    private let sessionPageSize = 50
    private var sessionOffset = 0
    private var pendingSessionReloadQuery: String?
    private var sessionMessageSignature = SessionMessageSignature(messages: [])
    private var connectionTestRequestID: UUID?
    private var statusTask: Task<Void, Never>?
    private var sessionTranscriptPollingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let paths = AppPaths()
        let connectionStore = ConnectionStore(paths: paths)
        let sshTransport = SSHTransport(paths: paths)
        let orgoCredentialStore = OrgoCredentialStore()
        let orgoApiKeyProvider: @Sendable () -> String? = { [weak orgoCredentialStore] in
            orgoCredentialStore?.loadAPIKey()
        }
        let orgoTransport = OrgoTransport(apiKeyProvider: orgoApiKeyProvider)
        let orgoCatalogService = OrgoCatalogService(
            httpClient: OrgoHTTPClient(apiKeyProvider: orgoApiKeyProvider)
        )
        let orgoHermesInstaller = OrgoHermesInstaller(transport: orgoTransport)
        let transport = MultiplexedRemoteTransport(ssh: sshTransport, orgo: orgoTransport)
        let hermesUpdater = HermesUpdater(orgoTransport: orgoTransport, multiplexed: transport)

        self.connectionStore = connectionStore
        self.sshTransport = sshTransport
        self.orgoTransport = orgoTransport
        self.orgoCredentialStore = orgoCredentialStore
        self.orgoCatalogService = orgoCatalogService
        self.orgoHermesInstaller = orgoHermesInstaller
        self.hermesUpdater = hermesUpdater
        self.transport = transport
        self.remoteHermesService = RemoteHermesService(transport: transport)
        self.fileEditorService = FileEditorService(transport: transport)
        self.sessionBrowserService = SessionBrowserService(transport: transport)
        self.hermesChatService = HermesChatService(transport: transport)
        self.usageBrowserService = UsageBrowserService(transport: transport)
        self.skillBrowserService = SkillBrowserService(transport: transport)
        self.knowledgeBaseService = KnowledgeBaseService(transport: transport)
        self.cronBrowserService = CronBrowserService(transport: transport)
        self.kanbanBrowserService = KanbanBrowserService(transport: transport)
        self.terminalWorkspace = TerminalWorkspaceStore(
            sshTransport: sshTransport,
            orgoTransport: orgoTransport
        )
        let credentialStore = AgentMailCredentialStore()
        let accountStore = AgentMailAccountStore()
        let agentMailVMScanner = AgentMailVMScanner(
            orgoTransport: orgoTransport,
            multiplexed: transport
        )
        self.agentMailCredentialStore = credentialStore
        self.agentMailAccountStore = accountStore
        self.agentMailVMScanner = agentMailVMScanner
        self.mailSetupViewModel = MailSetupViewModel(
            credentialStore: credentialStore,
            accountStore: accountStore,
            vmScanner: agentMailVMScanner
        )
        let agentMailRealtime = AgentMailRealtimeService()
        self.agentMailRealtimeService = agentMailRealtime
        self.mailInboxViewModel = MailInboxViewModel(
            credentialStore: credentialStore,
            accountStore: accountStore,
            realtimeService: agentMailRealtime
        )

        let composioCredentialStore = ComposioCredentialStore()
        let composioVMInstaller = ComposioVMInstaller(
            orgoTransport: orgoTransport,
            multiplexed: transport
        )
        // Provider reads the active connection from a thread-safe
        // snapshot at call time and resolves its profile-scoped key
        // (with default fallback). Means every Composio API call
        // automatically targets the right key for whichever host is
        // currently selected — no explicit swap step needed when the
        // user changes connections.
        let snapshot = activeConnectionSnapshot
        let composioAPIKeyProvider: @Sendable () -> String? = { [weak composioCredentialStore] in
            guard let composioCredentialStore else { return nil }
            let profileId = snapshot.get()?.uuidString
            return composioCredentialStore.loadAPIKey(forProfileId: profileId)
        }
        let composioMCPClient = ComposioMCPClient(apiKeyProvider: composioAPIKeyProvider)
        let composioToolkitService = ComposioToolkitService(mcp: composioMCPClient)
        let composioUserIdentity = ComposioUserIdentity()
        self.composioCredentialStore = composioCredentialStore
        self.composioVMInstaller = composioVMInstaller
        self.composioUserIdentity = composioUserIdentity
        self.composioToolkitService = composioToolkitService
        self.connectorsViewModel = ConnectorsViewModel(
            credentialStore: composioCredentialStore,
            installer: composioVMInstaller,
            toolkitService: composioToolkitService,
            urlOpener: { url in
                // Composio OAuth flows happen in the user's default
                // browser. We discard the success Bool — the polling
                // loop that follows tells us whether the user actually
                // completed the auth.
                _ = NSWorkspace.shared.open(url)
            }
        )

        let providerCredentialStore = ProviderCredentialStore()
        let providerVMInstaller = ProviderVMInstaller(
            orgoTransport: orgoTransport,
            multiplexed: transport
        )
        let openRouterOAuthService = OpenRouterOAuthService()
        self.providerCredentialStore = providerCredentialStore
        self.providerVMInstaller = providerVMInstaller
        self.openRouterOAuthService = openRouterOAuthService
        self.providersViewModel = ProvidersViewModel(
            credentialStore: providerCredentialStore,
            installer: providerVMInstaller,
            oauthService: openRouterOAuthService,
            urlOpener: { url in
                // Provider dashboard "Get key" links open in the
                // default browser; the OAuth dance for OpenRouter is
                // handled inside OpenRouterOAuthService directly so
                // we don't need a separate hop here.
                _ = NSWorkspace.shared.open(url)
            }
        )

        let telegramCredentialStore = TelegramCredentialStore()
        let telegramVMInstaller = TelegramVMInstaller(
            orgoTransport: orgoTransport,
            multiplexed: transport
        )
        self.telegramCredentialStore = telegramCredentialStore
        self.telegramVMInstaller = telegramVMInstaller
        self.messagingViewModel = MessagingViewModel(
            credentialStore: telegramCredentialStore,
            installer: telegramVMInstaller
        )
        self.doctorViewModel = DoctorViewModel(
            credentialStore: telegramCredentialStore,
            telegramInstaller: telegramVMInstaller,
            hermesUpdater: hermesUpdater
        )
        // Wire DoctorViewModel <-> AppState bridge after both exist:
        // when Doctor probes availability it forwards the result to
        // AppState (so the Overview banner sees the same value), and
        // its Update action calls AppState.performHermesUpdate so the
        // running spinner shows on both surfaces.
        self.doctorViewModel.bindHermesUpdateBridge(
            performUpdate: { [weak self] in
                await self?.performHermesUpdate()
            },
            publishAvailability: { [weak self] availability in
                self?.hermesUpdateAvailability = availability
            }
        )

        connectionStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        connectionStore.$persistenceError
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.activeAlert = AppAlert(
                    title: L10n.string("Local storage error"),
                    message: message
                )
                self?.setStatusMessage(L10n.string("Local storage error"))
            }
            .store(in: &cancellables)

        self.activeConnectionID = connectionStore.lastConnectionID
        self.activeConnectionSnapshot.set(self.activeConnectionID)

        // Mirror future changes into the Sendable snapshot so credential
        // providers running off the main actor (URLSession callbacks,
        // background tasks) always see a fresh value.
        $activeConnectionID
            .sink { [weak self] newId in
                self?.activeConnectionSnapshot.set(newId)
            }
            .store(in: &cancellables)

        if activeConnectionID != nil {
            selectedSection = .overview
        }
    }

    var activeConnection: ConnectionProfile? {
        guard let activeConnectionID else { return nil }
        return connectionStore.connections.first(where: { $0.id == activeConnectionID })
    }

    var canonicalWorkspaceFileReferences: [WorkspaceFileReference] {
        guard let activeConnection else { return [] }

        return RemoteTrackedFile.allCases.map { trackedFile in
            WorkspaceFileReference.canonical(
                trackedFile,
                remotePath: resolvedRemotePath(for: trackedFile, connection: activeConnection)
            )
        }
    }

    var bookmarkedWorkspaceFileReferences: [WorkspaceFileReference] {
        guard let activeConnection else { return [] }

        return connectionStore
            .bookmarks(for: activeConnection.workspaceScopeFingerprint)
            .map(WorkspaceFileReference.bookmark)
    }

    var bookmarkedWorkspaceFileGroups: [WorkspaceFileBookmarkGroup] {
        WorkspaceFileBookmarkGroup.groups(for: bookmarkedWorkspaceFileReferences)
    }

    var workspaceFileReferences: [WorkspaceFileReference] {
        canonicalWorkspaceFileReferences + bookmarkedWorkspaceFileReferences
    }

    var pinnedSessionSummaries: [SessionSummary] {
        guard let activeConnection else { return [] }

        return connectionStore
            .pinnedSessions(for: activeConnection.workspaceScopeFingerprint)
            .map { pinnedSession in
                sessions.first(where: { $0.id == pinnedSession.id }) ?? pinnedSession.summary
            }
    }

    var unpinnedSessions: [SessionSummary] {
        guard let activeConnection else { return sessions }
        let pinnedIDs = Set(
            connectionStore
                .pinnedSessions(for: activeConnection.workspaceScopeFingerprint)
                .map(\.id)
        )
        return sessions.filter { !pinnedIDs.contains($0.id) }
    }

    var selectedWorkspaceFileReference: WorkspaceFileReference? {
        workspaceFileReferences.first { $0.id == selectedWorkspaceFileID } ??
            workspaceFileReferences.first
    }

    var workspaceFileBrowserDefaultPath: String {
        overview?.hermesHome ?? activeConnection?.remoteHermesHomePath ?? "~"
    }

    var hasUnsavedFileChanges: Bool {
        workspaceFileDocuments.values.contains { $0.isDirty }
    }

    var canRefreshCurrentSection: Bool {
        guard activeConnection != nil else { return false }

        switch selectedSection {
        case .overview:
            return !isRefreshingOverview && !isBusy
        case .sessions:
            return !isLoadingSessions && !isRefreshingSessions
        case .cronjobs:
            return !isLoadingCronJobs && !isRefreshingCronJobs
        case .kanban:
            return !isLoadingKanbanBoard && !isRefreshingKanbanBoard
        case .usage:
            return !isLoadingUsage && !isRefreshingUsage
        case .skills:
            return !isLoadingSkills && !isRefreshingSkills
        case .knowledgeBase:
            return !isLoadingKnowledgeBase && !isRefreshingKnowledgeBase
        case .connections, .files, .terminal, .desktop, .mail, .messaging, .connectors, .providers, .doctor:
            return false
        }
    }

    var canSaveCurrentWorkspaceFile: Bool {
        guard selectedSection == .files else { return false }
        guard let document = workspaceFileDocuments[selectedWorkspaceFileID] else { return false }
        return document.hasLoaded && document.isDirty && !document.isLoading
    }

    func isSectionAvailable(_ section: AppSection) -> Bool {
        if section == .connections { return true }
        guard let connection = activeConnection else { return false }
        // Desktop (VNC) is only meaningful for Orgo VMs.
        if section == .desktop {
            if case .orgo = connection.transport { return true }
            return false
        }
        return true
    }

    func requestSectionSelection(_ section: AppSection) {
        guard selectedSection != section else { return }
        guard section != .files || activeConnection != nil else {
            selectedSection = .connections
            return
        }
        if section == .terminal,
           let activeConnection,
           activeConnection.validationError != nil {
            setStatusMessage(L10n.string("Please fix this connection before opening a terminal tab."))
            return
        }
        if section == .terminal, activeConnection == nil {
            selectedSection = .connections
            setStatusMessage(L10n.string("Select a connection before opening Terminal."))
            return
        }

        if hasUnsavedFileChanges && selectedSection == .files {
            pendingSectionSelection = section
            showDiscardChangesAlert = true
            return
        }

        selectedSection = section
        handleSectionEntry(section)
    }

    func requestNewConnectionEditorFromCommand() {
        requestSectionSelection(.connections)
        guard selectedSection == .connections else { return }
        pendingNewConnectionEditorRequestID = UUID()
    }

    func consumeNewConnectionEditorRequest(_ requestID: UUID) {
        guard pendingNewConnectionEditorRequestID == requestID else { return }
        pendingNewConnectionEditorRequestID = nil
    }

    func requestNewSessionFromCommand() {
        guard activeConnection != nil, !isSendingSessionMessage else { return }
        requestSectionSelection(.sessions)
        guard selectedSection == .sessions else { return }
        prepareNewSessionComposer()
    }

    func openNewTerminalTabFromCommand() {
        guard let profile = activeConnection, profile.validationError == nil else {
            setStatusMessage(L10n.string("Please fix this connection before opening a terminal tab."))
            return
        }
        terminalWorkspace.addTab(for: profile.updated())
        selectedSection = .terminal
        handleSectionEntry(.terminal)
        setStatusMessage(L10n.string("New Terminal tab opened"))
    }

    func toggleRealtimeVoiceMode() {
        isRealtimeVoiceEnabled.toggle()
        realtimeVoiceStatus = isRealtimeVoiceEnabled ? "starting" : "off"
    }

    func updateRealtimeVoiceStatus(_ status: String) {
        realtimeVoiceStatus = status
    }

    func refreshCurrentSectionFromCommand() async {
        guard canRefreshCurrentSection else { return }

        switch selectedSection {
        case .overview:
            await refreshOverview(manual: true)
        case .sessions:
            await refreshSessions(query: sessionSearchQuery)
        case .cronjobs:
            await refreshCronJobs()
        case .kanban:
            await refreshKanbanBoard()
        case .usage:
            await refreshUsage()
        case .skills:
            await refreshSkills()
        case .knowledgeBase:
            await refreshKnowledgeBase()
        case .connections, .files, .terminal, .desktop, .mail, .messaging, .connectors, .providers, .doctor:
            break
        }
    }

    func discardChangesAndContinue() {
        for fileID in Array(workspaceFileDocuments.keys) {
            var document = workspaceFileDocuments[fileID]
            document?.discardChanges()
            workspaceFileDocuments[fileID] = document
        }
        if let pendingSectionSelection {
            selectedSection = pendingSectionSelection
            handleSectionEntry(pendingSectionSelection)
        }
        pendingSectionSelection = nil
    }

    func stayOnCurrentSection() {
        pendingSectionSelection = nil
    }

    func connect(to profile: ConnectionProfile) {
        let isSwitchingConnection = activeConnection?.workspaceScopeFingerprint != profile.workspaceScopeFingerprint

        if isSwitchingConnection {
            resetWorkspaceStateForConnectionChange()
        }

        activeConnectionID = profile.id
        connectionStore.lastConnectionID = profile.id
        var updatedProfile = profile
        updatedProfile.lastConnectedAt = Date()
        connectionStore.upsert(updatedProfile)
        selectedSection = .overview
        setStatusMessage(L10n.string("Connecting to %@…", profile.label))

        Task {
            await prepareWorkspaceForActiveConnection()
        }
    }

    func saveConnection(_ profile: ConnectionProfile) {
        let normalized = profile.updated()
        let previous = connectionStore.connections.first(where: { $0.id == normalized.id })
        let isActiveConnection = activeConnectionID == normalized.id
        let isChangingWorkspaceScope = previous?.workspaceScopeFingerprint != normalized.workspaceScopeFingerprint

        if isActiveConnection && isChangingWorkspaceScope && hasUnsavedFileChanges {
            activeAlert = AppAlert(
                title: L10n.string("Unsaved file edits"),
                message: L10n.string("Save or discard Workspace Files edits before switching the Hermes profile for the active host.")
            )
            return
        }

        connectionStore.upsert(normalized)

        guard isActiveConnection else { return }
        guard isChangingWorkspaceScope else { return }

        resetWorkspaceStateForConnectionChange()
        selectedSection = .overview
        setStatusMessage(L10n.string("Refreshing %@…", normalized.label))

        Task {
            await prepareWorkspaceForActiveConnection()
        }
    }

    func switchHermesProfile(to profileName: String) async {
        guard let activeConnection else { return }
        guard activeConnection.resolvedHermesProfileName != profileName else { return }

        if hasUnsavedFileChanges {
            activeAlert = AppAlert(
                title: L10n.string("Unsaved file edits"),
                message: L10n.string("Save or discard Workspace Files edits before switching Hermes profiles.")
            )
            return
        }

        let updatedConnection = activeConnection.applyingHermesProfile(named: profileName)
        let shouldCarryTerminalWorkspace = selectedSection == .terminal || terminalWorkspace.hasTabs

        if shouldCarryTerminalWorkspace {
            terminalWorkspace.ensureInitialTab(for: updatedConnection)
        }

        connectionStore.upsert(updatedConnection)
        await reloadWorkspaceScope(
            section: selectedSection,
            statusMessage: L10n.string("Switching to %@…", profileName)
        )
    }

    func testConnection(_ profile: ConnectionProfile) {
        let requestID = UUID()
        connectionTestRequestID = requestID

        Task {
            do {
                isBusy = true
                setStatusMessage(L10n.string("Testing %@…", profile.label))

                let script = try RemotePythonScript.wrap(
                    ConnectionTestRequest(),
                    body: """
                    import json
                    import pathlib
                    import sys

                    print(json.dumps({
                        "ok": True,
                        "remote_home": str(pathlib.Path.home()),
                        "python_executable": sys.executable,
                    }, ensure_ascii=False))
                    """
                )

                let response = try await transport.executeJSON(
                    on: profile,
                    pythonScript: script,
                    responseType: ConnectionTestResponse.self
                )

                guard connectionTestRequestID == requestID else { return }
                isBusy = false
                let home = response.remoteHome.trimmingCharacters(in: .whitespacesAndNewlines)
                setStatusMessage(L10n.string("SSH and python3 OK for %@", profile.label))
                let messageLines = [
                    L10n.string("SSH and python3 are available for this Hermes host."),
                    home.isEmpty ? nil : L10n.string("Remote HOME: %@", home)
                ].compactMap { $0 }
                activeAlert = AppAlert(
                    title: L10n.string("Connection OK"),
                    message: messageLines.joined(separator: "\n")
                )
            } catch {
                guard connectionTestRequestID == requestID else { return }
                isBusy = false
                activeAlert = AppAlert(
                    title: L10n.string("Connection failed"),
                    message: error.localizedDescription
                )
            }
        }
    }

    func refreshOverview(manual: Bool = false) async {
        guard let profile = activeConnection else { return }
        if manual {
            guard !isRefreshingOverview, !isBusy else { return }
            isRefreshingOverview = true
        }

        do {
            isBusy = true
            overviewError = nil
            let discovery = try await remoteHermesService.discover(connection: profile)
            guard isActiveWorkspace(profile) else { return }
            overview = discovery
            isBusy = false
            if manual {
                isRefreshingOverview = false
            }
            // Piggyback the update check off discovery — it's the natural
            // moment to learn the host's Hermes state, and Overview is
            // where the "update available" banner shows up. Cheap (reads
            // ~/.hermes/.update_check), so safe to do here.
            Task { await refreshHermesUpdateAvailability() }
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isBusy = false
            if manual {
                isRefreshingOverview = false
            }
            overview = nil
            overviewError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to refresh remote discovery"))
        }
    }

    /// Runs the Hermes Agent installer on the active Orgo connection. Refuses
    /// when the active connection isn't Orgo or when an install is already
    /// running. On success, transitions back to .idle and refreshes the
    /// overview so the install banner disappears and feature panels can
    /// populate. On failure, captures stderr_tail for the UI to surface.
    @MainActor
    func installHermesOnActiveOrgoConnection() async {
        guard let profile = activeConnection else { return }
        guard case .orgo = profile.transport else { return }
        if case .running = hermesInstallStatus { return }

        hermesInstallStatus = .running
        setStatusMessage(L10n.string("Installing Hermes Agent on the Orgo VM…"))

        do {
            let result = try await orgoHermesInstaller.installHermes(on: profile)
            guard isActiveWorkspace(profile) else { return }
            if result.succeeded {
                hermesInstallStatus = .idle
                setStatusMessage(L10n.string("Hermes Agent installed."))
                await refreshOverview(manual: true)
                // Probe version + update availability now that hermes is on the
                // host. install.sh installs from `main`, so this is normally a
                // .upToDate, but the cache check is cheap and primes the UI.
                await refreshHermesUpdateAvailability()
            } else {
                // Prefer stderr_tail; fall back to stdout_tail because some
                // installers (and our own clock-sync wrapper) print failure
                // diagnostics to stdout, not stderr.
                let stderrTail = result.stderrTail
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stdoutTail = result.stdoutTail
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail: String
                if !stderrTail.isEmpty {
                    detail = stderrTail
                } else if !stdoutTail.isEmpty {
                    detail = stdoutTail
                } else {
                    detail = "Installer exited \(result.exitCode) with no output."
                }
                hermesInstallStatus = .failed(message: detail)
                setStatusMessage(L10n.string("Hermes installer failed."))
            }
        } catch {
            guard isActiveWorkspace(profile) else { return }
            hermesInstallStatus = .failed(message: error.localizedDescription)
            setStatusMessage(L10n.string("Hermes installer failed."))
        }
    }

    @MainActor
    func dismissHermesInstallError() {
        if case .failed = hermesInstallStatus {
            hermesInstallStatus = .idle
        }
    }

    /// Probes the active host for the installed Hermes version and whether
    /// an update is available. Cheap (reads the cache file Hermes itself
    /// writes); safe to call on every Doctor refresh and after a successful
    /// install/update. Silently no-ops if no host is active or an update is
    /// in flight (the in-flight status is the more useful signal).
    @MainActor
    func refreshHermesUpdateAvailability() async {
        guard let profile = activeConnection else { return }
        if case .running = hermesUpdateStatus { return }

        do {
            let result = try await hermesUpdater.checkAvailability(on: profile)
            guard isActiveWorkspace(profile) else { return }
            if !result.installed {
                hermesUpdateAvailability = .notInstalled
                return
            }
            let label = result.version_label ?? L10n.string("Hermes Agent")
            switch result.behind {
            case .some(0):
                hermesUpdateAvailability = .upToDate(versionLabel: label)
            case .some(let n) where n > 0:
                hermesUpdateAvailability = .behind(versionLabel: label, commits: n)
            case .some(-1):
                // Behind, count unknown — `hermes update --check` exited 1
                // but we didn't parse stdout for an exact number.
                hermesUpdateAvailability = .behind(versionLabel: label, commits: nil)
            default:
                // Probe couldn't determine state (no git repo, network
                // failure on Nix builds, etc.). We still know hermes is
                // installed; treat as up-to-date so the UI doesn't nag.
                hermesUpdateAvailability = .upToDate(versionLabel: label)
            }
        } catch {
            // Don't surface transport errors here — the Doctor tab's
            // gateway check handles host-unreachable. Leave availability
            // .unknown so the banner stays hidden.
        }
    }

    /// Runs `hermes update --backup` on the active host. Surfaces a running
    /// state for the Overview banner / Doctor row spinner; on success
    /// re-probes availability and the overview so any new version + restarted
    /// gateway show up immediately.
    @MainActor
    func performHermesUpdate() async {
        guard let profile = activeConnection else { return }
        if case .running = hermesUpdateStatus { return }

        hermesUpdateStatus = .running
        setStatusMessage(L10n.string("Updating Hermes Agent…"))

        do {
            let result = try await hermesUpdater.performUpdate(on: profile)
            guard isActiveWorkspace(profile) else { return }
            if result.succeeded {
                hermesUpdateStatus = .idle
                setStatusMessage(L10n.string("Hermes Agent updated."))
                await refreshHermesUpdateAvailability()
                await refreshOverview(manual: true)
            } else {
                let stderrTail = result.stderr_tail
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stdoutTail = result.stdout_tail
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let detail: String
                if !stderrTail.isEmpty {
                    detail = stderrTail
                } else if !stdoutTail.isEmpty {
                    detail = stdoutTail
                } else {
                    detail = "hermes update exited \(result.exit_code) with no output."
                }
                hermesUpdateStatus = .failed(message: detail, logTail: result.log_tail)
                setStatusMessage(L10n.string("Hermes update failed."))
            }
        } catch {
            guard isActiveWorkspace(profile) else { return }
            hermesUpdateStatus = .failed(message: error.localizedDescription, logTail: nil)
            setStatusMessage(L10n.string("Hermes update failed."))
        }
    }

    @MainActor
    func dismissHermesUpdateError() {
        if case .failed = hermesUpdateStatus {
            hermesUpdateStatus = .idle
        }
    }

    func refreshSessions(query: String? = nil) async {
        guard !isLoadingSessions, !isRefreshingSessions else { return }
        isRefreshingSessions = true
        await loadSessions(reset: true, query: query)
        isRefreshingSessions = false
    }

    func refreshUsage() async {
        guard !isLoadingUsage, !isRefreshingUsage else { return }
        isRefreshingUsage = true
        await loadUsage(forceRefresh: true)
        isRefreshingUsage = false
    }

    func refreshSkills() async {
        guard !isLoadingSkills, !isRefreshingSkills else { return }
        isRefreshingSkills = true
        await loadSkills(reset: true)
        isRefreshingSkills = false
    }

    func refreshCronJobs() async {
        guard !isLoadingCronJobs, !isRefreshingCronJobs else { return }
        isRefreshingCronJobs = true
        await loadCronJobs()
        isRefreshingCronJobs = false
    }

    func refreshKanbanBoard(includeArchived: Bool? = nil) async {
        guard !isLoadingKanbanBoard, !isRefreshingKanbanBoard else { return }
        isRefreshingKanbanBoard = true
        await loadKanbanBoard(includeArchived: includeArchived)
        isRefreshingKanbanBoard = false
    }

    func workspaceFileDocument(for fileID: String) -> FileEditorDocument? {
        workspaceFileDocuments[fileID]
    }

    func selectWorkspaceFile(_ fileID: String) {
        guard workspaceFileReferences.contains(where: { $0.id == fileID }) else { return }
        selectedWorkspaceFileID = fileID
    }

    func loadSelectedWorkspaceFile(forceReload: Bool = false) async {
        guard let reference = selectedWorkspaceFileReference else { return }
        selectedWorkspaceFileID = reference.id
        await loadWorkspaceFile(reference, forceReload: forceReload)
    }

    func loadWorkspaceFile(_ reference: WorkspaceFileReference, forceReload: Bool = false) async {
        guard let profile = activeConnection else { return }
        var document = document(for: reference)

        if document.hasLoaded && !forceReload {
            setDocument(document)
            return
        }

        document.isLoading = true
        document.errorMessage = nil
        setDocument(document)

        do {
            let snapshot = try await fileEditorService.read(
                remotePath: reference.remotePath,
                connection: profile
            )
            guard isActiveWorkspace(profile) else { return }
            document.content = snapshot.content
            document.originalContent = snapshot.content
            document.remoteContentHash = snapshot.contentHash
            document.lastSavedAt = nil
            document.errorMessage = nil
            document.isLoading = false
            document.hasLoaded = true
            setDocument(document)
        } catch {
            guard isActiveWorkspace(profile) else { return }
            document.isLoading = false
            document.errorMessage = error.localizedDescription
            setDocument(document)
        }
    }

    func saveSelectedWorkspaceFile() async {
        await saveWorkspaceFile(fileID: selectedWorkspaceFileID)
    }

    func saveWorkspaceFile(fileID: String) async {
        guard let profile = activeConnection else { return }
        guard let reference = workspaceFileReferences.first(where: { $0.id == fileID }) else { return }
        var document = document(for: reference)
        guard document.hasLoaded, document.remoteContentHash != nil else {
            document.errorMessage = L10n.string("Reload the file before saving.")
            setDocument(document)
            setStatusMessage(document.errorMessage)
            return
        }

        document.isLoading = true
        document.errorMessage = nil
        setDocument(document)

        do {
            let saveResult = try await fileEditorService.write(
                remotePath: reference.remotePath,
                content: document.content,
                expectedContentHash: document.remoteContentHash,
                connection: profile
            )
            guard isActiveWorkspace(profile) else { return }
            document.originalContent = document.content
            document.remoteContentHash = saveResult.contentHash
            document.lastSavedAt = Date()
            document.hasLoaded = true
            document.isLoading = false
            setDocument(document)
            setStatusMessage(L10n.string("%@ saved", reference.title))
        } catch {
            guard isActiveWorkspace(profile) else { return }
            document.isLoading = false
            document.errorMessage = error.localizedDescription
            setDocument(document)
            setStatusMessage(error.localizedDescription)
        }
    }

    func updateWorkspaceFile(_ fileID: String, content: String) {
        guard let reference = workspaceFileReferences.first(where: { $0.id == fileID }) else { return }
        var document = document(for: reference)
        document.content = content
        setDocument(document)
    }

    func discardWorkspaceFile(_ fileID: String) {
        var document = workspaceFileDocuments[fileID]
        document?.discardChanges()
        workspaceFileDocuments[fileID] = document
    }

    @discardableResult
    func addWorkspaceFileBookmark(
        remotePath: String,
        title: String? = nil,
        selectAfterAdd: Bool = true
    ) -> WorkspaceFileBookmark? {
        guard let activeConnection else { return nil }
        guard let bookmark = connectionStore.upsertWorkspaceFileBookmark(
            remotePath: remotePath,
            title: title,
            workspaceScopeFingerprint: activeConnection.workspaceScopeFingerprint
        ) else {
            return nil
        }

        let reference = WorkspaceFileReference.bookmark(bookmark)
        if selectAfterAdd {
            selectedWorkspaceFileID = reference.id
            workspaceFileDocuments[reference.id] = workspaceFileDocuments[reference.id] ??
                FileEditorDocument(fileID: reference.id, title: reference.title, remotePath: reference.remotePath)
        }
        setStatusMessage(L10n.string("%@ added to Workspace Files", reference.title))
        return bookmark
    }

    func removeWorkspaceFileBookmark(id: UUID) {
        connectionStore.removeWorkspaceFileBookmark(id: id)
        workspaceFileDocuments.removeValue(forKey: "bookmark:\(id.uuidString)")

        if selectedWorkspaceFileID == "bookmark:\(id.uuidString)" {
            selectedWorkspaceFileID = RemoteTrackedFile.memory.workspaceFileID
        }

        setStatusMessage(L10n.string("Bookmark removed"))
    }

    func isSessionPinned(_ sessionID: String) -> Bool {
        guard let activeConnection else { return false }
        return connectionStore.isSessionPinned(
            id: sessionID,
            workspaceScopeFingerprint: activeConnection.workspaceScopeFingerprint
        )
    }

    func pinSession(_ session: SessionSummary) {
        guard let activeConnection else { return }
        connectionStore.upsertPinnedSession(
            session,
            workspaceScopeFingerprint: activeConnection.workspaceScopeFingerprint
        )
        sessionPinStateVersion &+= 1
    }

    func unpinSession(_ session: SessionSummary) {
        guard let activeConnection else { return }
        connectionStore.removePinnedSession(
            id: session.id,
            workspaceScopeFingerprint: activeConnection.workspaceScopeFingerprint
        )
        sessionPinStateVersion &+= 1
    }

    func toggleSessionPin(_ session: SessionSummary) {
        if isSessionPinned(session.id) {
            unpinSession(session)
        } else {
            pinSession(session)
        }
    }

    func sessionSummary(for sessionID: String) -> SessionSummary? {
        sessions.first(where: { $0.id == sessionID }) ??
            pinnedSessionSummaries.first(where: { $0.id == sessionID })
    }

    func browseWorkspaceDirectory(path: String? = nil) async {
        guard let profile = activeConnection else { return }
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let browsePath = trimmedPath?.isEmpty == false ? trimmedPath! : workspaceFileBrowserDefaultPath

        isLoadingWorkspaceFileBrowser = true
        workspaceFileBrowserError = nil

        do {
            let listing = try await fileEditorService.listDirectory(
                remotePath: browsePath,
                hermesHome: overview?.hermesHome ?? profile.remoteHermesHomePath,
                connection: profile
            )
            guard isActiveWorkspace(profile) else { return }
            workspaceFileBrowserListing = listing
            isLoadingWorkspaceFileBrowser = false
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isLoadingWorkspaceFileBrowser = false
            workspaceFileBrowserError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to browse remote files"))
        }
    }

    func loadSessions(
        reset: Bool = false,
        query: String? = nil,
        preferredSessionID: String? = nil,
        allowsFallbackSelection: Bool = true
    ) async {
        guard let profile = activeConnection else { return }

        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? sessionSearchQuery
        if isLoadingSessions {
            if reset, query != nil {
                sessionSearchQuery = normalizedQuery
                pendingSessionReloadQuery = normalizedQuery
            }
            return
        }

        let previousSelectedSessionID = selectedSessionID

        isLoadingSessions = true
        sessionsError = nil

        if reset, query != nil {
            sessionSearchQuery = normalizedQuery
        }

        do {
            let page = try await sessionBrowserService.listSessions(
                connection: profile,
                offset: reset ? 0 : sessionOffset,
                limit: sessionPageSize,
                query: normalizedQuery
            )
            guard isActiveWorkspace(profile) else { return }

            if reset {
                sessions = page.items
                sessionOffset = page.items.count
            } else {
                sessions.append(contentsOf: page.items)
                sessionOffset += page.items.count
            }

            totalSessionsCount = page.totalCount
            hasMoreSessions = sessionOffset < totalSessionsCount
            isLoadingSessions = false

            if reset {
                let resolvedPreferredSessionID: String?
                if let explicitPreferredSessionID = preferredSessionID,
                   sessions.contains(where: { $0.id == explicitPreferredSessionID }) ||
                    isSessionPinned(explicitPreferredSessionID) {
                    resolvedPreferredSessionID = explicitPreferredSessionID
                } else if let previousSelectedSessionID,
                   sessions.contains(where: { $0.id == previousSelectedSessionID }) ||
                    isSessionPinned(previousSelectedSessionID) {
                    resolvedPreferredSessionID = previousSelectedSessionID
                } else if !allowsFallbackSelection {
                    resolvedPreferredSessionID = nil
                } else {
                    resolvedPreferredSessionID = normalizedQuery.isEmpty
                        ? pinnedSessionSummaries.first?.id ?? sessions.first?.id
                        : sessions.first?.id
                }

                if let resolvedPreferredSessionID {
                    await loadSessionDetail(sessionID: resolvedPreferredSessionID)
                } else {
                    selectedSessionID = nil
                    clearSessionMessages()
                }
            }
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isLoadingSessions = false
            sessionsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to load sessions"))
        }

        guard let queuedQuery = pendingSessionReloadQuery else { return }
        pendingSessionReloadQuery = nil
        guard queuedQuery != normalizedQuery else { return }
        await loadSessions(reset: true, query: queuedQuery)
    }

    func loadSessionDetail(sessionID: String) async {
        guard let profile = activeConnection else { return }
        if selectedSessionID != sessionID {
            clearSessionMessages()
        }
        selectedSessionID = sessionID
        sessionsError = nil
        sessionConversationError = nil

        do {
            let messages = try await sessionBrowserService.loadTranscript(
                connection: profile,
                sessionID: sessionID
            )
            guard isActiveWorkspace(profile), selectedSessionID == sessionID else { return }
            await setSessionMessages(messages, for: profile, sessionID: sessionID)
        } catch {
            guard isActiveWorkspace(profile), selectedSessionID == sessionID else { return }
            clearSessionMessages()
            sessionsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to load session transcript"))
        }
    }

    func prepareNewSessionComposer() {
        selectedSessionID = nil
        clearSessionMessages()
        sessionsError = nil
        sessionConversationError = nil
    }

    func startNewSession(with prompt: String, autoApproveCommands: Bool) async -> Bool {
        guard let profile = activeConnection else { return false }
        guard !isSendingSessionMessage else { return false }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return false }

        let existingVisibleSessionIDs = Set((sessions + pinnedSessionSummaries).map(\.id))

        isSendingSessionMessage = true
        pendingSessionTurn = PendingSessionTurn(
            sessionID: nil,
            prompt: trimmedPrompt,
            autoApproveCommands: autoApproveCommands
        )
        sessionConversationError = nil
        sessionsError = nil

        do {
            let turnResult = try await hermesChatService.sendMessage(
                trimmedPrompt,
                sessionID: nil,
                connection: profile,
                autoApproveCommands: autoApproveCommands
            )
            guard isActiveWorkspace(profile) else { return false }

            isSendingSessionMessage = false
            pendingSessionTurn = nil
            sessionSearchQuery = ""
            await loadSessions(
                reset: true,
                query: "",
                preferredSessionID: turnResult.sessionID,
                allowsFallbackSelection: false
            )

            let createdSessionID = turnResult.sessionID ??
                likelyNewSessionID(
                    afterStartingWith: trimmedPrompt,
                    excluding: existingVisibleSessionIDs
                ) ??
                sessions.first?.id

            if let createdSessionID {
                await loadSessionDetail(sessionID: createdSessionID)
            }
            return true
        } catch {
            guard isActiveWorkspace(profile) else { return false }
            isSendingSessionMessage = false
            pendingSessionTurn = nil
            sessionConversationError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to start Hermes session"))
            return false
        }
    }

    private func likelyNewSessionID(
        afterStartingWith prompt: String,
        excluding existingSessionIDs: Set<String>
    ) -> String? {
        let newSessions = sessions.filter { !existingSessionIDs.contains($0.id) }
        guard !newSessions.isEmpty else { return nil }

        let normalizedPrompt = Self.normalizedSessionSelectionText(prompt)
        guard !normalizedPrompt.isEmpty else {
            return newSessions.first?.id
        }

        return newSessions.first { summary in
            Self.sessionSummary(summary, matchesNewSessionPrompt: normalizedPrompt)
        }?.id ?? newSessions.first?.id
    }

    nonisolated private static func sessionSummary(
        _ summary: SessionSummary,
        matchesNewSessionPrompt normalizedPrompt: String
    ) -> Bool {
        [summary.title, summary.preview].contains { candidate in
            let normalizedCandidate = normalizedSessionSelectionText(candidate ?? "")
            guard !normalizedCandidate.isEmpty else { return false }

            return normalizedPrompt.hasPrefix(normalizedCandidate) ||
                normalizedCandidate.hasPrefix(normalizedPrompt) ||
                normalizedCandidate.contains(normalizedPrompt)
        }
    }

    nonisolated private static func normalizedSessionSelectionText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func sendMessageToSelectedSession(_ prompt: String, autoApproveCommands: Bool) async -> Bool {
        guard let profile = activeConnection,
              let selectedSessionID else {
            return false
        }
        guard !isSendingSessionMessage else { return false }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return false }

        isSendingSessionMessage = true
        pendingSessionTurn = PendingSessionTurn(
            sessionID: selectedSessionID,
            prompt: trimmedPrompt,
            autoApproveCommands: autoApproveCommands
        )
        sessionConversationError = nil
        sessionsError = nil
        startSessionTranscriptPolling(sessionID: selectedSessionID, connection: profile)

        do {
            _ = try await hermesChatService.sendMessage(
                trimmedPrompt,
                sessionID: selectedSessionID,
                connection: profile,
                autoApproveCommands: autoApproveCommands
            )
            guard isActiveWorkspace(profile) else { return false }

            stopSessionTranscriptPolling()
            if self.selectedSessionID == selectedSessionID {
                await loadSessionDetail(sessionID: selectedSessionID)
            }
            isSendingSessionMessage = false
            pendingSessionTurn = nil
            await loadSessions(reset: true, query: sessionSearchQuery)
            return true
        } catch {
            guard isActiveWorkspace(profile) else { return false }
            stopSessionTranscriptPolling()
            isSendingSessionMessage = false
            pendingSessionTurn = nil
            sessionConversationError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to send prompt to Hermes"))
            return false
        }
    }

    func deleteSession(_ session: SessionSummary) async {
        guard let profile = activeConnection else { return }
        if isDeletingSession { return }

        isDeletingSession = true
        sessionsError = nil

        do {
            try await sessionBrowserService.deleteSession(
                connection: profile,
                sessionID: session.id,
                hintedSessionStore: overview?.sessionStore
            )
            guard isActiveWorkspace(profile) else { return }

            await loadSessions(reset: true)
            await loadUsage(forceRefresh: true)
            isDeletingSession = false
            setStatusMessage(L10n.string("Session deleted locally and on the remote Hermes host"))
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isDeletingSession = false
            sessionsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to delete session"))
        }
    }

    func loadUsage(forceRefresh: Bool = false) async {
        guard let profile = activeConnection else { return }
        if isLoadingUsage { return }
        if !forceRefresh {
            if usageSummary != nil || usageError != nil {
                return
            }
        }

        isLoadingUsage = true
        usageError = nil

        do {
            let summary = try await usageBrowserService.loadUsage(
                connection: profile,
                hintedSessionStore: overview?.sessionStore
            )
            guard isActiveWorkspace(profile) else { return }

            let profileBreakdown: UsageProfileBreakdown?
            if let overview,
               overview.availableProfiles.count > 1 {
                profileBreakdown = await loadUsageProfileBreakdown(
                    using: profile,
                    activeSummary: summary,
                    discoveredProfiles: overview.availableProfiles
                )
            } else {
                profileBreakdown = nil
            }
            guard isActiveWorkspace(profile) else { return }

            usageSummary = summary
            usageProfileBreakdown = profileBreakdown
            isLoadingUsage = false
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isLoadingUsage = false
            usageSummary = nil
            usageProfileBreakdown = nil
            usageError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to load usage"))
        }
    }

    // MARK: - Knowledge Base

    func refreshKnowledgeBase() async {
        guard !isLoadingKnowledgeBase, !isRefreshingKnowledgeBase else { return }
        isRefreshingKnowledgeBase = true
        await loadKnowledgeBase()
        isRefreshingKnowledgeBase = false
    }

    func loadKnowledgeBase() async {
        guard let profile = activeConnection else { return }
        if isLoadingKnowledgeBase { return }

        isLoadingKnowledgeBase = true
        knowledgeBaseError = nil

        do {
            let response = try await knowledgeBaseService.loadVault(connection: profile)
            guard isActiveWorkspace(profile) else { return }
            knowledgeVault = response.vault
            knowledgeSkillInstalled = response.skillInstalled
            isLoadingKnowledgeBase = false
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isLoadingKnowledgeBase = false
            knowledgeBaseError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to load knowledge base"))
        }
    }

    func uploadKnowledgeBase(localFolder: URL, vaultName: String) async -> Bool {
        guard let profile = activeConnection else { return false }
        guard !isUploadingKnowledgeBase else { return false }

        isUploadingKnowledgeBase = true
        knowledgeBaseError = nil
        setStatusMessage(L10n.string("Syncing knowledge base…"))

        do {
            let response = try await knowledgeBaseService.uploadVault(
                connection: profile,
                localFolder: localFolder,
                vaultName: vaultName
            )
            guard isActiveWorkspace(profile) else { return false }
            knowledgeVault = response.vault
            knowledgeSkillInstalled = response.skillInstalled
            isUploadingKnowledgeBase = false
            setStatusMessage(L10n.string("Knowledge base synced."))
            return true
        } catch {
            guard isActiveWorkspace(profile) else { return false }
            isUploadingKnowledgeBase = false
            knowledgeBaseError = error.localizedDescription
            setStatusMessage(L10n.string("Knowledge base sync failed."))
            return false
        }
    }

    func removeKnowledgeBase() async -> Bool {
        guard let profile = activeConnection else { return false }
        guard !isRemovingKnowledgeBase else { return false }

        isRemovingKnowledgeBase = true
        knowledgeBaseError = nil
        setStatusMessage(L10n.string("Removing knowledge base…"))

        do {
            _ = try await knowledgeBaseService.removeVault(connection: profile)
            guard isActiveWorkspace(profile) else { return false }
            knowledgeVault = nil
            isRemovingKnowledgeBase = false
            setStatusMessage(L10n.string("Knowledge base removed."))
            return true
        } catch {
            guard isActiveWorkspace(profile) else { return false }
            isRemovingKnowledgeBase = false
            knowledgeBaseError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to remove the knowledge base"))
            return false
        }
    }

    func loadSkills(reset: Bool = false) async {
        guard let profile = activeConnection else { return }
        if isLoadingSkills { return }

        let previousSelectedSkillID = selectedSkillID

        isLoadingSkills = true
        skillsError = nil

        do {
            let items = try await skillBrowserService.listSkills(connection: profile)
            guard isActiveWorkspace(profile) else { return }
            skills = items
            isLoadingSkills = false

            if reset {
                let preferredSkillID: String?
                if let previousSelectedSkillID,
                   items.contains(where: { $0.id == previousSelectedSkillID }) {
                    preferredSkillID = previousSelectedSkillID
                } else {
                    preferredSkillID = items.first?.id
                }

                if let preferredSkill = items.first(where: { $0.id == preferredSkillID }) {
                    await loadSkillDetail(summary: preferredSkill)
                } else if let firstSkill = items.first {
                    await loadSkillDetail(summary: firstSkill)
                } else {
                    selectedSkillID = nil
                    selectedSkillDetail = nil
                    isLoadingSkillDetail = false
                }
            }
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isLoadingSkills = false
            skillsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to load skills"))
        }
    }

    func loadSkillDetail(summary: SkillSummary) async {
        guard let profile = activeConnection else { return }
        let skillID = summary.id
        selectedSkillID = skillID
        selectedSkillDetail = nil
        skillsError = nil
        isLoadingSkillDetail = true

        do {
            let detail = try await skillBrowserService.loadSkillDetail(
                connection: profile,
                locator: summary.locator
            )

            guard isActiveWorkspace(profile), selectedSkillID == skillID else { return }
            selectedSkillDetail = detail
            isLoadingSkillDetail = false
        } catch {
            guard isActiveWorkspace(profile), selectedSkillID == skillID else { return }
            selectedSkillDetail = nil
            isLoadingSkillDetail = false
            skillsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to load skill detail"))
        }
    }

    func createSkill(_ draft: SkillDraft) async -> Bool {
        guard let profile = activeConnection else { return false }
        guard !isSavingSkillDraft else { return false }

        if let validationError = draft.validationError {
            let localizedError = L10n.string(validationError)
            skillsError = localizedError
            setStatusMessage(localizedError)
            return false
        }

        isSavingSkillDraft = true
        skillsError = nil
        setStatusMessage(L10n.string("Creating skill…"))

        do {
            let detail = try await skillBrowserService.createSkill(
                connection: profile,
                draft: draft
            )
            guard isActiveWorkspace(profile) else { return false }
            await loadSkills(reset: true)
            selectedSkillID = detail.id
            selectedSkillDetail = detail
            isSavingSkillDraft = false
            setStatusMessage(L10n.string("%@ created", draft.normalizedName))
            return true
        } catch {
            guard isActiveWorkspace(profile) else { return false }
            isSavingSkillDraft = false
            skillsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to create skill"))
            return false
        }
    }

    func updateSkill(
        _ detail: SkillDetail,
        markdownContent: String,
        ensureReferencesFolder: Bool,
        ensureScriptsFolder: Bool,
        ensureTemplatesFolder: Bool
    ) async -> Bool {
        guard let profile = activeConnection else { return false }
        guard !isSavingSkillDraft else { return false }

        let normalizedContent = markdownContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else {
            let message = L10n.string("SKILL.md content cannot be empty.")
            skillsError = message
            setStatusMessage(message)
            return false
        }

        isSavingSkillDraft = true
        skillsError = nil
        setStatusMessage(L10n.string("Updating %@…", detail.resolvedName))

        do {
            let updatedDetail = try await skillBrowserService.updateSkill(
                connection: profile,
                locator: detail.locator,
                markdownContent: normalizedContent + "\n",
                expectedContentHash: detail.contentHash,
                ensureReferencesFolder: ensureReferencesFolder,
                ensureScriptsFolder: ensureScriptsFolder,
                ensureTemplatesFolder: ensureTemplatesFolder
            )
            guard isActiveWorkspace(profile) else { return false }
            await loadSkills(reset: true)
            selectedSkillID = updatedDetail.id
            selectedSkillDetail = updatedDetail
            isSavingSkillDraft = false
            setStatusMessage(L10n.string("%@ updated", updatedDetail.resolvedName))
            return true
        } catch {
            guard isActiveWorkspace(profile) else { return false }
            isSavingSkillDraft = false
            skillsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to update skill"))
            return false
        }
    }

    func loadCronJobs() async {
        guard let profile = activeConnection else { return }
        if isLoadingCronJobs { return }

        let previousSelectedCronJobID = selectedCronJobID
        isLoadingCronJobs = true
        cronJobsError = nil

        do {
            let jobs = try await cronBrowserService.listJobs(connection: profile)
            guard isActiveWorkspace(profile) else { return }
            cronJobs = jobs
            isLoadingCronJobs = false

            if let previousSelectedCronJobID,
               jobs.contains(where: { $0.id == previousSelectedCronJobID }) {
                selectedCronJobID = previousSelectedCronJobID
            } else {
                selectedCronJobID = jobs.first?.id
            }
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isLoadingCronJobs = false
            cronJobsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to load cron jobs"))
        }
    }

    func pauseCronJob(_ job: CronJob) async {
        guard let profile = activeConnection else { return }
        guard !isOperatingOnCronJob else { return }

        isOperatingOnCronJob = true
        operatingCronJobID = job.id
        cronJobsError = nil

        do {
            try await cronBrowserService.pauseJob(connection: profile, jobID: job.id)
            guard isActiveWorkspace(profile) else { return }
            await loadCronJobs()
            isOperatingOnCronJob = false
            operatingCronJobID = nil
            setStatusMessage(L10n.string("%@ paused", job.resolvedName))
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isOperatingOnCronJob = false
            operatingCronJobID = nil
            cronJobsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to pause cron job"))
        }
    }

    func createCronJob(_ draft: CronJobDraft) async -> Bool {
        guard let profile = activeConnection else { return false }
        guard !isSavingCronJobDraft, !isOperatingOnCronJob else { return false }

        if let validationError = draft.validationError {
            let localizedError = L10n.string(validationError)
            cronJobsError = localizedError
            setStatusMessage(localizedError)
            return false
        }

        isSavingCronJobDraft = true
        cronJobsError = nil
        setStatusMessage(L10n.string("Creating cron job…"))

        do {
            let jobID = try await cronBrowserService.createJob(connection: profile, draft: draft)
            guard isActiveWorkspace(profile) else { return false }
            await loadCronJobs()
            selectedCronJobID = jobID
            isSavingCronJobDraft = false
            setStatusMessage(L10n.string("%@ created", draft.normalizedName))
            return true
        } catch {
            guard isActiveWorkspace(profile) else { return false }
            isSavingCronJobDraft = false
            cronJobsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to create cron job"))
            return false
        }
    }

    func updateCronJob(_ job: CronJob, draft: CronJobDraft) async -> Bool {
        guard let profile = activeConnection else { return false }
        guard !isSavingCronJobDraft, !isOperatingOnCronJob else { return false }

        if let validationError = draft.validationError {
            let localizedError = L10n.string(validationError)
            cronJobsError = localizedError
            setStatusMessage(localizedError)
            return false
        }

        isSavingCronJobDraft = true
        cronJobsError = nil
        setStatusMessage(L10n.string("Updating %@…", job.resolvedName))

        do {
            try await cronBrowserService.updateJob(connection: profile, jobID: job.id, draft: draft)
            guard isActiveWorkspace(profile) else { return false }
            await loadCronJobs()
            selectedCronJobID = job.id
            isSavingCronJobDraft = false
            setStatusMessage(L10n.string("%@ updated", draft.normalizedName))
            return true
        } catch {
            guard isActiveWorkspace(profile) else { return false }
            isSavingCronJobDraft = false
            cronJobsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to update cron job"))
            return false
        }
    }

    func resumeCronJob(_ job: CronJob) async {
        guard let profile = activeConnection else { return }
        guard !isOperatingOnCronJob else { return }

        isOperatingOnCronJob = true
        operatingCronJobID = job.id
        cronJobsError = nil

        do {
            try await cronBrowserService.resumeJob(connection: profile, jobID: job.id)
            guard isActiveWorkspace(profile) else { return }
            await loadCronJobs()
            isOperatingOnCronJob = false
            operatingCronJobID = nil
            setStatusMessage(L10n.string("%@ resumed", job.resolvedName))
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isOperatingOnCronJob = false
            operatingCronJobID = nil
            cronJobsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to resume cron job"))
        }
    }

    func deleteCronJob(_ job: CronJob) async {
        guard let profile = activeConnection else { return }
        guard !isOperatingOnCronJob else { return }

        isOperatingOnCronJob = true
        operatingCronJobID = job.id
        cronJobsError = nil

        do {
            try await cronBrowserService.removeJob(connection: profile, jobID: job.id)
            guard isActiveWorkspace(profile) else { return }
            await loadCronJobs()
            isOperatingOnCronJob = false
            operatingCronJobID = nil
            setStatusMessage(L10n.string("%@ removed", job.resolvedName))
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isOperatingOnCronJob = false
            operatingCronJobID = nil
            cronJobsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to remove cron job"))
        }
    }

    func runCronJobNow(_ job: CronJob) async {
        guard let profile = activeConnection else { return }
        guard !isOperatingOnCronJob else { return }

        isOperatingOnCronJob = true
        operatingCronJobID = job.id
        cronJobsError = nil
        setStatusMessage(L10n.string("Triggering %@…", job.resolvedName))

        do {
            try await cronBrowserService.runJobNow(connection: profile, jobID: job.id)
            guard isActiveWorkspace(profile) else { return }
            await loadCronJobs()
            isOperatingOnCronJob = false
            operatingCronJobID = nil
            setStatusMessage(L10n.string("Run requested for %@", job.resolvedName))
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isOperatingOnCronJob = false
            operatingCronJobID = nil
            cronJobsError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to run cron job"))
        }
    }

    func loadKanbanBoard(includeArchived: Bool? = nil) async {
        guard let profile = activeConnection else { return }
        if isLoadingKanbanBoard { return }

        if let includeArchived {
            includeArchivedKanbanTasks = includeArchived
        }

        let previousSelectedTaskID = selectedKanbanTaskID
        isLoadingKanbanBoard = true
        kanbanError = nil

        do {
            let board = try await kanbanBrowserService.loadBoard(
                connection: profile,
                includeArchived: includeArchivedKanbanTasks
            )
            guard isActiveWorkspace(profile) else { return }
            kanbanBoard = board
            isLoadingKanbanBoard = false

            let nextSelectedTaskID: String?
            if let previousSelectedTaskID,
               board.tasks.contains(where: { $0.id == previousSelectedTaskID }) {
                nextSelectedTaskID = previousSelectedTaskID
            } else {
                nextSelectedTaskID = board.tasks.first?.id
            }

            selectedKanbanTaskID = nextSelectedTaskID
            if let nextSelectedTaskID {
                await loadKanbanTaskDetail(taskID: nextSelectedTaskID)
            } else {
                selectedKanbanTaskDetail = nil
            }
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isLoadingKanbanBoard = false
            kanbanError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to load Kanban board"))
        }
    }

    func loadKanbanTaskDetail(taskID: String) async {
        guard let profile = activeConnection else { return }

        selectedKanbanTaskID = taskID
        isLoadingKanbanTaskDetail = true
        kanbanError = nil

        do {
            let detail = try await kanbanBrowserService.loadTaskDetail(
                connection: profile,
                taskID: taskID
            )
            guard isActiveWorkspace(profile), selectedKanbanTaskID == taskID else { return }
            selectedKanbanTaskDetail = detail
            isLoadingKanbanTaskDetail = false
        } catch {
            guard isActiveWorkspace(profile), selectedKanbanTaskID == taskID else { return }
            selectedKanbanTaskDetail = nil
            isLoadingKanbanTaskDetail = false
            kanbanError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to load Kanban task"))
        }
    }

    func createKanbanTask(_ draft: KanbanTaskDraft) async -> Bool {
        guard let profile = activeConnection else { return false }
        guard !isSavingKanbanTaskDraft, !isOperatingOnKanbanTask else { return false }

        if let validationError = draft.validationError {
            let localizedError = L10n.string(validationError)
            kanbanError = localizedError
            setStatusMessage(localizedError)
            return false
        }

        isSavingKanbanTaskDraft = true
        kanbanError = nil
        setStatusMessage(L10n.string("Creating Kanban task..."))

        do {
            let taskID = try await kanbanBrowserService.createTask(connection: profile, draft: draft)
            guard isActiveWorkspace(profile) else { return false }
            await loadKanbanBoard(includeArchived: includeArchivedKanbanTasks)
            selectedKanbanTaskID = taskID
            await loadKanbanTaskDetail(taskID: taskID)
            isSavingKanbanTaskDraft = false
            setStatusMessage(L10n.string("Kanban task created"))
            return true
        } catch {
            guard isActiveWorkspace(profile) else { return false }
            isSavingKanbanTaskDraft = false
            kanbanError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to create Kanban task"))
            return false
        }
    }

    func addKanbanComment(taskID: String, body: String) async -> Bool {
        guard let profile = activeConnection else { return false }
        guard !isOperatingOnKanbanTask else { return false }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        isOperatingOnKanbanTask = true
        operatingKanbanTaskID = taskID
        kanbanError = nil

        do {
            try await kanbanBrowserService.addComment(connection: profile, taskID: taskID, body: trimmed)
            guard isActiveWorkspace(profile) else { return false }
            await reloadKanbanAfterOperation(taskID: taskID)
            isOperatingOnKanbanTask = false
            operatingKanbanTaskID = nil
            setStatusMessage(L10n.string("Comment added"))
            return true
        } catch {
            guard isActiveWorkspace(profile) else { return false }
            isOperatingOnKanbanTask = false
            operatingKanbanTaskID = nil
            kanbanError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to add Kanban comment"))
            return false
        }
    }

    func assignKanbanTask(taskID: String, assignee: String?) async {
        await operateOnKanbanTask(
            taskID: taskID,
            successMessage: "Kanban task assigned",
            failureMessage: "Unable to assign Kanban task"
        ) { profile in
            try await kanbanBrowserService.assignTask(connection: profile, taskID: taskID, assignee: assignee)
        }
    }

    func blockKanbanTask(taskID: String, reason: String?) async {
        await operateOnKanbanTask(
            taskID: taskID,
            successMessage: "Kanban task blocked",
            failureMessage: "Unable to block Kanban task"
        ) { profile in
            try await kanbanBrowserService.blockTask(connection: profile, taskID: taskID, reason: reason)
        }
    }

    func unblockKanbanTask(taskID: String) async {
        await operateOnKanbanTask(
            taskID: taskID,
            successMessage: "Kanban task unblocked",
            failureMessage: "Unable to unblock Kanban task"
        ) { profile in
            try await kanbanBrowserService.unblockTask(connection: profile, taskID: taskID)
        }
    }

    func completeKanbanTask(taskID: String, result: String?) async {
        await operateOnKanbanTask(
            taskID: taskID,
            successMessage: "Kanban task completed",
            failureMessage: "Unable to complete Kanban task"
        ) { profile in
            try await kanbanBrowserService.completeTask(connection: profile, taskID: taskID, result: result)
        }
    }

    func archiveKanbanTask(taskID: String) async {
        await operateOnKanbanTask(
            taskID: taskID,
            successMessage: "Kanban task archived",
            failureMessage: "Unable to archive Kanban task"
        ) { profile in
            try await kanbanBrowserService.archiveTask(connection: profile, taskID: taskID)
        }
    }

    func deleteKanbanTask(taskID: String) async {
        guard let profile = activeConnection else { return }
        guard !isOperatingOnKanbanTask else { return }

        isOperatingOnKanbanTask = true
        operatingKanbanTaskID = taskID
        kanbanError = nil

        do {
            try await kanbanBrowserService.deleteTask(connection: profile, taskID: taskID)
            guard isActiveWorkspace(profile) else { return }
            await loadKanbanBoard(includeArchived: includeArchivedKanbanTasks)
            if selectedKanbanTaskID == nil {
                selectedKanbanTaskDetail = nil
            }
            isOperatingOnKanbanTask = false
            operatingKanbanTaskID = nil
            setStatusMessage(L10n.string("Kanban task deleted"))
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isOperatingOnKanbanTask = false
            operatingKanbanTaskID = nil
            kanbanError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to delete Kanban task"))
        }
    }

    func dispatchKanbanNow() async {
        guard let profile = activeConnection else { return }
        guard !isDispatchingKanban else { return }

        isDispatchingKanban = true
        kanbanError = nil
        setStatusMessage(L10n.string("Nudging Kanban dispatcher..."))

        do {
            let result = try await kanbanBrowserService.dispatchNow(connection: profile)
            guard isActiveWorkspace(profile) else { return }
            await loadKanbanBoard(includeArchived: includeArchivedKanbanTasks)
            isDispatchingKanban = false

            if let result {
                setStatusMessage(
                    L10n.string(
                        "Kanban dispatch: %@ spawned, %@ promoted",
                        "\(result.spawned.count)",
                        "\(result.promoted)"
                    )
                )
            } else {
                setStatusMessage(L10n.string("Kanban dispatcher nudged"))
            }
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isDispatchingKanban = false
            kanbanError = error.localizedDescription
            setStatusMessage(L10n.string("Unable to nudge Kanban dispatcher"))
        }
    }

    func deleteConnection(_ profile: ConnectionProfile) {
        connectionStore.delete(profile)
        terminalWorkspace.closeTabs(forConnectionID: profile.id)
        if activeConnectionID == profile.id {
            activeConnectionID = nil
            resetWorkspaceStateForConnectionChange(closeTerminalTabs: false)
            selectedSection = .connections
        }
    }

    func ensureTerminalSession() {
        guard let profile = activeConnection else { return }
        terminalWorkspace.ensureInitialTab(for: profile)
    }

    func resumeSessionInTerminal(_ session: SessionSummary) {
        guard let profile = activeConnection else {
            sessionsError = L10n.string("Select a connection before resuming a session in Terminal.")
            setStatusMessage(L10n.string("No active connection"))
            return
        }

        let invocation = HermesSessionResumeInvocation(sessionID: session.id, connection: profile)
        terminalWorkspace.addCommandTab(
            for: profile.updated(),
            commandLine: invocation.commandLine
        )
        selectedSection = .terminal
        handleSectionEntry(.terminal)
        setStatusMessage(L10n.string("Opening %@ in Terminal…", session.resolvedTitle))
    }

    private func operateOnKanbanTask(
        taskID: String,
        successMessage: String,
        failureMessage: String,
        operation: (ConnectionProfile) async throws -> Void
    ) async {
        guard let profile = activeConnection else { return }
        guard !isOperatingOnKanbanTask else { return }

        isOperatingOnKanbanTask = true
        operatingKanbanTaskID = taskID
        kanbanError = nil

        do {
            try await operation(profile)
            guard isActiveWorkspace(profile) else { return }
            await reloadKanbanAfterOperation(taskID: taskID)
            isOperatingOnKanbanTask = false
            operatingKanbanTaskID = nil
            setStatusMessage(L10n.string(successMessage))
        } catch {
            guard isActiveWorkspace(profile) else { return }
            isOperatingOnKanbanTask = false
            operatingKanbanTaskID = nil
            kanbanError = error.localizedDescription
            setStatusMessage(L10n.string(failureMessage))
        }
    }

    private func reloadKanbanAfterOperation(taskID: String) async {
        await loadKanbanBoard(includeArchived: includeArchivedKanbanTasks)
        if kanbanBoard?.tasks.contains(where: { $0.id == taskID }) == true {
            selectedKanbanTaskID = taskID
            await loadKanbanTaskDetail(taskID: taskID)
        }
    }

    private func handleSectionEntry(_ section: AppSection) {
        switch section {
        case .overview:
            Task { await refreshOverview() }
        case .files:
            Task { await ensureInitialFileLoads() }
        case .sessions:
            Task { await loadSessions(reset: true) }
        case .cronjobs:
            Task { await loadCronJobs() }
        case .kanban:
            Task { await loadKanbanBoard() }
        case .usage:
            Task { await loadUsage(forceRefresh: true) }
        case .skills:
            Task { await loadSkills(reset: true) }
        case .knowledgeBase:
            Task { await loadKnowledgeBase() }
        case .terminal:
            ensureTerminalSession()
        case .connections, .desktop, .mail, .messaging, .connectors, .providers, .doctor:
            // .desktop manages its own VNC lifecycle inside DesktopView.
            // .mail manages its own AgentMail setup state inside MailView.
            // .connectors manages its own Composio setup state inside ConnectorsView.
            break
        }
    }

    private func ensureInitialFileLoads() async {
        await loadSelectedWorkspaceFile()
    }

    private func document(for reference: WorkspaceFileReference) -> FileEditorDocument {
        var document = workspaceFileDocuments[reference.id] ??
            FileEditorDocument(fileID: reference.id, title: reference.title, remotePath: reference.remotePath)
        document.title = reference.title
        document.remotePath = reference.remotePath
        return document
    }

    private func resolvedRemotePath(for trackedFile: RemoteTrackedFile, connection: ConnectionProfile) -> String {
        trackedFile.resolvedRemotePath(using: overview?.paths) ?? connection.remotePath(for: trackedFile)
    }

    private func isActiveWorkspace(_ profile: ConnectionProfile) -> Bool {
        activeConnection?.workspaceScopeFingerprint == profile.workspaceScopeFingerprint
    }

    private func setDocument(_ document: FileEditorDocument) {
        workspaceFileDocuments[document.fileID] = document
    }

    private func reloadWorkspaceScope(section: AppSection, statusMessage: String) async {
        resetWorkspaceStateForConnectionChange(closeTerminalTabs: false)
        selectedSection = section
        setStatusMessage(statusMessage)
        await prepareWorkspaceForActiveConnection()
        await reloadSectionAfterScopeChange(section)
    }

    private func reloadSectionAfterScopeChange(_ section: AppSection) async {
        switch section {
        case .connections, .overview, .desktop, .mail, .messaging, .connectors, .providers, .doctor:
            // Desktop reconnects on its own when the active connection changes.
            // Mail and Connectors re-evaluate setup state on their own.
            break
        case .files:
            await ensureInitialFileLoads()
        case .sessions:
            await loadSessions(reset: true)
        case .cronjobs:
            await loadCronJobs()
        case .kanban:
            await loadKanbanBoard()
        case .usage:
            await loadUsage(forceRefresh: true)
        case .skills:
            await loadSkills(reset: true)
        case .knowledgeBase:
            await loadKnowledgeBase()
        case .terminal:
            ensureTerminalSession()
        }
    }

    private func clearSessionMessages() {
        guard !sessionMessages.isEmpty || !sessionMessageDisplays.isEmpty else { return }
        sessionMessages = []
        sessionMessageDisplays = []
        sessionMessageSignature = SessionMessageSignature(messages: [])
    }

    private func setSessionMessages(
        _ messages: [SessionMessage],
        for profile: ConnectionProfile? = nil,
        sessionID: String? = nil
    ) async {
        let signature = await Task.detached(priority: .userInitiated) {
            SessionMessageSignature(messages: messages)
        }.value

        if let profile {
            guard isActiveWorkspace(profile) else { return }
        }
        if let sessionID {
            guard selectedSessionID == sessionID else { return }
        }
        guard signature != sessionMessageSignature else { return }

        let displays = await Task.detached(priority: .userInitiated) {
            Self.makeSessionMessageDisplays(from: messages)
        }.value

        if let profile {
            guard isActiveWorkspace(profile) else { return }
        }
        if let sessionID {
            guard selectedSessionID == sessionID else { return }
        }
        applySessionMessages(messages, displays: displays, signature: signature)
    }

    private func applySessionMessages(
        _ messages: [SessionMessage],
        displays: [SessionMessageDisplay],
        signature: SessionMessageSignature
    ) {
        guard signature != sessionMessageSignature else { return }
        sessionMessages = messages
        sessionMessageDisplays = displays
        sessionMessageSignature = signature
    }

    nonisolated private static func makeSessionMessageDisplays(
        from messages: [SessionMessage]
    ) -> [SessionMessageDisplay] {
        messages.map(SessionMessageDisplay.init)
    }

    private func startSessionTranscriptPolling(sessionID: String, connection: ConnectionProfile) {
        stopSessionTranscriptPolling()
        let workspaceScopeFingerprint = connection.workspaceScopeFingerprint

        sessionTranscriptPollingTask = Task { [sessionBrowserService] in
            while !Task.isCancelled {
                do {
                    let messages = try await sessionBrowserService.loadTranscript(
                        connection: connection,
                        sessionID: sessionID
                    )

                    let signature = await Task.detached(priority: .utility) {
                        SessionMessageSignature(messages: messages)
                    }.value

                    let shouldBuildDisplays = await MainActor.run { [weak self] in
                        guard let self,
                              self.activeConnection?.workspaceScopeFingerprint == workspaceScopeFingerprint,
                              self.isSendingSessionMessage,
                              self.selectedSessionID == sessionID else {
                            return false
                        }
                        return signature != self.sessionMessageSignature
                    }

                    guard shouldBuildDisplays else {
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }

                    let displays = await Task.detached(priority: .utility) {
                        Self.makeSessionMessageDisplays(from: messages)
                    }.value

                    await MainActor.run { [weak self] in
                        guard let self,
                              self.activeConnection?.workspaceScopeFingerprint == workspaceScopeFingerprint,
                              self.isSendingSessionMessage,
                              self.selectedSessionID == sessionID else {
                            return
                        }
                        self.applySessionMessages(messages, displays: displays, signature: signature)
                    }
                } catch {
                    // Keep polling best-effort; a transient SSH/store read failure
                    // should not end the in-flight chat turn.
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopSessionTranscriptPolling() {
        sessionTranscriptPollingTask?.cancel()
        sessionTranscriptPollingTask = nil
    }

    private func loadUsageProfileBreakdown(
        using connection: ConnectionProfile,
        activeSummary: UsageSummary,
        discoveredProfiles: [RemoteHermesProfile]
    ) async -> UsageProfileBreakdown {
        var slices: [UsageProfileSlice] = []
        let activeProfileName = connection.resolvedHermesProfileName

        for discoveredProfile in discoveredProfiles {
            if discoveredProfile.name == activeProfileName {
                slices.append(
                    usageProfileSlice(
                        for: discoveredProfile,
                        summary: activeSummary,
                        activeProfileName: activeProfileName
                    )
                )
                continue
            }

            let scopedConnection = connection.applyingHermesProfile(named: discoveredProfile.name)

            do {
                let summary = try await usageBrowserService.loadUsage(
                    connection: scopedConnection,
                    hintedSessionStore: nil
                )

                slices.append(
                    usageProfileSlice(
                        for: discoveredProfile,
                        summary: summary,
                        activeProfileName: activeProfileName
                    )
                )
            } catch {
                slices.append(
                    UsageProfileSlice(
                        profileName: discoveredProfile.name,
                        hermesHomePath: discoveredProfile.path,
                        state: .unavailable,
                        sessionCount: 0,
                        inputTokens: 0,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        reasoningTokens: 0,
                        databasePath: nil,
                        message: error.localizedDescription,
                        isActiveProfile: discoveredProfile.name == activeProfileName
                    )
                )
            }
        }

        return UsageProfileBreakdown(profiles: slices)
    }

    private func usageProfileSlice(
        for discoveredProfile: RemoteHermesProfile,
        summary: UsageSummary,
        activeProfileName: String
    ) -> UsageProfileSlice {
        UsageProfileSlice(
            profileName: discoveredProfile.name,
            hermesHomePath: discoveredProfile.path,
            state: summary.state,
            sessionCount: summary.sessionCount,
            inputTokens: summary.inputTokens,
            outputTokens: summary.outputTokens,
            cacheReadTokens: summary.cacheReadTokens,
            cacheWriteTokens: summary.cacheWriteTokens,
            reasoningTokens: summary.reasoningTokens,
            databasePath: summary.databasePath,
            message: summary.message,
            isActiveProfile: discoveredProfile.name == activeProfileName
        )
    }

    private func prepareWorkspaceForActiveConnection() async {
        guard let profile = activeConnection else { return }
        await refreshOverview()
        guard isActiveWorkspace(profile) else { return }

        guard overviewError == nil else {
            isRefreshingOverview = false
            sessions = []
            clearSessionMessages()
            sessionsError = nil
            isLoadingSessions = false
            isRefreshingSessions = false
            pendingSessionReloadQuery = nil
            isSendingSessionMessage = false
            sessionConversationError = nil
            pendingSessionTurn = nil
            stopSessionTranscriptPolling()
            usageSummary = nil
            usageProfileBreakdown = nil
            usageError = nil
            isLoadingUsage = false
            isRefreshingUsage = false
            skills = []
            selectedSkillID = nil
            selectedSkillDetail = nil
            skillsError = nil
            isLoadingSkills = false
            isRefreshingSkills = false
            isLoadingSkillDetail = false
            isSavingSkillDraft = false
            cronJobs = []
            selectedCronJobID = nil
            cronJobsError = nil
            isLoadingCronJobs = false
            isRefreshingCronJobs = false
            isOperatingOnCronJob = false
            operatingCronJobID = nil
            isSavingCronJobDraft = false
            kanbanBoard = nil
            selectedKanbanTaskID = nil
            selectedKanbanTaskDetail = nil
            kanbanError = nil
            isLoadingKanbanBoard = false
            isRefreshingKanbanBoard = false
            isLoadingKanbanTaskDetail = false
            isOperatingOnKanbanTask = false
            operatingKanbanTaskID = nil
            isSavingKanbanTaskDraft = false
            isDispatchingKanban = false
            includeArchivedKanbanTasks = false
            resetDocuments()
            return
        }

        await ensureInitialFileLoads()
        await loadSessions(reset: true)
    }

    private func resetWorkspaceStateForConnectionChange(closeTerminalTabs: Bool = true) {
        isBusy = false
        connectionTestRequestID = nil
        overview = nil
        overviewError = nil
        isRefreshingOverview = false
        sessions = []
        clearSessionMessages()
        sessionsError = nil
        isLoadingSessions = false
        isRefreshingSessions = false
        isDeletingSession = false
        isSendingSessionMessage = false
        sessionConversationError = nil
        pendingSessionTurn = nil
        stopSessionTranscriptPolling()
        hasMoreSessions = false
        totalSessionsCount = 0
        selectedSessionID = nil
        sessionOffset = 0
        pendingSessionReloadQuery = nil
        sessionSearchQuery = ""
        usageSummary = nil
        usageProfileBreakdown = nil
        usageError = nil
        isLoadingUsage = false
        isRefreshingUsage = false
        skills = []
        selectedSkillID = nil
        selectedSkillDetail = nil
        skillsError = nil
        isLoadingSkills = false
        isRefreshingSkills = false
        isLoadingSkillDetail = false
        isSavingSkillDraft = false
        cronJobs = []
        selectedCronJobID = nil
        cronJobsError = nil
        isLoadingCronJobs = false
        isRefreshingCronJobs = false
        isOperatingOnCronJob = false
        operatingCronJobID = nil
        isSavingCronJobDraft = false
        kanbanBoard = nil
        selectedKanbanTaskID = nil
        selectedKanbanTaskDetail = nil
        kanbanError = nil
        isLoadingKanbanBoard = false
        isRefreshingKanbanBoard = false
        isLoadingKanbanTaskDetail = false
        isOperatingOnKanbanTask = false
        operatingKanbanTaskID = nil
        isSavingKanbanTaskDraft = false
        isDispatchingKanban = false
        includeArchivedKanbanTasks = false
        resetDocuments()
        hermesUpdateAvailability = .unknown
        hermesUpdateStatus = .idle
        if closeTerminalTabs {
            terminalWorkspace.closeAllTabs()
        }
    }

    private func resetDocuments() {
        workspaceFileDocuments = [:]
        workspaceFileBrowserListing = nil
        workspaceFileBrowserError = nil
        isLoadingWorkspaceFileBrowser = false
        selectedWorkspaceFileID = RemoteTrackedFile.memory.workspaceFileID
    }

    private func setStatusMessage(_ message: String?) {
        statusTask?.cancel()
        statusMessage = message

        guard let message else { return }

        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.statusMessage == message else { return }
                self.statusMessage = nil
            }
        }
    }
}

private struct SessionMessageSignature: Equatable, Sendable {
    let count: Int
    let digest: Int

    init(messages: [SessionMessage]) {
        var hasher = Hasher()
        hasher.combine(messages.count)

        for message in messages {
            hasher.combine(message.id)
            hasher.combine(message.role)
            hasher.combine(message.content)
            hasher.combine(message.timestamp)
            hasher.combine(message.metadata)
        }

        count = messages.count
        digest = hasher.finalize()
    }
}

private struct ConnectionTestRequest: Encodable {}

private struct ConnectionTestResponse: Decodable {
    let ok: Bool
    let remoteHome: String
    let pythonExecutable: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case remoteHome = "remote_home"
        case pythonExecutable = "python_executable"
    }
}
