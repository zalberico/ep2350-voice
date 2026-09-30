// Original vector geometry; no external assets or dependencies.
// Regenerate with:
// xcrun swift tools/generate-ios-probe-icon.swift ios/EP2350Probe/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-ios-probe-icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let side = 1024
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: side * 4,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not create opaque icon context")
}

// Leave the square corners intact; iOS applies its own app-icon mask.
context.setFillColor(CGColor(red: 0.045, green: 0.055, blue: 0.065, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: side, height: side))
let yellow = CGColor(red: 1, green: 0.77, blue: 0.26, alpha: 1)
context.setFillColor(yellow)
context.addPath(CGPath(roundedRect: CGRect(x: 420, y: 411, width: 184, height: 364),
                       cornerWidth: 92, cornerHeight: 92, transform: nil))
context.fillPath()

context.setStrokeColor(yellow)
context.setLineWidth(48)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 332, y: 560))
context.addLine(to: CGPoint(x: 332, y: 463))
context.addCurve(to: CGPoint(x: 512, y: 283),
                 control1: CGPoint(x: 332, y: 363),
                 control2: CGPoint(x: 412, y: 283))
context.addCurve(to: CGPoint(x: 692, y: 463),
                 control1: CGPoint(x: 612, y: 283),
                 control2: CGPoint(x: 692, y: 363))
context.addLine(to: CGPoint(x: 692, y: 560))
context.strokePath()
context.move(to: CGPoint(x: 512, y: 283))
context.addLine(to: CGPoint(x: 512, y: 211))
context.move(to: CGPoint(x: 408, y: 211))
context.addLine(to: CGPoint(x: 616, y: 211))
context.strokePath()

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL,
                                                        UTType.png.identifier as CFString,
                                                        1, nil) else {
    fatalError("Could not create icon output")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write icon") }
print("Generated opaque 1024 × 1024 icon: \(outputURL.path)")
