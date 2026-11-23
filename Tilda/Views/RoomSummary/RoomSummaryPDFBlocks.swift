import SwiftUI

/// Print header: title, date and the hero totals on a white page.
struct RoomSummaryPDFHeader: View {
    let name: String
    let date: Date
    let facts: RoomFacts
    let units: AppSettings.Units
    @Environment(\.summaryPalette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.title.weight(.semibold)).foregroundStyle(p.primary)
                Text("Room summary · \(date.formatted(date: .long, time: .omitted))")
                    .font(.subheadline).foregroundStyle(p.secondary)
            }
            SummaryHero(facts: facts, units: units)
        }
    }
}

struct RoomSummaryPDFFootnote: View {
    @Environment(\.summaryPalette) private var p
    var body: some View {
        Text("Measured with Tilda. Dimensions are approximate and assume rectangular rooms. Paint assumes 10 m² per litre, two coats. Flooring adds 10% for waste.")
            .font(.caption)
            .foregroundStyle(p.muted)
    }
}
