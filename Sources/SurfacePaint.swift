import AppKit

// Original strokes remain vectors. Only the small compositing preview is cached.
// Masks and analysis files are immutable snapshots, so undo/reanalysis never changes old strokes.
enum SurfacePaint {
    static func material(_ stroke: Ink, binding: SurfaceBinding, scene: SceneData, mask: [UInt8]) -> CGImage? {
        guard scene.valid(), mask.count == scene.count else { return nil }
        var average = 0.0, total = 0.0
        for i in 0..<scene.count where mask[i] > 0 {
            let weight = Double(mask[i]) / 255
            let lum = (0.2126 * Double(scene.rgb[i * 3]) + 0.7152 * Double(scene.rgb[i * 3 + 1]) + 0.0722 * Double(scene.rgb[i * 3 + 2])) / 255
            average += lum * weight; total += weight
        }
        average = max(0.05, average / max(1, total))
        var pixels = [UInt8](repeating: 0, count: scene.count * 4)
        for i in 0..<scene.count {
            let alpha = binding.reference.outline == nil ? Double(mask[i]) / 255 : 1.0
            let lum = (0.2126 * Double(scene.rgb[i * 3]) + 0.7152 * Double(scene.rgb[i * 3 + 1]) + 0.0722 * Double(scene.rgb[i * 3 + 2])) / 255
            let gain = (1 - binding.shading) + binding.shading * min(1.45, max(0.12, lum / average))
            let factor=alpha*255
            pixels[i*4]=UInt8(clamping:Int(min(1,max(0,stroke.red*gain))*factor))
            pixels[i*4+1]=UInt8(clamping:Int(min(1,max(0,stroke.green*gain))*factor))
            pixels[i*4+2]=UInt8(clamping:Int(min(1,max(0,stroke.blue*gain))*factor))
            pixels[i * 4 + 3] = mask[i]
        }
        return SceneWorker.raster(pixels, width: scene.width, height: scene.height)
    }
    static func render(_ stroke: Ink, binding: SurfaceBinding, scene: SceneData, mask: [UInt8]) -> CGImage? {
        guard scene.valid(), mask.count == scene.count else { return nil }
        let w = scene.width, h = scene.height, f = binding.reference.frame
        guard f.width > 0, f.height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: scene.count * 4)
        rgba.withUnsafeMutableBytes { bytes in
            guard let cg = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            cg.translateBy(x: 0, y: Double(h)); cg.scaleBy(x: 1, y: -1)
            let sx = Double(w) / f.width, sy = Double(h) / f.height
            // Stamp in top-down bitmap coordinates, exactly matching the AI arrays.
            // Keep the brush centerline exactly on the captured cursor path.
            // Geometry projection must never remap a freehand gesture.
            cg.scaleBy(x: sx, y: sy)
            cg.setStrokeColor(CGColor(gray: 1, alpha: 1))
            cg.setLineWidth(stroke.width); cg.setLineCap(.round); cg.setLineJoin(.round)
            cg.beginPath()
            if let first = stroke.points.first {
                cg.move(to: CGPoint(x: first.x - f.x, y: first.y - f.y))
                if stroke.points.count == 1 { cg.addLine(to: CGPoint(x: first.x - f.x + 0.01, y: first.y - f.y)) }
                for p in stroke.points.dropFirst() { cg.addLine(to: CGPoint(x: p.x - f.x, y: p.y - f.y)) }
                cg.strokePath()
            }
        }
        var average = 0.0, total = 0.0
        for i in 0..<scene.count where mask[i] > 0 {
            let weight = Double(mask[i]) / 255
            let lum = (0.2126 * Double(scene.rgb[i * 3]) + 0.7152 * Double(scene.rgb[i * 3 + 1]) + 0.0722 * Double(scene.rgb[i * 3 + 2])) / 255
            average += lum * weight; total += weight
        }
        average = max(0.05, average / max(1, total))
        for i in 0..<scene.count {
            let alpha = Double(rgba[i * 4 + 3]) / 255 * Double(mask[i]) / 255
            let lum = (0.2126 * Double(scene.rgb[i * 3]) + 0.7152 * Double(scene.rgb[i * 3 + 1]) + 0.0722 * Double(scene.rgb[i * 3 + 2])) / 255
            // Photo luminance transfers visible shadows AND texture; it is not an albedo solve.
            let gain = (1 - binding.shading) + binding.shading * min(1.45, max(0.12, lum / average))
            for (c, value) in [stroke.red, stroke.green, stroke.blue].enumerated() {
                rgba[i * 4 + c] = UInt8(clamping: Int(min(1, max(0, value * gain)) * alpha * 255))
            }
            rgba[i * 4 + 3] = UInt8(clamping: Int(alpha * 255))
        }
        return SceneWorker.raster(rgba, width: w, height: h)
    }
}

extension SurfacePaint{
    /// Match the photo renderer's pixel resolution for shading/texture transfer;
    /// model-resolution RGB is an analysis input, not the final paint texture.
    static func photoMaterial(_ stroke:Ink,binding:SurfaceBinding,scene:SceneData,mask:[UInt8],photo:CGImage)->CGImage?{
        let w=photo.width,h=photo.height
        guard mask.count==scene.count,w>0,h>0,w*h<=8_000_000,
              let cg=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let rgb=cg.data?.assumingMemoryBound(to:UInt8.self)else{return nil}
        cg.draw(photo,in:CGRect(x:0,y:0,width:w,height:h))
        let sw=scene.width,sh=scene.height
        let xs=(0..<w).map{x->(Int,Int,Double) in let f=max(0,min(Double(sw-1),(Double(x)+0.5)/Double(w)*Double(sw)-0.5)),a=Int(f);return(a,min(sw-1,a+1),f-Double(a))}
        let ys=(0..<h).map{y->(Int,Int,Double) in let f=max(0,min(Double(sh-1),(Double(y)+0.5)/Double(h)*Double(sh)-0.5)),a=Int(f);return(a,min(sh-1,a+1),f-Double(a))}
        func alpha(_ x:Int,_ y:Int)->Double{
            let (x0,x1,tx)=xs[x],(y0,y1,ty)=ys[y]
            return ((Double(mask[y0*sw+x0])*(1-tx)+Double(mask[y0*sw+x1])*tx)*(1-ty)+(Double(mask[y1*sw+x0])*(1-tx)+Double(mask[y1*sw+x1])*tx)*ty)/255
        }
        var sum=0.0,weight=0.0
        for y in 0..<h{for x in 0..<w{
            let i=y*cg.bytesPerRow+x*4,a=alpha(x,y)
            sum += (0.2126*Double(rgb[i])+0.7152*Double(rgb[i+1])+0.0722*Double(rgb[i+2]))/255*a;weight += a
        }}
        let average=max(0.05,sum/max(1,weight))
        for y in 0..<h{for x in 0..<w{
            let i=y*cg.bytesPerRow+x*4,opacity=alpha(x,y)
            let lum=(0.2126*Double(rgb[i])+0.7152*Double(rgb[i+1])+0.0722*Double(rgb[i+2]))/255
            let gain=(1-binding.shading)+binding.shading*min(1.45,max(0.12,lum/average))
            let a=binding.reference.outline == nil ? opacity:1
            rgb[i]=UInt8(clamping:Int(min(1,max(0,stroke.red*gain))*a*255))
            rgb[i+1]=UInt8(clamping:Int(min(1,max(0,stroke.green*gain))*a*255))
            rgb[i+2]=UInt8(clamping:Int(min(1,max(0,stroke.blue*gain))*a*255))
            rgb[i+3]=UInt8(clamping:Int(opacity*255))
        }}
        return cg.makeImage()
    }
}
