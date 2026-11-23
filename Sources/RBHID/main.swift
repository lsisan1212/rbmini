import Foundation

// RBHID — reads G9N9N HID reports from the unified Bluetooth log.
//
// macOS BTLEServer receives the remote's GATT input reports but drops some of
// them before IOHID, so IOHID callbacks never fire. With the Bluetooth private
// logging profile installed, BTLEServer logs the raw report; this helper parses
// those lines and broadcasts button edges as newline JSON over UDP 127.0.0.1:51888.

let logPath = "/var/log/rbhid.log"

func hlog(_ s: String) {
    let t = DateFormatter(); t.dateFormat = "HH:mm:ss.SSS"
    let line = "[\(t.string(from: Date()))] \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
        fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

// MARK: - UDP sink

let udp = socket(AF_INET, SOCK_DGRAM, 0)
var dest = sockaddr_in()
dest.sin_family = sa_family_t(AF_INET)
dest.sin_port = UInt16(51888).bigEndian
dest.sin_addr.s_addr = inet_addr("127.0.0.1")

func emit(_ button: String, pressed: Bool) {
    let json = "{\"button\":\"\(button)\",\"pressed\":\(pressed)}\n"
    let data = Array(json.utf8)
    withUnsafePointer(to: dest) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            _ = data.withUnsafeBufferPointer { buf in
                sendto(udp, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

// MARK: - G9N9N consumer usages

let indexedUsages: [UInt16] = [
    0x019E, 0x00CD, 0x0042, 0x0043, 0x0044, 0x0045,
    0x0041, 0x00E2, 0x0221, 0x0223, 0x0224, 0x00E9,
    0x00EA, 0x0077, 0x0078, 0x0079, 0x0089,
]

let names: [UInt16: String] = [
    0x0042: "up", 0x0043: "down", 0x0044: "left", 0x0045: "right",
    0x0041: "ok", 0x0224: "back", 0x0223: "home",
    0x00E9: "volumeUp", 0x00EA: "volumeDown", 0x00E2: "mute",
    0x0077: "youtube", 0x0078: "netflix",
    0x0189: "input", 0x0089: "input", 0x019E: "power",
]

func parseUsages(reportID: UInt32, _ data: [UInt8]) -> Set<UInt16> {
    if reportID == 1 {
        var b = data
        if b.count == 3, b.first == 1 { b.removeFirst() }
        guard b.count == 2 else { return [] }
        var out = Set<UInt16>()
        for idx in b where idx != 0 && Int(idx) <= indexedUsages.count {
            out.insert(indexedUsages[Int(idx) - 1])
        }
        return out
    }
    if reportID == 2 {
        var b = data
        if b.count % 2 == 1, b.first == 2 { b.removeFirst() }
        guard !b.isEmpty, b.count % 2 == 0 else { return [] }
        var out = Set<UInt16>()
        for i in stride(from: 0, to: b.count, by: 2) {
            let u = UInt16(b[i]) | UInt16(b[i + 1]) << 8
            if u != 0 { out.insert(u) }
        }
        return out
    }
    return []
}

var previous: Set<UInt16> = []

func handleReport(reportID: UInt32, data: [UInt8]) {
    let now = parseUsages(reportID: reportID, data)
    hlog("report id=\(reportID) [\(data.map { String(format: "%02X", $0) }.joined(separator: " "))] -> \(now.map { String(format: "0x%04X", $0) }.joined(separator: ","))")
    guard now != previous else { return }
    for u in now.subtracting(previous) { if let n = names[u] { emit(n, pressed: true) } }
    for u in previous.subtracting(now) { if let n = names[u] { emit(n, pressed: false) } }
    previous = now
}

// MARK: - log stream

let predicate = "(process == \"BTLEServer\" AND eventMessage BEGINSWITH \"Updated input report for ID #\")"

let reportPattern = try! NSRegularExpression(
    pattern: #"^Updated input report for ID #(\d+): \{length = (\d+), bytes = 0x([0-9a-fA-F]+)\}$"#
)

func parseLine(_ raw: String) {
    guard let d = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let message = obj["eventMessage"] as? String else { return }
    let range = NSRange(message.startIndex..., in: message)
    guard let m = reportPattern.firstMatch(in: message, range: range),
          let idR = Range(m.range(at: 1), in: message),
          let lenR = Range(m.range(at: 2), in: message),
          let hexR = Range(m.range(at: 3), in: message),
          let reportID = UInt32(message[idR]),
          let length = Int(message[lenR]) else { return }
    let hex = String(message[hexR])
    guard length > 0, length <= 64, hex.count == length * 2 else { return }
    var bytes: [UInt8] = []
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2)
        guard let b = UInt8(hex[idx..<next], radix: 16) else { return }
        bytes.append(b)
        idx = next
    }
    handleReport(reportID: reportID, data: bytes)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
process.arguments = ["stream", "--style", "ndjson", "--level", "debug", "--predicate", predicate]

let pipe = Pipe()
process.standardOutput = pipe
process.standardError = FileHandle.nullDevice

do {
    try process.run()
} catch {
    hlog("failed to start log stream: \(error)")
    exit(1)
}

hlog("rbhid log-stream started uid=\(getuid())")

let handle = pipe.fileHandleForReading
var buffer = Data()
handle.readabilityHandler = { h in
    let chunk = h.availableData
    if chunk.isEmpty { return }
    buffer.append(chunk)
    while let nl = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer[buffer.startIndex..<nl]
        buffer.removeSubrange(buffer.startIndex...nl)
        if let line = String(data: lineData, encoding: .utf8) { parseLine(line) }
    }
}

RunLoop.main.run()
