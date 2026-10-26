import AppKit
import SwiftUI

@MainActor
final class WindowActionNotificationController {
    private let store: PersistenceStore
    init(store: PersistenceStore) { self.store = store }
    private var panel: NSPanel?
    private var hostingView: NSHostingView<WindowActionNotificationView>?
    private var hideWorkItem: DispatchWorkItem?

    func show(_ content: WindowActionNotification, onAction: (() -> Void)?) {
        let settings = store.loadConfiguration().behavior
        guard settings.shows(content) else { return }
        hideWorkItem?.cancel()
        let panel = panel ?? makePanel(content: content, onAction: onAction)
        hostingView?.rootView = WindowActionNotificationView(content: content, onAction: onAction)
        let screenFrame = FloatingHUDScreenResolver.visibleFrame()
        let size = WindowActionNotificationMetrics.panelSize
        panel.setFrame(
            FloatingHUDPlacementPolicy().frame(
                visibleFrame: screenFrame,
                panelSize: size,
                effectOutset: WindowActionNotificationMetrics.effectOutset,
                surfaceInset: WindowActionNotificationMetrics.surfaceInset,
                corner: settings.feedbackCorner
            ),
            display: true
        )
        panel.orderFrontRegardless()
        self.panel = panel

        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        let duration: TimeInterval
        if content.actionTitle != nil || content.tone == .warning {
            duration = 4
        } else {
            duration = 1.5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    private func makePanel(
        content: WindowActionNotification,
        onAction: (() -> Void)?
    ) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.hasShadow = false
        let hostingView = NSHostingView(
            rootView: WindowActionNotificationView(content: content, onAction: onAction)
        )
        panel.contentView = hostingView
        self.hostingView = hostingView
        return panel
    }
}

private enum WindowActionNotificationMetrics {
    static let surfaceSize = CGSize(width: 420, height: 58)
    static let surfaceInset: CGFloat = 20

    // SwiftUI effects are clipped to the hosting window's rectangular bounds.
    // Keep the rounded surface inset so its shadow can fade naturally instead
    // of being cut into a sharp-edged rectangle at the panel boundary.
    static let effectOutset: CGFloat = 24
    static let panelSize = CGSize(
        width: surfaceSize.width + effectOutset * 2,
        height: surfaceSize.height + effectOutset * 2
    )
}

@MainActor
final class InteractionDiagnosticHUDController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<InteractionDiagnosticHUDView>?
    private var hideWorkItem: DispatchWorkItem?

    func show(_ event: WindowInteractionEvent) {
        hideWorkItem?.cancel()
        let panel = panel ?? makePanel(event: event)
        hostingView?.rootView = InteractionDiagnosticHUDView(event: event)
        panel.setFrame(
            FloatingHUDPlacementPolicy().frame(
                visibleFrame: FloatingHUDScreenResolver.visibleFrame(),
                panelSize: InteractionDiagnosticHUDMetrics.panelSize,
                effectOutset: InteractionDiagnosticHUDMetrics.effectOutset,
                surfaceInset: InteractionDiagnosticHUDMetrics.surfaceInset,
                corner: .bottomLeading
            ),
            display: true
        )
        panel.orderFrontRegardless()
        self.panel = panel

        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    private func makePanel(event: WindowInteractionEvent) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let hostingView = NSHostingView(rootView: InteractionDiagnosticHUDView(event: event))
        panel.contentView = hostingView
        self.hostingView = hostingView
        return panel
    }
}

private enum InteractionDiagnosticHUDMetrics {
    static let surfaceSize = CGSize(width: 230, height: 36)
    static let effectOutset: CGFloat = 16
    static let surfaceInset: CGFloat = 20
    static let panelSize = CGSize(
        width: surfaceSize.width + effectOutset * 2,
        height: surfaceSize.height + effectOutset * 2
    )
}

private struct InteractionDiagnosticHUDView: View {
    var event: WindowInteractionEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(event.kind.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(event.phase.rawValue.capitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(
            width: InteractionDiagnosticHUDMetrics.surfaceSize.width,
            height: InteractionDiagnosticHUDMetrics.surfaceSize.height
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
        .padding(InteractionDiagnosticHUDMetrics.effectOutset)
    }
}

@MainActor
private enum FloatingHUDScreenResolver {
    static func visibleFrame() -> CGRect {
        let fallback = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return PointerScreenSelectionPolicy().visibleFrame(
            containing: NSEvent.mouseLocation,
            candidates: NSScreen.screens.map {
                ScreenFrameCandidate(frame: $0.frame, visibleFrame: $0.visibleFrame)
            },
            fallback: fallback
        )
    }
}

private struct WindowActionNotificationView: View {
    var content: WindowActionNotification
    var onAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(toneColor.opacity(0.16))
                Image(systemName: content.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(toneColor)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if !content.detail.isEmpty {
                    Text(content.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let actionTitle = content.actionTitle {
                Button(actionTitle) {
                    onAction?()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: WindowActionNotificationMetrics.surfaceSize.width, height: WindowActionNotificationMetrics.surfaceSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
        .padding(WindowActionNotificationMetrics.effectOutset)
    }

    private var toneColor: Color {
        switch content.tone {
        case .accent: .accentColor
        case .success: .green
        case .warning: .orange
        }
    }
}
