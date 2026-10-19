import AppKit
let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
for size in [16,32,64,128,256,512,1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    rep.size = NSSize(width:size,height:size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
    let s = CGFloat(size)
    let tile = NSBezierPath(roundedRect:NSRect(x:s*0.06,y:s*0.06,width:s*0.88,height:s*0.88),xRadius:s*0.20,yRadius:s*0.20)
    NSGradient(starting:NSColor(calibratedRed:0.20,green:0.51,blue:0.96,alpha:1),ending:NSColor(calibratedRed:0.13,green:0.33,blue:0.76,alpha:1))!.draw(in:tile,angle:-90)
    NSColor.white.setStroke()
    let book = NSBezierPath(); book.lineWidth=s*0.045; book.lineCapStyle = .round; book.lineJoinStyle = .round
    book.move(to:NSPoint(x:s*0.5,y:s*0.29));book.line(to:NSPoint(x:s*0.5,y:s*0.70))
    book.curve(to:NSPoint(x:s*0.25,y:s*0.75),controlPoint1:NSPoint(x:s*0.40,y:s*0.77),controlPoint2:NSPoint(x:s*0.31,y:s*0.77))
    book.line(to:NSPoint(x:s*0.25,y:s*0.34));book.curve(to:NSPoint(x:s*0.5,y:s*0.29),controlPoint1:NSPoint(x:s*0.34,y:s*0.36),controlPoint2:NSPoint(x:s*0.43,y:s*0.34))
    book.curve(to:NSPoint(x:s*0.75,y:s*0.34),controlPoint1:NSPoint(x:s*0.57,y:s*0.34),controlPoint2:NSPoint(x:s*0.66,y:s*0.36))
    book.line(to:NSPoint(x:s*0.75,y:s*0.75));book.curve(to:NSPoint(x:s*0.5,y:s*0.70),controlPoint1:NSPoint(x:s*0.69,y:s*0.77),controlPoint2:NSPoint(x:s*0.60,y:s*0.77));book.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let data=rep.representation(using:.png,properties:[:])!
    // iconutil requires base sizes and retina aliases.
    if [16,32,128,256,512].contains(size) { try data.write(to:root.appendingPathComponent("icon_\(size)x\(size).png")) }
    if [32,64,256,512,1024].contains(size) { try data.write(to:root.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
