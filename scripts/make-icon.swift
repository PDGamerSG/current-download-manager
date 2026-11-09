import AppKit

let output = CommandLine.arguments[1]
let image = NSImage(size:NSSize(width:1024,height:1024))
image.lockFocus()
let rect = NSRect(x:60,y:60,width:904,height:904)
let background = NSBezierPath(roundedRect:rect,xRadius:210,yRadius:210)
NSGradient(starting:NSColor(calibratedRed:0.13,green:0.48,blue:0.90,alpha:1),ending:NSColor(calibratedRed:0.08,green:0.24,blue:0.68,alpha:1))!.draw(in:background,angle:-85)
NSColor.white.setStroke()
let arrow = NSBezierPath(); arrow.lineWidth = 72; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
arrow.move(to:NSPoint(x:512,y:764)); arrow.line(to:NSPoint(x:512,y:350))
arrow.move(to:NSPoint(x:348,y:510)); arrow.line(to:NSPoint(x:512,y:346)); arrow.line(to:NSPoint(x:676,y:510)); arrow.stroke()
let wave = NSBezierPath(); wave.lineWidth = 40; wave.lineCapStyle = .round
wave.move(to:NSPoint(x:277,y:278)); wave.curve(to:NSPoint(x:747,y:278),controlPoint1:NSPoint(x:430,y:205),controlPoint2:NSPoint(x:590,y:205)); wave.stroke()
image.unlockFocus()
let data = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
try data.write(to:URL(fileURLWithPath:output))
