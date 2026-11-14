import Foundation

extension SurfaceMesh{
 /// Jointly upsample depth with the photo colors. Smooth within a surface, select
 /// a single depth class at silhouettes so foreground/background never blend.
 func prepareDepthEdges(_ scene:SceneData,key:String){
  guard depthGuideKey != key,!occlusionDepth.isEmpty,occlusionWidth>1,occlusionHeight>1,scene.valid()else{return}
  let w=scene.width,h=scene.height,sw=occlusionWidth,sh=occlusionHeight
  var output=[Float](repeating:0,count:w*h)
  // Neighborhood depth ranges and guide colors are properties of the low-
  // resolution mesh. Compute once, rather than for every upsampled photo pixel.
  var nearDepth=[Float](repeating:0,count:sw*sh),farDepth=nearDepth,guideRGB=[UInt8](repeating:0,count:sw*sh*3)
  for sy in 0..<sh{for sx in 0..<sw{
   var near=Float.infinity,far:Float=0
   for yy in max(0,sy-1)...min(sh-1,sy+1){for xx in max(0,sx-1)...min(sw-1,sx+1){let z=occlusionDepth[yy*sw+xx];if z>0{near=min(near,z);far=max(far,z)}}}
   nearDepth[sy*sw+sx]=near;farDepth[sy*sw+sx]=far
   let px=max(0,min(w-1,Int((Double(sx)+0.5)/Double(sw)*Double(w)))),py=max(0,min(h-1,Int((Double(sy)+0.5)/Double(sh)*Double(h))))
   for c in 0..<3{guideRGB[(sy*sw+sx)*3+c]=scene.rgb[(py*w+px)*3+c]}
  }}
  for y in 0..<h{for x in 0..<w{
   let gx=(Double(x)+0.5)/Double(w)*Double(sw)-0.5,gy=(Double(y)+0.5)/Double(h)*Double(sh)-0.5
   let cx=max(0,min(sw-1,Int(gx.rounded()))),cy=max(0,min(sh-1,Int(gy.rounded())))
   let near=nearDepth[cy*sw+cx],far=farDepth[cy*sw+cx]
   guard far>0 else{continue}
   if far-near<near*0.035{
    let x0=max(0,min(sw-1,Int(floor(gx)))),y0=max(0,min(sh-1,Int(floor(gy)))),x1=min(sw-1,x0+1),y1=min(sh-1,y0+1)
    let tx=max(0,min(1,gx-Double(x0))),ty=max(0,min(1,gy-Double(y0)))
    let a=Double(occlusionDepth[y0*sw+x0]),b=Double(occlusionDepth[y0*sw+x1]),c=Double(occlusionDepth[y1*sw+x0]),d=Double(occlusionDepth[y1*sw+x1])
    if min(a,b,c,d)>0{output[y*w+x]=Float((a*(1-tx)+b*tx)*(1-ty)+(c*(1-tx)+d*tx)*ty);continue}
   }
   var best=Double.infinity,chosen:Float=0
   let index=(y*w+x)*3
   for yy in max(0,cy-2)...min(sh-1,cy+2){for xx in max(0,cx-2)...min(sw-1,cx+2){
    let z=occlusionDepth[yy*sw+xx];guard z>0 else{continue}
    var color=0.0
    for c in 0..<3{let d=Double(scene.rgb[index+c])-Double(guideRGB[(yy*sw+xx)*3+c]);color += d*d}
    let dx=gx-Double(xx),dy=gy-Double(yy),score=color/600+(dx*dx+dy*dy)*0.08
    if score<best{best=score;chosen=z}
   }}
   output[y*w+x]=chosen
  }}
  guidedDepth=output;guidedWidth=w;guidedHeight=h;depthGuideKey=key
 }
}
