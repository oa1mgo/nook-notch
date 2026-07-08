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
    /// Once `true`, the initial GeometryReader measurement has been
    /// recorded and subsequent `onPreferenceChange` callbacks are
    /// ignored. This prevents the feedback loop from overwriting the
    /// incremental updates (which use the compile-time
    /// `claudeDirPickerLayout.expandedHeight`) and causing scrollbar
    /// flicker.
    @State private var baseHeightRecorded = false

    /// Compile-time layout for the Claude dir picker. Per-row heights
    /// because each row's sublabel presence varies at runtime:
    ///
    /// - "Auto-detect" — sublabel is `resolvedAutoDetectPath`
    ///   (`ClaudePaths.claudeDir.path`), always non-nil → renders at
    ///   `settingsSubPickerRowVerticalSublabelHeight`.
    /// - "Choose folder…" — sublabel is `isCustomClaudeDir ? path : nil`
    ///   → renders at `settingsSubPickerRowVerticalSublabelHeight` when
    ///   a custom path is set, else at `settingsSubPickerRowHeight`
    ///   with the title centered (SettingsSubPickerRow auto-falls-back
    ///   to the small inline layout when its sublabel is nil, even if
    ///   the caller asked for `verticalSublabel: true`).
    ///
    /// Converting from `static` to instance lets the layout track
    /// `currentClaudeDir` reactively, which is required when the user
    /// picks "Auto-detect" while the picker is open — the layout
    /// shrinks and `agentsContentHeight` must follow it to keep the
    /// panel ScrollView contentSize and `openedSize.height` in lock-
    /// step (no scrollbar flicker).
    private var claudeDirPickerLayout: PickerLayout {
        let autoHeight = settingsSubPickerRowVerticalSublabelHeight
        let chooseHeight = isCustomClaudeDir
            ? settingsSubPickerRowVerticalSublabelHeight
            : settingsSubPickerRowHeight
        return PickerLayout(rowHeights: [autoHeight, chooseHeight])
    }
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
            // Record the initial base height (no picker expanded) from
            // the GeometryReader's first measurement. After that,
            // `agentsContentHeight` is updated incrementally by the
            // picker's `onToggle` callback and the keyboard handler —
            // using the compile-time `claudeDirPickerLayout.expandedHeight`.
            //
            // NOT overwriting here eliminates the double-source-of-truth
            // conflict that caused scrollbar flicker: the old code ran
            // `withAnimation { agentsContentHeight = height }` on every
            // GeometryReader report, which fought the incremental
            // `+= expandedHeight` updates and briefly put the panel
            // shorter than the content during collapse → scrollbar flash.
            if !baseHeightRecorded {
                baseHeightRecorded = true
                // Persist the base height so navigation round-trips can
                // reset `agentsContentHeight` back to baseline instead
                // of carrying over the stale `+= expandedHeight` from
                // the previous session — which would re-open the panel
                // at the expanded height with the picker closed.
                viewModel.agentsBaseHeight = height
                viewModel.agentsContentHeight = height
            }
            // DIAGNOSTIC: log scrollbar visibility state
            let headerHeight = settingsPageHeaderHeight(for: viewModel.geometry)
            let visibleArea = viewModel.openedSize.height - headerHeight - 12
            let overflow = height - visibleArea
            let willScroll = overflow > 0.5
            DebugLog.shared.write("[agents-pref] vstack=\(String(format: "%.1f", height))pt agentsHeight=\(String(format: "%.1f", viewModel.agentsContentHeight))pt openedSize=\(String(format: "%.1f", viewModel.openedSize.height))pt visibleArea=\(String(format: "%.1f", visibleArea))pt overflow=\(String(format: "%.1f", overflow))pt scrollbar=\(willScroll ? "VISIBLE" : "hidden")")
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
            // Reset content height in lock-step — the picker's expanded
            // height (88pt) was added on the previous session and
            // persists on `viewModel` across View instances.
            viewModel.agentsContentHeight = viewModel.agentsBaseHeight
        }
        .onChange(of: viewModel.contentType) { oldValue, newValue in
            if oldValue == .agents && newValue != .agents {
                // EXIT — reset transient state BEFORE the new View is
                // created. Doing this here (rather than only on the next
                // ENTRY's onAppear) avoids a race where the new View's
                // first GeometryReader / layout pass reads the still-
                // expanded picker state and snapshots a stale height.
                viewModel.agentsClaudeDirPickerExpanded = false
                viewModel.agentsContentHeight = viewModel.agentsBaseHeight
            }
            if newValue == .agents {
                // ENTRY — refresh. The EXIT reset above is the
                // authoritative one; this branch handles the very first
                // navigation into agents.
                didAppear = true
                refreshStates()
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
        // Reconcile the panel height when `currentClaudeDir` changes
        // while the picker is still open. The "Choose folder…" row's
        // sublabel-presence drives the picker's per-row height (see
        // `claudeDirPickerLayout`); without this handler, switching
        // between "Auto-detect" and a custom path with the picker
        // open would leave the panel either under-sized or with a
        // blank band at the bottom — the same drift bug that full-
        // recompute aims to avoid everywhere else.
        .onChange(of: currentClaudeDir) { _, _ in
            if viewModel.agentsClaudeDirPickerExpanded {
                viewModel.agentsContentHeight = agentsContentHeight
            }
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            performFocusedAction()
        }
    }

    // MARK: - Keyboard activation

    /// Full-recompute target for `agentsContentHeight`. Replaces the
    /// previous incremental `+=`/`-=` pattern — `currentClaudeDir` can
    /// change while the picker is open (e.g. the user picks a folder
    /// via the panel and we land back on the picker), which would
    /// otherwise drift from the picker layout's actual size.
    private var agentsContentHeight: CGFloat {
        viewModel.agentsBaseHeight
            + (viewModel.agentsClaudeDirPickerExpanded
               ? claudeDirPickerLayout.expandedHeight
               : 0)
    }

    private func performFocusedAction() {
        let i = viewModel.settingsFocusedIndex
        switch i {
        case backIndex:
            viewModel.navigateBack()
        case claudeMainIndex:
            // Animate both panel height and picker frame in the same
            // withAnimation block so the OUTER ScrollView's contentView
            // tracks the VStack's contentSize. Target height comes from
            // the compile-time `claudeDirPickerLayout` — no measurement.
            let newExpanded = !viewModel.agentsClaudeDirPickerExpanded
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.agentsClaudeDirPickerExpanded = newExpanded
                viewModel.agentsContentHeight = agentsContentHeight
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
                    isExpanded: $viewModel.agentsClaudeDirPickerExpanded,
                    targetHeight: claudeDirPickerLayout.expandedHeight,
                    onToggle: { _, _ in
                        // `agentsClaudeDirPickerExpanded` is already
                        // mutated by the binding setter inside the same
                        // `withAnimation` block — re-derive the full
                        // content height from `baseHeight + (expanded ?
                        // layout : 0)` so any drift between
                        // `currentClaudeDir` changes and the layout
                        // (e.g. user picks "Auto-detect" while the
                        // picker is open) is reconciled here.
                        viewModel.agentsContentHeight = agentsContentHeight
                    }
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

    /// Brand icon for a provider, returned as `some View` so the
    /// concrete type is preserved (no `AnyView` heap allocation).
    /// Generic `MenuRow<Icon>` infers `Icon` from the opaque return
    /// at the call site.
    /// - Claude: `ClaudeCrabIcon` (the app's crab mascot)
    /// - Codex: Codex logo
    /// - Cursor: Cursor logo
    /// - OpenCode: `OpenCodeLogoIcon` (square ring, official brand mark)
    ///
    /// Each icon is wrapped in a 16×16 frame so the icon column is
    /// uniform across all four providers. Sizing rationale:
    /// - Claude size 12.6 → natural 16×12.6, crab is wider than tall
    /// - Codex / Cursor size 16 → fill the 16×16 slot edge-to-edge
    /// - **OpenCode size 13** → drawn at ~10.4×13 in a 13×13 canvas,
    ///   then padded to 16×16. The OpenCode ring outline is solid
    ///   white at full opacity (highest contrast on the dark menu),
    ///   so drawing it at full 16 height would make it look
    ///   noticeably bigger than the Codex/Cursor gradient fills.
    ///   Scaling to 13 evens out the visual mass.
    @ViewBuilder
    private func brandIcon(for provider: SessionProvider) -> some View {
        switch provider {
        case .claude:
            // size: 16 → 16×16 internal frame, content 16 wide × 12.6 tall
            // (66:52 body fits the frame's width; 1.7pt top/bottom margin
            // from the 16×16 caller's frame). Matches the notch's 16pt
            // crab and the pre-refactor visual exactly.
            ClaudeCrabIcon(size: 16)
                .frame(width: 16, height: 16)
        case .codex:
            CodexLogoIcon(size: 16, color: SessionLoadingStyle.tint(for: .codex))
                .frame(width: 16, height: 16)
        case .cursor:
            CursorLogoIcon(size: 16, color: primaryTextColor.opacity(0.82))
                .frame(width: 16, height: 16)
        case .opencode:
            // See sizing rationale above. 13/16 ≈ 0.81 scale gives a
            // visual mass close to Codex/Cursor while keeping the ring
            // shape recognizable.
            OpenCodeLogoIcon(size: 13, color: primaryTextColor)
                .frame(width: 16, height: 16)
        }
    }

    // MARK: - Claude Directory Picker Options

    private var claudeDirPickerOptions: some View {
        VStack(spacing: 2) {
            SettingsSubPickerRow(
                label: "Auto-detect",
                sublabel: resolvedAutoDetectPath,
                sublabelDesign: .monospaced,
                // `verticalSublabel: true` so the resolved path sits
                // under the title (stacked layout, ~41pt row). The
                // sublabel is always non-nil, so the per-row height in
                // `claudeDirPickerLayout` is the large constant.
                verticalSublabel: true,
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
                // We pass `verticalSublabel: true` for symmetry with
                // the Auto-detect row above, but when the sublabel is
                // nil `SettingsSubPickerRow` auto-falls-back to the
                // small inline layout (~27pt) and the title centers.
                // `claudeDirPickerLayout` picks the matching height per
                // row so the panel stays in lock-step.
                verticalSublabel: true,
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
        // OpenCode uses a plugin mechanism (installed via `opencode plugin --global`),
        // not a hooks one. The other three providers use real hooks. Show the
        // mechanism that matches the implementation.
        let label: String = (provider == .opencode) ? "Plugin" : "Hooks"
        return SettingsSubToggleRow(
            label: label,
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

    /// The "is the toggle on" answer for the UI. We OR the local
    /// `@State` (driven by the install check) with `AppSettings.*HooksEnabled`
    /// (the persisted user intent). The fallback to AppSettings matters because
    /// `refreshStates()` overwrites the local @State from `isInstalled()`,
    /// which can return false even when the install is actually present
    /// (e.g. transient file-check races, JSONC comment edge cases in the
    /// opencode config, plugin path string mismatches). AppSettings is the
    /// durable "user wants this on" signal and should win.
    private func hooksInstalled(_ provider: SessionProvider) -> Bool {
        switch provider {
        case .claude:   return claudeHooksInstalled   || AppSettings.claudeHooksEnabled
        case .codex:    return codexHooksInstalled    || AppSettings.codexHooksEnabled
        case .opencode: return opencodeHooksInstalled || AppSettings.opencodeHooksEnabled
        case .cursor:   return cursorHooksInstalled   || AppSettings.cursorHooksEnabled
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
