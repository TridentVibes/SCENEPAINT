import AppKit

enum DrawingAssist:String,Codable,CaseIterable,Identifiable{
    case freehand="Freehand",line="Straight line",curve="Curve assist",rectangle="Rectangle",ellipse="Ellipse",triangle="Triangle"
    var id:String{rawValue}
    var isShape:Bool{self == .rectangle || self == .ellipse || self == .triangle}
}
enum DrawingGeometry{
    static func points(_ raw:[Dot],assist:DrawingAssist,constrained:Bool=false)->[Dot]{
        guard let a=raw.first,var b=raw.last,raw.count>1 else{return raw}
        if constrained{
            if assist.isShape{let d=max(abs(b.x-a.x),abs(b.y-a.y));b=Dot(x:a.x+(b.x<a.x ? -d:d),y:a.y+(b.y<a.y ? -d:d))}
            else if assist == .line{let angle=(atan2(b.y-a.y,b.x-a.x)/(.pi/4)).rounded()*(.pi/4),d=hypot(b.x-a.x,b.y-a.y);b=Dot(x:a.x+cos(angle)*d,y:a.y+sin(angle)*d)}
        }
        switch assist{
        case .freehand:return raw
        case .line:return [a,b]
        case .rectangle:return [a,Dot(x:b.x,y:a.y),b,Dot(x:a.x,y:b.y),a]
        case .triangle:return [Dot(x:(a.x+b.x)/2,y:a.y),b,Dot(x:a.x,y:b.y),Dot(x:(a.x+b.x)/2,y:a.y)]
        case .ellipse:
            return (0...96).map{i in let t=Double(i)*2 * .pi/96;return Dot(x:(a.x+b.x)/2+abs(b.x-a.x)/2*cos(t),y:(a.y+b.y)/2+abs(b.y-a.y)/2*sin(t))}
        case .curve:
            // Fit a single quadratic to the gesture, keeping both endpoints fixed.
            var distances=[0.0]
            for i in 1..<raw.count{distances.append(distances.last!+hypot(raw[i].x-raw[i-1].x,raw[i].y-raw[i-1].y))}
            guard let length=distances.last,length>0.1 else{return [a,b]}
            var cx=0.0,cy=0.0,den=0.0
            for i in raw.indices{let t=distances[i]/length,k=2*t*(1-t);cx += k*(raw[i].x-pow(1-t,2)*a.x-t*t*b.x);cy += k*(raw[i].y-pow(1-t,2)*a.y-t*t*b.y);den += k*k}
            guard den>0.0001 else{return [a,b]}
            let c=Dot(x:cx/den,y:cy/den),steps=min(512,max(24,Int(length/2)))
            return (0...steps).map{i in let t=Double(i)/Double(steps);return Dot(x:pow(1-t,2)*a.x+2*t*(1-t)*c.x+t*t*b.x,y:pow(1-t,2)*a.y+2*t*(1-t)*c.y+t*t*b.y)}
        }
    }
    static func path(_ points:[Dot],smooth:Bool,closed:Bool=false)->CGPath{
        let p=CGMutablePath();guard let first=points.first else{return p}
        p.move(to:CGPoint(x:first.x,y:first.y))
        if smooth && !closed && points.count>2{
            for i in 0..<points.count-1{
                let a=points[max(0,i-1)],b=points[i],c=points[i+1],d=points[min(points.count-1,i+2)]
                // Bounded tangents avoid spikes at tight turns and noisy input.
                let limit=hypot(c.x-b.x,c.y-b.y)/3
                func tangent(_ x:Double,_ y:Double)->CGPoint{let n=hypot(x,y),s=n>limit && n>0 ? limit/n:1;return CGPoint(x:x*s,y:y*s)}
                let u=tangent((c.x-a.x)/6,(c.y-a.y)/6),v=tangent((d.x-b.x)/6,(d.y-b.y)/6)
                p.addCurve(to:CGPoint(x:c.x,y:c.y),control1:CGPoint(x:b.x+u.x,y:b.y+u.y),control2:CGPoint(x:c.x-v.x,y:c.y-v.y))
            }
        }else{for b in points.dropFirst(){p.addLine(to:CGPoint(x:b.x,y:b.y))}}
        if closed{p.closeSubpath()}
        if points.count==1{p.addLine(to:CGPoint(x:first.x+0.001,y:first.y))}
        return p
    }
}

enum AlbedoEstimate{
    static func rgba(_ scene:SceneData)->[UInt8]{
        let w=scene.width,h=scene.height,stride=w+1
        var integral=[Double](repeating:0,count:(w+1)*(h+1))
        for y in 0..<h{var sum=0.0;for x in 0..<w{let i=(y*w+x)*3;sum += (0.2126*Double(scene.rgb[i])+0.7152*Double(scene.rgb[i+1])+0.0722*Double(scene.rgb[i+2]))/255;integral[(y+1)*stride+x+1]=integral[y*stride+x+1]+sum}}
        let mean=max(0.08,integral.last!/Double(w*h)),radius=max(4,min(w,h)/14)
        var out=[UInt8](repeating:255,count:w*h*4)
        for y in 0..<h{for x in 0..<w{
            let x0=max(0,x-radius),x1=min(w,x+radius+1),y0=max(0,y-radius),y1=min(h,y+radius+1)
            let sum=integral[y1*stride+x1]-integral[y0*stride+x1]-integral[y1*stride+x0]+integral[y0*stride+x0]
            let illumination=max(0.25,min(2.5,sum/Double((x1-x0)*(y1-y0))/mean))
            for c in 0..<3{out[(y*w+x)*4+c]=UInt8(clamping:Int(Double(scene.rgb[(y*w+x)*3+c])/pow(illumination,0.8))) }
        }}
        return out
    }
}
