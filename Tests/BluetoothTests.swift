import Foundation
@main struct BluetoothTests {
    static func main() throws {
        var checks=0
        func check(_ result: Bool,_ message:String){checks+=1;if !result{fatalError(message)}}
        check(BluetoothWire.acknowledgement("ACK:7",current:7,waiting:true)?.completes == true,"current acknowledgement advances delivery")
        check(BluetoothWire.acknowledgement("ACK:7",current:7,waiting:false)?.completes == false,"duplicate acknowledgement is accepted without disconnect")
        check(BluetoothWire.acknowledgement("ACK:6",current:7,waiting:true)?.completes == false,"late acknowledgement cannot close newer delivery")
        check(BluetoothWire.acknowledgement("ACK:4294967296",current:7,waiting:true) == nil,"malformed acknowledgement is rejected")
        let id=UUID(),stream=UUID().uuidString
        let original=String(repeating:"안녕하세요，今天讨论蓝牙字幕🙂。",count:40)
        let caption=Caption(id:id,date:Date(timeIntervalSince1970:0),original:original,translated:"中文翻译")
        let snapshot=PhoneSnapshot(status:"正在收音",running:true,captions:[caption],pending:0)
        let update=BluetoothWire.update(previous:nil,latest:snapshot,stream:stream,message:7)!
        check(update.kind=="snapshot" && update.captions.count==1,"initial snapshot")
        check(BluetoothWire.update(previous:snapshot,latest:snapshot,stream:stream,message:8)==nil,"unchanged state not retransmitted")
        var translated=snapshot;translated.captions[0].translated="新的译文"
        let patch=BluetoothWire.update(previous:snapshot,latest:translated,stream:stream,message:8)!
        check(patch.kind=="patch" && patch.captions[0].translated=="新的译文","translation update sends only changed caption")
        let empty=PhoneSnapshot(status:"准备就绪",running:false,captions:[],pending:0)
        let clear=BluetoothWire.update(previous:snapshot,latest:empty,stream:stream,message:9)!
        check(clear.captions.isEmpty && clear.removed==[id],"clear removes phone history")
        let data=try JSONEncoder().encode(update)
        var fixture=Data()
        for mtu in [20,64,182,512] {
            let frames=try BluetoothWire.frames(data,message:7,maximumLength:mtu)
            var joined=Data()
            for frame in frames {check(frame.count<=mtu,"MTU respected");joined.append(frame.dropFirst(12))}
            check(joined==data,"multi-byte UTF-8 survives chunk boundaries")
            if mtu==20 {for frame in frames {fixture.append(UInt8((frame.count>>8)&255));fixture.append(UInt8(frame.count&255));fixture.append(frame)}}
        }
        do{_=try BluetoothWire.frames(Data(repeating:0,count:BluetoothWire.maximumPayload+1),message:1,maximumLength:20);fatalError("unbounded payload")}catch{checks+=1}
        try fixture.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("ble-frames.bin"))
        print("PASS: \(checks) BLE protocol checks (snapshot, delta, clear, bounded UTF-8 frames)")
    }
}
