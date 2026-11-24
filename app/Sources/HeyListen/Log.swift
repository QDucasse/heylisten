import Foundation

private let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/heylisten.log")

/// At launch: past 1 MB, the log moves to heylisten.log.1 (replacing the previous one) and starts over.
func rotateLog(maxBytes: Int = 1_000_000) {
    let fm = FileManager.default
    guard let size = (try? fm.attributesOfItem(atPath: logPath))?[.size] as? Int, size > maxBytes else { return }
    let old = logPath + ".1"
    try? fm.removeItem(atPath: old)
    try? fm.moveItem(atPath: logPath, toPath: old)
}

/// Appends to ~/Library/Logs/heylisten.log (NSLog output doesn't reliably reach `log show`).
func hlog(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    let path = logPath
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
