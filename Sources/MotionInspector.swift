import SwiftUI

struct MotionInspector:View{
    @ObservedObject var editor:Editor
    @State private var playbackOpen=true
    func stackBinding<T>(_ path:WritableKeyPath<MotionStack,T>)->Binding<T>{Binding(get:{editor.selectedMotionStack[keyPath:path]},set:{value in editor.editMotion("stack"){$0[keyPath:path]=value}})}
    func settingsBinding<T>(_ path:WritableKeyPath<MotionSettings,T>)->Binding<T>{Binding(get:{editor.motionSettings[keyPath:path]},set:{value in editor.setMotionSettings{$0[keyPath:path]=value}})}
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Text("SCENEPAINT MOTION").font(.headline)
            Text("Animate your artwork over a still photograph.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Playback & loop",isExpanded:$playbackOpen){
                VStack(alignment:.leading,spacing:8){
                    HStack{
                        Button(editor.motionPlaying ? "Pause":"Play",action:editor.playMotion).disabled(!editor.hasMotion)
                        Button("Restart",action:editor.restartMotion).disabled(!editor.hasMotion)
                        Toggle("Loop",isOn:settingsBinding(\.loop)).toggleStyle(.checkbox)
                    }
                    TimelineView(.periodic(from:.now,by:0.2)){_ in
                        VStack{
                            HStack{Text(String(format:"%.2f s",editor.motionPosition));Spacer();Text(String(format:"%.1f s loop",editor.motionSettings.duration))}.font(.caption).monospacedDigit()
                            Slider(value:Binding(get:{editor.motionPosition},set:editor.seekMotion),in:0...max(0.25,editor.motionSettings.duration))
                        }
                    }
                    Toggle("Preview effects",isOn:$editor.motionPreviewEnabled).onChange(of:editor.motionPreviewEnabled){_,_ in editor.refreshMotionIfNeeded()}
                    HStack{Text("Duration");Slider(value:settingsBinding(\.duration),in:0.5...12,step:0.5);Text(String(format:"%.1fs",editor.motionSettings.duration)).font(.caption)}
                    Picker("Output FPS",selection:settingsBinding(\.fps)){ForEach([8,12,15,24,30],id:\.self){Text("\($0)").tag($0)}}
                    Picker("Preview size",selection:settingsBinding(\.previewSize)){ForEach([384,512,768,1024],id:\.self){Text("\($0) px").tag($0)}}
                    Text("Timing snaps to complete cycles for a seamless loop. Drawing pauses playback. Preview skips frames when busy.").font(.caption2).foregroundStyle(.secondary)
                    if editor.motionPreparing{ProgressView().controlSize(.small)}
                    Text(editor.motionPreviewNote).font(.caption2).foregroundStyle(.secondary)
                }.padding(.top,6)
            }
            Divider()
            Picker("Apply to",selection:$editor.motionScope){ForEach(MotionScope.allCases,id:\.self){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
            Text(editor.painting.layers.first(where:{$0.id==editor.selected})?.name ?? "Select an artwork layer").font(.subheadline)
            if editor.motionScope == .strokes || editor.motionScope == .group{strokeSelection}
            if editor.motionScope == .group{groupControls}
            if editor.motionEligible{
                Toggle("Enable Animation",isOn:stackBinding(\.enabled))
                HStack{Text("Phase offset").font(.caption);Slider(value:stackBinding(\.phase),in:0...editor.motionSettings.duration)}
                Menu("Add Effect"){ForEach(MotionKind.allCases){kind in Button(kind.rawValue){editor.addMotionEffect(kind)}}}
                ForEach(editor.selectedMotionStack.effects){effect in
                    MotionEffectInspector(editor:editor,effectID:effect.id)
                }
                if editor.selectedMotionStack.effects.isEmpty{Text("Add an effect to existing artwork. Original strokes stay editable.").font(.caption).foregroundStyle(.secondary)}
            }else{Text("Select paint strokes or a text layer. Photo pixels and frozen composites remain static.").font(.caption).foregroundStyle(.secondary)}
            Divider()
            DisclosureGroup("Bake & export"){
                VStack(alignment:.leading,spacing:8){
                    Button("Bake Current Frame",action:editor.bakeMotionFrame).disabled(!editor.hasMotion || editor.motionExporting || editor.freezingLayers)
                    Text("Creates a still snapshot at the playhead. Originals are retained; Unfreeze restores animation.").font(.caption2).foregroundStyle(.secondary)
                    Picker("Output size",selection:settingsBinding(\.outputSize)){ForEach([512,768,1024,1536,2048],id:\.self){Text("\($0) px longest edge").tag($0)}}
                    HStack{Text("MP4 quality");Slider(value:settingsBinding(\.quality),in:0.25...1)}
                    HStack{Button("Export GIF…"){editor.exportMotion(.gif)};Button("Export MP4…"){editor.exportMotion(.mp4)}}.disabled(!editor.hasMotion || editor.motionExporting)
                    if editor.motionExporting{
                        ProgressView(value:editor.motionProgress)
                        Button("Cancel export"){editor.motionExportTask?.cancel()}
                    }
                    Text("GIF includes looping metadata. MP4 contains one cycle; repeat playback is controlled by the player.").font(.caption2).foregroundStyle(.secondary)
                }.padding(.top,6)
            }
        }
    }
    var strokeSelection:some View{
        VStack(alignment:.leading,spacing:6){
            HStack{Text("Selected: \(editor.motionSelection.count)").font(.caption);Spacer();Button("Clear"){editor.motionSelection=[]}}
            if let i=editor.activeIndex{
                ScrollView{
                    LazyVStack(alignment:.leading){ForEach(editor.painting.layers[i].strokes.indices,id:\.self){j in
                        let ink=editor.painting.layers[i].strokes[j]
                        if ink.eraser != true{
                            Toggle(isOn:Binding(get:{ink.id.map{editor.motionSelection.contains($0)} ?? false},set:{_ in editor.toggleMotionStroke(j)})){
                                HStack{Text("Stroke \(j+1)");if ink.motionGroup != nil{Image(systemName:"link")};if ink.animation?.active == true{Image(systemName:"waveform.path")}}
                            }.toggleStyle(.checkbox)
                        }
                    }}
                }.frame(maxHeight:140)
                Text("Selections can span layers. With no checked strokes, the current stroke is used.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    var groupControls:some View{
        VStack(alignment:.leading,spacing:6){
            Picker("Sync group",selection:$editor.motionGroupSelection){
                Text("Choose a group").tag(UUID?.none)
                ForEach(editor.painting.motionGroups ?? []){Text($0.name).tag(Optional($0.id))}
            }
            HStack{Button("New group",action:editor.makeMotionGroup);Button("Assign selected",action:editor.assignMotionGroup).disabled(editor.motionGroupSelection==nil)}
            if editor.motionGroupSelection != nil{
                TextField("Group name",text:Binding(get:{editor.painting.motionGroups?.first{$0.id==editor.motionGroupSelection}?.name ?? ""},set:{name in editor.inspectorEdit("motion-group-name"){if let i=editor.painting.motionGroups?.firstIndex(where:{$0.id==editor.motionGroupSelection}){editor.painting.motionGroups?[i].name=name}}}))
                Button("Remove group",action:editor.removeMotionGroup)
            }
        }
    }
}

struct MotionEffectInspector:View{
    @ObservedObject var editor:Editor;let effectID:UUID
    var effect:MotionEffect{editor.selectedMotionStack.effects.first{$0.id==effectID} ?? .make(.boil)}
    func binding<T>(_ path:WritableKeyPath<MotionEffect,T>)->Binding<T>{Binding(get:{effect[keyPath:path]},set:{value in editor.updateMotionEffect(effectID){$0[keyPath:path]=value}})}
    func slider(_ label:String,_ path:WritableKeyPath<MotionEffect,Double>,_ range:ClosedRange<Double>)->some View{
        VStack(alignment:.leading,spacing:2){HStack{Text(label);Spacer();Text(String(format:"%.2f",effect[keyPath:path])).monospacedDigit()}.font(.caption);Slider(value:binding(path),in:range)}
    }
    var body:some View{
        DisclosureGroup{
            VStack(alignment:.leading,spacing:8){
                Toggle("Enabled",isOn:binding(\.enabled))
                HStack{Button("↑"){editor.moveMotionEffect(effectID,by:-1)};Button("↓"){editor.moveMotionEffect(effectID,by:1)};Button("Duplicate"){editor.duplicateMotionEffect(effectID)};Button{editor.removeMotionEffect(effectID)}label:{Image(systemName:"trash")}}
                switch effect.kind{
                case .boil:
                    Picker("Mode",selection:binding(\.boilMode)){ForEach(BoilMode.allCases,id:\.self){Text($0.rawValue).tag($0)}}
                    slider("Displacement · document px",\.intensity,0...8)
                    slider("Redraws / second",\.frequency,0.5...16)
                    Stepper("\(effect.variations) variations",value:binding(\.variations),in:2...12)
                    Text("Surface strokes deform on their mesh. Raster bucket fills use masked jitter; text retains its projected shape.").font(.caption2).foregroundStyle(.secondary)
                case .blink:
                    Picker("Timing",selection:binding(\.blinkMode)){ForEach(BlinkMode.allCases,id:\.self){Text($0.rawValue).tag($0)}}
                    slider("Frequency · Hz",\.frequency,0.1...8)
                    slider("On fraction · duty",\.duty,0.05...0.95)
                    Text(String(format:"On %.2fs · Off %.2fs",effect.duty/max(0.1,effect.frequency),(1-effect.duty)/max(0.1,effect.frequency))).font(.caption2)
                    slider("Fade in · seconds",\.fadeIn,0...0.5);slider("Fade out · seconds",\.fadeOut,0...0.5)
                    slider("Minimum opacity",\.minimum,0...1);slider("Maximum opacity",\.maximum,0...1)
                    if effect.blinkMode == .flicker{slider("Irregularity",\.randomness,0...1)}
                    if effect.blinkMode == .sequence{TextField("Repeating sequence, e.g. 11010010",text:binding(\.sequence))}
                case .glitch:
                    slider("Displacement · px",\.intensity,0...20);slider("Events / second",\.frequency,0.1...8)
                    slider("Event duration · seconds",\.eventDuration,0.02...0.5);slider("Randomness",\.randomness,0...1)
                    Stepper("\(effect.segments) segments",value:binding(\.segments),in:1...32)
                    Toggle("RGB offsets",isOn:binding(\.rgbOffset))
                case .emission:
                    slider("Emission strength",\.intensity,0...4);slider("Pulse frequency · Hz",\.frequency,0.1...8)
                    Toggle("Synchronize with blink",isOn:binding(\.syncBlink));Toggle("Use stroke color",isOn:binding(\.inheritColor))
                    if !effect.inheritColor{
                        ColorPicker("Emission color",selection:Binding(get:{let c=effect.color;return Color(red:c[0],green:c[1],blue:c[2])},set:{value in let c=NSColor(value).usingColorSpace(.deviceRGB) ?? .white;editor.updateMotionEffect(effectID){$0.color=[c.redComponent,c.greenComponent,c.blueComponent]}}),supportsOpacity:false)
                    }
                    slider("Glow radius",\.glowRadius,0...60);slider("Falloff",\.falloff,0.25...4)
                    slider("Linked light spill",\.spill,0...4);slider("Spill radius",\.spillRadius,1...200);slider("Spill opacity",\.spillOpacity,0...1)
                    Toggle("Constrain spill to surface",isOn:binding(\.constrainSpill))
                    Button("Use selected surface mask"){editor.useSurfaceForSpill(effectID)}
                    if effect.spillMaskAsset != nil{Button("Clear spill mask"){editor.updateMotionEffect(effectID){$0.spillMaskAsset=nil;$0.spillMaskFrame=nil}}}
                    Text("Light spill is a composited glow, not a physical light simulation.").font(.caption2).foregroundStyle(.secondary)
                }
                Stepper("Seed: \(effect.seed)",value:binding(\.seed),in:0...99999)
            }.padding(.vertical,6)
        }label:{HStack{Text(effect.kind.rawValue);Spacer();Image(systemName:effect.enabled ? "checkmark.circle.fill":"circle").foregroundStyle(effect.enabled ? Color.accentColor:Color.secondary)}}
        .padding(8).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:6))
    }
}
