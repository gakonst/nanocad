import AppKit
let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.18, blue: 0.24, alpha: 1), ending: NSColor(srgbRed: 0.035, green: 0.065, blue: 0.10, alpha: 1))!.draw(in: CGRect(origin: .zero, size: size), angle: 90)
func path(_ points: [CGPoint], fill: NSColor?, stroke: NSColor?, width: CGFloat = 20) {
    let p = NSBezierPath(); p.move(to: points[0]); for point in points.dropFirst() { p.line(to: point) }; p.close()
    p.lineJoinStyle = .round; p.lineWidth = width
    if let fill { fill.setFill(); p.fill() }; if let stroke { stroke.setStroke(); p.stroke() }
}
let top = CGPoint(x: 512, y: 798), left = CGPoint(x: 258, y: 650), mid = CGPoint(x: 512, y: 504), right = CGPoint(x: 766, y: 650), bottom = CGPoint(x: 512, y: 212), bl = CGPoint(x: 258, y: 358), br = CGPoint(x: 766, y: 358)
let line = NSColor(srgbRed: 0.74, green: 0.87, blue: 0.92, alpha: 1)
path([top,right,mid,left], fill: NSColor(srgbRed: 0.25, green: 0.40, blue: 0.49, alpha: 1), stroke: line)
path([left,mid,bottom,bl], fill: NSColor(srgbRed: 0.10, green: 0.21, blue: 0.28, alpha: 1), stroke: line)
path([mid,right,br,bottom], fill: NSColor(srgbRed: 0.11, green: 0.72, blue: 0.61, alpha: 1), stroke: line)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
