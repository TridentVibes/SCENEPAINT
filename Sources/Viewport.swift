import Foundation
import CoreGraphics

struct CanvasViewport:Equatable {
    var viewWidth:Double;var viewHeight:Double
    var documentWidth:Double;var documentHeight:Double
    var zoom:Double=1;var panX:Double=0;var panY:Double=0
    var fitScale:Double{max(0.001,min((viewWidth-48)/documentWidth,(viewHeight-48)/documentHeight))}
    var scale:Double{fitScale*zoom}
    var origin:CGPoint{CGPoint(x:(viewWidth-documentWidth*scale)/2+panX,y:(viewHeight-documentHeight*scale)/2+panY)}
    func documentPoint(_ p:CGPoint)->Dot{Dot(x:(p.x-origin.x)/scale,y:(p.y-origin.y)/scale)}
    func viewPoint(_ p:Dot)->CGPoint{CGPoint(x:p.x*scale+origin.x,y:p.y*scale+origin.y)}
    func magnified(by factor:Double,at anchor:CGPoint)->CanvasViewport {
        let point=documentPoint(anchor)
        var next=self;next.zoom=max(0.1,min(32,zoom*factor))
        let moved=next.viewPoint(point)
        next.panX += anchor.x-moved.x;next.panY += anchor.y-moved.y
        return next
    }
}
