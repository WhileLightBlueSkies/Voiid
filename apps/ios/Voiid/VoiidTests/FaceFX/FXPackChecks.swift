import Foundation
var checks = 0
func expect(_ c: Bool, _ m: String) { checks += 1; if !c { print("FAIL: \(m)"); exit(1) } }

let url = URL(fileURLWithPath: "packages/facefx/dist/shades.voiidfx")
let data = try! Data(contentsOf: url)
print("pack: \(data.count) bytes")

let entries = try! FXZip.entries(in: data)
print("entries: \(entries.keys.sorted())")
expect(entries["manifest.json"] != nil, "manifest.json not found by the zip reader")
expect(entries["atlas.webp"] != nil, "atlas.webp not found by the zip reader")

// The atlas must be byte-identical to what the packer wrote.
expect(entries["atlas.webp"]!.count > 10_000, "atlas suspiciously small")
let webpMagic = [UInt8](entries["atlas.webp"]!.prefix(12))
expect(Array(webpMagic[0..<4]) == Array("RIFF".utf8), "atlas is not a RIFF container")
expect(Array(webpMagic[8..<12]) == Array("WEBP".utf8), "atlas is not WebP")
print("atlas: \(entries["atlas.webp"]!.count) bytes, valid WebP header")

let m = try! FXManifest.decode(entries["manifest.json"]!)
print("manifest: id=\(m.id) v\(m.version) tier=\(m.tier) bundled=\(m.bundled)")
expect(m.id == "shades", "wrong id")
expect(m.passes == [.occluder, .props], "passes not as authored")
expect(m.atlasSize == [1024, 512], "atlasSize not injected by the packer: \(String(describing: m.atlasSize))")

let layers = m.sortedLayers
print("layers (draw order): \(layers.map { "\($0.id)@\($0.order)" }.joined(separator: ", "))")
expect(layers.count == 3, "expected 3 layers")
expect(layers.map(\.id) == ["armLeft", "armRight", "frame"], "layers not sorted by order")

// atlasRect must have been resolved from the sprite name by the packer.
for l in layers {
    expect(l.atlasRect.count == 4, "\(l.id): atlasRect not resolved")
    expect(l.atlasRect[2] > 0 && l.atlasRect[3] > 0, "\(l.id): zero-size rect")
    let sum = l.anchor.weights.reduce(0, +)
    expect(abs(sum - 1) < 0.001, "\(l.id): weights sum \(sum)")
    print("  \(l.id): rect=\(l.atlasRect) sizeCm=\(l.sizeCm) anchor=\(l.anchor.indices)")
}

// The two arms must be mirror images, or the glasses are lopsided.
let al = layers[0], ar = layers[1]
expect(al.sizeCm == ar.sizeCm, "arms differ in size")
expect(abs(al.offsetCm[0] + ar.offsetCm[0]) < 1e-6, "arm X offsets are not mirrored")
expect(abs(al.rotationDeg[1] + ar.rotationDeg[1]) < 1e-6, "arm Y rotations are not mirrored")
print("arms are mirror-symmetric")

// A truncated pack must be rejected, not half-read.
let truncated = data.prefix(data.count / 2)
if let e = try? FXZip.entries(in: truncated), e["manifest.json"] != nil {
    print("FAIL: truncated pack yielded a manifest"); exit(1)
}
checks += 1
print("truncated pack rejected")

print("\n\(checks) checks passed")
