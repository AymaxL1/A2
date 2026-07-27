// PROTOTYPE — S2 capability 纵切 spike。抛弃式代码，不进产品。见同目录 README.md。
// 日志助手：所有 print 后立即 fflush（stdout 重定向到文件时为块缓冲，不 flush 会看不到实时日志）。
import Foundation

/// 每次新建 formatter，避免跨线程共享 ISO8601DateFormatter 的线程安全隐患（spike 调用量小，代价可忽略）。
func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

/// 串行化日志，避免多线程 print 交错；每行后 fflush。
private let s2logQueue = DispatchQueue(label: "s2.log")

func s2log(_ msg: String) {
    let line = "[S2Host \(isoNow())] \(msg)"
    s2logQueue.sync {
        print(line)
        fflush(stdout)
    }
}
