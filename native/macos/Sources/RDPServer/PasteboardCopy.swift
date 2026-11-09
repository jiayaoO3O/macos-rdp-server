import AppKit

/// Copies user-facing error text to the general pasteboard. NSPopover text is
/// not selectable by default, so every error display also offers an explicit
/// copy action; this keeps crash/error reports easy to forward.
func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
