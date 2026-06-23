import SwiftUI

struct AgentSettingsView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color

    @State private var currentClaudeDir: String = AppSettings.claudeDirectoryName
    @State private var claudeHooksInstalled = false
    @State private var codexHooksInstalled = false
    @State private var opencodeHooksInstalled = false
    @State private var cursorHooksInstalled = false
    @State private var debugLogOn: Bool = AppSettings.debugLogEnabled
    @State private var didAppear = false
    // Hover state for the debug log row. Agent main rows now reuse
    // MenuRow (which owns its own hover state), so only the debug log
    // row — which is still hand-rolled — needs an external hover flag.
    @State private var debugLogRowHovered = false

    private var claudeInstalled: Bool { AgentPathsResolver.isInstalled(.claude) }
    private var codexInstalled: Bool { AgentPathsResolver.isInstalled(.codex) }
    private var opencodeInstalled: Bool { AgentPathsResolver.isInstalled(.opencode) }
    private var cursorInstalled: Bool { AgentPathsResolver.isInstalled(.cursor) }

    // MARK: - Keyboard nav indices
    //
    // Visual order: Back, Claude main, [Claude picker × 2 if expanded],
    // [Claude hooks if installed], Codex main, [Codex hooks if installed],
    // OpenCode main, [OpenCode hooks if installed], Cursor main,
    // [Cursor hooks if installed], Debug log.
    private let backIndex = 0
    private let claudeMainIndex = 1
    private let claudeAutoDetectIndex = 2
    private let claudeChooseFolderIndex = 3
    private var claudeHooksIndex: Int? {
        guard claudeInstalled else { return nil }
        // Claude hooks sits right after Claude main (and the two picker
        // options, when the picker is expanded). So index is 2 collapsed,
        // 4 expanded.
        return claudeMainIndex + 1 + (viewModel.agentsClaudeDirPickerExpanded ? 2 : 0)
    }
    private var codexMainIndex: Int {
        // Codex main sits right after Claude's block (main + optional picker + optional hooks).
        var idx = claudeMainIndex + 1
        if viewModel.agentsClaudeDirPickerExpanded { idx += 2 }
        if claudeInstalled { idx += 1 }
        return idx
    }
    private var codexHooksIndex: Int? {
        guard codexInstalled else { return nil }
        return codexMainIndex + 1
    }
    private var opencodeMainIndex: Int {
        var idx = codexMainIndex + 1
        if codexInstalled { idx += 1 }
        return idx
    }
    private var opencodeHooksIndex: Int? {
        guard opencodeInstalled else { return nil }
        return opencodeMainIndex + 1
    }
    private var cursorMainIndex: Int {
        var idx = opencodeMainIndex + 1
        if opencodeInstalled { idx += 1 }
        return idx
    }
    private var cursorHooksIndex: Int? {
        guard cursorInstalled else { return nil }
        return cursorMainIndex + 1
    }
    private var debugLogIndex: Int {
        var idx = cursorMainIndex + 1
        if cursorInstalled { idx += 1 }
        return idx
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 4) {
                backButton
                Divider().background(separatorColor).padding(.vertical, 4)
                ForEach(SessionProvider.allCases, id: \.self) { provider in
                    agentSection(provider)
                }
                Divider().background(separatorColor).padding(.vertical, 4)
                debugLogSection
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                GeometryReader { g in
                    Color.clear
                        .preference(key: AgentsContentHeightKey.self, value: g.size.height)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(AgentsContentHeightKey.self) { height in
            viewModel.agentsContentHeight = height
        }
        .onAppear {
            didAppear = true
            refreshStates()
            // Match the convention used by SoundPickerRow / ScreenPickerRow /
            // ChatView section toggles: every picker defaults to closed and
            // resets when the page is re-entered. Perf Metrics is the only
            // outlier (its expansion persists via VM-level @Published) —
            // we don't follow that pattern here.
            viewModel.agentsClaudeDirPickerExpanded = false
        }
        .onChange(of: viewModel.contentType) { _, newValue in
            if newValue == .agents {
                didAppear = true
                refreshStates()
                viewModel.agentsClaudeDirPickerExpanded = false
            }
        }
        // If the Claude picker collapses (mouse click or keyboard) while the
        // focus was inside the picker block, snap focus back to Claude main
        // so the highlight stays consistent with what's rendered. The picker
        // block covers indices 2..4 when expanded: the two picker options
        // (2, 3) vanish, and Claude hooks shifts from 4 → 2, so a stale
        // focus at 4 would land on Codex hooks after collapse.
        .onChange(of: viewModel.agentsClaudeDirPickerExpanded) { _, isExpanded in
            if !isExpanded {
                let i = viewModel.settingsFocusedIndex
                if (2...4).contains(i) {
                    viewModel.settingsFocusedIndex = claudeMainIndex
                }
            }
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            performFocusedAction()
        }
    }

    // MARK: - Keyboard activation

    private func performFocusedAction() {
        let i = viewModel.settingsFocusedIndex
        switch i {
        case backIndex:
            viewModel.navigateBack()
        case claudeMainIndex:
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.agentsClaudeDirPickerExpanded.toggle()
            }
        case codexMainIndex, opencodeMainIndex, cursorMainIndex:
            break // Static rows — no action on activate.
        case debugLogIndex:
            toggleDebugLog()
        case claudeAutoDetectIndex where viewModel.agentsClaudeDirPickerExpanded:
            applyClaudeDirChoice(path: "")
        case claudeChooseFolderIndex where viewModel.agentsClaudeDirPickerExpanded:
            openClaudeFolderPicker()
        default:
            // Hooks toggles
            if i == claudeHooksIndex {
                toggleHooks(provider: .claude, currentlyOn: hooksInstalled(.claude))
            } else if i == codexHooksIndex {
                toggleHooks(provider: .codex, currentlyOn: hooksInstalled(.codex))
            } else if i == opencodeHooksIndex {
                toggleHooks(provider: .opencode, currentlyOn: hooksInstalled(.opencode))
            } else if i == cursorHooksIndex {
                toggleHooks(provider: .cursor, currentlyOn: hooksInstalled(.cursor))
            }
        }
    }

    private func toggleDebugLog() {
        withAnimation {
            debugLogOn.toggle()
            AppSettings.debugLogEnabled = debugLogOn
            if debugLogOn {
                DebugLog.shared.enable()
                DebugLog.shared.write("debug log enabled from settings UI")
            } else {
                DebugLog.shared.write("debug log disabled from settings UI")
                DebugLog.shared.disable()
            }
        }
    }

    // MARK: - Back Button

    private var backButton: some View {
        MenuRow(
            icon: "chevron.left",
            label: "Back",
            primaryTextColor: primaryTextColor,
            isFocused: viewModel.settingsFocusedIndex == backIndex
        ) {
            viewModel.navigateBack()
        }
    }

    // MARK: - Agent Section

    @ViewBuilder
    private func agentSection(_ provider: SessionProvider) -> some View {
        let installed = isInstalled(provider)
        let hooksOn = hooksInstalled(provider)

        VStack(spacing: 2) {
            // Claude uses the same `ExpandableSettingsRow` as the home-page
            // Sound/Screen pickers and the Performance Visible Metrics
            // picker — so hover/focus styling and the expand/collapse
            // animation are consistent. (The shared component also avoids
            // the agents-page scrollbar flash: see `NotchView`'s
            // `.animation(.settingsExpand, value: notchSize)` for the
            // root-cause fix.)
            if provider == .claude {
                ExpandableSettingsRow(
                    icon: provider.systemImage,
                    customIcon: brandIcon(for: provider),
                    label: provider.displayName,
                    trailingText: AgentPathsResolver.displayPath(for: provider),
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == claudeMainIndex,
                    isExpanded: $viewModel.agentsClaudeDirPickerExpanded
                ) {
                    claudeDirPickerOptions
                }
            } else {
                // Codex / OpenCode / Cursor: reuse MenuRow directly so
                // styling is 100% inherited from the shared component.
                // Pass a brand logo for Codex/Cursor via customIcon;
                // OpenCode uses the SF Symbol from systemImage.
                let mainIndex: Int = {
                    switch provider {
                    case .codex:    return codexMainIndex
                    case .opencode: return opencodeMainIndex
                    case .cursor:   return cursorMainIndex
                    default:        return 0 // unreachable for static rows
                    }
                }()
                MenuRow(
                    icon: provider.systemImage,
                    customIcon: brandIcon(for: provider),
                    label: provider.displayName,
                    trailingLabel: installed
                        ? AgentPathsResolver.displayPath(for: provider)
                        : "Not installed",
                    trailingLabelDesign: installed ? .monospaced : .default,
                    trailingLabelDimmed: !installed,
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == mainIndex
                ) {
                    // Static row — no action on click.
                }
            }

            if installed {
                hooksToggle(provider: provider, hooksOn: hooksOn)
                    .padding(.leading, 28)
            }
        }
    }

    /// Brand icon for a provider, or `nil` to fall back to the SF Symbol
    /// supplied via `icon:` in MenuRow / ExpandableSettingsRow.
    /// - Claude: `ClaudeCrabIcon` (the app's crab mascot)
    /// - Codex: Codex logo
    /// - Cursor: Cursor logo
    /// - OpenCode: `OpenCodeLogoIcon` (square ring, official brand mark)
    ///
    /// Each icon is wrapped in a 16×16 frame so the icon column is
    /// uniform across all four providers. ClaudeCrabIcon's natural
    /// aspect is 66/52 (wider than tall) so we pass `size: 12.6` to
    /// make its natural width 16 and keep height at 12.6 — preserving
    /// the full crab shape. Codex and Cursor canvases are square, so
    /// we pass `size: 16` to fill the slot edge-to-edge.
    private func brandIcon(for provider: SessionProvider) -> AnyView? {
        switch provider {
        case .claude:
            // size: 12.6 → natural 16 wide × 12.6 tall; frame centers it.
            // Crab is wider than tall; squeezing it into 16×16 would
            // crop the leg tips and antennae.
            return AnyView(
                ClaudeCrabIcon(size: 12.6)
                    .frame(width: 16, height: 16)
            )
        case .codex:
            return AnyView(
                CodexLogoIcon(size: 16, color: SessionLoadingStyle.tint(for: .codex))
                    .frame(width: 16, height: 16)
            )
        case .cursor:
            return AnyView(
                CursorLogoIcon(size: 16, color: primaryTextColor.opacity(0.82))
                    .frame(width: 16, height: 16)
            )
        case .opencode:
            return AnyView(
                OpenCodeLogoIcon(size: 16, color: primaryTextColor)
                    .frame(width: 16, height: 16)
            )
        }
    }

    // MARK: - Claude Directory Picker Options

    private var claudeDirPickerOptions: some View {
        VStack(spacing: 2) {
            SettingsSubPickerRow(
                label: "Auto-detect",
                sublabel: resolvedAutoDetectPath,
                sublabelDesign: .monospaced,
                isSelected: !isCustomClaudeDir,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor,
                isFocused: viewModel.settingsFocusedIndex == claudeAutoDetectIndex
            ) {
                applyClaudeDirChoice(path: "")
            }

            SettingsSubPickerRow(
                label: "Choose folder…",
                sublabel: isCustomClaudeDir ? shortenedPath(currentClaudeDir) : nil,
                sublabelDesign: .monospaced,
                isSelected: isCustomClaudeDir,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor,
                isFocused: viewModel.settingsFocusedIndex == claudeChooseFolderIndex
            ) {
                openClaudeFolderPicker()
            }
        }
    }

    private var isCustomClaudeDir: Bool {
        !currentClaudeDir.isEmpty && currentClaudeDir != ".claude"
    }

    private var resolvedAutoDetectPath: String {
        shortenedPath(ClaudePaths.claudeDir.path)
    }

    // MARK: - Hooks Toggle

    private func hooksToggle(provider: SessionProvider, hooksOn: Bool) -> some View {
        let focusedIndex: Int? = {
            switch provider {
            case .claude:   return claudeHooksIndex
            case .codex:    return codexHooksIndex
            case .opencode: return opencodeHooksIndex
            case .cursor:   return cursorHooksIndex
            }
        }()
        return SettingsSubToggleRow(
            label: "Hooks",
            isOn: hooksOn,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            isFocused: focusedIndex.map { viewModel.settingsFocusedIndex == $0 } ?? false,
            locked: false
        ) {
            withAnimation {
                toggleHooks(provider: provider, currentlyOn: hooksOn)
            }
        }
    }

    // MARK: - Debug Log Section

    /// Diagnostic toggle: when enabled, internal log output is mirrored
    /// to `/tmp/nook-debug.log` (10 MB rolling, recreated on launch).
    /// Off by default because the file grows during normal use and is
    /// only useful when reproducing a specific bug.
    private var debugLogSection: some View {
        let isFocused = viewModel.settingsFocusedIndex == debugLogIndex
        // Match MenuToggleRow's text-on-hover behavior: label and icon
        // brighten from 0.82 → 1.0 on hover so the row feels alive even
        // without a background change.
        let textColor = primaryTextColor.opacity(debugLogRowHovered ? 1.0 : 0.82)
        return Button {
            toggleDebugLog()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "ladybug")
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text("Debug log")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Text("/tmp/nook-debug.log")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Circle()
                    .fill(debugLogOn ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(debugLogOn ? "On" : "Off")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFocused ? Color.white.opacity(0.12) : (debugLogRowHovered ? Color.white.opacity(0.08) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { debugLogRowHovered = $0 }
        .help("Mirror internal log output to /tmp/nook-debug.log (10 MB, rotated). Restart the app to clear the file.")
    }

    // MARK: - Actions

    private func toggleHooks(provider: SessionProvider, currentlyOn: Bool) {
        switch provider {
        case .claude:
            if currentlyOn {
                HookInstaller.uninstall()
                claudeHooksInstalled = false
            } else {
                HookInstaller.installIfNeeded()
                claudeHooksInstalled = true
            }
            AppSettings.claudeHooksEnabled = !currentlyOn
        case .codex:
            if currentlyOn {
                CodexHookInstaller.uninstall()
                codexHooksInstalled = false
            } else {
                CodexHookInstaller.installIfNeeded()
                codexHooksInstalled = true
            }
            AppSettings.codexHooksEnabled = !currentlyOn
        case .opencode:
            if currentlyOn {
                OpencodeHookInstaller.uninstall()
                opencodeHooksInstalled = false
            } else {
                OpencodeHookInstaller.installIfNeeded()
                opencodeHooksInstalled = true
            }
            AppSettings.opencodeHooksEnabled = !currentlyOn
        case .cursor:
            if currentlyOn {
                CursorHookInstaller.uninstall()
                cursorHooksInstalled = false
            } else {
                CursorHookInstaller.installIfNeeded()
                cursorHooksInstalled = true
            }
            AppSettings.cursorHooksEnabled = !currentlyOn
        }
    }

    private func applyClaudeDirChoice(path: String) {
        currentClaudeDir = path
        AppSettings.claudeDirectoryName = path
        ClaudePaths.invalidateCache()
        if AppSettings.autoInstallHooks && AppSettings.claudeHooksEnabled {
            HookInstaller.installIfNeeded()
        }
        claudeHooksInstalled = HookInstaller.isInstalled()
    }

    private func openClaudeFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude Config Directory"
        panel.message = "Select the folder Claude Code uses (typically ~/.claude or ~/.config/claude)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = false
        panel.directoryURL = ClaudePaths.claudeDir

        let notchWindow = NSApp.windows.first { $0 is NotchPanel }
        let originalLevel = notchWindow?.level ?? (.mainMenu + 3)
        let wasIgnoring = notchWindow?.ignoresMouseEvents ?? true
        notchWindow?.level = .normal
        notchWindow?.ignoresMouseEvents = true

        let response = panel.runModal()

        notchWindow?.level = originalLevel
        notchWindow?.ignoresMouseEvents = wasIgnoring

        if response == .OK, let url = panel.url {
            applyClaudeDirChoice(path: url.path)
        }
    }

    // MARK: - Helpers

    private func isInstalled(_ provider: SessionProvider) -> Bool {
        AgentPathsResolver.isInstalled(provider)
    }

    private func hooksInstalled(_ provider: SessionProvider) -> Bool {
        switch provider {
        case .claude: return claudeHooksInstalled
        case .codex: return codexHooksInstalled
        case .opencode: return opencodeHooksInstalled
        case .cursor: return cursorHooksInstalled
        }
    }

    private func refreshStates() {
        claudeHooksInstalled = HookInstaller.isInstalled()
        codexHooksInstalled = CodexHookInstaller.isInstalled()
        opencodeHooksInstalled = OpencodeHookInstaller.isInstalled()
        cursorHooksInstalled = CursorHookInstaller.isInstalled()
        currentClaudeDir = AppSettings.claudeDirectoryName
    }

    private func shortenedPath(_ raw: String) -> String {
        let path = raw.hasPrefix("/") ? raw : NSHomeDirectory() + "/" + raw
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Content Height Key

private struct AgentsContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
