// Everyday FileManager work: copy, move, probe, list — the methods
// issue #7 found generated-but-unreachable behind the sentinel.
import Foundation

let fm = FileManager.default
let dir = NSTemporaryDirectory() + "_ssp_fm_probe"
try? fm.removeItem(atPath: dir)
try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
try "alpha".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
try fm.copyItem(atPath: dir + "/a.txt", toPath: dir + "/b.txt")
print(fm.contentsEqual(atPath: dir + "/a.txt", andPath: dir + "/b.txt"))
try fm.moveItem(atPath: dir + "/b.txt", toPath: dir + "/c.txt")
print(try fm.contentsOfDirectory(atPath: dir).sorted())
print(fm.isReadableFile(atPath: dir + "/c.txt"))
if let bytes = fm.contents(atPath: dir + "/c.txt") {
    print(bytes.count)
}
try fm.removeItem(atPath: dir)
print(fm.fileExists(atPath: dir))
