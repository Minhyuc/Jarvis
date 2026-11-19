import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OpenAIServiceError: Error, LocalizedError, Equatable, Sendable {
    case missingKey, disabled, dailyLimit, inputTooLong, unauthorized, rateLimited
    case network, unavailable, invalidResponse, incomplete, refused

    public var errorDescription: String? {
        switch self {
        case .missingKey: "OpenAI API 키를 먼저 저장해주세요."
        case .disabled: "OpenAI 비사용 모드입니다."
        case .dailyLimit: "설정한 오늘의 OpenAI 요청 한도에 도달했습니다."
        case .inputTooLong: "입력이 길어 이번 요청은 기기에서 처리합니다."
        case .unauthorized: "OpenAI API 키 또는 프로젝트 접근 권한을 확인해주세요."
        case .rateLimited: "OpenAI 사용 한도 또는 크레딧을 확인해주세요."
        case .network: "OpenAI에 연결하지 못했습니다. 인터넷 연결을 확인해주세요."
        case .unavailable: "OpenAI 서비스가 응답하지 않습니다. 잠시 뒤 다시 시도해주세요."
        case .invalidResponse: "OpenAI 응답을 읽지 못했습니다."
        case .incomplete: "OpenAI 답변이 완성되지 않았습니다."
        case .refused: "OpenAI가 이 요청에 답변하지 않았습니다."
        }
    }
}

public struct OpenAITextResponse: Equatable, Sendable {
    public let text: String
    public let inputTokens: Int
    public let outputTokens: Int

    public init(text: String, inputTokens: Int, outputTokens: Int) {
        self.text = text
        self.inputTokens = min(1_000_000, max(0, inputTokens))
        self.outputTokens = min(1_000_000, max(0, outputTokens))
    }
}

public protocol OpenAIResponding: Sendable {
    func generate(apiKey: String, instructions: String, input: String, maximumOutputTokens: Int) async throws -> OpenAITextResponse
}

/// Text-only transport. No tools, remote memory, background jobs, automatic
/// retry, or device execution. Never surface raw server bodies or credentials.
public struct OpenAIResponsesTransport: OpenAIResponding {
    public static let model = "gpt-4.1-mini"
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 25
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    public func generate(
        apiKey: String, instructions: String, input: String, maximumOutputTokens: Int
    ) async throws -> OpenAITextResponse {
        try Task.checkCancellation()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              apiKey.count <= 512, !apiKey.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw OpenAIServiceError.missingKey
        }
        guard input.count <= 8_000, instructions.count <= 3_000 else {
            throw OpenAIServiceError.inputTooLong
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(
            model: Self.model,
            instructions: instructions,
            input: input,
            max_output_tokens: min(max(maximumOutputTokens, 128), 800),
            store: false
        ))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw OpenAIServiceError.network
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw OpenAIServiceError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw OpenAIServiceError.unauthorized
        case 429: throw OpenAIServiceError.rateLimited
        case 500...599: throw OpenAIServiceError.unavailable
        default: throw OpenAIServiceError.invalidResponse
        }
        guard data.count <= 262_144,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OpenAIServiceError.invalidResponse
        }
        guard decoded.status == "completed" else { throw OpenAIServiceError.incomplete }
        let content = decoded.output.filter { $0.type == "message" && $0.role == "assistant" }.flatMap { $0.content ?? [] }
        if content.contains(where: { $0.type == "refusal" }) { throw OpenAIServiceError.refused }
        let text = content.filter { $0.type == "output_text" }.compactMap(\.text)
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 16_000 else { throw OpenAIServiceError.invalidResponse }
        return .init(text: text, inputTokens: decoded.usage?.input_tokens ?? 0, outputTokens: decoded.usage?.output_tokens ?? 0)
    }

    private struct Payload: Encodable {
        let model: String
        let instructions: String
        let input: String
        let max_output_tokens: Int
        let store: Bool
    }

    private struct Response: Decodable {
        let status: String
        let output: [Output]
        let usage: Usage?
        struct Output: Decodable {
            let type: String
            let role: String?
            let content: [Content]?
        }
        struct Content: Decodable {
            let type: String
            let text: String?
        }
        struct Usage: Decodable {
            let input_tokens: Int
            let output_tokens: Int
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Do not forward a bearer credential to a redirected endpoint.
        completionHandler(nil)
    }
}
