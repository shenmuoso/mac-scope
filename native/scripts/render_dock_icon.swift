import AppKit

guard CommandLine.arguments.count == 3 else {
  fatalError("Usage: render_dock_icon.swift input.png output.png")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSImage(contentsOf: input) else {
  fatalError("Unable to load icon: \(input.path)")
}

// Icon Composer exports the mask edge-to-edge; Dock images include the macOS 10% inset.
let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { bounds in
  source.draw(in: bounds.insetBy(dx: 102.4, dy: 102.4))
  return true
}
guard let tiff = image.tiffRepresentation,
  let bitmap = NSBitmapImageRep(data: tiff),
  let png = bitmap.representation(using: .png, properties: [:])
else { fatalError("Unable to render Dock icon") }
try png.write(to: output)
