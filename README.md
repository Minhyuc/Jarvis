# JARVIS iOS MVP

개인 iPhone에서 사용하는 음성 비서의 첫 번째 MVP입니다. 카카오톡, 날씨, 옷 추천은 이번 범위에서 제외했습니다.

## 현재 가능한 기능

- 앱에서 한 번만 음성 명령 듣기
- 사용자가 시작한 뒤 “자비스” 호출어 기다리기
- 기본적인 로컬 응답
- “유튜브에서 아이유 밤편지 틀어줘” 같은 명령을 인식해 YouTube 검색 열기
- 텍스트 명령 입력
- App Intent와 단축어를 통한 빠른 실행
- 백그라운드 오디오 모드 및 마이크/음성 인식 권한 설정

YouTube 명령은 현재 검색 결과를 여는 단계까지 지원합니다. YouTube 앱의 재생 상태를 임의로 제어하지는 않습니다.

## 실행 준비

1. Mac App Store에서 최신 안정 버전 Xcode를 설치합니다.
2. `Jarvis.xcodeproj`를 Xcode로 엽니다.
3. 프로젝트 탐색기에서 `Jarvis` 타깃을 선택합니다.
4. **Signing & Capabilities**에서 본인의 Apple 계정 Team을 선택합니다.
5. Bundle Identifier가 충돌하면 `com.personal.jarvisassistant`를 고유한 값으로 변경합니다.
6. 실제 iPhone을 Mac에 연결하고, iPhone에서 개발자 모드를 활성화합니다.
7. 실행 대상을 연결된 iPhone으로 선택한 뒤 Run을 누릅니다.

시뮬레이터보다 실제 iPhone 테스트를 권장합니다. 마이크, 화면 잠금, 백그라운드 오디오, App Shortcut은 실제 기기에서 확인해야 합니다.

## 첫 실행

첫 실행 시 다음 권한을 허용합니다.

- 마이크
- 음성 인식

“한 번만 대화하기”는 호출어 없이 곧바로 명령을 듣습니다. “음성 대기 시작”은 “자비스”를 들을 때까지 대기합니다.

## 뒷면 탭 연결

앱을 한 번 실행한 후 단축어 앱에서 JARVIS의 “자비스에게 말하기” 동작이 나타나는지 확인합니다.

1. 설정 → 손쉬운 사용 → 터치 → 뒷면 탭으로 이동합니다.
2. 이중 탭 또는 삼중 탭을 선택합니다.
3. “자비스에게 말하기” 단축어를 지정합니다.

액션 버튼을 지원하는 iPhone은 설정 → 액션 버튼 → 단축어에서 같은 동작을 선택할 수 있습니다.

## 구조

```text
Jarvis/                  iOS 앱과 음성/UI 구현
Sources/JarvisCore/      플랫폼 독립 명령 라우터
Tests/JarvisCoreTests/   명령 라우터 단위 테스트
Package.swift            핵심 로직을 별도로 테스트하기 위한 패키지
Jarvis.xcodeproj/        iOS 앱 프로젝트
```

`AIClient` 뒤의 `MockAIClient`를 이후 Apple Foundation Models 또는 원격 모델 구현으로 교체할 수 있습니다. 알려진 명령은 `CommandRouter`에서 AI 없이 처리하므로 모델 상태와 관계없이 빠르게 실행할 수 있습니다.

## 테스트

Xcode가 설치되고 활성화된 환경에서는 다음 명령으로 핵심 로직을 테스트할 수 있습니다.

```sh
swift test
```

앱 빌드는 다음과 같이 확인할 수 있습니다.

```sh
xcodebuild -project Jarvis.xcodeproj \
  -scheme Jarvis \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

사용 가능한 시뮬레이터 이름은 Xcode 설치 버전에 따라 다릅니다.

## 현재 제한

- Xcode 전체가 설치되지 않은 현재 생성 환경에서는 iOS 빌드를 실행하지 못했습니다.
- 설치된 Command Line Tools의 Swift 컴파일러와 SDK 버전도 일치하지 않아 `swift test`를 완료하지 못했습니다.
- Speech framework 기반 호출어 감지는 장시간 대기용 전용 wake-word 엔진보다 배터리 사용량이 많을 수 있습니다.
- 앱 강제 종료 또는 기기 재시동 후에는 사용자가 대기 모드를 다시 시작해야 합니다.
- 외부 YouTube 앱의 재생, 일시 정지, 다음 곡을 JARVIS가 직접 제어하지는 않습니다.

## 다음 권장 단계

1. Xcode 설치 후 빌드 오류 수정 및 실제 기기 실행
2. 화면 잠금과 백그라운드 호출어 테스트
3. 오디오 인터럽트 및 자동 복구 추가
4. Apple Foundation Models 기반 기본 대화 추가
5. 전용 온디바이스 호출어 모델 검토
6. YouTube 검색 결과 선택 정확도 개선
