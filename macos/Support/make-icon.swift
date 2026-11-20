// Draws Pixelpress's own icon: two offset tiles pressed by a chevron.
import CoreGraphics; import ImageIO; import Foundation
let s = 1024.0
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let c = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
c.addPath(body); c.clip()
let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.98, green: 0.42, blue: 0.25, alpha: 1), CGColor(red: 0.85, green: 0.16, blue: 0.42, alpha: 1)] as CFArray, locations: [0, 1])!
c.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
func tile(_ r: CGRect, _ a: CGFloat) { c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: a)); c.addPath(CGPath(roundedRect: r, cornerWidth: 48, cornerHeight: 48, transform: nil)); c.fillPath() }
tile(CGRect(x: 250, y: 300, width: 420, height: 420), 0.45)
tile(CGRect(x: 360, y: 210, width: 420, height: 320), 1)
c.setStrokeColor(CGColor(red: 0.85, green: 0.16, blue: 0.42, alpha: 1)); c.setLineWidth(46); c.setLineCap(.round); c.setLineJoin(.round)
c.move(to: CGPoint(x: 470, y: 420)); c.addLine(to: CGPoint(x: 570, y: 330)); c.addLine(to: CGPoint(x: 670, y: 420)); c.strokePath()
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(d, c.makeImage()!, nil); CGImageDestinationFinalize(d)
