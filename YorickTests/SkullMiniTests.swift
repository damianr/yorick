import XCTest
@MainActor private final class MiniTestLink: YorickEyeLink {
 var isLinkReady=true
 var sent:[String]=[]
 var incoming:[String]=[]
 func sendEyeLine(_ line:String){sent.append(line)}
 func takeEyeLines()->[String]{defer{incoming=[]};return incoming}
}
final class SkullMiniTests:XCTestCase {
 func testSeparateIdentityAndCompatibleAudioProtocol(){
  XCTAssertNotEqual(SkullMiniBluetoothProtocol.service,SkullBluetoothProtocol.service)
  XCTAssertNotEqual(SkullMiniBluetoothProtocol.deviceUID,SkullBluetoothProtocol.deviceUID)
  #if YORICK_HARDWARE_LAB
  XCTAssertTrue(YorickEyeProtocol.isMicrophoneName(SkullMiniBluetoothProtocol.deviceName))
  #endif
  XCTAssertEqual(SkullMiniBluetoothProtocol.parse("YORICK END 7 16000"),.ended(session:7,samples:16000))
 }
 @MainActor func testSwitchingEyeLinkDoesNotSendMiniCommandsToBigSkull(){
  let d=UserDefaults(suiteName:"MiniTest.\(UUID())")!
  #if YORICK_HARDWARE_LAB
  let mic=YorickMicController(monitor:false,defaults:d,discover:{(0,[])})
  #else
  _=d; let mic=YorickMicController(monitor:false)
  #endif
  let big=MiniTestLink(),mini=MiniTestLink()
  mic.bluetoothSelected={true};mic.bluetoothLink=big;mic.tick()
  let count=big.sent.count
  mic.bluetoothLink=mini;mic.miniSelected=true;mic.inputSelectionChanged()
  XCTAssertEqual(big.sent.count,count)
  XCTAssertTrue(mini.sent.contains("YORICK HELLO 1"))
  XCTAssertEqual(mic.styleGroups.flatMap{$0.1},[YorickEyeStyle.circular,.equalizer,.ember])
  mini.incoming=["YORICK EYES 1"];mic.tick()
  XCTAssertTrue(mic.controlsReady)
 }
}
