import AppKit

enum IndicatorStyle: String { case ring, track }

func targetFraction(_ snapshot: Snapshot, stale: Bool) -> Double? {
    guard !stale, snapshot.mode != "recovering", let fan = snapshot.fans.first,
          let target = fan.target, let maximum = fan.maximum, target.isFinite,
          maximum.isFinite, maximum > 0 else { return nil }
    return min(1, max(0, target / maximum))
}

// One template image keeps the perimeter, fan and target aligned at either backing scale.
func trackIcon(reading: String, fraction: Double?, showFan: Bool = true, showSpeed: Bool = true) -> NSImage {
    let text = NSAttributedString(string: reading, attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.black
    ])
    let gap: CGFloat = showFan && showSpeed ? 4 : 0
    let textX: CGFloat = 8 + (showFan ? 12 : 0) + gap
    let size = NSSize(width: textX + (showSpeed ? ceil(text.size().width) : 0) + 8, height: 22)
    let image = NSImage(size: size, flipped: false) { rect in
        let midY = rect.midY, radius: CGFloat = 9
        let left = rect.minX + 1.5 + radius, right = rect.maxX - 1.5 - radius
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left, y: midY + radius))
        path.appendArc(withCenter: NSPoint(x:left,y:midY), radius:radius, startAngle:90, endAngle:270, clockwise:false)
        path.line(to: NSPoint(x:right,y:midY-radius))
        path.appendArc(withCenter: NSPoint(x:right,y:midY), radius:radius, startAngle:-90, endAngle:90, clockwise:false)
        path.close()
        path.lineWidth = 1.8
        NSColor.black.withAlphaComponent(0.25).setStroke(); path.stroke()
        if let f = fraction, f > 0 {
            let length = 2 * (right-left) + 2 * CGFloat.pi * radius
            if f < 1 { path.setLineDash([length * f, length * 2], count:2, phase:0) }
            path.lineCapStyle = .round
            NSColor.black.setStroke(); path.stroke()
        }
        if showFan { icon("fanblades.fill")?.withSymbolConfiguration(.init(paletteColors:[.black]))?.draw(in:NSRect(x:8,y:midY-6,width:12,height:12)) }
        if showSpeed { text.draw(at:NSPoint(x:textX,y:midY-text.size().height/2)) }
        return true
    }
    image.isTemplate = true
    return image
}
