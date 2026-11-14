import Foundation

enum V01MaterialStroke{
    /// Restore material strokes written into hidden Albedo paint layers by v0.2.
    /// The file is untouched until the user saves; every gesture and mask survives.
    static func restoreStoredStrokes(_ input:Painting)->(painting:Painting,changed:Bool){
        var output=input,changed=false
        for i in output.layers.indices where output.layers[i].plane == .albedo && output.layers[i].materialPaint == true && output.layers[i].imageAsset == nil{
            let owner=output.layers[i].mapSourceID ?? output.layers[i].strokes.compactMap{$0.surface?.reference.sourceID}.first
            output.layers[i].plane = .artwork;output.layers[i].photoSourceID=owner;output.layers[i].mapSourceID=nil;output.layers[i].materialPaint=nil
            for j in output.layers[i].strokes.indices{
                output.layers[i].strokes[j].materialPaint=nil
                output.layers[i].strokes[j].surface?.shading=0.85
            }
            changed=true
        }
        return(output,changed)
    }
}
