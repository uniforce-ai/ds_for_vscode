import Foundation

/// The Linux machine behind the frontmost VS Code Remote SSH window.
struct RemoteEndpoint: Equatable {
    let user: String
    let host: String

    var destination: String { "\(user)@\(host)" }

    static func parse(authority: String) -> RemoteEndpoint? {
        guard let marker = authority.range(of: "ssh-remote+") else { return nil }
        var token = String(authority[marker.upperBound...])
        if let slash = token.firstIndex(of: "/") {
            token = String(token[..<slash])
        }
        token = token.removingPercentEncoding ?? token
        if token.hasPrefix("{"),
           let data = token.data(using: .utf8),
           let endpoint = endpoint(from: data) {
            return endpoint
        }
        if token.allSatisfy({ $0.isHexDigit }), let data = Data(hexEncoded: token), let endpoint = endpoint(from: data) {
            return endpoint
        }
        if let at = token.lastIndex(of: "@"), at != token.startIndex, token.index(after: at) != token.endIndex {
            return RemoteEndpoint(user: String(token[..<at]), host: String(token[token.index(after: at)...]))
        }
        guard token.contains(".") else { return nil }
        return RemoteEndpoint(user: NSUserName(), host: token)
    }

    /// VS Code's current remote window, when it is an SSH host.
    static func current(storage: URL = RemoteEndpoint.vscodeStorage) -> RemoteEndpoint? {
        guard let data = try? Data(contentsOf: storage),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = root["windowsState"] as? [String: Any] else { return nil }
        let active = (windows["lastActiveWindow"] as? [String: Any])?["remoteAuthority"] as? String
        if let active, let endpoint = parse(authority: active) { return endpoint }
        let opened = windows["openedWindows"] as? [[String: Any]] ?? []
        for window in opened.reversed() {
            if let authority = window["remoteAuthority"] as? String, let endpoint = parse(authority: authority) {
                return endpoint
            }
        }
        return nil
    }

    static var vscodeStorage: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json")
    }

    private static func endpoint(from data: Data) -> RemoteEndpoint? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = object["hostName"] as? String, !host.isEmpty else { return nil }
        let user = (object["user"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        return RemoteEndpoint(user: user, host: host)
    }
}

private extension Data {
    init?(hexEncoded text: String) {
        let digits = Array(text)
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let byte = UInt8(String(digits[index...index + 1]), radix: 16) else { return nil }
            data.append(byte)
            index += 2
        }
        self = data
    }
}

/// Tails the remote Codex session log over SSH and reports turn boundaries only.
final class RemoteLightBridge {
    var onCue: ((SessionCue, Bool) -> Void)?
    var onStatus: ((String) -> Void)?

    private var process: Process?
    private var endpoint: RemoteEndpoint?
    private var output = Data()
    private var errorText = ""
    private var stopped = false
    private var sawCue = false
    private var nextAttempt = Date.distantPast
    private let outputLock = NSLock()

    func poll(now: Date = Date()) {
        guard !stopped else { return }
        let found = RemoteEndpoint.current()
        if found != endpoint {
            endpoint = found
            stopProcess()
            nextAttempt = .distantPast
            guard let found else {
                onStatus?("远端：VS Code 没有连着 Linux")
                return
            }
            AppLog.write("remote target \(found.destination)")
        }
        guard let endpoint, process?.isRunning != true, now >= nextAttempt else { return }
        start(endpoint)
    }

    func stop() {
        stopped = true
        stopProcess()
    }

    private func start(_ endpoint: RemoteEndpoint) {
        guard let scriptURL = Bundle.main.url(forResource: "remote-session-follow", withExtension: "py"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            onStatus?("远端：缺少会话跟随脚本")
            nextAttempt = Date().addingTimeInterval(30)
            return
        }
        let askpass = prepareAskpass(for: endpoint)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T",
            "-o", "ConnectTimeout=12",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "PreferredAuthentications=publickey,password",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            endpoint.destination,
            "python3", "-"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpass.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
        environment["DS_CODEX_ASKPASS_ACCOUNT"] = endpoint.destination
        process.environment = environment

        let input = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        output = Data()
        errorText = ""
        sawCue = false
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.consume(chunk)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            self?.outputLock.lock()
            self?.errorText.append(text)
            if (self?.errorText.count ?? 0) > 4000 {
                self?.errorText = String(self?.errorText.suffix(2000) ?? "")
            }
            self?.outputLock.unlock()
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.finished(process)
            }
        }
        do {
            try process.run()
        } catch {
            onStatus?("远端：无法启动 SSH")
            nextAttempt = Date().addingTimeInterval(15)
            return
        }
        self.process = process
        onStatus?("远端：正在连接 \(endpoint.destination)")
        AppLog.write("remote connect \(endpoint.destination)")
        if let data = script.data(using: .utf8) {
            input.fileHandleForWriting.write(data)
        }
        try? input.fileHandleForWriting.close()
    }

    private func consume(_ chunk: Data) {
        outputLock.lock()
        output.append(chunk)
        var lines: [Data] = []
        while let newline = output.firstIndex(of: 0x0A) {
            lines.append(Data(output[..<newline]))
            output.removeSubrange(...newline)
        }
        outputLock.unlock()
        let cues = lines.compactMap { SessionCue.cue($0) }
        guard !cues.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for cue in cues {
                let replay = !self.sawCue
                self.sawCue = true
                if replay && !cue.isFresh(now: Date()) { continue }
                self.onCue?(cue, !replay)
            }
            if let endpoint = self.endpoint {
                self.onStatus?("远端：已连接 \(endpoint.destination)")
            }
        }
    }

    private func finished(_ process: Process) {
        guard self.process === process else { return }
        self.process = nil
        outputPipeHandlersOff(process)
        outputLock.lock()
        let error = errorText
        outputLock.unlock()
        let denied = error.localizedCaseInsensitiveContains("permission denied")
            || error.localizedCaseInsensitiveContains("too many authentication")
        if denied, let endpoint {
            deletePassword(for: endpoint)
            onStatus?("远端：SSH 被拒绝，稍后会再问一次密码")
            AppLog.write("remote auth rejected")
        } else if error.localizedCaseInsensitiveContains("python3") {
            onStatus?("远端：没有 python3，无法读取会话")
        } else if endpoint != nil {
            onStatus?("远端：连接中断，正在重试")
        }
        let clipped = error.replacingOccurrences(of: "\n", with: " ")
        AppLog.write("remote exit \(process.terminationStatus) \(clipped.suffix(180))")
        nextAttempt = Date().addingTimeInterval(denied ? 20 : 4)
    }

    private func outputPipeHandlersOff(_ process: Process) {
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    private func stopProcess() {
        guard let process else { return }
        outputPipeHandlersOff(process)
        if process.isRunning { process.terminate() }
        self.process = nil
    }

    private func prepareAskpass(for endpoint: RemoteEndpoint) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ds-codex-askpass.sh")
        let script = #"""
        #!/bin/sh
        account="$DS_CODEX_ASKPASS_ACCOUNT"
        service="DS Codex SSH"
        if password=$(security find-generic-password -a "$account" -s "$service" -w 2>/dev/null); then
          printf '%s\n' "$password"
          exit 0
        fi
        password=$(osascript - "$account" <<'APPLESCRIPT'
        on run argv
          set who to item 1 of argv
          set prompt to "DS Codex SSH 需要 " & who & " 的 SSH 密码，用来同步手柄灯效。密码只保存在本机钥匙串。"
          return text returned of (display dialog prompt default answer "" with hidden answer)
        end run
        APPLESCRIPT
        ) || exit 1
        [ -n "$password" ] || exit 1
        security add-generic-password -U -a "$account" -s "$service" -w "$password" >/dev/null 2>&1 || true
        printf '%s\n' "$password"
        """#
        try? script.data(using: .utf8)?.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        _ = endpoint
        return url
    }

    private func deletePassword(for endpoint: RemoteEndpoint) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-a", endpoint.destination, "-s", "DS Codex SSH"]
        try? process.run()
        process.waitUntilExit()
    }
}
