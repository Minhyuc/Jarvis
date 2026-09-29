import Foundation

protocol AIClient {
    func reply(to text: String) async throws -> String
}

struct MockAIClient: AIClient {
    func reply(to text: String) async throws -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.contains("안녕") {
            return "안녕하세요. 무엇을 도와드릴까요?"
        }
        if normalized.contains("이름") {
            return "저는 자비스입니다. 현재는 기본 명령과 간단한 대화를 처리할 수 있습니다."
        }
        if normalized.contains("할 수") {
            return "현재는 음성 대화와 유튜브 검색 실행을 지원합니다."
        }

        return "‘\(normalized)’라고 말씀하셨습니다. 아직 학습 중이라 기본 명령 위주로 도와드릴 수 있습니다."
    }
}
