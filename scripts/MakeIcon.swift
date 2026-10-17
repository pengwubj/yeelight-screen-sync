import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:destination,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size*scale
        let image = NSImage(size:NSSize(width:pixels,height:pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let outline = NSBezierPath(roundedRect:NSRect(x:p*0.06,y:p*0.06,width:p*0.88,height:p*0.88),xRadius:p*0.20,yRadius:p*0.20)
        let gradient = NSGradient(starting:NSColor(red:0.12,green:0.16,blue:0.24,alpha:1),ending:NSColor(red:0.025,green:0.035,blue:0.065,alpha:1))!
        gradient.draw(in:outline,angle:-90)
        let glow = NSGradient(starting:NSColor(red:1,green:0.48,blue:0.15,alpha:0.85),ending:NSColor(red:0.5,green:0.18,blue:1,alpha:0.04))!
        glow.draw(in:NSBezierPath(roundedRect:NSRect(x:p*0.16,y:p*0.25,width:p*0.68,height:p*0.45),xRadius:p*0.12,yRadius:p*0.12),angle:90)
        NSColor(red:0.19,green:0.23,blue:0.33,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:p*0.22,y:p*0.29,width:p*0.56,height:p*0.40),xRadius:p*0.045,yRadius:p*0.045).fill()
        NSColor(red:0.04,green:0.06,blue:0.10,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:p*0.25,y:p*0.33,width:p*0.50,height:p*0.31),xRadius:p*0.025,yRadius:p*0.025).fill()
        NSColor(red:1,green:0.75,blue:0.42,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:p*0.17,y:p*0.66,width:p*0.66,height:p*0.065),xRadius:p*0.03,yRadius:p*0.03).fill()
        NSColor(red:0.58,green:0.64,blue:0.75,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:p*0.47,y:p*0.22,width:p*0.06,height:p*0.08),xRadius:p*0.01,yRadius:p*0.01).fill()
        NSBezierPath(roundedRect:NSRect(x:p*0.36,y:p*0.20,width:p*0.28,height:p*0.035),xRadius:p*0.015,yRadius:p*0.015).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
        let data = bitmap.representation(using:.png,properties:[:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to:URL(fileURLWithPath:destination).appendingPathComponent(name))
    }
}
