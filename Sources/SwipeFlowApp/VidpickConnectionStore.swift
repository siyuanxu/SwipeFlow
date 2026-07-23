import Foundation
import Security

enum VidpickCredentialStoreError: Error, LocalizedError {
    case missingPassword
    case keychainFailure(OSStatus)
    case invalidPasswordData

    var errorDescription: String? {
        switch self {
        case .missingPassword:
            "没有找到已保存的 Vidpick 密码。"
        case .keychainFailure:
            "无法访问 macOS 钥匙串。"
        case .invalidPasswordData:
            "钥匙串中的 Vidpick 密码无法读取。"
        }
    }
}

enum VidpickCredentialStore {
    private static let service = "app.swipeflow.vidpick"

    static func account(baseURL: URL, username: String) -> String {
        "\(baseURL.absoluteString)|\(username)"
    }

    static func save(password: String, account: String) throws {
        let passwordData = Data(password.utf8)
        let lookup: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData: passwordData] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw VidpickCredentialStoreError.keychainFailure(updateStatus)
        }

        var item = lookup
        item[kSecValueData] = passwordData
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VidpickCredentialStoreError.keychainFailure(addStatus)
        }
    }

    static func loadPassword(account: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw VidpickCredentialStoreError.missingPassword
        }
        guard status == errSecSuccess else {
            throw VidpickCredentialStoreError.keychainFailure(status)
        }
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw VidpickCredentialStoreError.invalidPasswordData
        }
        return password
    }
}

struct VidpickSavedProfile: Codable, Equatable {
    let serverAddress: String
    let username: String
    let folderPath: String
    let recursive: Bool
}

struct VidpickLocalReviewState: Codable {
    let profile: VidpickSavedProfile
    let retention: [String: String]
    let favorites: [String]
}

enum VidpickProfileStore {
    private static let key = "vidpick.connection.profile.v1"

    static func load() -> VidpickSavedProfile? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(VidpickSavedProfile.self, from: data)
    }

    static func save(_ profile: VidpickSavedProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum VidpickLocalReviewStore {
    private static let key = "vidpick.review.state.v1"

    static func load(for profile: VidpickSavedProfile) -> VidpickLocalReviewState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(VidpickLocalReviewState.self, from: data),
              state.profile == profile else {
            return nil
        }
        return state
    }

    static func save(_ state: VidpickLocalReviewState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
