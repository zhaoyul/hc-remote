import AppKit

func drawIcon(size: Int) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let s = CGFloat(size)

  let bg = NSBezierPath(
    roundedRect: NSRect(x: s * 0.02, y: s * 0.02, width: s * 0.96, height: s * 0.96),
    xRadius: s * 0.22, yRadius: s * 0.22)
  let gradient = NSGradient(colors: [
    NSColor(red: 0.32, green: 0.56, blue: 1.0, alpha: 1),
    NSColor(red: 0.10, green: 0.30, blue: 0.92, alpha: 1),
  ])!
  gradient.draw(in: bg, angle: -90)

  let white = NSColor.white.withAlphaComponent(0.95)

  let screen = NSBezierPath(
    roundedRect: NSRect(x: s * 0.22, y: s * 0.33, width: s * 0.56, height: s * 0.36),
    xRadius: s * 0.055, yRadius: s * 0.055)
  screen.lineWidth = s * 0.05
  white.setStroke()
  screen.stroke()

  let stand = NSBezierPath()
  stand.move(to: NSPoint(x: s * 0.5, y: s * 0.33))
  stand.line(to: NSPoint(x: s * 0.5, y: s * 0.245))
  stand.line(to: NSPoint(x: s * 0.42, y: s * 0.245))
  stand.move(to: NSPoint(x: s * 0.5, y: s * 0.245))
  stand.line(to: NSPoint(x: s * 0.58, y: s * 0.245))
  stand.lineWidth = s * 0.05
  stand.lineCapStyle = .round
  stand.lineJoinStyle = .round
  white.setStroke()
  stand.stroke()

  let dotRing = NSBezierPath(
    ovalIn: NSRect(x: s * 0.585, y: s * 0.575, width: s * 0.155, height: s * 0.155))
  NSColor(red: 0.10, green: 0.30, blue: 0.92, alpha: 1).setFill()
  dotRing.fill()
  let dot = NSBezierPath(
    ovalIn: NSRect(x: s * 0.605, y: s * 0.595, width: s * 0.115, height: s * 0.115))
  NSColor(red: 0.25, green: 0.85, blue: 0.42, alpha: 1).setFill()
  dot.fill()

  image.unlockFocus()
  return image
}

func save(_ image: NSImage, pixels: Int, path: String) {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: path))
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try! FileManager.default.createDirectory(
  atPath: output, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
  ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in entries {
  save(drawIcon(size: pixels), pixels: pixels, path: "\(output)/\(name)")
}
print("iconset written to \(output)")
