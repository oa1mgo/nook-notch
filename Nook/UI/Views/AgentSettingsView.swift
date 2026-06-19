import SwiftUI

struct AgentSettingsView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color

    @State private var claudeDirPickerExpanded = false
    @State private var currentClaudeDir: String = AppSettings.claudeDirectoryName
    @State private var claudeHooksInstalled = false
    @State private var codexHooksInstalled = false
    @State private var opencodeHooksInstalled = false
    @State private var cursorHooksInstalled = false
    @State private var debugLogOn: Bool = AppSettings.debugLogEnabled
    @State private var didAppear = false

    private var claudeInstalled: Bool { AgentPathsResolver.isInstalled(.claude) }
    private var codexInstalled: Bool { AgentPathsResolver.isInstalled(.codex) }
    private var opencodeInstalled: Bool { AgentPathsResolver.isInstalled(.opencode) }
    private var cursorInstalled: Bool { AgentPathsResolver.isInstalled(.cursor) }

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
        }
        .onChange(of: viewModel.contentType) { _, newValue in
            if newValue == .agents {
                didAppear = true
                refreshStates()
            }
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            if viewModel.settingsFocusedIndex == 0 {
                viewModel.navigateBack()
            }
        }
    }

    // MARK: - Back Button

    private var backButton: some View {
        MenuRow(
            icon: "chevron.left",
            label: "Back",
            primaryTextColor: primaryTextColor,
            isFocused: viewModel.settingsFocusedIndex == 0
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
            agentMainRow(provider: provider, installed: installed)

            if installed {
                VStack(spacing: 2) {
                    if provider == .claude && claudeDirPickerExpanded {
                        claudeDirPickerOptions
                            .padding(.leading, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    hooksToggle(provider: provider, hooksOn: hooksOn)
                }
                .padding(.leading, 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Main Row (merged: icon + name + path + hooks indicator)

    @ViewBuilder
    private func agentMainRow(provider: SessionProvider, installed: Bool) -> some View {
        let bg = RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03))

        if provider == .claude {
            // Claude: entire row is one button that expands the dir picker.
            // Status indicator is purely decorative here.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    claudeDirPickerExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    settingsProviderIcon(provider)

                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(primaryTextColor.opacity(0.82))

                    Spacer()

                    Text(AgentPathsResolver.displayPath(for: provider))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: claudeDirPickerExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(secondaryTextColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(bg)
        } else {
            // Codex / OpenCode / Cursor: static row with decorative indicator.
            HStack(spacing: 10) {
                settingsProviderIcon(provider)

                Text(provider.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(primaryTextColor.opacity(0.82))

                if installed {
                    Spacer()

                    Text(AgentPathsResolver.displayPath(for: provider))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Spacer()

                    Text("Not installed")
                        .font(.system(size: 11))
                        .foregroundColor(primaryTextColor.opacity(0.35))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(bg)
        }
    }

    @ViewBuilder
    private func settingsProviderIcon(_ provider: SessionProvider) -> some View {
        if provider == .cursor {
            CursorLogoIcon(size: 16, color: primaryTextColor.opacity(0.82))
                .frame(width: 16)
        } else {
            Image(systemName: provider.systemImage)
                .font(.system(size: 12))
                .foregroundColor(primaryTextColor.opacity(0.82))
                .frame(width: 16)
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
                secondaryTextColor: secondaryTextColor
            ) {
                applyClaudeDirChoice(path: "")
            }

            SettingsSubPickerRow(
                label: "Choose folder…",
                sublabel: isCustomClaudeDir ? shortenedPath(currentClaudeDir) : nil,
                sublabelDesign: .monospaced,
                isSelected: isCustomClaudeDir,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
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
        SettingsSubToggleRow(
            label: "Hooks",
            isOn: hooksOn,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            isFocused: false,
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
        Button {
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
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "ladybug")
                    .font(.system(size: 12))
                    .foregroundColor(primaryTextColor.opacity(0.82))
                    .frame(width: 16)

                Text("Debug log")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(primaryTextColor.opacity(0.82))

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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
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
