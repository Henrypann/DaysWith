import SwiftUI
import UIKit

/// Keeps one native input instance when a credential is masked or revealed.
struct SensitiveCredentialField: UIViewRepresentable {
    let title: String
    @Binding var text: String
    let identifier: String
    let secure: Bool
    @Binding var focusedField: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CredentialTextField {
        let field = CredentialTextField()
        field.placeholder = title
        field.accessibilityLabel = title
        field.accessibilityIdentifier = identifier
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = UIColor(Theme.ink)
        field.tintColor = UIColor(Theme.ink)
        field.keyboardType = .asciiCapable
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .done
        field.clearsOnBeginEditing = false
        field.isSecureTextEntry = secure
        field.clearsOnInsertion = false
        // API credentials must not participate in iOS password creation/confirmation heuristics.
        field.textContentType = .oneTimeCode
        field.text = text
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toolbar = UIToolbar()
        let done = UIBarButtonItem(title: "Done", style: .done, target: context.coordinator, action: #selector(Coordinator.done))
        done.accessibilityIdentifier = "dismissCloudKeyboard"
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        toolbar.sizeToFit()
        field.inputAccessoryView = toolbar
        context.coordinator.field = field
        return field
    }

    func updateUIView(_ field: CredentialTextField, context: Context) {
        context.coordinator.parent = self
        // Reassigning text on every SwiftUI update resets UIKit's selection and secure editing.
        if field.text != text { field.text = text }
        if field.isSecureTextEntry != secure {
            let selection = field.selectedTextRange.map {
                (field.offset(from: field.beginningOfDocument, to: $0.start),
                 field.offset(from: field.beginningOfDocument, to: $0.end))
            }
            field.isSecureTextEntry = secure
            field.text = text
            field.clearsOnInsertion = false
            if let selection,
               let start = field.position(from: field.beginningOfDocument, offset: selection.0),
               let end = field.position(from: field.beginningOfDocument, offset: selection.1) {
                field.selectedTextRange = field.textRange(from: start, to: end)
            }
        }
        // Taps establish native focus. SwiftUI only requests its dismissal, never steals it.
        if field.isFirstResponder && focusedField != identifier {
            field.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CredentialTextField, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: max(24, uiView.intrinsicContentSize.height))
    }

    static func dismantleUIView(_ field: CredentialTextField, coordinator: Coordinator) {
        field.delegate = nil
        field.removeTarget(coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.resignFirstResponder()
        coordinator.field = nil
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SensitiveCredentialField
        weak var field: UITextField?

        init(_ parent: SensitiveCredentialField) { self.parent = parent }

        @objc func editingChanged(_ field: UITextField) {
            let value = field.text ?? ""
            if parent.text != value { parent.text = value }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if parent.focusedField != parent.identifier { parent.focusedField = parent.identifier }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.focusedField == parent.identifier { parent.focusedField = nil }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            done()
            return false
        }

        @objc func done() {
            field?.resignFirstResponder()
            if parent.focusedField == parent.identifier { parent.focusedField = nil }
        }
    }
}

final class CredentialTextField: UITextField {
    override func becomeFirstResponder() -> Bool {
        let existingText = text ?? ""
        let restoreSecureBuffer = !isFirstResponder && isSecureTextEntry && !existingText.isEmpty
        let existingSelection = selectedTextRange.map {
            (offset(from: beginningOfDocument, to: $0.start),
             offset(from: beginningOfDocument, to: $0.end))
        }
        let accepted = super.becomeFirstResponder()
        guard accepted else { return false }
        clearsOnInsertion = false
        if restoreSecureBuffer {
            // Rebuild UIKit's secure editing buffer once per new editing session.
            // Assigning the same text alone leaves its first-edit replacement state
            // armed on some iOS versions; insertText establishes an edited buffer.
            // No layout/run-loop boundary occurs while the buffer is empty, and
            // secure masking remains enabled throughout.
            text = nil
            super.insertText(existingText)
            clearsOnInsertion = false
            if let existingSelection,
               let start = position(from: beginningOfDocument, offset: existingSelection.0),
               let end = position(from: beginningOfDocument, offset: existingSelection.1) {
                selectedTextRange = textRange(from: start, to: end)
            }
        }
        return true
    }

    override func insertText(_ text: String) {
        // Keep normal UIKit insertion/selection replacement, including paste.
        clearsOnInsertion = false
        super.insertText(text)
    }

    override func deleteBackward() {
        clearsOnInsertion = false
        super.deleteBackward()
    }

    #if JINBAO_UI_TEST_HOOKS
    // Read directly from UIKit when accessibility is queried, avoiding a stale SwiftUI snapshot.
    // These fixed fixture comparisons never disclose entered text, length, or a digest.
    private var fixture: String? {
        guard ProcessInfo.processInfo.environment["JINBAO_CREDENTIAL_UI_PROBE"] == "1" else { return nil }
        switch accessibilityIdentifier {
        case "secretID": return "SyntheticLifecycleID"
        case "secretKey": return "SyntheticLifecycleKey"
        case "sessionToken": return "SyntheticLifecycleToken"
        default: return nil
        }
    }

    override var accessibilityLabel: String? {
        get {
            guard let fixture else { return super.accessibilityLabel }
            let value = text ?? ""
            if accessibilityIdentifier == "secretKey", value == fixture + "X" { return "fixture-appended" }
            return value.isEmpty ? "fixture-empty" : value == fixture ? "fixture-exact" : "fixture-other"
        }
        set { super.accessibilityLabel = newValue }
    }

    override var accessibilityHint: String? {
        get {
            guard fixture != nil else { return super.accessibilityHint }
            return isFirstResponder ? "firstResponder=true" : "firstResponder=false"
        }
        set { super.accessibilityHint = newValue }
    }
    #endif
}
