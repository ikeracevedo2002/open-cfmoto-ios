import CoreLocation
import Foundation

struct RouteCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct RouteLane: Codable, Equatable {
    let valid: Bool
    let indications: [String]
}

struct RouteStep: Codable, Equatable {
    let maneuverType: String
    let modifier: String?
    let roadName: String
    let maneuver: RouteCoordinate
    let distanceMeters: Double
    let exit: Int?
    let lanes: [RouteLane]?

    var instruction: String {
        let direction = modifier?.replacingOccurrences(of: "-", with: " ") ?? ""
        switch maneuverType {
        case "depart": return roadName.isEmpty ? "Start navigation" : "Take (roadName)"
        case "arrive": return "You have arrived"
        case "gpx": return "Follow the imported GPX route"
        case "roundabout", "rotary":
            if let exit { return "Take exit (exit) at the roundabout" }
            return "Enter the roundabout"
        case "merge": return roadName.isEmpty ? "Merge (direction)" : "Merge (direction) onto (roadName)"
        case "fork": return roadName.isEmpty ? "Keep (direction) at the fork" : "Keep (direction) onto (roadName)"
        case "turn", "on ramp", "off ramp", "new name":
            if roadName.isEmpty { return "Turn (direction)" }
            return "Turn (direction) onto (roadName)"
        default:
            return roadName.isEmpty ? "Continue ahead" : "Continue on (roadName)"
        }
    }
}

struct NavigationRoute: Equatable {
    let points: [RouteCoordinate]
    let distanceMeters: Double
    let durationSeconds: Double
    let steps: [RouteStep]
    let label: String

    var firstInstruction: String {
        steps.first(where: { $0.maneuverType != "depart" })?.instruction
            ?? steps.first?.instruction
            ?? "Continue on the highlighted route"
    }
}

protocol RouteEngine {
    func routes(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        alternatives: Int
    ) async throws -> [NavigationRoute]
}

final class OSRMRouteEngine: RouteEngine {
    private let session: URLSession
    private let baseURL = URL(string: "https://router.project-osrm.org/route/v1/driving")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func routes(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        alternatives: Int = 3
    ) async throws -> [NavigationRoute] {
        let coordinates = "\(from.longitude),\(from.latitude);\(to.longitude),\(to.latitude)"
        var components = URLComponents(url: baseURL.appendingPathComponent(coordinates), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "alternatives", value: alternatives > 0 ? "true" : "false"),
        ]
        guard let url = components?.url else { throw RouteEngineError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("OpenCFMoto-iOS/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RouteEngineError.httpFailure
        }
        let decoded = try JSONDecoder().decode(OSRMResponse.self, from: data)
        guard decoded.code == "Ok", !decoded.routes.isEmpty else {
            throw RouteEngineError.noRoute
        }
        return decoded.routes.compactMap { NavigationRoute(osrm: $0) }
    }
}

private struct OSRMResponse: Decodable {
    let code: String
    let routes: [OSRMRoute]
}

private struct OSRMRoute: Decodable {
    let geometry: OSRMGeometry
    let distance: Double
    let duration: Double
    let legs: [OSRMLeg]
}

private struct OSRMGeometry: Decodable {
    let coordinates: [[Double]]
}

private struct OSRMLeg: Decodable {
    let steps: [OSRMStep]
}

private struct OSRMStep: Decodable {
    let distance: Double
    let name: String
    let maneuver: OSRMManeuver
    let intersections: [OSRMIntersection]?
}

private struct OSRMManeuver: Decodable {
    let type: String
    let modifier: String?
    let location: [Double]
    let exit: Int?
}

private struct OSRMIntersection: Decodable {
    let lanes: [OSRMLane]?
}

private struct OSRMLane: Decodable {
    let valid: Bool?
    let indications: [String]?
}

private extension NavigationRoute {
    init?(osrm: OSRMRoute, label: String = "") {
        let points = osrm.geometry.coordinates.compactMap { pair -> RouteCoordinate? in
            guard pair.count >= 2 else { return nil }
            return RouteCoordinate(latitude: pair[1], longitude: pair[0])
        }
        guard points.count >= 2 else { return nil }
        let steps = osrm.legs.flatMap(\.steps).compactMap { step -> RouteStep? in
            guard step.maneuver.location.count >= 2 else { return nil }
            let lanes = step.intersections?.compactMap(\.lanes).first?.map {
                RouteLane(valid: $0.valid ?? false, indications: $0.indications ?? [])
            }
            return RouteStep(
                maneuverType: step.maneuver.type,
                modifier: step.maneuver.modifier,
                roadName: step.name,
                maneuver: RouteCoordinate(
                    latitude: step.maneuver.location[1],
                    longitude: step.maneuver.location[0]
                ),
                distanceMeters: step.distance,
                exit: step.maneuver.exit,
                lanes: lanes
            )
        }
        self.init(
            points: points,
            distanceMeters: osrm.distance,
            durationSeconds: osrm.duration,
            steps: steps,
            label: label
        )
    }
}

enum RouteEngineError: LocalizedError {
    case invalidURL
    case httpFailure
    case noRoute

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The route URL is invalid"
        case .httpFailure: return "The route service could not be reached"
        case .noRoute: return "No driving route was found"
        }
    }
}
