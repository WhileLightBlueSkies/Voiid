import UIKit
import ImageIO
import Foundation

// Verbatim copies of the two bounding mechanisms from AvatarCache.swift.
let maxPixelSize: CGFloat = 768

func downsample(_ data: Data) -> UIImage? {
    let opts = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
    let thumbOpts = [
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ] as CFDictionary
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return nil }
    return UIImage(cgImage: cg, scale: 1, orientation: .up)
}

func cost(_ image: UIImage) -> Int {
    let px = image.size.width * image.scale * image.size.height * image.scale
    return Int(px * 4)
}

func makeJPEG(w: Int, h: Int) -> Data {
    let r = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
    let img = r.image { ctx in
        UIColor.systemTeal.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        UIColor.systemPink.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: w/2, height: h/2))
    }
    return img.jpegData(compressionQuality: 0.9)!
}

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print((cond ? "PASS  " : "FAIL  ") + name + (cond ? "" : "  -- " + detail))
    if !cond { failures += 1 }
}

// 1. A camera-sized photo must not be decoded at full size.
let big = makeJPEG(w: 4000, h: 3000)
let naive = UIImage(data: big)!
let bounded = downsample(big)!
let naiveCost = cost(naive), boundedCost = cost(bounded)
print("   full-size decode: \(naiveCost/1024/1024)MB   downsampled: \(boundedCost/1024/1024)MB")
check("a 4000x3000 photo is downsampled",
      max(bounded.size.width, bounded.size.height) <= maxPixelSize,
      "got \(bounded.size)")
check("downsampling cuts resident memory by >10x",
      boundedCost * 10 < naiveCost,
      "\(naiveCost) vs \(boundedCost)")

// 2. Aspect ratio must survive (a squashed avatar is a visible bug).
let ratioIn = 4000.0/3000.0
let ratioOut = Double(bounded.size.width / bounded.size.height)
check("aspect ratio is preserved", abs(ratioIn - ratioOut) < 0.02, "\(ratioIn) vs \(ratioOut)")

// 3. A small avatar must not be UPscaled.
// NOTE: makeJPEG renders at the screen scale (3x), so makeJPEG(120,120) is a
// 360x360-PIXEL file. Comparing its output against 120 was comparing pixels to
// points and reported a phantom "upscale" that never happened — the assertion was
// wrong, not the code. Compare against the source's real pixel dimensions.
let small = makeJPEG(w: 120, h: 120)
let smallSrc = CGImageSourceCreateWithData(small as CFData, nil)!
let smallProps = CGImageSourceCopyPropertiesAtIndex(smallSrc, 0, nil) as! [CFString: Any]
let smallPx = smallProps[kCGImagePropertyPixelWidth] as! CGFloat
let smallOut = downsample(small)!
check("a small image is not upscaled",
      smallOut.size.width <= smallPx, "source \(smallPx)px -> got \(smallOut.size)")

// 4. Garbage must be refused, not decoded.
check("non-image data is refused", downsample(Data(repeating: 0xAB, count: 4096)) == nil)
check("empty data is refused", downsample(Data()) == nil)
check("an HTML error page is refused",
      downsample("<html><body>403 Forbidden</body></html>".data(using: .utf8)!) == nil)

// 5. The cost bound must actually evict.
let cache = NSCache<NSString, UIImage>()
cache.totalCostLimit = 48 * 1024 * 1024
cache.countLimit = 512
// 600 distinct avatars, each ~2.3MB decoded => ~1.4GB if nothing is evicted.
// DISTINCT instances, one per ref — as the real cache holds. An earlier version of
// this harness inserted the SAME UIImage under 600 keys, so NSCache saw one live
// object and evicted nothing; the "failure" was the test's, not the cache's.
let per = cost(downsample(makeJPEG(w: 768, h: 768))!)
for i in 0..<600 {
    cache.setObject(downsample(makeJPEG(w: 768, h: 768))!, forKey: "ref-\(i)" as NSString, cost: per)
}
var live = 0
for i in 0..<600 where cache.object(forKey: "ref-\(i)" as NSString) != nil { live += 1 }
print("   \(live)/600 avatars retained, ~\(live*per/1024/1024)MB (unbounded would be ~\(600*per/1024/1024)MB)")
check("the cache evicts rather than growing without limit", live < 600, "all 600 retained")
check("retained bytes stay near the stated bound",
      live * per <= 64*1024*1024, "\(live*per/1024/1024)MB retained")

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
