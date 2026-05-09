import SwiftUI
import AppKit

/// A SwiftUI wrapper around NSTextField. Used in places where SwiftUI's
/// TextField has flaky first-responder behaviour on macOS (the Library
/// search bar in particular — clicking it set focus visually but the
/// underlying field never became first responder for keystrokes). NSTextField
/// has none of those issues; this wrapper just bridges the binding.
struct AppKitTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onChange: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Only mutate if the bound value diverged externally (e.g. clear
        // button) — pushing on every render fights user input.
        if field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppKitTextField
        init(_ parent: AppKitTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let v = field.stringValue
            parent.text = v
            parent.onChange?(v)
        }
    }
}
