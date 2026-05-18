// FILE: NewChatDraftView.swift
// Purpose: Compose-first New Chat surface that lets users pick a local folder
//          before the first send creates the real runtime thread.
// Layer: View
// Exports: NewChatDraftRoute, NewChatDraftView
// Depends on: SwiftUI, PhotosUI, CodexService, TurnComposerHostView,
//             SidebarNewChatProjectPickerSheet, SidebarLocalFolderBrowserSheet

import PhotosUI
import SwiftUI

struct NewChatDraftRoute: Hashable {
    let id: String
    let preferredProjectPath: String?
    let source: NewChatDraftSource

    var isFromGeneralChat: Bool {
        source == .generalChat
    }
}

// Tracks which sidebar affordance opened the draft. UI experiments can branch
// on `route.isFromGeneralChat` while keeping thread creation logic shared.
enum NewChatDraftSource: Hashable {
    case generalChat
    case folderChat
}

// Picks which leading toolbar affordance the New Chat surface should show.
// Pushed routes fall back to the system back chevron (same as the rest of the
// chats); drawer mode swaps in the hamburger so the sidebar stays one tap away.
enum NewChatDraftLeadingControl {
    case back
    case hamburger(action: () -> Void)
}

struct NewChatDraftView: View {
    @Environment(CodexService.self) private var codex
    @Environment(SubscriptionService.self) private var subscriptions

    let route: NewChatDraftRoute
    var leadingControl: NewChatDraftLeadingControl = .back
    var onOpenTerminal: ((String?) -> Void)? = nil
    let onOpenThread: (CodexThread) -> Void

    @State private var viewModel = TurnViewModel()
    @State private var isInputFocused = false
    @State private var selectedProjectPath: String?
    @State private var projectlessChatRootPaths: [String] = []
    @State private var activeSheet: NewChatDraftSheet?
    @State private var hasInitializedProjectSelection = false
    @State private var isLoadingRepositoryDiff = false
    @State private var repositoryDiffPresentation: TurnDiffPresentation?
    @State private var alertApprovalRequest: CodexApprovalRequest?
    @State private var isApprovalAlertPresented = false
    @State private var isShowingMacHandoffConfirm = false
    @State private var macHandoffErrorMessage: String?

    // UI-only check for layout experiments: true when opened from the general
    // sidebar Chat affordance, false when opened from a folder section button.
    private var isFromGeneralChat: Bool {
        route.isFromGeneralChat
    }

    var body: some View {
        // Original target layout: just title + folder pill, tightly stacked and
        // biased toward the top half so the composer dominates the lower third.
        // No AppLogo or encryption tagline here — that hero block is the chat
        // empty state's job, not the draft's.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            promptStack
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .navigationTitle("New thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .hamburger(let action) = leadingControl {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: action) {
                        TwoLineHamburgerIcon()
                    }
                    .accessibilityLabel("Open menu")
                }
            }
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .title) {
                    toolbarTitleLabel
                }
            } else {
                ToolbarItem(placement: .principal) {
                    toolbarTitleLabel
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                draftGitActionsButton
            }

            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }

            ToolbarItem(placement: .topBarTrailing) {
                draftThreadActionsMenu
            }
        }
        .task {
            initializeProjectSelectionIfNeeded()
            await refreshProjectlessChatRoots()
            refreshDraftGitStateIfNeeded()
        }
        .onChange(of: projectChoices) { _, _ in
            initializeProjectSelectionIfNeeded()
            refreshDraftGitStateIfNeeded()
        }
        .onChange(of: selectedProjectPath) { _, _ in
            viewModel.clearComposerAutocomplete()
            refreshDraftGitStateIfNeeded()
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
        .sheet(item: $repositoryDiffPresentation) { presentation in
            TurnDiffSheet(
                title: presentation.title,
                entries: presentation.entries,
                bodyText: presentation.bodyText,
                messageID: presentation.messageID
            )
        }
        .turnViewAlerts(
            alertApprovalRequest: $alertApprovalRequest,
            isApprovalAlertPresented: $isApprovalAlertPresented,
            isShowingNothingToCommitAlert: isShowingNothingToCommitAlertBinding,
            gitSyncAlert: gitSyncAlertBinding,
            isShowingMacHandoffConfirm: $isShowingMacHandoffConfirm,
            macHandoffErrorMessage: $macHandoffErrorMessage,
            onDeclineApproval: { _ in },
            onApproveApproval: { _ in },
            onConfirmGitSyncAction: { action in
                viewModel.confirmGitSyncAlertAction(
                    action,
                    codex: codex,
                    workingDirectory: selectedProjectPath,
                    threadID: route.id,
                    activeTurnID: nil
                )
            },
            onDismissGitSyncAlert: {
                viewModel.dismissGitSyncAlert()
            },
            onConfirmMacHandoff: {}
        )
        .fullScreenCover(isPresented: isCameraPresentedBinding) {
            CameraImagePicker { data in
                viewModel.enqueueCapturedImageData(data, codex: codex, threadID: route.id)
            }
            .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: isPhotoPickerPresentedBinding,
            selection: photoPickerItemsBinding,
            maxSelectionCount: max(1, viewModel.remainingAttachmentSlots),
            matching: .images,
            preferredItemEncoding: .automatic
        )
        .onChange(of: viewModel.photoPickerItems) { _, newItems in
            viewModel.enqueuePhotoPickerItems(newItems, codex: codex, threadID: route.id)
            viewModel.photoPickerItems = []
        }
    }

    // Source-specific prompt UI:
    // - General Chat exposes the picker because the folder is still user-selectable.
    // - Folder/project button keeps the normal title because that folder is already implied.
    private var promptStack: some View {
        Group {
            if isFromGeneralChat {
                generalChatPrompt
            } else {
                folderButtonPrompt
            }
        }
        .padding()
    }

    private var generalChatPrompt: some View {
        VStack(spacing: 8) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .adaptiveGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.bottom, 4)
            Text("What should we work on?")
                .font(AppFont.title2(weight: .regular))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            folderPickerPill
            Text("Chats are End-to-end encrypted")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
    }

    private var folderButtonPrompt: some View {
        VStack(spacing: 12) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .clipShape(RoundedRecta ngle(cornerRadius: 18, style: .continuous))
                .adaptiveGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            ChatEmptyStateTitleBuilder.makeTitle(for: placeholderFolderName)
                .font(AppFont.title2(weight: .regular))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Text("Chats are End-to-end encrypted")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
    }

    private var toolbarTitleLabel: some View {
        TurnChatToolbarTitleLabel(
            title: "New thread",
            subtitle: placeholderFolderName ?? trustedHostName,
            onTap: { activeSheet = .projectPicker },
            accessibilityHint: "Opens the project picker"
        )
    }

    // Only Quick Chat / no-folder drafts are blocked. If the draft already has
    // a selected project (including the default latest-used project from the
    // general Chat button), expose the same Git state/actions as TurnView.
    private var draftGitActionsButton: some View {
        TurnGitActionsToolbarButton(
            isEnabled: isDraftGitActionEnabled,
            disabledActions: areDraftToolbarActionsDisabled ? Set(TurnGitActionKind.allCases) : viewModel.disabledGitActions,
            isRunningAction: viewModel.isRunningGitAction,
            loadingTitle: nil,
            showsDiscardRuntimeChangesAndSync: viewModel.shouldShowDiscardRuntimeChangesAndSync,
            gitSyncState: viewModel.gitSyncState,
            repoDiffTotals: viewModel.gitRepoSync?.repoDiffTotals,
            isLoadingRepoDiff: isLoadingRepositoryDiff,
            onTapRepoDiff: areDraftToolbarActionsDisabled ? nil : {
                presentRepositoryDiff()
            },
            onSelect: handleDraftGitActionSelection
        )
        .opacity(areDraftToolbarActionsDisabled ? 0.45 : 1)
        .disabled(areDraftToolbarActionsDisabled)
    }

    // Mirrors the regular chat ellipsis chrome. It is disabled only for the
    // general Chat draft, where the folder can still change before first send.
    private var draftThreadActionsMenu: some View {
        Menu {
            Button {
                HapticFeedback.shared.triggerImpactFeedback(style: .light)
                onOpenTerminal?(selectedProjectPath)
            } label: {
                HStack(spacing: 10) {
                    RemodexIcon.image(systemName: "terminal", size: 13, weight: .semibold)
                    Text("Open Terminal Here")
                }
            }
            .disabled(areDraftToolbarActionsDisabled || onOpenTerminal == nil)
        } label: {
            TurnMacHandoffToolbarLabel(isLoading: false)
        }
        .opacity(areDraftToolbarActionsDisabled ? 0.45 : 1)
        .disabled(areDraftToolbarActionsDisabled)
        .accessibilityLabel("Thread actions")
    }

    private var areDraftToolbarActionsDisabled: Bool {
        !hasSelectedProject
    }

    private var isDraftGitActionEnabled: Bool {
        !areDraftToolbarActionsDisabled
            && viewModel.gitRepoSync != nil
            && viewModel.canRunGitAction(
                isConnected: codex.isConnected,
                isThreadRunning: false,
                hasGitWorkingDirectory: selectedProjectPath != nil
            )
    }

    // Preloads the same repo/branch status TurnView uses whenever there is an
    // actual selected project. General Chat starts enabled too if it defaulted
    // to the latest-used project; only Quick Chat stays blocked.
    private func refreshDraftGitStateIfNeeded() {
        guard hasSelectedProject, codex.isConnected else {
            return
        }
        viewModel.refreshGitBranchTargets(
            codex: codex,
            workingDirectory: selectedProjectPath,
            threadID: route.id
        )
    }

    private var hasSelectedProject: Bool {
        selectedProjectPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func handleDraftGitActionSelection(_ action: TurnGitActionKind) {
        guard isDraftGitActionEnabled else { return }
        viewModel.triggerGitAction(
            action,
            codex: codex,
            workingDirectory: selectedProjectPath,
            threadID: route.id,
            activeTurnID: nil
        )
    }

    // Fetches the repo patch for folder-backed drafts so the Git menu's
    // "Changes" row matches the regular TurnView toolbar behavior.
    private func presentRepositoryDiff() {
        guard !isLoadingRepositoryDiff,
              !areDraftToolbarActionsDisabled else {
            return
        }
        isLoadingRepositoryDiff = true

        Task { @MainActor in
            defer { isLoadingRepositoryDiff = false }

            let gitService = GitActionsService(codex: codex, workingDirectory: selectedProjectPath)
            do {
                let result = try await gitService.diff()
                guard let presentation = TurnDiffPresentationBuilder.repositoryPresentation(from: result.patch) else {
                    viewModel.gitSyncAlert = TurnGitSyncAlert(
                        title: "Git Error",
                        message: "There are no repository changes to show.",
                        action: .dismissOnly
                    )
                    return
                }
                repositoryDiffPresentation = presentation
            } catch let error as GitActionsError {
                viewModel.gitSyncAlert = TurnGitSyncAlert(
                    title: "Git Error",
                    message: error.errorDescription ?? "Could not load repository changes.",
                    action: .dismissOnly
                )
            } catch {
                viewModel.gitSyncAlert = TurnGitSyncAlert(
                    title: "Git Error",
                    message: error.localizedDescription,
                    action: .dismissOnly
                )
            }
        }
    }

    private var isShowingNothingToCommitAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isShowingNothingToCommitAlert },
            set: { viewModel.isShowingNothingToCommitAlert = $0 }
        )
    }

    private var gitSyncAlertBinding: Binding<TurnGitSyncAlert?> {
        Binding(
            get: { viewModel.gitSyncAlert },
            set: { newValue in
                if let newValue {
                    viewModel.gitSyncAlert = newValue
                } else {
                    viewModel.dismissGitSyncAlert()
                }
            }
        )
    }

    private var placeholderFolderName: String? {
        guard let selectedProjectPath,
              !selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return selectedProjectPath.pathDisplayName
    }

    // Always reads the same way as the toolbar subtitle so the pill and the
    // navigation block never disagree on what folder is currently bound.
    private var folderPillLabel: String {
        placeholderFolderName ?? "Quick Chat"
    }

    // Inline tap target: folder icon + name + chevron.up.chevron.down sized
    // at body so it sits visually under the title3 prompt without competing
    // with it for emphasis.
    private var folderPickerPill: some View {
        Button {
            HapticFeedback.shared.triggerImpactFeedback(style: .light)
            activeSheet = .projectPicker
        } label: {
            HStack(spacing: 8) {
                pickerIcon
                    .frame(width: 24, height: 24)

                Text(folderPillLabel)
                    .font(AppFont.title2(weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "chevron.up.chevron.down")
                    .font(AppFont.caption())
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select folder")
        .accessibilityHint("Opens the project picker")
        .accessibilityValue(folderPillLabel)
    }

    // Uses the Remodex custom asset set directly: chat bubbles for Quick Chat,
    // folder glyph for project-backed drafts.
    private var pickerIcon: some View {
        Image(placeholderFolderName == nil ? "central-chat-bubbles" : "central-folder-2")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
    }

    private var trustedHostName: String? {
        let trimmed = (codex.trustedPairPresentation?.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var composer: some View {
        TurnComposerHostView(
            viewModel: viewModel,
            codex: codex,
            thread: draftThread,
            activeTurnID: nil,
            isThreadRunning: false,
            isEmptyThread: true,
            isWorktreeProject: false,
            canForkLocally: false,
            isInputFocused: $isInputFocused,
            orderedModelOptions: orderedModelOptions,
            selectedModelTitle: selectedModelTitle,
            reasoningDisplayOptions: reasoningDisplayOptions,
            showsGitControls: hasSelectedProject && viewModel.isGitRepositoryInitialized,
            isGitBranchSelectorEnabled: isDraftGitActionEnabled && viewModel.isGitRepositoryInitialized,
            onSelectGitBranch: { _ in },
            onCreateGitBranch: { _ in },
            onRefreshGitBranches: {
                guard hasSelectedProject, viewModel.isGitRepositoryInitialized else { return }
                viewModel.refreshGitBranchTargets(
                    codex: codex,
                    workingDirectory: selectedProjectPath,
                    threadID: route.id
                )
            },
            onStartCodeReviewThread: { target in
                viewModel.applyPendingComposerAction(.codeReview(target: target.codexPendingTarget))
            },
            onStartForkThreadLocally: {},
            onOpenForkWorktree: {},
            onOpenWorktreeHandoff: {},
            onOpenFeedbackMail: {},
            onShowStatus: {},
            voiceButtonPresentation: TurnVoiceButtonPresentationBuilder.presentation(
                isTranscribing: false,
                isPreflighting: false,
                isRecording: false,
                isConnected: codex.isConnected
            ),
            isVoiceRecording: false,
            voiceAudioLevels: [],
            voiceRecordingDuration: 0,
            onTapVoice: {},
            onCancelVoiceRecording: {},
            onSend: sendDraft,
            showsSecondaryBar: hasSelectedProject
        )
    }

    private var draftThread: CodexThread {
        CodexThread(
            id: route.id,
            title: "New thread",
            cwd: selectedProjectPath
        )
    }

    private var projectChoices: [SidebarProjectChoice] {
        SidebarThreadGrouping.makeProjectChoices(
            from: codex.threads,
            projectlessRootPaths: projectlessChatRootPaths
        )
    }

    private var orderedModelOptions: [CodexModelOption] {
        TurnComposerMetaMapper.orderedModels(from: codex.availableModels)
    }

    private var reasoningDisplayOptions: [TurnComposerReasoningDisplayOption] {
        TurnComposerMetaMapper.reasoningDisplayOptions(
            from: codex.supportedReasoningEffortsForSelectedModel().map(\.reasoningEffort)
        )
    }

    private var selectedModelTitle: String {
        if let selectedModel = codex.selectedModelOption() {
            return TurnComposerMetaMapper.modelTitle(for: selectedModel)
        }

        return TurnComposerMetaMapper.modelTitle(forIdentifier: codex.selectedModelId)
    }

    private var isPhotoPickerPresentedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isPhotoPickerPresented },
            set: { viewModel.isPhotoPickerPresented = $0 }
        )
    }

    private var isCameraPresentedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isCameraPresented },
            set: { viewModel.isCameraPresented = $0 }
        )
    }

    private var photoPickerItemsBinding: Binding<[PhotosPickerItem]> {
        Binding(
            get: { viewModel.photoPickerItems },
            set: { viewModel.photoPickerItems = $0 }
        )
    }

    private func initializeProjectSelectionIfNeeded() {
        guard !hasInitializedProjectSelection else { return }

        selectedProjectPath = CodexThreadStartProjectBinding.normalizedProjectPath(route.preferredProjectPath)
            ?? projectChoices.first?.projectPath
        hasInitializedProjectSelection = selectedProjectPath != nil || !projectChoices.isEmpty
    }

    private func refreshProjectlessChatRoots() async {
        guard codex.isConnected else { return }

        do {
            let roots = try await codex.fetchProjectlessChatRoots().roots
            guard roots != projectlessChatRootPaths else { return }
            projectlessChatRootPaths = roots
            initializeProjectSelectionIfNeeded()
        } catch {
            // Project grouping still has built-in fallbacks for older local bridges.
        }
    }

    private func sendDraft() {
        isInputFocused = false
        viewModel.clearComposerAutocomplete()
        viewModel.sendNewThread(
            codex: codex,
            subscriptions: subscriptions,
            draftThreadID: route.id,
            preferredProjectPath: selectedProjectPath,
            onThreadCreated: onOpenThread
        )
    }

    @ViewBuilder
    private func sheetContent(_ sheet: NewChatDraftSheet) -> some View {
        switch sheet {
        case .projectPicker:
            SidebarNewChatProjectPickerSheet(
                choices: projectChoices,
                showsWithoutProjectOption: false,
                showsWorktreeOptions: false,
                onSelectProject: { projectPath in
                    selectedProjectPath = projectPath
                    activeSheet = nil
                },
                onSelectWorktreeProject: { projectPath in
                    selectedProjectPath = projectPath
                    activeSheet = nil
                },
                onSelectWithoutProject: {
                    selectedProjectPath = nil
                    activeSheet = nil
                },
                onBrowseLocalFolder: {
                    activeSheet = .localFolderBrowser
                }
            )
        case .localFolderBrowser:
            SidebarLocalFolderBrowserSheet { projectPath in
                selectedProjectPath = projectPath
                activeSheet = nil
            }
        }
    }
}

private enum NewChatDraftSheet: String, Identifiable {
    case projectPicker
    case localFolderBrowser

    var id: String { rawValue }
}

#Preview("New Chat Draft") {
    NavigationStack {
        NewChatDraftView(
            route: NewChatDraftRoute(
                id: "draft_preview",
                preferredProjectPath: "/Users/emanueledipietro/Developer/Remodex",
                source: .generalChat
            ),
            onOpenThread: { _ in }
        )
    }
    .environment(CodexService())
    .environment(SubscriptionService())
}

#Preview("New Chat Draft – No Folder") {
    NavigationStack {
        NewChatDraftView(
            route: NewChatDraftRoute(
                id: "draft_preview_no_folder",
                preferredProjectPath: nil,
                source: .generalChat
            ),
            onOpenThread: { _ in }
        )
    }
    .environment(CodexService())
    .environment(SubscriptionService())
}

#Preview("New Chat Draft – Folder Button") {
    NavigationStack {
        NewChatDraftView(
            route: NewChatDraftRoute(
                id: "draft_preview_folder_button",
                preferredProjectPath: "/Users/emanueledipietro/Developer/Remodex",
                source: .folderChat
            ),
            onOpenThread: { _ in }
        )
    }
    .environment(CodexService())
    .environment(SubscriptionService())
}
