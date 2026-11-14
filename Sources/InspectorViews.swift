import AppKit
import SwiftUI

struct BrushTipPreview:NSViewRepresentable{
    var preset:BrushPreset
    func makeNSView(context:Context)->TipView{TipView(preset)}
    func updateNSView(_ view:TipView,context:Context){view.preset=preset;view.needsDisplay=true}
    final class TipView:NSView{
        var preset:BrushPreset
        override var isFlipped:Bool{true}
        init(_ preset:BrushPreset){self.preset=preset;super.init(frame:.zero)}
        required init?(coder:NSCoder){fatalError()}
        override func draw(_ dirtyRect:NSRect){
            guard let cg=NSGraphicsContext.current?.cgContext else{return}
            var pts:[Dot]=[]
            for x in stride(from:6.0,through:max(6,Double(bounds.width)-6),by:2){pts.append(Dot(x:x,y:Double(bounds.height)/2+sin(x/22)*4))}
            let ink=Ink(brush:preset.settings,points:pts,width:preset == .pencil ? 6:13,red:0.9,green:0.94,blue:1)
            BrushEngine.draw(ink,in:cg)
        }
    }
}
struct BrushInspector:View{
    @ObservedObject var editor:Editor
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Text(editor.tool == .eraser ? "ERASER TIP":editor.tool == .wrapBrush ? "WRAP BRUSH":"BRUSH PALETTE").font(.caption).foregroundStyle(.secondary)
            if editor.tool == .bucket{
                Toggle("Use AI object region",isOn:$editor.bucketUseAI)
                Text("Without AI, fills connected colors in the visible artwork, including closed line art.").font(.caption).foregroundStyle(.secondary)
                Text("Color tolerance · \(Int(editor.bucketTolerance*100))%")
                Slider(value:$editor.bucketTolerance,in:0.02...0.5)
            }
            Picker("Drawing assist",selection:$editor.drawingAssist){ForEach(DrawingAssist.allCases){Text($0.rawValue).tag($0)}}
            if editor.drawingAssist.isShape{Toggle("Solid shape",isOn:$editor.fillShapes);Text("Turn off for a hollow outline. Hold Shift for equal sides.").font(.caption).foregroundStyle(.secondary)}
            if editor.drawingAssist == .line{Text("Drag between endpoints. Hold Shift to snap to 45° angles.").font(.caption).foregroundStyle(.secondary)}
            if editor.drawingAssist == .curve{Text("Draw an arc; Curve assist fits a smooth curve through the gesture.").font(.caption).foregroundStyle(.secondary)}
            Toggle("Smooth continuous lines",isOn:$editor.smoothLines)
            Toggle("Paint over, keep photo shading",isOn:$editor.preserveShading)
            if editor.preserveShading{Text("Uses the v0.1 material stroke: photo shading and texture stay visible on the selected paint layer.").font(.caption).foregroundStyle(.secondary)}
            Picker("Paint area",selection:Binding(get:{editor.paintArea},set:{editor.paintArea=$0})){
                ForEach(PaintArea.allCases){Text($0.rawValue).tag($0)}
            }
            if editor.paintArea == .outside{Text("Protects the selected surface and paints around it in this photo.").font(.caption).foregroundStyle(.secondary)}
            Toggle("Surface overlay grid",isOn:$editor.showMeshGrid).disabled(!editor.hasSurfaceMesh)
            if editor.showMeshGrid{Slider(value:$editor.gridDensity,in:6...28,step:1);Text("Cyan and yellow contours follow the estimated 3D surface. The grid is a guide and is excluded from exports.").font(.caption).foregroundStyle(.secondary)}
            if editor.tool == .wrapBrush{
                Text("Paint travels along a 3D mesh. Brush footprints turn with surface normals and perspective.").font(.caption).foregroundStyle(.secondary)
                Picker("Geometry detail",selection:$editor.geometryDetail){Text("Fast").tag(1200);Text("Detailed").tag(2500)}.pickerStyle(.segmented)
                Toggle("Auto surface lock",isOn:Binding(get:{editor.brushTopography.autoTarget == true},set:{editor.brushTopography.autoTarget=$0;if $0{editor.brushTopography.respectRegion=true;editor.brushTopography.excludeRegion=false}}))
                Toggle("Preserve drawn shape",isOn:Binding(get:{editor.brushTopography.keepDrawnShape == true},set:{editor.brushTopography.keepDrawnShape=$0}))
                Toggle("Reuse this layer's surface target",isOn:Binding(get:{editor.brushTopography.lockLayerSurface == true},set:{editor.brushTopography.lockLayerSurface=$0}))
                Text("Preserve drawn shape keeps your gesture intact and applies the surface mask and photo shading without mesh bending. Reuse target keeps new strokes attached to the same selected object.").font(.caption2).foregroundStyle(.secondary)
                Text(editor.brushTopography.autoTarget == true ? "New strokes stay on the starting object's mask. Selection may exclude an adjoining face." : "New strokes cross surface joins using mesh depth; no automatic selection delay.").font(.caption).foregroundStyle(.secondary)
                HStack{Button(editor.buildingGeometry ? "Building surface…":"Build 3D surface",action:editor.buildSurfaceMesh).disabled(editor.buildingGeometry);if editor.buildingGeometry{ProgressView().controlSize(.small)}}
                Toggle("Infer missing geometry",isOn:Binding(get:{editor.painting.scene?.completionEnabled != false},set:{value in editor.checkpoint();editor.painting.scene?.completionEnabled=value;editor.storeActiveScene()})).disabled(editor.buildingGeometry || editor.painting.scene == nil)
                Text("Rebuild to apply. Fits surfaces throughout the photo; supported curves can gain hidden backs. Irregular shapes receive local continuation. Orange in 3D marks estimates.").font(.caption).foregroundStyle(.secondary)
                Button("Inspect 3D surface",action:editor.inspectSurfaceMesh).disabled(!editor.hasSurfaceMesh)
                Button("Make selected wall perpendicular",action:editor.squareSelectedWall).disabled(editor.buildingGeometry || editor.painting.scene?.maskAsset == nil)
                Text("Select one wall face with Surface or Outline, then constrain it to 90° from the floor. Select the inside and outside separately; leave the top out of each face selection.").font(.caption).foregroundStyle(.secondary).disabled(!editor.hasSurfaceMesh)
                Text("Surface distance · \(editor.brushTopography.relief,specifier:"%.1f")×")
                Slider(value:$editor.brushTopography.relief,in:0.25...2)
                Button("Apply mesh wrap to selected stroke",action:editor.applyBrushTopography).disabled(!editor.hasSurfaceMesh)
                Text("Strokes continue across hidden sections and small gaps. Foreground depth hides the paint; matching surfaces receive it again. Shape hypotheses guide hidden sections; unsupported gaps use the last tangent.").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:7){
                ForEach(BrushPreset.allCases){preset in
                    Button{let erasing=editor.tool == .eraser;editor.chooseBrush(preset);if erasing{editor.tool = .eraser}}label:{
                        VStack(spacing:2){BrushTipPreview(preset:preset).frame(height:28);Text(preset.rawValue).font(.caption)}
                            .frame(maxWidth:.infinity).padding(6)
                            .background(editor.brushSettings.preset == preset ? Color.accentColor.opacity(0.25):Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius:6))
                    }.buttonStyle(.plain)
                }
            }
            HStack{Text("Size");Spacer();TextField("px",value:$editor.brushSize,format:.number.precision(.fractionLength(0...1))).frame(width:65);Text("px").foregroundStyle(.secondary)}
            Slider(value:$editor.brushSize,in:1...500)
            Text("\(editor.tool == .eraser ? "Eraser strength":"Brush opacity") · \(Int(editor.brushOpacity*100))%")
            Slider(value:$editor.brushOpacity,in:0...1)
            Text("Flow · \(Int(editor.brushSettings.flow*100))%")
            Slider(value:$editor.brushSettings.flow,in:0.02...1)
            if [.hard,.soft,.airbrush].contains(editor.brushSettings.preset){
                Text("Hardness · \(Int(editor.brushSettings.hardness*100))%")
                Slider(value:$editor.brushSettings.hardness,in:0...1)
            }
            Text("Spacing · \(Int(editor.brushSettings.spacing*100))%")
            Slider(value:$editor.brushSettings.spacing,in:0.02...1)
            HStack{Text("Angle");Spacer();TextField("°",value:$editor.brushSettings.angle,format:.number.precision(.fractionLength(0))).frame(width:55)}
            Slider(value:$editor.brushSettings.angle,in:0...180)
            Text("Roundness · \(Int(editor.brushSettings.roundness*100))%")
            Slider(value:$editor.brushSettings.roundness,in:0.05...1)
            ColorPicker("Ink color",selection:$editor.color,supportsOpacity:false)
            Text("A/Z: tools · S/X: layers · Q/W: views · [ / ]: tip size. The eraser affects only the selected layer. Opacity below edits existing work.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct TextInspector:View{
    @ObservedObject var editor:Editor
    func setting<T>(_ key:WritableKeyPath<TextSettings,T>)->Binding<T>{Binding(get:{editor.textSettings[keyPath:key]},set:{value in editor.changeText{$0[keyPath:key]=value}})}
    func surface<T>(_ key:WritableKeyPath<SurfaceTextSettings,T>)->Binding<T>{Binding(get:{editor.selectedTextSurface[keyPath:key]},set:{value in editor.changeTextSurface{$0[keyPath:key]=value}})}
    var textColor:Binding<Color>{Binding(get:{Color(red:editor.textSettings.red,green:editor.textSettings.green,blue:editor.textSettings.blue)},set:{color in
        let c=NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        editor.changeText{$0.red=c.redComponent;$0.green=c.greenComponent;$0.blue=c.blueComponent}
    })}
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Text("TEXT PALETTE").font(.caption).foregroundStyle(.secondary)
            TextEditor(text:Binding(get:{editor.textInput},set:editor.changeTextContent)).font(.system(size:13)).frame(height:76).border(Color.white.opacity(0.12))
            Toggle("Wrap text over surface",isOn:surface(\.enabled))
            if editor.selectedTextSurface.enabled,let id=editor.selected,let message=editor.textWrapWarnings[id]{Text(message).font(.caption).foregroundStyle(.orange)}
            Picker("Font",selection:setting(\.family)){ForEach(NSFontManager.shared.availableFontFamilies.sorted(),id:\.self){Text($0).tag($0)}}
            HStack{Text("Size");TextField("pt",value:setting(\.size),format:.number.precision(.fractionLength(0...1))).frame(width:65);Text("pt");Spacer();Stepper("",value:setting(\.size),in:1...512,step:1).labelsHidden()}
            HStack{Toggle("Bold",isOn:setting(\.bold));Toggle("Italic",isOn:setting(\.italic));Toggle("Underline",isOn:setting(\.underline))}.toggleStyle(.button)
            Picker("Alignment",selection:setting(\.alignment)){ForEach(TextAlignment.allCases){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
            ColorPicker("Text color",selection:textColor,supportsOpacity:false)
            Text("Text opacity · \(Int((editor.activeIndex.flatMap{editor.painting.layers[$0].text != nil ? editor.painting.layers[$0].opacity:nil} ?? editor.textOpacity)*100))%")
            Slider(value:Binding(get:{editor.activeIndex.flatMap{editor.painting.layers[$0].text != nil ? editor.painting.layers[$0].opacity:nil} ?? editor.textOpacity},set:editor.setTextOpacity),in:0...1)
            HStack{Text("Tracking");Spacer();TextField("pt",value:setting(\.tracking),format:.number).frame(width:65)}
            Slider(value:setting(\.tracking),in:-5...30)
            Text("Line height · \(editor.textSettings.lineHeight, specifier:"%.2f")×")
            Slider(value:setting(\.lineHeight),in:0.8...2.5)
            HStack{Text("Text box width");Spacer();TextField("px",value:setting(\.boxWidth),format:.number.precision(.fractionLength(0))).frame(width:65)}
            Slider(value:setting(\.boxWidth),in:40...1600)
            if editor.selectedTextSurface.enabled{
                Divider()
                if editor.selectedTextSurface.enabled{
                    Button(editor.buildingGeometry ? "Building 3D surface…":"Build 3D surface",action:editor.buildSurfaceMesh).disabled(editor.buildingGeometry)
                    if editor.selectedTextSurface.engine == 2{
                        Toggle("Limit text to selected region",isOn:Binding(get:{editor.selectedTextSurface.respectRegion == true},set:{value in editor.changeTextSurface{$0.respectRegion=value}}))
                        Toggle("Fit text to connected surface",isOn:Binding(get:{editor.selectedTextSurface.fitToSurface == true},set:{value in editor.changeTextSurface{$0.fitToSurface=value}}))
                        Text("Keeps the starting baseline horizontal and scales the whole label uniformly, down to half size. If the surface is too broken, the label stays flat.").font(.caption).foregroundStyle(.secondary)
                        Text("Surface distance")
                        Slider(value:Binding(get:{editor.selectedTextSurface.depthRelief ?? 1},set:{value in editor.changeTextSurface{$0.depthRelief=value}}),in:0.25...2)
                        Text("Text can cross connected faces. Depth hides covered letters; region limiting is optional.").font(.caption).foregroundStyle(.secondary)
                    }else{
                    Text("Depth relief")
                    Slider(value:Binding(get:{editor.selectedTextSurface.depthRelief ?? 1},set:{value in editor.changeTextSurface{$0.depthRelief=value}}),in:0...2)
                    Text("Projection direction")
                    Slider(value:Binding(get:{editor.selectedTextSurface.depthDirection ?? -90},set:{value in editor.changeTextSurface{$0.depthDirection=value}}),in:-180...180)
                    Text("Curvature");Slider(value:surface(\.curvature),in:-1...1)
                    Text("Horizontal angle");Slider(value:surface(\.yaw),in:-65...65)
                    Text("Vertical angle");Slider(value:surface(\.pitch),in:-55...55)
                    Text("Depth influence");Slider(value:surface(\.followDepth),in:0...1)
                    }
                    Text("Photo shading");Slider(value:surface(\.lighting),in:0...1)
                    Text("Adjust curvature and angles to fit the surface. Single-photo depth is an estimate.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Select a text layer to edit it live. Text tool: click to place new text. Move tool: drag it; its surface mask stays on the photo.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct SurfaceInspector:View{
    @ObservedObject var editor:Editor
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Text("PRECISE REGIONS").font(.caption).foregroundStyle(.secondary)
            Toggle("Surface-aware paint",isOn:$editor.surfaceMode).disabled(editor.painting.scene == nil)
            Picker("Paint area",selection:Binding(get:{editor.paintArea},set:{editor.paintArea=$0})){
                ForEach(PaintArea.allCases){Text($0.rawValue).tag($0)}
            }
            Toggle("Show region",isOn:$editor.showMask).disabled(editor.painting.scene?.maskAsset == nil)
            Picker("Region scope",selection:$editor.maskChoice){Text("Detail").tag(1);Text("Auto").tag(0);Text("Object").tag(2)}.pickerStyle(.segmented)
            Text("Detail uses nearby material differences as hints to SAM. If pants and shirt still join, Option-click the shirt to exclude it, or trace the pants boundary with Outline. Object selects the larger subject.").font(.caption).foregroundStyle(.secondary)
            Button("Update AI Region",action:editor.updateSAMSelection).disabled(editor.painting.scene?.prompts == nil || editor.selectingSurface)
            Button("Apply Region to Selected Layer",action:editor.applyMaskToSelectedLayer).disabled(editor.activeIndex == nil || editor.painting.scene?.maskAsset == nil)
            Text("Surface: click a target. Shift-click includes; Option-click excludes. Outline closes a boundary when you release. Pinch to inspect edges; Mask + / − correct them.").font(.caption).foregroundStyle(.secondary)
            Text("Keep shading / texture")
            Slider(value:$editor.shadeStrength,in:0...1)
            Toggle("Analyze new photos",isOn:$editor.autoAnalyze)
            Toggle("Build 3D surfaces automatically",isOn:$editor.autoGeometry)
            if editor.plane == .depth{Button("Use Edited Depth",action:editor.applyEditedDepth);Text("White is nearer, black is farther.").font(.caption).foregroundStyle(.secondary)}
            Divider()
            Text("Mesh builds combine depth with AI surface normals. Before a mesh build, the Normals map is depth-derived. Shading is a luminance guide. Albedo remains an estimate.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct LayerInspector:View{
    @ObservedObject var editor:Editor
    var body:some View{
        VStack(alignment:.leading,spacing:8){
            HStack{Text("LAYERS").font(.caption).foregroundStyle(.secondary);Spacer();Button(action:editor.addPaintLayer){Image(systemName:"plus")}}
            HStack{
                if editor.selectedFrozenLayer != nil{Button("Unfreeze",action:editor.unfreezeSelectedLayer)}
                else{Button(editor.freezingLayers ? "Freezing…":"Freeze Visible",action:editor.freezeVisibleLayers).disabled(!editor.canFreezeVisible)}
                Text("Keeps originals").font(.caption2).foregroundStyle(.secondary)
            }
            if editor.hasFrozenLayers{
                HStack{Button("Unfreeze All",action:editor.unfreezeAllLayers).disabled(editor.freezingLayers);Text("Restore editable artwork & Motion").font(.caption2).foregroundStyle(.secondary)}
            }
            ScrollViewReader{proxy in
            ScrollView{
                LazyVStack(spacing:4){ForEach(editor.displayedLayers.reversed()){layer in
                    HStack{
                        Button{editor.toggle(layer.id)}label:{Image(systemName:layer.visible ? "eye":"eye.slash")}.buttonStyle(.plain)
                        Button{editor.selectLayer(layer.id)}label:{
                            HStack{Image(systemName:layer.imageAsset != nil ? "photo":layer.text != nil ? "textformat":"paintbrush");Text(layer.name).lineLimit(1);if editor.layerHasMotion(layer){Image(systemName:"waveform.path").foregroundStyle(Color.accentColor)};Spacer()}.padding(7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if editor.layerHasMotion(layer) || layer.motionMuted == true{
                            Button{editor.toggleLayerMotion(layer.id)}label:{Image(systemName:layer.motionMuted == true ? "play.circle":"pause.circle")}.buttonStyle(.plain).help("Toggle this layer's animation")
                        }
                    }.padding(.horizontal,4).background(editor.selected == layer.id ? Color.accentColor.opacity(0.22):Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:5)).id(layer.id)
                }}
            }.frame(minHeight:90,idealHeight:140,maxHeight:210)
            .onChange(of:editor.selected){_,id in
                if let id{proxy.scrollTo(id,anchor:.center)}
            }
            .onChange(of:editor.displayedLayers.map(\.id)){_,_ in
                if let id=editor.selected{proxy.scrollTo(id,anchor:.center)}
            }
            .onAppear{if let id=editor.selected{proxy.scrollTo(id,anchor:.center)}}
            }
            Button("Animate selected artwork"){editor.inspectorTab="Motion"}.disabled(editor.activeIndex == nil)
            HStack{Button("Raise"){editor.reorder(1)};Button("Lower"){editor.reorder(-1)};Spacer();Button(action:editor.deleteLayer){Image(systemName:"trash")}}.disabled(editor.activeIndex == nil)
            Text("Layer opacity · \(Int(editor.selectedLayerOpacity*100))%").font(.caption)
            Slider(value:Binding(get:{editor.selectedLayerOpacity},set:editor.setLayerOpacity),in:0...1).disabled(editor.activeIndex == nil)
            if let i=editor.activeIndex,!editor.painting.layers[i].strokes.isEmpty{
                Picker("Stroke",selection:Binding(get:{editor.strokeIndex ?? 0},set:{editor.selectedStroke=$0})){
                    ForEach(editor.painting.layers[i].strokes.indices,id:\.self){j in
                        Text("\(j+1) · \(editor.painting.layers[i].strokes[j].eraser == true ? "Eraser":editor.painting.layers[i].strokes[j].brush?.preset.rawValue ?? "Brush")").tag(j)
                    }
                }
                HStack{Text("Stroke opacity");Spacer();Text("\(Int(editor.selectedStrokeOpacity*100))%")}.font(.caption)
                Slider(value:Binding(get:{editor.selectedStrokeOpacity},set:editor.setStrokeOpacity),in:0...1)
            }
        }
    }
}
