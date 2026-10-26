import AppKit

/// Transfers an immutable image result to the utility rasterizer without view graphics state.
struct ThumbnailImageSource: @unchecked Sendable {
  private let pixels: CGImage?
  private let image: NSImage?

  init(_ image: CGImage) {
    pixels = image
    self.image = nil
  }
  init(_ image: NSImage) {
    pixels = nil
    self.image = image
  }

  func rasterize(size: CGSize) -> CGImage? {
    guard !Thread.isMainThread else { return nil }
    return autoreleasepool {
      var proposed = CGRect(origin: .zero, size: size)
      guard
        let source = pixels ?? image?.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
        let space = CGColorSpace(name: CGColorSpace.sRGB)
      else { return nil }
      let width = max(1, Int(size.width.rounded(.up)))
      let height = max(1, Int(size.height.rounded(.up)))
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      let scale = max(
        CGFloat(width) / CGFloat(source.width), CGFloat(height) / CGFloat(source.height))
      let bounds = CGRect(
        x: (CGFloat(width) - CGFloat(source.width) * scale) / 2,
        y: (CGFloat(height) - CGFloat(source.height) * scale) / 2,
        width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
      context.interpolationQuality = .high
      context.draw(source, in: bounds)
      return context.makeImage()
    }
  }
}
