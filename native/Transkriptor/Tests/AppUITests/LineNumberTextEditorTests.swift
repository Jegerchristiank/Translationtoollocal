import SwiftUI
import Testing
@testable import AppUI

@Test
@MainActor
func lineEditorLineCountIsAtLeastOne() {
    #expect(LineNumberTextEditorStyle.lineCount(for: "") == 1)
    #expect(LineNumberTextEditorStyle.lineCount(for: "I: Hej") == 1)
    #expect(LineNumberTextEditorStyle.lineCount(for: "I: Hej\nD: Svar") == 2)
}

@Test
@MainActor
func lineEditorLineCountTracksBlankLines() {
    #expect(LineNumberTextEditorStyle.lineCount(for: "I: Hej\n\nD: Svar") == 3)
    #expect(LineNumberTextEditorStyle.lineCount(for: "I: Hej\n") == 2)
}

@Test
@MainActor
func lineEditorProvidesDifferentForegroundPerScheme() {
    let dark = String(describing: LineNumberTextEditorStyle.editorForeground(for: .dark))
    let light = String(describing: LineNumberTextEditorStyle.editorForeground(for: .light))
    #expect(dark != light)
}

@Test
@MainActor
func lineEditorProvidesDifferentBackgroundPerScheme() {
    let dark = String(describing: LineNumberTextEditorStyle.editorBackground(for: .dark))
    let light = String(describing: LineNumberTextEditorStyle.editorBackground(for: .light))
    #expect(dark != light)
}

@Test
@MainActor
func lineEditorViewCanRenderEditableAndReadOnly() {
    let editable = LineNumberTextEditor(text: .constant("I: Hej"), isEditable: true)
    _ = editable.body

    let readOnly = LineNumberTextEditor(text: .constant("D: Svar"), isEditable: false)
    _ = readOnly.body
}
