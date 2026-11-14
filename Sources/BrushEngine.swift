import AppKit

enum BrushPreset: String, Codable, CaseIterable, Identifiable {
    case hard = "Hard Round", soft = "Soft Round", pencil = "Pencil", marker = "Marker", chisel = "Chisel", dry = "Dry Bristle", airbrush = "Airbrush"
    var id: String { rawValue }
    var settings: BrushSettings {
        switch self {
        case .hard: return BrushSettings(preset:self,hardness:1,flow:1,spacing:0.15,angle:0,roundness:1)
        case .soft: return BrushSettings(preset:self,hardness:0.15,flow:0.45,spacing:0.14,angle:0,roundness:1)
        case .pencil: return BrushSettings(preset:self,hardness:0.85,flow:0.7,spacing:0.12,angle:0,roundness:1)
        case .marker: return BrushSettings(preset:self,hardness:0.9,flow:0.35,spacing:0.12,angle:35,roundness:0.65)
        case .chisel: return BrushSettings(preset:self,hardness:1,flow:0.8,spacing:0.1,angle:40,roundness:0.2)
        case .dry: return BrushSettings(preset:self,hardness:0.8,flow:0.65,spacing:0.12,angle:15,roundness:0.6)
        case .airbrush: return BrushSettings(preset:self,hardness:0,flow:0.1,spacing:0.08,angle:0,roundness:1)
        }
    }
    var defaultSize: Double {
        switch self { case .hard:return 16;case .soft:return 50;case .pencil:return 4;case .marker:return 28;case .chisel:return 32;case .dry:return 30;case .airbrush:return 80 }
    }
}
struct BrushSettings: Codable, Equatable {
    var preset: BrushPreset = .hard
    var hardness = 1.0
    var flow = 1.0
    var spacing = 0.15
    var angle = 0.0
    var roundness = 1.0
}
enum BrushEngine {
    static func draw(_ stroke: Ink, in cg: CGContext) {
        guard let first=stroke.points.first else{return}
        let settings=stroke.brush ?? BrushPreset.hard.settings
        let width=max(0.1,stroke.width), flow=max(0,min(1,settings.flow))
        let color=CGColor(red:stroke.red,green:stroke.green,blue:stroke.blue,alpha:flow)
        cg.saveGState();defer{cg.restoreGState()}
        cg.setShouldAntialias(true)
        if stroke.filled == true{
            cg.setFillColor(CGColor(red:stroke.red,green:stroke.green,blue:stroke.blue,alpha:flow))
            cg.addPath(DrawingGeometry.path(stroke.points,smooth:false,closed:true));cg.fillPath();return
        }
        if settings.preset == .hard && settings.hardness >= 0.98 && settings.roundness >= 0.999 {
            cg.setStrokeColor(color);cg.setLineWidth(width);cg.setLineCap(.round);cg.setLineJoin(.round)
            cg.addPath(DrawingGeometry.path(stroke.points,smooth:stroke.smooth ?? false,closed:stroke.closed == true))
            cg.strokePath();return
        }
        let step=max(0.25,width*min(0.12,max(0.02,settings.spacing))), radius=width/2
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let transparent=CGColor(red:stroke.red,green:stroke.green,blue:stroke.blue,alpha:0)
        let gradient=CGGradient(colorsSpace:space,colors:[color,transparent] as CFArray,locations:[0,1])
        var dabIndex=0
        func noise(_ seed:Int)->Double{
            var n=UInt64(truncatingIfNeeded:seed)&*2862933555777941757&+3037000493
            n ^= n>>21;n ^= n<<17;n ^= n>>9
            return Double(n&0xffff)/65535
        }
        func dab(_ p:CGPoint){
            cg.saveGState();defer{cg.restoreGState()}
            cg.translateBy(x:p.x,y:p.y);cg.rotate(by:settings.angle * .pi/180)
            cg.scaleBy(x:1,y:max(0.05,settings.roundness))
            switch settings.preset {
            case .hard,.soft,.airbrush:
                if let gradient {
                    let inner=radius*max(0,min(0.98,settings.hardness))
                    cg.drawRadialGradient(gradient,startCenter:.zero,startRadius:inner,endCenter:.zero,endRadius:radius,options:.drawsBeforeStartLocation)
                }
            case .pencil,.dry:
                let bristles=settings.preset == .pencil ? 5 : 13
                for b in 0..<bristles {
                    let seed=dabIndex*37+b*173
                    if noise(seed+5)<(settings.preset == .dry ? 0.32:0.12){continue}
                    let a=noise(seed)*2 * .pi,r=sqrt(noise(seed+1))*radius
                    let size=max(0.35,radius*(settings.preset == .pencil ? 0.2:0.13))
                    cg.setFillColor(CGColor(red:stroke.red,green:stroke.green,blue:stroke.blue,alpha:flow*(0.25+0.6*noise(seed+2))))
                    cg.fillEllipse(in:CGRect(x:cos(a)*r-size/2,y:sin(a)*r-size/2,width:size,height:size))
                }
            case .chisel:
                cg.setFillColor(color);cg.fill(CGRect(x:-radius,y:-radius,width:width,height:width))
            default:
                cg.setFillColor(color);cg.fillEllipse(in:CGRect(x:-radius,y:-radius,width:width,height:width))
            }
            dabIndex += 1
        }
        dab(CGPoint(x:first.x,y:first.y))
        var carried=0.0
        for i in 1..<max(1,stroke.points.count){
            let a=stroke.points[i-1],b=stroke.points[i],length=hypot(b.x-a.x,b.y-a.y)
            guard length>0 else{continue}
            var distance=step-carried
            while distance<=length {
                let t=distance/length
                dab(CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t));distance += step
            }
            carried=length-(distance-step)
        }
    }
}

struct ToolPreferences: Codable {
    var brush:BrushSettings
    var size:Double
    var opacity:Double
    var ink:[Double]
    var text:TextSettings
    var textOpacity:Double
    var textInput:String
    var regionChoice:Int
    var topography:BrushTopography? = nil
    var textSurface:SurfaceTextSettings? = nil
    var drawingAssist:DrawingAssist? = nil
    var fillShapes:Bool? = nil
    var smoothLines:Bool? = nil
    var preserveShading:Bool? = nil
    var bucketUseAI:Bool? = nil
    var bucketTolerance:Double? = nil
}
