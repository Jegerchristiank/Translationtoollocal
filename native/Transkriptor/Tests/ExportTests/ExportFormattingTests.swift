import Domain
@testable import Export
import Foundation
import Testing

@Test
func lineNumbersAreSequential() throws {
    let result = JobResult(
        jobId: "job-1",
        sourcePath: "/tmp/test.wav",
        durationSec: 1800,
        transcript: [
            TranscriptSegment(startSec: 0, endSec: 5, speaker: .interviewer, text: "Hej og velkommen til interviewet.", confidence: nil),
            TranscriptSegment(startSec: 6, endSec: 11, speaker: .participant, text: "Tak skal du have, jeg er klar.", confidence: nil)
        ]
    )

    let formatting = TranscriptFormatting()
    let entries = formatting.lineEntries(from: result.transcript)

    #expect(!entries.isEmpty)
    #expect(entries.enumerated().allSatisfy { idx, entry in
        entry.number == idx + 1
    })
}

@Test
func insertsBlankLineWhenSpeakerChanges() throws {
    let transcript = [
        TranscriptSegment(startSec: 0, endSec: 1, speaker: .interviewer, text: "Første", confidence: nil),
        TranscriptSegment(startSec: 2, endSec: 3, speaker: .participant, text: "Svar", confidence: nil),
        TranscriptSegment(startSec: 4, endSec: 5, speaker: .participant, text: "Mere svar", confidence: nil)
    ]

    let entries = TranscriptFormatting().lineEntries(from: transcript)
    #expect(entries.count == 4)
    #expect(entries[0].number == 1 && entries[0].speaker == .interviewer && entries[0].text == "Første")
    #expect(entries[1].number == 2 && entries[1].speaker == nil && entries[1].text.isEmpty)
    #expect(entries[2].number == 3 && entries[2].speaker == .participant && entries[2].text == "Svar")
    #expect(entries[3].number == 4 && entries[3].speaker == nil && entries[3].text == "Mere svar")
}

@Test
func keepsSingleSpeakerPrefixForMultiLineSegment() throws {
    let transcript = [
        TranscriptSegment(startSec: 0, endSec: 4, speaker: .participant, text: "Linje 1\nLinje 2\nLinje 3", confidence: nil)
    ]

    let entries = TranscriptFormatting().lineEntries(from: transcript)
    #expect(entries.count == 3)
    #expect(entries[0].number == 1 && entries[0].speaker == .participant && entries[0].text == "Linje 1")
    #expect(entries[1].number == 2 && entries[1].speaker == nil && entries[1].text == "Linje 2")
    #expect(entries[2].number == 3 && entries[2].speaker == nil && entries[2].text == "Linje 3")
}

@Test
func exportsTxtAndDocxFiles() throws {
    let result = JobResult(
        jobId: "job-2",
        sourcePath: "/tmp/demo.wav",
        durationSec: 1200,
        transcript: [
            TranscriptSegment(startSec: 0, endSec: 3, speaker: .interviewer, text: "Velkommen til interviewet.", confidence: nil),
            TranscriptSegment(startSec: 4, endSec: 8, speaker: .participant, text: "Tak fordi jeg måtte komme.", confidence: nil)
        ]
    )

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("transkriptor-export-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let txtURL = tempDir.appendingPathComponent("out.txt")
    let docxURL = tempDir.appendingPathComponent("out.docx")

    _ = try TxtExporter().export(result: result, outputURL: txtURL)
    _ = try DocxExporter().export(result: result, outputURL: docxURL)

    #expect(FileManager.default.fileExists(atPath: txtURL.path))
    #expect(FileManager.default.fileExists(atPath: docxURL.path))

    let txt = try String(contentsOf: txtURL, encoding: .utf8)
    #expect(txt.contains("Navn på fil:"))
    #expect(txt.contains("1\tI: Velkommen til interviewet."))
    #expect(txt.contains("2\t"))
    #expect(txt.contains("3\tD: Tak fordi jeg måtte komme."))
}

@Test
func exportsUseOverriddenSourceNameInHeader() throws {
    let result = JobResult(
        jobId: "job-override",
        sourcePath: "/tmp/original-navn.wav",
        durationSec: 120,
        transcript: [
            TranscriptSegment(startSec: 0, endSec: 2, speaker: .interviewer, text: "Hej", confidence: nil)
        ]
    )

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("transkriptor-export-override-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let overrideTitle = "Interview om Nintendo strategi"
    let txtURL = tempDir.appendingPathComponent("override.txt")
    let docxURL = tempDir.appendingPathComponent("override.docx")

    _ = try TxtExporter().export(result: result, outputURL: txtURL, sourceNameOverride: overrideTitle)
    _ = try DocxExporter().export(result: result, outputURL: docxURL, sourceNameOverride: overrideTitle)

    let txt = try String(contentsOf: txtURL, encoding: .utf8)
    #expect(txt.contains("Navn på fil: \"\(overrideTitle)\""))

    let documentXML = try unzipEntry(from: docxURL, entryPath: "word/document.xml")
    #expect(documentXML.contains("Navn på fil: &quot;\(xmlEscapeForTest(overrideTitle))&quot;"))
}

@Test
func docxLayoutMatchesReferenceMarginsFontAndRowHeight() throws {
    let result = JobResult(
        jobId: "job-3",
        sourcePath: "/tmp/layout.wav",
        durationSec: 900,
        transcript: [
            TranscriptSegment(
                startSec: 0,
                endSec: 6,
                speaker: .interviewer,
                text: "Dette er en linje der skal bruge bredden i dokumentet korrekt.",
                confidence: nil
            )
        ]
    )

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("transkriptor-export-layout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let docxURL = tempDir.appendingPathComponent("layout.docx")
    _ = try DocxExporter().export(result: result, outputURL: docxURL)

    let documentXML = try unzipEntry(from: docxURL, entryPath: "word/document.xml")
    let stylesXML = try unzipEntry(from: docxURL, entryPath: "word/styles.xml")

    #expect(documentXML.contains("w:left=\"1134\""))
    #expect(documentXML.contains("w:right=\"1134\""))
    #expect(documentXML.contains("<w:gridCol w:w=\"8708\"/>"))
    #expect(documentXML.contains("<w:trHeight w:val=\"283\" w:hRule=\"atLeast\"/>"))
    #expect(!documentXML.contains("w:hRule=\"exact\""))

    #expect(stylesXML.contains("w:asciiTheme=\"minorHAnsi\""))
    #expect(stylesXML.contains("w:sz w:val=\"24\""))
}

@Test
func docxKeepsLongLineContentVisibleWithFlexibleRowHeight() throws {
    let longLine = "Hej, jeg er interviewer og jeg vil bare lige sige at alt det her er fortroligt og vi siger ikke dit navn, så kan du fortælle lidt om dig selv?"
    let result = JobResult(
        jobId: "job-4",
        sourcePath: "/tmp/longline.wav",
        durationSec: 60,
        transcript: [
            TranscriptSegment(startSec: 0, endSec: 8, speaker: .interviewer, text: longLine, confidence: nil)
        ]
    )

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("transkriptor-export-longline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let docxURL = tempDir.appendingPathComponent("longline.docx")
    _ = try DocxExporter().export(result: result, outputURL: docxURL)

    let documentXML = try unzipEntry(from: docxURL, entryPath: "word/document.xml")
    #expect(documentXML.contains("w:hRule=\"atLeast\""))
    #expect(documentXML.contains(xmlEscapeForTest("Hej, jeg er interviewer")))
    #expect(documentXML.contains(xmlEscapeForTest("dig selv?")))

    let rowCount = documentXML.components(separatedBy: "<w:tr>").count - 1
    #expect(rowCount >= 2)
    #expect(documentXML.contains("<w:r><w:t>1</w:t></w:r>"))
    #expect(documentXML.contains("<w:r><w:t>2</w:t></w:r>"))
}

private func xmlEscapeForTest(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

private func unzipEntry(from archiveURL: URL, entryPath: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", archiveURL.path, entryPath]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8) ?? "Ukendt unzip-fejl"
        throw NSError(domain: "ExportTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText])
    }

    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    guard let xml = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "ExportTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Kunne ikke læse unzip-output som UTF-8"])
    }
    return xml
}
