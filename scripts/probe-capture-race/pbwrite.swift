import AppKit
import Foundation

// Writes the pasteboard several ways so a poller can be tested against each:
//   fast      - clearContents + setString in the same instant (what pbcopy does)
//   slow      - clearContents, then a 300ms gap before the data lands, which is
//               what multi-flavor writers (Office, Teams, browsers) really do
//   slower    - same, with a 1.2s gap
//   concealed - a password-manager style write, marked never-record
let mode = CommandLine.arguments[1]
let text = CommandLine.arguments[2]
let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
let pb = NSPasteboard.general
pb.clearContents()
switch mode {
case "slow": Thread.sleep(forTimeInterval: 0.3)
case "slower": Thread.sleep(forTimeInterval: 1.2)
case "concealed":
    Thread.sleep(forTimeInterval: 0.3)
    pb.setData(Data(), forType: concealed)
default: break
}
pb.setString(text, forType: .string)
print(pb.changeCount)
