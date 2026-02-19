import Domain
import Foundation
import CoreText

public enum ExportError: Error, LocalizedError {
    case zipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .zipFailed(let message):
            return "Kunne ikke pakke DOCX: \(message)"
        }
    }
}

public struct DocxExporter {
    private let formatting = TranscriptFormatting()

    private let numberColTwips = 601
    private let gapColTwips = 329
    private let textColTwips = 8708
    private let minimumRowHeightTwips = 283 // 0.5 cm minimum; row may grow for wrapped text
    private let docxFontSize: CGFloat = 12
    private let minWrapWidthPoints: CGFloat = 120

    public init() {}

    @discardableResult
    public func export(
        result: JobResult,
        outputURL: URL,
        createdAt: Date = Date(),
        sourceNameOverride: String? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("transkriptor-docx-\(UUID().uuidString)", isDirectory: true)

        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        try fm.createDirectory(at: tempRoot.appendingPathComponent("_rels", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: tempRoot.appendingPathComponent("word", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: tempRoot.appendingPathComponent("word/_rels", isDirectory: true), withIntermediateDirectories: true)

        let contentTypes = contentTypesXML()
        let rels = rootRelsXML()
        let docRels = documentRelsXML()
        let styles = stylesXML()
        let document = documentXML(
            result: result,
            createdAt: createdAt,
            sourceNameOverride: sourceNameOverride
        )

        try contentTypes.write(to: tempRoot.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rels.write(to: tempRoot.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try docRels.write(to: tempRoot.appendingPathComponent("word/_rels/document.xml.rels"), atomically: true, encoding: .utf8)
        try styles.write(to: tempRoot.appendingPathComponent("word/styles.xml"), atomically: true, encoding: .utf8)
        try document.write(to: tempRoot.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)

        try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }

        try zipDirectory(source: tempRoot, output: outputURL)
        return outputURL
    }

    private func contentTypesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """
    }

    private func rootRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
    }

    private func documentRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
    }

    private func stylesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                <w:docDefaults>
                    <w:rPrDefault>
                        <w:rPr>
                            <w:rFonts w:asciiTheme="minorHAnsi" w:eastAsiaTheme="minorHAnsi" w:hAnsiTheme="minorHAnsi" w:cstheme="minorBidi"/>
                            <w:sz w:val="24"/>
                            <w:szCs w:val="24"/>
                        </w:rPr>
                    </w:rPrDefault>
                    <w:pPrDefault/>
                </w:docDefaults>
                <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
                    <w:name w:val="Normal"/>
                    <w:qFormat/>
                </w:style>
        </w:styles>
        """
    }

    private func documentXML(
        result: JobResult,
        createdAt: Date,
        sourceNameOverride: String?
    ) -> String {
        let headerLines = formatting.headerLines(
            for: result,
            createdAt: createdAt,
            sourceNameOverride: sourceNameOverride
        )
        let lineEntries = docxLineEntries(from: formatting.lineEntries(from: result.transcript))

        let headerXML = headerLines.enumerated().map { index, line in
            paragraphXML(
                text: line,
                bold: line == "Deltagere:",
                addSpacingAfter: index < headerLines.count - 1
            )
        }.joined()

        let tableXML: String
        if lineEntries.isEmpty {
            tableXML = ""
        } else {
            let rows = lineEntries.map(rowXML).joined()
            tableXML = """
            <w:tbl>
                <w:tblPr>
                    <w:tblW w:w="0" w:type="auto"/>
                    <w:tblLayout w:type="fixed"/>
                    <w:tblCellMar>
                        <w:top w:w="0" w:type="dxa"/>
                        <w:left w:w="40" w:type="dxa"/>
                        <w:bottom w:w="0" w:type="dxa"/>
                        <w:right w:w="40" w:type="dxa"/>
                    </w:tblCellMar>
                    <w:tblLook w:val="0000"/>
                </w:tblPr>
                <w:tblGrid>
                    <w:gridCol w:w="\(numberColTwips)"/>
                    <w:gridCol w:w="\(gapColTwips)"/>
                    <w:gridCol w:w="\(textColTwips)"/>
                </w:tblGrid>
                \(rows)
            </w:tbl>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document
            xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas"
            xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
            xmlns:o="urn:schemas-microsoft-com:office:office"
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
            xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"
            xmlns:v="urn:schemas-microsoft-com:vml"
            xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing"
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
            xmlns:w10="urn:schemas-microsoft-com:office:word"
            xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"
            xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
            xmlns:wpi="http://schemas.microsoft.com/office/word/2010/wordprocessingInk"
            xmlns:wne="http://schemas.microsoft.com/office/word/2006/wordml"
            xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
            mc:Ignorable="w14 wp14">
            <w:body>
                \(headerXML)
                \(tableXML)
                <w:sectPr>
                    <w:pgSz w:w="11906" w:h="16838"/>
                    <w:pgMar w:top="1701" w:right="1134" w:bottom="1701" w:left="1134" w:header="708" w:footer="708" w:gutter="0"/>
                </w:sectPr>
            </w:body>
        </w:document>
        """
    }

    private func paragraphXML(text: String, bold: Bool, addSpacingAfter: Bool) -> String {
        let escaped = xmlEscape(text)
        let spacing = addSpacingAfter ? "<w:spacing w:before=\"0\" w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>" : ""
        if escaped.isEmpty {
            return "<w:p><w:pPr>\(spacing)</w:pPr></w:p>"
        }

        let runPr = bold ? "<w:rPr><w:b/></w:rPr>" : ""
        return """
        <w:p>
            <w:pPr>\(spacing)</w:pPr>
            <w:r>\(runPr)<w:t xml:space="preserve">\(escaped)</w:t></w:r>
        </w:p>
        """
    }

    private func rowXML(entry: LineEntry) -> String {
        let numberText = String(entry.number)

        let textCellRuns: String
        if let speaker = entry.speaker {
            let escapedText = xmlEscape(entry.text)
            if escapedText.isEmpty {
                textCellRuns = "<w:r><w:rPr><w:b/></w:rPr><w:t>\(speaker.rawValue):</w:t></w:r>"
            } else {
                textCellRuns = """
                <w:r><w:rPr><w:b/></w:rPr><w:t>\(speaker.rawValue):</w:t></w:r>
                <w:r><w:t xml:space="preserve"> \(escapedText)</w:t></w:r>
                """
            }
        } else if entry.text.isEmpty {
            textCellRuns = ""
        } else {
            textCellRuns = "<w:r><w:t xml:space=\"preserve\">\(xmlEscape(entry.text))</w:t></w:r>"
        }

        return """
        <w:tr>
            <w:trPr>
                <w:trHeight w:val="\(minimumRowHeightTwips)" w:hRule="atLeast"/>
            </w:trPr>
            <w:tc>
                <w:tcPr><w:tcW w:w="\(numberColTwips)" w:type="dxa"/></w:tcPr>
                <w:p>
                    <w:pPr>
                        <w:jc w:val="right"/>
                        <w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/>
                    </w:pPr>
                    <w:r><w:t>\(numberText)</w:t></w:r>
                </w:p>
            </w:tc>
            <w:tc>
                <w:tcPr><w:tcW w:w="\(gapColTwips)" w:type="dxa"/></w:tcPr>
                <w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:p>
            </w:tc>
            <w:tc>
                <w:tcPr><w:tcW w:w="\(textColTwips)" w:type="dxa"/></w:tcPr>
                <w:p>
                    <w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>
                    \(textCellRuns)
                </w:p>
            </w:tc>
        </w:tr>
        """
    }

    private func docxLineEntries(from logicalEntries: [LineEntry]) -> [LineEntry] {
        var expanded: [LineEntry] = []
        var lineNumber = 1

        for entry in logicalEntries {
            let wrapped = wrapEntryForDocx(entry)
            if wrapped.isEmpty {
                expanded.append(LineEntry(number: lineNumber, speaker: entry.speaker, text: entry.text))
                lineNumber += 1
                continue
            }

            for wrappedEntry in wrapped {
                expanded.append(
                    LineEntry(
                        number: lineNumber,
                        speaker: wrappedEntry.speaker,
                        text: wrappedEntry.text
                    )
                )
                lineNumber += 1
            }
        }

        return expanded
    }

    private func wrapEntryForDocx(_ entry: LineEntry) -> [LineEntry] {
        if entry.text.isEmpty {
            return [entry]
        }

        if let speaker = entry.speaker {
            let prefix = "\(speaker.rawValue): "
            let wrappedDisplay = wrapDisplayLineForDocx(prefix + entry.text)
            guard !wrappedDisplay.isEmpty else {
                return [entry]
            }

            return wrappedDisplay.enumerated().map { index, displayLine in
                if index == 0 {
                    let firstLineText: String
                    if displayLine.hasPrefix(prefix) {
                        firstLineText = String(displayLine.dropFirst(prefix.count))
                    } else {
                        firstLineText = displayLine
                    }
                    return LineEntry(number: 0, speaker: speaker, text: firstLineText)
                } else {
                    return LineEntry(number: 0, speaker: nil, text: displayLine)
                }
            }
        }

        return wrapDisplayLineForDocx(entry.text).map { wrappedLine in
            LineEntry(number: 0, speaker: nil, text: wrappedLine)
        }
    }

    private func wrapDisplayLineForDocx(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\t", with: "    ")
        if normalized.isEmpty {
            return [""]
        }

        let font = CTFontCreateWithName("Calibri" as CFString, docxFontSize, nil)
        let attributes = [NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font]
        let attributed = NSAttributedString(string: normalized, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let source = normalized as NSString

        let widthPoints = max(minWrapWidthPoints, (CGFloat(textColTwips) / 20.0) - 8)
        var lines: [String] = []
        var index = 0

        while index < source.length {
            var count = CTTypesetterSuggestLineBreak(typesetter, index, Double(widthPoints))
            if count <= 0 {
                count = 1
            }

            let range = NSRange(location: index, length: min(count, source.length - index))
            var line = source.substring(with: range)
            line = line.trimmingCharacters(in: .newlines)
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                lines.append(line)
            }
            index = NSMaxRange(range)
        }

        return lines.isEmpty ? [""] : lines
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func zipDirectory(source: URL, output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", output.path, "."]
        process.currentDirectoryURL = source

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Ukendt zip-fejl"
            throw ExportError.zipFailed(message)
        }
    }
}
