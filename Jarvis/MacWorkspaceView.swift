// Mac 개발 공간 보류. 기존 JARVIS 화면만 사용합니다.
#if false
import SwiftUI

struct MacWorkspaceView: View {
    @ObservedObject private var store = MacWorkspaceStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var pairingText = ""
    @State private var query = ""
    @State private var confirmingPairing = false
    @State private var confirmingDisconnect = false
    @State private var pairingCandidate: MacWorkspacePairing?
    @State private var invalidPairing = false

    var body: some View {
        List {
            Section {
                Label("읽기 전용 · REA 없이 사용", systemImage: "lock.doc")
                Text("Mac에서 직접 허용한 프로젝트만 조회합니다. 파일 수정·프로그램 실행·자동 AI 분석은 아직 지원하지 않습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Mac 연결") {
                if let pairing = store.pairing {
                    LabeledContent("프로젝트", value: pairing.projectName)
                    LabeledContent("로컬 주소", value: "\(pairing.host):\(pairing.port)")
                    LabeledContent("연결 상태", value: store.verified ? "최근 조회 확인됨" : "저장됨 · 조회로 확인 필요")
                    Button("프로젝트 불러오기") { Task { await store.browse() } }
                        .disabled(store.busy)
                    Button("연결 정보 삭제", role: .destructive) { confirmingDisconnect = true }
                }
                SecureField("Mac pairing.json 내용 붙여넣기", text: $pairingText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .privacySensitive()
                Button("연결 정보 확인·등록") {
                    pairingCandidate = try? MacWorkspacePairing(json: pairingText)
                    if pairingCandidate != nil { confirmingPairing = true }
                    else { invalidPairing = true }
                }
                .disabled(pairingText.isEmpty || store.busy)
                Text("Mac 터미널에서 읽기 서비스를 직접 시작한 뒤 pairing.json을 본인 아이폰에만 전달하세요. 인증서 지문과 공유 프로젝트를 확인하세요. 연결 정보는 이 기기의 Keychain에만 저장합니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("작업 상태") {
                Text(store.message)
                if store.busy { ProgressView("Mac에서 조회 중…") }
                Button("조회 중지·화면 내용 지우기", role: .cancel) { store.cancel() }
                if store.partial {
                    Label("일부 결과만 표시했습니다. 폴더 범위를 좁혀 다시 조회하세요.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
            }
            if store.pairing != nil {
                Section("프로젝트 파일") {
                    Text(verbatim: store.path.isEmpty ? "/ (허용 프로젝트)" : store.path)
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Button("현재 폴더 다시 조회") { Task { await store.browse(store.path) } }
                        .disabled(store.busy)
                    if !store.path.isEmpty {
                        Button("상위 폴더") {
                            let parent = store.path.split(separator: "/").dropLast().joined(separator: "/")
                            Task { await store.browse(parent) }
                        }.disabled(store.busy)
                    }
                    ForEach(store.entries) { entry in
                        Button {
                            Task {
                                if entry.directory { await store.browse(entry.path) }
                                else { await store.read(entry.path) }
                            }
                        } label: {
                            Label(entry.path.split(separator: "/").last.map(String.init) ?? entry.path,
                                  systemImage: entry.directory ? "folder" : "doc.text")
                        }.disabled(store.busy)
                    }
                    if store.entries.isEmpty && store.document == nil && store.matches.isEmpty && !store.busy {
                        Text("프로젝트를 불러오면 허용된 파일과 폴더가 표시됩니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("현재 폴더에서 텍스트 검색") {
                    TextField("코드·문서 검색어 (최대 100자)", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("검색") { Task { await store.search(query) } }
                        .disabled(store.busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.count > 100)
                    ForEach(store.matches) { match in
                        Button { Task { await store.read(match.path) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: "\(match.path):\(match.line)").font(.caption)
                                Text(verbatim: match.excerpt).font(.caption.monospaced()).lineLimit(3)
                            }
                        }.disabled(store.busy)
                    }
                }
            }
            if let document = store.document {
                Section("파일 내용 · 자동 실행되지 않음") {
                    Text(verbatim: document.path).font(.caption).textSelection(.enabled)
                    Text(verbatim: "SHA-256: \(document.sha256)").font(.caption2.monospaced())
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: document.text).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 180, maxHeight: 420)
                    .privacySensitive()
                }
            }
            Section("Mac 서비스 시작 방법") {
                Text("프로젝트의 Tools/MacBridge/README.md를 참고하세요. 같은 로컬 네트워크에서 Mac 서비스가 실행 중이어야 합니다. Mac이 꺼지거나 서비스가 중지되면 읽을 수 없습니다.")
                    .font(.footnote)
                Text("서버 재시작 시 토큰이 바뀌므로 다시 등록해야 합니다. 파일은 UTF-8 텍스트·64 KiB 이하만 지원합니다. 민감정보 필터가 모든 비밀을 탐지한다고 보장하지 않으므로 공유할 전용 프로젝트를 선택하세요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("개발 공간")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Mac 프로젝트 읽기 연결", isPresented: $confirmingPairing) {
            Button("확인 후 연결 저장") {
                _ = store.configure(pairingText, confirmed: true)
                pairingText = ""; pairingCandidate = nil
            }
            Button("취소", role: .cancel) { pairingCandidate = nil }
        } message: {
            if let candidate = pairingCandidate {
                Text("프로젝트: \(candidate.projectName)\n주소: \(candidate.host):\(candidate.port)\n인증서 SHA-256:\n\(candidate.fingerprint)\n\nMac에 표시된 정보와 일치하는지 확인하세요. 이 연결은 파일 조회만 허용하며 AI에 내용을 보내지 않습니다.")
            }
        }
        .confirmationDialog("이 아이폰의 Mac 연결 정보를 삭제할까요?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("연결 정보 삭제", role: .destructive) { _ = store.disconnect(); pairingText = ""; query = "" }
        }
        .alert("연결 정보 형식을 확인해주세요", isPresented: $invalidPairing) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("Mac에서 실행 중인 서비스의 pairing.json 내용 전체를 붙여 넣어주세요. 로컬 IPv4 주소와 인증서·토큰·프로젝트 정보가 필요합니다.")
        }
        .onDisappear { store.cancel(); pairingText = ""; query = "" }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.cancel(); pairingText = ""; query = "" }
        }
    }
}
#endif
