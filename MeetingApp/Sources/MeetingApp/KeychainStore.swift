import Foundation
import Security

// Хранилище секретов в Связке ключей macOS.
//
// Токен Notion — это ключ от рабочего пространства, и в UserDefaults ему не
// место: настройки приложения лежат обычным файлом в ~/Library/Preferences,
// который читает кто угодно без пароля. Связка ключей шифруется и отдаёт
// значение только этому приложению.
enum KeychainStore {
    // Разделяем секреты тестовой и рабочей сборки: у них разные идентификаторы,
    // и подменять друг другу токен они не должны.
    private static var account: String {
        return Bundle.main.bundleIdentifier ?? "com.meetingapp.macos"
    }

    static func read(service: String) -> String? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    @discardableResult
    static func write(_ value: String, service: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(service: service) }

        let query = baseQuery(service: service)
        let attributes: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]

        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        if updated == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = Data(trimmed.utf8)
            // Секрет нужен только когда человек работает за компьютером, а не
            // сразу после включения до первого входа: так он защищён лучше.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete(service: String) -> Bool {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(service: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
