// Draws the app icon: a holographic gyroscope in an iridescent bubble.
// Run: swift Tools/make-icon.swift Gyre/Resources/Assets.xcassets/AppIcon.appiconset/Icon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon.png"
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(
  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let s = CGFloat(size)
let c = CGPoint(x: s / 2, y: s / 2 + 10)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Background: deep navy with a soft glow behind the bubble.
let bg = CGGradient(
  colorsSpace: space, colors: [color(0.05, 0.09, 0.20), color(0.012, 0.016, 0.05)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bg, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.75, options: .drawsAfterEndLocation)

// Horizon line and faint grid.
ctx.setLineWidth(2)
for i in -4...4 {
  let y = c.y + CGFloat(i) * 70
  ctx.setStrokeColor(color(0.25, 0.35, 0.7, i == 0 ? 0.35 : 0.08))
  ctx.move(to: CGPoint(x: 0, y: y))
  ctx.addLine(to: CGPoint(x: s, y: y))
  ctx.strokePath()
}

func glowStroke(_ path: CGPath, _ col: CGColor, width: CGFloat, glow: CGFloat) {
  ctx.saveGState()
  ctx.setShadow(offset: .zero, blur: glow, color: col)
  ctx.setStrokeColor(col)
  ctx.setLineWidth(width)
  ctx.setLineCap(.round)
  ctx.addPath(path)
  ctx.strokePath()
  ctx.restoreGState()
}

func ellipse(_ center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat) -> CGPath {
  var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
  return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &t)
}

// Bubble: iridescent rim built from offset coloured rings.
let R: CGFloat = 400
let film: [(CGFloat, CGFloat, CGFloat)] = [(0.4, 0.9, 1.0), (0.9, 0.45, 1.0), (1.0, 0.75, 0.35), (0.45, 1.0, 0.7)]
for (i, f) in film.enumerated() {
  let a = CGFloat(i) * .pi / 2
  let off = CGPoint(x: cos(a) * 6, y: sin(a) * 6)
  glowStroke(
    CGPath(ellipseIn: CGRect(x: c.x - R + off.x, y: c.y - R + off.y, width: 2 * R, height: 2 * R), transform: nil),
    color(f.0, f.1, f.2, 0.55), width: 5, glow: 30)
}
// Specular glint.
ctx.saveGState()
let glint = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.8), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
let gp = CGPoint(x: c.x - 190, y: c.y + 240)
ctx.drawRadialGradient(glint, startCenter: gp, startRadius: 0, endCenter: gp, endRadius: 70, options: [])
ctx.restoreGState()

// Gyroscope: tilted axle, cage meridians, rotor rim.
let tilt: CGFloat = -0.32
let axis = CGPoint(x: sin(-tilt), y: cos(-tilt))
let rotorC = CGPoint(x: c.x + axis.x * 40, y: c.y + axis.y * 40)
let cyan = color(0.35, 0.9, 1.0)
let violet = color(0.7, 0.5, 1.0)
glowStroke(ellipse(rotorC, rx: 250, ry: 250, angle: tilt), violet, width: 9, glow: 26)
glowStroke(ellipse(rotorC, rx: 250, ry: 78, angle: tilt), violet, width: 8, glow: 24)
glowStroke(ellipse(rotorC, rx: 90, ry: 250, angle: tilt), violet, width: 7, glow: 22)
glowStroke(ellipse(rotorC, rx: 215, ry: 62, angle: tilt + .pi / 2 + .pi / 2), cyan, width: 14, glow: 36)
glowStroke(ellipse(CGPoint(x: rotorC.x + axis.x * 16, y: rotorC.y + axis.y * 16), rx: 215, ry: 62, angle: tilt), cyan, width: 8, glow: 30)

let axle = CGMutablePath()
axle.move(to: CGPoint(x: c.x - axis.x * 260, y: c.y - axis.y * 260))
axle.addLine(to: CGPoint(x: rotorC.x + axis.x * 310, y: rotorC.y + axis.y * 310))
glowStroke(axle, color(0.85, 0.95, 1.0), width: 10, glow: 30)
for p in [CGPoint(x: c.x - axis.x * 260, y: c.y - axis.y * 260), CGPoint(x: rotorC.x + axis.x * 310, y: rotorC.y + axis.y * 310)] {
  ctx.saveGState()
  ctx.setShadow(offset: .zero, blur: 30, color: cyan)
  ctx.setFillColor(color(0.9, 1, 1))
  ctx.fillEllipse(in: CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36))
  ctx.restoreGState()
}

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: out)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out) \(image.width)×\(image.height)")
