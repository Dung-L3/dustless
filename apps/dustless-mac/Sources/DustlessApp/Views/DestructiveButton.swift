import AppKit
import SwiftUI

enum DestructiveStyle {
    static let red = Color(nsColor: .systemRed)
}

struct DestructiveButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    var help: String?
    var hint: String?
    var prominent = true

    init(
        help: String? = nil,
        hint: String? = nil,
        prominent: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.action = action
        self.label = label
        self.help = help
        self.hint = hint
        self.prominent = prominent
    }

    var body: some View {
        Group {
            if prominent {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .tint(DestructiveStyle.red)
        .modifier(OptionalHelp(text: help))
        .modifier(OptionalHint(text: hint))
    }

    private var button: some View {
        Button(role: .destructive, action: action, label: label)
    }
}

private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

private struct OptionalHint: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.accessibilityHint(text)
        } else {
            content
        }
    }
}
