import Foundation

public enum ActionRiskLevel: Int, Codable, Comparable, Sendable {
    case informational = 0
    case low = 1
    case medium = 2
    case high = 3

    public static func < (lhs: ActionRiskLevel, rhs: ActionRiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum SafetyExecutionOrigin: Equatable, Sendable {
    case directUserRequest
    case modelProposed
    case backgroundAutomation
    case proactiveSuggestion
}

public struct SafetyEvaluationContext: Equatable, Sendable {
    public let origin: SafetyExecutionOrigin
    public let externalActionsLocked: Bool
    public let wasExplicitlyConfirmed: Bool

    public init(
        origin: SafetyExecutionOrigin = .directUserRequest,
        externalActionsLocked: Bool = false,
        wasExplicitlyConfirmed: Bool = false
    ) {
        self.origin = origin
        self.externalActionsLocked = externalActionsLocked
        self.wasExplicitlyConfirmed = wasExplicitlyConfirmed
    }
}

public enum SafetyDecision: Equatable, Sendable {
    case allow(risk: ActionRiskLevel, actionName: String)
    case requireConfirmation(risk: ActionRiskLevel, actionName: String, prompt: String)
    case block(risk: ActionRiskLevel, actionName: String, reason: String)
}

/// Deterministic execution policy. The language model may suggest an intent,
/// but only this layer decides whether a device action is allowed to proceed.
///
/// Before extending this policy, read ``SafetyDevelopmentGuide``. Keep the
/// intent switch exhaustive so every newly added command must receive an
/// explicit safety classification before the project can compile.
public struct SafetyPolicyEngine: Sendable {
    public init() {}

    public func evaluate(
        _ intent: AssistantIntent,
        context: SafetyEvaluationContext
    ) -> SafetyDecision {
        let profile = actionProfile(for: intent)

        if context.externalActionsLocked, profile.isBlockedByEmergencyLock {
            return .block(
                risk: profile.risk,
                actionName: profile.name,
                reason: "안전 잠금이 켜져 있어 외부 실행과 데이터 변경을 중단했습니다. 설정의 안전 및 실행 기록에서 잠금을 해제할 수 있습니다."
            )
        }

        if context.origin == .proactiveSuggestion {
            if profile.risk == .high {
                return .block(risk: .high, actionName: profile.name, reason: "위험도가 높은 제안은 실행하지 않습니다. 필요한 작업은 사용자가 직접 요청해주세요.")
            }
            // Long-term memory still requires explicit consent, regardless of
            // automatic mode. A suggestion is never storage authorization.
            if case .remember = intent, !context.wasExplicitlyConfirmed {
                return .requireConfirmation(risk: .low, actionName: profile.name, prompt: "이 내용을 장기 기억에 저장할까요?")
            }
        }

        if profile.alwaysRequiresConfirmation, !context.wasExplicitlyConfirmed {
            return .requireConfirmation(
                risk: profile.risk,
                actionName: profile.name,
                prompt: profile.confirmationPrompt
                    ?? "되돌리기 어려운 작업입니다. 정말 실행할까요?"
            )
        }

        if context.origin != .directUserRequest,
           profile.hasSideEffect,
           profile.risk >= .medium,
           !context.wasExplicitlyConfirmed {
            return .requireConfirmation(
                risk: profile.risk,
                actionName: profile.name,
                prompt: "자비스가 \(profile.name) 작업을 제안했습니다. 직접 실행을 승인하시겠습니까?"
            )
        }

        return .allow(risk: profile.risk, actionName: profile.name)
    }

    private func actionProfile(for intent: AssistantIntent) -> ActionProfile {
        switch intent {
        case .codexLocal(let action):
            switch action {
            case .agentHistoryChange:
                return ActionProfile(name: "Codex 작업 세션 관리", risk: .high, hasSideEffect: true, isBlockedByEmergencyLock: true,
                    alwaysRequiresConfirmation: true, confirmationPrompt: "선택한 세션과 보관·복원·삭제·압축 작업을 확인해주세요. 압축은 OpenAI 서비스를 사용하며 삭제는 되돌릴 수 없습니다.")
            case .agentConfigureExtensions:
                return ActionProfile(name: "Codex 확장·검색 자격 증명 설정", risk: .high, hasSideEffect: true, isBlockedByEmergencyLock: true,
                    alwaysRequiresConfirmation: true, confirmationPrompt: "검토한 MCP 도구·스킬·검색 설정을 이 Mac에 저장할까요? 저장이 실행 승인을 부여하지 않습니다.")
            case .agentHistoryRead:
                return ActionProfile(name: "Codex 작업 세션 조회", risk: .informational, hasSideEffect: false, isBlockedByEmergencyLock: true)
            case .agentStart:
                return ActionProfile(name: "Codex 프로젝트 작업 시작", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "선택한 프로젝트에서 이 요청을 처리하도록 Codex 작업을 시작할까요? 파일 공유·변경·검증 실행은 별도로 확인합니다.")
            case .agentRespond:
                return ActionProfile(name: "Codex 도구 결과 전송", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "표시된 도구 결과를 현재 Codex 작업에 전달할까요?")
            case .agentSteer:
                return ActionProfile(name: "Codex 작업 추가 지시", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "현재 작업에 이 추가 지시를 전달할까요?")
            case .agentPoll:
                return ActionProfile(name: "Codex 작업 상태 조회", risk: .informational, hasSideEffect: false, isBlockedByEmergencyLock: true)
            case .agentStop:
                return ActionProfile(name: "Codex 프로젝트 작업 중지", risk: .low, hasSideEffect: true, isBlockedByEmergencyLock: false)
            case .attachmentRead:
                return ActionProfile(name: "선택한 첨부 파일 읽기", risk: .informational, hasSideEffect: false,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "첨부할 파일을 직접 선택하고 전송 내용을 검토해주세요.")
            case .workspaceExport:
                return ActionProfile(name: "선택한 답변 파일 저장", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "선택한 답변과 저장 위치를 확인하고 파일로 저장할까요?")
            case .nativeTool:
                return ActionProfile(name: "Codex 네이티브 도구 실행", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "표시된 프로젝트·프로그램·인자와 실행 범위를 확인하고 이번 도구 실행을 허용할까요? MCP 프로그램은 Mac 권한으로 실행되며 연결 서비스에 데이터를 전송할 수 있습니다.")
            case .codeConnect, .codeDraft, .codeApply, .codeRestore:
                return ActionProfile(name: action == .codeConnect ? "Codex 코드 프로젝트 연결" : action == .codeDraft ? "선택 코드 전송·변경안 요청" : action == .codeApply ? "코드 변경 적용" : "코드 백업 복구",
                    risk: .high, hasSideEffect: true, isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: action == .codeConnect ? "선택한 코드 프로젝트의 파일을 읽고 검토한 변경만 적용하도록 허용할까요?"
                        : action == .codeDraft ? "화면에 선택한 코드 범위와 요청을 OpenAI에 전송해 변경안을 받을까요?"
                        : "표시된 파일의 변경 전후 내용과 백업을 확인하고 이 파일에 적용할까요? 실행 중인 앱은 자동으로 바뀌지 않으며 빌드·테스트 실행 승인은 포함하지 않습니다.")
            case .codeRead:
                return ActionProfile(name: "코드 프로젝트·변경안 조회", risk: .informational, hasSideEffect: false, isBlockedByEmergencyLock: true)
            case .loginStart, .logout:
                return ActionProfile(name: action == .loginStart ? "Codex 전용 ChatGPT 로그인" : "Codex 전용 계정 로그아웃", risk: .high,
                    hasSideEffect: true, isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: action == .loginStart ? "브라우저에서 ChatGPT 계정으로 전용 App Server에 로그인할까요? 로그인 정보는 Codex가 보관합니다." : "JARVIS 전용 App Server에서 로그아웃할까요? 기존 CLI와 Codex 앱 계정은 변경하지 않습니다.")
            case .loginPoll, .diagnostics:
                return ActionProfile(name: "Codex 연결·인증 상태 진단", risk: .informational, hasSideEffect: false, isBlockedByEmergencyLock: true)
            case .serviceStart:
                return ActionProfile(name: "Codex 전용 보조 서비스 시작·연결", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "앱에 포함된 전용 보조 서비스를 실행하고 이 Mac에서 연결할까요? 서비스는 기존 Codex 로그인을 사용하며 파일·셸 도구를 허용하지 않습니다.")
            case .configure, .probe:
                return ActionProfile(name: action == .configure ? "Codex 로컬 연결 설정" : "Codex 고정 응답 테스트",
                    risk: .high, hasSideEffect: true, isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: action == .configure
                        ? "선택한 연결 파일로 이 Mac의 로컬 Codex 보조 프로그램에 연결할까요? iCloud에 저장하지 않으며 파일·명령 실행 권한은 부여하지 않습니다."
                        : "고정된 연결 테스트 질문 한 번을 Codex로 보낼까요? OpenAI 서비스에 전송되며 계정 사용 한도가 소모될 수 있습니다. 코드·파일·셸 작업은 요청하지 않습니다.")
            case .status:
                return ActionProfile(name: "Codex 로컬 로그인 상태 확인", risk: .informational, hasSideEffect: false, isBlockedByEmergencyLock: true)
            case .models, .workspaceRead, .usage:
                return ActionProfile(name: "Codex 대화 공간 조회", risk: .informational, hasSideEffect: false, isBlockedByEmergencyLock: true)
            case .chatImageRead:
                return ActionProfile(name: "선택한 이미지 미리보기", risk: .informational, hasSideEffect: false,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "첨부할 이미지를 선택해주세요.")
            case .steer:
                return ActionProfile(name: "진행 중인 Codex 작업에 메시지 전송", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "이 메시지를 진행 중인 Codex 작업에 반영할까요?")
            case .chat:
                return ActionProfile(name: "Codex 대화 전송", risk: .high, hasSideEffect: true, isBlockedByEmergencyLock: true,
                    alwaysRequiresConfirmation: true,
                    confirmationPrompt: "선택한 모델에 입력 내용과 이 대화의 최근 문맥을 전송할까요? OpenAI 서비스와 계정 사용 한도를 사용합니다. 파일·명령 실행 권한은 부여하지 않습니다.")
            case .workspaceImport:
                return ActionProfile(name: "ChatGPT 대화 내보내기 가져오기", risk: .medium, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "선택한 대화를 이 Mac의 JARVIS 대화 기록에 저장할까요?")
            case .workspaceEdit:
                return .mutable("Codex 대화 공간 저장", risk: .low)
            case .selectBackend, .configureRecovery:
                return .mutable("Codex 연결 방식 선택", risk: .low)
            case .workspaceDelete:
                return ActionProfile(name: "Codex 대화 기록 삭제", risk: .high, hasSideEffect: true, isBlockedByEmergencyLock: true,
                    alwaysRequiresConfirmation: true, confirmationPrompt: "선택한 프로젝트 또는 대화와 그 안의 로컬 기록을 삭제할까요? 이 작업은 되돌릴 수 없으며 OpenAI 측 기록 삭제를 의미하지 않습니다.")
            case .cancel, .disconnect, .serviceStop, .loginCancel:
                return ActionProfile(name: "Codex 로컬 요청 중지·연결 해제", risk: .low, hasSideEffect: true, isBlockedByEmergencyLock: false)
            }
        case .projectWorkflow(let workflow):
            if case .commit(let plan) = workflow {
                let risk: ActionRiskLevel = [.remove, .move].contains(plan.request.operation) ? .high : .medium
                return ActionProfile(name: "공유 프로젝트 명령 적용", risk: risk, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: plan.confirmation)
            }
            return ActionProfile(name: "공유 프로젝트 명령 준비", risk: .informational, hasSideEffect: false,
                isBlockedByEmergencyLock: true)
        case .sharedProject(let action):
            switch action {
            case .syncRead:
                return ActionProfile(name: "공유 데이터 동기화 검토", risk: .informational, hasSideEffect: false,
                    isBlockedByEmergencyLock: true)
            case .syncInitialize, .syncCapture, .syncExport, .syncImport:
                return ActionProfile(name: "공유 데이터 수동 동기화", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "표시된 저장소·변경 항목과 백업 범위를 확인하고 적용할까요? 실제 알람 예약은 변경하지 않습니다.")
            case .connect:
                return ActionProfile(name: "공유 프로젝트 접근 허용", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "선택한 폴더의 코드 파일을 읽고 승인 후 수정하도록 허용할까요?")
            case .save, .create, .createFolder:
                return ActionProfile(name: "공유 코드 파일 저장", risk: .medium, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "표시된 파일과 변경 내용을 확인하고 저장할까요? 다른 기기로 동기화될 수 있습니다.")
            case .move, .remove:
                return ActionProfile(name: "공유 프로젝트 이동·복구함 변경", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "표시한 원본·대상 경로와 포함 항목을 확인하고 이동할까요? 영구 삭제하지 않습니다.")
            case .browse, .read, .inspect:
                return ActionProfile(name: "공유 프로젝트 조회", risk: .informational, hasSideEffect: false,
                    isBlockedByEmergencyLock: true)
            case .unlock:
                return ActionProfile(name: "개발 공간 안전 잠금 해제", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: false, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "이 기기의 안전 잠금을 해제할까요?")
            case .disconnect, .cancel, .lock:
                return ActionProfile(name: "개발 공간 중지 또는 잠금", risk: .low, hasSideEffect: true,
                    isBlockedByEmergencyLock: false)
            }
        case .macWorkspace(let action):
            switch action {
            case .configure:
                return ActionProfile(name: "Mac 프로젝트 읽기 연결", risk: .high, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "Mac에 표시된 주소·인증서와 허용 프로젝트를 확인하고 읽기 전용 연결을 저장할까요?")
            case .disconnect:
                return ActionProfile(name: "Mac 연결 해제", risk: .low, hasSideEffect: true, isBlockedByEmergencyLock: false)
            case .cancel:
                return ActionProfile(name: "Mac 조회 중지", risk: .low, hasSideEffect: true, isBlockedByEmergencyLock: false)
            case .browse, .read, .search:
                return ActionProfile(name: "Mac 프로젝트 읽기 조회", risk: .informational, hasSideEffect: false,
                    isBlockedByEmergencyLock: true)
            }
        case .localData(let action):
            switch action {
            case .createAlarm: return .mutable("알람 생성", risk: .low)
            case .changeAlarm: return .mutable("알람 변경", risk: .medium)
            case .deleteAlarm: return .mutable("알람 삭제", risk: .medium)
            case .refreshNotifications, .reconcileAlarms:
                return .mutable("기존 예약 상태 갱신", risk: .low)
            case .deleteAllCalendarEvents, .restoreStorage:
                return ActionProfile(name: action == .restoreStorage ? "저장소 백업 복구" : "모든 일정 삭제",
                    risk: .high, hasSideEffect: true, isBlockedByEmergencyLock: true,
                    alwaysRequiresConfirmation: true,
                    confirmationPrompt: action == .restoreStorage ? "보존된 백업으로 목록을 복구할까요? 최근 변경은 없을 수 있습니다. 예약 상태는 별도로 확인해야 합니다." : "등록된 모든 일정을 삭제할까요? 되돌릴 수 없습니다.")
            }
        case .dismissConversation:
            return .informational("대화 종료")
        case .assistantCapabilities:
            return .informational("기능 안내")
        case .unknownCommand:
            return .informational("명령 재확인")
        case .generalConversation:
            return .informational("일반 대화")
        case .configureCloudAI:
            return ActionProfile(
                name: "외부 AI 연결 설정",
                risk: .high,
                hasSideEffect: true,
                isBlockedByEmergencyLock: true,
                alwaysRequiresConfirmation: true,
                confirmationPrompt: "OpenAI 연결 설정과 외부 전송 범위를 변경할까요?"
            )
        case .disableCloudAI:
            return ActionProfile(
                name: "외부 AI 사용 중지",
                risk: .low,
                hasSideEffect: true,
                isBlockedByEmergencyLock: false
            )
        case .weather:
            return .informational("날씨 조회")
        case .nearbyPlaces:
            return .informational("주변 장소 조회")
        case .configureImprovementCollection, .assistImprovementData, .runResponseEvaluation,
             .configureCommandPractice, .runCommandPractice, .applyCommandPractice:
            return ActionProfile(name: "개선 자료 수집 또는 외부 평가 승인", risk: .high,
                hasSideEffect: true, isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                confirmationPrompt: "자료 저장·외부 전송 범위와 API 비용을 확인하고 이 작업을 승인할까요?")
        case .reviewImprovementData:
            return .mutable("개선 자료 검토 저장", risk: .low)
        case .deleteImprovementData:
            return ActionProfile(name: "개선 자료 삭제", risk: .low, hasSideEffect: true, isBlockedByEmergencyLock: false)
        case .removeCommandPractice:
            return ActionProfile(name: "명령 연습 적용 철회·중지", risk: .low, hasSideEffect: true, isBlockedByEmergencyLock: false)
        case .calendar:
            return .informational("일정 조회")
        case .prepareOuting:
            return .informational("외출 준비 계획 조회")
        case .calendarWorkflow(let command):
            if case .commit(let change) = command {
                let date = change.start.formatted(date: .abbreviated, time: .shortened)
                return ActionProfile(name: "일정 변경", risk: .medium, hasSideEffect: true,
                    isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                    confirmationPrompt: "\(change.conflictIDs.isEmpty ? "" : "겹치는 일정이 \(Set(change.conflictIDs).count)개 있습니다. 겹쳐도 진행할지 확인해주세요. ")\(change.title) 일정을 \(change.deleting ? "삭제" : "저장")할까요? \(date), 시간대 \(change.timeZoneID).")
            }
            return .informational("일정 요청 확인")
        case .resolveMemoryConflict:
            return ActionProfile(name: "기억 충돌 해결", risk: .medium, hasSideEffect: true,
                isBlockedByEmergencyLock: true, alwaysRequiresConfirmation: true,
                confirmationPrompt: "선택한 기억을 남기고 충돌하는 기억을 삭제할까요?")
        case .time:
            return .informational("시간 조회")
        case .recommendRestaurants:
            return .informational("주변 음식점 조회")
        case .webSearch:
            return .informational("인터넷 검색")
        case .listAlarms:
            return .informational("알람 조회")
        case .listMemories:
            return .informational("장기 기억 조회")

        case .stopActiveAlarm:
            return ActionProfile(
                name: "울리는 알람 정지",
                risk: .low,
                hasSideEffect: true,
                isBlockedByEmergencyLock: false
            )
        case .pauseMedia:
            return ActionProfile(
                name: "미디어 재생 중지",
                risk: .low,
                hasSideEffect: true,
                isBlockedByEmergencyLock: false
            )
        case .setVolume, .adjustVolume:
            return ActionProfile(
                name: "기기 음량 변경",
                risk: .low,
                hasSideEffect: true,
                isBlockedByEmergencyLock: false
            )

        case .identifySong:
            return .external("노래 찾기 실행", risk: .low)
        case .playYouTube:
            return .external("YouTube 영상 실행", risk: .low)
        case .playYouTubePlaylist:
            return .external("YouTube 재생목록 실행", risk: .low)
        case .navigate:
            return .external("네이버 지도 길 안내", risk: .medium)
        case .call:
            return .external("전화 앱 연결", risk: .medium)
        case .openApp:
            return .external("외부 앱 실행", risk: .medium)

        case .setAlarm:
            return .mutable("알람 생성", risk: .low)
        case .updateAlarm:
            return .mutable("알람 수정", risk: .medium)
        case .cancelAlarm(let query):
            if case .all = query {
                return ActionProfile(
                    name: "모든 알람 삭제",
                    risk: .high,
                    hasSideEffect: true,
                    isBlockedByEmergencyLock: true,
                    alwaysRequiresConfirmation: true,
                    confirmationPrompt: "등록된 모든 알람을 삭제할까요? 이 작업은 되돌릴 수 없습니다."
                )
            }
            return .mutable("알람 삭제", risk: .medium)
        case .remember:
            return .mutable("장기 기억 저장", risk: .low)
        case .forgetMemory(let scope):
            if case .all = scope {
                return ActionProfile(
                    name: "모든 장기 기억 삭제",
                    risk: .high,
                    hasSideEffect: true,
                    isBlockedByEmergencyLock: true,
                    alwaysRequiresConfirmation: true,
                    confirmationPrompt: "저장된 모든 장기 기억을 삭제할까요? 이 작업은 되돌릴 수 없습니다."
                )
            }
            return .mutable("장기 기억 삭제", risk: .medium)
        case .fullBriefing:
            return .informational("현재 브리핑")
        }
    }
}

private struct ActionProfile: Sendable {
    let name: String
    let risk: ActionRiskLevel
    let hasSideEffect: Bool
    let isBlockedByEmergencyLock: Bool
    var alwaysRequiresConfirmation = false
    var confirmationPrompt: String?

    static func informational(_ name: String) -> ActionProfile {
        ActionProfile(
            name: name,
            risk: .informational,
            hasSideEffect: false,
            isBlockedByEmergencyLock: false
        )
    }

    static func external(_ name: String, risk: ActionRiskLevel) -> ActionProfile {
        ActionProfile(
            name: name,
            risk: risk,
            hasSideEffect: true,
            isBlockedByEmergencyLock: true
        )
    }

    static func mutable(_ name: String, risk: ActionRiskLevel) -> ActionProfile {
        ActionProfile(
            name: name,
            risk: risk,
            hasSideEffect: true,
            isBlockedByEmergencyLock: true
        )
    }
}
