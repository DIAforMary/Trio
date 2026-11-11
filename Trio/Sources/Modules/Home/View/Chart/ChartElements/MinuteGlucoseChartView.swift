import Charts
import Foundation
import SwiftUI

/// Fork feature (DIAforMary/Trio, branch libre-1min-display): Libre 3 minute
/// readings as small, faded dots behind Trio's normal 5-minute glucose dots.
/// Display only: the data comes from `MinuteGlucoseStore`, never from
/// `GlucoseStored`, so nothing here feeds the algorithm.
struct MinuteGlucoseChartView: ChartContent {
    let readings: [MinuteGlucoseReading]
    let units: GlucoseUnits
    let highGlucose: Decimal
    let lowGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme

    var body: some ChartContent {
        ForEach(readings) { reading in
            let value = units == .mgdL ? Decimal(reading.mgdl) : Decimal(reading.mgdl).asMmolL
            PointMark(
                x: .value("Time", reading.date, unit: .second),
                y: .value("Value", value)
            )
            .foregroundStyle(color(for: reading).opacity(0.45))
            .symbolSize(7)
            .symbol(.circle)
        }
    }

    /// Same color rules as `GlucoseChartView`.
    private func color(for reading: MinuteGlucoseReading) -> Color {
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor
        return Trio.getDynamicGlucoseColor(
            glucoseValue: Decimal(reading.mgdl),
            highGlucoseColorValue: isDynamicColorScheme ? Decimal(220) : highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? Decimal(55) : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }
}
