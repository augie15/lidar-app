import SwiftUI
import UIKit

/// Builds the print-friendly PDF (US Letter, light theme) and handles the clipboard.
@MainActor
enum RoomSummaryExporter {
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 40
    static let gap: CGFloat = 14

    static func copy(_ text: String) { UIPasteboard.general.string = text }

    /// One block never splits across pages: blocks are measured, then packed top to bottom.
    static func makePDF(name: String, date: Date, facts: RoomFacts, plan: FloorPlan?,
                        fixtures: FixtureLibrary? = nil, units: AppSettings.Units) -> URL? {
        let width = pageSize.width - margin * 2
        let usable = pageSize.height - margin * 2

        var blocks: [AnyView] = [AnyView(RoomSummaryPDFHeader(name: name, date: date, facts: facts, units: units))]
        if let plan, !plan.walls.isEmpty {
            blocks.append(AnyView(SummaryPlan(plan: plan, fixtures: fixtures?.fixtures ?? [])))
        }
        if let fixtures, !fixtures.fixtures.isEmpty { blocks.append(AnyView(SummaryFixturesBlock(library: fixtures, units: units))) }
        for room in facts.rooms { blocks.append(AnyView(SummaryRoomCard(room: room, units: units))) }
        blocks.append(AnyView(RoomSummaryPDFFootnote()))

        let styled = blocks.map { block in
            AnyView(block
                .environment(\.summaryPalette, .light)
                .environment(\.colorScheme, .light)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true))
        }
        let heights: [CGFloat] = styled.map { view in
            let host = UIHostingController(rootView: view)
            return ceil(host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        }

        var pages: [[(index: Int, y: CGFloat)]] = [[]]
        var y: CGFloat = 0
        for i in styled.indices {
            if y > 0, y + heights[i] > usable { pages.append([]); y = 0 }
            pages[pages.count - 1].append((i, y))
            y += heights[i] + gap
        }

        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe) summary.pdf")
        try? FileManager.default.removeItem(at: url)
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        for page in pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(box)
            for (index, top) in page {
                let renderer = ImageRenderer(content: styled[index])
                renderer.proposedSize = ProposedViewSize(width: width, height: heights[index])
                renderer.render { size, draw in
                    ctx.saveGState()
                    ctx.translateBy(x: margin, y: pageSize.height - margin - top - size.height)
                    draw(ctx)
                    ctx.restoreGState()
                }
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
