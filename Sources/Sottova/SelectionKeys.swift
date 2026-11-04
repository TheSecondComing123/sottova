import AppKit

@MainActor
enum SelectionKeys {
    static func belongToPage(in window: NSWindow?) -> Bool {
        guard let window, window.frameAutosaveName == "main", window.attachedSheet == nil else { return false }
        guard !(window.firstResponder is NSTableView), !(window.firstResponder is NSText) else { return false }
        return true
    }
}
