import SwiftUI

private let workbenchPrimaryColumnWidth: CGFloat = 460

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme
    @Environment(\.os1BootAnimationFinished) private var bootAnimationFinished

    @State private var sessionsSplitLayout = HermesSplitLayout(
        minPrimaryWidth: workbenchPrimaryColumnWidth,
        defaultPrimaryWidth: workbenchPrimaryColumnWidth
    )
    @State private var cronJobsSplitLayout = HermesSplitLayout(
        minPrimaryWidth: workbenchPrimaryColumnWidth,
        defaultPrimaryWidth: workbenchPrimaryColumnWidth
    )
    @State private var kanbanSplitLayout = HermesSplitLayout(
        minPrimaryWidth: workbenchPrimaryColumnWidth,
        defaultPrimaryWidth: workbenchPrimaryColumnWidth
    )
    @State private var filesSplitLayout = HermesSplitLayout(minPrimaryWidth: 300, defaultPrimaryWidth: 360)
    @State private var skillsSplitLayout = HermesSplitLayout(
        minPrimaryWidth: workbenchPrimaryColumnWidth,
        defaultPrimaryWidth: workbenchPrimaryColumnWidth
    )
    @State private var knowledgeBaseSplitLayout = HermesSplitLayout(
        minPrimaryWidth: workbenchPrimaryColumnWidth,
        defaultPrimaryWidth: workbenchPrimaryColumnWidth
    )

    var body: some View {
        OS1HSplitView {
            sidebar
                .frame(minWidth: 196, idealWidth: 220, maxWidth: 264)
                .background(theme.palette.coral)
        } detail: {
            detailView
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .clipped()
        }
        .background(theme.palette.coral)
        .overlay(alignment: .topLeading) {
            realtimeVoiceRuntime
        }
        .overlay(alignment: .bottom) {
            if let statusMessage = appState.statusMessage {
                Text(statusMessage)
                    .os1Style(theme.typography.smallCaps)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .os1GlassSurface(cornerRadius: 999)
                    .padding(.bottom, 16)
            }
        }
        .alert(item: $appState.activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(L10n.string("OK")))
            )
        }
        .alert(L10n.string("Discard unsaved changes?"), isPresented: $appState.showDiscardChangesAlert) {
            Button(L10n.string("Discard"), role: .destructive) {
                appState.discardChangesAndContinue()
            }
            Button(L10n.string("Stay"), role: .cancel) {
                appState.stayOnCurrentSection()
            }
        } message: {
            Text(L10n.string("USER.md, MEMORY.md, or SOUL.md has unsaved edits."))
        }
    }

    private var activeOrgoComputerID: String? {
        guard case .orgo(let config) = appState.activeConnection?.transport else { return nil }
        let trimmed = config.computerId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var activeProfileID: String? {
        appState.activeConnection?.id.uuidString
    }

    private var openAIAPIKey: String? {
        appState.providerCredentialStore.loadAPIKey(slug: "openai", forProfileId: activeProfileID)
    }

    @ViewBuilder
    private var realtimeVoiceRuntime: some View {
        if appState.isRealtimeVoiceEnabled && bootAnimationFinished {
            RealtimeVoiceRuntimeView(
                openAIAPIKey: openAIAPIKey,
                orgoAPIKey: appState.orgoCredentialStore.loadAPIKey(),
                orgoDefaultComputerID: activeOrgoComputerID
            ) { status in
                appState.updateRealtimeVoiceStatus(status)
            }
            .id(activeOrgoComputerID ?? "no-active-orgo-computer")
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    OS1BrandLockup(surface: .onCoral)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)

                    if let activeConnection = appState.activeConnection {
                        WorkspaceSidebarCard(connection: activeConnection)
                            .padding(.horizontal, 10)

                        Rectangle()
                            .fill(theme.palette.onCoralMuted.opacity(0.18))
                            .frame(height: 1)
                            .padding(.horizontal, 16)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(availableSections) { section in
                            sectionRow(section)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .padding(.bottom, 18)
            }

            voiceModeButton
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
        }
    }

    private var voiceModeButton: some View {
        Button {
            appState.toggleRealtimeVoiceMode()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: appState.isRealtimeVoiceEnabled ? "mic.fill" : "mic.slash")
                    .font(.system(size: 13, weight: appState.isRealtimeVoiceEnabled ? .semibold : .regular))
                    .frame(width: 18)
                Text(L10n.string("Voice"))
                    .os1Style(theme.typography.body)
                Spacer(minLength: 0)
                Text(voiceStatusLabel)
                    .os1Style(theme.typography.smallCaps)
                    .lineLimit(1)
                Circle()
                    .fill(voiceStatusColor)
                    .frame(width: 7, height: 7)
            }
            .foregroundStyle(appState.isRealtimeVoiceEnabled
                             ? theme.palette.onCoralPrimary
                             : theme.palette.onCoralSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(appState.isRealtimeVoiceEnabled ? theme.palette.glassFill : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.palette.glassBorder, lineWidth: appState.isRealtimeVoiceEnabled ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .help(appState.realtimeVoiceStatus)
    }

    private var voiceStatusLabel: String {
        guard appState.isRealtimeVoiceEnabled else { return "OFF" }
        guard bootAnimationFinished else { return "..." }
        let status = appState.realtimeVoiceStatus.lowercased()
        if status.contains("listening") || status.contains("connected") {
            return "ON"
        }
        if status.contains("error") || status.contains("failed") || status.contains("missing") {
            return "ERR"
        }
        if status.contains("idle") || status.contains("stopped") || status.contains("off") {
            return "..."
        }
        if status.contains("requesting") || status.contains("starting") || status.contains("ready") || status.contains("connecting") {
            return "..."
        }
        return "..."
    }

    private var voiceStatusColor: Color {
        guard appState.isRealtimeVoiceEnabled else { return theme.palette.onCoralMuted }
        guard bootAnimationFinished else { return theme.palette.warning }
        let status = appState.realtimeVoiceStatus.lowercased()
        if status.contains("error") || status.contains("failed") || status.contains("missing") {
            return theme.palette.danger
        }
        if status.contains("listening") || status.contains("connected") {
            return theme.palette.success
        }
        return theme.palette.warning
    }

    private func sectionRow(_ section: AppSection) -> some View {
        let isSelected = appState.selectedSection == section
        return Button {
            appState.requestSectionSelection(section)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .frame(width: 18)
                Text(L10n.string(section.title))
                    .os1Style(theme.typography.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected
                             ? theme.palette.onCoralPrimary
                             : theme.palette.onCoralSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? theme.palette.glassFill : Color.clear)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var availableSections: [AppSection] {
        guard let connection = appState.activeConnection else {
            return [.connections]
        }
        var sections: [AppSection] = [.connections, .overview, .sessions, .cronjobs, .kanban, .files, .usage, .skills, .knowledgeBase, .connectors, .providers, .mail, .messaging, .terminal, .doctor]
        // Desktop is only meaningful for Orgo VMs (SSH hosts have no VM screen).
        if case .orgo = connection.transport {
            sections.append(.desktop)
        }
        return sections
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        activeDetailContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var activeDetailContent: some View {
        switch appState.selectedSection {
        case .connections:
            ConnectionsView()
        case .overview:
            OverviewView()
        case .files:
            FilesView(splitLayout: $filesSplitLayout)
        case .sessions:
            SessionsView(splitLayout: $sessionsSplitLayout)
        case .cronjobs:
            CronJobsView(splitLayout: $cronJobsSplitLayout)
        case .kanban:
            KanbanView(splitLayout: $kanbanSplitLayout)
        case .usage:
            UsageView()
        case .skills:
            SkillsView(splitLayout: $skillsSplitLayout)
        case .knowledgeBase:
            KnowledgeBaseView(splitLayout: $knowledgeBaseSplitLayout)
        case .desktop:
            DesktopView()
        case .mail:
            MailView(viewModel: appState.mailSetupViewModel)
        case .messaging:
            MessagingView(viewModel: appState.messagingViewModel)
        case .connectors:
            ConnectorsView(viewModel: appState.connectorsViewModel)
        case .providers:
            ProvidersView(viewModel: appState.providersViewModel)
        case .doctor:
            DoctorView(viewModel: appState.doctorViewModel)
        case .terminal:
            TerminalWorkspaceView(
                workspace: appState.terminalWorkspace,
                context: TerminalWorkspaceContext(
                    activeConnection: appState.activeConnection,
                    activeWorkspaceScopeFingerprint: appState.activeConnection?.workspaceScopeFingerprint,
                    isTerminalSectionActive: appState.selectedSection == .terminal,
                    terminalTheme: appState.connectionStore.terminalTheme
                ),
                ensureTerminalSession: {
                    appState.ensureTerminalSession()
                },
                updateTerminalTheme: { newValue in
                    appState.connectionStore.terminalTheme = newValue
                }
            )
        }
    }
}

private struct WorkspaceSidebarCard: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    let connection: ConnectionProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(connection.label)
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                profileControl

                Text("·")
                    .foregroundStyle(theme.palette.onCoralMuted)

                Text(connection.displayDestination)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var profileControl: some View {
        if availableProfiles.count > 1 {
            Menu {
                ForEach(availableProfiles) { profile in
                    Button {
                        Task {
                            await appState.switchHermesProfile(to: profile.name)
                        }
                    } label: {
                        if profile.name == connection.resolvedHermesProfileName {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(connection.resolvedHermesProfileName)
                        .os1Style(theme.typography.smallCaps)
                        .foregroundStyle(theme.palette.onCoralSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.palette.onCoralMuted)
                }
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(appState.isRefreshingOverview || appState.isBusy)
        } else {
            Text(connection.resolvedHermesProfileName)
                .os1Style(theme.typography.smallCaps)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var availableProfiles: [RemoteHermesProfile] {
        if let overview = appState.overview, !overview.availableProfiles.isEmpty {
            return overview.availableProfiles
        }

        return [
            RemoteHermesProfile(
                name: connection.resolvedHermesProfileName,
                path: connection.remoteHermesHomePath,
                isDefault: connection.usesDefaultHermesProfile,
                exists: true
            )
        ]
    }
}
