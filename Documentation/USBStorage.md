# JARVIS 외장 SSD APFS 운영

외장 SSD는 JARVIS(APFS, 100GB)와 MH(exFAT, 나머지 공간)로 나뉜다. 실행 데이터는 `/Volumes/JARVIS/Jarvis`의 일반 파일과 폴더이며 sparsebundle을 연결하지 않는다. MH는 공용 파일 공간으로 JARVIS 실행에 필요하지 않다.

- 코드: `Project` (실제 `.swift`, `.xcodeproj`, `.git` 파일)
- 앱: `Applications/JARVIS.app` (macOS 실행 앱은 표준 app 패키지 유지)
- 대화·DB·백업: `Data/ApplicationSupport`
- 설정: `Data/preferences.plist`
- Codex 전용 프로필: `Data/CodexLocal/AppServer`
- 임시 작업: `Data/Temporary`
- 일반 프로젝트: `Shared` 또는 APFS 설치 루트 내부의 사용자 작업 폴더
- 빌드: `Builds`, 보존 자료: `Archives`

Mac 앱·XPC·Python 서비스·실행 스크립트는 새 루트와 JARVIS 볼륨 UUID를 검증한다. 앱은 샌드박스를 유지하고 실행마다 Jarvis 폴더 접근을 명시적으로 허용한다. 연결 해제·저장 오류 시 작업을 중단하며 Mac 로컬 저장소로 대체하지 않는다. 안전 잠금과 파일 공유·수정·명령 실행 승인은 이전과 동일하다. 실제 실행 담당과 iPhone 데이터 경로는 바꾸지 않는다.

`JARVIS 실행.command`는 앱을, `JARVIS 개발.command`는 Mac Xcode 프로젝트를 연다. 소스는 Finder에서도 일반 파일로 볼 수 있다. 파일 형식이 달라지는 변환이 아니라 APFS 이미지 내부의 파일을 실제 APFS 볼륨으로 복원한 것이다. 앱 자체의 `.app` 패키지는 정상 macOS 형식이다.

복원 직후 전체 일반 파일을 SHA-256으로 비교하며 결과는 설치 루트의 `restore-verification.json`에 남긴다. 이후 변경한 실행 소스와 재빌드 앱은 원본과 달라진다. 기존 실행 파일과 안내는 `Archives/OriginalLaunchers`에 보관한다. 인증 파일은 읽거나 복사하지 않으며 Codex 로그인은 별도 확인한다. 이전에 선택한 폴더 권한은 재선택이 필요할 수 있다.

분리 전 앱·Xcode를 종료하고 볼륨을 추출한다. Mac에는 Xcode·Python·공식 Codex 실행 의존성과 OS 권한·캐시·로그가 남을 수 있다. iPhone과 iCloud 원본을 이동하거나 삭제하지 않는다. 일반 파일 도구로 Data·Applications·Builds·Archives를 수정하지 못하게 하는 보호를 유지한다.
