import AppKit

// Validate both generated PNGs and the actual multi-resolution TIFF in the DMG.
// Pixel dimensions / DPI alone cannot detect artwork drawn with a doubled CTM.
func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw NSError(domain: "NookInstallerArtwork", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func normalizedPixels(_ representation: NSBitmapImageRep, width: Int, height: Int) throws -> [UInt8] {
    guard let image = representation.cgImage else {
        throw NSError(domain: "NookInstallerArtwork", code: 2)
    }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "NookInstallerArtwork", code: 3)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return pixels
}

do {
    try require(CommandLine.arguments.count >= 3,
        "Usage: validate-background.swift layout.json image [image ...]")
    let layoutData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let layout = try JSONSerialization.jsonObject(with: layoutData) as! [String: Int]
    let width = layout["width"]!
    let height = layout["height"]!
    var representations: [Int: NSBitmapImageRep] = [:]
    for path in CommandLine.arguments.dropFirst(2) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let images = NSBitmapImageRep.imageReps(with: data).compactMap { $0 as? NSBitmapImageRep }
        try require(!images.isEmpty, "Unreadable installer background: \(path)")
        for image in images {
            let scale = image.pixelsWide / width
            try require([1, 2].contains(scale) && image.pixelsWide == width * scale
                && image.pixelsHigh == height * scale, "Incorrect background pixel dimensions")
            try require(abs(image.size.width - CGFloat(width)) < 0.1
                && abs(image.size.height - CGFloat(height)) < 0.1,
                "Incorrect background logical size / DPI at \(scale)x")
            try require(representations[scale] == nil, "Duplicate background representation at \(scale)x")
            representations[scale] = image
        }
    }
    try require(Set(representations.keys) == Set([1, 2]), "Background must include both 1x and 2x representations")
    let standard = try normalizedPixels(representations[1]!, width: width, height: height)
    let retina = try normalizedPixels(representations[2]!, width: width, height: height)
    var difference = 0.0
    for index in standard.indices where index % 4 != 3 {
        difference += Double(abs(Int(standard[index]) - Int(retina[index]))) / 255
    }
    let error = difference / Double(width * height * 3)
    // Allow font antialiasing and downsampling differences, not moved/cropped art.
    try require(error < 0.008,
        String(format: "1x/2x artwork is misaligned (mean pixel difference %.4f)", error))
    print(String(format: "Verified 1x/2x artwork: %d × %d points, difference %.4f", width, height, error))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
