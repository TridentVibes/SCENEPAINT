import Foundation

/// Refine only the uncertain silhouette band against full analysis-resolution RGB.
/// Confident pixels on either side supply color samples; shadows alone do not create holes.
enum EdgeMatte{
 static func refine(_ mask:[UInt8],rgb:[UInt8],width:Int,height:Int,radius:Int=12,focus:[CGPoint]?=nil,brushRadius:Double=0)->[UInt8]{
  guard width>2,height>2,mask.count==width*height,rgb.count==mask.count*3 else{return mask}
  let count=mask.count
  var distance=[UInt8](repeating:255,count:count),queue:[Int]=[]
  queue.reserveCapacity(count/8)
  for y in 1..<height-1{for x in 1..<width-1{
   let i=y*width+x,v=mask[i]>127
   if (mask[i-1]>127) != v || (mask[i+1]>127) != v || (mask[i-width]>127) != v || (mask[i+width]>127) != v{distance[i]=0;queue.append(i)}
  }}
  var head=0
  while head<queue.count{
   let i=queue[head];head += 1
   if distance[i]>=radius{continue}
   let x=i%width,y=i/width
   for n in [x>0 ? i-1:-1,x+1<width ? i+1:-1,y>0 ? i-width:-1,y+1<height ? i+width:-1] where n>=0{
    if distance[n]>distance[i]+1{distance[n]=distance[i]+1;queue.append(n)}
   }
  }
  let tile=16,columns=(width+tile-1)/tile,rows=(height+tile-1)/tile
  var active=[Bool](repeating:focus==nil,count:columns*rows)
  if let focus{
   let margin=max(1,Int(ceil((brushRadius+Double(tile))/Double(tile))))
   func mark(_ p:CGPoint){
    let x=Int(p.x)/tile,y=Int(p.y)/tile
    guard x>=0,x<columns,y>=0,y<rows else{return}
    for yy in max(0,y-margin)...min(rows-1,y+margin){for xx in max(0,x-margin)...min(columns-1,x+margin){active[yy*columns+xx]=true}}
   }
   for (index,p) in focus.enumerated(){
    mark(p)
    if index>0{
     let a=focus[index-1],steps=max(1,min(4096,Int(ceil(hypot(p.x-a.x,p.y-a.y)/8))))
     for n in 0...steps{let t=Double(n)/Double(steps);mark(CGPoint(x:a.x+(p.x-a.x)*t,y:a.y+(p.y-a.y)*t))}
    }
   }
  }
  var result=mask
  let reach=radius*2+3
  for i in queue{
   let x=i%width,y=i/width
   guard active[(y/tile)*columns+x/tile] else{continue}
   var best0=Double.infinity,best1=Double.infinity
   for dy in stride(from:-reach,through:reach,by:2){for dx in stride(from:-reach,through:reach,by:2){
    let xx=x+dx,yy=y+dy
    guard xx>=0,xx<width,yy>=0,yy<height else{continue}
    let j=yy*width+xx
    guard distance[j]>radius else{continue}
    var difference=0.0
    for c in 0..<3{let d=Double(rgb[i*3+c])-Double(rgb[j*3+c]);difference += d*d}
    let score=difference/700 + Double(dx*dx+dy*dy)*0.003
    if mask[j]>127{best1=min(best1,score)}else{best0=min(best0,score)}
   }}
   guard best0.isFinite,best1.isFinite else{continue}
   let delta=max(-20,min(20,(best0-best1)*2.5))
   let alpha=1/(1+exp(-delta))
   result[i]=UInt8(clamping:Int((max(0,min(1,(alpha-0.12)/0.76))*255).rounded()))
  }
  return result
 }
}
