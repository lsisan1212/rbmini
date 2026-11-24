import Foundation
import CoreBluetooth
import IOKit.hid
import ApplicationServices
import AppKit
import AVFoundation
import AudioToolbox

// MARK: - ATVV protocol constants

enum ATVV {
    static let service = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    static let transmit = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    static let audio = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    static let control = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")

    static let getCapabilities = Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])

    static func micOpen(version: UInt16, codec: UInt8) -> Data {
        version >= 0x0100 ? Data([0x0C, 0x00]) : Data([0x0C, 0x00, codec])
    }
    static func micClose(version: UInt16, session: UInt8) -> Data {
        version >= 0x0100 ? Data([0x0D, session]) : Data([0x0D])
    }
    static func micExtend(version: UInt16, session: UInt8) -> Data? {
        version >= 0x0100 ? Data([0x0E, session]) : nil
    }
}

struct Caps {
    var version: UInt16 = 0
    var codec: UInt8 = 1
    var frameSize: Int = 120
    var sampleRate: Double = 8_000
}

// MARK: - IMA ADPCM (high nibble first), same algorithm the remote uses

final class ADPCM {
    private static let steps: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130,
        143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
        494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
        1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
        4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
        27086, 29794, 32767,
    ]
    private static let indexTable = [-1, -1, -1, -1, 2, 4, 6, 8]

    private var predictor = 0
    private var stepIndex = 0

    func reset(predictor: Int = 0, stepIndex: Int = 0) {
        self.predictor = min(32_767, max(-32_768, predictor))
        self.stepIndex = min(88, max(0, stepIndex))
    }

    func decode(_ data: Data) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(nibble(Int(byte >> 4)))
            out.append(nibble(Int(byte & 0x0F)))
        }
        return out
    }

    private func nibble(_ n: Int) -> Int16 {
        let step = Self.steps[stepIndex]
        var diff = step >> 3
        if n & 1 != 0 { diff += step >> 2 }
        if n & 2 != 0 { diff += step >> 1 }
        if n & 4 != 0 { diff += step }
        predictor += (n & 8 != 0) ? -diff : diff
        predictor = min(32_767, max(-32_768, predictor))
        stepIndex += Self.indexTable[n & 7]
        stepIndex = min(88, max(0, stepIndex))
        return Int16(predictor)
    }
}

// MARK: - WAV output

func writeWAV(_ samples: [Int16], sampleRate: Double, to url: URL) throws {
    var data = Data()
    let channels: UInt16 = 1
    let bits: UInt16 = 16
    let blockAlign = channels * bits / 8
    let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
    let payload = UInt32(samples.count * 2)

    func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    data.append("RIFF".data(using: .ascii)!)
    data.append(le32(36 + payload))
    data.append("WAVEfmt ".data(using: .ascii)!)
    data.append(le32(16))
    data.append(le16(1))
    data.append(le16(channels))
    data.append(le32(UInt32(sampleRate)))
    data.append(le32(byteRate))
    data.append(le16(blockAlign))
    data.append(le16(bits))
    data.append("data".data(using: .ascii)!)
    data.append(le32(payload))
    for s in samples { data.append(le16(UInt16(bitPattern: s))) }
    try data.write(to: url)
}

// MARK: - Client

final class ATVVClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var audioChar: CBCharacteristic?
    private var controlChar: CBCharacteristic?
    private var hidReportChar: CBCharacteristic?
    private var hidCount = 0

    private var caps = Caps()
    private var capsConfirmed = false
    private var sessionID: UInt8 = 0
    private var streaming = false
    private var micOpened = false
    private var controlCount = 0
    private var audioPackets = 0
    private var pending = Data()
    private var decoder = ADPCM()
    private var pcm: [Int16] = []
    private var pendingSync: (Int, Int)?
    private var framesBeforeSync = 0
    private var keepalive: Timer?
    private var startTime = Date()

    var onStreamStart: (() -> Void)?
    var onStreamStop: (() -> Void)?

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("central state=\(central.state.rawValue)")
        guard central.state == .poweredOn else { return }
        let existing = central.retrieveConnectedPeripherals(withServices: [ATVV.service])
        for p in existing {
            log("retrieved connected \(p.name ?? "<unnamed>")")
            if self.peripheral == nil {
                self.peripheral = p
                p.delegate = self
                central.connect(p)
            }
        }
        log("scanning…")
        central.scanForPeripherals(withServices: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let advServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isVoiceRemote = name.localizedCaseInsensitiveContains("chromecast")
            || advServices.contains(ATVV.service)
        guard isVoiceRemote else { return }
        guard self.peripheral == nil else { return }
        log("found \(name.isEmpty ? "<unnamed>" : name) rssi=\(RSSI)")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("connected \(peripheral.name ?? "?")")
        peripheral.discoverServices([ATVV.service, CBUUID(string: "1812")])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("connect failed: \(error?.localizedDescription ?? "?")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("disconnected: \(error?.localizedDescription ?? "clean")")
        flush()
        exit(0)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return log("discover services error \(error!)") }
        for service in peripheral.services ?? [] {
            if service.uuid == ATVV.service {
                peripheral.discoverCharacteristics([ATVV.transmit, ATVV.audio, ATVV.control], for: service)
            } else if service.uuid == CBUUID(string: "1812") {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return log("discover chars error \(error!)") }
        guard service.uuid == ATVV.service else {
            for c in service.characteristics ?? [] {
                log("hid char \(c.uuid.uuidString) props=0x\(String(c.properties.rawValue, radix: 16))")
                if c.uuid == CBUUID(string: "2A4D") || c.uuid == CBUUID(string: "2A22") {
                    hidReportChar = c
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            return
        }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case ATVV.transmit: tx = c
            case ATVV.audio: audioChar = c
            case ATVV.control: controlChar = c
            default: break
            }
            log("char \(c.uuid.uuidString) props=0x\(String(c.properties.rawValue, radix: 16))")
        }
        guard let txC = tx, let audioC = audioChar, let controlC = controlChar else {
            return log("missing characteristics: tx=\(tx != nil) audio=\(audioChar != nil) control=\(controlChar != nil)")
        }
        log("subscribing notifications")
        peripheral.setNotifyValue(true, for: audioC)
        peripheral.setNotifyValue(true, for: controlC)
        log("requesting capabilities")
        peripheral.writeValue(ATVV.getCapabilities, for: txC,
                              type: txC.properties.contains(.write) ? .withResponse : .withoutResponse)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("write \(characteristic.uuid.uuidString) error \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log("notify \(characteristic.uuid) error \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        if characteristic.uuid == ATVV.control { handleControl(data) }
        if characteristic.uuid == ATVV.audio { handleAudio(data) }
        if characteristic.uuid == hidReportChar?.uuid || characteristic.uuid == CBUUID(string: "2A4D") {
            hidCount += 1
            if hidCount <= 12 || hidCount % 20 == 0 {
                log("hid #\(hidCount) \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
        }
    }

    // MARK: control

    private func handleControl(_ data: Data) {
        let b = Array(data)
        guard let op = b.first else { return }
        controlCount += 1
        if controlCount <= 40 || op != 0x00 {
            log("ctl op=0x\(String(format: "%02X", op)) bytes=\(b.count) \(b.prefix(10).map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        switch op {
        case 0x0B:
            guard b.count >= 7 else { return log("caps too short") }
            caps.version = UInt16(b[1]) << 8 | UInt16(b[2])
            let codecs = caps.version >= 0x0100 ? b[3] : b[4]
            let frame = caps.version >= 0x0100
                ? Int(b[5]) << 8 | Int(b[6])
                : Int(b[7]) << 8 | Int(b[8])
            caps.codec = (codecs & 0x02 != 0) ? 0x02 : 0x01
            caps.frameSize = frame == 0 ? 120 : frame
            caps.sampleRate = caps.codec == 0x02 ? 16_000 : 8_000
            capsConfirmed = true
            log("caps version=0x\(String(caps.version, radix: 16)) codec=\(caps.codec) frame=\(caps.frameSize) rate=\(Int(caps.sampleRate))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.micOpened else { return }
                self.write(ATVV.micOpen(version: self.caps.version, codec: self.caps.codec))
                self.micOpened = true
                log("proactive MIC_OPEN")
            }

        case 0x08:
            guard capsConfirmed else { return }
            log("remote voice press → MIC_OPEN")
            if !micOpened {
                write(ATVV.micOpen(version: caps.version, codec: caps.codec))
                micOpened = true
            }

        case 0x04:
            if b.count >= 4, b[3] == 0 {
                log("ignore session-0 start")
                return
            }
            if b.count >= 4 { sessionID = b[3] }
            audioPackets = 0
            if b.count >= 3 {
                let codec = b[2]
                caps.codec = codec
                caps.sampleRate = codec == 0x02 ? 16_000 : 8_000
            }
            streaming = true
            pending.removeAll()
            pcm.removeAll()
            decoder.reset()
            pendingSync = nil
            startTime = Date()
            log("stream start session=\(sessionID) codec=\(caps.codec)")
            onStreamStart?()
            startKeepalive()

        case 0x00:
            guard streaming else { return }
            if audioPackets == 0 {
                log("empty stop ignored")
                streaming = false
                return
            }
            log("remote stream stop")
            onStreamStop?()
            stopStreaming()

        case 0x0A:
            guard b.count >= 7 else { return }
            let bits = UInt16(b[4]) << 8 | UInt16(b[5])
            pendingSync = (Int(Int16(bitPattern: bits)), Int(b[6]))
            framesBeforeSync = pending.isEmpty ? 0 : 1

        default:
            log("control op=0x\(String(format: "%02X", op)) bytes=\(b.count)")
        }
    }

    private func handleAudio(_ data: Data) {
        guard streaming else { return }
        audioPackets += 1
        if audioPackets <= 3 || audioPackets % 50 == 0 {
            log("audio #\(audioPackets) bytes=\(data.count)")
        }
        pending.append(data)
        while pending.count >= caps.frameSize {
            let frame = pending.prefix(caps.frameSize)
            pending.removeFirst(caps.frameSize)
            if let sync = pendingSync, framesBeforeSync == 0 {
                decoder.reset(predictor: sync.0, stepIndex: sync.1)
                pendingSync = nil
            }
            if framesBeforeSync > 0 { framesBeforeSync -= 1 }
            let samples = decoder.decode(frame)
            pcm.append(contentsOf: samples)
            audioOut.play(samples)
        }
    }

    private func startKeepalive() {
        keepalive?.invalidate()
        keepalive = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, streaming, let cmd = ATVV.micExtend(version: self.caps.version, session: self.sessionID) else { return }
            self.write(cmd)
        }
    }

    private func stopStreaming() {
        keepalive?.invalidate(); keepalive = nil
        streaming = false
        if micOpened {
            write(ATVV.micClose(version: caps.version, session: sessionID))
            micOpened = false
            log("MIC_CLOSE sent session=\(sessionID)")
        }
        flush()
    }

    private func flush() {
        if !pending.isEmpty {
            let frame = pending
            pending.removeAll()
            if let sync = pendingSync, framesBeforeSync == 0 {
                decoder.reset(predictor: sync.0, stepIndex: sync.1)
                pendingSync = nil
            }
            pcm.append(contentsOf: decoder.decode(frame))
        }
        guard !pcm.isEmpty else { return log("no audio captured") }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Workbuddy/remotebuddy-mini/out", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("voice-\(fmt.string(from: startTime)).wav")
        do {
            try writeWAV(pcm, sampleRate: caps.sampleRate, to: url)
            let secs = Double(pcm.count) / caps.sampleRate
            log("saved \(pcm.count) samples (\(String(format: "%.2f", secs))s) → \(url.path)")
        } catch {
            log("wav write failed \(error)")
        }
        pcm.removeAll()
    }

    private func write(_ data: Data) {
        guard let peripheral, let tx else { return log("write skipped (not ready)") }
        let type: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: tx, type: type)
    }
}

// MARK: - HID buttons (IOHIDManager sees the system HID link, no GATT HID needed)

let hidReportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)

func hidReportCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                       sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                       reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
    let bytes = (0..<length).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
    log("hid report id=\(reportID) len=\(length) [\(bytes)]")
}

func hidDeviceCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                       sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    log("hid device matched: \(name)")
}

func hidValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                      sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let int = IOHIDValueGetIntegerValue(value)
    if int != 0 || page == 0x0C {
        log("hid value page=0x\(String(page, radix: 16)) usage=0x\(String(usage, radix: 16)) value=\(int)")
    }
}

func startHID() {
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    log("hid listen access=\(access.rawValue) (0=granted 1=denied 2=unknown)")
    if access != kIOHIDAccessTypeGranted {
        let requested = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        log("hid access requested=\(requested)")
    }
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matches: [[String: Any]] = [[
        kIOHIDVendorIDKey: 0x18D1,
        kIOHIDProductIDKey: 0x9450,
    ]]
    // Callbacks must be installed before matching: matching enumerates already
    // connected devices immediately and later callbacks are not replayed.
    IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceCallback, nil)
    IOHIDManagerRegisterInputReportCallback(manager, hidReportCallback, nil)
    IOHIDManagerRegisterInputValueCallback(manager, hidValueCallback, nil)
    IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    let r: IOReturn = kIOReturnSuccess
    log("hid manager scheduled (no manager-level open)")
    if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
        log("hid matched devices=\(set.count)")
        for d in set {
            let v = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int ?? -1
            let p = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? -1
            let n = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
            IOHIDDeviceRegisterInputValueCallback(d, hidValueCallback, nil)
            IOHIDDeviceRegisterInputReportCallback(d, hidReportBuffer, 4096, hidReportCallback, nil)
            IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            let seized = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            var opened = seized
            if seized != kIOReturnSuccess {
                opened = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            let page = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let usage = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            let transport = IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? "?"
            let elements = (IOHIDDeviceCopyMatchingElements(d, nil, 0) as? [IOHIDElement])?.count ?? -1
            log("  \(n) vid=0x\(String(v, radix: 16)) pid=0x\(String(p, radix: 16)) page=0x\(String(page, radix: 16)) usage=0x\(String(usage, radix: 16)) transport=\(transport) elements=\(elements) seize=\(seized) open=\(opened)")
        }
    }
}

// MARK: - Event tap (what macOS already derives from the remote)

func startEventTap() {
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    let trusted = AXIsProcessTrustedWithOptions(prompt as CFDictionary)
    log("ax trusted=\(trusted)")

    let systemDefined = CGEventType(rawValue: 14)!
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << systemDefined.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, type, event, _ in
            if type.rawValue == 14, let ns = NSEvent(cgEvent: event) {
                log("event systemDefined subtype=\(ns.subtype.rawValue) data1=0x\(String(ns.data1, radix: 16))")
            } else {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                log("event type=\(type.rawValue) keycode=\(code) flags=0x\(String(event.flags.rawValue, radix: 16))")
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
    else { return log("event tap create FAILED") }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("event tap installed")
}

// MARK: - Playback into the virtual microphone

final class AudioOut {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16_000, channels: 1, interleaved: false)!
    private(set) var ready = false

    func start() {
        guard !ready else { return }
        engine.attach(player)

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var count: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &count)
        var devices = [AudioDeviceID](repeating: 0, count: Int(count) / Int(size))
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &count, &devices)
        for d in devices {
            var ua = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
            var cf: CFString = "" as CFString
            var s = UInt32(MemoryLayout<CFString>.size)
            let err = withUnsafeMutablePointer(to: &cf) { p in
                AudioObjectGetPropertyData(d, &ua, 0, nil, &s, p)
            }
            if err == noErr, (cf as String) == "BuddyMic2ch_UID" { deviceID = d; break }
        }
        guard deviceID != 0 else { return log("audio: BuddyMic device not found") }
        var a = AudioObjectPropertyAddress(mSelector: kAudioOutputUnitProperty_CurrentDevice,
                                           mScope: kAudioUnitScope_Global,
                                           mElement: kAudioObjectPropertyElementMain)
        let status = AudioUnitSetProperty(engine.outputNode.audioUnit!, a.mSelector,
                                          a.mScope, 0, &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        log("audio: set device \(deviceID) status=\(status)")

        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            engine.prepare()
            try engine.start()
            ready = true
            log("audio engine started")
        } catch {
            log("audio engine failed: \(error.localizedDescription)")
        }
    }

    func play(_ samples: [Int16]) {
        guard ready, !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let ch = buf.floatChannelData?[0] {
            for i in samples.indices { ch[i] = Float(samples[i]) / 32768.0 }
        }
        player.scheduleBuffer(buf)
        if !player.isPlaying { player.play() }
    }

    func stop() {
        player.stop()
        engine.stop()
        ready = false
    }
}

let audioOut = AudioOut()

// MARK: - Action table

let buttonOrder = ["up", "down", "left", "right", "ok", "back", "home",
                   "volumeUp", "volumeDown", "mute", "youtube", "netflix",
                   "input", "power"]

let buttonLabels: [String: String] = [
    "up": "上", "down": "下", "left": "左", "right": "右",
    "ok": "OK", "back": "返回", "home": "Home",
    "volumeUp": "音量 +", "volumeDown": "音量 −", "mute": "靜音",
    "youtube": "YouTube", "netflix": "Netflix", "input": "Input", "power": "Power",
]

let actionGroups: [(String, [(String, String)])] = [
    ("基本", [
        ("arrowUp", "↑ 方向鍵上"), ("arrowDown", "↓ 方向鍵下"),
        ("arrowLeft", "← 方向鍵左"), ("arrowRight", "→ 方向鍵右"),
        ("returnKey", "Return ／ Enter"), ("keypadEnter", "數字鍵盤 Enter"),
        ("escape", "Esc"), ("tab", "Tab"), ("space", "Space"),
        ("deleteBackward", "Delete（退格）"), ("deleteForward", "Delete（向前）"),
        ("homeKey", "Home"), ("endKey", "End"),
        ("pageUp", "Page Up"), ("pageDown", "Page Down"),
    ]),
    ("編輯", [
        ("copy", "複製 ⌘C"), ("paste", "貼上 ⌘V"), ("cut", "剪下 ⌘X"),
        ("selectAll", "全選 ⌘A"), ("undo", "還原 ⌘Z"), ("save", "儲存 ⌘S"),
        ("find", "尋找 ⌘F"),
    ]),
    ("系統", [
        ("appSwitcher", "切換 App ⌘Tab"), ("missionControl", "Mission Control"),
        ("appExpose", "App Exposé"), ("launchpad", "Launchpad"),
        ("spotlight", "Spotlight ⌘Space"),
        ("closeWindow", "關閉視窗 ⌘W"), ("quitApp", "結束 App ⌘Q"),
        ("lockScreen", "鎖定螢幕 ⌃⌘Q"),
        ("screenshotFull", "截圖 全螢幕"), ("screenshotArea", "截圖 選取範圍"),
    ]),
    ("媒體", [
        ("volumeUp", "音量 +"), ("volumeDown", "音量 −"), ("volumeMute", "靜音"),
        ("brightnessUp", "亮度 +"), ("brightnessDown", "亮度 −"),
        ("playPause", "播放／暫停"), ("nextTrack", "下一曲"), ("previousTrack", "上一曲"),
        ("scrollUp", "向上捲動"), ("scrollDown", "向下捲動"),
    ]),
]

let actionCatalog: [(String, String)] = actionGroups.flatMap { $0.1 } + [("none", "無")]

let actionMapKey = "actionMap"
var actionMap: [String: String] = [:]

func saveActionMap() {
    UserDefaults.standard.set(actionMap, forKey: actionMapKey)
}

// MARK: - Button actions

var fnHeld = false
func setFnHeld(_ down: Bool) {
    guard down != fnHeld else { return }
    fnHeld = down
    let src = CGEventSource(stateID: .hidSystemState)
    if let e = CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: down) {
        e.flags = down ? .maskSecondaryFn : []
        e.post(tap: .cghidEventTap)
    }
    log("FN \(down ? "down" : "up")")
}

func sendKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
        down.flags = flags
        down.post(tap: .cghidEventTap)
    }
    if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }
}

func sendMediaKey(_ key: Int32) {
    for isDown in [true, false] {
        let data1 = (Int(key) << 16) | (isDown ? 0x0a00 : 0x0b00)
        if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                       modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil,
                                       subtype: 8, data1: data1, data2: -1),
           let cg = ev.cgEvent {
            cg.post(tap: .cghidEventTap)
        }
    }
}

let defaultActions: [String: String] = [
    "up": "arrowUp", "down": "arrowDown", "left": "arrowLeft", "right": "arrowRight",
    "ok": "returnKey", "back": "escape", "home": "appSwitcher",
    "volumeUp": "volumeUp", "volumeDown": "volumeDown", "mute": "volumeMute",
    "youtube": "previousTrack", "netflix": "nextTrack",
    "input": "playPause", "power": "deleteBackward",
]

if let saved = UserDefaults.standard.dictionary(forKey: actionMapKey) as? [String: String] {
    actionMap = saved
} else {
    actionMap = defaultActions
}

// MARK: - Custom actions: shell command / URL

func runShell(_ command: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", command]
    do {
        try p.run()
        log("sh: \(command)")
    } catch {
        log("sh failed: \(error.localizedDescription)")
    }
}

func openTarget(_ target: String) {
    let t = target.trimmingCharacters(in: .whitespaces)
    if let url = URL(string: t), let scheme = url.scheme?.lowercased(),
       ["http", "https", "mailto", "shortcuts", "raycast"].contains(scheme) {
        NSWorkspace.shared.open(url)
        log("open url: \(t)")
    } else {
        let path = (t as NSString).expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        log("open path: \(path)")
    }
}

func scrollWheel(_ lines: Int32) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                          wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
    e.post(tap: .cghidEventTap)
}

func perform(_ action: String) {
    if action.hasPrefix("sh:") { return runShell(String(action.dropFirst(3))) }
    if action.hasPrefix("open:") { return openTarget(String(action.dropFirst(5))) }

    switch action {
    case "arrowUp": sendKey(126)
    case "arrowDown": sendKey(125)
    case "arrowLeft": sendKey(123)
    case "arrowRight": sendKey(124)
    case "returnKey": sendKey(36)
    case "keypadEnter": sendKey(76)
    case "escape": sendKey(53)
    case "tab": sendKey(48)
    case "space": sendKey(49)
    case "deleteBackward": sendKey(51)
    case "deleteForward": sendKey(117)
    case "homeKey": sendKey(115)
    case "endKey": sendKey(119)
    case "pageUp": sendKey(116)
    case "pageDown": sendKey(121)

    case "copy": sendKey(8, flags: .maskCommand)
    case "paste": sendKey(9, flags: .maskCommand)
    case "cut": sendKey(7, flags: .maskCommand)
    case "selectAll": sendKey(0, flags: .maskCommand)
    case "undo": sendKey(6, flags: .maskCommand)
    case "save": sendKey(1, flags: .maskCommand)
    case "find": sendKey(3, flags: .maskCommand)

    case "appSwitcher": sendKey(48, flags: .maskCommand)
    case "missionControl": sendKey(126, flags: .maskControl)
    case "appExpose": sendKey(125, flags: .maskControl)
    case "launchpad": runShell("open -a Launchpad")
    case "spotlight": sendKey(49, flags: .maskCommand)
    case "closeWindow": sendKey(13, flags: .maskCommand)
    case "quitApp": sendKey(12, flags: .maskCommand)
    case "lockScreen": sendKey(12, flags: [.maskCommand, .maskControl])
    case "screenshotFull": sendKey(20, flags: [.maskCommand, .maskShift])
    case "screenshotArea": sendKey(21, flags: [.maskCommand, .maskShift])

    case "volumeUp": sendMediaKey(0)
    case "volumeDown": sendMediaKey(1)
    case "volumeMute": sendMediaKey(7)
    case "brightnessUp": sendMediaKey(2)
    case "brightnessDown": sendMediaKey(3)
    case "playPause": sendMediaKey(16)
    case "nextTrack": sendMediaKey(17)
    case "previousTrack": sendMediaKey(18)
    case "scrollUp": scrollWheel(3)
    case "scrollDown": scrollWheel(-3)

    default: log("  unknown action \(action)")
    }
}

func handleButton(_ name: String, pressed: Bool) {
    log("BTN \(name) \(pressed ? "down" : "up")")
    guard pressed else { return }
    if let action = actionMap[name], action != "none" {
        log("  action=\(action)")
        perform(action)
    }
}

// MARK: - Button events from the root helper

func startButtonReceiver() {
    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    guard sock >= 0 else { return log("udp socket failed") }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(51888).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { return log("udp bind 51888 failed errno=\(errno)") }
    log("button receiver listening on 127.0.0.1:51888")
    DispatchQueue.global(qos: .userInteractive).async {
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = recv(sock, &buf, buf.count, 0)
            guard n > 0 else { continue }
            let line = String(decoding: buf[0..<n], as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let button = obj["button"] as? String,
                  let pressed = obj["pressed"] as? Bool else { continue }
            DispatchQueue.main.async { handleButton(button, pressed: pressed) }
        }
    }
}

// MARK: - main

let outDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Workbuddy/remotebuddy-mini/out", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let logURL = outDir.appendingPathComponent("rbmini.log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try? FileHandle(forWritingTo: logURL)

func log(_ s: String) {
    let t = DateFormatter(); t.dateFormat = "HH:mm:ss.SSS"
    let line = "[\(t.string(from: Date()))] \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    logHandle?.write(line.data(using: .utf8)!)
}

final class StatusController: NSObject {
    let item: NSStatusItem
    private let menu = NSMenu()

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            for name in ["av.remote.fill", "av.remote", "dot.radiowaves.left.and.right"] {
                if let img = NSImage(systemSymbolName: name, accessibilityDescription: "RBMini") {
                    img.isTemplate = true
                    button.image = img
                    button.imagePosition = .imageLeading
                    break
                }
            }
            button.title = "RBMini"
            button.toolTip = "RBMini — G9N9N remote bridge"
        }
        rebuild()
        item.menu = menu
    }

    private func rebuild() {
        menu.removeAllItems()

        let mapping = NSMenuItem(title: "動作映射", action: nil, keyEquivalent: "")
        mapping.submenu = buildMappingMenu()
        menu.addItem(mapping)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "打開 Log", action: #selector(openLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "退出 RBMini", action: #selector(quit), keyEquivalent: "q"))
        for m in menu.items { m.target = self }
    }

    private func buildMappingMenu() -> NSMenu {
        let root = NSMenu()
        for button in buttonOrder {
            let item = NSMenuItem(title: buttonLabels[button] ?? button, action: nil, keyEquivalent: "")
            item.submenu = buildActionMenu(for: button)
            root.addItem(item)
        }
        return root
    }

    private func buildActionMenu(for button: String) -> NSMenu {
        let sub = NSMenu()
        let current = actionMap[button] ?? "none"

        for (groupTitle, actions) in actionGroups {
            sub.addItem(.sectionHeader(title: groupTitle))
            for (id, label) in actions {
                let mi = NSMenuItem(title: label, action: #selector(selectAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = [button, id]
                mi.state = (current == id) ? .on : .off
                sub.addItem(mi)
            }
        }

        sub.addItem(.sectionHeader(title: "自訂"))
        let custom = NSMenuItem(title: "執行指令／開網址…", action: #selector(promptCustom(_:)), keyEquivalent: "")
        custom.target = self
        custom.representedObject = button
        sub.addItem(custom)

        if current.hasPrefix("sh:") || current.hasPrefix("open:") {
            let body = current.hasPrefix("sh:") ? String(current.dropFirst(3)) : String(current.dropFirst(5))
            let info = NSMenuItem(title: "目前：\(body)", action: nil, keyEquivalent: "")
            info.state = .on
            sub.addItem(info)
            let clear = NSMenuItem(title: "清除自訂動作", action: #selector(selectAction(_:)), keyEquivalent: "")
            clear.target = self
            clear.representedObject = [button, "none"]
            sub.addItem(clear)
        }

        let none = NSMenuItem(title: "無", action: #selector(selectAction(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = [button, "none"]
        none.state = (current == "none") ? .on : .off
        sub.addItem(none)
        return sub
    }

    @objc private func promptCustom(_ sender: NSMenuItem) {
        guard let button = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "自訂動作 — \(buttonLabels[button] ?? button)"
        alert.informativeText = """
        輸入 shell 指令，例如：open -a Music
        或以 http:// 開頭的網址，例如：https://youtube.com
        指令會以 /bin/zsh -lc 執行。
        """
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "open -a Music"
        if let cur = actionMap[button] {
            if cur.hasPrefix("sh:") { field.stringValue = String(cur.dropFirst(3)) }
            else if cur.hasPrefix("open:") { field.stringValue = String(cur.dropFirst(5)) }
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let lower = text.lowercased()
        actionMap[button] = (lower.hasPrefix("http://") || lower.hasPrefix("https://"))
            ? "open:\(text)" : "sh:\(text)"
        saveActionMap()
        rebuild()
        log("mapping \(button) -> \(actionMap[button] ?? "")")
    }

    @objc private func selectAction(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        actionMap[pair[0]] = pair[1]
        saveActionMap()
        rebuild()
        log("mapping \(pair[0]) -> \(pair[1])")
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusController = StatusController()

let client = ATVVClient()
client.onStreamStart = {
    audioOut.start()
    setFnHeld(true)
}
client.onStreamStop = {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
        setFnHeld(false)
        audioOut.stop()
    }
}
client.start()
startHID()
startEventTap()
startButtonReceiver()
app.run()
