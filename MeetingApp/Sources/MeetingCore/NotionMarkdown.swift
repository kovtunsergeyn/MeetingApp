import Foundation

// Перевод саммари из markdown в блоки Notion.
//
// Notion принимает не текст, а дерево блоков: заголовок, абзац, пункт списка.
// Отправить markdown строкой нельзя — он попадёт на страницу как есть, со
// звёздочками и решётками. Разбор живёт здесь, в ядре без интерфейса, потому
// что это чистая логика: её видно в тестах, и она не зависит от сети.
public enum NotionMarkdown {

    // Отрезок текста с оформлением. Notion хранит абзац не строкой, а набором
    // таких отрезков: «жирный» — свойство куска текста, а не разметка внутри него.
    public struct TextRun: Equatable {
        public let text: String
        public let bold: Bool
        public let italic: Bool
        public let code: Bool
        public let link: String?

        public init(text: String, bold: Bool = false, italic: Bool = false,
                    code: Bool = false, link: String? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.code = code
            self.link = link
        }
    }

    public struct Block: Equatable {
        public let type: String
        public let runs: [TextRun]
        public let language: String?

        public init(type: String, runs: [TextRun], language: String? = nil) {
            self.type = type
            self.runs = runs
            self.language = language
        }
    }

    // Ограничения Notion: один отрезок текста — не длиннее 2000 символов,
    // за один запрос принимается не больше 100 блоков. Длинное саммари иначе
    // отлетает с ошибкой уже после создания страницы, и остаётся пустая запись.
    public static let maxTextLength = 2000
    public static let maxBlocksPerRequest = 100

    // MARK: - Разбор документа

    public static func blocks(from markdown: String) -> [Block] {
        var result: [Block] = []
        let lines = markdown.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                index += 1
                continue
            }

            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1  // закрывающие кавычки
                result.append(Block(type: "code",
                                    runs: splitLongRuns([TextRun(text: code.joined(separator: "\n"))]),
                                    language: language.isEmpty ? "plain text" : language))
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                result.append(Block(type: "divider", runs: []))
                index += 1
                continue
            }

            if let heading = headingBlock(line) {
                result.append(heading)
                index += 1
                continue
            }

            if line.hasPrefix("> ") {
                result.append(Block(type: "quote", runs: runs(from: String(line.dropFirst(2)))))
                index += 1
                continue
            }

            if let bullet = listMarkerLength(line, markers: ["- ", "* ", "+ "]) {
                result.append(Block(type: "bulleted_list_item",
                                    runs: runs(from: String(line.dropFirst(bullet)))))
                index += 1
                continue
            }

            if let numbered = numberedMarkerLength(line) {
                result.append(Block(type: "numbered_list_item",
                                    runs: runs(from: String(line.dropFirst(numbered)))))
                index += 1
                continue
            }

            // Обычный абзац: в markdown он может быть разбит переносами, но на
            // странице это один абзац — иначе саммари рассыпается на обрывки.
            var paragraph = [line]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || startsNewBlock(next) { break }
                paragraph.append(next)
                index += 1
            }
            result.append(Block(type: "paragraph", runs: runs(from: paragraph.joined(separator: " "))))
        }

        return result
    }

    // Первый заголовок первого уровня дублирует название страницы, которое и
    // так стоит в заголовке записи, поэтому на странице он не нужен.
    public static func blocksForPage(markdown: String) -> [Block] {
        var blocks = self.blocks(from: markdown)
        if blocks.first?.type == "heading_1" { blocks.removeFirst() }
        return blocks
    }

    private static func startsNewBlock(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix("> ") || line.hasPrefix("```") { return true }
        if line == "---" || line == "***" || line == "___" { return true }
        if listMarkerLength(line, markers: ["- ", "* ", "+ "]) != nil { return true }
        if numberedMarkerLength(line) != nil { return true }
        return false
    }

    private static func headingBlock(_ line: String) -> Block? {
        // Notion знает только три уровня заголовков, остальные сводим к третьему.
        for (prefix, type) in [("### ", "heading_3"), ("## ", "heading_2"), ("# ", "heading_1")] {
            if line.hasPrefix(prefix) {
                return Block(type: type, runs: runs(from: String(line.dropFirst(prefix.count))))
            }
        }
        if line.hasPrefix("#") {
            let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return Block(type: "heading_3", runs: runs(from: text)) }
        }
        return nil
    }

    private static func listMarkerLength(_ line: String, markers: [String]) -> Int? {
        for marker in markers where line.hasPrefix(marker) { return marker.count }
        return nil
    }

    private static func numberedMarkerLength(_ line: String) -> Int? {
        guard let range = line.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) else { return nil }
        return line.distance(from: range.lowerBound, to: range.upperBound)
    }

    // MARK: - Разбор строки

    public static func runs(from text: String) -> [TextRun] {
        var result: [TextRun] = []
        var plain = ""
        var index = text.startIndex

        func flushPlain() {
            if !plain.isEmpty {
                result.append(TextRun(text: plain))
                plain = ""
            }
        }

        while index < text.endIndex {
            let rest = text[index...]

            if let (content, length) = enclosed(rest, marker: "**") {
                flushPlain()
                result.append(TextRun(text: content, bold: true))
                index = text.index(index, offsetBy: length)
                continue
            }
            if let (content, length) = enclosed(rest, marker: "`") {
                flushPlain()
                result.append(TextRun(text: content, code: true))
                index = text.index(index, offsetBy: length)
                continue
            }
            if let (content, length) = enclosed(rest, marker: "*"), !content.isEmpty {
                flushPlain()
                result.append(TextRun(text: content, italic: true))
                index = text.index(index, offsetBy: length)
                continue
            }
            if let (title, url, length) = link(rest) {
                flushPlain()
                result.append(TextRun(text: title, link: url))
                index = text.index(index, offsetBy: length)
                continue
            }

            plain.append(text[index])
            index = text.index(after: index)
        }

        flushPlain()
        return splitLongRuns(result.isEmpty ? [TextRun(text: "")] : result)
    }

    // Текст между парой одинаковых пометок: «**жирный**», «`код`».
    private static func enclosed(_ text: Substring, marker: String) -> (String, Int)? {
        guard text.hasPrefix(marker) else { return nil }
        let afterOpening = text.index(text.startIndex, offsetBy: marker.count)
        guard afterOpening < text.endIndex,
              let closing = text.range(of: marker, range: afterOpening..<text.endIndex) else { return nil }
        let content = String(text[afterOpening..<closing.lowerBound])
        guard !content.isEmpty else { return nil }
        return (content, marker.count * 2 + content.count)
    }

    // Ссылка вида [текст](адрес).
    private static func link(_ text: Substring) -> (String, String, Int)? {
        guard text.hasPrefix("["),
              let titleEnd = text.firstIndex(of: "]") else { return nil }
        let afterTitle = text.index(after: titleEnd)
        guard afterTitle < text.endIndex, text[afterTitle] == "(",
              let urlEnd = text[afterTitle...].firstIndex(of: ")") else { return nil }
        let title = String(text[text.index(after: text.startIndex)..<titleEnd])
        let url = String(text[text.index(after: afterTitle)..<urlEnd])
        guard !title.isEmpty, !url.isEmpty else { return nil }
        let length = text.distance(from: text.startIndex, to: text.index(after: urlEnd))
        return (title, url, length)
    }

    // Длинный кусок текста режем по границе слова: Notion отказывает целиком,
    // если хоть один отрезок длиннее 2000 символов.
    private static func splitLongRuns(_ runs: [TextRun]) -> [TextRun] {
        var result: [TextRun] = []
        for run in runs {
            var rest = Substring(run.text)
            while rest.count > maxTextLength {
                let limit = rest.index(rest.startIndex, offsetBy: maxTextLength)
                let cut = rest[rest.startIndex..<limit].lastIndex(of: " ") ?? limit
                let piece = rest[rest.startIndex..<cut]
                result.append(TextRun(text: String(piece), bold: run.bold, italic: run.italic,
                                      code: run.code, link: run.link))
                rest = rest[rest.index(after: cut)...]
            }
            result.append(TextRun(text: String(rest), bold: run.bold, italic: run.italic,
                                  code: run.code, link: run.link))
        }
        return result
    }

    // MARK: - Тело запроса

    // Блок в том виде, в каком его ждёт API Notion.
    public static func payload(for block: Block) -> [String: Any] {
        if block.type == "divider" {
            return ["object": "block", "type": "divider", "divider": [String: Any]()]
        }

        var content: [String: Any] = ["rich_text": block.runs.map(payload(for:))]
        if block.type == "code" {
            content["language"] = block.language ?? "plain text"
        }
        return ["object": "block", "type": block.type, block.type: content]
    }

    public static func payload(for run: TextRun) -> [String: Any] {
        var text: [String: Any] = ["content": run.text]
        if let link = run.link { text["link"] = ["url": link] }
        return [
            "type": "text",
            "text": text,
            "annotations": ["bold": run.bold, "italic": run.italic, "code": run.code]
        ]
    }
}
