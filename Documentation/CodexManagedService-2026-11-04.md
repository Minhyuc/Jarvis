# Codex 로컬 서비스 1~3단계 구현·검증

이 문서는 1~3단계 완료 당시의 기록입니다. 후속 로그인·복구·진단 구현은 [4~6단계 검증](CodexServiceStages4-6-2026-11-04.md)을 참조하세요.

## 범위

- 앱 번들에 `JARVISCodexService.xpc`와 기존 두 Python 어댑터 포함.
- 연결 설정에서 시작·자동 연결 승인, 진행 표시, 중지·연결 해제 제공.
- 앱 전용 XPC를 통해 descriptor를 메모리로 수신. 수동 JSON 파일 선택 불필요.
- 기존 CLI와 App Server 선택·수동 연결은 유지. 자동 백엔드 전환·질문 재전송 없음.

사용 방법: 최신 Mac 앱 → 개발 공간 → 멀티 에이전트 → Codex 연결 설정 → 연결 방식 선택 → **보조 서비스 시작·자동 연결** 승인. 로그인 확인 후 기존 대화 창에서 입력한다. 시작 자체는 모델 질문을 만들지 않는다.

## 권한과 수명주기

본체 sandbox는 유지한다. 내장 서비스는 설치된 개인 Codex 실행 파일과 기존 로그인 저장소에 접근하는 비샌드박스 프로세스다. root 권한, LaunchAgent, 로그인 항목은 설치하지 않는다. XPC 메서드는 입력 없는 start/stop으로 제한한다. 양쪽은 정확한 현재 번들 코드 해시로 peer 서명 조건을 고정하고, 서명 조건 구문도 Security API로 검증한 뒤 XPC에 적용한다.

서비스 시작·페어링은 `AssistantIntent.codexLocal(.serviceStart)`의 고위험 개별 승인과 잠금 검사를 거친다. 중지 `.serviceStop`은 잠금 중에도 가능하다. 이 두 동작은 HTTP 및 모델 선택 기능으로 노출하지 않는다. 토큰·승인·로그인 정보를 저장하거나 공유하지 않는다.

관리 모드 Python은 descriptor를 디스크에 쓰지 않는다. 앱 → private XPC → 서비스 → private pipe → Python의 소유 관계를 유지한다. 연결 해제·앱 종료 시 stdin EOF로 소유한 CLI/App Server와 서버를 정리한다. 자식 종료 시 XPC 연결도 무효화한다. 시작 시간 초과·취소·늦은 응답은 새 연결 상태로 적용하지 않는다. UI의 중지 문구는 요청·연결 해제를 나타내며 종료 확인 전 완료를 단정하지 않는다.

## 검증 결과

- Swift 테스트 287개 통과: 서비스 시작 승인·잠금·제안 차단, 잠금 중 중지, 일반 HTTP로 서비스 제어 불가 포함.
- Python 테스트 44개 통과: 관리 모드 메모리 bootstrap, 기존 파일 미게시, EOF로 양쪽 소유 백엔드 중지 포함.
- 실제 서명된 임시 sandbox 앱: XPC bootstrap, 인증 없는 HTTP 요청 거부, 중지 후 포트 종료, 새 세션 재시작, 시작 중 취소 통과. 계정 조회·모델 요청 없음.
- Mac 대화 UI·저장·입력 회귀 검사 통과.
- Mac 앱 ad-hoc 서명 빌드 및 unsigned iOS Simulator 빌드 통과.

재현 도구: `Tools/CodexLocal/check_service.py`, `test_managed_service.py`, `check_mac_ui.py`.

## 남은 범위

Python 3·Codex 설치 및 전용 App Server 로그인은 기존 의존성이다. 다른 Mac의 런타임 설치·배포, 앱 내 로그인 UI, 로그인 시 자동 시작, 장기 장애 복구·업데이트 마이그레이션은 이번 단계에 포함하지 않는다. 코드·파일·셸 실행 권한도 추가하지 않는다. Developer ID 배포·공증은 별도 검증이 필요하다. 개인 Debug 빌드는 ad-hoc 서명으로 검증했으며 이때 Xcode는 hardened runtime을 비활성화한다.

참고: [Apple XPC 서비스 구조·앱 전용 서비스](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html), [XPC peer 서명 조건](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)).
