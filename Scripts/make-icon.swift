// Draws Airbag's app icon: a stitched, inflated shield (an airbag) with the undo arrow moulded on it, on a cobalt
// squircle. The cushion is lit from a height field (a membrane under pressure), so it reads as soft fabric. Small sizes
// get their own drawings with a bolder arrow and no stitching. Writes Resources/AppIcon.icns, AppIcon-1024.png and
// AirbagMark-1024.png (the cushion alone, for cards).
//   swiftc -O Scripts/make-icon.swift -o build/make-icon && build/make-icon .      (make icon)
import AppKit
import simd

let S = 2048                      // supersampled canvas; design units are the 1024 macOS icon grid
let k = Double(S) / 1024

/// One drawing of the icon. Below 128 px the arrow gets heavier, the shield a little larger, and fine detail goes.
struct Variant {
    var shieldScale = 1.0
    var uC = (x: 552.0, y: 516.0), uR = 76.0, uW = 54.0              // the U-turn: bend centre, radius, stroke
    var headBase = 430.0, headTip = 366.0, headHalf = 52.0, headRound = 10.0, tailX = 456.0
    var stitches = true, spec = 1.0, ink = 0x1747D6, inkDeep = 0x0B237A
    var cast = 0.34, contact = 0.30, glow = 0.07, edgeLight = 0.30, drop = 0.24
}
let master = Variant()
var v64 = master
v64.uW = 64; v64.headHalf = 60; v64.headTip = 356; v64.headRound = 12; v64.stitches = false; v64.spec = 0.7
var v32 = master
v32.shieldScale = 1.08; v32.uC = (556, 516); v32.uR = 84; v32.uW = 76; v32.headHalf = 66; v32.headTip = 340
v32.headRound = 12; v32.tailX = 462; v32.stitches = false; v32.spec = 0.45; v32.ink = 0x123CC0
v32.cast = 0.22; v32.contact = 0.24; v32.glow = 0; v32.edgeLight = 0
var v16 = v32
v16.shieldScale = 1.14; v16.uR = 90; v16.uW = 90; v16.headHalf = 78; v16.headTip = 322; v16.spec = 0
v16.cast = 0.14; v16.contact = 0.20; v16.drop = 0

// MARK: geometry (design units, y down)

/// macOS icon body: 824-point squircle centred on the 1024 grid.
func bodyPath() -> CGPath {
    let p = CGMutablePath(), c = 512.0, a = 412.0, n = 5.0
    for i in 0..<1440 {
        let t = Double(i) / 1440 * 2 * .pi
        let x = c + a * copysign(pow(abs(cos(t)), 2 / n), cos(t)), y = c + a * copysign(pow(abs(sin(t)), 2 / n), sin(t))
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

/// A shield as pressure would shape it: an arched top, sides bowing out, a softened point.
func shieldPath(scale: Double) -> CGPath {
    let p = CGMutablePath(), cy = 520.0
    func q(_ m: Double, _ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: 512 + scale * m * (x - 512), y: cy + scale * (y - cy))
    }
    let half: [(Double, Double, Double, Double, Double, Double)] = [
        (430, 212, 350, 224, 296, 250),
        (260, 266, 244, 296, 244, 342),
        (244, 420, 248, 470, 260, 520),
        (290, 662, 400, 780, 488, 814),
        (500, 819, 507, 822, 512, 822)]
    p.move(to: q(1, 512, 212))
    for s in half { p.addCurve(to: q(1, s.4, s.5), control1: q(1, s.0, s.1), control2: q(1, s.2, s.3)) }
    // The mirrored half, walked back from the point to the top centre.
    let starts = [(512.0, 212.0)] + half.map { ($0.4, $0.5) }
    for i in stride(from: half.count - 1, through: 0, by: -1) {
        let s = half[i]
        p.addCurve(to: q(-1, starts[i].0, starts[i].1), control1: q(-1, s.2, s.3), control2: q(-1, s.0, s.1))
    }
    p.closeSubpath()
    return p
}

func segSDF(_ x: Double, _ y: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
    let pax = x - ax, pay = y - ay, bax = bx - ax, bay = by - ay
    let h = max(0, min(1, (pax * bax + pay * bay) / (bax * bax + bay * bay)))
    let dx = pax - bax * h, dy = pay - bay * h
    return (dx * dx + dy * dy).squareRoot()
}

/// The undo arrow (the ⌘Z U-turn): a bend on the right, a lower arm with a round end, an upper arm into the head.
func arrowSDF(_ x: Double, _ y: Double, _ v: Variant) -> Double {
    let bend = x >= v.uC.x ? abs(((x - v.uC.x) * (x - v.uC.x) + (y - v.uC.y) * (y - v.uC.y)).squareRoot() - v.uR) - v.uW / 2 : 1e9
    let top = segSDF(x, y, v.uC.x, v.uC.y - v.uR, v.headBase + 6, v.uC.y - v.uR) - v.uW / 2
    let bottom = segSDF(x, y, v.uC.x, v.uC.y + v.uR, v.tailX, v.uC.y + v.uR) - v.uW / 2
    let ty = v.uC.y - v.uR
    let tri = triangleSDF(x, y, (v.headBase, ty - v.headHalf), (v.headBase, ty + v.headHalf), (v.headTip, ty)) - v.headRound
    let body = min(bend, top, bottom)
    // Smooth union, so the arm flows into the head without a notch.
    let blend = max(10 - abs(body - tri), 0) / 10
    return min(body, tri) - blend * blend * 10 / 4
}

/// Signed distance to a triangle (after Inigo Quilez's sdTriangle).
func triangleSDF(_ x: Double, _ y: Double, _ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double)) -> Double {
    func sub(_ u: (Double, Double), _ v: (Double, Double)) -> (Double, Double) { (u.0 - v.0, u.1 - v.1) }
    func dot(_ u: (Double, Double), _ v: (Double, Double)) -> Double { u.0 * v.0 + u.1 * v.1 }
    let e0 = sub(b, a), e1 = sub(c, b), e2 = sub(a, c)
    let v0 = sub((x, y), a), v1 = sub((x, y), b), v2 = sub((x, y), c)
    func seg(_ v: (Double, Double), _ e: (Double, Double)) -> (Double, Double) {
        let t = max(0, min(1, dot(v, e) / dot(e, e))); return (v.0 - e.0 * t, v.1 - e.1 * t)
    }
    let pq0 = seg(v0, e0), pq1 = seg(v1, e1), pq2 = seg(v2, e2)
    let s = (e0.0 * e2.1 - e0.1 * e2.0) > 0 ? 1.0 : -1.0
    let d = min(dot(pq0, pq0), dot(pq1, pq1), dot(pq2, pq2))
    let sg = min(s * (v0.0 * e0.1 - v0.1 * e0.0), s * (v1.0 * e1.1 - v1.1 * e1.0), s * (v2.0 * e2.1 - v2.1 * e2.0))
    return -d.squareRoot() * (sg > 0 ? 1 : (sg < 0 ? -1 : 0))
}

// MARK: raster helpers

func rasterize(_ path: CGPath) -> [Double] {
    var buf = [UInt8](repeating: 0, count: S * S)
    let ctx = CGContext(data: &buf, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(S)); ctx.scaleBy(x: CGFloat(k), y: -CGFloat(k))
    ctx.setFillColor(gray: 1, alpha: 1); ctx.addPath(path); ctx.fillPath()
    // With the flip, the first rows in memory are the design's top rows: the buffer is y-down like the design units.
    return buf.map { Double($0) / 255 }
}

/// Euclidean distance (canvas pixels) from each covered pixel to the nearest uncovered one (Felzenszwalb–Huttenlocher).
func distanceInside(_ cov: [Double]) -> [Double] {
    let inf = 1e20
    var f = cov.map { $0 >= 0.5 ? inf : 0 }
    func pass(_ get: (Int) -> Double, _ set: (Int, Double) -> Void, _ n: Int) {
        var v = [Int](repeating: 0, count: n), z = [Double](repeating: 0, count: n + 1), d = [Double](repeating: 0, count: n)
        var j = 0; z[0] = -inf; z[1] = inf
        func cross(_ q: Int, _ p: Int) -> Double { ((get(q) + Double(q * q)) - (get(p) + Double(p * p))) / Double(2 * q - 2 * p) }
        for q in 1..<n {
            var s = cross(q, v[j])
            while s <= z[j] { j -= 1; s = cross(q, v[j]) }
            j += 1; v[j] = q; z[j] = s; z[j + 1] = inf
        }
        j = 0
        for q in 0..<n { while z[j + 1] < Double(q) { j += 1 }; d[q] = Double((q - v[j]) * (q - v[j])) + get(v[j]) }
        for q in 0..<n { set(q, d[q]) }
    }
    for x in 0..<S { pass({ f[$0 * S + x] }, { f[$0 * S + x] = $1 }, S) }
    for y in 0..<S { pass({ f[y * S + $0] }, { f[y * S + $0] = $1 }, S) }
    return f.map { $0.squareRoot() }
}

func blur(_ a: [Double], _ sigma: Double) -> [Double] {
    // Three box passes each way approximate a Gaussian.
    let r = max(1, Int((sigma * sigma + 1).squareRoot()))
    var src = a, dst = a
    for _ in 0..<3 {
        for y in 0..<S {
            var acc = 0.0
            let row = y * S
            for x in -r...r { acc += src[row + min(max(x, 0), S - 1)] }
            for x in 0..<S {
                dst[row + x] = acc / Double(2 * r + 1)
                acc += src[row + min(x + r + 1, S - 1)] - src[row + max(x - r, 0)]
            }
        }
        swap(&src, &dst)
        for x in 0..<S {
            var acc = 0.0
            for y in -r...r { acc += src[min(max(y, 0), S - 1) * S + x] }
            for y in 0..<S {
                dst[y * S + x] = acc / Double(2 * r + 1)
                acc += src[min(y + r + 1, S - 1) * S + x] - src[max(y - r, 0) * S + x]
            }
        }
        swap(&src, &dst)
    }
    return src
}

/// Height of a membrane under pressure over the mask (∇²h = −1 inside, 0 outside), scaled to 0…1: how a cushion
/// inflates, smooth everywhere, with no creases along the middle. Solved coarse to fine with red-black SOR.
func inflate(_ cov: [Double]) -> [Double] {
    var h: [Double] = [], n = 0
    for g in [128, 256, 512] {
        let f = S / g
        var inside = [Bool](repeating: false, count: g * g)
        for y in 0..<g {
            for x in 0..<g {
                var s = 0.0
                for yy in 0..<f { for xx in 0..<f { s += cov[(y * f + yy) * S + x * f + xx] } }
                inside[y * g + x] = s / Double(f * f) > 0.5
            }
        }
        var cur = [Double](repeating: 0, count: g * g)
        if n > 0 { for y in 0..<g { for x in 0..<g where inside[y * g + x] { cur[y * g + x] = h[(y / 2) * n + x / 2] } } }
        let step2 = pow(1024 / Double(g), 2), omega = 1.92
        for _ in 0..<(g == 512 ? 700 : 900) {
            for parity in 0..<2 {
                for y in 1..<(g - 1) {
                    var x = 1 + ((y + parity) & 1)
                    while x < g - 1 {
                        let i = y * g + x
                        if inside[i] { cur[i] += omega * ((cur[i - 1] + cur[i + 1] + cur[i - g] + cur[i + g] + step2) / 4 - cur[i]) }
                        x += 2
                    }
                }
            }
        }
        h = cur; n = g
    }
    var out = [Double](repeating: 0, count: S * S)
    let f = Double(n) / Double(S)
    for y in 0..<S {
        let sy = (Double(y) + 0.5) * f - 0.5, y0 = max(0, min(n - 1, Int(sy.rounded(.down)))), y1 = min(n - 1, y0 + 1)
        let ty = max(0, min(1, sy - Double(y0)))
        for x in 0..<S {
            let sx = (Double(x) + 0.5) * f - 0.5, x0 = max(0, min(n - 1, Int(sx.rounded(.down)))), x1 = min(n - 1, x0 + 1)
            let tx = max(0, min(1, sx - Double(x0)))
            let a = h[y0 * n + x0] * (1 - tx) + h[y0 * n + x1] * tx, b = h[y1 * n + x0] * (1 - tx) + h[y1 * n + x1] * tx
            out[y * S + x] = a * (1 - ty) + b * ty
        }
    }
    let m = out.max() ?? 1
    return out.map { $0 / m }
}

func shifted(_ a: [Double], dy: Int) -> [Double] {
    var out = [Double](repeating: 0, count: S * S)
    for y in 0..<S where y - dy >= 0 && y - dy < S { for x in 0..<S { out[y * S + x] = a[(y - dy) * S + x] } }
    return out
}

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }
func hex(_ v: Int) -> SIMD3<Double> { SIMD3(Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255)) / 255 }

// MARK: render

/// Premultiplied RGBA on the 2048 canvas. `markOnly` leaves out the panel: the cushion and its shadow on transparency.
func render(_ v: Variant, markOnly: Bool = false) -> [SIMD4<Double>] {
    let body = rasterize(bodyPath()), shield = rasterize(shieldPath(scale: v.shieldScale))
    let bodyIn = distanceInside(body), shieldIn = distanceInside(shield)
    let dropShadow = blur(shifted(body, dy: Int(8 * k)), 18 * k)
    let castShadow = blur(shifted(shield, dy: Int(20 * k)), 22 * k), contact = blur(shifted(shield, dy: Int(4 * k)), 5 * k)

    // The cushion's height in canvas pixels: the inflated membrane, a stitched seam near the edge, and the arrow raised
    // on top with a flat face and a soft bevel, like a moulded rubber badge.
    let membrane = inflate(shield), lift = 150 * k
    var height = [Double](repeating: 0, count: S * S), glyph = [Double](repeating: 0, count: S * S)
    for i in 0..<(S * S) where shield[i] > 0 {
        let y = Double(i / S) / k, x = Double(i % S) / k
        var h = lift * pow(membrane[i], 0.5) * smoothstep(0, 3 * k, shieldIn[i])
        if v.stitches {
            let seam = (shieldIn[i] / k - 18) / 2.6
            let stitch = smoothstep(0.15, 0.55, cos(atan2(y - 520, x - 512) * 72))
            h -= (1.2 + 4.0 * stitch) * k * exp(-seam * seam)
        }
        let g = arrowSDF(x, y, v) * k                                    // canvas px, negative inside the arrow
        glyph[i] = 1 - smoothstep(-0.8 * k, 0.8 * k, g - 1.2 * k)        // ink reaches just past the bevel's foot
        let crown = min(max(-g / (v.uW / 2 * k), 0), 1)
        h += 11 * k * smoothstep(0, 10 * k, -g) + 4 * k * (1 - (1 - crown) * (1 - crown))   // a slight crown across the stroke
        height[i] = h
    }
    height = blur(height, 1.0 * k)
    let arrowShadow = blur(shifted(glyph, dy: Int(6 * k)), 6 * k)

    let light = simd_normalize(SIMD3<Double>(-0.30, 0.75, 0.60)), view = SIMD3<Double>(0, 0, 1)
    let halfway = simd_normalize(light + view)
    let sky = hex(0x4C8DFF), azure = hex(0x2459EA), indigo = hex(0x1E2FB8), ink = hex(v.ink), inkDeep = hex(v.inkDeep)
    let fabric = hex(0xF4F7FD), fabricShade = hex(0xA3B2D6)

    var out = [SIMD4<Double>](repeating: .zero, count: S * S)
    for y in 0..<S {
        for x in 0..<S {
            let i = y * S + x
            let u = Double(x) / Double(S), w = Double(y) / Double(S)
            // Panel: lit from the top like the cushion, cobalt deepening downwards, a faint glow at the top edge.
            let t = 0.15 * u + 0.85 * w
            var bg = t < 0.5 ? mix(sky, azure, smoothstep(0.05, 0.5, t)) : mix(azure, indigo, smoothstep(0.5, 1.0, t))
            let gx = u - 0.5, gy = w - 0.04
            bg += SIMD3(repeating: v.glow) * exp(-(gx * gx + gy * gy) / 0.10)
            bg *= 1 - (v.cast * castShadow[i] + v.contact * contact[i])
            bg = mix(bg, SIMD3(repeating: 1), exp(-bodyIn[i] / (2.2 * k)) * smoothstep(0.62, 0.15, w) * v.edgeLight)

            var col = bg
            if shield[i] > 0 {
                let hx = (height[min(i + 1, S * S - 1)] - height[max(i - 1, 0)]) / 2
                let hy = (height[min(i + S, S * S - 1)] - height[max(i - S, 0)]) / 2
                let n = simd_normalize(SIMD3(-hx, hy, 1.0))              // rows run down, the light's y runs up
                let wrap = max(0, (simd_dot(n, light) + 0.25) / 1.25), nh = max(simd_dot(n, halfway), 0)
                var c = mix(fabricShade, fabric, min(1, 0.04 + 0.98 * wrap))
                c += SIMD3(repeating: v.spec * (0.08 * pow(nh, 10) + 0.16 * pow(nh, 56) + 0.05 * pow(1 - n.z, 2)))
                // Light bounced from the panel onto the lower, outward-facing roll.
                c = mix(c, mix(bg, SIMD3(repeating: 1), 0.35), 0.30 * max(0, -n.y) * (1 - n.z))
                c *= 1 - 0.20 * arrowShadow[i] * (1 - glyph[i])
                let inkCol = mix(inkDeep, ink, min(1, 0.35 + 0.8 * wrap)) + SIMD3(repeating: v.spec * 0.38 * pow(nh, 90))
                c = mix(c, inkCol, glyph[i])
                col = mix(bg, c, shield[i])
            }
            if markOnly {
                // The cushion alone; its shadow becomes a translucent navy.
                let sa = 0.35 * castShadow[i] * (1 - shield[i])
                out[i] = SIMD4(col * shield[i] + hex(0x050F45) * sa, shield[i] + sa)
                continue
            }
            let a = body[i]
            out[i] = SIMD4(col * a, a + v.drop * dropShadow[i] * (1 - a))   // premultiplied; the drop shadow is black
        }
    }
    return out
}

/// Box-averages exact blocks of the canvas down to `size`: crisper small sizes than resampling.
func image(_ px: [SIMD4<Double>], size: Int) -> CGImage {
    let f = S / size
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            var s = SIMD4<Double>.zero
            for yy in 0..<f { for xx in 0..<f { s += px[(y * f + yy) * S + x * f + xx] } }
            s /= Double(f * f)
            let o = (y * size + x) * 4
            for (j, c) in [s.x, s.y, s.z, s.w].enumerated() { bytes[o + j] = UInt8(max(0, min(255, (c * 255).rounded()))) }
        }
    }
    return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

func write(_ img: CGImage, to url: URL) {
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let res = root.appendingPathComponent("Resources")
let big = render(master)
write(image(big, size: 1024), to: res.appendingPathComponent("AppIcon-1024.png"))
write(image(render(master, markOnly: true), size: 1024), to: res.appendingPathComponent("AirbagMark-1024.png"))
let small = [16: render(v16), 32: render(v32), 64: render(v64)]
let iconset = res.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        write(image(small[px] ?? big, size: px), to: iconset.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", res.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote Resources/AppIcon.icns, AppIcon-1024.png and AirbagMark-1024.png")
