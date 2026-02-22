import Foundation

/// Detects a "lottery ticket scratch" mouse gesture — rapid horizontal
/// back-and-forth (~20px) — in recorded cursor data and returns zoom keyframes.
struct GestureZoomDetector {

    // MARK: - Constants

    /// Time window for counting X-direction reversals (seconds).
    static let scratchWindow: Double = 0.4

    /// Minimum X-direction sign changes within the window to trigger.
    /// A real scratch easily produces 6+ reversals in 0.4s.
    static let scratchReversalThreshold: Int = 5

    /// Ignore X-deltas smaller than this between consecutive events (pixels).
    static let velocityDeadzone: Double = 3.0

    /// How long the cursor must be still to end a gesture region (seconds).
    static let settleTimeout: Double = 0.3

    /// Extra zoom time appended after the gesture ends (seconds).
    static let zoomTailDuration: Double = 3.0

    /// Maximum gap between two gesture regions to merge them (seconds).
    static let mergeGapThreshold: Double = 2.0

    /// Zoom level assigned to all auto-detected regions.
    static let defaultZoomLevel: Double = 2.0

    // MARK: - Detection

    /// Analyze cursor events and return zoom keyframes for detected scratch gestures.
    static func detect(events: [CursorEvent]) -> [ZoomKeyframe] {
        guard events.count >= 4 else { return [] }

        // Step 1: Mark each event as "in gesture" or not
        var gestureFlags = [Bool](repeating: false, count: events.count)

        for i in 0..<events.count {
            if isScratch(events: events, at: i) {
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

    // MARK: - Scratch Detector

    /// Check if the cursor is doing a rapid horizontal scratch at the given index.
    /// Requires 5+ X-direction reversals within a 0.4s trailing window.
    private static func isScratch(events: [CursorEvent], at index: Int) -> Bool {
        let currentTime = events[index].t
        let windowStart = currentTime - scratchWindow

        // Walk backward to find window start
        var start = index
        while start > 0 && events[start - 1].t >= windowStart {
            start -= 1
        }

        // Need enough events to count reversals
        guard index - start >= 4 else { return false }

        var reversals = 0
        var lastSign: Int = 0

        for j in (start + 1)...index {
            let dx = events[j].x - events[j - 1].x
            let dt = events[j].t - events[j - 1].t
            guard dt > 0 else { continue }

            if abs(dx) < velocityDeadzone { continue }

            let sign = dx > 0 ? 1 : -1
            if lastSign != 0 && sign != lastSign {
                reversals += 1
            }
            lastSign = sign
        }

        return reversals >= scratchReversalThreshold
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
                if events[i].t - lastGestureTime >= settleTimeout {
                    regions.append((start: start, end: lastGestureTime))
                    regionStart = nil
                }
            }
        }

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
