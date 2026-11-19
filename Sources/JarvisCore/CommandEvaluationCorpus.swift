import Foundation

/// A repeatable baseline for command understanding. These cases contain no
/// personal data and deliberately exercise spacing, wake-word and punctuation
/// changes commonly produced by Korean speech recognition.
public enum CommandEvaluationCorpus {
    public static let minimumPassRate = 0.95
    public static let realisticV2Version = "2026.10-v6-personal-workflows"

    public static let semanticSupplement: [SemanticRoutingEvaluationCase] = [
        .init(id: "note-draft-never-cloud-fallback", input: "안녕이라고 적혀있는 메모를 만들어줘",
              candidate: .init(capabilityID: .call, primaryArgument: "임의 대상", confidence: 1),
              expected: .intent(.init(intent: .projectWorkflow(.noteDraft(text: "안녕")), source: .deterministic))),
        .init(id: "project-no-semantic-override", input: "공유 폴더의 어디든 지워줘",
              candidate: .init(capabilityID: .call, primaryArgument: "임의 대상", confidence: 1),
              expected: .intent(.init(intent: .projectWorkflow(.clarify), source: .deterministic))),
        .init(id: "calendar-write-never-semantic", input: "내일 오후 3시 회의 일정 등록해줘",
              candidate: .init(capabilityID: .call, primaryArgument: "임의 대상", confidence: 1),
              expected: .intent(.init(intent: .calendarWorkflow(.draft(.init(title: "회의", time: .atTime(hour: 3, minute: 0, period: .pm, day: .tomorrow)))), source: .deterministic))),
        .init(id: "new-destination-beats-model", input: "서울역까지 자가용으로 안내해줘",
              candidate: .init(capabilityID: .navigate, primaryArgument: "강남역", secondaryArgument: "car", confidence: 1),
              expected: .intent(.init(intent: .navigate(destination: "서울역", mode: .car), source: .deterministic))),
        .init(id: "reviewed-example-time", input: "테스트용 정중한 요청 문구",
              candidate: .init(capabilityID: .time, secondaryArgument: "time", confidence: 1),
              expected: .intent(.init(intent: .time(.currentTime), source: .semanticModel))),
        .init(id: "nearby-market-semantic", input: "장을 볼 곳 좀 알아봐",
              candidate: .init(capabilityID: .nearbyPlaces, primaryArgument: "market", secondaryArgument: "search", confidence: 0.92),
              expected: .intent(.init(intent: .nearbyPlaces(category: .market, navigate: false, mode: nil), source: .semanticModel))),
        .init(id: "nearby-pharmacy-semantic", input: "약을 구할 곳으로 데려다줘",
              candidate: .init(capabilityID: .nearbyPlaces, primaryArgument: "pharmacy", secondaryArgument: "navigate_car", confidence: 0.91),
              expected: .intent(.init(intent: .nearbyPlaces(category: .pharmacy, navigate: true, mode: .car), source: .semanticModel))),
        .init(id: "nearby-invalid-category", input: "어떤 곳을 좀 알아봐",
              candidate: .init(capabilityID: .nearbyPlaces, primaryArgument: "invented", confidence: 0.91),
              expected: .clarification("마트, 약국, 병원, 주차장, 카페 중 어떤 장소를 찾을까요?")),
        .init(id: "deterministic-beats-model", input: "지금 몇 시야?",
              candidate: .init(capabilityID: .call, primaryArgument: "임의 대상", confidence: 1),
              expected: .intent(.init(intent: .time(.currentTime), source: .deterministic)))
    ]

    public static let standard: [RoutingEvaluationCase] = {
        let wrappers: [(prefix: String, suffix: String)] = [
            ("", ""), ("", "."), ("", "!"), ("", "?"),
            ("자비스 ", ""), ("자비스 ", "."), ("자비스 ", "!"), ("자비스 ", "?"),
            ("자비스야 ", ""), ("자비스야 ", "."), ("자비스야 ", "!"), ("자비스야 ", "?")
        ]

        let stableCases = seeds.flatMap { seed in
            wrappers.enumerated().map { index, wrapper in
                RoutingEvaluationCase(
                    name: "\(seed.name)-변형\(index + 1)",
                    category: seed.category,
                    input: wrapper.prefix + seed.input + wrapper.suffix,
                    previousIntent: seed.previousIntent,
                    expectedIntent: seed.expectedIntent
                )
            }
        }
        let argumentPrefixes = ["", "자비스 ", "자비스야 "]
        let argumentCases = argumentSeeds.flatMap { seed in
            argumentPrefixes.enumerated().map { index, prefix in
                RoutingEvaluationCase(
                    name: "\(seed.name)-호출변형\(index + 1)",
                    category: seed.category,
                    input: prefix + seed.input,
                    previousIntent: seed.previousIntent,
                    expectedIntent: seed.expectedIntent
                )
            }
        }
        let nearbyCases: [RoutingEvaluationCase] = NearbyPlaceCategory.allCases.flatMap { category in
            [RoutingEvaluationCase(name: "주변-\(category.rawValue)", category: .navigation,
                input: "근처 \(category.title) 찾아줘", expectedIntent: .nearbyPlaces(category: category, navigate: false, mode: nil)),
             RoutingEvaluationCase(name: "주변길안내-\(category.rawValue)", category: .navigation,
                input: "주변 \(category.title)로 자가용 안내해줘", expectedIntent: .nearbyPlaces(category: category, navigate: true, mode: .car))]
        }
        let workflows = [
            RoutingEvaluationCase(name: "일정-등록", category: .calendar, input: "내일 오후 3시 회의 일정 등록해줘",
                expectedIntent: .calendarWorkflow(.draft(.init(title: "회의", time: .atTime(hour: 3, minute: 0, period: .pm, day: .tomorrow))))),
            RoutingEvaluationCase(name: "외출-준비", category: .calendar, input: "내일 외출 준비 도와줘", expectedIntent: .prepareOuting(dayOffset: 1))
        ]
        return stableCases + argumentCases + nearbyCases + workflows + sharedProjectCommands
    }()

    public static let sharedProjectCommands: [RoutingEvaluationCase] = [
        .init(name: "메모-자연어내용초안", category: .application, input: "안녕이라고 적혀있는 메모를 만들어줘",
              expectedIntent: .projectWorkflow(.noteDraft(text: "안녕"))),
        .init(name: "메모-TXT내용초안", category: .application, input: "안녕이라는 문구가 적혀있는 txt 파일을 만들어줘",
              expectedIntent: .projectWorkflow(.noteDraft(text: "안녕"))),
        .init(name: "메모-호출내용초안", category: .application, input: "자비스, “반가워”라는 내용의 텍스트 파일을 만들어줘",
              expectedIntent: .projectWorkflow(.noteDraft(text: "반가워"))),
        .init(name: "공유-음성호출구두점", category: .application, input: "자비스, 공유 폴더의 메모 폴더 만들어줘",
              expectedIntent: .projectWorkflow(.prepare(.init(.folder, path: "메모")))),
        .init(name: "공유-폴더생성", category: .application, input: "공유 폴더의 \"메모\" 폴더 만들어줘",
              expectedIntent: .projectWorkflow(.prepare(.init(.folder, path: "메모")))),
        .init(name: "공유-메모생성", category: .application, input: "공유 폴더의 \"메모/장보기.txt\" 메모 만들어줘 내용: 우유",
              expectedIntent: .projectWorkflow(.prepare(.init(.note, path: "메모/장보기.txt", text: "우유")))),
        .init(name: "공유-자연어메모", category: .application, input: "공유 폴더의 메모 폴더에 장보기 메모 만들어줘 내용은 우유",
              expectedIntent: .projectWorkflow(.prepare(.init(.note, path: "메모/장보기.txt", text: "우유")))),
        .init(name: "공유-메모수정", category: .application, input: "공유 폴더의 \"메모/장보기.txt\" 메모 수정해줘 내용: 달걀",
              expectedIntent: .projectWorkflow(.prepare(.init(.update, path: "메모/장보기.txt", text: "달걀")))),
        .init(name: "공유-지정위치이동", category: .application, input: "공유 폴더의 \"메모/장보기.txt\" 파일을 \"기록/장보기.txt\"로 옮겨줘",
              expectedIntent: .projectWorkflow(.prepare(.init(.move, path: "메모/장보기.txt", destination: "기록/장보기.txt")))),
        .init(name: "공유-명시적삭제", category: .safety, input: "공유 폴더의 \"메모/장보기.txt\" 파일 삭제해줘",
              expectedIntent: .projectWorkflow(.prepare(.init(.remove, path: "메모/장보기.txt")))),
        .init(name: "공유-모호한경로", category: .safety, input: "공유 폴더의 거기에 메모 만들어줘", expectedIntent: .projectWorkflow(.clarify)),
        .init(name: "공유-상위탈출", category: .safety, input: "공유 폴더의 \"../다른곳\" 폴더 만들어줘", expectedIntent: .projectWorkflow(.clarify)),
        .init(name: "공유-절대경로", category: .safety, input: "공유 폴더의 \"/tmp/test\" 폴더 만들어줘", expectedIntent: .projectWorkflow(.clarify))
    ]

    /// Semantically distinct, privacy-safe utterances based on commands used
    /// in the app. Unlike `standard`, this corpus does not inflate its size by
    /// adding only wake words or punctuation to the same sentence.
    public static let realisticV2: [EvaluationCaseV2] = {
        var result: [EvaluationCaseV2] = []

        func append(
            _ key: String,
            category: RoutingEvaluationCategory,
            phrases: [String],
            expected: AssistantIntent,
            previous: AssistantIntent? = nil,
            behavior: ExpectedEvaluationBehavior = .resolveIntent,
            risk: ActionRiskLevel = .informational,
            tags: Set<EvaluationTag> = [.naturalSpeech]
        ) {
            for (index, phrase) in phrases.enumerated() {
                result.append(EvaluationCaseV2(
                    id: "\(key)-\(index + 1)",
                    category: category,
                    input: phrase,
                    previousIntent: previous,
                    expectedIntent: expected,
                    expectedBehavior: behavior,
                    riskLevel: risk,
                    tags: tags
                ))
            }
        }

        append("weather-summary", category: .weather, phrases: [
            "오늘 날씨 알려줘", "오늘의 날씨를 말해줘", "오늘 날씨가 어때", "밖의 날씨 어때",
            "오늘 날씨 브리핑해줘", "지금 밖에 나가도 될 날씨야", "오늘 날씨 상태 알려줘", "오늘 전체 날씨를 보여줘",
            "오늘은 날씨가 어떻대", "실시간 날씨 알려줘"
        ], expected: .weather(.todaySummary))
        append("weather-current", category: .weather, phrases: [
            "현재 기온 알려줘", "지금 몇 도야", "밖에 지금 온도가 몇 도야", "현재 온도를 말해줘",
            "지금 기온 확인해줘", "현재 밖의 기온은", "지금 날씨 온도 알려줘", "현재기온 몇도야",
            "지금 온도만 알려줘", "밖에 몇 도인지 알려줘"
        ], expected: .weather(.currentTemperature))
        append("weather-high", category: .weather, phrases: [
            "오늘 최고 기온 알려줘", "오늘 가장 높은 온도는", "낮 최고 기온이 몇 도야", "오늘 최고온도 확인해줘",
            "기온이 최고로 얼마까지 올라", "오늘 제일 따뜻할 때는 몇 도야", "오늘의 최고 기온은", "최고 기온만 말해줘"
        ], expected: .weather(.highTemperature))
        append("weather-low", category: .weather, phrases: [
            "오늘 최저 기온 알려줘", "오늘 가장 낮은 온도는", "오늘 최저온도 확인해줘", "기온이 최저로 얼마까지 내려가",
            "오늘 제일 추울 때는 몇 도야", "오늘의 최저 기온은", "최저 기온만 말해줘", "아침 최저 기온이 몇 도야"
        ], expected: .weather(.lowTemperature))
        append("weather-rain", category: .weather, phrases: [
            "오늘 비 올 확률 알려줘", "오늘 강수 확률은", "오늘 비가 올 가능성은 몇 퍼센트야", "강수확률 확인해줘",
            "오늘 비 예보 확률이 어떻게 돼", "비 올 확률만 말해줘", "오늘 비 가능성 알려줘", "현재 강수 확률은 얼마야"
        ], expected: .weather(.precipitationProbability))
        append("weather-umbrella", category: .weather, phrases: [
            "우산 챙겨야 해", "오늘 우산을 가져갈까", "외출할 때 우산 필요해", "오늘 우산이 필요한지 알려줘",
            "비 대비해서 우산 챙길까", "우산 없이 나가도 돼", "오늘 우산 가져가야 하나", "우산 챙길지 판단해줘"
        ], expected: .weather(.umbrellaAdvice))

        append("calendar-today", category: .calendar, phrases: [
            "오늘 일정 알려줘", "오늘 스케줄을 브리핑해줘", "오늘 무슨 일정이 있어", "오늘 캘린더 보여줘",
            "오늘 예정된 일정을 말해줘", "오늘의 전체 일정은", "오늘 할 일이 뭐야", "오늘 일정 확인해줘",
            "오늘 캘린더에 뭐가 있어", "오늘 스케줄 요약해줘"
        ], expected: .calendar(.todaySummary))
        append("calendar-remaining", category: .calendar, phrases: [
            "오늘 남은 일정 알려줘", "지금 이후 스케줄은", "오늘 앞으로 뭐가 남았어", "남아 있는 오늘 일정 보여줘",
            "오늘 이후 일정만 알려줘", "지금부터의 일정은", "오늘 뒤에 일정 남았어", "남은 스케줄 확인해줘"
        ], expected: .calendar(.remainingToday))
        append("calendar-next", category: .calendar, phrases: [
            "다음 일정 알려줘", "가장 가까운 일정은", "지금 다음 스케줄이 뭐야", "이제 무슨 일정이 있어",
            "첫 번째 남은 일정을 말해줘", "다음 스케줄 확인해줘", "가장 먼저 있는 일정은", "이후 첫 일정 알려줘"
        ], expected: .calendar(.nextEvent))
        append("calendar-count", category: .calendar, phrases: [
            "오늘 일정 몇 개야", "오늘 스케줄 개수를 알려줘", "오늘 약속이 몇 개 있어", "오늘 캘린더 항목 수는",
            "오늘 잡힌 일정이 총 몇 개야", "일정 개수만 말해줘", "오늘 할 일 몇 개 있어", "오늘 일정 수를 세어줘"
        ], expected: .calendar(.eventCount))

        append("time-current", category: .time, phrases: [
            "지금 몇 시야", "현재 시간 알려줘", "지금 시각을 말해줘", "현재 몇 시 몇 분이야",
            "시간 확인해줘", "지금의 정확한 시간은", "현재 시각은", "몇 시인지 알려줘",
            "지금 시계가 몇 시야", "현재시간 얼마야"
        ], expected: .time(.currentTime))
        append("time-date", category: .time, phrases: [
            "오늘 날짜 알려줘", "오늘이 몇 월 며칠이야", "현재 날짜는", "오늘 일자를 말해줘",
            "오늘 며칠이지", "날짜 확인해줘", "오늘의 날짜는", "오늘 몇 일이야"
        ], expected: .time(.todayDate))
        append("time-both", category: .time, phrases: [
            "오늘 날짜와 시간 알려줘", "지금 날짜랑 시각을 말해줘", "현재 일시는", "오늘 며칠이고 몇 시야",
            "날짜와 현재 시간을 함께 알려줘", "지금의 날짜 시간은", "오늘 일자와 시간 확인해줘", "오늘 날짜 그리고 시간은"
        ], expected: .time(.currentDateAndTime))
        append("briefing", category: .briefing, phrases: [
            "현재 브리핑 해줘", "오늘 아침 브리핑해줘", "오늘 날씨와 일정을 함께 알려줘", "오늘 전체 브리핑 부탁해",
            "현재 상황을 브리핑해줘", "오늘 일정과 날씨를 요약해줘", "오늘 하루 브리핑 시작해줘", "지금 기준 전체 브리핑해줘",
            "오늘 스케줄과 날씨 브리핑해줘", "아침 정보 브리핑 해줘"
        ], expected: .fullBriefing)

        append("song-identify", category: .media, phrases: [
            "지금 이 노래 뭐야", "지금 나오는 노래 제목 알려줘", "이 음악이 무슨 곡이야", "현재 재생 중인 노래를 찾아줘",
            "들리는 노래 이름이 뭐야", "이 노래 제목 확인해줘", "지금 듣는 곡 알려줘", "주변에서 나오는 노래 찾아줘",
            "이 음악 인식해줘", "지금 노래 제목이 뭐지"
        ], expected: .identifySong)
        append("media-pause", category: .media, phrases: [
            "유튜브 노래 꺼줘", "지금 재생 중인 음악 멈춰줘", "노래 일시 정지해줘", "미디어 재생을 중지해줘",
            "재생 그만해줘", "지금 나오는 소리 멈춰줘", "유튜브 재생 종료해줘", "음악 재생 멈춰",
            "현재 노래를 정지해줘", "재생하던 거 꺼줘"
        ], expected: .pauseMedia)
        append("volume-up", category: .volume, phrases: [
            "볼륨 올려줘", "소리를 더 키워줘", "음량을 올려줘", "지금보다 크게 틀어줘",
            "핸드폰 소리 조금 올려", "소리가 작아 키워줘", "볼륨을 한 단계 높여줘", "재생 음량 높여줘"
        ], expected: .adjustVolume(delta: 10), risk: .low)
        append("volume-down", category: .volume, phrases: [
            "볼륨 내려줘", "소리를 줄여줘", "음량을 낮춰줘", "지금보다 작게 틀어줘",
            "핸드폰 소리 조금 내려", "소리가 커 줄여줘", "볼륨을 한 단계 낮춰줘", "재생 음량 줄여줘"
        ], expected: .adjustVolume(delta: -10), risk: .low)
        append("volume-exact", category: .volume, phrases: [
            "볼륨 30퍼센트로 해줘", "소리를 30퍼로 맞춰줘", "음량 30퍼센트로 설정해줘", "볼륨을 30으로 변경해줘",
            "핸드폰 소리 30퍼로 해", "소리 크기를 30퍼센트로 설정해줘", "볼륨 30으로 맞춰", "음량을 30퍼로 바꾸어줘"
        ], expected: .setVolume(percent: 30), risk: .low)

        append("youtube-song", category: .media, phrases: [
            "유튜브에서 체념 틀어줘", "유튜브로 체념 재생해줘", "체념을 유튜브에서 들려줘", "유튜브에서 체념 노래 재생해줘",
            "체념 유튜브로 틀어줘", "유튜브 체념 듣고 싶어", "유튜브에서 체념 검색해서 틀어줘", "체념을 유튜브로 재생해",
            "유튜브 체념 노래 틀어", "유튜브에서 체념 들려줄래"
        ], expected: .playYouTube(query: "체념"), risk: .low)
        append("youtube-asr", category: .media, phrases: [
            "유투브에서 체념 틀어줘", "유 튜브에서 체념 틀어줘", "유튜브 체념좀 켜봐", "유튜브에서 체념좀 들려줘",
            "유튜브에 체념 재생해줘", "유튜브에서 체념 틀어 줘", "유튜브로체념틀어줘", "유튜브 체념 틀어줄래",
            "유튜브에서 체념을 틀어줘", "유튜브 체념을 재생해줘"
        ], expected: .playYouTube(query: "체념"), risk: .low, tags: [.speechRecognitionVariation])
        append("youtube-playlist", category: .media, phrases: [
            "유튜브에서 운동 재생목록 틀어줘", "저장한 운동 플레이리스트 재생해줘", "내 운동 재생목록 틀어줘", "유튜브 운동 목록을 열어줘",
            "운동 플레이리스트 시작해줘", "내가 만든 운동 재생목록 재생해", "유튜브에서 운동 플레이리스트 틀어줘", "저장된 운동 목록 재생해줘"
        ], expected: .playYouTubePlaylist(name: "운동"), risk: .low)

        append("alarm-relative", category: .alarm, phrases: [
            "10분 뒤에 알람 울려줘", "10분 후에 알람 맞춰줘", "10분 있다가 알람 설정해줘", "10분 뒤 알람을 등록해줘",
            "10분 후 알람 설정해", "10분 후 알람을 맞춰줘요", "10분 이후 알람을 설정해줘", "10분뒤 알람 맞춰줘",
            "지금부터 10분 뒤 알람 등록해줘", "10분 지나면 알람 울려줘"
        ], expected: .setAlarm(request: .afterMinutes(10), label: nil, message: nil, delivery: .system), risk: .low)
        append("alarm-absolute", category: .alarm, phrases: [
            "내일 오전 7시 30분에 알람 맞춰줘", "내일 아침 7시 30분 알람 설정해줘", "내일 오전 7시 30분에 알람 울려줘", "내일 오전 일곱 시 삼십 분 알람 맞춰줘",
            "내일 아침 7시 반에 알람 맞춰줘", "내일 오전 7시 30분 알람 등록해줘", "내일 아침 일곱시 삼십분에 알람 울려줘", "내일 오전 7시 30분 알람 설정 부탁해"
        ], expected: .setAlarm(request: .atTime(hour: 7, minute: 30, period: .am, day: .tomorrow), label: nil, message: nil, delivery: .system), risk: .low)
        append("alarm-list", category: .alarm, phrases: [
            "등록된 알람 보여줘", "알람 목록 알려줘", "맞춰 둔 알람이 뭐가 있어", "전체 알람을 확인해줘",
            "설정된 알람 목록 보여줘", "지금 있는 알람을 말해줘", "알람이 몇 개 있는지 보여줘", "활성화된 알람 확인해줘"
        ], expected: .listAlarms(.all))
        append("alarm-stop", category: .alarm, phrases: [
            "지금 울리는 알람 꺼줘", "알람 소리 멈춰줘", "현재 알람 종료해줘", "울리고 있는 알람 정지해줘",
            "알람 소리 꺼", "지금 난 알람을 멈춰", "알람이 울리는 중이야 꺼줘", "현재 재생 중인 알람을 중단해줘"
        ], expected: .stopActiveAlarm, risk: .low, tags: [.naturalSpeech, .safetyCritical])

        append("navigation-car", category: .navigation, phrases: [
            "강남역까지 자가용으로 안내해줘", "강남역으로 차로 길 안내해줘", "자동차로 강남역까지 네비게이션 시작해줘", "강남역 차량 경로를 열어줘",
            "강남역까지 운전해서 가는 길 알려줘", "차로 강남역 가는 방법을 안내해줘", "강남역으로 자가용 네비 열어줘", "현재 위치에서 강남역까지 차로 안내해줘",
            "강남역까지 자동차 길찾기 해줘", "강남역으로 운전 경로 시작해줘"
        ], expected: .navigate(destination: "강남역", mode: .car), risk: .medium, tags: [.naturalSpeech, .safetyCritical])
        append("navigation-transit", category: .navigation, phrases: [
            "서울역까지 대중교통으로 안내해줘", "서울역으로 버스나 지하철 경로 열어줘", "대중교통으로 서울역 가는 길 알려줘", "서울역 대중교통 길찾기 해줘",
            "현재 위치에서 서울역까지 대중교통 안내해줘", "서울역으로 지하철 경로를 보여줘", "버스로 서울역 가는 방법 알려줘", "서울역까지 대중교통 네비 시작해줘",
            "서울역으로 대중교통 경로 안내해줘", "서울역 가는 대중교통 길을 열어줘"
        ], expected: .navigate(destination: "서울역", mode: .publicTransit), risk: .medium, tags: [.naturalSpeech, .safetyCritical])
        append("call-mother", category: .communication, phrases: [
            "엄마한테 전화해줘", "엄마에게 전화 걸어줘", "엄마 연락처로 통화 연결해줘", "엄마한테 전화 걸기 해줘",
            "엄마를 전화로 연결해줘", "엄마한테 통화하고 싶어", "엄마 전화번호로 전화해줘", "엄마에게 통화 시도해줘",
            "엄마한테 전화 연결해", "엄마랑 통화하게 해줘"
        ], expected: .call(recipient: "엄마", speakerRequested: false), risk: .medium, tags: [.naturalSpeech, .safetyCritical])
        append("app-kakao", category: .application, phrases: [
            "카카오톡 열어줘", "카톡 앱 실행해줘", "카카오톡을 켜줘", "카톡으로 들어가줘",
            "카카오톡 앱을 열어줘", "카톡 시작해줘", "카카오톡 실행해", "카톡 화면을 열어줘",
            "카카오톡으로 전환해줘", "카톡 어플을 켜줘"
        ], expected: .openApp(name: "카카오톡"), risk: .medium, tags: [.naturalSpeech, .safetyCritical])

        append("web-search", category: .search, phrases: [
            "인터넷에 광합성을 검색해줘", "웹에서 광합성을 찾아줘", "인터넷으로 광합성 정보를 찾아줘", "광합성을 인터넷에서 검색해줘",
            "웹 검색으로 광합성을 알려줘", "인터넷에서 광합성 자료를 찾아줘", "광합성에 대해 웹을 검색해줘", "온라인에서 광합성을 찾아줘",
            "인터넷 검색으로 광합성을 찾아줘", "웹에서 광합성 내용을 검색해줘"
        ], expected: .webSearch(query: "광합성을"))
        append("restaurant", category: .search, phrases: [
            "근처 한식 맛집 추천해줘", "가까운 한식집 찾아줘", "현재 위치에서 평점 좋은 한식집 알려줘", "주변에 인기 있는 한식 맛집 추천해줘",
            "이 근처 한식 식당 세 곳 알려줘", "근처에서 잘하는 한식집 찾아줘", "가까운 한식 음식점 추천해줘", "주변 한식 맛집을 알려줘",
            "현재 위치 기준 한식집 추천해줘", "근처 한식 맛집을 찾아줘"
        ], expected: .recommendRestaurants(query: "한식"))
        append("memory-list", category: .memory, phrases: [
            "기억 목록 보여줘", "저장한 기억을 알려줘", "장기 기억에 뭐가 있어", "나에 대해 기억한 내용 보여줘",
            "저장된 모든 기억 확인해줘", "기억하고 있는 항목을 말해줘", "장기 기억 목록을 열어줘", "내 기억 항목 확인해줘"
        ], expected: .listMemories)
        append("dismiss", category: .safety, phrases: [
            "아니야 잘못 불렀어", "됐어 취소해", "아냐 그만해", "잘못 불렀으니 대화 끝내",
            "아무것도 아니야", "요청 취소할게", "자비스 그만", "지금 명령은 취소해줘",
            "실수로 불렀어", "아냐 됐어"
        ], expected: .dismissConversation, behavior: .dismiss, tags: [.naturalSpeech, .safetyCritical])
        append("capabilities", category: .conversation, phrases: [
            "어떤 기능을 할 수 있어", "네가 할 수 있는 걸 알려줘", "자비스 기능 목록 보여줘", "무슨 명령을 지원해",
            "현재 가능한 기능은 뭐야", "무엇을 부탁할 수 있어", "자비스가 할 수 있는 작업은", "사용 가능한 명령을 설명해줘"
        ], expected: .assistantCapabilities)

        let ambiguousPhrases = [
            "그거 해줘", "저거 열어줘", "아까 거 실행해줘", "거기로 가줘", "그 사람한테 해줘",
            "이거 취소해줘", "그대로 진행해줘", "다음 걸로 해줘", "지금 필요한 거 해줘", "아까 말한 곳으로 열어줘"
        ]
        for (index, phrase) in ambiguousPhrases.enumerated() {
            result.append(EvaluationCaseV2(
                id: "ambiguous-\(index + 1)",
                category: .safety,
                input: phrase,
                expectedIntent: .unknownCommand(text: phrase),
                expectedBehavior: .askForClarification,
                riskLevel: .high,
                tags: [.ambiguous, .safetyCritical]
            ))
        }

        append(
            "context-youtube-pronoun",
            category: .media,
            phrases: ["아까 그 노래 다시", "그 노래 한 번 더 틀어줘"],
            expected: .playYouTube(query: "체념"),
            previous: .playYouTube(query: "체념"),
            risk: .low,
            tags: [.followUp, .pronoun]
        )
        append(
            "context-app-pronoun",
            category: .application,
            phrases: ["그 앱 다시 열어줘", "아까 그 앱을 열어줘"],
            expected: .openApp(name: "카카오톡"),
            previous: .openApp(name: "카카오톡"),
            risk: .medium,
            tags: [.followUp, .pronoun, .safetyCritical]
        )
        append(
            "context-weather-high-followup",
            category: .weather,
            phrases: ["그럼 최고는"],
            expected: .weather(.highTemperature),
            previous: .weather(.todaySummary),
            tags: [.followUp]
        )
        append(
            "context-weather-low-followup",
            category: .weather,
            phrases: ["그러면 최저 기온은"],
            expected: .weather(.lowTemperature),
            previous: .weather(.todaySummary),
            tags: [.followUp]
        )
        append(
            "context-topic-change",
            category: .weather,
            phrases: ["일정 말고 오늘 날씨 알려줘", "길 안내 말고 지금 날씨 알려줘"],
            expected: .weather(.todaySummary),
            previous: .navigate(destination: "강남역", mode: .car),
            tags: [.topicChange]
        )
        append(
            "spacing-youtube",
            category: .media,
            phrases: ["유 튜브에서 체념 틀어 줘", "유튜브 에서 체념 재생 해줘"],
            expected: .playYouTube(query: "체념"),
            risk: .low,
            tags: [.speechRecognitionVariation, .spacingVariation]
        )

        append("nearby-market", category: .navigation,
            phrases: ["근처에 마트가 어떤 게 있어?", "주변 슈퍼 찾아줘", "가까운 마트 알려줘"],
            expected: .nearbyPlaces(category: .market, navigate: false, mode: nil))
        append("nearby-pharmacy", category: .navigation,
            phrases: ["근처 약국으로 자가용 안내해줘", "가까운 약국 자가용으로 안내해줘"],
            expected: .nearbyPlaces(category: .pharmacy, navigate: true, mode: .car))
        append("fresh-navigation-target", category: .navigation,
            phrases: ["서울역까지 자가용으로 안내해줘", "서울역으로 차로 안내해줘"],
            expected: .navigate(destination: "서울역", mode: .car),
            previous: .navigate(destination: "강남역", mode: .publicTransit),
            risk: .medium, tags: [.topicChange, .followUp])
        append("calendar-create", category: .calendar, phrases: ["내일 오후 3시 회의 일정 등록해줘"],
            expected: .calendarWorkflow(.draft(.init(title: "회의", time: .atTime(hour: 3, minute: 0, period: .pm, day: .tomorrow)))))
        append("calendar-delete", category: .calendar, phrases: ["회의 일정 취소해줘"],
            expected: .calendarWorkflow(.draft(.init(operation: .delete, title: "회의"))))
        append("outing-plan", category: .calendar, phrases: ["내일 외출 준비 도와줘"], expected: .prepareOuting(dayOffset: 1))
        append("outing-plan-today", category: .calendar, phrases: ["오늘 나갈 준비 도와줘"], expected: .prepareOuting(dayOffset: 0))
        return result
    }()

    private struct Seed {
        let name: String
        let category: RoutingEvaluationCategory
        let input: String
        let previousIntent: AssistantIntent?
        let expectedIntent: AssistantIntent

        init(
            name: String,
            category: RoutingEvaluationCategory,
            input: String,
            previousIntent: AssistantIntent? = nil,
            expectedIntent: AssistantIntent
        ) {
            self.name = name
            self.category = category
            self.input = input
            self.previousIntent = previousIntent
            self.expectedIntent = expectedIntent
        }
    }

    private static let seeds: [Seed] = [
        .init(name: "오늘 날씨", category: .weather, input: "오늘 날씨 알려줘", expectedIntent: .weather(.todaySummary)),
        .init(name: "밖의 날씨", category: .weather, input: "밖에 어때", expectedIntent: .weather(.todaySummary)),
        .init(name: "현재 기온", category: .weather, input: "현재 기온 알려줘", expectedIntent: .weather(.currentTemperature)),
        .init(name: "지금 온도", category: .weather, input: "지금 몇 도야", expectedIntent: .weather(.currentTemperature)),
        .init(name: "최고 기온", category: .weather, input: "오늘 최고 기온 알려줘", expectedIntent: .weather(.highTemperature)),
        .init(name: "최저 기온", category: .weather, input: "오늘 최저 기온 알려줘", expectedIntent: .weather(.lowTemperature)),
        .init(name: "기온 범위", category: .weather, input: "오늘 최고와 최저 알려줘", expectedIntent: .weather(.temperatureRange)),
        .init(name: "강수 확률", category: .weather, input: "오늘 비 올 확률 알려줘", expectedIntent: .weather(.precipitationProbability)),
        .init(name: "우산", category: .weather, input: "우산 챙겨야 해", expectedIntent: .weather(.umbrellaAdvice)),
        .init(name: "오늘 일정", category: .calendar, input: "오늘 일정 알려줘", expectedIntent: .calendar(.todaySummary)),
        .init(name: "남은 일정", category: .calendar, input: "남은 일정 알려줘", expectedIntent: .calendar(.remainingToday)),
        .init(name: "다음 일정", category: .calendar, input: "다음 일정 알려줘", expectedIntent: .calendar(.nextEvent)),
        .init(name: "일정 개수", category: .calendar, input: "오늘 일정 몇 개야", expectedIntent: .calendar(.eventCount)),
        .init(name: "현재 시각", category: .time, input: "지금 몇 시야", expectedIntent: .time(.currentTime)),
        .init(name: "현재 시간", category: .time, input: "현재 시간 알려줘", expectedIntent: .time(.currentTime)),
        .init(name: "오늘 날짜", category: .time, input: "오늘 날짜 알려줘", expectedIntent: .time(.todayDate)),
        .init(name: "날짜와 시간", category: .time, input: "오늘 날짜와 시간 알려줘", expectedIntent: .time(.currentDateAndTime)),
        .init(name: "현재 브리핑", category: .briefing, input: "현재 브리핑 해줘", expectedIntent: .fullBriefing),
        .init(name: "날씨 일정 브리핑", category: .briefing, input: "날씨와 일정 알려줘", expectedIntent: .fullBriefing),
        .init(name: "현재 노래", category: .media, input: "지금 이 노래 뭐야", expectedIntent: .identifySong),
        .init(name: "노래 제목", category: .media, input: "노래 제목 알려줘", expectedIntent: .identifySong),
        .init(name: "볼륨 올리기", category: .volume, input: "볼륨 올려줘", expectedIntent: .adjustVolume(delta: 10)),
        .init(name: "볼륨 내리기", category: .volume, input: "소리 줄여줘", expectedIntent: .adjustVolume(delta: -10)),
        .init(name: "볼륨 지정", category: .volume, input: "볼륨 30퍼센트로 해줘", expectedIntent: .setVolume(percent: 30)),
        .init(name: "음소거", category: .volume, input: "음소거 해줘", expectedIntent: .setVolume(percent: 0)),
        .init(name: "유튜브 중지", category: .media, input: "유튜브 노래 꺼줘", expectedIntent: .pauseMedia),
        .init(name: "미디어 중지", category: .media, input: "미디어 재생 멈춰줘", expectedIntent: .pauseMedia),
        .init(name: "기능 질문", category: .conversation, input: "무슨 기능을 할 수 있어", expectedIntent: .assistantCapabilities),
        .init(name: "자비스 기능", category: .conversation, input: "자비스 기능 알려줘", expectedIntent: .assistantCapabilities),
        .init(name: "잘못 호출", category: .safety, input: "잘못 불렀어", expectedIntent: .dismissConversation),
        .init(name: "반복 취소 응답", category: .safety, input: "아냐 아냐", expectedIntent: .dismissConversation)
    ]

    private static let argumentSeeds: [Seed] = [
        .init(name: "유튜브 노래", category: .media, input: "유튜브에서 아이유 밤편지 틀어줘", expectedIntent: .playYouTube(query: "아이유 밤편지")),
        .init(name: "유튜브 요청 변형", category: .media, input: "혹시 유튜브에서 체념 좀 들려줄래", expectedIntent: .playYouTube(query: "체념")),
        .init(name: "운동 재생목록", category: .media, input: "유튜브에서 운동 재생목록 틀어줘", expectedIntent: .playYouTubePlaylist(name: "운동")),
        .init(name: "출근 재생목록", category: .media, input: "내가 저장한 출근 플레이리스트 재생해줘", expectedIntent: .playYouTubePlaylist(name: "출근")),
        .init(name: "연락처 전화", category: .communication, input: "민수한테 전화해줘", expectedIntent: .call(recipient: "민수", speakerRequested: false)),
        .init(name: "스피커폰 전화", category: .communication, input: "엄마한테 스피커폰으로 전화 걸어줘", expectedIntent: .call(recipient: "엄마", speakerRequested: true)),
        .init(name: "번호 전화", category: .communication, input: "010-1234-5678로 전화해줘", expectedIntent: .call(recipient: "010-1234-5678", speakerRequested: false)),
        .init(name: "카카오톡 실행", category: .application, input: "카카오톡 열어줘", expectedIntent: .openApp(name: "카카오톡")),
        .init(name: "인스타그램 실행", category: .application, input: "인스타그램 앱을 실행해 줘", expectedIntent: .openApp(name: "인스타그램")),
        .init(name: "목적지 질문", category: .navigation, input: "현재 위치에서 강남역까지 가는 방법을 알려줘", expectedIntent: .navigate(destination: "강남역", mode: .publicTransit)),
        .init(name: "차량 길 안내", category: .navigation, input: "서울역까지 차로 길 안내해줘", expectedIntent: .navigate(destination: "서울역", mode: .car)),
        .init(name: "대중교통 안내", category: .navigation, input: "광화문으로 대중교통 안내해줘", expectedIntent: .navigate(destination: "광화문", mode: .publicTransit)),
        .init(name: "안내 부탁", category: .navigation, input: "강남역으로 안내 부탁해", expectedIntent: .navigate(destination: "강남역", mode: .publicTransit)),
        .init(name: "중복 역명 정리", category: .navigation, input: "강남역 역으로 대중교통 안내해줘", expectedIntent: .navigate(destination: "강남역", mode: .publicTransit)),
        .init(name: "인터넷 제품 검색", category: .search, input: "인터넷에 아이폰 17 프로 스펙을 검색해서 알려줘", expectedIntent: .webSearch(query: "아이폰 17 프로 스펙을")),
        .init(name: "웹 뉴스 검색", category: .search, input: "웹에서 오늘의 AI 뉴스를 찾아줘", expectedIntent: .webSearch(query: "오늘의 ai 뉴스를")),
        .init(name: "최신 정보 자동 검색", category: .search, input: "최신 AI 뉴스 알려줘", expectedIntent: .webSearch(query: "최신 AI 뉴스 알려줘")),
        .init(name: "한식 추천", category: .search, input: "현재 위치에서 평점 좋은 한식 맛집 추천해줘", expectedIntent: .recommendRestaurants(query: "한식")),
        .init(name: "초밥 추천", category: .search, input: "가까운 초밥집 찾아줘", expectedIntent: .recommendRestaurants(query: "초밥집")),
        .init(name: "기억 저장", category: .memory, input: "나는 매운 음식을 좋아해 기억해줘", expectedIntent: .remember(content: "나는 매운 음식을 좋아해")),
        .init(name: "최근 기억 삭제", category: .memory, input: "방금 기억한 거 잊어줘", expectedIntent: .forgetMemory(.latest)),
        .init(name: "전체 기억 삭제", category: .memory, input: "모든 기억을 잊어줘", expectedIntent: .forgetMemory(.all)),
        .init(name: "기억 목록", category: .memory, input: "기억 목록 보여줘", expectedIntent: .listMemories),
        .init(name: "상대 알람", category: .alarm, input: "10분 뒤에 알람 울려줘", expectedIntent: .setAlarm(request: .afterMinutes(10), label: nil, message: nil, delivery: .system)),
        .init(name: "절대 알람", category: .alarm, input: "내일 오전 7시 30분에 알람 맞춰줘", expectedIntent: .setAlarm(request: .atTime(hour: 7, minute: 30, period: .am, day: .tomorrow), label: nil, message: nil, delivery: .system)),
        .init(name: "라면 음성 알림", category: .alarm, input: "라면 물 꺼야하니까 3분 뒤에 알려줘", expectedIntent: .setAlarm(request: .afterMinutes(3), label: "라면 물 끄기", message: "라면 물 끄실 시간입니다.", delivery: .jarvisVoice)),
        .init(name: "약 음성 알림", category: .alarm, input: "20분 뒤에 약 먹으라고 알려줘", expectedIntent: .setAlarm(request: .afterMinutes(20), label: "약 먹기", message: "약 드실 시간입니다.", delivery: .jarvisVoice)),
        .init(name: "후속 날씨", category: .weather, input: "그럼 최저는", previousIntent: .weather(.todaySummary), expectedIntent: .weather(.lowTemperature)),
        .init(name: "후속 일정", category: .calendar, input: "그럼 다음은", previousIntent: .calendar(.todaySummary), expectedIntent: .calendar(.nextEvent)),
        .init(name: "후속 유튜브", category: .media, input: "다시 틀어줘", previousIntent: .playYouTube(query: "체념"), expectedIntent: .playYouTube(query: "체념")),
        .init(name: "후속 앱 실행", category: .application, input: "다시 열어줘", previousIntent: .openApp(name: "카카오톡"), expectedIntent: .openApp(name: "카카오톡")),
        .init(name: "새 목적지 우선", category: .navigation, input: "하이디 라우까지 자가용으로 안내해줘", previousIntent: .navigate(destination: "강남역", mode: .publicTransit), expectedIntent: .navigate(destination: "하이디 라우", mode: .car)),
        .init(name: "음성 식당명 목적지", category: .navigation, input: "하이디 라오까지 자가용으로 안내해줘", expectedIntent: .navigate(destination: "하이디 라오", mode: .car)),
        .init(name: "이동 방식만 후속 변경", category: .navigation, input: "자가용으로 안내해줘", previousIntent: .navigate(destination: "강남역", mode: .publicTransit), expectedIntent: .navigate(destination: "강남역", mode: .car)),
        .init(name: "새 앱 대상 우선", category: .application, input: "인스타그램 다시 열어줘", previousIntent: .openApp(name: "카카오톡"), expectedIntent: .openApp(name: "인스타그램")),
        .init(name: "새 웹 검색어 우선", category: .search, input: "인터넷에서 최신 아이폰 정보를 검색해줘", previousIntent: .webSearch(query: "서울 날씨"), expectedIntent: .webSearch(query: "최신 아이폰 정보를"))
    ]
}
