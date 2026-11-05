import SwiftUI
import SottovaCore

/// What was just done, at the foot of the page, with Undo. A newer one takes its place.
struct Toast: View {
    /// The main window's also shows while Sottova is in the background; Settings' only while it's in front.
    var main = true
    @Environment(Controller.self) private var controller
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    /// Edit › Undo's name now, which typing in a field can change under the toast.
    @State private var top: String?

    var body: some View {
        ZStack {
            // in one window at a time, so one timer takes it down
            if let notice = controller.notice, activeState == .key || main && activeState == .inactive {
                bar(notice)
                    // restarts on leaving, so it never goes while you're reaching for Undo
                    .task(id: hovering) {
                        guard !hovering else { return }
                        try? await Task.sleep(for: .seconds(notice.undoable ? 6 : 2))
                        guard !Task.isCancelled, controller.notice?.id == notice.id else { return }
                        controller.notice = nil
                    }
                    // under the id, so a notice that replaces one still up gets its own timer
                    .id(notice.id)
                    .transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)),
                                            removal: .opacity.animation(Theme.curve(0.15))))
            }
        }
        .animation(Theme.curve(0.2), value: controller.notice?.id)
        // the old toast's hover would hold the new one up for good
        .onChange(of: controller.notice?.id) { hovering = false }
        // so one doesn't wait to show when the window opens again
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.frameAutosaveName == "main" { controller.notice = nil }
        }
        .onAppear { top = undoManager?.undoActionName }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in top = undoManager?.undoActionName }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in top = undoManager?.undoActionName }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in top = undoManager?.undoActionName }
    }

    private func bar(_ notice: Controller.Notice) -> some View {
        HStack(spacing: 14) {
            Text(notice.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Theme.text)
            if notice.undoable, top == notice.action {
                Button { undoManager?.undo() } label: {
                    HStack(spacing: 5) {
                        Text("Undo").foregroundStyle(Theme.primary)
                        Text("⌘Z").foregroundStyle(Theme.faint)
                    }
                }
                .buttonStyle(PressStyle())
            }
        }
        .role(.body)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Theme.popover, in: .rect(cornerRadius: Radius.medium))
        // the queue panel's edge, so it holds on a page of the same gray
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).stroke(.black.opacity(0.5), lineWidth: 0.5).padding(-0.25))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .frame(maxWidth: 440)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(notice.text).post() }
    }
}
