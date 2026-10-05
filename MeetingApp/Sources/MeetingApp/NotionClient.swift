import Foundation
import MeetingCore

// Прямая работа с API Notion по токену.
//
// Раньше выгрузкой занимался Claude Code через подключение Notion, и это
// оказалось ненадёжным: подключения аккаунта claude.ai не достаются сессии,
// которую запускает приложение, а сам claude завершался с нулевым кодом, ничего
// не сделав. Теперь приложение ходит в Notion само: токен — в Связке ключей,
// запросы — обычный HTTP, ошибку видно сразу и по делу.
enum NotionError: LocalizedError {
    case noToken
    case unauthorized
    case databaseNotFound(String)
    case noTitleProperty
    case http(Int, String)
    case network(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "Токен Notion не задан. Настройки → Интеграции."
        case .unauthorized:
            return "Notion не принял токен: он отозван или скопирован не полностью."
        case .databaseNotFound(let name):
            return "База «\(name)» не найдена. Проверь название и доступ токена к этой базе "
                 + "(Notion → Settings → Developer → Manage your tokens → Access)."
        case .noTitleProperty:
            return "В базе нет свойства-названия — записать страницу некуда."
        case .http(let code, let message):
            return "Notion ответил ошибкой \(code): \(message)"
        case .network(let message):
            return "Не удалось связаться с Notion: \(message)"
        case .badResponse:
            return "Notion вернул неожиданный ответ."
        }
    }
}

struct NotionDatabase {
    let id: String
    let titleProperty: String
    let dateProperty: String?
}

struct NotionClient {
    let token: String

    // Версия API фиксирована намеренно: Notion не ломает старые версии, а на
    // новых поведение меняется (в 2025-09-03 страница создаётся уже не в базе,
    // а в источнике данных). Обновлять — осознанно и с проверкой.
    private let apiVersion = "2022-06-28"
    private let base = URL(string: "https://api.notion.com/v1/")!

    // Токен живой? Ответ на этот запрос — единственная честная проверка.
    func checkToken() async throws {
        _ = try await send(method: "GET", path: "users/me", body: nil)
    }

    func findDatabase(named name: String) async throws -> NotionDatabase {
        let body: [String: Any] = [
            "query": name,
            "filter": ["value": "database", "property": "object"],
            "page_size": 20
        ]
        let response = try await send(method: "POST", path: "search", body: body)
        guard let results = response["results"] as? [[String: Any]] else { throw NotionError.badResponse }

        // Точное совпадение названия важнее порядка выдачи: поиск Notion охотно
        // возвращает похожие базы, и саммари уехало бы не туда.
        let matching = results.first { database in
            plainTitle(of: database).compare(name, options: .caseInsensitive) == .orderedSame
        } ?? results.first

        guard let database = matching, let id = database["id"] as? String else {
            throw NotionError.databaseNotFound(name)
        }

        let properties = database["properties"] as? [String: Any] ?? [:]
        guard let titleProperty = propertyName(in: properties, ofType: "title") else {
            throw NotionError.noTitleProperty
        }
        return NotionDatabase(id: id,
                              titleProperty: titleProperty,
                              dateProperty: propertyName(in: properties, ofType: "date"))
    }

    // Создаёт страницу и возвращает ссылку на неё.
    func createPage(in database: NotionDatabase,
                    title: String,
                    date: Date?,
                    blocks: [NotionMarkdown.Block]) async throws -> String {
        var properties: [String: Any] = [
            database.titleProperty: ["title": [["text": ["content": String(title.prefix(200))]]]]
        ]
        if let dateProperty = database.dateProperty, let date = date {
            properties[dateProperty] = ["date": ["start": NotionClient.dayFormatter.string(from: date)]]
        }

        let first = Array(blocks.prefix(NotionMarkdown.maxBlocksPerRequest))
        let body: [String: Any] = [
            "parent": ["database_id": database.id],
            "properties": properties,
            "children": first.map(NotionMarkdown.payload(for:))
        ]

        let page = try await send(method: "POST", path: "pages", body: body)
        guard let pageID = page["id"] as? String else { throw NotionError.badResponse }

        // Остаток саммари дописываем частями: больше ста блоков за раз Notion
        // не принимает, а длинные встречи дают их заметно больше.
        var rest = Array(blocks.dropFirst(NotionMarkdown.maxBlocksPerRequest))
        while !rest.isEmpty {
            let chunk = Array(rest.prefix(NotionMarkdown.maxBlocksPerRequest))
            rest = Array(rest.dropFirst(NotionMarkdown.maxBlocksPerRequest))
            _ = try await send(method: "PATCH",
                               path: "blocks/\(pageID)/children",
                               body: ["children": chunk.map(NotionMarkdown.payload(for:))])
        }

        if let url = page["url"] as? String { return url }
        return "https://www.notion.so/" + pageID.replacingOccurrences(of: "-", with: "")
    }

    // MARK: - Внутреннее

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func plainTitle(of database: [String: Any]) -> String {
        guard let parts = database["title"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["plain_text"] as? String }.joined()
    }

    private func propertyName(in properties: [String: Any], ofType type: String) -> String? {
        for (name, value) in properties {
            if let property = value as? [String: Any], property["type"] as? String == type {
                return name
            }
        }
        return nil
    }

    private func send(method: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NotionError.noToken }

        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NotionError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw NotionError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode == 401 { throw NotionError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let message = json["message"] as? String ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw NotionError.http(http.statusCode, message)
        }
        return json
    }
}
