import Darwin
import Foundation

/// Minimal Unix-domain-socket client used by the cmux app and the cmux-digest
/// sidecar to talk over the v1 line protocol or the v2 JSON-RPC protocol.
///
/// The CLI ships a separate, more feature-rich `SocketClient` in `CLI/cmux.swift`
/// that also handles relay-over-TCP authentication; this client is intentionally
/// stripped down to the parent ↔ child IPC use case (Unix socket only).
struct CmuxSocketError: Error, CustomStringConvertible, LocalizedError {
    let message: String
    var description: String { message }
    var errorDescription: String? { message }
}

final class CmuxSocketClient {
    private let path: String
    private var fd: Int32 = -1
    private static let defaultTimeoutSeconds: TimeInterval = 15.0
    private static let multilineIdleTimeoutSeconds: TimeInterval = 0.12

    init(path: String) {
        self.path = path
    }

    deinit {
        close()
    }

    var socketPath: String { path }

    var isConnected: Bool { fd >= 0 }

    func connect() throws {
        if fd >= 0 { return }

        var st = stat()
        guard stat(path, &st) == 0 else {
            throw CmuxSocketError(message: "Socket not found at \(path)")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw CmuxSocketError(message: "Path exists at \(path) but is not a Unix socket")
        }
        guard st.st_uid == getuid() else {
            throw CmuxSocketError(message: "Socket at \(path) not owned by current user — refusing to connect")
        }

        let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard newFD >= 0 else {
            throw CmuxSocketError(message: "Failed to create socket (errno \(errno))")
        }
        fd = newFD

        do {
            try configureSendTimeout(Self.defaultTimeoutSeconds)
            try disableSigPipe()
        } catch {
            close()
            throw error
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, cstr, maxLen - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let connectErrno = errno
            close()
            throw CmuxSocketError(
                message: "Failed to connect to \(path) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
            )
        }
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Send a v1 line command (e.g. `set_status digest "..." --workspace=<id>`)
    /// and return the response with the trailing newline stripped. Responses
    /// follow cmux's v1 contract: `OK [data]` on success, `ERROR: <message>` on failure.
    @discardableResult
    func send(command: String) throws -> String {
        guard fd >= 0 else {
            throw CmuxSocketError(message: "Not connected to \(path)")
        }

        let payload = command.hasSuffix("\n") ? command : command + "\n"
        try writeAll(Data(payload.utf8))

        var data = Data()
        var sawNewline = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let timeout = sawNewline ? Self.multilineIdleTimeoutSeconds : Self.defaultTimeoutSeconds
            guard try waitForReadable(timeout) else {
                if sawNewline { break }
                throw CmuxSocketError(message: "Command timed out")
            }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw CmuxSocketError(message: "Socket read error (errno \(errno))")
            }
            if count == 0 { break }
            if !sawNewline,
               buffer.prefix(count).contains(UInt8(0x0A)) {
                sawNewline = true
            }
            data.append(buffer, count: count)
        }

        guard var response = String(data: data, encoding: .utf8) else {
            throw CmuxSocketError(message: "Invalid UTF-8 in response")
        }
        if response.hasSuffix("\n") {
            response.removeLast()
        }
        return response
    }

    /// Send a v2 JSON-RPC request and return the parsed `result` payload.
    func sendV2(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw CmuxSocketError(message: "Failed to encode v2 request for \(method)")
        }
        let data = try JSONSerialization.data(withJSONObject: request, options: [])
        guard let line = String(data: data, encoding: .utf8) else {
            throw CmuxSocketError(message: "Failed to encode v2 request for \(method)")
        }

        let raw = try send(command: line)
        if raw.hasPrefix("ERROR:") {
            throw CmuxSocketError(message: raw)
        }
        guard let responseData = raw.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw CmuxSocketError(message: "Invalid v2 response: \(raw)")
        }
        if let ok = response["ok"] as? Bool, ok {
            return (response["result"] as? [String: Any]) ?? [:]
        }
        if let error = response["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? "error"
            let message = (error["message"] as? String) ?? "Unknown v2 error"
            throw CmuxSocketError(message: "\(code): \(message)")
        }
        throw CmuxSocketError(message: "v2 request failed: \(method)")
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    let code = errno
                    close()
                    if code == EAGAIN || code == EWOULDBLOCK || code == ETIMEDOUT {
                        throw CmuxSocketError(message: "Command timed out while writing")
                    }
                    throw CmuxSocketError(message: "Failed to write to socket (errno \(code))")
                }
                if written == 0 {
                    close()
                    throw CmuxSocketError(message: "Socket closed during write")
                }
                offset += written
            }
        }
    }

    private func waitForReadable(_ timeout: TimeInterval) throws -> Bool {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = max(deadline.timeIntervalSinceNow, 0)
            let timeoutMilliseconds = Int32(min(max(remaining * 1_000, 1), Double(Int32.max)))
            let result = Darwin.poll(&pollFD, 1, timeoutMilliseconds)
            if result > 0 {
                return true
            }
            if result == 0 {
                return false
            }
            if errno == EINTR {
                if remaining <= 0 { return false }
                continue
            }
            throw CmuxSocketError(message: "Socket poll error (errno \(errno))")
        }
    }

    private func configureSendTimeout(_ timeout: TimeInterval) throws {
        var tv = Self.timeval(for: timeout)
        let result = withUnsafePointer(to: &tv) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        guard result == 0 else {
            throw CmuxSocketError(message: "Failed to set socket send timeout")
        }
    }

    private func disableSigPipe() throws {
#if os(macOS)
        var on: Int32 = 1
        let result = withUnsafePointer(to: &on) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ptr, socklen_t(MemoryLayout<Int32>.size))
        }
        guard result == 0 else {
            throw CmuxSocketError(message: "Failed to disable SIGPIPE on socket")
        }
#endif
    }

    private static func timeval(for seconds: TimeInterval) -> Darwin.timeval {
        let clamped = max(seconds, 0.01)
        let whole = floor(clamped)
        let frac = min(max(Int((clamped - whole) * 1_000_000), 0), 999_999)
        return Darwin.timeval(tv_sec: Int(whole), tv_usec: __darwin_suseconds_t(frac))
    }
}
