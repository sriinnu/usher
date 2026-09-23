import AppKit
import Foundation

// Apple's app-icon grid: content occupies ~824/1024, centred, leaving optical margin.
let contentRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat  = 185.0 / 824.0   // continuous-corner approximation

func draw(size S: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: S, height: S))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let side = S * contentRatio
    let origin = (S - side) / 2
    let rect = CGRect(x: origin, y: origin, width: side, height: side)
    let radius = side * cornerRatio
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow, as macOS icons carry
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.022),
                  blur: side * 0.055,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(squircle); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Gradient body: deep indigo lifting to violet
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.42, green: 0.36, blue: 0.93, alpha: 1).cgColor,  // top
        NSColor(srgbRed: 0.31, green: 0.24, blue: 0.78, alpha: 1).cgColor,
        NSColor(srgbRed: 0.21, green: 0.15, blue: 0.56, alpha: 1).cgColor   // bottom
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY),
                           options: [])

    // Glass highlight across the top third
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.26).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.midY + side * 0.06),
                           options: [])
    ctx.restoreGState()

    // ---- Glyph: one arrival, three candidate destinations, one chosen ----
    let unit = side / 100.0
    func u(_ v: CGFloat) -> CGFloat { v * unit }
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: rect.minX + u(x), y: rect.minY + u(y))
    }
    func line(_ a: NSPoint, _ b: NSPoint, width: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: a); path.line(to: b)
        path.lineWidth = width; path.lineCapStyle = .round
        color.setStroke(); path.stroke()
    }

    let solid = NSColor.white
    let faint = NSColor.white.withAlphaComponent(0.34)
    let heavy = u(7.5), light = u(5.5)
    let lanes: [CGFloat] = [21, 50, 79]
    let takenLane: CGFloat = 79
    let busY: CGFloat = 54, dropTo: CGFloat = 40

    // The arriving file
    let item = NSBezierPath(roundedRect:
        CGRect(x: rect.minX + u(41), y: rect.minY + u(76), width: u(18), height: u(18)),
        xRadius: u(5), yRadius: u(5))
    solid.setFill(); item.fill()

    // Stem into the junction
    line(P(50, 76), P(50, busY), width: heavy, color: solid)

    // Distribution bus — faint across, solid only as far as the chosen lane
    line(P(lanes.first!, busY), P(lanes.last!, busY), width: light, color: faint)
    line(P(50, busY), P(takenLane, busY), width: heavy, color: solid)

    // Drops into each slot
    for lane in lanes {
        let taken = lane == takenLane
        line(P(lane, busY), P(lane, dropTo),
             width: taken ? heavy : light, color: taken ? solid : faint)
    }

    // Slots: outlined trays, the chosen one filled
    for lane in lanes {
        let taken = lane == takenLane
        let w = u(23), h = u(19)
        let r = CGRect(x: rect.minX + u(lane) - w/2, y: rect.minY + u(19), width: w, height: h)
        if taken {
            NSBezierPath(roundedRect: r, xRadius: u(5), yRadius: u(5)).fill()
            solid.setFill()
            NSBezierPath(roundedRect: r, xRadius: u(5), yRadius: u(5)).fill()
        } else {
            let o = NSBezierPath(roundedRect: r.insetBy(dx: u(2.3), dy: u(2.3)),
                                 xRadius: u(4), yRadius: u(4))
            o.lineWidth = light
            faint.setStroke(); o.stroke()
        }
    }

    image.unlockFocus()
    return image
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
                   ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),
                   ("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let img = draw(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { continue }
    rep.size = NSSize(width: px, height: px)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("rendered")
