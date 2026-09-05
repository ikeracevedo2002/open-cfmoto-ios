import CoreLocation
import Foundation

struct GPXPoint: Equatable {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let name: String?
}

struct GPXTrack: Equatable {
    let name: String
    let points: [GPXPoint]
    let waypoints: [GPXPoint]

    var route: NavigationRoute? {
        guard points.count >= 2 else { return nil }
        var distance = 0.0
        for pair in zip(points, points.dropFirst()) {
            distance += Self.distanceMeters(from: pair.0, to: pair.1)
        }
        let coordinates = points.map {
            RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        let step = RouteStep(
            maneuverType: "gpx",
            modifier: nil,
            roadName: name,
            maneuver: coordinates[0],
            distanceMeters: distance,
            exit: nil,
            lanes: nil
        )
        return NavigationRoute(
            points: coordinates,
            distanceMeters: distance,
            durationSeconds: distance / (45.0 / 3.6),
            steps: [step],
            label: "GPX"
        )
    }

    private static func distanceMeters(from a: GPXPoint, to b: GPXPoint) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(h), sqrt(max(0, 1 - h)))
    }
}

enum GPXParser {
    static func parse(data: Data, fallbackName: String = "Imported GPX") throws -> GPXTrack {
        let delegate = ParserDelegate(fallbackName: fallbackName)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw GPXParserError.invalidXML(parser.parserError?.localizedDescription ?? "Invalid GPX")
        }
        return GPXTrack(
            name: delegate.name,
            points: delegate.trackPoints.isEmpty ? delegate.routePoints : delegate.trackPoints,
            waypoints: delegate.waypoints
        )
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        let fallbackName: String
        var name: String
        var trackPoints: [GPXPoint] = []
        var routePoints: [GPXPoint] = []
        var waypoints: [GPXPoint] = []

        private var currentKind: String?
        private var currentLatitude: Double?
        private var currentLongitude: Double?
        private var currentElevation: Double?
        private var currentPointName: String?
        private var currentElement: String?
        private var text = ""

        init(fallbackName: String) {
            self.fallbackName = fallbackName
            self.name = fallbackName
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let element = elementName.lowercased()
            if element == "trkpt" || element == "rtept" || element == "wpt" {
                currentKind = element
                currentLatitude = Double(attributeDict["lat"] ?? "")
                currentLongitude = Double(attributeDict["lon"] ?? "")
                currentElevation = nil
                currentPointName = nil
            }
            currentElement = element
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let element = elementName.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if element == "name", currentKind == nil, !value.isEmpty, name == fallbackName {
                name = value
            } else if element == "ele", currentKind != nil {
                currentElevation = Double(value)
            } else if element == "name", currentKind != nil, !value.isEmpty {
                currentPointName = value
            } else if element == currentKind {
                if let latitude = currentLatitude, let longitude = currentLongitude {
                    let point = GPXPoint(
                        latitude: latitude,
                        longitude: longitude,
                        elevation: currentElevation,
                        name: currentPointName
                    )
                    switch currentKind {
                    case "trkpt": trackPoints.append(point)
                    case "rtept": routePoints.append(point)
                    case "wpt": waypoints.append(point)
                    default: break
                    }
                }
                currentKind = nil
            }
            currentElement = nil
            text = ""
        }
    }
}

enum GPXParserError: LocalizedError {
    case invalidXML(String)

    var errorDescription: String? {
        switch self { case .invalidXML(let message): return message }
    }
}
