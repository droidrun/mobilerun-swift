// Copyright 2026 Mobilerun
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Decode/crop through CoreGraphics; write PNG evidence and normalized RGBA bytes for comparison.
let args = CommandLine.arguments
precondition(args.count == 8, "source target x y width height raw-output")
let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let rect = CGRect(x: Int(args[3])!, y: Int(args[4])!, width: Int(args[5])!, height: Int(args[6])!)
precondition(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= CGFloat(image.width)
    && rect.maxY <= CGFloat(image.height), "crop exceeds image")
let cropped = image.cropping(to: rect)!
let width = cropped.width
let height = cropped.height
var bytes = Data(count: width * height * 4)
bytes.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue)!
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
}
try bytes.write(to: URL(fileURLWithPath: args[7]))
let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, cropped, nil)
precondition(CGImageDestinationFinalize(destination))
