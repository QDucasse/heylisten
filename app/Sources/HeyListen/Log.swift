import Foundation

/// Appends to ~/Library/Logs/heylisten.log (NSLog output doesn't reliably reach `log show`).
func hlog(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/heylisten.log")
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
