import AppKit
// Usage: glyphstat label=path[@x,y,w,h] ...   (optional region in image pixels, origin top-left)
// Background = most common colour in the (region of the) image; glyph pixels = pixels >= 1.5:1 against it.
func lum(_ r: UInt8,_ g: UInt8,_ b: UInt8) -> Double {
  func c(_ v: UInt8) -> Double { let x = Double(v)/255; return x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055, 2.4) }
  return 0.2126*c(r)+0.7152*c(g)+0.0722*c(b)
}
for arg in CommandLine.arguments.dropFirst() {
  let parts = arg.split(separator: "=", maxSplits: 1); let label = String(parts[0])
  let spec = String(parts[1]).split(separator: "@", maxSplits: 1); let file = String(spec[0])
  guard let img = NSImage(contentsOfFile: file), let full = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print(label, "load failed"); continue }
  var cg = full
  if spec.count == 2 {
    let n = spec[1].split(separator: ",").compactMap { Double($0) }
    if n.count == 4, let c = full.cropping(to: CGRect(x: n[0], y: n[1], width: n[2], height: n[3])) { cg = c }
  }
  let w = cg.width, h = cg.height; var d = [UInt8](repeating: 0, count: w*h*4)
  let ctx = CGContext(data: &d, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
  var hist: [UInt32: Int] = [:]; var lums: [Double] = []
  for i in stride(from: 0, to: d.count, by: 4) { let k = UInt32(d[i])<<16 | UInt32(d[i+1])<<8 | UInt32(d[i+2]); hist[k, default: 0] += 1; lums.append(lum(d[i],d[i+1],d[i+2])) }
  let bgk = hist.max { $0.value < $1.value }!.key
  let bg = lum(UInt8(bgk>>16 & 0xFF), UInt8(bgk>>8 & 0xFF), UInt8(bgk & 0xFF))
  let ratios = lums.map { (max($0,bg)+0.05)/(min($0,bg)+0.05) }.filter { $0 >= 1.5 }.sorted()
  func pct(_ p: Double) -> Double { ratios.isEmpty ? 0 : ratios[min(ratios.count-1, Int(Double(ratios.count)*p))] }
  print(label, "\(w)x\(h)", String(format: "bg #%06X", bgk), "glyph px", ratios.count, String(format: "p50 %.2f p75 %.2f p90 %.2f max %.2f", pct(0.5), pct(0.75), pct(0.9), ratios.last ?? 0))
}
