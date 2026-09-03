import SwiftUI

public enum MNMarkdownStyle: Hashable, Sendable {
    case ui
    case article

    public var bodyFont: Font { self == .article ? MNFont.body2 : MNFont.body3 }
    public var bodySize: CGFloat { self == .article ? 16 : 14 }
    public var bodyLineSpacing: CGFloat { self == .article ? Self.articleLineSpacing : Self.uiLineSpacing }
    public var blockSpacing: CGFloat { self == .article ? MNSpacing.s16 : MNSpacing.s8 }
    public var listItemSpacing: CGFloat { self == .article ? 6 : MNSpacing.s4 }
    public var tableRowSpacing: CGFloat { self == .article ? MNSpacing.s8 : MNSpacing.s4 }
    public var tableHeaderFont: Font { self == .article ? MNFont.subtitle1 : MNFont.subtitle2 }
    public var codeFontSize: CGFloat { self == .article ? 13 : 12 }
    public var codeLineSpacing: CGFloat { self == .article ? 3 : 0 }
    public var inlineCodeFont: Font { self == .article ? Self.articleCodeFont : Self.uiCodeFont }

    private static let uiLineSpacing = MNFont.lineSpacing(size: 14, lineHeight: 1.45)
    private static let articleLineSpacing = MNFont.lineSpacing(size: 16, lineHeight: 1.6)
    private static let uiCodeFont = Font.system(size: 14 * 0.875, design: .monospaced)
    private static let articleCodeFont = Font.system(size: 16 * 0.875, design: .monospaced)

    public func headingFont(_ level: Int) -> Font {
        switch (self, level) {
        case (.article, 1): return MNFont.title1
        case (.article, 2): return MNFont.title2
        case (.article, 3): return MNFont.subtitle1
        case (.article, _): return MNFont.subtitle2
        case (.ui, 1): return MNFont.title2
        case (.ui, 2): return MNFont.subtitle1
        case (.ui, _): return MNFont.subtitle2
        }
    }

    public func headingTopPadding(_ level: Int) -> CGFloat {
        switch (self, level) {
        case (.article, 1): return MNSpacing.s24
        case (.article, 2): return MNSpacing.s20
        case (.article, _): return MNSpacing.s12
        case (.ui, _): return level <= 2 ? MNSpacing.s8 : MNSpacing.s4
        }
    }
}

private enum RenderedBlock: Sendable {
    struct Item: Sendable {
        let indent: Int
        let marker: String
        let text: AttributedString
    }

    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case code(String)
    case list([Item])
    case quote(AttributedString)
    case table([[AttributedString]])
    case rule

    init(_ block: MarkdownBlock, style: MNMarkdownStyle) {
        switch block {
        case let .heading(level, text):
            self = .heading(level: level, text: Self.inline(text, style: style))
        case let .paragraph(text):
            self = .paragraph(Self.inline(text, style: style))
        case let .code(code):
            self = .code(code)
        case let .list(items):
            self = .list(items.map {
                Item(indent: $0.indent, marker: $0.marker,
                     text: Self.inline($0.text, style: style))
            })
        case let .quote(text):
            self = .quote(Self.inline(text, style: style))
        case let .table(rows):
            self = .table(rows.map { $0.map { Self.inline($0, style: style) } })
        case .rule:
            self = .rule
        }
    }

    private static func inline(_ text: String, style: MNMarkdownStyle) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let codeRanges = attributed.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            attributed[range].backgroundColor = MNColor.bgCode
            attributed[range].font = style.inlineCodeFont
        }
        let linkRanges = attributed.runs.compactMap { run in
            run.link != nil ? run.range : nil
        }
        for range in linkRanges {
            attributed[range].foregroundColor = MNColor.secondary
        }
        return attributed
    }
}

public final class MNMarkdownDocument: Equatable, Sendable {
    fileprivate let blocks: [RenderedBlock]
    fileprivate let anchors: [Int: String]
    public let slugs: Set<String>
    public let style: MNMarkdownStyle

    public init(parsing text: String, style: MNMarkdownStyle = .ui,
                headingSlugs: ([String]) -> [String] = HeadingSlug.slugs(forHeadings:)) {
        let parsed = MarkdownBlock.parse(text)
        var indices: [Int] = []
        var texts: [String] = []
        for (index, block) in parsed.enumerated() {
            if case .heading(_, let heading) = block {
                indices.append(index)
                texts.append(heading)
            }
        }
        let slugList = headingSlugs(texts)
        self.blocks = parsed.map { RenderedBlock($0, style: style) }
        self.anchors = Dictionary(uniqueKeysWithValues: zip(indices, slugList))
        self.slugs = Set(slugList)
        self.style = style
    }

    fileprivate var blockCount: Int { blocks.count }

    public static func == (lhs: MNMarkdownDocument, rhs: MNMarkdownDocument) -> Bool {
        lhs === rhs
    }
}

@MainActor
private enum MNMarkdownCache {
    private struct Key: Hashable {
        let text: String
        let style: MNMarkdownStyle
    }

    private static var documents: [Key: MNMarkdownDocument] = [:]
    private static var order: [Key] = []
    private static let limit = 64

    static func document(text: String, style: MNMarkdownStyle) -> MNMarkdownDocument {
        let key = Key(text: text, style: style)
        if let hit = documents[key] { return hit }
        let document = MNMarkdownDocument(parsing: text, style: style)
        documents[key] = document
        order.append(key)
        if order.count > limit {
            documents.removeValue(forKey: order.removeFirst())
        }
        return document
    }
}

public struct MNMarkdownView: View, Equatable {
    private enum Source: Equatable {
        case text(String, MNMarkdownStyle)
        case document(MNMarkdownDocument)
    }

    private static let lazyThreshold = 24

    private let source: Source

    public init(text: String, style: MNMarkdownStyle = .ui) {
        self.source = .text(text, style)
    }

    public init(document: MNMarkdownDocument) {
        self.source = .document(document)
    }

    public static func anchorID(_ slug: String) -> String { "h:\(slug)" }

    private var resolved: MNMarkdownDocument {
        switch source {
        case let .text(text, style): return MNMarkdownCache.document(text: text, style: style)
        case let .document(document): return document
        }
    }

    public var body: some View {
        let document = resolved
        stack(document)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func stack(_ document: MNMarkdownDocument) -> some View {
        if document.blockCount >= Self.lazyThreshold {
            LazyVStack(alignment: .leading, spacing: document.style.blockSpacing) {
                blocks(document)
            }
        } else {
            VStack(alignment: .leading, spacing: document.style.blockSpacing) {
                blocks(document)
            }
        }
    }

    @ViewBuilder
    private func blocks(_ document: MNMarkdownDocument) -> some View {
        ForEach(document.blocks.indices, id: \.self) { index in
            if let anchor = document.anchors[index] {
                blockView(document.blocks[index], style: document.style)
                    .id(Self.anchorID(anchor))
            } else {
                blockView(document.blocks[index], style: document.style)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: RenderedBlock, style: MNMarkdownStyle) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(style.headingFont(level))
                .foregroundStyle(MNColor.contents000)
                .padding(.top, style.headingTopPadding(level))

        case .paragraph(let text):
            Text(text)
                .font(style.bodyFont)
                .lineSpacing(style.bodyLineSpacing)
                .foregroundStyle(MNColor.contents100)

        case .code(let code):
            Text(code)
                .font(.system(size: style.codeFontSize, design: .monospaced))
                .lineSpacing(style.codeLineSpacing)
                .foregroundStyle(MNColor.contents100)
                .padding(MNSpacing.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MNColor.bgCode, in: RoundedRectangle(cornerRadius: MNRadius.r6))

        case .list(let items):
            VStack(alignment: .leading, spacing: style.listItemSpacing) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .top, spacing: MNSpacing.s8) {
                        Text(item.marker)
                            .font(style.bodyFont)
                            .foregroundStyle(MNColor.contents150)
                        Text(item.text)
                            .font(style.bodyFont)
                            .lineSpacing(style.bodyLineSpacing)
                            .foregroundStyle(MNColor.contents100)
                    }
                    .padding(.leading, CGFloat(item.indent) * MNSpacing.s16)
                }
            }

        case .quote(let text):
            Text(text)
                .font(style.bodyFont)
                .lineSpacing(style.bodyLineSpacing)
                .foregroundStyle(MNColor.contents150)
                .padding(.leading, MNSpacing.s12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(MNColor.divider)
                        .frame(width: 3)
                }

        case .table(let rows):
            Grid(alignment: .topLeading,
                 horizontalSpacing: MNSpacing.s16, verticalSpacing: style.tableRowSpacing) {
                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(rows[rowIndex].indices, id: \.self) { column in
                            Text(rows[rowIndex][column])
                                .font(rowIndex == 0 ? style.tableHeaderFont : style.bodyFont)
                                .lineSpacing(style.bodyLineSpacing)
                                .foregroundStyle(rowIndex == 0
                                    ? MNColor.contents000 : MNColor.contents100)
                        }
                    }
                    if rowIndex == 0 {
                        Divider()
                    }
                }
            }

        case .rule:
            Divider()
        }
    }
}

private enum MarkdownBlock {
    struct ListItem {
        let indent: Int
        let marker: String
        let text: String
    }

    case heading(Int, String)
    case paragraph(String)
    case code(String)
    case list([ListItem])
    case quote(String)
    case table([[String]])
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String]?
        var listItems: [ListItem] = []
        var quoteLines: [String] = []
        var tableRows: [[String]] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !listItems.isEmpty {
                blocks.append(.list(listItems))
                listItems = []
            }
            if !quoteLines.isEmpty {
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                quoteLines = []
            }
            if !tableRows.isEmpty {
                blocks.append(.table(tableRows))
                tableRows = []
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            if codeLines != nil {
                if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(codeLines!.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    codeLines!.append(rawLine)
                }
                continue
            }

            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flush()
                codeLines = []
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let rest = line.drop(while: { $0 == "#" })
                if level <= 6, rest.first == " " {
                    flush()
                    blocks.append(.heading(level, rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if line == "---" || line == "***" || line == "___" {
                flush()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix(">") {
                if !paragraph.isEmpty || !listItems.isEmpty || !tableRows.isEmpty { flush() }
                quoteLines.append(
                    String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if line.hasPrefix("|") {
                if line.allSatisfy({ "|-: ".contains($0) }) { continue }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if !paragraph.isEmpty || !listItems.isEmpty || !quoteLines.isEmpty { flush() }
                tableRows.append(cells)
                continue
            }
            if let item = listItem(rawLine: rawLine, trimmed: line) {
                if !paragraph.isEmpty || !quoteLines.isEmpty || !tableRows.isEmpty { flush() }
                listItems.append(item)
                continue
            }

            if !listItems.isEmpty || !quoteLines.isEmpty || !tableRows.isEmpty { flush() }
            paragraph.append(line)
        }

        if let codeLines {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    private static func listItem(rawLine: String, trimmed: String) -> ListItem? {
        let indent = min(rawLine.prefix(while: { $0 == " " }).count / 2, 3)
        if let first = trimmed.first, "-*+".contains(first),
           trimmed.dropFirst().first == " " {
            return ListItem(indent: indent, marker: "•",
                            text: String(trimmed.dropFirst(2)))
        }
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let rest = trimmed.dropFirst(digits.count)
            if let punct = rest.first, punct == "." || punct == ")",
               rest.dropFirst().first == " " {
                return ListItem(indent: indent, marker: "\(digits).",
                                text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
