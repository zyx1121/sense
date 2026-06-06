import Foundation
import Security

/// OpenAI API key 來源：環境變數優先（開發方便），否則 Keychain（service=kilo, account=openai）。
/// 絕不寫進 code / repo。
enum Keychain {
    static func openAIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "kilo",
            kSecAttrAccount as String: "openai",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
