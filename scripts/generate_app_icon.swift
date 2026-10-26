#!/usr/bin/env swift
// Renders KeepOne's app icon variants (light, dark, tinted) at 1024×1024.
// Concept: several similar frames fanned behind → one selected frame in front.
// Usage: swift scripts/generate_app_icon.swift KeepOne/Resources/Assets.xcassets/AppIcon.appiconset

import AppKit
import CoreGraphics
import Foundation

enum Variant { case light, dark, tinted }

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "."

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(_ variant: Variant) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let full = CGRect(x: 0, y: 0, width: size, height: size)

    // Background.
    let bgColors: [CGColor]
    switch variant {
    case .light: bgColors = [color(0xF9FAFC), color(0xE6EAF1)]
    case .dark: bgColors = [color(0x202226), color(0x0B0C0E)]
    case .tinted: bgColors = [color(0x000000), color(0x000000)]
    }
    let bg = CGGradient(colorsSpace: space, colors: bgColors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: 0), options: [])

    // Fanned back frames (the "many similar shots").
    let card = CGSize(width: 520, height: 640)
    let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2 - 10)
    let backTones: [CGColor]
    switch variant {
    case .light: backTones = [color(0xC9CFDA), color(0xD7DCE5), color(0xE3E7EE)]
    case .dark: backTones = [color(0x3A3D44), color(0x30333A), color(0x2A2C31)]
    case .tinted: backTones = [color(0x5A5A5A), color(0x6E6E6E), color(0x828282)]
    }
    let angles: [CGFloat] = [-16, -9, -3]
    let offsets: [CGFloat] = [-70, -42, -16]
    for (i, angle) in angles.enumerated() {
        ctx.saveGState()
        ctx.translateBy(x: center.x + offsets[i], y: center.y + abs(offsets[i]) * 0.35)
        ctx.rotate(by: angle * .pi / 180)
        let rect = CGRect(x: -card.width / 2, y: -card.height / 2, width: card.width, height: card.height)
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x000000, variant == .light ? 0.10 : 0.35))
        ctx.addPath(roundedRect(rect, radius: 56))
        ctx.setFillColor(backTones[i])
        ctx.fillPath()
        ctx.restoreGState()
    }

    // The selected frame.
    ctx.saveGState()
    ctx.translateBy(x: center.x + 34, y: center.y - 12)
    ctx.rotate(by: 4 * .pi / 180)
    let front = CGRect(x: -card.width / 2, y: -card.height / 2, width: card.width, height: card.height)
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, variant == .light ? 0.18 : 0.5))
    ctx.addPath(roundedRect(front, radius: 56))
    ctx.setFillColor(variant == .dark ? color(0xF2F2F5) : (variant == .tinted ? color(0xDDDDDD) : color(0xFFFFFF)))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Photo inside the frame: a calm landscape gradient with a sun.
    let inset = front.insetBy(dx: 34, dy: 34)
    let photo = CGRect(x: inset.minX, y: inset.minY + 120, width: inset.width, height: inset.height - 120)
    ctx.saveGState()
    ctx.addPath(roundedRect(photo, radius: 30))
    ctx.clip()
    let photoColors: [CGColor] = variant == .tinted
        ? [color(0xBBBBBB), color(0x777777)]
        : [color(0x5AC8FA), color(0x0A64D8)]
    let pg = CGGradient(colorsSpace: space, colors: photoColors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(pg, start: CGPoint(x: photo.midX, y: photo.maxY), end: CGPoint(x: photo.midX, y: photo.minY), options: [])
    ctx.setFillColor(variant == .tinted ? color(0xEEEEEE) : color(0xFFE38A))
    ctx.fillEllipse(in: CGRect(x: photo.maxX - 170, y: photo.maxY - 170, width: 96, height: 96))
    let hills = CGMutablePath()
    hills.move(to: CGPoint(x: photo.minX, y: photo.minY))
    hills.addLine(to: CGPoint(x: photo.minX, y: photo.minY + 120))
    hills.addQuadCurve(to: CGPoint(x: photo.midX + 20, y: photo.minY + 90), control: CGPoint(x: photo.minX + 140, y: photo.minY + 250))
    hills.addQuadCurve(to: CGPoint(x: photo.maxX, y: photo.minY + 170), control: CGPoint(x: photo.maxX - 120, y: photo.minY + 20))
    hills.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
    hills.closeSubpath()
    ctx.addPath(hills)
    ctx.setFillColor(variant == .tinted ? color(0x555555) : color(0x0B3F8A, 0.85))
    ctx.fillPath()
    ctx.restoreGState()

    // Check badge: "this one".
    let badgeCenter = CGPoint(x: front.maxX - 40, y: front.minY + 40)
    let badge = CGRect(x: badgeCenter.x - 92, y: badgeCenter.y - 92, width: 184, height: 184)
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, 0.25))
    ctx.setFillColor(variant == .tinted ? color(0xFFFFFF) : color(0x34C759))
    ctx.fillEllipse(in: badge)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setStrokeColor(variant == .tinted ? color(0x000000) : color(0xFFFFFF))
    ctx.setLineWidth(26)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: badgeCenter.x - 44, y: badgeCenter.y + 2))
    ctx.addLine(to: CGPoint(x: badgeCenter.x - 12, y: badgeCenter.y - 32))
    ctx.addLine(to: CGPoint(x: badgeCenter.x + 48, y: badgeCenter.y + 36))
    ctx.strokePath()
    ctx.restoreGState()

    var image = ctx.makeImage()!
    if variant == .tinted {
        // Tinted icons must be grayscale.
        let gray = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        gray.draw(image, in: full)
        image = gray.makeImage()!
    }
    return image
}

func write(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

write(render(.light), to: "\(output)/AppIcon.png")
write(render(.dark), to: "\(output)/AppIcon-Dark.png")
write(render(.tinted), to: "\(output)/AppIcon-Tinted.png")
