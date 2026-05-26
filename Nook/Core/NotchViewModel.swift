//
//  NotchViewModel.swift
//  Nook
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .chat(let session): return "chat-\(session.sessionId)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false
    @Published var instancesPageHasSessions: Bool = false
    @Published var instancesPageSessionCount: Int = 0
    @Published var instancesPageShowsMusic: Bool = false
    @Published var instancesPageRowHeight: CGFloat = 0
    @Published var instancesPageMusicCardHeight: CGFloat = 0
    @Published var animatedTopCornerRadius: CGFloat = 6
    @Published var animatedBottomCornerRadius: CGFloat = 12
    /// Extra width beyond device notch for closed state activity indicators (music, processing, etc.)
    @Published var closedNotchExpansionWidth: CGFloat = 0

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared
    private let claudeDirSelector = ClaudeDirSelector.shared

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        switch contentType {
        case .chat:
            // Large size for chat view
            return CGSize(
                width: min(screenRect.width * 0.5, 600),
                height: 580
            )
        case .menu:
            // Base height covers all static rows (Back, 3 picker rows, 3 toggles,
            // Accessibility, Update, GitHub, Quit + 4 dividers + padding).
            // Picker expansion deltas added on top when expanded.
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 540
                    + screenSelector.expandedPickerHeight
                    + soundSelector.expandedPickerHeight
                    + claudeDirSelector.expandedPickerHeight
            )
        case .instances:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: instancesPageOpenedHeight
            )
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared
    private var hoverTimer: DispatchWorkItem?
    /// Set when the notch is closing due to a click on the notch area,
    /// so the redundant SwiftUI onTapGesture can skip re-opening it.
    var closedByTapAt: Date?

    private enum InstancesPageLayout {
        static let contentSpacing: CGFloat = 8
        static let targetVisibleRows: CGFloat = 3.2
        static let listRowSpacing: CGFloat = 2
        static let listVerticalPadding: CGFloat = 4
        static let emptyStateHeight: CGFloat = 84
        static let emptyHeight: CGFloat = 112
        static let emptyHeightWithMusic: CGFloat = 228
        static let fallbackRowHeight: CGFloat = 58
        static let fallbackMusicBlockHeight: CGFloat = emptyHeightWithMusic - emptyHeight
    }

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        setupEventHandlers()
        observeSelectors()
    }

    private func observeSelectors() {
        screenSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        soundSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        claudeDirSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private var instancesPageOpenedHeight: CGFloat {
        let chromeHeight = InstancesPageLayout.emptyHeight - InstancesPageLayout.emptyStateHeight
        let musicBlockHeight: CGFloat = instancesPageShowsMusic
            ? resolvedMusicCardHeight + InstancesPageLayout.contentSpacing
            : 0

        let contentHeight: CGFloat
        if instancesPageSessionCount > 0 {
            contentHeight = listHeight(
                rowHeight: resolvedRowHeight,
                visibleRows: min(CGFloat(instancesPageSessionCount), InstancesPageLayout.targetVisibleRows)
            )
        } else {
            contentHeight = InstancesPageLayout.emptyStateHeight
        }

        return chromeHeight + musicBlockHeight + contentHeight
    }

    private var resolvedRowHeight: CGFloat {
        max(instancesPageRowHeight, InstancesPageLayout.fallbackRowHeight)
    }

    private var resolvedMusicCardHeight: CGFloat {
        max(instancesPageMusicCardHeight, InstancesPageLayout.fallbackMusicBlockHeight - InstancesPageLayout.contentSpacing)
    }

    private func listHeight(rowHeight: CGFloat, visibleRows: CGFloat) -> CGFloat {
        let clampedVisibleRows = max(0, visibleRows)
        let visibleRowsHeight = rowHeight * clampedVisibleRows
        let visibleSpacingCount = max(0, ceil(clampedVisibleRows) - 1)
        let spacingHeight = InstancesPageLayout.listRowSpacing * visibleSpacingCount
        let verticalPaddingHeight = InstancesPageLayout.listVerticalPadding * 2
        return visibleRowsHeight + spacingHeight + verticalPaddingHeight
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    private func handleMouseMove(_ location: CGPoint) {
        let inNotch = geometry.isPointInNotch(location, expansionWidth: closedNotchExpansionWidth)
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering

        // Cancel any pending hover timer
        hoverTimer?.cancel()
        hoverTimer = nil

        // Start hover timer to auto-expand after 0.8 seconds
        if isHovering && (status == .closed || status == .popping) {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.isHovering else { return }
                self.notchOpen(reason: .hover)
            }
            hoverTimer = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
        }
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                notchClose()
                // Re-post the click so it reaches the window/app behind us
                repostClickAt(location)
            } else if geometry.notchScreenRect.contains(location) {
                // Clicking notch while opened - only close if NOT in chat mode
                if !isInChatMode {
                    notchClose()
                    closedByTapAt = Date()
                }
            }
        case .closed, .popping:
            if geometry.isPointInNotch(location, expansionWidth: closedNotchExpansionWidth) {
                notchOpen(reason: .click)
            }
        }
    }

    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // Small delay to let the window's ignoresMouseEvents update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Convert to CGEvent coordinate system (screen coordinates with Y from top-left)
            guard let screen = NSScreen.main else { return }
            let screenHeight = screen.frame.height
            let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

            // Create and post mouse down event
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }

            // Create and post mouse up event
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)) {
            status = .opened
            animatedTopCornerRadius = 12
            animatedBottomCornerRadius = 24
        }

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current.sessionId == chatSession.sessionId {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func notchClose() {
        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)) {
            status = .closed
            animatedTopCornerRadius = 6
            animatedBottomCornerRadius = 12
        }
        contentType = .instances
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        contentType = contentType == .menu ? .instances : .menu
    }

    func showChat(for session: SessionState) {
        // Avoid unnecessary updates if already showing this chat
        if case .chat(let current) = contentType, current.sessionId == session.sessionId {
            return
        }
        contentType = .chat(session)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        contentType = .instances
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
}
