import AppKit
import SwiftUI

/// 크기 두 단계 — `.ui`는 화면 속 본문(14), `.article`은 문서 읽기(16). 장식·비율은 같고 크기만 다르다
public enum MNMarkdownStyle: Hashable, Sendable {
    case ui
    case article

    public var bodySize: CGFloat { self == .article ? 16 : 14 }
    public var bodyFont: Font { MNFont.sized(bodySize) }
    public var bodyLineSpacing: CGFloat { bodySize * 0.2 }
    public var blockSpacing: CGFloat { self == .article ? MNSpacing.s16 : 14 }
    public var listItemSpacing: CGFloat { self == .article ? 6 : MNSpacing.s4 }
    public var codeFontSize: CGFloat { self == .article ? 13 : 12.5 }
    public var inlineCodeFont: Font { MNFont.mono(bodySize * 0.9) }

    private static let headingScales: [CGFloat] = [1.45, 1.25, 1.1, 1, 1, 1]

    public func headingFont(_ level: Int) -> Font {
        let level = min(max(level, 1), 6)
        return MNFont.sized(bodySize * Self.headingScales[level - 1],
                            weight: level <= 3 ? .semibold : .medium)
    }

    /// 블록 간격 위로 더 띄우는 몫 — 큰 제목일수록 앞 단락과 멀다
    public func headingTopPadding(_ level: Int) -> CGFloat {
        let top: CGFloat = level <= 2 ? (self == .article ? 24 : 18) : (self == .article ? 18 : 14)
        return max(0, top - blockSpacing)
    }

    /// 제목과 본문은 블록 간격보다 붙인다 — 음수 패딩으로 스택 간격을 깎는다
    public var headingBottomPadding: CGFloat { 8 - blockSpacing }
}

private enum RenderedBlock: Sendable {
    struct Item: Sendable {
        let indent: Int
        let marker: String
        let text: AttributedString
    }

    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case code(language: String?, code: String)
    case list([Item])
    case quote(AttributedString)
    case table([[AttributedString]])
    case rule

    private static let bulletMarkers = ["•", "◦", "▪"]

    init(_ block: MarkdownBlock, style: MNMarkdownStyle) {
        switch block {
        case let .heading(level, text):
            self = .heading(level: level, text: Self.inline(text, style: style))
        case let .paragraph(text):
            self = .paragraph(Self.inline(text, style: style))
        case let .code(language, code):
            self = .code(language: language, code: code)
        case let .list(items):
            self = .list(items.map {
                Item(indent: $0.indent,
                     marker: $0.ordinal ?? Self.bulletMarkers[$0.indent % Self.bulletMarkers.count],
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
            attributed[range].backgroundColor = MNColor.codeBackground
            attributed[range].foregroundColor = MNColor.codeText
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

/// 코드 펜스를 그리는 방법 — 호스트가 구문 강조 렌더러로 갈아끼운다(`markdownCodeBlock`). 없으면 패키지 기본 상자
public struct MNCodeBlockRenderer: @unchecked Sendable {
    fileprivate let make: @MainActor (_ code: String, _ language: String?) -> AnyView

    public init<Content: View>(
        @ViewBuilder _ make: @escaping @MainActor (_ code: String, _ language: String?) -> Content
    ) {
        self.make = { AnyView(make($0, $1)) }
    }
}

private struct MNCodeBlockRendererKey: EnvironmentKey {
    static let defaultValue: MNCodeBlockRenderer? = nil
}

private struct MNMarkdownLazyKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    public var mnMarkdownCodeBlock: MNCodeBlockRenderer? {
        get { self[MNCodeBlockRendererKey.self] }
        set { self[MNCodeBlockRendererKey.self] = newValue }
    }

    /// 긴 문서를 LazyVStack으로 그려도 되는가 — 이미 지연 목록의 한 행인 곳(대화 기록)은 끈다.
    /// 지연 스택 안의 지연 스택은 행 높이가 추정치로만 남아 바깥 목록의 높이 추정이 패스마다 출렁인다
    public var mnMarkdownAllowsLazy: Bool {
        get { self[MNMarkdownLazyKey.self] }
        set { self[MNMarkdownLazyKey.self] = newValue }
    }
}

extension View {
    /// 하위의 모든 `MNMarkdownView`가 코드 펜스를 이 뷰로 그린다
    public func markdownCodeBlock<Content: View>(
        @ViewBuilder _ make: @escaping @MainActor (_ code: String, _ language: String?) -> Content
    ) -> some View {
        environment(\.mnMarkdownCodeBlock, MNCodeBlockRenderer(make))
    }

    /// 지연 목록의 행 안에서는 `false` — 마크다운이 자기 LazyVStack을 만들지 않고 한 번에 그린다
    public func markdownAllowsLazy(_ allowed: Bool) -> some View {
        environment(\.mnMarkdownAllowsLazy, allowed)
    }
}

public struct MNMarkdownView: View, Equatable {
    private enum Source: Equatable {
        case text(String, MNMarkdownStyle, cached: Bool)
        case document(MNMarkdownDocument)
    }

    private static let lazyThreshold = 24

    private let source: Source
    @Environment(\.mnMarkdownCodeBlock) private var codeBlock
    @Environment(\.mnMarkdownAllowsLazy) private var allowsLazy

    /// `cached: false` — 스트리밍 꼬리처럼 매번 바뀌는 글. 캐시에 넣으면 다시 볼 일 없는 사본으로 캐시를 밀어낸다
    public init(text: String, style: MNMarkdownStyle = .ui, cached: Bool = true) {
        self.source = .text(text, style, cached: cached)
    }

    public init(document: MNMarkdownDocument) {
        self.source = .document(document)
    }

    nonisolated public static func == (lhs: MNMarkdownView, rhs: MNMarkdownView) -> Bool {
        lhs.source == rhs.source
    }

    public static func anchorID(_ slug: String) -> String { "h:\(slug)" }

    private var resolved: MNMarkdownDocument {
        switch source {
        case let .text(text, style, cached):
            return cached ? MNMarkdownCache.document(text: text, style: style)
                : MNMarkdownDocument(parsing: text, style: style)
        case let .document(document): return document
        }
    }

    public var body: some View {
        stack(resolved)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 텍스트 선택은 지연 여부에 따라 거는 자리가 다르다. 선택은 붙은 컨테이너 안 Text 레이아웃을
    /// 묶어 지켜보고 묶음이 바뀌면 선택 오버레이를 다시 설정하는데, 그 설정이 레이아웃을 무효화한다.
    /// LazyVStack에 통째로 걸면 측정 패스마다 실체화되는 블록이 달라져 묶음이 바뀌고, 무효화가 다음
    /// 패스를 부르는 순환이 한 프레임 안에서 끝나지 않는다(실측: 메인 스레드 고착, 메모리 16GB).
    /// 그래서 지연 스택에선 블록마다 걸어 블록이 들고 나도 다른 묶음은 그대로 두게 한다
    @ViewBuilder
    private func stack(_ document: MNMarkdownDocument) -> some View {
        if allowsLazy, document.blockCount >= Self.lazyThreshold {
            LazyVStack(alignment: .leading, spacing: document.style.blockSpacing) {
                blocks(document, selectablePerBlock: true)
            }
        } else {
            VStack(alignment: .leading, spacing: document.style.blockSpacing) {
                blocks(document, selectablePerBlock: false)
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func blocks(_ document: MNMarkdownDocument, selectablePerBlock: Bool) -> some View {
        ForEach(document.blocks.indices, id: \.self) { index in
            if let anchor = document.anchors[index] {
                block(document, at: index, selectable: selectablePerBlock)
                    .id(Self.anchorID(anchor))
            } else {
                block(document, at: index, selectable: selectablePerBlock)
            }
        }
    }

    @ViewBuilder
    private func block(_ document: MNMarkdownDocument, at index: Int, selectable: Bool) -> some View {
        if selectable {
            blockView(document.blocks[index], style: document.style)
                .textSelection(.enabled)
        } else {
            blockView(document.blocks[index], style: document.style)
        }
    }

    @ViewBuilder
    private func blockView(_ block: RenderedBlock, style: MNMarkdownStyle) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(style.headingFont(level))
                .lineSpacing(style.bodyLineSpacing * 0.75)
                .foregroundStyle(MNColor.contents000)
                .padding(.top, style.headingTopPadding(level))
                .padding(.bottom, style.headingBottomPadding)

        case .paragraph(let text):
            prose(text, style: style)

        case let .code(language, code):
            if let codeBlock {
                codeBlock.make(code, language)
            } else {
                MNCodeBlock(code: code, language: language, fontSize: style.codeFontSize)
            }

        case .list(let items):
            VStack(alignment: .leading, spacing: style.listItemSpacing) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .firstTextBaseline, spacing: style.bodySize * 0.6) {
                        Text(item.marker)
                            .font(style.bodyFont)
                            .foregroundStyle(MNColor.contents150)
                        prose(item.text, style: style)
                    }
                    .padding(.leading, CGFloat(item.indent) * style.bodySize * 1.4)
                }
            }

        case .quote(let text):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(MNColor.divider)
                    .frame(width: 3)
                prose(text, style: style, color: MNColor.contents150)
                    .padding(.leading, MNSpacing.s12)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .table(let rows):
            table(rows, style: style)

        case .rule:
            Rectangle()
                .fill(MNColor.divider)
                .frame(height: 1)
        }
    }

    private func prose(_ text: AttributedString, style: MNMarkdownStyle,
                       color: Color = MNColor.contents000) -> some View {
        Text(text)
            .font(style.bodyFont)
            .lineSpacing(style.bodyLineSpacing)
            .foregroundStyle(color)
    }

    /// 헤더 행 채움 + 행 사이 가로선 + 둥근 테두리. 칸 간격을 0으로 두고 패딩으로 띄워야 헤더 채움이 끊기지 않는다
    private func table(_ rows: [[AttributedString]], style: MNMarkdownStyle) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                if rowIndex > 0 {
                    Rectangle()
                        .fill(MNColor.divider)
                        .frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    ForEach(rows[rowIndex].indices, id: \.self) { column in
                        Text(rows[rowIndex][column])
                            .font(style.bodyFont)
                            .fontWeight(rowIndex == 0 ? .semibold : .regular)
                            .lineSpacing(style.bodyLineSpacing * 0.75)
                            .foregroundStyle(MNColor.contents000)
                            .padding(.vertical, 7)
                            .padding(.horizontal, MNSpacing.s12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(rowIndex == 0 ? MNColor.bg300 : Color.clear)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MNRadius.r8))
        .overlay(RoundedRectangle(cornerRadius: MNRadius.r8).stroke(MNColor.divider, lineWidth: 1))
        .padding(.vertical, MNSpacing.s4)
    }
}

/// 패키지 기본 코드 상자 — 언어 라벨·복사 머리 + 고정폭 본문. 강조는 하지 않는다
private struct MNCodeBlock: View {
    let code: String
    let language: String?
    let fontSize: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MNSpacing.s8) {
                Text(language ?? "code")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MNColor.contents150)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(copied ? MNColor.roleGreen : MNColor.contents150)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(copied ? "복사했습니다" : "복사")
            }
            .padding(.horizontal, MNSpacing.s12)
            .padding(.vertical, 6)
            Rectangle().fill(MNColor.dividerLite).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(MNFont.mono(fontSize))
                    .lineSpacing(fontSize * 0.25)
                    .foregroundStyle(MNColor.contents000)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(MNSpacing.s12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MNColor.bgCode, in: RoundedRectangle(cornerRadius: MNRadius.r8))
        .overlay(RoundedRectangle(cornerRadius: MNRadius.r8).stroke(MNColor.dividerLite, lineWidth: 1))
        .padding(.vertical, MNSpacing.s4)
    }
}

private enum MarkdownBlock {
    struct ListItem {
        let indent: Int
        /// 번호 목록의 `3.` — nil이면 글머리표(단계별 모양은 렌더가 고른다)
        let ordinal: String?
        let text: String
    }

    case heading(Int, String)
    case paragraph(String)
    case code(String?, String)
    case list([ListItem])
    case quote(String)
    case table([[String]])
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: (marker: String, language: String?, lines: [String])?
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
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if line.hasPrefix(open.marker) {
                    blocks.append(.code(open.language, open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence?.lines.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                let marker = String(line.prefix(3))
                let hint = line.drop(while: { $0 == marker.first })
                    .trimmingCharacters(in: .whitespaces)
                fence = (marker, hint.isEmpty ? nil : hint, [])
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

        if let fence {
            blocks.append(.code(fence.language, fence.lines.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    private static func listItem(rawLine: String, trimmed: String) -> ListItem? {
        let indent = min(rawLine.prefix(while: { $0 == " " }).count / 2, 3)
        if let first = trimmed.first, "-*+".contains(first),
           trimmed.dropFirst().first == " " {
            return ListItem(indent: indent, ordinal: nil,
                            text: String(trimmed.dropFirst(2)))
        }
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let rest = trimmed.dropFirst(digits.count)
            if let punct = rest.first, punct == "." || punct == ")",
               rest.dropFirst().first == " " {
                return ListItem(indent: indent, ordinal: "\(digits).",
                                text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
