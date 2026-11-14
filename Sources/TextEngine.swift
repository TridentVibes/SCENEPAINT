import AppKit
import CoreText

enum TextAlignment: String,Codable,CaseIterable,Identifiable {
    case left="Left",center="Center",right="Right"
    var id:String{rawValue}
    var native:NSTextAlignment{self == .left ? .left:self == .center ? .center:.right}
}
struct TextSettings: Codable,Equatable {
    var family="Helvetica"
    var size=64.0
    var bold=false;var italic=false;var underline=false
    var alignment:TextAlignment = .left
    var tracking=0.0;var lineHeight=1.15;var boxWidth=600.0
    var red=1.0;var green=1.0;var blue=1.0
}
@MainActor enum TextEngine {
    static func attributed(_ text:String,settings:TextSettings)->NSAttributedString {
        var font=NSFont(name:settings.family,size:settings.size) ?? NSFont.systemFont(ofSize:settings.size)
        if let family=NSFontManager.shared.font(withFamily:settings.family,traits:[],weight:5,size:settings.size){font=family}
        if settings.bold{font=NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask)}
        if settings.italic{font=NSFontManager.shared.convert(font,toHaveTrait:.italicFontMask)}
        let paragraph=NSMutableParagraphStyle();paragraph.alignment=settings.alignment.native
        paragraph.lineHeightMultiple=max(0.8,settings.lineHeight);paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string:text,attributes:[.font:font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(red:settings.red,green:settings.green,blue:settings.blue,alpha:1),.kern:settings.tracking,.paragraphStyle:paragraph,.underlineStyle:settings.underline ? NSUnderlineStyle.single.rawValue:0])
    }
    static func measure(_ text:String,settings:TextSettings)->CGSize{
        let content=attributed(text,settings:settings),setter=CTFramesetterCreateWithAttributedString(attributed(text,settings:settings))
        let size=CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(location:0,length:content.length),nil,CGSize(width:max(20,settings.boxWidth),height:100000),nil)
        return CGSize(width:settings.alignment == .left ? max(1,ceil(size.width)+3):max(20,settings.boxWidth),height:max(settings.size*1.4,ceil(size.height)+settings.size*0.4))
    }
    static func draw(_ text:String,settings:TextSettings,in cg:CGContext){
        let content=attributed(text,settings:settings)
        let setter=CTFramesetterCreateWithAttributedString(content)
        let width=max(20,settings.boxWidth)
        let size=CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRange(location:0,length:content.length),nil,CGSize(width:width,height:100000),nil)
        let height=max(settings.size*1.4,ceil(size.height)+settings.size*0.4)
        let path=CGPath(rect:CGRect(x:0,y:0,width:width,height:height),transform:nil)
        let frame=CTFramesetterCreateFrame(setter,CFRange(location:0,length:content.length),path,nil)
        cg.saveGState();cg.translateBy(x:0,y:height);cg.scaleBy(x:1,y:-1);cg.textMatrix = .identity
        CTFrameDraw(frame,cg);cg.restoreGState()
    }
}
