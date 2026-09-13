import Foundation

public struct FluxgramMihomoSubscriptionInfo: Codable, Equatable {
    public let upload: Int64?
    public let download: Int64?
    public let total: Int64?
    public let expire: Int64?

    private enum CodingKeys: String, CodingKey {
        case upload = "Upload"
        case download = "Download"
        case total = "Total"
        case expire = "Expire"
    }
}

public struct FluxgramMihomoProvider: Codable, Equatable {
    public let name: String
    public let vehicleCount: Int
    public let updatedAt: String?
    public let subscriptionInfo: FluxgramMihomoSubscriptionInfo?
}

public struct FluxgramMihomoGroup: Codable, Equatable {
    public let name: String
    public let type: String
    public let now: String?
    public let candidates: [String]
}

public struct FluxgramMihomoStatus: Codable, Equatable {
    public let ok: Bool
    public let version: String?
    public let groups: [FluxgramMihomoGroup]
    public let providers: [FluxgramMihomoProvider]
}

public final class FluxgramMihomoService {
    public static let shared = FluxgramMihomoService()

    private init() {
    }

    func fetchStatus(settings: FluxgramSettings, completion: @escaping (FluxgramMihomoStatus?, String?) -> Void) {
        perform(settings: settings, path: ["mihomo", "status"], method: "GET", body: nil) { data, statusCode, error in
            guard let data, statusCode == 200 else {
                completion(nil, error ?? "无法连接 Mihomo 管理服务。")
                return
            }
            do {
                completion(try JSONDecoder().decode(FluxgramMihomoStatus.self, from: data), nil)
            } catch {
                completion(nil, "Mihomo 返回的数据无效。")
            }
        }
    }

    func refreshProvider(settings: FluxgramSettings, name: String, completion: @escaping (Bool, String?) -> Void) {
        let body = try? JSONSerialization.data(withJSONObject: ["name": name], options: [])
        perform(settings: settings, path: ["mihomo", "provider", "refresh"], method: "POST", body: body) { _, statusCode, error in
            completion(statusCode == 200, error ?? (statusCode == 200 ? nil : "订阅刷新失败。"))
        }
    }

    func selectGroup(settings: FluxgramSettings, group: String, name: String, completion: @escaping (Bool, String?) -> Void) {
        let body = try? JSONSerialization.data(withJSONObject: ["group": group, "name": name], options: [])
        perform(settings: settings, path: ["mihomo", "group", "select"], method: "POST", body: body) { _, statusCode, error in
            completion(statusCode == 200, error ?? (statusCode == 200 ? nil : "代理组切换失败。"))
        }
    }

    private func perform(settings: FluxgramSettings, path: [String], method: String, body: Data?, completion: @escaping (Data?, Int, String?) -> Void) {
        let endpoint = settings.notifyStatusURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (settings.notifyStatusToken.isEmpty ? settings.accessToken : settings.notifyStatusToken)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, !token.isEmpty, var components = URLComponents(string: endpoint), components.scheme != nil else {
            completion(nil, 0, "请先在 Fluxgram 设置中填写 NAS 监听地址和令牌。")
            return
        }
        var basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath == "status" || basePath == "control" {
            basePath = ""
        } else if basePath.hasSuffix("/status") || basePath.hasSuffix("/control") {
            basePath = String(basePath.dropLast("/status".count))
        }
        let suffix = path.joined(separator: "/")
        components.path = "/" + ([basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/"))
        guard let url = components.url else {
            completion(nil, 0, "Mihomo 管理地址无效。")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue(token, forHTTPHeaderField: "X-TGAPP-Token")
        if body != nil {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = error.map { _ in "网络请求失败。" }
            DispatchQueue.main.async {
                completion(data, statusCode, message)
            }
        }.resume()
    }
}
