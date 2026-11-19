import XCTest
@testable import JarvisCore

final class CommandRouterTests: XCTestCase {
    private let router = CommandRouter()

    func testRoutesMistakenInvocationDismissal() {
        XCTAssertEqual(router.route("아니야"), .dismissConversation)
        XCTAssertEqual(router.route("아냐 아냐"), .dismissConversation)
        XCTAssertEqual(router.route("아냐 됐어"), .dismissConversation)
        XCTAssertEqual(router.route("자비스야, 잘못 불렀어"), .dismissConversation)
        XCTAssertEqual(router.route("별일 아니야"), .dismissConversation)
        XCTAssertEqual(router.route("됐어요"), .dismissConversation)
    }

    func testRoutesExplicitMemorySave() {
        XCTAssertEqual(
            router.route("나는 매운 음식을 좋아해. 기억해줘"),
            .remember(content: "나는 매운 음식을 좋아해")
        )
        XCTAssertEqual(
            router.route("내 생일은 5월 3일이야 기억해 둬"),
            .remember(content: "내 생일은 5월 3일이야")
        )
    }

    func testRoutesMemoryDeletion() {
        XCTAssertEqual(
            router.route("매운 음식을 좋아한다는 기억을 잊어줘"),
            .forgetMemory(.matching("매운 음식을 좋아한다는"))
        )
        XCTAssertEqual(router.route("방금 기억한 거 잊어줘"), .forgetMemory(.latest))
        XCTAssertEqual(router.route("모든 기억을 잊어줘"), .forgetMemory(.all))
    }

    func testRoutesMemoryList() {
        XCTAssertEqual(router.route("기억 목록 보여줘"), .listMemories)
        XCTAssertEqual(router.route("나에 대해 뭘 기억하고 있어?"), .listMemories)
    }

    func testRoutesCurrentSongIdentification() {
        XCTAssertEqual(router.route("지금 나오는 노래가 뭐야?"), .identifySong)
        XCTAssertEqual(router.route("지금 이 노래는 뭐야?"), .identifySong)
        XCTAssertEqual(router.route("현재 들리는 곡 제목이 뭐야"), .identifySong)
        XCTAssertEqual(router.route("이 음악 누가 부른 거야"), .identifySong)
    }

    func testRoutesSongTitleIdentification() {
        XCTAssertEqual(router.route("이 노래 제목 알려줘"), .identifySong)
    }

    func testRoutesSongIdentificationFollowUp() {
        XCTAssertEqual(
            router.route("다시 들어봐", previousIntent: .identifySong),
            .identifySong
        )
    }

    func testRoutesYouTubePause() {
        XCTAssertEqual(router.route("유튜브 노래 꺼줘"), .pauseMedia)
    }

    func testRoutesMediaPause() {
        XCTAssertEqual(router.route("지금 재생 중인 음악을 멈춰줘"), .pauseMedia)
        XCTAssertEqual(router.route("지금 나오는 노래 좀 꺼"), .pauseMedia)
        XCTAssertEqual(router.route("유튜브 재생 그만해"), .pauseMedia)
    }

    func testRoutesExactVolume() {
        XCTAssertEqual(router.route("볼륨을 35퍼센트로 해줘"), .setVolume(percent: 35))
    }

    func testRoutesVolumeUp() {
        XCTAssertEqual(router.route("볼륨 10퍼센트 올려줘"), .adjustVolume(delta: 10))
        XCTAssertEqual(router.route("소리 좀 키워줘"), .adjustVolume(delta: 10))
    }

    func testRoutesVolumeDown() {
        XCTAssertEqual(router.route("음량을 내려줘"), .adjustVolume(delta: -10))
        XCTAssertEqual(router.route("소리를 조금 조용히 해줘"), .adjustVolume(delta: -10))
    }

    func testRoutesMute() {
        XCTAssertEqual(router.route("음소거해줘"), .setVolume(percent: 0))
    }

    func testRoutesAbsoluteAlarm() {
        XCTAssertEqual(
            router.route("내일 오전 7시 30분에 알람 맞춰줘"),
            .setAlarm(
                request: .atTime(hour: 7, minute: 30, period: .am, day: .tomorrow),
                label: nil,
                message: nil,
                delivery: .system
            )
        )
    }

    func testRoutesAfternoonAlarm() {
        XCTAssertEqual(
            router.route("오후 3시에 알람 설정해줘"),
            .setAlarm(
                request: .atTime(hour: 3, minute: 0, period: .pm, day: .automatic),
                label: nil,
                message: nil,
                delivery: .system
            )
        )
    }

    func testRoutesRelativeAlarm() {
        XCTAssertEqual(
            router.route("10분 뒤에 알람 울려줘"),
            .setAlarm(request: .afterMinutes(10), label: nil, message: nil, delivery: .system)
        )
        XCTAssertEqual(
            router.route("10분 후에 알람을 맞춰줘"),
            .setAlarm(request: .afterMinutes(10), label: nil, message: nil, delivery: .system)
        )
    }

    func testRoutesNaturalLanguageAlarmWithPurpose() {
        XCTAssertEqual(
            router.route("라면 물 꺼야하니까 3분 뒤에 알려줘"),
            .setAlarm(
                request: .afterMinutes(3),
                label: "라면 물 끄기",
                message: "라면 물 끄실 시간입니다.",
                delivery: .jarvisVoice
            )
        )
    }

    func testRoutesNaturalLanguageAlarmWithPurposeAfterTime() {
        XCTAssertEqual(
            router.route("20분 뒤에 약 먹으라고 알려줘"),
            .setAlarm(
                request: .afterMinutes(20),
                label: "약 먹기",
                message: "약 드실 시간입니다.",
                delivery: .jarvisVoice
            )
        )
    }

    func testPreservesUnrecognizedAlarmPurpose() {
        XCTAssertEqual(
            router.route("치과 서류 챙겨야 하니까 15분 뒤에 알려줘"),
            .setAlarm(
                request: .afterMinutes(15),
                label: "치과 서류 챙겨야",
                message: "치과 서류 챙겨야 알림입니다.",
                delivery: .jarvisVoice
            )
        )
    }

    func testRoutesOneHourRelativeAlarm() {
        XCTAssertEqual(
            router.route("한 시간 뒤에 출발한다고 알려줘"),
            .setAlarm(
                request: .afterMinutes(60),
                label: "출발하기",
                message: "출발하실 시간입니다.",
                delivery: .jarvisVoice
            )
        )
    }

    func testRoutesHoursAndMinutesAfterReminder() {
        XCTAssertEqual(
            router.route("1시간 30분 이후에 약 먹으라고 알려줘"),
            .setAlarm(
                request: .afterMinutes(90),
                label: "약 먹기",
                message: "약 드실 시간입니다.",
                delivery: .jarvisVoice
            )
        )
    }

    func testRoutesMinutesAfterSystemAlarm() {
        XCTAssertEqual(
            router.route("25분 이후에 스트레칭하라고 알람 맞춰줘"),
            .setAlarm(
                request: .afterMinutes(25),
                label: "스트레칭하기",
                message: "스트레칭하실 시간입니다.",
                delivery: .system
            )
        )
    }

    func testRoutesAlarmWithExactQuotedMessage() {
        XCTAssertEqual(
            router.route("5분 뒤에 ‘오븐을 확인하세요’라고 알려줘"),
            .setAlarm(
                request: .afterMinutes(5),
                label: "오븐을 확인",
                message: "오븐을 확인하세요.",
                delivery: .jarvisVoice
            )
        )
    }

    func testRoutesKoreanNumberAlarm() {
        XCTAssertEqual(
            router.route("세 분 뒤에 스트레칭하라고 알려줘"),
            .setAlarm(
                request: .afterMinutes(3),
                label: "스트레칭하기",
                message: "스트레칭하실 시간입니다.",
                delivery: .jarvisVoice
            )
        )
    }

    func testRoutesHalfPastAlarmWithPurpose() {
        XCTAssertEqual(
            router.route("회의 들어가야 해서 내일 오후 두 시 반에 알람 맞춰줘"),
            .setAlarm(
                request: .atTime(hour: 2, minute: 30, period: .pm, day: .tomorrow),
                label: "회의 들어가기",
                message: "회의 들어가실 시간입니다.",
                delivery: .system
            )
        )
    }

    func testRoutesNaturalDoThisLaterAsJarvisVoiceReminder() {
        XCTAssertEqual(
            router.route("10분 뒤에 불 끄라고 해줘"),
            .setAlarm(
                request: .afterMinutes(10),
                label: "불 끄기",
                message: "불 끄실 시간입니다.",
                delivery: .jarvisVoice
            )
        )
    }

    func testRoutesExplicitNotificationSetupAsSystemAlarm() {
        XCTAssertEqual(
            router.route("10분 뒤에 일어나라고 알림 맞춰줘"),
            .setAlarm(
                request: .afterMinutes(10),
                label: "일어나기",
                message: "일어나실 시간입니다.",
                delivery: .system
            )
        )
    }

    func testRoutesAlarmList() {
        XCTAssertEqual(router.route("내 알람 보여줘"), .listAlarms(.all))
        XCTAssertEqual(router.route("다음 알람이 언제야?"), .listAlarms(.next))
        XCTAssertEqual(router.route("설정된 알람 확인해줘"), .listAlarms(.all))
    }

    func testRoutesAlarmCancellation() {
        XCTAssertEqual(router.route("방금 맞춘 알람 취소해줘"), .cancelAlarm(.latest))
        XCTAssertEqual(router.route("모든 알람 삭제해줘"), .cancelAlarm(.all))
    }

    func testRoutesActiveAlarmStop() {
        XCTAssertEqual(router.route("알람 꺼줘"), .stopActiveAlarm)
        XCTAssertEqual(router.route("알림 멈춰줘"), .stopActiveAlarm)
        XCTAssertEqual(router.route("현재 울리는 알람 중지해줘"), .stopActiveAlarm)
        XCTAssertEqual(router.route("지금 울리는 타이머 정지해"), .stopActiveAlarm)
    }

    func testRoutesNamedAlarmCancellation() {
        XCTAssertEqual(router.route("라면 알람 취소해줘"), .cancelAlarm(.named("라면")))
    }

    func testRoutesAlarmTimeUpdate() {
        XCTAssertEqual(
            router.route("운동 알람을 오전 8시로 바꿔줘"),
            .updateAlarm(
                query: .named("운동"),
                update: AlarmUpdate(
                    request: .atTime(hour: 8, minute: 0, period: .am, day: .automatic)
                )
            )
        )
    }

    func testRoutesAlarmUpdateWithOldAndNewTimes() {
        XCTAssertEqual(
            router.route("오후 2시 알람을 오후 3시로 미뤄줘"),
            .updateAlarm(
                query: .atTime(.atTime(hour: 2, minute: 0, period: .pm, day: .automatic)),
                update: AlarmUpdate(
                    request: .atTime(hour: 3, minute: 0, period: .pm, day: .automatic)
                )
            )
        )
    }

    func testRoutesLatestAlarmRelativeUpdate() {
        XCTAssertEqual(
            router.route("방금 맞춘 알람을 10분 뒤로 변경해줘"),
            .updateAlarm(
                query: .latest,
                update: AlarmUpdate(request: .afterMinutes(10))
            )
        )
    }

    func testRoutesAlarmLabelUpdate() {
        XCTAssertEqual(
            router.route("라면 알람 이름을 가스 끄기로 바꿔줘"),
            .updateAlarm(
                query: .named("라면"),
                update: AlarmUpdate(label: "가스 끄기")
            )
        )
    }

    func testRoutesAlarmCancellationByTime() {
        XCTAssertEqual(
            router.route("오후 2시 알람 삭제해줘"),
            .cancelAlarm(.atTime(.atTime(
                hour: 2,
                minute: 0,
                period: .pm,
                day: .automatic
            )))
        )
    }

    func testRoutesYouTubeCommand() {
        XCTAssertEqual(
            router.route("자비스야 유튜브에서 아이유 밤편지 틀어줘"),
            .playYouTube(query: "아이유 밤편지")
        )
        XCTAssertEqual(
            router.route("혹시 유튜브에서 체념 좀 들려줄래"),
            .playYouTube(query: "체념")
        )
    }

    func testRoutesEnglishYouTubeWithSpacedKoreanParticle() {
        XCTAssertEqual(
            router.route("YouTube 에서 못해 틀어 줘"),
            .playYouTube(query: "못해")
        )
    }

    func testRoutesSpacedEnglishYouTubeName() {
        XCTAssertEqual(
            router.route("You Tube에서 아이유 밤편지 재생해줘"),
            .playYouTube(query: "아이유 밤편지")
        )
    }

    func testRoutesSavedYouTubePlaylist() {
        XCTAssertEqual(
            router.route("유튜브에서 운동 재생목록 틀어줘"),
            .playYouTubePlaylist(name: "운동")
        )
        XCTAssertEqual(
            router.route("내 운동 플레이리스트 시작해줘"),
            .playYouTubePlaylist(name: "운동")
        )
    }

    func testRoutesSavedYouTubePlaylistWithoutYouTubePrefix() {
        XCTAssertEqual(
            router.route("내가 저장한 출근 플레이리스트 재생해줘"),
            .playYouTubePlaylist(name: "출근")
        )
    }

    func testRoutesUnnamedPlaylistToUnknownCommand() {
        XCTAssertEqual(
            router.route("내 재생목록 틀어줘"),
            .unknownCommand(text: "내 재생목록 틀어줘")
        )
    }

    func testRoutesAppOpenCommand() {
        XCTAssertEqual(
            router.route("자비스야 카카오톡 열어줘"),
            .openApp(name: "카카오톡")
        )
    }

    func testRoutesAppRunCommand() {
        XCTAssertEqual(
            router.route("인스타그램 앱을 실행해 줘"),
            .openApp(name: "인스타그램")
        )
        XCTAssertEqual(router.route("카카오톡 좀 띄워줄래"), .openApp(name: "카카오톡"))
    }

    func testRoutesCurrentBriefingCommand() {
        XCTAssertEqual(
            router.route("자비스야 현재 브리핑 실행해줘"),
            .fullBriefing
        )
    }

    func testRoutesCombinedWeatherAndScheduleToFullBriefing() {
        XCTAssertEqual(
            router.route("날씨와 일정 모두 알려줘"),
            .fullBriefing
        )
    }

    func testRoutesWeatherQuestionToWeatherSummary() {
        XCTAssertEqual(
            router.route("오늘 날씨 알려줘"),
            .weather(.todaySummary)
        )
        XCTAssertEqual(router.route("오늘 밖에 어때?"), .weather(.todaySummary))
        XCTAssertEqual(router.route("오늘 추워?"), .weather(.todaySummary))
    }

    func testRoutesNearbyRestaurantRecommendation() {
        XCTAssertEqual(
            router.route("근처 맛집 추천해줘"),
            .recommendRestaurants(query: nil)
        )
        XCTAssertEqual(router.route("이 근처에서 뭐 먹지?"), .recommendRestaurants(query: nil))
        XCTAssertEqual(router.route("주변에 밥 먹을 데 알려줘"), .recommendRestaurants(query: nil))
    }

    func testRoutesNaturalPopularityRestaurantRequest() {
        XCTAssertEqual(
            router.route("현재 위치를 기반으로 해서 가장 인기, 평가가 좋은 음식집을 추천해줘"),
            .recommendRestaurants(query: nil)
        )
    }

    func testRoutesDifferentRestaurantFollowUp() {
        XCTAssertEqual(
            router.route("다른 집 추천해줘", previousIntent: .recommendRestaurants(query: "한식")),
            .recommendRestaurants(query: "한식")
        )
    }

    func testRoutesCuisineRestaurantRecommendation() {
        XCTAssertEqual(
            router.route("현재 위치에서 평점 좋은 한식 맛집 추천해줘"),
            .recommendRestaurants(query: "한식")
        )
    }

    func testRoutesNearbySushiRestaurantRecommendation() {
        XCTAssertEqual(
            router.route("가까운 초밥집 찾아줘"),
            .recommendRestaurants(query: "초밥집")
        )
    }

    func testRoutesNavigationRequestFromCurrentLocation() {
        XCTAssertEqual(
            router.route("현재 위치에서 강남역까지 가는 방법을 알려줘"),
            .navigate(destination: "강남역", mode: .publicTransit)
        )
        XCTAssertEqual(
            router.route("잠실역 길 안내해줘"),
            .navigate(destination: "잠실역", mode: .publicTransit)
        )
        XCTAssertEqual(
            router.route("강남역으로 안내 부탁해"),
            .navigate(destination: "강남역", mode: .publicTransit)
        )
        XCTAssertEqual(
            router.route("강남역 안내 부탁드립니다"),
            .navigate(destination: "강남역", mode: .publicTransit)
        )
        XCTAssertEqual(
            router.route("강남역 역으로 대중교통 안내해줘"),
            .navigate(destination: "강남역", mode: .publicTransit)
        )
    }

    func testRoutesNavigationWithExplicitTravelMode() {
        XCTAssertEqual(
            router.route("서울역까지 차로 길 안내해줘"),
            .navigate(destination: "서울역", mode: .car)
        )
        XCTAssertEqual(
            router.route("광화문으로 대중교통 안내해줘"),
            .navigate(destination: "광화문", mode: .publicTransit)
        )
    }

    func testRoutesNavigationModeFollowUp() {
        XCTAssertEqual(
            router.route(
                "지하철로 갈게",
                previousIntent: .navigate(destination: "강남역", mode: nil)
            ),
            .navigate(destination: "강남역", mode: .publicTransit)
        )
    }

    func testExplicitNavigationDestinationOverridesPreviousNavigationContext() {
        XCTAssertEqual(
            router.route(
                "하이디 라우까지 자가용으로 안내해줘",
                previousIntent: .navigate(destination: "강남역", mode: .publicTransit)
            ),
            .navigate(destination: "하이디 라우", mode: .car)
        )
        XCTAssertEqual(
            router.route("하이디 라오까지 자가용으로 안내해줘"),
            .navigate(destination: "하이디 라오", mode: .car)
        )
    }

    func testTravelModeOnlyNavigationStillUsesPreviousDestination() {
        XCTAssertEqual(
            router.route(
                "자가용으로 안내해줘",
                previousIntent: .navigate(destination: "강남역", mode: .publicTransit)
            ),
            .navigate(destination: "강남역", mode: .car)
        )
    }

    func testExplicitAppTargetOverridesPreviousAppContext() {
        XCTAssertEqual(
            router.route(
                "인스타그램 다시 열어줘",
                previousIntent: .openApp(name: "카카오톡")
            ),
            .openApp(name: "인스타그램")
        )
        XCTAssertEqual(
            router.route("다시 열어줘", previousIntent: .openApp(name: "카카오톡")),
            .openApp(name: "카카오톡")
        )
    }

    func testExplicitWebQueryOverridesPreviousWebSearchContext() {
        XCTAssertEqual(
            router.route(
                "인터넷에서 최신 아이폰 정보를 검색해줘",
                previousIntent: .webSearch(query: "서울 날씨")
            ),
            .webSearch(query: "최신 아이폰 정보를")
        )
    }

    func testRoutesRestaurantAppToAppOpen() {
        XCTAssertEqual(
            router.route("맛집 앱 열어줘"),
            .openApp(name: "맛집")
        )
    }

    func testRoutesWeatherBriefingToWeatherOnly() {
        XCTAssertEqual(
            router.route("날씨 브리핑해줘"),
            .weather(.todaySummary)
        )
    }

    func testRoutesTemperatureQuestionToCurrentTemperature() {
        XCTAssertEqual(
            router.route("현재 기온 말해줘"),
            .weather(.currentTemperature)
        )
        XCTAssertEqual(router.route("지금 밖 온도가 어떻게 돼?"), .weather(.currentTemperature))
    }

    func testRoutesHighTemperatureQuestion() {
        XCTAssertEqual(
            router.route("오늘 최고 기온 알려줘"),
            .weather(.highTemperature)
        )
    }

    func testRoutesLowTemperatureQuestion() {
        XCTAssertEqual(
            router.route("오늘 최저 기온 알려줘"),
            .weather(.lowTemperature)
        )
    }

    func testRoutesTemperatureRangeQuestion() {
        XCTAssertEqual(
            router.route("오늘 일교차 알려줘"),
            .weather(.temperatureRange)
        )
    }

    func testRoutesPrecipitationQuestion() {
        XCTAssertEqual(
            router.route("오늘 비 올 확률 알려줘"),
            .weather(.precipitationProbability)
        )
        XCTAssertEqual(router.route("오늘 비 오니?"), .weather(.precipitationProbability))
    }

    func testRoutesUmbrellaQuestionToUmbrellaAdvice() {
        XCTAssertEqual(
            router.route("오늘 우산 필요할까"),
            .weather(.umbrellaAdvice)
        )
    }

    func testRoutesCalendarQuestionToTodaySummary() {
        XCTAssertEqual(
            router.route("오늘 캘린더 일정 확인해줘"),
            .calendar(.todaySummary)
        )
        XCTAssertEqual(router.route("오늘 뭐가 있어?"), .calendar(.todaySummary))
        XCTAssertEqual(router.route("오늘 해야 할 일 알려줘"), .calendar(.todaySummary))
    }

    func testRoutesRemainingScheduleQuestion() {
        XCTAssertEqual(
            router.route("오늘 남은 일정 알려줘"),
            .calendar(.remainingToday)
        )
    }

    func testRoutesNextEventQuestion() {
        XCTAssertEqual(
            router.route("다음 일정 알려줘"),
            .calendar(.nextEvent)
        )
    }

    func testRoutesEventCountQuestion() {
        XCTAssertEqual(
            router.route("오늘 일정 몇 개야"),
            .calendar(.eventCount)
        )
    }

    func testRoutesCurrentTimeQuestion() {
        XCTAssertEqual(
            router.route("지금 몇 시야"),
            .time(.currentTime)
        )
        XCTAssertEqual(router.route("현재 몇 시지?"), .time(.currentTime))
        XCTAssertEqual(router.route("지금 시간이 어떻게 돼?"), .time(.currentTime))
    }

    func testRoutesTodayDateQuestion() {
        XCTAssertEqual(
            router.route("오늘 며칠이야"),
            .time(.todayDate)
        )
        XCTAssertEqual(router.route("오늘이 몇 일이야?"), .time(.todayDate))
    }

    func testRoutesCurrentDateAndTimeQuestion() {
        XCTAssertEqual(
            router.route("지금 날짜와 시간 알려줘"),
            .time(.currentDateAndTime)
        )
    }

    func testRoutesWeatherVideoToYouTube() {
        XCTAssertEqual(
            router.route("유튜브에서 오늘 날씨 영상 틀어줘"),
            .playYouTube(query: "오늘 날씨 영상")
        )
    }

    func testRoutesWeatherAppToAppOpen() {
        XCTAssertEqual(
            router.route("날씨 앱 열어줘"),
            .openApp(name: "날씨")
        )
    }

    func testRoutesCapabilityQuestion() {
        XCTAssertEqual(
            router.route("자비스 무엇을 할 수 있어?"),
            .assistantCapabilities
        )
        XCTAssertEqual(router.route("어떤 기능이 있어?"), .assistantCapabilities)
        XCTAssertEqual(router.route("너는 뭘 할 줄 알아?"), .assistantCapabilities)
    }

    func testRoutesInternetSearchRequest() {
        XCTAssertEqual(
            router.route("인터넷에 아이폰 17 프로 스펙을 검색해서 알려줘"),
            .webSearch(query: "아이폰 17 프로 스펙을")
        )
        XCTAssertEqual(
            router.route("웹에서 오늘의 AI 뉴스를 찾아줘"),
            .webSearch(query: "오늘의 ai 뉴스를")
        )
        XCTAssertEqual(
            router.route("구글로 서울 내일 축제 검색해줘"),
            .webSearch(query: "서울 내일 축제")
        )
    }

    func testRoutesFreshInformationQuestionToWebSearch() {
        XCTAssertEqual(
            router.route("최신 AI 뉴스 알려줘"),
            .webSearch(query: "최신 AI 뉴스 알려줘")
        )
    }

    func testDeterministicWeatherRouteWinsOverFreshInformationSearch() {
        XCTAssertEqual(
            router.route("실시간 날씨 알려줘"),
            .weather(.todaySummary)
        )
    }

    func testInternetSearchWithoutQueryIsUnknown() {
        XCTAssertEqual(
            router.route("인터넷에서 검색해줘"),
            .unknownCommand(text: "인터넷에서 검색해줘")
        )
    }

    func testRoutesWeatherFollowUpUsingPreviousIntent() {
        XCTAssertEqual(
            router.route("그럼 최저는?", previousIntent: .weather(.todaySummary)),
            .weather(.lowTemperature)
        )
    }

    func testRoutesCalendarFollowUpUsingPreviousIntent() {
        XCTAssertEqual(
            router.route("그럼 다음은?", previousIntent: .calendar(.todaySummary)),
            .calendar(.nextEvent)
        )
    }

    func testRoutesBriefingFollowUpToCalendar() {
        XCTAssertEqual(
            router.route("남은 일정은?", previousIntent: .fullBriefing),
            .calendar(.remainingToday)
        )
    }

    func testRoutesRepeatYouTubeFollowUp() {
        XCTAssertEqual(
            router.route("다시 틀어줘", previousIntent: .playYouTube(query: "체념")),
            .playYouTube(query: "체념")
        )
    }

    func testRoutesRepeatYouTubePlaylistFollowUp() {
        XCTAssertEqual(
            router.route("다시 틀어줘", previousIntent: .playYouTubePlaylist(name: "운동")),
            .playYouTubePlaylist(name: "운동")
        )
    }

    func testRoutesRepeatAppFollowUp() {
        XCTAssertEqual(
            router.route("다시 열어줘", previousIntent: .openApp(name: "카카오톡")),
            .openApp(name: "카카오톡")
        )
    }

    func testRoutesIncompleteActionToUnknownCommand() {
        XCTAssertEqual(
            router.route("틀어줘"),
            .unknownCommand(text: "틀어줘")
        )
    }

    func testRoutesContactCall() {
        XCTAssertEqual(
            router.route("자비스야 민수한테 전화해줘"),
            .call(recipient: "민수", speakerRequested: false)
        )
        XCTAssertEqual(
            router.route("엄마에게 전화 좀 걸어줄래"),
            .call(recipient: "엄마", speakerRequested: false)
        )
    }

    func testRoutesSpeakerphoneCallRequest() {
        XCTAssertEqual(
            router.route("엄마한테 (스피커폰으로) 전화 걸어줘"),
            .call(recipient: "엄마", speakerRequested: true)
        )
    }

    func testRoutesPhoneNumberCall() {
        XCTAssertEqual(
            router.route("010-1234-5678로 전화해줘"),
            .call(recipient: "010-1234-5678", speakerRequested: false)
        )
    }

    func testRemovesMobilePhoneQualifierFromContactCall() {
        XCTAssertEqual(
            router.route("김민수 휴대폰으로 전화해줘"),
            .call(recipient: "김민수", speakerRequested: false)
        )
    }

    func testRoutesUnknownTextToConversation() {
        XCTAssertEqual(
            router.route("오늘 뭐 하고 싶어?"),
            .generalConversation(text: "오늘 뭐 하고 싶어?")
        )
    }

    func testDetectsSpacedWakeWord() {
        XCTAssertTrue(router.containsWakeWord("자 비스야"))
    }

    func testDoesNotDetectUnrelatedText() {
        XCTAssertFalse(router.containsWakeWord("지금 몇 시야"))
    }
}
