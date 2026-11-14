import AppKit
import SwiftUI

struct WorkspacePreferences:Codable{
    var sidebarWidth=310.0;var railWidth=72.0;var layerHeight=390.0;var compact=false
    var autoAnalyze=true;var autoGeometry=true
}
@MainActor extension Editor{
    func loadWorkspacePreferences(){
        if let data=try? Data(contentsOf:root.appendingPathComponent("Settings.json")),let settings=try? JSONDecoder().decode(WorkspacePreferences.self,from:data){
            workspacePreferences=settings;autoAnalyze=settings.autoAnalyze;autoGeometry=settings.autoGeometry
        }
    }
    func saveWorkspacePreferences(){
        workspacePreferences.autoAnalyze=autoAnalyze;workspacePreferences.autoGeometry=autoGeometry
        do{try ExternalFiles.write(JSONEncoder().encode(workspacePreferences),to:root.appendingPathComponent("Settings.json"))}catch{fail(error)}
    }
    func resetWorkspaceLayout(){workspacePreferences=WorkspacePreferences(autoAnalyze:autoAnalyze,autoGeometry:autoGeometry);saveWorkspacePreferences()}
}
struct WorkspaceSettingsView:View{
    @ObservedObject var editor:Editor
    var body:some View{
        Form{
            Section("Workspace"){
                Slider(value:$editor.workspacePreferences.sidebarWidth,in:270...450){Text("Inspector width")}
                Slider(value:$editor.workspacePreferences.railWidth,in:64...100){Text("Tool rail width")}
                Slider(value:$editor.workspacePreferences.layerHeight,in:210...520){Text("Layers height")}
                Toggle("Compact spacing",isOn:$editor.workspacePreferences.compact)
                Button("Reset Layout",action:editor.resetWorkspaceLayout)
                Text("Tools stay on the left, canvas in the center, inspector and layers on the right.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Local processing"){
                Toggle("Analyze newly imported photos",isOn:$editor.autoAnalyze)
                Toggle("Build geometry automatically",isOn:$editor.autoGeometry)
                Text("All image processing runs locally. No account or API key is required.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage"){
                Text(editor.root.path).font(.caption).textSelection(.enabled)
                Button("Show Data Folder"){NSWorkspace.shared.open(editor.root)}
                Text("Projects include their photos and analysis. Use Save As to create a portable copy. PNG export saves a flattened image.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding().frame(width:530,height:530)
        .onDisappear{editor.saveWorkspacePreferences()}
        .onChange(of:editor.workspacePreferences.sidebarWidth){_,_ in editor.saveWorkspacePreferences()}
        .onChange(of:editor.workspacePreferences.railWidth){_,_ in editor.saveWorkspacePreferences()}
        .onChange(of:editor.workspacePreferences.layerHeight){_,_ in editor.saveWorkspacePreferences()}
        .onChange(of:editor.workspacePreferences.compact){_,_ in editor.saveWorkspacePreferences()}
        .onChange(of:editor.autoAnalyze){_,_ in editor.saveWorkspacePreferences()}
        .onChange(of:editor.autoGeometry){_,_ in editor.saveWorkspacePreferences()}
    }
}
