import AppKit
import SwiftUI

@MainActor extension Editor {
    static let toolCycle:[Tool]=Tool.allCases
    func activateTool(_ next:Tool){
        tool=next
        if next == .text{selected=nil;textInput="text here";inspectorTab="Text"}
        else if next == .brush || next == .wrapBrush || next == .eraser || next == .bucket{inspectorTab="Brush";if next == .wrapBrush{surfaceMode=painting.scene != nil; if let ref=painting.scene{Task{await prepareBrushResources(ref)}}}}
        else if next == .surface || next == .outline || next == .maskAdd || next == .maskRemove{inspectorTab="Surface"}
    }
    func cycleTool(_ direction:Int){
        let cycle=Self.toolCycle
        let index=cycle.firstIndex(of:tool) ?? 0
        let next=cycle[max(0,min(cycle.count-1,index+direction))]
        if next != tool{activateTool(next)}
    }
    func cycleLayer(_ direction:Int){
        let layers=Array(displayedLayers.reversed());guard !layers.isEmpty else{return}
        let next=layers.firstIndex(where:{$0.id==selected}).map{max(0,min(layers.count-1,$0+direction))} ?? (direction>0 ? 0:layers.count-1)
        selectLayer(layers[next].id)
    }
    func cycleViewport(_ direction:Int){
        let planes=Plane.allCases,index=Plane.allCases.firstIndex(of:plane) ?? 0
        switchViewport(planes[max(0,min(planes.count-1,index+direction))])
    }
    func switchViewport(_ next:Plane){
        guard plane != next else{return};requestInteractivePreview();plane=next;selectedStroke=nil
        if next == .albedo{ensureAlbedoMap()}
        if !displayedLayers.contains(where:{$0.id==selected}){selected=displayedLayers.last?.id}
        syncSelectionControls()
    }
    @discardableResult func navigateKey(_ key:String)->Bool{
        switch key.lowercased(){
        case "a":cycleTool(-1)
        case "z":cycleTool(1)
        case "s":cycleLayer(-1)
        case "x":cycleLayer(1)
        case "q":cycleViewport(-1)
        case "w":cycleViewport(1)
        default:return false
        };return true
    }
    func setTextWrapWarning(_ id:UUID,_ message:String?){
        guard textWrapWarnings[id] != message else{return}
        Task{[weak self] in
            guard let self,self.textWrapWarnings[id] != message else{return}
            self.textWrapWarnings[id]=message
        }
    }
    static var defaultTextSurface:SurfaceTextSettings{SurfaceTextSettings(enabled:false,curvature:0,followDepth:0,depthRelief:1,depthDirection:-90,engine:2)}
    func textGeometryReference(_ layer:Layer)->SceneReference?{
        if let owner=Relighter.owner(of:layer,editor:self),let photo=painting.layers.first(where:{$0.id==owner}),let ref=Relighter.reference(for:photo,editor:self){return ref}
        return layer.surface?.reference
    }
    var selectedTextSurface:SurfaceTextSettings{
        guard let i=activeIndex,painting.layers[i].text != nil else{return textSurfaceSettings}
        return painting.layers[i].textSurface ?? Self.defaultTextSurface
    }
    func changeTextSurface(_ edit:(inout SurfaceTextSettings)->Void){
        var next=selectedTextSurface;edit(&next);if next.enabled{next.engine=2}else if let selected{setTextWrapWarning(selected,nil)};textSurfaceSettings=next
        guard let i=activeIndex,painting.layers[i].text != nil else{return}
        inspectorEdit("surface-text"){painting.layers[i].textSurface=next}
    }
    func syncSelectionControls(){
        guard let i=activeIndex else { selectedStroke=nil; return }
        let layer=painting.layers[i]
        if let j=selectedStroke,!layer.strokes.indices.contains(j){selectedStroke=nil}
        if let text=layer.text {textSurfaceSettings=layer.textSurface ?? Self.defaultTextSurface;textInput=text;textSettings=layer.textSettings ?? TextSettings(size:layer.fontSize,bold:true);textOpacity=layer.opacity}
    }
    func makeInk(_ points:[Dot],erasing:Bool=false)->Ink{
        let c=NSColor(color).usingColorSpace(.deviceRGB) ?? .orange
        return Ink(brush:brushSettings,topography:erasing || tool != .wrapBrush || plane != .artwork ? nil:brushTopography,opacity:brushOpacity,eraser:erasing,smooth:smoothLines,closed:drawingAssist.isShape,filled:drawingAssist.isShape && fillShapes,photoShading:preserveShading,materialPaint:preserveShading && plane == .artwork && !erasing,invertSelection:paintArea == .outside,points:points,width:max(0.1,min(500,brushSize)),red:c.redComponent,green:c.greenComponent,blue:c.blueComponent)
    }
    func chooseBrush(_ preset:BrushPreset){brushSettings=preset.settings;brushSize=preset.defaultSize;if tool != .wrapBrush{tool = .brush};inspectorTab="Brush"}
    func inspectorEdit(_ key:String,_ edit:()->Void){
        requestInteractivePreview()
        let full="\(selected?.uuidString ?? "none")|\(key)"
        if lastInspectorKey != full || Date().timeIntervalSince(lastInspectorTime)>0.7{checkpoint()}
        lastInspectorKey=full;lastInspectorTime=Date();edit();dirty=true
    }
    var selectedLayerOpacity:Double{activeIndex.map{painting.layers[$0].opacity} ?? 1}
    func setLayerOpacity(_ value:Double){guard let i=activeIndex else{return};inspectorEdit("layer-opacity"){painting.layers[i].opacity=max(0,min(1,value))}}
    var strokeIndex:Int?{
        guard let i=activeIndex,!painting.layers[i].strokes.isEmpty else{return nil}
        if let selectedStroke,painting.layers[i].strokes.indices.contains(selectedStroke){return selectedStroke}
        return painting.layers[i].strokes.count-1
    }
    var selectedStrokeOpacity:Double{guard let i=activeIndex,let j=strokeIndex else{return 1};return painting.layers[i].strokes[j].opacity ?? 1}
    func setStrokeOpacity(_ value:Double){guard let i=activeIndex,let j=strokeIndex else{return};inspectorEdit("stroke-opacity-\(j)"){painting.layers[i].strokes[j].opacity=max(0,min(1,value))}}
    func changeText(_ update:(inout TextSettings)->Void){
        var next=textSettings;update(&next);next.size=max(1,min(512,next.size));next.boxWidth=max(20,min(4096,next.boxWidth));next.tracking=max(-10,min(100,next.tracking));next.lineHeight=max(0.8,min(3,next.lineHeight));textSettings=next
        guard let i=activeIndex,painting.layers[i].text != nil else{return}
        inspectorEdit("text-style"){painting.layers[i].textSettings=next;painting.layers[i].fontSize=next.size}
    }
    func changeTextContent(_ value:String){textInput=value;guard let i=activeIndex,painting.layers[i].text != nil else{return};inspectorEdit("text-content"){painting.layers[i].text=value}}
    func setTextOpacity(_ value:Double){textOpacity=value;if let i=activeIndex,painting.layers[i].text != nil{setLayerOpacity(value)}}
    func zoomBy(_ factor:Double){requestInteractivePreview();let next=max(0.1,min(32,zoom*factor));let ratio=next/zoom;panX *= ratio;panY *= ratio;zoom=next}
    func fitCanvas(){requestInteractivePreview();zoom=1;panX=0;panY=0}
    func outlineMask(_ points:[Dot]){
        guard points.count>=3,var reference=painting.scene,let scene=sceneData(reference) else{status="Analyze a photo, then trace the boundary with Outline.";return}
        let f=reference.frame
        let normalized=points.map{Dot(x:($0.x-f.x)/f.width,y:($0.y-f.y)/f.height)}
        var pixels=[UInt8](repeating:0,count:scene.count*4)
        pixels.withUnsafeMutableBytes{bytes in
            guard let cg=CGContext(data:bytes.baseAddress,width:scene.width,height:scene.height,bitsPerComponent:8,bytesPerRow:scene.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return}
            cg.translateBy(x:0,y:Double(scene.height));cg.scaleBy(x:1,y:-1)
            cg.addPath(Self.outlinePath(normalized,frame:SceneFrame(x:0,y:0,width:Double(scene.width),height:Double(scene.height))))
            cg.setFillColor(CGColor(gray:1,alpha:1));cg.fillPath(using:.evenOdd)
        }
        let mask=(0..<scene.count).map{pixels[$0*4+3]}
        guard mask.contains(where:{$0>128})else{status="Trace a larger closed region.";return}
        do{let name=try writeMask(mask);checkpoint();reference.maskAsset=name;reference.outline=normalized;reference.prompts=nil;reference.maskScore=nil;painting.scene=reference;lockSurface=true;showMask=true;surfaceMode=true;tool = .brush;status="Precise outline selected · Unlock to choose another surface"}catch{fail(error)}
    }
    static func outlinePath(_ points:[Dot],frame:SceneFrame)->CGPath{
        let path=CGMutablePath();guard let first=points.first else{return path}
        path.move(to:CGPoint(x:frame.x+first.x*frame.width,y:frame.y+first.y*frame.height))
        for p in points.dropFirst(){path.addLine(to:CGPoint(x:frame.x+p.x*frame.width,y:frame.y+p.y*frame.height))};path.closeSubpath();return path
    }
}
