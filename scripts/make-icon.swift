// Cuts the squircle out of assets/icon-source.jpg (baked-in checkerboard) into a
// transparent 1024x1024 macOS icon with Apple's standard 824px body and shadow.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
guard let src = NSImage(contentsOf: root.appendingPathComponent("assets/icon-source.jpg"))?
        .cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("cannot read source") }
let w = src.width, h = src.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let read = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
read.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
func dark(_ x: Int, _ y: Int) -> Bool { let i = (y * w + x) * 4; return (Int(px[i]) + Int(px[i+1]) + Int(px[i+2])) / 3 < 70 }

// Squircle bounds: first dark pixel scanning inward along the centre lines.
let my = h / 2, mx = w / 2
let left = (0..<w).first { dark($0, my) }!, right = (0..<w).reversed().first { dark($0, my) }!
let bottom = (0..<h).first { dark(mx, $0) }!, top = (0..<h).reversed().first { dark(mx, $0) }!
let inset = 4
let crop = src.cropping(to: CGRect(x: left + inset, y: h - 1 - top + inset,
                                   width: right - left - 2 * inset, height: top - bottom - 2 * inset))!
print("squircle bounds x:\(left)-\(right) y:\(bottom)-\(top)")

let size = 1024, body = CGRect(x: 100, y: 100, width: 824, height: 824)
let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
out.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.35))
out.beginTransparencyLayer(auxiliaryInfo: nil)
out.addPath(shape); out.clip()
out.draw(crop, in: body)
out.endTransparencyLayer()

let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("assets/AppIcon.png"))
print("wrote assets/AppIcon.png")
