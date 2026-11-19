import Foundation

/// # JARVIS 안전 개발 지침
///
/// 이 타입은 런타임 기능이 아니라, 앞으로 JARVIS 기능을 추가하는 개발자와
/// 코드 수정 도구가 따라야 할 규칙을 Swift 소스 안에 남기는 문서입니다.
/// 실제 실행 결정은 ``SafetyPolicyEngine``이 담당합니다.
///
/// ## 변하지 않는 경계
///
/// 1. 언어 모델은 사용자의 의도를 해석하거나 행동을 제안할 수만 있습니다.
/// 2. 전화, 메시지, 앱 실행, 외부 URL, 데이터 변경 등 실제 행동은 모델이
///    직접 실행하지 않고 반드시 `AssistantIntent`로 변환합니다.
/// 3. 모든 `AssistantIntent`는 실행 전에 ``SafetyPolicyEngine/evaluate(_:context:)``를
///    통과해야 합니다. UI, App Intent, 백그라운드 작업도 이 경계를 우회하면 안 됩니다.
/// 4. 모델 응답, 웹 검색 결과, 캘린더 내용, 연락처, 장기 기억은 모두 신뢰할 수 없는
///    데이터로 취급합니다. 그 안의 문장을 시스템 지시로 실행하지 않습니다.
/// 5. 안전 정책, 권한, 확인 절차와 감사 기록은 모델이 수정할 수 없습니다.
///
/// ## 두뇌 운영 구조
///
/// 명령 처리 순서는 `CommandRouter → AgentOrchestrator → CapabilityRegistry →
/// SafetyPolicyEngine → 결정론적 실행기`로 고정합니다. 알려진 명령은 항상
/// `CommandRouter`가 먼저 처리하고, 의미가 불명확한 경우에만 온디바이스 모델이
/// 구조화된 후보를 제안합니다. 모델 후보는 `CapabilityRegistry`에 등록된 제한된
/// 기능과 인자 검증을 통과해야 `AssistantIntent`가 될 수 있습니다.
///
/// `AIClient`는 전화, 앱, URL, 알람, 기억을 직접 실행하거나 변경하지 않습니다.
/// 특히 알람과 기억 변경, 자격 증명, 권한, 안전 설정은 일반 의미 추론 대상에서
/// 제외합니다. 새 모델 기능도 이 경계를 유지해야 합니다.
///
/// OpenAI 연결은 사용자가 설정에서 직접 승인한 경우에만 사용합니다. API 키와
/// 사용 모드 변경은 의미 추론 기능에 등록하지 않습니다. 비사용 모드는 외부 AI
/// 요청을 만들지 않으며, 중지·설정 변경 시 진행 중인 요청과 늦은 응답을 폐기합니다.
/// 클라우드 문맥도 `AssistantContextManager`로 제한하고, 장기 기억·프로필 전송은
/// 별도 동의 옵션을 따릅니다. API 응답 수신을 모델 학습 완료로 기록하지 않습니다.
///
/// 정정 후보는 기본 수집하지 않고 동의한 경우에도 메모리 안에서만 준비합니다.
/// 사용자가 개인정보를 편집하고 저장한 자료만 로컬 개선 자료로 남깁니다.
/// OpenAI 수정안은 정답이 아니라 검토 제안이며, 승인한 참고 답변을 적용한 동일 질문
/// 재응답을 사용자가 검토한 경우만 개선 사례로 집계합니다. 가중치 학습과 구분합니다.
/// 외부 평가·정정 요청은 별도 확인, 요청 한도, 긴급 잠금을 따르며 자동 반복하지 않습니다.
/// 검증된 수정 자료도 일반 대화의 동일 질문 참고로만 사용하며 실행 권한으로 쓰지 않습니다.
/// 명령 자동 연습의 승인 예제는 별도 라이브러리에서 관리합니다. 고정 합성 기준과 교사
/// 해석이 일치하고 사용자가 문항별로 승인한 경우만 추가하며, 기존 라우터를 덮어쓰지
/// 않습니다. 동일 문장 조회 결과도 의미 모델의 제안으로 취급하여 CapabilityRegistry와
/// SafetyPolicyEngine을 다시 통과합니다. 문맥이 필요한 대명사·취소·부정·모호한 대상은
/// 독립 명령 예제로 고정하지 않습니다. 학습 적용 승인은 실제 실행 승인이 아닙니다.
/// 대기 결과 30개에는 실패·중단도 포함하며, 적용·폐기 전에는 자동 삭제하지 않습니다.
/// 개인용 명령 분류 검토 범위와 입력 권리를 별도 확인하며 API 생성 자료로 가중치
/// 학습·증류·경쟁 모델 개발·재배포를 자동 수행하지 않습니다. 목적·배포 범위 변경 시
/// 최신 약관과 제3자 권리를 재검토합니다. 코드가 법적 무위험을 보장하지 않습니다.
/// 예제 적용·버전 복구 전 기존 라우터 회귀와 독립 보관 문장의 로컬 모델을 변경 전후
/// 비교합니다. 새 실패·안전 실패는 사용자 승인으로 우회할 수 없습니다. 고정 평가
/// 문장은 생성 프롬프트나 승인 예제에 넣지 않으며 반복 점검 결과를 일반화 성공으로
/// 기록하지 않습니다. 버전 복구는 예제 라이브러리만 대상으로 하고 권한·안전 정책은
/// 복구하지 않습니다. 전체 삭제 시 복구본도 지워 삭제 자료가 부활하지 않게 합니다.
/// 장소 검색 결과의 ID·주소·좌표는 하나의 단기 작업에 묶고, 모델이 좌표나 영업 여부를
/// 생성하지 않습니다. 만료·취소·주제 변경 때 후보를 폐기하고 지도 전달을 완료로 말하지 않습니다.
///
/// 대화 문맥은 `AssistantContextManager`가 최근 대화, 제한된 요약, 관련 장기 기억만
/// 선택해 제공합니다. 전체 기억 저장소나 외부 콘텐츠 원문을 무제한으로 모델에
/// 전달하지 않습니다. 명령 이해를 변경한 뒤에는 `EvaluationRunner`의 고정 사례로
/// 기존 명령과 의미 추론의 회귀 여부를 확인합니다.
///
/// 후속 질문과 확인 대화는 `DialogueStateManager`가 하나의 활성 작업으로 관리합니다.
/// 새 작업이 시작되면 이전 작업을 교체하고, 관계없는 새 명령·만료·반복 실패가 발생하면
/// 보류 문맥을 폐기합니다. 오래된 “네”나 다른 대화의 대상을 재사용하지 않습니다.
///
/// 도구는 단순한 `Bool` 대신 `ToolExecutionResult`를 반환합니다. JARVIS 내부에서
/// 검증된 완료와 외부 앱에 요청을 넘긴 상태를 구분하고, 권한 부족·추가 확인·실패·
/// 결과 확인 불가를 사용자에게 사실대로 안내합니다. 동일 작업 중복 실행과 무기한
/// 대기를 막기 위해 `ToolExecutionCoordinator`의 키와 제한 시간을 사용합니다.
/// 시간 초과는 미실행의 증거가 아니므로 자동 재실행하지 않습니다. 취소된 작업은
/// 도구 진입 전에 거절하고 늦은 성공을 UI 완료로 반영하지 않습니다. 음성 안내 뒤
/// 실행도 같은 처리 Task에 묶어 중지·새 입력·오디오 인터럽트가 취소할 수 있게 합니다.
/// 음성 완료 콜백은 상호작용 식별자로 제한하고, 취소 시 대기 continuation을 해제합니다.
/// 진단에는 숫자·지연만 기록하며 발화 원문·오디오·출력 기기 이름은 넣지 않습니다.
///
/// ## 위험도 선택
///
/// - `informational`: 읽기 전용 조회 또는 대화. 외부 상태를 바꾸지 않습니다.
/// - `low`: 쉽게 중지하거나 되돌릴 수 있는 제한된 기기 동작입니다.
/// - `medium`: 외부 앱 전환, 연락, 기존 데이터 변경처럼 사용자에게 눈에 띄는
///   결과가 생기는 동작입니다.
/// - `high`: 대량 삭제, 결제, 메시지 전송, 보안·개인정보 변경처럼 피해가 크거나
///   되돌리기 어려운 동작입니다. 명시적인 사용자 재확인이 필수입니다.
///
/// 위험도가 애매하면 더 높은 등급을 선택합니다. 기능의 편리함 때문에 위험도를
/// 낮추지 않습니다.
///
/// ## 새 명령을 추가할 때의 필수 순서
///
/// 1. `AssistantIntent`에 의미가 명확한 case를 추가합니다.
/// 2. `CommandRouter`가 자연어를 해당 intent로만 변환하게 합니다.
/// 3. 모델이 선택할 수 있어야 한다면 `CapabilityRegistry`에 제한된 스키마와 인자
///    검증을 추가합니다. `AIClient`에 실행 코드를 추가하지 않습니다.
/// 4. `SafetyPolicyEngine.actionProfile(for:)`에 위험도, 부작용 여부, 안전 잠금 시
///    차단 여부, 재확인 필요 여부를 등록합니다.
/// 5. `AssistantViewModel`의 중앙 `authorize` 경로를 거친 뒤에만 실행합니다.
/// 6. 허용, 차단, 재확인, 긴급 안전 잠금 상태를 단위 테스트하고 명령 해석은
///    `EvaluationRunner` 사례에 추가합니다.
/// 7. 후속 질문이 필요하면 `DialogueStateManager`의 제한된 상태로 표현합니다.
/// 8. 도구 실행은 `ToolExecutionResult`로 검증 완료와 외부 전달을 구분합니다.
/// 9. 실행 기록에는 명령 원문, 연락처 이름, 전화번호, 목적지, 기억 내용, API 키를
///    남기지 않고 일반적인 작업 이름과 정책 결과만 기록합니다.
///
/// `AssistantIntent`와 안전 정책의 switch는 exhaustive하게 유지합니다. 새 case를
/// 추가했을 때 컴파일 오류가 발생하도록 `default` 분기를 만들지 마세요. 이 오류가
/// 안전 등급 누락을 방지하는 장치입니다.
///
/// ## 확인과 취소
///
/// 확인은 실행할 동작과 영향을 짧고 구체적으로 말한 뒤 받아야 합니다. 이전 대화의
/// 모호한 긍정이나 모델이 생성한 문장을 승인으로 사용하지 않습니다. 거절하거나
/// 다른 명령을 말하면 보류된 승인은 즉시 폐기합니다. 안전 잠금은 승인보다 우선합니다.
///
/// ## 비상 동작
///
/// 긴급 안전 잠금 중에도 사용자의 피해를 줄이는 `현재 알람 정지`, `미디어 정지`,
/// `음량 조절` 같은 동작은 사용할 수 있습니다. 새 예외는 실제로 위험을 줄이는
/// 동작인지 검토하고 테스트를 추가한 경우에만 허용합니다.
///
/// ## 향후 자율성 확장
///
/// 기존 제안 설정은 `proactiveSuggestion` 출처로 중앙 정책을 통과합니다.
/// 자동 모드에서 정보 안내·낮은 위험만 자동 실행하고 보통 위험은 확인하며,
/// 높은 위험 제안은 확인 여부와 무관하게 차단합니다. 직접 사용자 명령의 기존
/// 고위험 확인 정책과 섞지 않습니다. 기억 저장에는 별도의 명시 동의가 필요합니다.
/// 제안에 유효기간을 두며 만료·설정 변경·취소 시 실행하지 않습니다.
/// 외출 준비는 최대 3단계·25초의 제한된 조회와 하나의 알림 제안으로 제한합니다.
/// 날씨 조언은 구조화된 예보 수치로 만들고 전날 자료가 없으면 급격한 하락을
/// 주장하지 않습니다. 일정 변경은 버전·충돌 확인을 거쳐 개별 승인하고 모델에
/// 노출하지 않습니다. 기억은 충돌 해결 전 제외하며 수정·삭제 시 문맥과 진행 중
/// 기억 답변을 무효화합니다. 삭제 표식은 해시·시각만 저장하고 감사 원문은 남기지 않습니다.
///
/// 예약 실행이나 모델 제안 실행은 ``SafetyExecutionOrigin/modelProposed`` 또는
/// ``SafetyExecutionOrigin/backgroundAutomation``으로 평가합니다. 중간·높은 위험의
/// 부작용은 사용자가 사전에 범위와 기간을 명확하게 위임하지 않았다면 실행 직전
/// 확인을 요구합니다. 실패했거나 실행 결과를 확인할 수 없으면 성공했다고 말하지 않습니다.
public enum SafetyDevelopmentGuide {}

// Quota lookup is a UI-only informational codexLocal(.usage) intent. The helper
// may call only account/rateLimits/read with empty params and return bounded
// percentages/windows/timestamps, never account identity or credentials. Unknown
// usage remains unknown; do not infer balances or grant reset/spending actions.
// The provider menu currently enables Codex only. A disabled future-provider row
// must not start that provider, read its auth state or transmit conversation data.

// Codex source editing uses an isolated, UI-only codeDraft schema, not a tool
// permission expansion for chat. A selected root stays security-scoped only
// during the editor session. Send only explicitly selected UTF-8 code ranges
// (8 files, 96KiB total) and a bounded relative file list via ContextManager;
// full original files stay local for revisions and backup. Each proposal is
// untrusted JSON, never shell, native fileChange approval or executable code.
// Code snapshots use isolated ephemeral native threads which are unsubscribed
// after each proposal, so source cannot contaminate ordinary conversations.
// Main-chat requests offer a relative inventory before sharing source. Treat
// model-selected read ranges as data; validate paths and ask exact inline sharing
// approval before deterministic reads/transmission. Native tools stay disabled.
// Limit a code task to twelve model calls/ten minutes. Reject, stop, new input, thread,
// model or session change and emergency lock revoke pending approvals. Coding
// transcript entries cannot enter ordinary chat context; snapshots stay ephemeral.
// Swift validates exact unique old text, non-overlap, root session, expiry,
// protected paths and current original content before a per-file approval.
// Component-wise no-follow FD access rejects traversal, symlinks and hardlinks.
// Safety/auth/executor/Codex/build-policy source and AGENTS remain read-only.
// Save a private local backup before atomic file replacement. Restore requires
// a new approval and exact post-apply content; never overwrite later user work.
// Stop/lock/close discard late proposals and cancel before commit. A local
// verified source write is not a verified build, test, deployment or running
// app update. Never execute model-proposed commands or auto-run changed source.

// The embedded Mac XPC service has only start/stop methods. It is deliberately
// outside the UI app sandbox to launch the installed personal Codex runtime;
// the main app sandbox stays enabled. Pin both XPC peers to their exact bundled
// code hashes. No arbitrary executable/path, RPC, file or shell input is allowed.
// Start/pair needs fresh explicit serviceStart consent; stop remains available
// under lock. Pairing material uses private pipes/XPC and memory only, never
// iCloud, preferences or a discovery file. EOF/invalidation stops owned children.
// Do not register login items or silently install/download a runtime. Python 3
// and the existing Codex-managed login remain explicit local dependencies.
// Browser login is an explicit high-risk loginStart action, scoped to the
// dedicated App Server home. Only Codex-owned ChatGPT PKCE URLs with an exact
// official origin and loopback callback may open. No caller API key, auth token,
// login ID, generic RPC or external callback is accepted. loginPoll returns only
// bounded states and verifies account/read after a matching completion event.
// Waiting expires after three minutes. Cancel/lock/disconnect closes that flow;
// cancellation does not mean logout. Logout has its own fresh approval and
// verifies an empty dedicated account; never log out the original CLI store.
// An explicit service start may authorize two transport-only repairs within ten
// minutes, pinned to the backend and exact installed build and monotonic time.
// Never persist or renew that lease automatically. Stop, lock, mode changes and
// leaving the workspace revoke it. No generated turn is automatically replayed.
// Keep only backend/recovery preferences across updates, never approvals,
// pairing tokens or OAuth URLs. Check helper code identity and native executable
// revision; changed runtimes require a fresh status check, not unsafe fallback.
// Diagnostics contain fixed versions, bounded counts, booleans and latency only.

// A-stage shared data sync is a separate device-local SQLite replica and an
// explicit manual capture of the existing native stores, not a scheduler.
// Immutable exchange packages carry no OS IDs, approvals or credentials.
// Import must never execute instructions or directly mutate native alarms or
// notifications. Keep staged data marked pending until the C-stage per-version
// policy/permission/scheduler reconciliation is implemented. All sync writes
// require a single-use, expiring, root/DB-revision-bound explicit confirmation.
// Generic file tools cannot mutate alarm/calendar/system trees or ancestors.
// Checksums are not authenticity; do not trust a shared folder as authorization.
// Local sync snapshots are read-only and lock/cancellation-sensitive. They must
// remain browsable without document-provider access and must never be described
// as remote acknowledgements or verified OS reservations. Export only new IDs,
// preflight combined limits, and bound every immutable chunk by count and bytes.
// UI feature cross-links must select a sibling in the canonical workspace host,
// not recursively push copies of feature screens. Keep record editors/details
// as children. Navigation grants no execution consent; leaving a sync/review
// screen must preserve cancellation and discard unapproved plans/late results.
// codexLocal is UI-only and must never enter CapabilityRegistry or model routing.
// Connect, every fixed probe, and each text-chat send require explicit confirmation.
// For text the user composed in the dedicated Codex editor, their Return or
// send-button gesture is the action-specific confirmation for that exact
// message/model/thread/session. The user opted out of repeated quota dialogs.
// Build and authorize that snapshot synchronously; never persist consent,
// reuse it for another input, or accept programmatic/background/model sends.
// Shift+Return only inserts a newline; Return during IME composition only
// commits composition. Emergency lock, duplicate guards and cancellation stay.
// Text chat uses a dedicated validated schema: selected model ID, allowlisted reasoning effort, current text,
// and <=6 successful pairs selected by AssistantContextManager from that thread.
// Never send other projects, failed/pending turns, memories, project file content,
// arbitrary JSON-RPC, runtime instructions, file or shell APIs across the bridge.
// Local chat/project CRUD is also codexLocal intent policy gated. Deletion needs
// action-specific approval. Persist only chat records (private atomic files with
// revision checks), never connection credentials or approvals. Replay bounded
// context in isolated exec; never resume arbitrary desktop session IDs. stdin
// carries chat text, not argv/logs. Recent model-cache metadata is not proof of
// current model entitlement. Preserve the app sandbox; credentials stay in Codex. Isolated
// General-chat creation is a workspaceEdit mutation, not transmission consent.
// Model/effort can be selected before a thread exists. Reasoning effort changes
// only the validated CLI config value, never tool access or approval policy.
// AssistantContextManager context must stay empty for the fixed connection probe.
// "Local" means local transport, not offline inference. Disclose quota use,
// reject API-key fallback, stop on lock/exit and never retry uncertain probes.
// App Server is an explicit parallel text backend, not an automatic fallback.
// Image input starts with an explicit native file selection. Send only the
// bounded re-encoded pixels with the user's chat submission. The private helper
// owns the temporary JPEG path and must clean it up and release the ephemeral
// thread. Never accept caller file paths, persist image bytes, or replay them.
// A user-entered steer is scoped to the active App Server request and native
// turn. It accepts bounded text only, never permission overrides or files.
// Keep CLI's original login/config intact. The private App Server CODEX_HOME
// uses a separate Codex-managed login; never copy/read credential files or
// import config, AGENTS, hooks, skills or project roots from another store.
// Only the adapter's fixed JSON-RPC allowlist is reachable. Tools and approval
// server requests are denied and terminate that dedicated process. Read-only
// sandbox plus disabled tools remain mandatory for model turns. Native threads are ephemeral,
// helper-owned aliases of JARVIS conversation IDs, bounded by turns/bytes/count.
// A restart, cancellation or unacknowledged local history reconstructs only
// managed recent context on the NEXT explicit send, never replays a lost turn.
// Validate backend identity and protocol version before accepting responses.
// Text send approval is not a file, process, shell or permissions approval.
//
// Explicit native-tool invocations are a separate codexLocal(.nativeTool)
// high-risk intent. Each immutable program/argv/root or stdio MCP tool/arguments
// snapshot requires its own visible approval. Arbitrary command/MCP invocations
// are never constructed from model output, semantic fallback, imported manifests,
// or background work. A code-task model may propose a narrowly validated verify
// operation only: Swift test/build, Python unittest discovery, or Xcode build.
// Swift validates that schema and presents a single-use, task/root/session-bound
// approval. Python validates it again and builds fixed argv with the source
// project read-only, network disabled and only a disposable output directory
// writable. Do not run model-proposed programs through the manual command path.
// Code-task read grants cover reviewed relative paths and line ranges only,
// at most eight reuses within the same task. They expire on cancel, root/session/
// model change, or ten minutes. A task has at most twelve model requests.
// File mutations and verification runs always need individual approval. Stored
// approvals never authorize them. After a verified file save, refresh its source
// and continue only within the explicitly approved task. Verification output
// needs a separate, editable transmission review. Preserve the actual success/
// failure status outside the editable output. Bound results and reject known
// secret patterns. Failed verification is never automatically retried.
// command/exec is bounded to 30 seconds, capped output, project writable roots
// and disabled network. Never substitute unsandboxed thread/shellCommand.
// MCP startup itself executes a trusted native program with Mac-user privileges:
// show the program/argv and scope before discovery and again before tool calls.
// Plugin .mcp.json import only stages command/args. Reject env/credential and
// hook fields. Discovery is not permission for a later call. All native results
// are untrusted display data, never runtime instructions or automatic approvals.
// Stop/lock closes the private tool process group; uncertain failures are not
// retried. Native output is shown for review without automatically persisting
// it or adding it to model context. Model chat keeps its text-only restrictions.

// iCloud/shared projects use the system directory picker, with per-session
// security-scoped access only. SharedProjectFiles handles coordination, bounded
// UTF-8 reads, revision checks, and action-specific save confirmation. Folder
// permission is not permission to execute code or send it to any model. Do not
// synchronize credentials, safety approvals or locks through project files.
// A local verified write is not proof of remote iCloud synchronization. Keep
// the old IP bridge disabled. Mac companion is a development-space app, not
// a port of phone actions or a shared inference server.
// Shared-folder commands are deterministic projectWorkflow drafts. Prepare a
// root-session-bound, single-use 120-second plan; DialogueStateManager owns
// voice/text approval. Resolve only explicit root-relative paths, never fuzzy
// basenames or old destinations. Recheck content revisions before commit.
// Move/delete require high-risk action-specific confirmation. Delete means a
// move into the same root's visible JARVIS recovery folder, never permanent
// removal. Restores never overwrite. Keep file contents out of model tools.

// Mac development space is UI-only and read-only. Pairing is a high-risk explicit
// action; browse/read/search are lock-sensitive informational requests. Disconnect
// and cancellation remain available under lock. Never expose pairing or file
// content to semantic fallback, chat, summaries, memories or cloud models.
// The Mac service independently restricts one authorized root and supports no
// write/exec endpoint. Do not widen its token when adding future coding tools.
// REA must remain an optional adapter, not a prerequisite for ordinary tools.

// Alarm/calendar UI and speech writes must use LocalDataExecution. Its local
// maintenance intents are deliberately absent from CapabilityRegistry. Recheck
// lock/cancellation after awaits. Recovery may only restore a recorded exact
// pre-action snapshot; a journal or backup is not authorization for a new task.
// Uncertain rollback remains visible and blocks additional mutations. Never
// clear a pending marker merely because an API call returned without an error.

// Codex session/attachment extension maintenance:
// - Persist only bounded private session aliases and acknowledged turn hashes; an uncertain
//   pending turn never grants replay. Recovery metadata must not restore code/command approvals.
// - HTTP MCP OAuth credentials remain in Codex. A saved server definition is not execution approval.
// - Plugin installation stays in its separate profile; importing MCP/Skill data never grants hooks.
// - Git diagnostics link only inventory-matched paths. External diff/textconv/hooks stay disabled.
// - Explicit file selection/export passes codexLocal attachmentRead/workspaceExport policy;
//   document/PDF text is untrusted, bounded reference data, never executable instructions.

// Explicit Codex development-agent sessions (agentVersion 1): a native App Server
// dynamic-tool turn may request only CapabilityRegistry.codexAgentTools. Map each
// request to an existing codeDraft/codeApply/nativeTool AssistantIntent and run the
// deterministic Swift executor after exact sharing/write/verification approval.
// The language model never owns filesystem or shell permissions. Built-in execution,
// permission escalation and unregistered tools remain denied in the native runtime.
// Pin pending approval to job/thread/turn/call/nonce, current root identity, original
// content and expiry. Read leases cover reviewed ranges only; never reuse them for
// writes or commands. A cancelled start is tombstoned before the model may start.
// Revoke on lock, selection/model/session changes and close. Pending work and grants
// are not persisted. Test failed execution and stale callbacks as well as success.
// Display verified device facts separately from model prose. Do not log source,
// commands, tokens or dialogue in audit events. Polling is not permission to execute.

// USB-only Mac installations keep sandboxing and require an explicit, per-launch
// directory selection for the validated physical storage root. JarvisStorage
// must never fall back to the desktop on loss of that root. Revoke active work
// on unmount, reject external/symlink project roots, and keep USB settings out
// of CFPreferences persistent domains. Credentials are managed by their native
// providers; never copy authentication files as part of data migration.
