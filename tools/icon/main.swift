// Renders the Menfez icon set from MenfezCore/LogoMark.swift.
//
//   tools/make-icon.sh            (compiles this with LogoMark.swift and runs it)
//
// Arguments: <output dir>. Writes icon.png (1024), AppIcon.iconset/*.png and
// menubar-{idle,flow,flowBadge}.png (22 pt @2x template previews).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func write(_ image: CGImage?, _ path: String) {
    guard let image,
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot render \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(path)") }
}

let out = CommandLine.arguments.dropFirst().first ?? "."
let iconset = "\(out)/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

write(LogoMark.appIcon(size: 1024), "\(out)/icon.png")
for s in [16, 32, 128, 256, 512] {
    write(LogoMark.appIcon(size: s), "\(iconset)/icon_\(s)x\(s).png")
    write(LogoMark.appIcon(size: s * 2), "\(iconset)/icon_\(s)x\(s)@2x.png")
}
for (name, v) in [("idle", LogoMark.Variant.idle), ("flow", .flow), ("flowBadge", .flowBadge)] {
    write(LogoMark.template(v), "\(out)/menubar-\(name).png")
}
