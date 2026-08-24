import Foundation

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

    private init() {
    }

    public func analyze(text: String, completion: @escaping (Result<FluxgramAIResult, FluxgramAIError>) -> Void) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
                self?.sendChat(baseURL: baseURL, apiKey: apiKey, model: model, text: trimmedText, completion: completion)
            }
        }
    }

    private func fetchModel(baseURL: URL, apiKey: String, preferredModel: String, completion: @escaping (Result<String, FluxgramAIError>) -> Void) {
        if !preferredModel.isEmpty {
            completion(.success(preferredModel))
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
            guard let models = try? JSONDecoder().decode(FluxgramAIModelsResponse.self, from: data), let model = models.modelIds.first else {
                DispatchQueue.main.async {
                    completion(.failure(.server("中转站没有返回可用模型。")))
                }
                return
            }
            DispatchQueue.main.async {
                completion(.success(model))
            }
        }.resume()
    }

    private func sendChat(baseURL: URL, apiKey: String, model: String, text: String, completion: @escaping (Result<FluxgramAIResult, FluxgramAIError>) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45.0
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 600,
            "messages": [
                [
                    "role": "system",
                    "content": "你是 Fluxgram 的消息整理助手。只根据用户提供的消息摘要，输出简洁的中文分析：先给出一句摘要，再给出 1-3 个建议分类标签。不要声称看到了未提供的图片、文件或会话内容。"
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

    private static func serverMessage(data: Data, statusCode: Int) -> String {
        if let decoded = try? JSONDecoder().decode(FluxgramAIErrorResponse.self, from: data), let message = decoded.error?.message ?? decoded.message, !message.isEmpty {
            return "AI 服务返回错误（HTTP \(statusCode)）：\(message)"
        }
        return "AI 服务返回错误（HTTP \(statusCode)）。"
    }
}
