import CoreLocation
import MapKit

struct RouteProgressSnapshot {
    let distanceFromRouteMeters: CLLocationDistance
    let remainingDistanceMeters: CLLocationDistance
    let remainingDurationSeconds: TimeInterval
    let completedFraction: Double
    let nextInstruction: String
}

enum NavigationProgressCalculator {
    static func progress(
        for location: CLLocation,
        on route: NavigationRoute
    ) -> RouteProgressSnapshot {
        guard route.points.count >= 2 else {
            return RouteProgressSnapshot(
                distanceFromRouteMeters: .greatestFiniteMagnitude,
                remainingDistanceMeters: route.distanceMeters,
                remainingDurationSeconds: route.durationSeconds,
                completedFraction: 0,
                nextInstruction: route.firstInstruction
            )
        }

        let mapPoints = route.points.map { MKMapPoint($0.clLocation) }
        let userPoint = MKMapPoint(location.coordinate)
        var closestDistance = CLLocationDistance.greatestFiniteMagnitude
        var closestAlongPolyline = 0.0
        var cumulativePolylineDistance = 0.0
        var closestSegmentIndex = 0

        for index in 0..<(mapPoints.count - 1) {
            let start = mapPoints[index]
            let end = mapPoints[index + 1]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let segmentLengthSquared = dx * dx + dy * dy
            let rawT = segmentLengthSquared > 0
                ? ((userPoint.x - start.x) * dx + (userPoint.y - start.y) * dy) / segmentLengthSquared
                : 0
            let t = min(max(rawT, 0), 1)
            let projected = MKMapPoint(x: start.x + dx * t, y: start.y + dy * t)
            let mapDistance = hypot(userPoint.x - projected.x, userPoint.y - projected.y)
            let metersPerMapPoint = MKMetersPerMapPointAtLatitude(location.coordinate.latitude)
            let distance = mapDistance * metersPerMapPoint
            let segmentStart = CLLocation(
                latitude: route.points[index].latitude,
                longitude: route.points[index].longitude
            )
            let segmentEnd = CLLocation(
                latitude: route.points[index + 1].latitude,
                longitude: route.points[index + 1].longitude
            )
            let segmentMeters = segmentStart.distance(from: segmentEnd)

            if distance < closestDistance {
                closestDistance = distance
                closestAlongPolyline = cumulativePolylineDistance + segmentMeters * t
                closestSegmentIndex = index
            }
            cumulativePolylineDistance += segmentMeters
        }

        let polylineDistance = max(cumulativePolylineDistance, 1)
        let completed = min(max(closestAlongPolyline / polylineDistance, 0), 1)
        let remainingDistance = max(route.distanceMeters * (1 - completed), 0)
        let remainingDuration = max(route.durationSeconds * (1 - completed), 0)
        let instruction = nextInstruction(
            route: route,
            closestSegmentIndex: closestSegmentIndex,
            completedFraction: completed
        )

        return RouteProgressSnapshot(
            distanceFromRouteMeters: closestDistance,
            remainingDistanceMeters: remainingDistance,
            remainingDurationSeconds: remainingDuration,
            completedFraction: completed,
            nextInstruction: instruction
        )
    }

    private static func nextInstruction(
        route: NavigationRoute,
        closestSegmentIndex: Int,
        completedFraction: Double
    ) -> String {
        if completedFraction >= 0.98 {
            return "You have arrived"
        }

        let futureSteps = route.steps.enumerated().filter { _, step in
            guard step.maneuverType != "depart" && step.maneuverType != "arrive" else {
                return false
            }
            return nearestPointIndex(for: step.maneuver, in: route.points) >= closestSegmentIndex
        }
        if let next = futureSteps.min(by: { lhs, rhs in
            nearestPointIndex(for: lhs.element.maneuver, in: route.points)
                < nearestPointIndex(for: rhs.element.maneuver, in: route.points)
        }) {
            return next.element.instruction
        }
        return route.steps.last?.instruction ?? "Continue on the highlighted route"
    }

    private static func nearestPointIndex(
        for coordinate: RouteCoordinate,
        in points: [RouteCoordinate]
    ) -> Int {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return points.enumerated().min { lhs, rhs in
            let left = CLLocation(latitude: lhs.element.latitude, longitude: lhs.element.longitude)
            let right = CLLocation(latitude: rhs.element.latitude, longitude: rhs.element.longitude)
            return target.distance(from: left) < target.distance(from: right)
        }?.offset ?? 0
    }
}
