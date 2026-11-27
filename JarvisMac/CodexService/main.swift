import Foundation

final class Service: NSObject, NSXPCListenerDelegate, JARVISCodexServiceProtocol {
    private let queue = DispatchQueue(label: "jarvis.codex.service")
    private var process: Process?
    private var input: Pipe?
    private var descriptor: Data?
    private var owner: NSXPCConnection?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // This embedded service is private to its containing app. Additionally
        // pin the peer to the exact current main app signature, never bundle ID alone.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard connection.effectiveUserIdentifier == getuid(),
              let requirement = try? CodexServiceIdentity.requirement(for: app) else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: JARVISCodexServiceProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.queue.async { [weak self] in
                guard let self, self.owner === connection else { return }
                self.shutdown(); self.owner = nil
            }
        }
        // A second window must never evict another window's active request or
        // cause competing automatic repair loops. Ownership ends on invalidation.
        let accepted = queue.sync { () -> Bool in
            guard owner == nil else { return false }
            shutdown(); owner = connection; return true
        }
        guard accepted else { return false }
        connection.resume()
        return true
    }

    func start(withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async { [self] in
            if let process, process.isRunning, let descriptor { reply(descriptor, nil); return }
            shutdown()
            // Personal installation: Python is an explicit local dependency.
            // Never search cwd/PATH, download a runtime, or accept an input executable.
            guard let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
                  let script = Bundle.main.url(forResource: "jarvis_codex_local", withExtension: "py") else {
                reply(nil, "Python 3 또는 앱에 포함된 보조 프로그램을 찾지 못했습니다."); return
            }
            let child = Process(), stdin = Pipe(), stdout = Pipe()
            child.executableURL = URL(fileURLWithPath: python)
            child.arguments = ["-E", "-s", "-B", "-u", script.path, "--managed"]
            child.environment = ["HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
            child.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            if let appBundle = Bundle(url: Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()),
               (appBundle.bundleIdentifier == "com.minhyuc.jarvis.mac" || appBundle.object(forInfoDictionaryKey: "JARVISPortable") as? Bool == true || appBundle.object(forInfoDictionaryKey: "JARVISPortable") as? String == "YES") {
                let root = URL(fileURLWithPath: "/Volumes/JARVIS/Jarvis")
                guard appBundle.bundleURL.path.hasPrefix(root.path + "/"),
                      (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == "8B1F8F32-6526-49B0-8C21-9C472EB5D8E8" else {
                    reply(nil, "JARVIS USB 저장 공간을 확인하지 못했습니다."); return
                }
                let temporary = root.appendingPathComponent("Data/Temporary")
                do { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                catch { reply(nil, "USB 임시 저장 공간을 열지 못했습니다."); return }
                child.environment?["JARVIS_STORAGE_ROOT"] = root.path
                child.environment?["TMPDIR"] = temporary.path
                child.currentDirectoryURL = temporary
            }
            child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] ended in
                self?.queue.async { [weak self] in
                    guard let self, self.process === ended else { return }
                    self.descriptor = nil; self.input = nil; self.process = nil
                    self.owner?.invalidate(); self.owner = nil
                }
            }
            do { try child.run() } catch { reply(nil, "보조 프로세스를 실행하지 못했습니다."); return }
            process = child; input = stdin
            // Bootstrap is bounded and never written to disk or logs.
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 20)
            timer.setEventHandler { if child.isRunning { child.terminate() } }
            timer.resume()
            var data = Data()
            while data.count <= 4096 {
                guard let next = try? stdout.fileHandleForReading.read(upToCount: 1), !next.isEmpty else { break }
                if next.first == 10 { break }
                data.append(next)
            }
            timer.cancel()
            guard child.isRunning, data.count <= 4096,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["format", "port", "sessionID", "token"] else {
                shutdown(); reply(nil, "서비스 준비를 확인하지 못했습니다. Python·Codex 설치와 앱 서명을 확인하세요."); return
            }
            descriptor = data
            reply(data, nil)
        }
    }
    func stop(withReply reply: @escaping () -> Void) {
        queue.async { [self] in shutdown(); reply() }
    }
    private func shutdown() {
        // EOF triggers Python's bounded cleanup of both owned Codex backends.
        try? input?.fileHandleForWriting.close(); input = nil; descriptor = nil
        if let child = process {
            let deadline = Date().addingTimeInterval(5)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if child.isRunning { child.terminate() }
        }
        process = nil
    }
}

let service = Service()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
