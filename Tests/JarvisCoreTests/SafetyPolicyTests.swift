import XCTest
@testable import JarvisCore

final class LocalDataSafetyTests: XCTestCase {
    func testMaintenanceCannotBeApprovedThroughModelOrEmergencyLock() {
        let policy = SafetyPolicyEngine()
        for action in [LocalDataAction.deleteAllCalendarEvents, .restoreStorage] {
            let intent = AssistantIntent.localData(action)
            guard case .requireConfirmation = policy.evaluate(intent, context: .init()),
                  case .allow = policy.evaluate(intent, context: .init(wasExplicitlyConfirmed: true)),
                  case .block = policy.evaluate(intent, context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)),
                  case .block = policy.evaluate(intent, context: .init(origin: .proactiveSuggestion, wasExplicitlyConfirmed: true)) else {
                XCTFail("Bulk/recovery safety boundary missing"); continue
            }
        }
        guard case .requireConfirmation = policy.evaluate(.localData(.changeAlarm), context: .init(origin: .modelProposed)),
              case .allow = policy.evaluate(.localData(.refreshNotifications), context: .init(origin: .backgroundAutomation)),
              case .block = policy.evaluate(.localData(.refreshNotifications), context: .init(origin: .backgroundAutomation, externalActionsLocked: true)) else {
            return XCTFail("Maintenance scope missing")
        }
    }
}

final class SafetyPolicyTests: XCTestCase {
    private let policy = SafetyPolicyEngine()

    func testCloudConfigurationRequiresConfirmationAndCannotBypassLock() {
        guard case .requireConfirmation = policy.evaluate(.configureCloudAI, context: .init()) else {
            return XCTFail("External data settings require explicit confirmation")
        }
        guard case .allow = policy.evaluate(.configureCloudAI, context: .init(wasExplicitlyConfirmed: true)) else {
            return XCTFail("Confirmed direct setting should be allowed")
        }
        guard case .block = policy.evaluate(.configureCloudAI, context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)) else {
            return XCTFail("Lock must take precedence")
        }
        guard case .allow = policy.evaluate(.disableCloudAI, context: .init(externalActionsLocked: true)) else {
            return XCTFail("Stopping external inference must remain available")
        }
        XCTAssertFalse(CapabilityRegistry.standardDescriptors.contains { $0.id.rawValue.contains("Cloud") })
    }

    func testReadOnlyRequestRemainsAvailableDuringEmergencyLock() {
        XCTAssertEqual(
            policy.evaluate(
                .weather(.todaySummary),
                context: SafetyEvaluationContext(externalActionsLocked: true)
            ),
            .allow(risk: .informational, actionName: "날씨 조회")
        )
    }

    func testExternalActionIsBlockedDuringEmergencyLock() {
        let decision = policy.evaluate(
            .call(recipient: "홍길동", speakerRequested: false),
            context: SafetyEvaluationContext(externalActionsLocked: true)
        )
        guard case .block(let risk, let actionName, _) = decision else {
            return XCTFail("전화 실행은 안전 잠금 상태에서 차단되어야 합니다.")
        }
        XCTAssertEqual(risk, .medium)
        XCTAssertEqual(actionName, "전화 앱 연결")
    }

    func testEmergencyStopActionsStayAvailableDuringLock() {
        XCTAssertEqual(
            policy.evaluate(
                .stopActiveAlarm,
                context: SafetyEvaluationContext(externalActionsLocked: true)
            ),
            .allow(risk: .low, actionName: "울리는 알람 정지")
        )
        XCTAssertEqual(
            policy.evaluate(
                .pauseMedia,
                context: SafetyEvaluationContext(externalActionsLocked: true)
            ),
            .allow(risk: .low, actionName: "미디어 재생 중지")
        )
    }

    func testBackgroundAlarmStopAppIntentIsAllowedEvenDuringEmergencyLock() {
        XCTAssertEqual(
            policy.evaluate(
                .stopActiveAlarm,
                context: SafetyEvaluationContext(
                    origin: .backgroundAutomation,
                    externalActionsLocked: true
                )
            ),
            .allow(risk: .low, actionName: "울리는 알람 정지")
        )
    }

    func testBulkDeletionRequiresExplicitConfirmation() {
        let intent = AssistantIntent.forgetMemory(.all)
        XCTAssertEqual(
            policy.evaluate(intent, context: SafetyEvaluationContext()),
            .requireConfirmation(
                risk: .high,
                actionName: "모든 장기 기억 삭제",
                prompt: "저장된 모든 장기 기억을 삭제할까요? 이 작업은 되돌릴 수 없습니다."
            )
        )
        XCTAssertEqual(
            policy.evaluate(
                intent,
                context: SafetyEvaluationContext(wasExplicitlyConfirmed: true)
            ),
            .allow(risk: .high, actionName: "모든 장기 기억 삭제")
        )
    }

    func testModelProposedMediumRiskActionRequiresApproval() {
        let decision = policy.evaluate(
            .openApp(name: "은행"),
            context: SafetyEvaluationContext(origin: .modelProposed)
        )
        guard case .requireConfirmation(let risk, let actionName, _) = decision else {
            return XCTFail("모델이 제안한 외부 앱 실행은 승인을 요구해야 합니다.")
        }
        XCTAssertEqual(risk, .medium)
        XCTAssertEqual(actionName, "외부 앱 실행")
    }

    func testBackgroundMediumRiskActionRequiresApproval() {
        let decision = policy.evaluate(
            .navigate(destination: "강남역", mode: nil),
            context: SafetyEvaluationContext(origin: .backgroundAutomation)
        )
        guard case .requireConfirmation(let risk, let actionName, _) = decision else {
            return XCTFail("백그라운드 길 안내 실행은 승인을 요구해야 합니다.")
        }
        XCTAssertEqual(risk, .medium)
        XCTAssertEqual(actionName, "네이버 지도 길 안내")
    }

    func testBackgroundReadOnlySuggestionCanRunAutomatically() {
        XCTAssertEqual(
            policy.evaluate(
                .calendar(.nextEvent),
                context: SafetyEvaluationContext(origin: .backgroundAutomation)
            ),
            .allow(risk: .informational, actionName: "일정 조회")
        )
    }
}
