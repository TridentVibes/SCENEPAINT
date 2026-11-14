import AppKit
import CoreText
import ImageIO
import SwiftUI

@MainActor enum Renderer {
    static func clip(_ reference:SceneReference,in cg:CGContext,inverted:Bool=false){
        let f=reference.frame;cg.clip(to:CGRect(x:f.x,y:f.y,width:f.width,height:f.height))
        if let outline=reference.outline{if inverted{cg.addRect(CGRect(x:f.x,y:f.y,width:f.width,height:f.height))};cg.addPath(Editor.outlinePath(outline,frame:f));cg.clip(using:.evenOdd)}
    }
    static func ink(_ stroke:Ink){
        guard let cg=NSGraphicsContext.current?.cgContext else{return}
        cg.saveGState();cg.setAlpha(max(0,min(1,stroke.opacity ?? 1)))
        if stroke.eraser == true{cg.setBlendMode(.destinationOut)}
        cg.beginTransparencyLayer(auxiliaryInfo:nil)
        BrushEngine.draw(stroke,in:cg)
        cg.endTransparencyLayer();cg.restoreGState()
    }
    static func stroke(_ stroke:Ink,editor:Editor,quality:Int=2){
        if let asset=stroke.imageAsset,let frame=stroke.imageFrame,let cg=NSGraphicsContext.current?.cgContext,
           let image=editor.image(for:Layer(id:stroke.id ?? UUID(),name:"Bucket stroke",imageAsset:asset))?.cgImage(forProposedRect:nil,context:nil,hints:nil){
            cg.saveGState();cg.setAlpha(max(0,min(1,stroke.opacity ?? 1)))
            cg.translateBy(x:frame.x,y:frame.y+frame.height);cg.scaleBy(x:1,y:-1)
            cg.draw(image,in:CGRect(x:0,y:0,width:frame.width,height:frame.height));cg.restoreGState();return
        }
        guard stroke.eraser != true,let binding=stroke.surface else{ink(stroke);return}
        guard let material=editor.surfaceMaterial(stroke),let cg=NSGraphicsContext.current?.cgContext else{return}
        let f=binding.reference.frame
        let warped=stroke.topography?.engine == 2 ? MeshPainter.render(stroke,editor:editor,quality:max(1,quality)):nil
        if stroke.topography?.engine == 2 && warped == nil{
            // Display the captured gesture while the accurate mesh raster is prepared.
            var preview=stroke;preview.topography=nil;preview.meshStroke=nil;preview.photoShading=true
            self.stroke(preview,editor:editor,quality:quality);return
        }
        let projected=warped == nil ? editor.topographicInk(stroke):stroke
        var paintBounds=warped?.bounds ?? CGRect.null
        if warped == nil,let first=projected.points.first{
            paintBounds=CGRect(x:first.x,y:first.y,width:0,height:0)
            for point in projected.points.dropFirst(){paintBounds=paintBounds.union(CGRect(x:point.x,y:point.y,width:0,height:0))}
            paintBounds=paintBounds.insetBy(dx:-stroke.width*2,dy:-stroke.width*2)
        }
        cg.saveGState();clip(binding.reference,in:cg,inverted:stroke.invertSelection == true);cg.clip(to:paintBounds);cg.setAlpha(max(0,min(1,stroke.opacity ?? 1)))
        cg.beginTransparencyLayer(auxiliaryInfo:nil);cg.setBlendMode(.normal)
        if let warped{
            cg.saveGState();cg.translateBy(x:warped.bounds.minX,y:warped.bounds.maxY);cg.scaleBy(x:1,y:-1);cg.draw(warped.image,in:CGRect(origin:.zero,size:warped.bounds.size));cg.restoreGState()
        }else{BrushEngine.draw(projected,in:cg)}
        cg.setBlendMode(.sourceIn);cg.translateBy(x:f.x,y:f.y+f.height);cg.scaleBy(x:1,y:-1)
        cg.interpolationQuality = .high
        cg.draw(material,in:CGRect(x:0,y:0,width:f.width,height:f.height))
        cg.endTransparencyLayer();cg.restoreGState()
    }
    static func localized(_ ink:Ink,layer:Layer)->Ink{
        var local=ink;local.imageFrame?.x -= layer.x;local.imageFrame?.y -= layer.y;local.points=ink.points.map{Dot(x:$0.x-layer.x,y:$0.y-layer.y)}
        local.surface?.reference.frame.x -= layer.x;local.surface?.reference.frame.y -= layer.y
        return local
    }
    static func content(_ layer:Layer,editor:Editor,in cg:CGContext,quality:Int){
            if let image=editor.image(for:layer),let raster=image.cgImage(forProposedRect:nil,context:nil,hints:nil){
                cg.saveGState();cg.translateBy(x:0,y:layer.height);cg.scaleBy(x:1,y:-1)
                cg.draw(MaterialPipeline.image(raster,photo:layer,editor:editor),in:CGRect(x:0,y:0,width:layer.width,height:layer.height));cg.restoreGState()
            }
            if layer.text != nil,layer.textSurface?.enabled == true,let projected=SurfaceText.render(layer:layer,editor:editor,quality:quality){
                cg.saveGState();cg.translateBy(x:projected.bounds.minX,y:projected.bounds.maxY);cg.scaleBy(x:1,y:-1)
                cg.draw(projected.image,in:CGRect(origin:.zero,size:projected.bounds.size));cg.restoreGState()
            }else if let text=layer.text {
                if let settings=layer.textSettings{TextEngine.draw(text,settings:settings,in:cg)}
                else {
                    let font=CTFontCreateWithName("Helvetica-Bold" as CFString,layer.fontSize,nil)
                    let attributed=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)])
                    cg.saveGState();cg.translateBy(x:0,y:CTFontGetAscent(font));cg.scaleBy(x:1,y:-1);cg.textMatrix = .identity;cg.textPosition = .zero
                    CTLineDraw(CTLineCreateWithAttributedString(attributed),cg);cg.restoreGState()
                }
            }
            for item in layer.strokes{stroke(item,editor:editor,quality:quality)}
    }
    static func liveLitStroke(_ live:Ink,layer:Layer,editor:Editor,in cg:CGContext,quality:Int){
        var preview=Layer(id:live.id ?? UUID(),name:"Live stroke",x:layer.x,y:layer.y,photoSourceID:layer.photoSourceID ?? Relighter.owner(of:layer,editor:editor),strokes:[localized(live,layer:layer)])
        if let reference=live.surface?.reference{preview.photoSourceID=reference.sourceID}
        if Relighter.light(for:preview,editor:editor) != nil,let raster=editor.renderCache.raster(preview,editor:editor,quality:quality){
            cg.saveGState();cg.translateBy(x:raster.bounds.minX,y:raster.bounds.maxY);cg.scaleBy(x:1,y:-1)
            cg.draw(Relighter.editImage(raster.image,layer:preview,bounds:raster.bounds,editor:editor),in:CGRect(origin:.zero,size:raster.bounds.size));cg.restoreGState()
        }else{stroke(localized(live,layer:layer),editor:editor,quality:quality)}
    }
    static func draw(_ editor:Editor,includePending:Bool=false,liveStroke:Ink?=nil,cacheLayers:Bool=false,quality:Int=2,layers:[Layer]?=nil){
        guard let context=NSGraphicsContext.current else{return};let cg=context.cgContext
        NSGraphicsContext.saveGraphicsState();cg.clip(to:CGRect(x:0,y:0,width:editor.painting.width,height:editor.painting.height))
        var liveInside=false
        for layer in layers ?? editor.displayedLayers where layer.visible {
            let crossSurfaceText=layer.text != nil && layer.textSurface?.enabled == true && layer.textSurface?.engine == 2 && layer.textSurface?.respectRegion != true
            let attached=crossSurfaceText ? nil:layer.surface.flatMap{editor.layerMask($0.reference)}
            if !crossSurfaceText && layer.surface != nil && attached == nil{continue}
            cg.saveGState();cg.translateBy(x:layer.x,y:layer.y);cg.setAlpha(layer.opacity)
            if var ref=layer.surface?.reference{if crossSurfaceText{ref.maskAsset=nil;ref.outline=nil};ref.frame.x -= layer.x;ref.frame.y -= layer.y;clip(ref,in:cg)}
            let cached=(cacheLayers || Relighter.light(for:layer,editor:editor) != nil) ? editor.renderCache.raster(layer,editor:editor,quality:quality):nil
            if let cached{
                var region=cached.bounds
                if let live=liveStroke,layer.id==editor.selected,live.eraser != true{
                    let local=localized(live,layer:layer)
                    if local.topography?.engine == 2,let shape=MeshPainter.shape(local,editor:editor,preview:quality==1){region=region.union(shape.bounds)}
                    else if let first=local.points.first{
                        var bounds=CGRect(x:first.x,y:first.y,width:0,height:0)
                        for p in local.points.dropFirst(){bounds=bounds.union(CGRect(x:p.x,y:p.y,width:0,height:0))}
                        region=region.union(bounds.insetBy(dx:-local.width*2,dy:-local.width*2))
                    }
                }
                cg.clip(to:region)
            }
            cg.beginTransparencyLayer(auxiliaryInfo:nil)
            if let cached{
                cg.saveGState();cg.translateBy(x:cached.bounds.minX,y:cached.bounds.maxY);cg.scaleBy(x:1,y:-1)
                cg.draw(Relighter.editImage(cached.image,layer:layer,bounds:cached.bounds,editor:editor),in:CGRect(origin:.zero,size:cached.bounds.size));cg.restoreGState()
            }else if layer.imageAsset != nil,layer.text == nil,layer.strokes.isEmpty,let image=editor.image(for:layer),let raster=image.cgImage(forProposedRect:nil,context:nil,hints:nil){
                cg.saveGState();cg.translateBy(x:0,y:layer.height);cg.scaleBy(x:1,y:-1)
                cg.draw(Relighter.image(raster,layer:layer,editor:editor),in:CGRect(x:0,y:0,width:layer.width,height:layer.height));cg.restoreGState()
            }else{content(layer,editor:editor,in:cg,quality:quality)}
            if let live=liveStroke,layer.id==editor.selected,(live.eraser == true || (layer.imageAsset == nil && layer.text == nil)){
                if live.eraser == true{stroke(localized(live,layer:layer),editor:editor)}
                else{liveLitStroke(live,layer:layer,editor:editor,in:cg,quality:quality)}
                liveInside=true
            }
            if let ref=layer.surface?.reference,let mask=attached {
                let f=ref.frame;cg.setBlendMode(.destinationIn)
                cg.translateBy(x:f.x-layer.x,y:f.y-layer.y+f.height);cg.scaleBy(x:1,y:-1)
                cg.draw(mask,in:CGRect(x:0,y:0,width:f.width,height:f.height))
            }
            cg.endTransparencyLayer();cg.restoreGState()
        }
        if let live=liveStroke,!liveInside,live.eraser != true{
            let layer=Layer(id:live.id ?? UUID(),name:"Live stroke",photoSourceID:live.surface?.reference.sourceID ?? editor.activePhotoID)
            liveLitStroke(live,layer:layer,editor:editor,in:cg,quality:quality)
        }
        if includePending{
            cg.saveGState();cg.setAlpha(0.55);cg.beginTransparencyLayer(auxiliaryInfo:nil)
            for pending in editor.pendingInk{ink(pending)}
            cg.endTransparencyLayer();cg.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
struct EditorCanvas:NSViewRepresentable{
    @ObservedObject var editor:Editor
    func makeNSView(context:Context)->PaintView{PaintView(editor)}
    func updateNSView(_ view:PaintView,context:Context){view.prepareGrid();view.updateBrushCursor();view.configureMotionPlayback();view.scheduleMotionRefresh();view.needsDisplay=true;view.window?.invalidateCursorRects(for:view)}
}
@MainActor final class PaintView:NSView{
    let editor:Editor
    var points:[Dot]=[]
    let motionPreview=CanvasMotionPreview()
    let paintPreview=PaintScenePreview()
    var tracedLive:SurfaceStroke?;var tracedPoints=0
    var assist:DrawingAssist = .freehand;var constrained=false;var priorCoalescing:Bool?
    var grid=MeshGridOverlay()
    var previous:Dot?;var movingID:UUID?
    var surfaceTask:Task<SceneReference?,Never>?
    var captured:Ink?
    var capturedLayerID:UUID?
    var panPoint:NSPoint?;var spacePan=false;var cursorPoint:NSPoint?
    var tracking:NSTrackingArea?
    var navigationMonitor:Any?
    var motionTimer:Timer?
    var motionRefreshTask:Task<Void,Never>?
    func scheduleMotionRefresh(){
        guard motionRefreshTask == nil else{return}
        motionRefreshTask=Task{[weak self] in
            // Do not publish editor changes inside NSViewRepresentable's update.
            await Task.yield()
            guard let self,!Task.isCancelled else{return}
            self.editor.refreshMotionIfNeeded()
            self.motionRefreshTask=nil
        }
    }
    func configureMotionPlayback(){
        if editor.motionPlaying,window != nil,motionTimer == nil{
            let timer=Timer(timeInterval:1.0/30,repeats:true){[weak self] _ in MainActor.assumeIsolated{
                guard let self,self.window?.isVisible == true,self.window?.isMiniaturized == false else{return}
                if self.points.isEmpty,self.movingID == nil,self.panPoint == nil,!self.editor.interactivePreview{self.editor.tickMotion()}else{self.editor.motionLastTick=Date()}
            }}
            RunLoop.main.add(timer,forMode:.common);motionTimer=timer
        }else if !editor.motionPlaying || window == nil{motionTimer?.invalidate();motionTimer=nil}
    }
    override func viewWillMove(toWindow newWindow:NSWindow?){
        if let navigationMonitor{NSEvent.removeMonitor(navigationMonitor);self.navigationMonitor=nil}
        if newWindow == nil,let priorCoalescing{NSEvent.isMouseCoalescingEnabled=priorCoalescing;self.priorCoalescing=nil}
        if newWindow == nil{motionTimer?.invalidate();motionTimer=nil;motionRefreshTask?.cancel();motionRefreshTask=nil;editor.stopMotion(clear:true);editor.motionFrameDisplay=nil}
        super.viewWillMove(toWindow:newWindow)
        guard newWindow != nil else{return}
        navigationMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
            guard let self,event.window === self.window,
                  event.modifierFlags.intersection([.command,.control,.option]).isEmpty,
                  !(self.window?.firstResponder is NSText),
                  let key=event.charactersIgnoringModifiers?.lowercased(),["a","z","s","x","q","w"].contains(key)else{return event}
            if !event.isARepeat{self.editor.navigateKey(key)}
            return nil
        }
    }
    let cursorOverlay=BrushCursorView(frame:.zero)
    var warmingCursorMeshes=Set<String>()
    func updateBrushCursor(){
        let show=editor.tool == .brush || editor.tool == .wrapBrush || editor.tool == .eraser || editor.tool == .maskAdd || editor.tool == .maskRemove
        guard show,let cursor=cursorPoint,bounds.contains(cursor)else{cursorOverlay.isHidden=true;return}
        if editor.tool == .wrapBrush,let ref=editor.painting.scene,let asset=ref.geometryAsset{
            if let mesh=editor.meshCache.meshes.object(forKey:asset as NSString)?.mesh{
                let point=viewport.documentPoint(cursor)
                if let corners=SurfaceCursorGeometry.plane(mesh:mesh,point:point,frame:ref.frame,diameter:editor.brushSize){
                    let viewPoints=corners.map{viewport.viewPoint(Dot(x:$0.x,y:$0.y))}
                    var rect=CGRect(x:viewPoints[0].x,y:viewPoints[0].y,width:0,height:0)
                    for p in viewPoints.dropFirst(){rect=rect.union(CGRect(x:p.x,y:p.y,width:0,height:0))}
                    rect=rect.insetBy(dx:-2,dy:-2).intersection(bounds)
                    if !rect.isNull,!rect.isEmpty{
                        cursorOverlay.frame=rect;cursorOverlay.showPlane(viewPoints.map{CGPoint(x:$0.x-rect.minX,y:$0.y-rect.minY)})
                        cursorOverlay.isHidden=false;return
                    }
                }
            }else if !warmingCursorMeshes.contains(asset){
                warmingCursorMeshes.insert(asset)
                Task{[weak self] in
                    guard let self else{return}
                    await self.editor.prepareBrushResources(ref)
                    self.warmingCursorMeshes.remove(asset)
                    self.updateBrushCursor()
                }
            }
        }
        cursorOverlay.showCircle()
        let d=max(2,editor.brushSize*Double(scale))
        cursorOverlay.frame=CGRect(x:cursor.x-d/2,y:cursor.y-d/2,width:d,height:d)
        cursorOverlay.layer?.cornerRadius=d/2;cursorOverlay.isHidden=false
    }
    override var isFlipped:Bool{true}
    override var acceptsFirstResponder:Bool{true}
    init(_ editor:Editor){
        self.editor=editor;super.init(frame:.zero)
        registerForDraggedTypes([.fileURL])
        wantsLayer=true
        clipsToBounds=true
        layer?.masksToBounds=true
        cursorOverlay.wantsLayer=true;cursorOverlay.layer?.borderColor=NSColor.white.withAlphaComponent(0.9).cgColor
        cursorOverlay.layer?.borderWidth=1;cursorOverlay.isHidden=true;addSubview(cursorOverlay)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func droppedImageURLs(from pasteboard:NSPasteboard)->[URL]{
        let types=CGImageSourceCopyTypeIdentifiers() as! [String]
        let options:[NSPasteboard.ReadingOptionKey:Any]=[.urlReadingFileURLsOnly:true,.urlReadingContentsConformToTypes:types]
        let files=pasteboard.readObjects(forClasses:[NSURL.self],options:options) as? [NSURL] ?? []
        return files.map{$0 as URL}.filter{$0.isFileURL}
    }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation{
        sender.draggingSourceOperationMask.contains(.copy) && !droppedImageURLs(from:sender.draggingPasteboard).isEmpty ? .copy:[]
    }
    override func draggingUpdated(_ sender:NSDraggingInfo)->NSDragOperation{draggingEntered(sender)}
    override func prepareForDragOperation(_ sender:NSDraggingInfo)->Bool{!droppedImageURLs(from:sender.draggingPasteboard).isEmpty}
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool{
        let urls=droppedImageURLs(from:sender.draggingPasteboard)
        guard !urls.isEmpty else{return false}
        editor.importURLs(urls);needsDisplay=true;return true
    }
    var viewport:CanvasViewport{CanvasViewport(viewWidth:Double(bounds.width),viewHeight:Double(bounds.height),documentWidth:editor.painting.width,documentHeight:editor.painting.height,zoom:editor.zoom,panX:editor.panX,panY:editor.panY)}
    var scale:CGFloat{CGFloat(viewport.scale)}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();window?.acceptsMouseMovedEvents=true;editor.motionFrameDisplay={[weak self] in self?.needsDisplay=true};configureMotionPlayback()}
    override func updateTrackingAreas(){
        super.updateTrackingAreas();if let tracking{removeTrackingArea(tracking)}
        let area=NSTrackingArea(rect:bounds,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area);tracking=area
    }
    override func resetCursorRects(){addCursorRect(visibleRect,cursor:editor.tool == .hand || spacePan ? .openHand:.crosshair)}
    func point(_ event:NSEvent)->Dot{viewport.documentPoint(convert(event.locationInWindow,from:nil))}
    func liveInk()->Ink?{
        guard !points.isEmpty,editor.tool == .brush || editor.tool == .wrapBrush || editor.tool == .eraser else{return nil}
        var ink=captured ?? editor.makeInk(points,erasing:editor.tool == .eraser)
        ink.points=DrawingGeometry.points(points,assist:assist,constrained:constrained)
        if ink.eraser != true,let ref=editor.liveSurface,surfaceTask != nil{ink.surface=SurfaceBinding(reference:ref,shading:editor.shadeStrength,conform:0)}
        // Input capture uses an immediate 2D preview. Mesh resolution is queued after release.
        if ink.topography?.engine == 2{ink.topography=nil;ink.meshStroke=nil;ink.photoShading=true}
        return ink
    }
    override func draw(_ dirtyRect:NSRect){
        editor.interactiveRender=true;defer{editor.interactiveRender=false}
        NSColor(calibratedWhite:0.1,alpha:1).setFill();bounds.fill()
        NSGraphicsContext.saveGraphicsState()
        // Clip in view coordinates before applying document zoom and pan.
        NSGraphicsContext.current?.cgContext.clip(to:bounds)
        let map=viewport,transform=NSAffineTransform();transform.translateX(by:map.origin.x,yBy:map.origin.y);transform.scale(by:scale);transform.concat()
        let rect=NSRect(x:0,y:0,width:editor.painting.width,height:editor.painting.height)
        NSColor(calibratedWhite:0.19,alpha:1).setFill();rect.fill();NSBezierPath(rect:rect).addClip()
        if let live=liveInk(),let cg=NSGraphicsContext.current?.cgContext{
            paintPreview.prepare(editor,viewport:map,ink:live)
            paintPreview.draw(paintPreview.below,in:cg)
            Renderer.draw(editor,liveStroke:live,cacheLayers:true,quality:1,layers:paintPreview.active)
            paintPreview.draw(paintPreview.above,in:cg)
            if !editor.pendingInk.isEmpty{Renderer.draw(editor,includePending:true,quality:1,layers:[])}
        }else if points.isEmpty,editor.motionPreviewEnabled,editor.plane == .artwork,editor.motionPreparedRevision==editor.contentRevision,let image=editor.motionFrame,let cg=NSGraphicsContext.current?.cgContext{
            cg.saveGState();cg.interpolationQuality = .medium;cg.translateBy(x:0,y:editor.painting.height);cg.scaleBy(x:1,y:-1);cg.draw(image,in:rect);cg.restoreGState()
        }else if points.isEmpty,let image=motionPreview.raster(editor),let cg=NSGraphicsContext.current?.cgContext{
            cg.saveGState();cg.interpolationQuality = .high;cg.translateBy(x:0,y:editor.painting.height);cg.scaleBy(x:1,y:-1)
            cg.draw(image,in:rect);cg.restoreGState()
        }else{Renderer.draw(editor,includePending:true,liveStroke:liveInk(),cacheLayers:true,quality:max(1,min(4,Int(ceil(Double(scale)*(window?.backingScaleFactor ?? 2))))))}
        if editor.showMeshGrid,editor.plane == .artwork,let ref=editor.painting.scene,let cg=NSGraphicsContext.current?.cgContext{grid.draw(in:cg,frame:ref.frame,scale:Double(scale))}
        if editor.showMask,editor.plane == .artwork,let ref=editor.painting.scene,let cg=NSGraphicsContext.current?.cgContext{
            if let outline=ref.outline{
                cg.addPath(Editor.outlinePath(outline,frame:ref.frame));cg.setFillColor(CGColor(red:0,green:1,blue:1,alpha:0.25));cg.fillPath(using:.evenOdd)
            }else if let overlay=editor.maskOverlay(){let f=ref.frame;cg.saveGState();cg.translateBy(x:f.x,y:f.y+f.height);cg.scaleBy(x:1,y:-1);cg.draw(overlay,in:CGRect(x:0,y:0,width:f.width,height:f.height));cg.restoreGState()}
        }
        if !points.isEmpty,editor.tool == .maskAdd || editor.tool == .maskRemove || editor.tool == .outline{
            let path=NSBezierPath();path.lineWidth=(editor.tool == .outline ? 1/Double(scale):editor.brushSize);path.lineCapStyle = .round
            path.move(to:NSPoint(x:points[0].x,y:points[0].y));for p in points.dropFirst(){path.line(to:NSPoint(x:p.x,y:p.y))}
            (editor.tool == .maskRemove ? NSColor.systemRed:NSColor.systemCyan).setStroke();path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func magnify(with event:NSEvent){
        guard points.isEmpty else{return}
        editor.requestInteractivePreview()
        let next=viewport.magnified(by:exp(Double(event.magnification)),at:convert(event.locationInWindow,from:nil))
        editor.zoom=next.zoom;editor.panX=next.panX;editor.panY=next.panY
    }
    override func scrollWheel(with event:NSEvent){
        guard points.isEmpty else{return}
        editor.requestInteractivePreview()
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option){
            let next=viewport.magnified(by:exp(Double(event.scrollingDeltaY)*0.015),at:convert(event.locationInWindow,from:nil));editor.zoom=next.zoom;editor.panX=next.panX;editor.panY=next.panY
        }else{let speed=event.hasPreciseScrollingDeltas ? 1.0:18.0;editor.panX += Double(event.scrollingDeltaX)*speed;editor.panY += Double(event.scrollingDeltaY)*speed}
    }
    override func mouseMoved(with event:NSEvent){cursorPoint=convert(event.locationInWindow,from:nil);updateBrushCursor()}
    override func mouseExited(with event:NSEvent){cursorPoint=nil;updateBrushCursor()}
    override func keyDown(with event:NSEvent){
        guard event.modifierFlags.intersection([.command,.control,.option]).isEmpty else{super.keyDown(with:event);return}
        if event.keyCode==49{spacePan=true;window?.invalidateCursorRects(for:self);return}
        switch event.charactersIgnoringModifiers?.lowercased(){
        case "a","z","s","x","q","w":if !event.isARepeat{editor.navigateKey(event.charactersIgnoringModifiers ?? "")}
        case "b":editor.activateTool(.brush)
        case "e":editor.activateTool(.eraser)
        case "h":editor.tool = .hand
        case "[":editor.brushSize=max(1,editor.brushSize/1.2)
        case "]":editor.brushSize=min(500,editor.brushSize*1.2)
        default:super.keyDown(with:event)
        }
    }
    override func keyUp(with event:NSEvent){if event.keyCode==49{spacePan=false;window?.invalidateCursorRects(for:self)}else{super.keyUp(with:event)}}
    override func mouseDown(with event:NSEvent){
        window?.makeFirstResponder(self)
        if editor.motionPlaying{editor.motionPlaying=false}
        capturedLayerID=editor.selected
        tracedLive=nil;tracedPoints=0;assist=editor.drawingAssist;constrained=event.modifierFlags.contains(.shift)
        if editor.tool == .hand || spacePan{panPoint=convert(event.locationInWindow,from:nil);return}
        editor.finishInteractivePreview()
        let p=point(event);guard p.x>=0,p.y>=0,p.x<=editor.painting.width,p.y<=editor.painting.height else{return}
        switch editor.tool{
        case .bucket:editor.smartFill(at:p)
        case .wrapBrush:
            if editor.preserveShading,editor.isPhotoFrozen(editor.activePhotoID){editor.status="Unfreeze to edit the material, or turn off Keep photo shading for an overlay.";return}
            if editor.plane != .artwork{guard let ink=editor.capturePlainBrush()else{return};surfaceTask=nil;editor.liveSurface=nil;captured=ink;points=[p];break}
            guard editor.hasSurfaceMesh,var ref=editor.painting.scene else{editor.status="Build the 3D surface in the Wrap Brush palette first.";return}
            if editor.brushTopography.autoTarget != true,editor.paintArea != .everywhere,ref.maskAsset == nil{editor.status="Choose a surface with Surface or Outline first.";return}
            editor.surfaceMode=true;surfaceTask=nil
            ref.automaticTarget=nil
            let priorTarget=editor.brushTopography.lockLayerSurface == true ? editor.activeIndex.flatMap{editor.painting.layers[$0].strokes.compactMap{$0.surface?.reference}.first(where:{$0.sourceID==ref.sourceID})}:nil
            if var priorTarget{if let i=editor.activeIndex{priorTarget.frame.x += editor.painting.layers[i].x;priorTarget.frame.y += editor.painting.layers[i].y};ref=priorTarget}
            else if editor.brushTopography.autoTarget == true{
                guard let task=editor.beginSurfaceSelection(at:p,automaticTarget:true)else{return}
                surfaceTask=task;ref.maskAsset=nil;ref.outline=nil;ref.automaticTarget=true
            }else if editor.paintArea == .everywhere{ref.maskAsset=nil;ref.outline=nil}
            var ink=editor.makeInk([],erasing:false);ink.topography?.respectRegion=editor.paintArea != .everywhere;ink.surface=SurfaceBinding(reference:ref,shading:editor.shadeStrength,conform:0)
            if editor.brushTopography.keepDrawnShape == true{ink.topography=nil;ink.meshStroke=nil}
            captured=ink;points=[p];if surfaceTask == nil{editor.liveSurface=ref}
        case .brush:
            surfaceTask=nil;editor.liveSurface=nil
            guard let ink=editor.capturePlainBrush()else{return}
            captured=ink;points=[p]
            if ink.surface != nil{Task{await editor.prepareSurfaceMaterial(ink)}}
        case .eraser:
            guard editor.activeIndex != nil else{editor.status="Select the layer you want to erase.";return}
            surfaceTask=nil;captured=editor.makeInk([],erasing:true);points=[p]
        case .outline:
            guard editor.plane == .artwork,editor.painting.scene != nil else{editor.status="Analyze a photo, then trace its region.";return};points=[p]
        case .surface:editor.pickSAMSurface(at:p,append:event.modifierFlags.contains(.shift)||event.modifierFlags.contains(.option),label:event.modifierFlags.contains(.option) ? 0:1)
        case .maskAdd,.maskRemove:
            guard editor.plane == .artwork,editor.painting.scene?.maskAsset != nil else{editor.status="Choose a surface first.";return};editor.showMask=true;points=[p]
        case .text:editor.placeText(at:p)
        case .move:
            guard let i=editor.activeIndex else{return};let layer=editor.painting.layers[i]
            guard editor.painting.scene?.sourceID != layer.id,!layer.strokes.contains(where:{$0.surface != nil})else{editor.status="Analyzed photos and surface paint stay aligned. Text and overlays can be moved.";return}
            editor.checkpoint();movingID=layer.id;previous=p
        case .hand:break
        }
        if !points.isEmpty{priorCoalescing=NSEvent.isMouseCoalescingEnabled;NSEvent.isMouseCoalescingEnabled=false}
        needsDisplay=true
    }
    override func mouseDragged(with event:NSEvent){
        if let last=panPoint{editor.requestInteractivePreview();let now=convert(event.locationInWindow,from:nil);editor.panX += Double(now.x-last.x);editor.panY += Double(now.y-last.y);panPoint=now;return}
        let p=point(event);cursorPoint=convert(event.locationInWindow,from:nil);updateBrushCursor()
        if !points.isEmpty{
            constrained=event.modifierFlags.contains(.shift)
            if let last=points.last,hypot(p.x-last.x,p.y-last.y)>=0.1{points.append(p)}
            needsDisplay=true
        }
        if let last=previous,let id=movingID,let i=editor.painting.layers.firstIndex(where:{$0.id==id}){editor.requestInteractivePreview();editor.painting.layers[i].x += p.x-last.x;editor.painting.layers[i].y += p.y-last.y;previous=p}
    }
    override func mouseUp(with event:NSEvent){
        if let priorCoalescing{NSEvent.isMouseCoalescingEnabled=priorCoalescing;self.priorCoalescing=nil}
        if !points.isEmpty{
            let end=point(event);if let last=points.last,hypot(end.x-last.x,end.y-last.y)>0.01{points.append(end)}
            if editor.tool == .maskAdd || editor.tool == .maskRemove{editor.refineMask(points:points,adding:editor.tool == .maskAdd)}
            else if editor.tool == .outline{editor.outlineMask(points)}
            else{var ink=captured ?? editor.makeInk(points,erasing:editor.tool == .eraser)
                ink.points=DrawingGeometry.points(points,assist:assist,constrained:constrained)
                if ink.filled == true{ink.topography=nil;ink.photoShading=true}
                if let ref=editor.liveSurface,surfaceTask != nil{ink.surface=SurfaceBinding(reference:ref,shading:editor.shadeStrength,conform:0)}
                if let task=surfaceTask{editor.finishSurfaceStroke(ink,task:task,targetLayerID:capturedLayerID)}else{editor.commitCapturedInk(ink,reference:ink.surface?.reference,targetPlane:editor.plane,targetLayerID:capturedLayerID)}}
        }
        points.removeAll();tracedLive=nil;tracedPoints=0;captured=nil;capturedLayerID=nil;surfaceTask=nil;editor.liveSurface=nil;previous=nil;movingID=nil;panPoint=nil;needsDisplay=true
    }
}


