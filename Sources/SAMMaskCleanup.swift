import Foundation

// Remove isolated prediction specks and tiny enclosed pinholes. No erosion or
// expansion of the main boundary; explicit include/exclude points are protected.
enum SAMMaskCleanup {
    static func apply(_ input: [UInt8], width: Int, height: Int, points: [SegmentPoint]) -> [UInt8] {
        guard width > 0, height > 0, input.count == width*height else { return input }
        var result = input
        let anchors = points.map { p in (min(height-1,max(0,Int(p.y*Double(height))))*width+min(width-1,max(0,Int(p.x*Double(width)))),p.label) }
        for foreground in [true,false] {
            var visited = [Bool](repeating:false,count:input.count)
            for seed in input.indices where !visited[seed] && (input[seed]>=128)==foreground {
                var queue=[seed];visited[seed]=true
                var cursor=0,touchesBorder=false
                while cursor<queue.count {
                    let i=queue[cursor];cursor += 1
                    let x=i%width,y=i/width
                    if x==0 || y==0 || x==width-1 || y==height-1 {touchesBorder=true}
                    for j in [x>0 ? i-1 : -1,x+1<width ? i+1 : -1,y>0 ? i-width : -1,y+1<height ? i+width : -1] where j>=0 {
                        if !visited[j] && (input[j]>=128)==foreground {visited[j]=true;queue.append(j)}
                    }
                }
                let small = foreground ? queue.count<=24 : !touchesBorder && queue.count<=6
                if small && !anchors.contains(where: { ($0.1==1)==foreground && queue.contains($0.0) }) {
                    for i in queue {result[i]=foreground ? 0 : 255}
                }
            }
        }
        return result
    }
}
