import Foundation
import DustlessKit

private let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let fixtures = here.appendingPathComponent("Fixtures")

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
}

private func findingJSON(
    tier: String, blocked: Bool, bytes: UInt64, path: String = "/tmp/x"
) -> Data {
    Data("""
    {"ruleId":"r","tier":"\(tier)","desc":"d","path":"\(path)","bytes":\(bytes),
     "mtime":0,"atime":0,"ageDays":10,"verified":\(!blocked),"blocked":\(blocked),"note":""}
    """.utf8)
}

func finding(
    tier: String, blocked: Bool, bytes: UInt64, path: String = "/tmp/x"
) throws -> Finding {
    try JSONDecoder().decode(Finding.self, from: findingJSON(tier: tier, blocked: blocked, bytes: bytes, path: path))
}

typealias MemProcess = DustlessKit.ProcessInfo

func process(command: String, mem: UInt64 = 1, pid: Int = 1) throws -> MemProcess {
    let executable = MemProcess.executablePath(in: command)
    let name = executable.split(separator: "/").last.map(String.init) ?? executable
    return try JSONDecoder().decode(MemProcess.self, from: Data("""
    {"pid":\(pid),"ppid":0,"name":"\(name)","command":"\(command)","cpu":0,"mem":\(mem),
     "owner":"me","root":false,"category":"other"}
    """.utf8))
}
