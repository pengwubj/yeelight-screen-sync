import Foundation

enum CoreTests {
    static func run() {
        func analyze(_ pixels: [UInt8], width: Int = 20, height: Int = 20, stride: Int = 80) -> RGB {
            pixels.withUnsafeBufferPointer { ColorAnalysis.dominant(bgra:$0.baseAddress!,width:width,height:height,stride:stride) }
        }
        let red = [[UInt8]](repeating:[0,0,255,255],count:400).flatMap{$0}
        precondition(analyze(red).packed == 0xff0000,"BGRA channel order")
        let blue = [[UInt8]](repeating:[255,0,0,255],count:400).flatMap{$0}
        precondition(analyze(blue).packed == 0x0000ff,"Blue extraction")
        precondition(analyze([UInt8](repeating:0,count:1600)).packed == 0,"Black scene")
        let white = [[UInt8]](repeating:[255,255,255,255],count:400).flatMap{$0}
        precondition(analyze(white).packed == 0xffffff,"Neutral scene")
        var mixed = red
        for i in 0..<400 where i%20 < 7 {
            mixed[i*4] = 255; mixed[i*4+2] = 0
        }
        precondition(analyze(mixed).packed == 0xff0000,"Dominant colour must not average to purple")
        let smooth = RGB(255,0,0).blended(with:RGB(0,0,255),amount:0.5)
        precondition(smooth.packed == 0x800080,"Temporal smoothing")
        precondition(RGB(-10,270,0).packed == 0x00ff00,"RGB clamping")
        var convergence = RGB(255,0,0)
        for _ in 0..<100 { convergence = convergence.blended(with:RGB(0,0,255),amount:0.25) }
        precondition(convergence.packed == 0x0000ff,"Static-frame smoothing convergence")
        var padded = [UInt8]()
        for _ in 0..<20 { padded += Array(red.prefix(80)) + [1,2,3,4,5,6,7,8] }
        precondition(analyze(padded,stride:88).packed == 0xff0000,"Pixel row stride")
        precondition(RGB(color:RGB(packed:0xff0000).color).packed == 0xff0000,"Exact sRGB colour presets")
        precondition(analyze(red,width:0,height:20,stride:0).packed == 0,"Empty pixel buffer dimensions")
        func scene(_ pixel: (Int,Int) -> RGB) -> [UInt8] {
            (0..<20).flatMap { y in (0..<20).flatMap { x -> [UInt8] in
                let value = pixel(x,y).packed
                return [UInt8(value & 255),UInt8((value >> 8) & 255),UInt8((value >> 16) & 255),255]
            } }
        }
        let greyAccent = scene { x,_ in x < 4 ? RGB(255,0,0) : RGB(128,128,128) }
        precondition(analyze(greyAccent).packed == 0x808080,"Small saturated accent must not override neutral majority")
        let whiteAccent = scene { x,_ in x < 4 ? RGB(0,0,255) : RGB(255,255,255) }
        precondition(analyze(whiteAccent).packed == 0xffffff,"White document with a small blue accent")
        let redMajority = scene { x,_ in x < 13 ? RGB(255,0,0) : RGB(128,128,128) }
        precondition(analyze(redMajority).packed == 0xff0000,"Coloured majority still wins over neutrals")
        let darkRed = scene { _,_ in RGB(32,0,0) }
        precondition(analyze(darkRed).packed == 0x200000,"Dark colours must not be normalized to full intensity")
        let hueBoundary = scene { x,_ in x < 10 ? RGB(255,8,0) : RGB(255,0,8) }
        precondition(analyze(hueBoundary).packed == 0xff0404,"Red hue wraparound combines adjacent colours")
        let letterbox = scene { _,y in (5..<15).contains(y) ? RGB(128,64,0) : RGB(0,0,0) }
        precondition(analyze(letterbox).packed == 0x804000,"Black letterbox bars do not dilute the picture colour")
        let nearBlack = scene { _,_ in RGB(16,0,0) }
        precondition(analyze(nearBlack).packed == 0,"Near-black scene stays black")
        print("PASS: 18 colour analysis and smoothing checks")
    }
}
