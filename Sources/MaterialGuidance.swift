import Foundation

// These are prompts to the learned model, never a color-threshold clipping mask.
// Only confidently different, interior material patches become exclusion hints.
enum MaterialGuidance {
    static func exclusions(scene:SceneData,mask:[UInt8],seed:SegmentPoint)->[SegmentPoint]{
        guard scene.valid(),mask.count==scene.count else{return []}
        let w=scene.width,h=scene.height
        func color(_ x:Int,_ y:Int)->[Double]{
            var rgb=[Double](repeating:0,count:3),count=0.0
            for yy in max(0,y-2)...min(h-1,y+2){for xx in max(0,x-2)...min(w-1,x+2){
                for c in 0..<3{rgb[c] += Double(scene.rgb[(yy*w+xx)*3+c])/255};count += 1
            }}
            return rgb.map{$0/count}
        }
        func distance(_ a:[Double],_ b:[Double])->Double{sqrt(zip(a,b).reduce(0){$0+pow($1.0-$1.1,2)})}
        let sx=min(w-1,max(0,Int(seed.x*Double(w)))),sy=min(h-1,max(0,Int(seed.y*Double(h))))
        let target=color(sx,sy)
        var candidates:[(SegmentPoint,[Double],Double)]=[]
        let step=max(4,min(w,h)/64)
        for y in stride(from:4,to:h-4,by:step){for x in stride(from:4,to:w-4,by:step){
            guard mask[y*w+x]>250,mask[(y-3)*w+x]>250,mask[(y+3)*w+x]>250,mask[y*w+x-3]>250,mask[y*w+x+3]>250 else{continue}
            let px=Double(x)/Double(w),py=Double(y)/Double(h)
            guard hypot(px-seed.x,py-seed.y)>0.12 else{continue}
            let rgb=color(x,y),difference=distance(rgb,target)
            guard difference>0.28 else{continue}
            let sample=(0..<3).map{Double(scene.rgb[(y*w+x)*3+$0])/255}
            guard distance(rgb,sample)<0.16 else{continue}
            candidates.append((SegmentPoint(x:px,y:py,label:0),rgb,difference))
        }}
        candidates.sort{$0.2>$1.2}
        var chosen:[(SegmentPoint,[Double])]=[]
        for candidate in candidates{
            if chosen.allSatisfy({hypot($0.0.x-candidate.0.x,$0.0.y-candidate.0.y)>0.10 && distance($0.1,candidate.1)>0.18}){
                chosen.append((candidate.0,candidate.1));if chosen.count==3{break}
            }
        }
        return chosen.map{$0.0}
    }
}
