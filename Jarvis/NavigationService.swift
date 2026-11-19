import CoreLocation
import Foundation
import MapKit
import UIKit

@MainActor
protocol NavigationServing {
    func search(destination: String) async throws -> [NavigationSearchCandidate]
    func nearby(category: NearbyPlaceCategory) async -> ToolExecutionResult<[NearbyPlace]>
    func isNaverMapInstalled() -> Bool
    func open(_ route: PreparedNavigation, mode: NavigationTravelMode) async -> ToolExecutionResult<NavigationLaunchResult>
}

struct PreparedNavigation: Sendable {
    let destinationName: String
    let destinationLatitude: Double
    let destinationLongitude: Double
    let sourceLatitude: Double
    let sourceLongitude: Double
    let straightLineDistance: CLLocationDistance

    init(
        destinationName: String,
        destinationLatitude: Double,
        destinationLongitude: Double,
        sourceLatitude: Double,
        sourceLongitude: Double,
        straightLineDistance: CLLocationDistance
    ) {
        self.destinationName = destinationName
        self.destinationLatitude = destinationLatitude
        self.destinationLongitude = destinationLongitude
        self.sourceLatitude = sourceLatitude
        self.sourceLongitude = sourceLongitude
        self.straightLineDistance = straightLineDistance
    }

    init(candidate: NavigationDestinationCandidate) {
        self.init(
            destinationName: candidate.name,
            destinationLatitude: candidate.latitude,
            destinationLongitude: candidate.longitude,
            sourceLatitude: candidate.sourceLatitude,
            sourceLongitude: candidate.sourceLongitude,
            straightLineDistance: candidate.straightLineDistance
        )
    }

    func dialogueCandidate(area: String) -> NavigationDestinationCandidate {
        NavigationDestinationCandidate(
            name: destinationName,
            area: area,
            latitude: destinationLatitude,
            longitude: destinationLongitude,
            sourceLatitude: sourceLatitude,
            sourceLongitude: sourceLongitude,
            straightLineDistance: straightLineDistance
        )
    }
}

struct NavigationSearchCandidate: Sendable {
    let route: PreparedNavigation
    let area: String
}

private struct GooglePlacesNavigationResponse: Decodable {
    struct Place: Decodable {
        struct LocalizedText: Decodable { let text: String }
        struct Coordinate: Decodable {
            let latitude: Double
            let longitude: Double
        }

        let displayName: LocalizedText
        let formattedAddress: String?
        let shortFormattedAddress: String?
        let location: Coordinate?
        let businessStatus: String?
    }

    let places: [Place]?
}

enum NavigationLaunchResult: Equatable, Sendable {
    case naverMap
    case appStore
}

enum NavigationServiceError: LocalizedError {
    case destinationNotFound(String)
    case placeSearchRequiresAPIKey(String)
    case unableToBuildURL
    case unableToOpen

    var errorDescription: String? {
        switch self {
        case .destinationNotFound(let name):
            return "\(name) 위치를 찾지 못했습니다. 지역명이나 정확한 장소명을 함께 말씀해주세요."
        case .placeSearchRequiresAPIKey(let name):
            return "\(name) 지점을 Apple 지도에서 찾지 못했습니다. 설정에 Google Places API 키를 등록하면 여러 지점을 검색할 수 있습니다."
        case .unableToBuildURL:
            return "네이버 지도 길 안내 주소를 만들지 못했습니다."
        case .unableToOpen:
            return "네이버 지도 또는 App Store를 열지 못했습니다."
        }
    }
}

@MainActor
final class NavigationService: NavigationServing {
    private let locationProvider = CurrentLocationProvider()

    func nearby(category: NearbyPlaceCategory) async -> ToolExecutionResult<[NearbyPlace]> {
        do {
            let source = try await locationProvider.currentLocation()
            try Task.checkCancellation()
            if !PlacesAPIKeyStore.load().isEmpty {
                // Reuse the explicitly configured Places key. Failure never
                // becomes a fabricated open/closed status.
                do {
                    let places = try await googleNearby(category: category, source: source)
                    if !places.isEmpty { return .succeeded(places) }
                } catch is CancellationError { throw CancellationError() }
                catch { /* Apple POI search is an independent fallback. */ }
            }
            let poiCategory: MKPointOfInterestCategory
            switch category {
            case .market: poiCategory = .foodMarket
            case .pharmacy: poiCategory = .pharmacy
            case .hospital: poiCategory = .hospital
            case .parking: poiCategory = .parking
            case .cafe: poiCategory = .cafe
            }
            let request = MKLocalPointsOfInterestRequest(center: source.coordinate, radius: 5_000)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [poiCategory])
            let response = try await MKLocalSearch(request: request).start()
            try Task.checkCancellation()
            var seen = Set<String>()
            let places = response.mapItems.compactMap { item -> NearbyPlace? in
                guard let name = item.name, !name.isEmpty else { return nil }
                let coordinate = item.placemark.coordinate
                let distance = source.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                guard distance.isFinite, distance <= 5_000 else { return nil }
                let id = "apple:\(name):\(coordinate.latitude):\(coordinate.longitude)"
                guard seen.insert(id).inserted else { return nil }
                return .init(id: id, name: name, address: item.placemark.title ?? areaDescription(for: item),
                    latitude: coordinate.latitude, longitude: coordinate.longitude,
                    sourceLatitude: source.coordinate.latitude, sourceLongitude: source.coordinate.longitude,
                    distance: distance)
            }.sorted { $0.distance < $1.distance }
            guard !places.isEmpty else { return .unverifiable(message: "주변 5킬로미터에서 해당 장소를 확인하지 못했습니다. 지역명이나 장소명을 말씀해주세요.") }
            return .succeeded(Array(places.prefix(3)))
        } catch {
            if Task.isCancelled || error is CancellationError { return .failed(message: "주변 검색을 취소했습니다.", retryable: false) }
            let denied = (error as? CLError)?.code == .denied
                || (error as? LocalizedError)?.errorDescription?.contains("권한") == true
            if denied { return .needsPermission(message: "주변 장소를 찾으려면 위치 접근을 허용해주세요.") }
            return .failed(message: "주변 장소 검색에 연결하지 못했습니다. 위치 설정과 인터넷 연결을 확인해주세요.", retryable: true)
        }
    }

    private func googleNearby(category: NearbyPlaceCategory, source: CLLocation) async throws -> [NearbyPlace] {
        struct Response: Decodable {
            struct Place: Decodable {
                struct Text: Decodable { let text: String }
                struct Coordinate: Decodable { let latitude: Double; let longitude: Double }
                struct Hours: Decodable { let openNow: Bool? }
                let id: String; let displayName: Text; let formattedAddress: String?
                let location: Coordinate; let currentOpeningHours: Hours?; let businessStatus: String?
            }
            let places: [Place]?
        }
        let type: String
        switch category {
        case .market: type = "supermarket"
        case .pharmacy: type = "pharmacy"
        case .hospital: type = "hospital"
        case .parking: type = "parking"
        case .cafe: type = "cafe"
        }
        var request = URLRequest(url: URL(string: "https://places.googleapis.com/v1/places:searchNearby")!)
        request.httpMethod = "POST"; request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(PlacesAPIKeyStore.load(), forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(Bundle.main.bundleIdentifier ?? "com.minhyuc.jarvis", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.setValue("places.id,places.displayName,places.formattedAddress,places.location,places.currentOpeningHours,places.businessStatus", forHTTPHeaderField: "X-Goog-FieldMask")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "includedTypes": [type], "maxResultCount": 5, "rankPreference": "DISTANCE", "languageCode": "ko",
            "locationRestriction": ["circle": ["center": ["latitude": source.coordinate.latitude, "longitude": source.coordinate.longitude], "radius": 5_000]]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        var seen = Set<String>()
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return Array((decoded.places ?? []).compactMap { place -> NearbyPlace? in
            guard place.businessStatus != "CLOSED_PERMANENTLY", place.businessStatus != "CLOSED_TEMPORARILY",
                  CLLocationCoordinate2DIsValid(.init(latitude: place.location.latitude, longitude: place.location.longitude)),
                  seen.insert(place.id).inserted else { return nil }
            let distance = source.distance(from: CLLocation(latitude: place.location.latitude, longitude: place.location.longitude))
            guard distance <= 5_000 else { return nil }
            return .init(id: "google:\(place.id)", name: place.displayName.text, address: place.formattedAddress ?? "주소 확인 불가",
                latitude: place.location.latitude, longitude: place.location.longitude,
                sourceLatitude: source.coordinate.latitude, sourceLongitude: source.coordinate.longitude,
                distance: distance, openNow: place.currentOpeningHours?.openNow)
        }.sorted { $0.distance < $1.distance }.prefix(3))
    }

    func prepare(destination rawDestination: String) async throws -> PreparedNavigation {
        guard let first = try await search(destination: rawDestination).first else {
            throw NavigationServiceError.destinationNotFound(rawDestination)
        }
        return first.route
    }

    func search(destination rawDestination: String) async throws -> [NavigationSearchCandidate] {
        // Revalidate at the external-tool boundary even when the command router
        // or semantic registry has already normalized the destination.
        let normalizer = NavigationDestinationNormalizer()
        let destination = normalizer.normalize(rawDestination)
        guard !destination.isEmpty else {
            throw NavigationServiceError.destinationNotFound(rawDestination)
        }

        let source = try await locationProvider.currentLocation()
        var mapItems: [MKMapItem] = []
        for query in normalizer.searchQueries(for: destination) {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = [.pointOfInterest, .address]
            request.region = MKCoordinateRegion(
                center: source.coordinate,
                latitudinalMeters: 100_000,
                longitudinalMeters: 100_000
            )
            do {
                let response = try await MKLocalSearch(request: request).start()
                mapItems.append(contentsOf: response.mapItems)
            } catch {
                // Continue to the compact query and Google Places fallback.
                continue
            }
        }

        var seen = Set<String>()
        var candidates: [NavigationSearchCandidate] = []
        for item in mapItems {
            let coordinate = item.placemark.coordinate
            let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = name.flatMap { $0.isEmpty ? nil : $0 } ?? destination
            guard normalizer.isPlausibleMatch(
                query: destination,
                candidate: resolvedName
            ) else {
                continue
            }
            let area = areaDescription(for: item)
            let key = [
                resolvedName.lowercased(),
                area.lowercased(),
                String(format: "%.4f", coordinate.latitude),
                String(format: "%.4f", coordinate.longitude)
            ].joined(separator: "|")
            guard seen.insert(key).inserted else { continue }

            let target = CLLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            candidates.append(NavigationSearchCandidate(
                route: PreparedNavigation(
                    destinationName: resolvedName,
                    destinationLatitude: coordinate.latitude,
                    destinationLongitude: coordinate.longitude,
                    sourceLatitude: source.coordinate.latitude,
                    sourceLongitude: source.coordinate.longitude,
                    straightLineDistance: source.distance(from: target)
                ),
                area: area
            ))
            if candidates.count == 5 { break }
        }

        // Apple Maps does not contain every Korean business available in
        // Naver Map. The existing Places key supplies POI candidates and exact
        // coordinates so JARVIS can ask which branch the user means.
        if candidates.count < 2, !PlacesAPIKeyStore.load().isEmpty {
            let googleCandidates = (try? await searchGooglePlaces(
                destination: destination,
                source: source,
                normalizer: normalizer
            )) ?? []
            for candidate in googleCandidates {
                let key = [
                    candidate.route.destinationName.lowercased(),
                    candidate.area.lowercased(),
                    String(format: "%.4f", candidate.route.destinationLatitude),
                    String(format: "%.4f", candidate.route.destinationLongitude)
                ].joined(separator: "|")
                guard seen.insert(key).inserted else { continue }
                candidates.append(candidate)
                if candidates.count == 5 { break }
            }
        }

        if candidates.isEmpty, PlacesAPIKeyStore.load().isEmpty {
            throw NavigationServiceError.placeSearchRequiresAPIKey(destination)
        }
        guard !candidates.isEmpty else {
            throw NavigationServiceError.destinationNotFound(destination)
        }
        return candidates
    }

    private func searchGooglePlaces(
        destination: String,
        source: CLLocation,
        normalizer: NavigationDestinationNormalizer
    ) async throws -> [NavigationSearchCandidate] {
        guard let url = URL(string: "https://places.googleapis.com/v1/places:searchText") else {
            return []
        }
        let apiKey = PlacesAPIKeyStore.load()
        guard !apiKey.isEmpty else { return [] }

        var collected: [GooglePlacesNavigationResponse.Place] = []
        for query in normalizer.searchQueries(for: destination) {
            let body: [String: Any] = [
                "textQuery": query,
                "pageSize": 10,
                "languageCode": "ko",
                "regionCode": "KR",
                "locationBias": [
                    "circle": [
                        "center": [
                            "latitude": source.coordinate.latitude,
                            "longitude": source.coordinate.longitude
                        ],
                        // Places Text Search accepts a circle radius of at
                        // most 50 km. A larger value makes the whole fallback
                        // request fail with HTTP 400.
                        "radius": 50_000.0
                    ]
                ]
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 12
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
            request.setValue(
                "places.displayName,places.formattedAddress,places.shortFormattedAddress,places.location,places.businessStatus",
                forHTTPHeaderField: "X-Goog-FieldMask"
            )
            if let bundleIdentifier = Bundle.main.bundleIdentifier {
                request.setValue(bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                continue
            }
            let decoded = try JSONDecoder().decode(
                GooglePlacesNavigationResponse.self,
                from: data
            )
            collected.append(contentsOf: decoded.places ?? [])
            if collected.count >= 10 { break }
        }

        var seen = Set<String>()
        return collected.compactMap { place in
            guard place.businessStatus != "CLOSED_PERMANENTLY",
                  let coordinate = place.location,
                  normalizer.isPlausibleMatch(
                      query: destination,
                      candidate: place.displayName.text
                  ) else {
                return nil
            }
            let key = [
                place.displayName.text.lowercased(),
                String(format: "%.4f", coordinate.latitude),
                String(format: "%.4f", coordinate.longitude)
            ].joined(separator: "|")
            guard seen.insert(key).inserted else { return nil }

            let target = CLLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            return NavigationSearchCandidate(
                route: PreparedNavigation(
                    destinationName: place.displayName.text,
                    destinationLatitude: coordinate.latitude,
                    destinationLongitude: coordinate.longitude,
                    sourceLatitude: source.coordinate.latitude,
                    sourceLongitude: source.coordinate.longitude,
                    straightLineDistance: source.distance(from: target)
                ),
                area: place.shortFormattedAddress
                    ?? place.formattedAddress
                    ?? "지역 정보 없음"
            )
        }
    }

    private func areaDescription(for item: MKMapItem) -> String {
        let placemark = item.placemark
        var components: [String] = []
        for value in [placemark.administrativeArea, placemark.locality, placemark.subLocality] {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !components.contains(value) else { continue }
            components.append(value)
        }
        return components.isEmpty ? "지역 정보 없음" : components.joined(separator: " ")
    }

    func distanceDescription(for route: PreparedNavigation) -> String {
        if route.straightLineDistance < 1_000 {
            let meters = Int((route.straightLineDistance / 50).rounded() * 50)
            return "약 \(max(50, meters))미터"
        }
        let kilometers = route.straightLineDistance / 1_000
        return String(format: "약 %.1f킬로미터", kilometers)
    }

    func isNaverMapInstalled() -> Bool {
        guard let url = URL(string: "nmap://map?appname=com.minhyuc.jarvis") else {
            return false
        }
        return UIApplication.shared.canOpenURL(url)
    }

    func open(
        _ route: PreparedNavigation,
        mode: NavigationTravelMode
    ) async -> ToolExecutionResult<NavigationLaunchResult> {
        guard let url = naverMapURL(for: route, mode: mode) else {
            return .failed(
                message: NavigationServiceError.unableToBuildURL.localizedDescription,
                retryable: false
            )
        }

        if UIApplication.shared.canOpenURL(url) {
            guard await UIApplication.shared.open(url) else {
                return .failed(
                    message: NavigationServiceError.unableToOpen.localizedDescription,
                    retryable: true
                )
            }
            return .handedOff(.naverMap)
        }

        guard let appStoreURL = URL(string: "https://itunes.apple.com/app/id311867728?mt=8"),
              await UIApplication.shared.open(appStoreURL) else {
            return .failed(
                message: NavigationServiceError.unableToOpen.localizedDescription,
                retryable: true
            )
        }
        return .handedOff(.appStore)
    }

    private func naverMapURL(
        for route: PreparedNavigation,
        mode: NavigationTravelMode
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "nmap"

        var queryItems: [URLQueryItem]
        switch mode {
        case .car:
            components.host = "navigation"
            queryItems = destinationQueryItems(for: route)

        case .publicTransit:
            components.host = "route"
            components.path = "/public"
            queryItems = [
                URLQueryItem(name: "slat", value: String(route.sourceLatitude)),
                URLQueryItem(name: "slng", value: String(route.sourceLongitude)),
                URLQueryItem(name: "sname", value: "현재 위치")
            ] + destinationQueryItems(for: route)
        }

        queryItems.append(
            URLQueryItem(
                name: "appname",
                value: Bundle.main.bundleIdentifier ?? "com.minhyuc.jarvis"
            )
        )
        components.queryItems = queryItems
        return components.url
    }

    private func destinationQueryItems(for route: PreparedNavigation) -> [URLQueryItem] {
        [
            URLQueryItem(name: "dlat", value: String(route.destinationLatitude)),
            URLQueryItem(name: "dlng", value: String(route.destinationLongitude)),
            URLQueryItem(name: "dname", value: route.destinationName)
        ]
    }
}
