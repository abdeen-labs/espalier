// The processes below a process, and their arguments, from the kernel's
// process table (`sysctl`): what stopping part of what a process started
// needs, such as a pull's fetch without the merge that follows it.

import Darwin

public enum ProcessTree {
    /// The processes whose parent is `pid`, in the kernel's order.
    public static func children(of pid: pid_t) -> [pid_t] {
        let table = parentsByProcess()
        return table.compactMap { $0.parent == pid ? $0.pid : nil }
    }

    /// The processes below `pid`: its children, theirs, and so on, each
    /// before the processes it started. `pid` itself isn't included.
    public static func descendants(of pid: pid_t) -> [pid_t] {
        let table = parentsByProcess()
        var found: [pid_t] = []
        var queue = [pid]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for entry in table where entry.parent == parent && entry.pid != parent && !found.contains(entry.pid) {
                found.append(entry.pid)
                queue.append(entry.pid)
            }
        }
        return found
    }

    /// The arguments `pid` was started with, its name first, or nil when
    /// they can't be read (the process is gone, or belongs to another user).
    public static func arguments(of pid: pid_t) -> [String]? {
        var maximumName: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var maximum: Int32 = 0
        var maximumSize = MemoryLayout<Int32>.size
        guard sysctl(&maximumName, UInt32(maximumName.count), &maximum, &maximumSize, nil, 0) == 0, maximum > 0 else {
            return nil
        }

        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(maximum))
        var size = buffer.count
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&name, UInt32(name.count), bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else {
            return nil
        }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    /// Parses `KERN_PROCARGS2`'s layout: the argument count (a 32-bit
    /// integer), the executable's path, padding, then the arguments, each
    /// ending in a zero byte (the environment follows).
    static func parseProcessArguments(_ bytes: [UInt8]) -> [String]? {
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count >= countSize else {
            return nil
        }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count >= 0 else {
            return nil
        }
        var index = countSize
        // The executable's path.
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
        // The zero bytes after it.
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }
        var arguments: [String] = []
        while arguments.count < Int(count), index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(count) ? arguments : nil
    }

    /// Every process and its parent.
    private static func parentsByProcess() -> [(pid: pid_t, parent: pid_t)] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }
        // Room for processes started between the two calls.
        size += size / 8
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        var bytes = processes.count * stride
        let result = processes.withUnsafeMutableBytes { buffer in
            sysctl(&name, UInt32(name.count), buffer.baseAddress, &bytes, nil, 0)
        }
        guard result == 0 else {
            return []
        }
        return processes.prefix(bytes / stride).map { (pid: $0.kp_proc.p_pid, parent: $0.kp_eproc.e_ppid) }
    }
}
