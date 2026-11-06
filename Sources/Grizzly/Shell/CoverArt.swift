import SwiftUI

/// Набор обложки: цвета одного и того же пейзажа.
struct CoverPreset: Identifiable {
    let id: String
    let title: String
    let sky: (UInt32, UInt32)
    let sun: UInt32
    let hills: [UInt32]
    let tree: UInt32
    let label: UInt32

    static var all: [CoverPreset] {
        [CoverPreset(id: "forest", title: L("Лес"), sky: (0xE7EAD2, 0xB7CFB7), sun: 0xF3DB9B, hills: [0xA4BC9D, 0x779779, 0x4B7357, 0x345740], tree: 0x315039, label: 0x334E37),
         CoverPreset(id: "mono", title: L("Монохром"), sky: (0xF1F1EF, 0xD9D9D6), sun: 0xFFFFFF, hills: [0xBDBDBA, 0x8F8F8C, 0x5E5E5B, 0x37352F], tree: 0x2B2A26, label: 0x37352F),
         CoverPreset(id: "dusk", title: L("Закат"), sky: (0xF7D9C4, 0xC9A7C9), sun: 0xFFE9A8, hills: [0xB78FB0, 0x8A6A95, 0x5F4B78, 0x3D3158], tree: 0x2F2547, label: 0x3D3158),
         CoverPreset(id: "ocean", title: L("Океан"), sky: (0xDCEEF2, 0xA9CFDA), sun: 0xFFF3C4, hills: [0x8DBCC9, 0x5F97A8, 0x3B7286, 0x234F63], tree: 0x1C4152, label: 0x234F63),
         CoverPreset(id: "autumn", title: L("Осень"), sky: (0xF8EBD3, 0xEBCFA5), sun: 0xF7B267, hills: [0xD9A566, 0xB97F45, 0x8C5A2F, 0x5F3B1E], tree: 0x4A2E17, label: 0x5F3B1E)]
    }

    static func find(_ id: String?) -> CoverPreset {
        all.first { $0.id == id } ?? all.first { $0.id == Tokens.theme.defaultCover } ?? all[0]
    }
}

/// Пейзаж обложки. По ширине растягиваются только холмы: солнце и деревья не обрезаются и не искажаются.
struct CoverArt: View {
    var preset: CoverPreset = CoverPreset.find(nil)

    var body: some View {
        Canvas { context, size in
            let sx = size.width / 1000, sy = size.height / 205
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [hex(preset.sky.0), hex(preset.sky.1)]),
                                                                                         startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            let radius = 39 * sy
            context.fill(Path(ellipseIn: CGRect(x: 752 * sx - radius, y: 63 * sy - radius, width: radius * 2, height: radius * 2)), with: .color(hex(preset.sun)))
            func hill(_ y0: CGFloat, _ q1: (CGFloat, CGFloat, CGFloat, CGFloat), _ t1: (CGFloat, CGFloat), _ q2: (CGFloat, CGFloat, CGFloat, CGFloat), _ t2: (CGFloat, CGFloat)) -> Path {
                var path = Path()
                path.move(to: p(0, y0))
                path.addQuadCurve(to: p(q1.2, q1.3), control: p(q1.0, q1.1))
                // T в SVG отражает предыдущую контрольную точку.
                path.addQuadCurve(to: p(t1.0, t1.1), control: p(2 * q1.2 - q1.0, 2 * q1.3 - q1.1))
                path.addQuadCurve(to: p(q2.2, q2.3), control: p(q2.0, q2.1))
                path.addQuadCurve(to: p(t2.0, t2.1), control: p(2 * q2.2 - q2.0, 2 * q2.3 - q2.1))
                path.addLine(to: p(1000, 205))
                path.addLine(to: p(0, 205))
                path.closeSubpath()
                return path
            }
            context.fill(hill(136, (120, 70, 232, 125), (436, 107), (554, 42, 674, 112), (1000, 93)), with: .color(hex(preset.hills[0])))
            context.fill(hill(168, (162, 102, 283, 155), (518, 143), (641, 93, 741, 133), (1000, 119)), with: .color(hex(preset.hills[1])))
            context.fill(hill(184, (151, 128, 305, 186), (588, 168), (720, 117, 838, 169), (1000, 148)), with: .color(hex(preset.hills[2])))
            var front = Path()
            front.move(to: p(0, 200))
            front.addQuadCurve(to: p(309, 201), control: p(165, 158))
            front.addQuadCurve(to: p(608, 192), control: p(453, 244))
            front.addQuadCurve(to: p(1000, 188), control: p(780, 153))
            front.addLine(to: p(1000, 205))
            front.addLine(to: p(0, 205))
            front.closeSubpath()
            context.fill(front, with: .color(hex(preset.hills[3])))
            func tree(_ x: CGFloat, _ y: CGFloat, _ deltas: [(CGFloat, CGFloat)]) -> Path {
                var path = Path()
                var at = CGPoint(x: x * sx, y: y * sy)
                path.move(to: at)
                for (dx, dy) in deltas {
                    at = CGPoint(x: at.x + dx * sy, y: at.y + dy * sy)
                    path.addLine(to: at)
                }
                path.closeSubpath()
                return path
            }
            context.fill(tree(880, 166, [(17, -32), (-8, 0), (12, -24), (-6, 0), (10, -24), (10, 24), (-6, 0), (12, 24), (-8, 0), (17, 32)]), with: .color(hex(preset.tree)))
            context.fill(tree(928, 177, [(12, -23), (-5, 0), (9, -17), (-4, 0), (7, -17), (7, 17), (-4, 0), (9, 17), (-5, 0), (12, 23)]), with: .color(hex(preset.tree)))
            var grain = Path()
            var y: CGFloat = 1
            while y < size.height {
                var x: CGFloat = 1
                while x < size.width {
                    grain.addEllipse(in: CGRect(x: x - 0.45, y: y - 0.45, width: 0.9, height: 0.9))
                    x += 6
                }
                y += 6
            }
            context.fill(grain, with: .color(hex(preset.hills[3]).opacity(0.13)))
        }
        .accessibilityHidden(true)
    }

    private func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
