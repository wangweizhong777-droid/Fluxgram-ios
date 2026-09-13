import Foundation
import CryptoKit

public struct FluxgramAIResult: Equatable {
    public let model: String
    public let text: String

    public init(model: String, text: String) {
        self.model = model
        self.text = text
    }
}

public enum FluxgramAIError: Error {
    case notConfigured
    case invalidEndpoint
    case invalidResponse
    case server(String)

    public var localizedDescription: String {
        switch self {
        case .notConfigured:
            return "请先在 Fluxgram 设置中填写 AI API Key。"
        case .invalidEndpoint:
            return "AI 中转站地址无效，请检查设置。"
        case .invalidResponse:
            return "AI 返回了无法识别的结果。"
        case let .server(message):
            return message
        }
    }
}

private struct FluxgramAIModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]?
    let models: [Model]?

    var modelIds: [String] {
        return (self.data ?? self.models ?? []).map(\.id).filter { !$0.isEmpty }
    }
}

private struct FluxgramAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message?
    }

    let choices: [Choice]?
}

private struct FluxgramAIErrorResponse: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
    }

    let error: ErrorBody?
    let message: String?
}

public final class FluxgramAIService {
    public static let shared = FluxgramAIService()

    private let preferredFallbackModels = [
        "gpt-5.6-terra",
        "claude-sonnet-4-6",
        "gpt-5.6-sol",
        "gpt-5.5"
    ]
    private let modelCacheLock = NSLock()
    private var cachedModel: (baseURL: String, credentialFingerprint: String, model: String, expiresAt: Date)?

    private init() {
    }

    public func analyze(text: String, completion: @escaping (Result<FluxgramAIResult, FluxgramAIError>) -> Void) {
        self.analyze(
            text: text,
            systemPrompt: "你是 Fluxgram 的消息抽取助手。只根据用户提供的消息摘要，严格输出两行：第一行是作者名，第二行是关键词。作者名优先取署名、频道名或作者候选；找不到就写未识别。关键词只输出 1-5 个最相关的短词，优先成人向或题材关键词，不要写长句，不要解释，不要总结剧情，不要额外输出其他内容。",
            completion: completion
        )
    }

    public func analyzeDownloadMetadata(text: String, completion: @escaping (Result<FluxgramAIResult, FluxgramAIError>) -> Void) {
        self.analyze(
            text: text,
            systemPrompt: "你是 Fluxgram 的 NAS 下载整理助手。只根据用户提供的 Telegram 文字摘要提取元数据。严格输出四行，格式必须是：作者名：xxx、xxx\n标题：xxx\n关键词：xxx、xxx\n日本名字：是或否。作者名优先取正文中的作者、主演、署名或账号，不要把 Telegram 发送者、平台名或话题标签当作者；有多个主演就全部列出；没有证据就写未识别。标题优先取正文里最像标题的一行；没有明确标题就写未识别。关键词只输出 1-8 个短词，保留正文中明确的成人向、服装、动作、题材或其他 # 标签，不要写长句，不要解释。日本名字只判断作者名是否像日本姓名，不要根据平台名判断。",
            completion: completion
        )
    }

    private func analyze(text: String, systemPrompt: String, completion: @escaping (Result<FluxgramAIResult, FluxgramAIError>) -> Void) {
        let trimmedText = Self.promptText(text)
        guard !trimmedText.isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(.server("这条消息没有可发送给 AI 的文字摘要。")))
            }
            return
        }

        let settings: FluxgramSettings
        do {
            settings = try FluxgramSettingsStore.load()
        } catch {
            DispatchQueue.main.async {
                completion(.failure(.notConfigured))
            }
            return
        }

        let apiKey = settings.aiAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(.notConfigured))
            }
            return
        }

        guard let baseURL = Self.baseURL(settings.aiBaseURL) else {
            DispatchQueue.main.async {
                completion(.failure(.invalidEndpoint))
            }
            return
        }

        let configuredModel = settings.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fetchModel(baseURL: baseURL, apiKey: apiKey, preferredModel: configuredModel) { [weak self] result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(model):
                self?.sendChat(baseURL: baseURL, apiKey: apiKey, model: model, text: trimmedText, systemPrompt: systemPrompt, allowModelFallback: true, completion: completion)
            }
        }
    }

    private func fetchModel(baseURL: URL, apiKey: String, preferredModel: String, completion: @escaping (Result<String, FluxgramAIError>) -> Void) {
        if !preferredModel.isEmpty {
            completion(.success(preferredModel))
            return
        }

        self.modelCacheLock.lock()
        let cached = self.cachedModel
        self.modelCacheLock.unlock()
        let credentialFingerprint = Self.credentialFingerprint(apiKey)
        if let cached, cached.baseURL == baseURL.absoluteString, cached.credentialFingerprint == credentialFingerprint, cached.expiresAt > Date() {
            completion(.success(cached.model))
            return
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20.0
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async {
                    completion(.failure(.server("读取 AI 模型列表失败：\(error.localizedDescription)")))
                }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(.failure(.invalidResponse))
                }
                return
            }
            guard let data else {
                DispatchQueue.main.async {
                    completion(.failure(.server("AI 模型列表为空（HTTP \(httpResponse.statusCode)）。")))
                }
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                DispatchQueue.main.async {
                    completion(.failure(.server(Self.serverMessage(data: data, statusCode: httpResponse.statusCode))))
                }
                return
            }
            guard let models = try? JSONDecoder().decode(FluxgramAIModelsResponse.self, from: data) else {
                DispatchQueue.main.async {
                    completion(.failure(.server("中转站没有返回可用模型。")))
                }
                return
            }
            let modelIds = models.modelIds
            if let preferredModel = self.preferredFallbackModels.first(where: { modelIds.contains($0) }) {
                self.cacheModel(preferredModel, for: baseURL, apiKey: apiKey)
                DispatchQueue.main.async {
                    completion(.success(preferredModel))
                }
                return
            }
            guard let model = modelIds.first else {
                DispatchQueue.main.async {
                    completion(.failure(.server("中转站没有返回可用模型。")))
                }
                return
            }
            self.cacheModel(model, for: baseURL, apiKey: apiKey)
            DispatchQueue.main.async {
                completion(.success(model))
            }
        }.resume()
    }

    private func cacheModel(_ model: String, for baseURL: URL, apiKey: String) {
        self.modelCacheLock.lock()
        self.cachedModel = (baseURL: baseURL.absoluteString, credentialFingerprint: Self.credentialFingerprint(apiKey), model: model, expiresAt: Date().addingTimeInterval(600.0))
        self.modelCacheLock.unlock()
    }

    private static func credentialFingerprint(_ apiKey: String) -> String {
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func sendChat(baseURL: URL, apiKey: String, model: String, text: String, systemPrompt: String, allowModelFallback: Bool, completion: @escaping (Result<FluxgramAIResult, FluxgramAIError>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45.0
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 220,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": text
                ]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async {
                    completion(.failure(.server("AI 请求失败：\(error.localizedDescription)")))
                }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, let data else {
                DispatchQueue.main.async {
                    completion(.failure(.invalidResponse))
                }
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                // Relay services may expose a stale/alias model or an upstream
                // provider may temporarily reject one model. Discover a
                // different currently available model once before surfacing
                // the 5xx error to the user.
                if allowModelFallback, httpResponse.statusCode >= 500 {
                    self.fetchModelExcluding(baseURL: baseURL, apiKey: apiKey, excluding: model) { fallback in
                        guard let fallback, fallback != model else {
                            DispatchQueue.main.async {
                                completion(.failure(.server(Self.serverMessage(data: data, statusCode: httpResponse.statusCode))))
                            }
                            return
                        }
                        self.sendChat(baseURL: baseURL, apiKey: apiKey, model: fallback, text: text, systemPrompt: systemPrompt, allowModelFallback: false, completion: completion)
                    }
                    return
                }
                DispatchQueue.main.async {
                    completion(.failure(.server(Self.serverMessage(data: data, statusCode: httpResponse.statusCode))))
                }
                return
            }
            guard let decoded = try? JSONDecoder().decode(FluxgramAIChatResponse.self, from: data), let result = decoded.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
                DispatchQueue.main.async {
                    completion(.failure(.invalidResponse))
                }
                return
            }
            DispatchQueue.main.async {
                completion(.success(FluxgramAIResult(model: model, text: result)))
            }
        }.resume()
    }

    private func fetchModelExcluding(baseURL: URL, apiKey: String, excluding: String, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 20.0
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let data,
                  let models = try? JSONDecoder().decode(FluxgramAIModelsResponse.self, from: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let model = models.modelIds.first(where: { $0 != excluding })
            if let model {
                self.cacheModel(model, for: baseURL, apiKey: apiKey)
            }
            DispatchQueue.main.async { completion(model) }
        }.resume()
    }

    private static func baseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https", components.host != nil else {
            return nil
        }
        components.scheme = scheme
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.lowercased().hasSuffix("/v1") {
            path += "/v1"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // Keep large multi-message selections responsive and within relay context
    // limits. The beginning usually contains the author/number/title, while
    // the tail often contains hashtags; retain both and make omission clear.
    private static func promptText(_ value: String, limit: Int = 12000) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            return trimmed
        }
        let headCount = min(8000, limit * 2 / 3)
        let tailCount = max(1, limit - headCount)
        let headEnd = trimmed.index(trimmed.startIndex, offsetBy: headCount)
        let tailStart = trimmed.index(trimmed.endIndex, offsetBy: -tailCount)
        return String(trimmed[..<headEnd]) + "\n…（中间文字已截断，仅发送摘要）…\n" + String(trimmed[tailStart...])
    }

    private static func serverMessage(data: Data, statusCode: Int) -> String {
        if let decoded = try? JSONDecoder().decode(FluxgramAIErrorResponse.self, from: data), let message = decoded.error?.message ?? decoded.message, !message.isEmpty {
            return "AI 服务返回错误（HTTP \(statusCode)）：\(message)"
        }
        return "AI 服务返回错误（HTTP \(statusCode)）。"
    }
}
