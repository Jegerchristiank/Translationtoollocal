import SwiftUI

@MainActor
enum LineNumberTextEditorStyle {
    static let editorFont = Font.system(size: 13, weight: .regular, design: .monospaced)

    static func lineCount(for text: String) -> Int {
        max(1, text.components(separatedBy: .newlines).count)
    }

    static func editorBackground(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color(red: 0.09, green: 0.10, blue: 0.12)
        case .light:
            return Color(red: 0.98, green: 0.98, blue: 0.99)
        @unknown default:
            return Color(red: 0.98, green: 0.98, blue: 0.99)
        }
    }

    static func editorForeground(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color(red: 0.94, green: 0.95, blue: 0.97)
        case .light:
            return Color(red: 0.10, green: 0.11, blue: 0.13)
        @unknown default:
            return Color(red: 0.10, green: 0.11, blue: 0.13)
        }
    }
}

struct LineNumberTextEditor: View {
    @Binding var text: String
    var isEditable: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TextEditor(text: $text)
            .font(LineNumberTextEditorStyle.editorFont)
            .foregroundStyle(LineNumberTextEditorStyle.editorForeground(for: colorScheme))
            .scrollContentBackground(.hidden)
            .background(LineNumberTextEditorStyle.editorBackground(for: colorScheme))
            .disabled(!isEditable)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
