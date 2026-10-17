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
        print("PASS: 11 colour analysis and smoothing checks")
    }
}
