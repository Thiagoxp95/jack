import Foundation

/// Detects mouse gesture patterns (jiggle, circle) in recorded cursor data
/// and returns zoom keyframes for the video editor.
struct GestureZoomDetector {

    // MARK: - Constants

    /// Time window for counting X-direction reversals (seconds).
    static let jiggleWindow: Double = 0.5

    /// Minimum X-velocity sign changes within the window to trigger jiggle.
    static let jiggleReversalThreshold: Int = 3

    /// Ignore velocity changes smaller than this (pixels per event gap).
    static let velocityDeadzone: Double = 5.0

    /// Minimum horizontal spread (max X - min X) in pixels to qualify as a jiggle (~2cm on screen).
    static let jiggleMinAmplitude: Double = 50.0

    /// Time window for angular displacement analysis (seconds).
    static let circleWindow: Double = 1.0

    /// Minimum cumulative angle (radians) to trigger circle detection (~270 degrees).
    static let circleAngleThreshold: Double = 4.712

    /// Minimum average distance from centroid in pixels to qualify as a circle (~1cm radius = 2cm diameter).
    static let circleMinRadius: Double = 25.0

    /// How long the cursor must be still to end a gesture region (seconds).
    static let settleTimeout: Double = 0.3

    /// Extra zoom time appended after the gesture ends (seconds).
    static let zoomTailDuration: Double = 3.0

    /// Maximum gap between two gesture regions to merge them (seconds).
    static let mergeGapThreshold: Double = 2.0

    /// Zoom level assigned to all auto-detected regions.
    static let defaultZoomLevel: Double = 2.0

    // MARK: - Detection

    /// Analyze cursor events and return zoom keyframes for detected gestures.
    static func detect(events: [CursorEvent]) -> [ZoomKeyframe] {
        guard events.count >= 4 else { return [] }

        // Step 1: Mark each event as "in gesture" or not
        var gestureFlags = [Bool](repeating: false, count: events.count)

        for i in 0..<events.count {
            if isJiggle(events: events, at: i) || isCircle(events: events, at: i) {
                gestureFlags[i] = true
            }
        }

        // Step 2: Build gesture regions from flagged events
        var rawRegions = buildRegions(events: events, flags: gestureFlags)

        // Step 3: Add tail duration
        rawRegions = rawRegions.map { region in
            (start: region.start, end: region.end + zoomTailDuration)
        }

        // Step 4: Merge nearby regions
        let merged = mergeRegions(rawRegions)

        // Step 5: Convert to ZoomKeyframes
        return merged.map { region in
            ZoomKeyframe(
                startTime: region.start,
                endTime: region.end,
                zoomLevel: defaultZoomLevel
            )
        }
    }

    // MARK: - Jiggle Detector

    /// Check if the cursor is jiggling at the given event index
    /// by counting X-direction reversals in a trailing time window.
    private static func isJiggle(events: [CursorEvent], at index: Int) -> Bool {
        let currentTime = events[index].t
        let windowStart = currentTime - jiggleWindow

        // Walk backward from index to find window start
        var start = index
        while start > 0 && events[start - 1].t >= windowStart {
            start -= 1
        }

        guard index - start >= 2 else { return false }

        // Check minimum horizontal spread (~2cm on screen)
        var minX = events[start].x
        var maxX = events[start].x
        for j in (start + 1)...index {
            minX = min(minX, events[j].x)
            maxX = max(maxX, events[j].x)
        }
        guard maxX - minX >= jiggleMinAmplitude else { return false }

        var reversals = 0
        var lastSign: Int = 0

        for j in (start + 1)...index {
            let dx = events[j].x - events[j - 1].x
            let dt = events[j].t - events[j - 1].t
            guard dt > 0 else { continue }

            // Skip tiny movements (noise)
            if abs(dx) < velocityDeadzone { continue }

            let sign = dx > 0 ? 1 : -1
            if lastSign != 0 && sign != lastSign {
                reversals += 1
            }
            lastSign = sign
        }

        return reversals >= jiggleReversalThreshold
    }

    // MARK: - Circle Detector

    /// Check if the cursor is making a circular motion at the given event index
    /// by measuring cumulative angular displacement around the window centroid.
    private static func isCircle(events: [CursorEvent], at index: Int) -> Bool {
        let currentTime = events[index].t
        let windowStart = currentTime - circleWindow

        var start = index
        while start > 0 && events[start - 1].t >= windowStart {
            start -= 1
        }

        let windowCount = index - start + 1
        guard windowCount >= 6 else { return false }

        // Compute centroid of events in window
        var centroidX: Double = 0
        var centroidY: Double = 0
        for j in start...index {
            centroidX += events[j].x
            centroidY += events[j].y
        }
        centroidX /= Double(windowCount)
        centroidY /= Double(windowCount)

        // Check minimum radius (~1cm radius = 2cm diameter circle)
        var totalDist: Double = 0
        var minX = events[start].x, maxX = events[start].x
        var minY = events[start].y, maxY = events[start].y
        for j in start...index {
            let dx = events[j].x - centroidX
            let dy = events[j].y - centroidY
            totalDist += (dx * dx + dy * dy).squareRoot()
            minX = min(minX, events[j].x)
            maxX = max(maxX, events[j].x)
            minY = min(minY, events[j].y)
            maxY = max(maxY, events[j].y)
        }
        let avgRadius = totalDist / Double(windowCount)
        guard avgRadius >= circleMinRadius else { return false }

        // Reject linear oscillations — a circle/oval needs spread in both axes.
        // Minor axis must be at least 30% of major axis.
        let spreadX = maxX - minX
        let spreadY = maxY - minY
        let majorSpread = max(spreadX, spreadY)
        let minorSpread = min(spreadX, spreadY)
        guard majorSpread > 0, minorSpread / majorSpread >= 0.3 else { return false }

        // Accumulate angular displacement
        var totalAngle: Double = 0
        for j in (start + 1)...index {
            let angle0 = atan2(events[j - 1].y - centroidY, events[j - 1].x - centroidX)
            let angle1 = atan2(events[j].y - centroidY, events[j].x - centroidX)
            var delta = angle1 - angle0

            // Normalize to [-pi, pi]
            while delta > .pi { delta -= 2.0 * .pi }
            while delta < -.pi { delta += 2.0 * .pi }

            totalAngle += abs(delta)
        }

        return totalAngle >= circleAngleThreshold
    }

    // MARK: - Region Building

    private static func buildRegions(
        events: [CursorEvent],
        flags: [Bool]
    ) -> [(start: Double, end: Double)] {
        var regions: [(start: Double, end: Double)] = []
        var regionStart: Double?
        var lastGestureTime: Double = 0

        for i in 0..<events.count {
            if flags[i] {
                if regionStart == nil {
                    regionStart = events[i].t
                }
                lastGestureTime = events[i].t
            } else if let start = regionStart {
                // Check if we've settled (no gesture for settleTimeout)
                if events[i].t - lastGestureTime >= settleTimeout {
                    regions.append((start: start, end: lastGestureTime))
                    regionStart = nil
                }
            }
        }

        // Close any open region
        if let start = regionStart {
            regions.append((start: start, end: lastGestureTime))
        }

        return regions
    }

    // MARK: - Merging

    private static func mergeRegions(
        _ regions: [(start: Double, end: Double)]
    ) -> [(start: Double, end: Double)] {
        guard !regions.isEmpty else { return [] }

        var merged = [regions[0]]
        for i in 1..<regions.count {
            let current = regions[i]
            let lastIndex = merged.count - 1

            if current.start - merged[lastIndex].end <= mergeGapThreshold {
                merged[lastIndex].end = max(merged[lastIndex].end, current.end)
            } else {
                merged.append(current)
            }
        }

        return merged
    }
}
