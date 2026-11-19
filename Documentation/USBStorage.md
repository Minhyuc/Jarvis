# JARVIS USB 전용 운영

USB의 `M_H/Jarvis/JARVISStorage.sparsebundle`은 APFS 저장 공간이다. USB를 포맷하지 않았다. 사용량에 따라 늘어나며 최대 64GiB다.

- 앱: `/Volumes/JARVISData/Applications/JARVIS.app`
- 코드: `/Volumes/JARVISData/Project`
- 일반 작업 폴더: `/Volumes/JARVISData/Shared` 또는 사용자가 만든 USB 내부 폴더
- 대화·DB·백업: `/Volumes/JARVISData/Data/ApplicationSupport`
- 설정: `/Volumes/JARVISData/Data/preferences.plist`
- Codex 전용 프로필: `/Volumes/JARVISData/Data/CodexLocal/AppServer`
- 임시 작업: `/Volumes/JARVISData/Data/Temporary`
- 빌드와 이전 자료: `Builds`, `Archives`

앱은 샌드박스를 유지한다. 실행할 때 JARVISData 접근을 직접 허용하며 권한은 이번 실행 동안만 유지한다. 프로젝트·첨부·가져오기·저장은 USB 내부의 일반 작업 폴더만 허용한다. 앱 데이터·앱 자체·빌드·이전 자료 영역과 저장 공간 최상위 전체는 일반 파일/코드 작업에서 보호한다. 모델의 실행·변경·출력 전송 승인은 별도로 유지한다.

USB가 없으면 실행할 수 없고 연결 해제 또는 저장 오류 시 작업 화면과 활성 작업을 중단한다. 빈 Mac 저장소로 자동 전환하지 않는다. 분리 전 작업을 끝내고 앱·Xcode를 종료한 뒤 JARVISData, USB 순서로 추출한다. 연결 중 강제 분리와 전원 손실은 데이터 손상을 일으킬 수 있으므로 별도 백업을 유지한다. sparsebundle 내부 band 파일은 직접 수정하지 않는다.

새 USB Codex 프로필은 기존 인증 파일을 복사하지 않으며 별도 로그인이 필요하다. 기존 일반 세션 자료는 Data/LegacyCodexProfile에 보존한다. 기존 Mac JARVIS 전용 Codex 로그인은 사용자 확인 후 로그아웃·정리했다. Keychain, OS 폴더 권한·캐시·로그 등 시스템 정보는 Mac에 남을 수 있다. macOS 전체 흔적이 전혀 없는 실행을 보장하지 않는다. Xcode·Python·공식 Codex는 이 Mac의 실행 의존성이다. iPhone 데이터나 iCloud 원본은 이 작업으로 이동·삭제하지 않는다.

USB 폴더의 실행·개발 연결은 USB 확인 후 앱/프로젝트를 연다. 실제 이전 확인은 migration-report.json과 Data/portable-data-migration.json에 남긴다.

검증: Swift 334개, Python 113개, Mac 서명 빌드·unsigned iOS Simulator 빌드·Mac UI 회귀 검증 통과. USB 앱의 권한 선택과 개발 공간 진입을 실제 화면에서 확인했다. 실제 계정의 새 USB Codex 로그인·모델 응답 검증은 사용자 로그인이 필요하며, 강제 분리 시험은 수행하지 않았다.
