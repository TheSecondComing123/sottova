import AppKit

@MainActor
private final class CheckWindow: NSWindow {
    var name = "main"
    var focus: NSResponder?
    var presented: NSWindow?
    override var frameAutosaveName: NSWindow.FrameAutosaveName { name }
    override var firstResponder: NSResponder? { focus }
    override var attachedSheet: NSWindow? { presented }
}

@main
struct SelectionKeysCheck {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = CheckWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        var failures = 0
        func check(_ expected: Bool, _ message: String) {
            if SelectionKeys.belongToPage(in: window) != expected {
                print("FAIL: \(message)")
                failures += 1
            }
        }
        check(true, "the page keeps its selection keys")
        window.focus = NSTableView()
        check(false, "a queue table must not remove the hidden page selection")
        window.focus = NSTextView()
        check(false, "a text editor keeps its deletion keys")
        window.focus = nil
        window.presented = CheckWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        check(false, "a sheet must not remove the hidden page selection")
        window.presented = nil
        window.name = "settings"
        check(false, "Settings must not remove the hidden page selection")
        guard failures == 0 else { exit(1) }
        print("PASS: 5 selection-key focus checks; no windows shown or input sent")
    }
}
