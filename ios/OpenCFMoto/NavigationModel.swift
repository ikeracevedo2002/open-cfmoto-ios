import CoreGraphics
import CoreLocation
import Combine
import Foundation
import MapKit
import UIKit

struct NavigationProjectionSnapshot {
    let mapImage: CGImage?
    let instruction: String
    let destination: String
    let distance: String
    let duration: String
    let speedKPH: Int
}

final class NavigationProjectionStore: @unchecked Sendable {
    static let shared = NavigationProjectionStore()

    private let lock = NSLock()
    private var value = NavigationProjectionSnapshot(
        mapImage: nil,
        instruction: "Choose a destination on the iPhone",
        destination: "OpenCFMoto Navigation",
        distance: "-- km",
        duration: "-- min",
        speedKPH: 0
    )

    func snapshot() -> NavigationProjectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func updateRoute(
        mapImage: CGImage?,
        instruction: String,
        destination: String,
        distance: String,
        duration: String
    ) {
        lock.lock()
        value = NavigationProjectionSnapshot(
            mapImage: mapImage,
            instruction: instruction,
            destination: destination,
            distance: distance,
            duration: duration,
            speedKPH: value.speedKPH
        )
        lock.unlock()
    }

    func updateSpeed(_ speedKPH: Int) {
        lock.lock()
        value = NavigationProjectionSnapshot(
            mapImage: value.mapImage,
            instruction: value.instruction,
            destination: value.destination,
            distance: value.distance,
            duration: value.duration,
            speedKPH: speedKPH
        )
        lock.unlock()
    }

    func clearRoute() {
        updateRoute(
            mapImage: nil,
            instruction: "Choose a destination on the iPhone",
            destination: "OpenCFMoto Navigation",
            distance: "-- km",
            duration: "-- min"
        )
    }
}

@MainActor
final class NavigationModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var destinationQuery = ""
    @Published private(set) var status = "No route selected"
    @Published private(set) var routeSummary = ""
    @Published private(set) var alternativesCount = 0
    @Published private(set) var isCalculating = false
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let locationManager = CLLocationManager()
    private let projectionStore = NavigationProjectionStore.shared
    private let routeEngine: RouteEngine = OSRMRouteEngine()
    private var currentLocation: CLLocation?
    private var calculateWhenLocationArrives = false
    private var routes: [NavigationRoute] = []
    private var selectedRouteIndex = 0
    private var destinationName = ""

    override init() {
        authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .automotiveNavigation
        locationManager.distanceFilter = 5
    }

    func start() {
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            locationManager.startUpdatingLocation()
        }
    }

    func calculateRoute() {
        let query = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            status = "Enter a destination"
            return
        }
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            status = "Location permission is required"
            calculateWhenLocationArrives = true
            locationManager.requestWhenInUseAuthorization()
            return
        }
        guard let origin = currentLocation ?? locationManager.location else {
            status = "Waiting for current GPS location"
            calculateWhenLocationArrives = true
            locationManager.startUpdatingLocation()
            return
        }

        isCalculating = true
        status = "Searching for \(query)…"
        Task {
            do {
                let searchRequest = MKLocalSearch.Request()
                searchRequest.naturalLanguageQuery = query
                searchRequest.region = MKCoordinateRegion(
                    center: origin.coordinate,
                    latitudinalMeters: 80_000,
                    longitudinalMeters: 80_000
                )
                let searchResponse = try await MKLocalSearch(request: searchRequest).start()
                guard let destination = searchResponse.mapItems.first else {
                    throw NavigationError.destinationNotFound
                }

                let name = destination.name ?? query
                let candidates: [NavigationRoute]
                do {
                    candidates = try await routeEngine.routes(
                        from: origin.coordinate,
                        to: destination.placemark.coordinate,
                        alternatives: 3
                    )
                } catch {
                    // MapKit remains a useful fallback when the phone has no route-service access.
                    status = "OSRM unavailable; using Apple route…"
                    candidates = try await mapKitRoutes(from: origin, to: destination)
                }
                guard let route = candidates.first else { throw NavigationError.routeNotFound }

                routes = candidates
                selectedRouteIndex = 0
                destinationName = name
                alternativesCount = candidates.count
                let image = try await renderMap(points: route.points)
                let instruction = route.firstInstruction
                let distance = Self.distanceFormatter.string(from: Measurement(
                    value: route.distanceMeters,
                    unit: UnitLength.meters
                ))
                let duration = Self.durationFormatter.string(from: route.durationSeconds) ?? "--"

                projectionStore.updateRoute(
                    mapImage: image,
                    instruction: instruction,
                    destination: name,
                    distance: distance,
                    duration: duration
                )
                routeSummary = "\(distance) • \(duration)"
                status = "Route to \(name) ready"
            } catch {
                status = "Route failed: \(error.localizedDescription)"
                routeSummary = ""
            }
            isCalculating = false
        }
    }

    func clearRoute() {
        destinationQuery = ""
        routeSummary = ""
        alternativesCount = 0
        routes = []
        selectedRouteIndex = 0
        destinationName = ""
        status = "No route selected"
        projectionStore.clearRoute()
    }

    func importGPX(data: Data, name: String) {
        do {
            guard let route = try GPXParser.parse(data: data, fallbackName: name).route else {
                throw GPXParserError.invalidXML("The GPX file has fewer than two route points")
            }
            routes = [route]
            selectedRouteIndex = 0
            destinationName = name
            alternativesCount = 1
            status = "Rendering GPX route…"
            Task {
                do {
                    let image = try await renderMap(points: route.points)
                    let distance = Self.distanceFormatter.string(from: Measurement(
                        value: route.distanceMeters,
                        unit: UnitLength.meters
                    ))
                    let duration = Self.durationFormatter.string(from: route.durationSeconds) ?? "--"
                    projectionStore.updateRoute(
                        mapImage: image,
                        instruction: route.firstInstruction,
                        destination: name,
                        distance: distance,
                        duration: duration
                    )
                    routeSummary = "\(distance) • \(duration)"
                    status = "GPX route ready"
                } catch {
                    status = "GPX map failed: \(error.localizedDescription)"
                }
            }
        } catch {
            status = "GPX import failed: \(error.localizedDescription)"
        }
    }

    func selectNextAlternative() {
        guard routes.count > 1 else { return }
        selectedRouteIndex = (selectedRouteIndex + 1) % routes.count
        let route = routes[selectedRouteIndex]
        Task {
            do {
                let image = try await renderMap(points: route.points)
                let distance = Self.distanceFormatter.string(from: Measurement(
                    value: route.distanceMeters,
                    unit: UnitLength.meters
                ))
                let duration = Self.durationFormatter.string(from: route.durationSeconds) ?? "--"
                projectionStore.updateRoute(
                    mapImage: image,
                    instruction: route.firstInstruction,
                    destination: destinationName,
                    distance: distance,
                    duration: duration
                )
                routeSummary = "\(distance) • \(duration)"
                status = "Alternative \(selectedRouteIndex + 1) of \(routes.count) selected"
            } catch {
                status = "Could not render alternative: \(error.localizedDescription)"
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
            status = "Waiting for current GPS location"
        } else if authorizationStatus == .denied || authorizationStatus == .restricted {
            calculateWhenLocationArrives = false
            status = "Location access was denied in Settings"
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        let speed = location.speed >= 0 ? Int((location.speed * 3.6).rounded()) : 0
        projectionStore.updateSpeed(speed)
        if calculateWhenLocationArrives {
            calculateWhenLocationArrives = false
            calculateRoute()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        status = "GPS unavailable: \(error.localizedDescription)"
    }

    private func renderMap(points: [RouteCoordinate]) async throws -> CGImage {
        let mapPoints = points.map { MKMapPoint($0.clLocation) }
        guard let first = mapPoints.first else { throw NavigationError.snapshotFailed }
        let emptySize = MKMapSize(width: 0, height: 0)
        var routeRect = MKMapRect(origin: first, size: emptySize)
        for point in mapPoints.dropFirst() {
            routeRect = routeRect.union(MKMapRect(origin: point, size: emptySize))
        }
        let paddingX = max(routeRect.size.width * 0.22, 800)
        let paddingY = max(routeRect.size.height * 0.22, 800)
        let options = MKMapSnapshotter.Options()
        options.mapRect = routeRect.insetBy(dx: -paddingX, dy: -paddingY)
        options.size = CGSize(width: 800, height: 480)
        options.scale = 1
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        let snapshot = try await MKMapSnapshotter(options: options).start()
        let image = UIGraphicsImageRenderer(size: options.size).image { renderer in
            snapshot.image.draw(at: .zero)
            let context = renderer.cgContext
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(8)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            guard !mapPoints.isEmpty else { return }
            context.beginPath()
            context.move(to: snapshot.point(for: mapPoints[0].coordinate))
            for point in mapPoints.dropFirst() {
                context.addLine(to: snapshot.point(for: point.coordinate))
            }
            context.strokePath()
        }
        guard let cgImage = image.cgImage else { throw NavigationError.snapshotFailed }
        return cgImage
    }

    private func mapKitRoutes(
        from origin: CLLocation,
        to destination: MKMapItem
    ) async throws -> [NavigationRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = destination
        request.transportType = .automobile
        let response = try await MKDirections(request: request).calculate()
        return response.routes.compactMap { route in
            let rawPoints = route.polyline.points()
            let points = (0..<route.polyline.pointCount).map { index in
                let point = rawPoints[index]
                return RouteCoordinate(
                    latitude: point.coordinate.latitude,
                    longitude: point.coordinate.longitude
                )
            }
            guard points.count >= 2 else { return nil }
            let steps = route.steps.map { step in
                RouteStep(
                    maneuverType: "turn",
                    modifier: nil,
                    roadName: step.instructions,
                    maneuver: points.first ?? RouteCoordinate(
                        latitude: origin.coordinate.latitude,
                        longitude: origin.coordinate.longitude
                    ),
                    distanceMeters: step.distance,
                    exit: nil,
                    lanes: nil
                )
            }
            return NavigationRoute(
                points: points,
                distanceMeters: route.distance,
                durationSeconds: route.expectedTravelTime,
                steps: steps,
                label: "Apple Maps"
            )
        }
    }

    private static let distanceFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private enum NavigationError: LocalizedError {
    case destinationNotFound
    case routeNotFound
    case snapshotFailed

    var errorDescription: String? {
        switch self {
        case .destinationNotFound: return "Destination not found"
        case .routeNotFound: return "No driving route was found"
        case .snapshotFailed: return "Map snapshot could not be generated"
        }
    }
}
