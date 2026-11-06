import SwiftUI

/// Обложка главного экрана: те же контуры, что в макете (viewBox 1000×205, заполнение как xMidYMid slice).
struct CoverArt: View {
    var body: some View {
        Canvas { context, size in
            let scale = max(size.width / 1000, size.height / 205)
            let dx = (size.width - 1000 * scale) / 2, dy = (size.height - 205 * scale) / 2
            context.translateBy(x: dx, y: dy)
            context.scaleBy(x: scale, y: scale)
            let frame = CGRect(x: 0, y: 0, width: 1000, height: 205)
            context.fill(Path(frame), with: .linearGradient(Gradient(colors: [hex(0xE7EAD2), hex(0xB7CFB7)]),
                                                            startPoint: .zero, endPoint: CGPoint(x: 1000, y: 205)))
            context.fill(Path(ellipseIn: CGRect(x: 752 - 39, y: 63 - 39, width: 78, height: 78)), with: .color(hex(0xF3DB9B)))
            func hill(_ y0: CGFloat, _ q1: (CGFloat, CGFloat, CGFloat, CGFloat), _ t1: (CGFloat, CGFloat), _ q2: (CGFloat, CGFloat, CGFloat, CGFloat), _ t2: (CGFloat, CGFloat)) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y0))
                p.addQuadCurve(to: CGPoint(x: q1.2, y: q1.3), control: CGPoint(x: q1.0, y: q1.1))
                // T в SVG отражает предыдущую контрольную точку.
                var control = CGPoint(x: 2 * q1.2 - q1.0, y: 2 * q1.3 - q1.1)
                p.addQuadCurve(to: CGPoint(x: t1.0, y: t1.1), control: control)
                p.addQuadCurve(to: CGPoint(x: q2.2, y: q2.3), control: CGPoint(x: q2.0, y: q2.1))
                control = CGPoint(x: 2 * q2.2 - q2.0, y: 2 * q2.3 - q2.1)
                p.addQuadCurve(to: CGPoint(x: t2.0, y: t2.1), control: control)
                p.addLine(to: CGPoint(x: 1000, y: 205))
                p.addLine(to: CGPoint(x: 0, y: 205))
                p.closeSubpath()
                return p
            }
            context.fill(hill(136, (120, 70, 232, 125), (436, 107), (554, 42, 674, 112), (1000, 93)), with: .color(hex(0xA4BC9D)))
            context.fill(hill(168, (162, 102, 283, 155), (518, 143), (641, 93, 741, 133), (1000, 119)), with: .color(hex(0x779779)))
            context.fill(hill(184, (151, 128, 305, 186), (588, 168), (720, 117, 838, 169), (1000, 148)), with: .color(hex(0x4B7357)))
            var front = Path()
            front.move(to: CGPoint(x: 0, y: 200))
            front.addQuadCurve(to: CGPoint(x: 309, y: 201), control: CGPoint(x: 165, y: 158))
            front.addQuadCurve(to: CGPoint(x: 608, y: 192), control: CGPoint(x: 453, y: 244))
            front.addQuadCurve(to: CGPoint(x: 1000, y: 188), control: CGPoint(x: 780, y: 153))
            front.addLine(to: CGPoint(x: 1000, y: 205))
            front.addLine(to: CGPoint(x: 0, y: 205))
            front.closeSubpath()
            context.fill(front, with: .color(hex(0x345740)))
            context.fill(tree(x: 880, y: 166, [(17, -32), (-8, 0), (12, -24), (-6, 0), (10, -24), (10, 24), (-6, 0), (12, 24), (-8, 0), (17, 32)]), with: .color(hex(0x315039)))
            context.fill(tree(x: 928, y: 177, [(12, -23), (-5, 0), (9, -17), (-4, 0), (7, -17), (7, 17), (-4, 0), (9, 17), (-5, 0), (12, 23)]), with: .color(hex(0x315039)))
            // Зерно макета: точка в сетке 6×6, opacity .13.
            var grain = Path()
            var y: CGFloat = 1
            while y < 205 {
                var x: CGFloat = 1
                while x < 1000 {
                    grain.addEllipse(in: CGRect(x: x - 0.45, y: y - 0.45, width: 0.9, height: 0.9))
                    x += 6
                }
                y += 6
            }
            context.fill(grain, with: .color(hex(0x26402B).opacity(0.13)))
        }
        .overlay(alignment: .topLeading) {
            Text("ЛИЧНОЕ ПРОСТРАНСТВО")
                .font(.system(size: 10))
                .tracking(2)
                .foregroundColor(hex(0x334E37))
                .padding(.leading, 24)
                .padding(.top, 20)
        }
        .frame(height: 205)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    private func tree(x: CGFloat, y: CGFloat, _ deltas: [(CGFloat, CGFloat)]) -> Path {
        var p = Path()
        var at = CGPoint(x: x, y: y)
        p.move(to: at)
        for (dx, dy) in deltas {
            at = CGPoint(x: at.x + dx, y: at.y + dy)
            p.addLine(to: at)
        }
        p.closeSubpath()
        return p
    }

    private func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
