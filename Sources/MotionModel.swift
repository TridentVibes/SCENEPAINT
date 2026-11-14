import Foundation

// Optional metadata leaves all pre-Motion projects and original geometry intact.
enum MotionKind:String,Codable,CaseIterable,Identifiable{
    case boil="Line Boil",blink="Blink / Flash",glitch="Glitch",emission="Emission / Spill"
    var id:String{rawValue}
}
enum BoilMode:String,Codable,CaseIterable{case redrawn="Redrawn",jitter="Jitter"}
enum BlinkMode:String,Codable,CaseIterable{case regular="Regular",flicker="Flicker",sequence="Sequence"}
struct MotionEffect:Codable,Equatable,Identifiable{
    var id=UUID();var kind:MotionKind;var enabled=true
    var intensity=1.0;var frequency=2.0;var seed=1
    var variations=3;var boilMode:BoilMode = .redrawn
    var duty=0.5;var fadeIn=0.03;var fadeOut=0.03;var minimum=0.0;var maximum=1.0
    var blinkMode:BlinkMode = .regular;var sequence="11010010"
    var randomness=0.5;var eventDuration=0.1;var segments=8;var rgbOffset=false
    var color=[1.0,0.2,0.05];var inheritColor=true;var glowRadius=8.0;var falloff=1.0
    var spill=0.0;var spillRadius=50.0;var spillOpacity=0.5;var constrainSpill=true
    var spillMaskAsset:String?=nil;var spillMaskFrame:SceneFrame?=nil;var syncBlink=true
    static func make(_ kind:MotionKind)->MotionEffect{
        var effect=MotionEffect(kind:kind)
        if kind == .boil{effect.frequency=8;effect.intensity=1.2}
        if kind == .glitch{effect.intensity=3}
        return effect
    }
}
struct MotionStack:Codable,Equatable{
    var enabled=true;var phase=0.0;var effects:[MotionEffect]=[]
    var active:Bool{enabled && effects.contains{$0.enabled}}
}
struct MotionGroup:Codable,Equatable,Identifiable{var id=UUID();var name:String;var animation=MotionStack()}
struct MotionSettings:Codable,Equatable{
    var duration=3.0;var fps=24;var loop=true;var outputSize=1024;var previewSize=768;var quality=0.8
    var frameCount:Int{max(1,Int((max(0.25,min(30,duration))*Double(max(6,min(30,fps)))).rounded()))}
}
enum MotionScope:String,CaseIterable{case layer="Layer",strokes="Strokes",group="Group"}

// No wall-clock random numbers or Swift Hasher: results survive save/reopen.
enum MotionTiming{
    static func random(_ seed:Int,_ index:Int)->Double{
        var x=UInt64(bitPattern:Int64(seed)) &+ UInt64(bitPattern:Int64(index)) &* 0x9E3779B97F4A7C15
        x=(x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9;x=(x ^ (x >> 27)) &* 0x94D049BB133111EB
        return Double((x ^ (x >> 31)) >> 11)/9007199254740992
    }
    static func phase(_ time:Double,_ duration:Double)->Double{
        let d=max(0.01,duration),p=time.truncatingRemainder(dividingBy:d)/d
        return p<0 ? p+1:p
    }
    static func cycles(_ effect:MotionEffect,_ duration:Double)->Int{max(1,Int((max(0.05,effect.frequency)*max(0.01,duration)).rounded()))}
    static func variation(_ effect:MotionEffect,time:Double,duration:Double)->Int{
        let n=max(2,min(12,effect.variations)),steps=n*max(1,Int((effect.frequency*duration/Double(n)).rounded()))
        return Int(floor(phase(time,duration)*Double(steps))) % n
    }
    static func level(_ effect:MotionEffect,time:Double,duration:Double)->Double{
        let count=cycles(effect,duration),p=phase(time,duration)*Double(count),index=Int(floor(p)),local=p-floor(p)
        let duty=max(0.01,min(0.99,effect.duty))
        var level:Double=0
        switch effect.blinkMode{
        case .regular:level=local<duty ? 1:0
        case .flicker:level=local<duty && random(effect.seed,index)>effect.randomness*0.7 ? 1:0
        case .sequence:
            let bits=effect.sequence.filter{$0=="0" || $0=="1"};let array=Array(bits.isEmpty ? "10":bits)
            let step=Int(floor(phase(time,duration)*Double(array.count)))
            level=array[min(array.count-1,step)]=="1" ? 1:0
        }
        if level>0,effect.blinkMode != .sequence{
            let seconds=duration/Double(count),on=seconds*duty,elapsed=local*seconds
            if effect.fadeIn>0{level=min(level,elapsed/effect.fadeIn)}
            if effect.fadeOut>0{level=min(level,max(0,(on-elapsed)/effect.fadeOut))}
        }
        return max(0,min(1,effect.minimum+(effect.maximum-effect.minimum)*level))
    }
    static func pulse(_ effect:MotionEffect,time:Double,duration:Double)->Double{
        0.5-0.5*cos(phase(time,duration)*Double(cycles(effect,duration))*2 * .pi)
    }
    static func geometryOffset(_ effect:MotionEffect,index:Int,variation:Int)->Dot{
        let a=random(effect.seed,variation*101+7)*2 * .pi
        if effect.boilMode == .jitter{return Dot(x:cos(a)*effect.intensity,y:sin(a)*effect.intensity)}
        let phase=random(effect.seed,variation*101+13)*2 * .pi
        let t=Double(index)*0.17
        return Dot(x:effect.intensity*(sin(t+phase)*0.65+sin(t*0.37+a)*0.35),y:effect.intensity*(cos(t*0.83+phase)*0.65+sin(t*0.43+a)*0.35))
    }
    static func geometryOffset(_ effect:MotionEffect,point:Dot,variation:Int)->Dot{
        if effect.boilMode == .jitter{return geometryOffset(effect,index:0,variation:variation)}
        let a=random(effect.seed,variation*101+7)*2 * .pi,b=random(effect.seed,variation*101+13)*2 * .pi
        return Dot(x:effect.intensity*(sin(point.x/45+point.y/73+a)*0.7+sin(point.y/31+b)*0.3),y:effect.intensity*(cos(point.y/51+point.x/89+b)*0.7+sin(point.x/37+a)*0.3))
    }
    static func blinkGain(_ stacks:[MotionStack],time:Double,duration:Double)->Double{
        stacks.filter{$0.enabled}.reduce(1){value,stack in
            stack.effects.filter{$0.enabled && $0.kind == .blink}.reduce(value){$0*level($1,time:time+stack.phase,duration:duration)}
        }
    }
}
