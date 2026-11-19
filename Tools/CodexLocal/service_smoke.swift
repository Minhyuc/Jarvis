// Sandboxed app harness: bootstrap + HTTP auth guard + stop/restart/cancel.
// No login/account lookup or model request. Never prints pairing material.
import AppKit

@main
struct ServiceSmoke {
    static func main() {
        print("check launched"); fflush(stdout)
        DispatchQueue.main.async {
          print("main queue ready"); fflush(stdout)
          Task { @MainActor in
            print("task ready"); fflush(stdout)
            let manager = CodexManagedService()
            @MainActor func start() async -> Data? {
                print("start entered"); fflush(stdout)
                return await withCheckedContinuation { continuation in
                    print("calling manager"); fflush(stdout)
                    manager.start { data, error in
                        print(data == nil ? "bootstrap failed: \(error ?? "unknown")" : "bootstrap ready"); fflush(stdout)
                        continuation.resume(returning: data)
                    }
                }
            }
            func rejected(_ descriptor: Data) async -> Bool {
                guard let json = try? JSONSerialization.jsonObject(with: descriptor) as? [String: Any],
                      let port = json["port"] as? Int else { return false }
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/status")!)
                request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.timeoutInterval = 2
                let response = try? await URLSession.shared.data(for: request)
                return (response?.1 as? HTTPURLResponse)?.statusCode == 403
            }
            func closed(_ descriptor: Data) async -> Bool {
                let json = try! JSONSerialization.jsonObject(with: descriptor) as! [String: Any]
                let port = json["port"] as! Int
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/status")!)
                request.timeoutInterval = 1
                return (try? await URLSession.shared.data(for: request)) == nil
            }
            var success = true
            var previous: Data?
            for iteration in 0..<4 {
                guard let descriptor = await start(), descriptor != previous,
                      manager.matchesInstalledBuild, await rejected(descriptor) else { success = false; break }
                if iteration == 0 {
                    let contender = CodexManagedService()
                    let denied = await withCheckedContinuation { continuation in
                        contender.start { data, _ in continuation.resume(returning: data == nil) }
                    }
                    contender.stop()
                    guard denied, await rejected(descriptor) else { success = false; break }
                }
                previous = descriptor
                manager.stop()
                try? await Task.sleep(for: .seconds(2))
                guard !manager.matchesInstalledBuild, await closed(descriptor) else { success = false; break }
            }
            // Cancellation must finish the callback exactly once with no descriptor.
            var callbacks = 0
            manager.start { data, _ in callbacks += 1; if data != nil { success = false } }
            manager.stop()
            try? await Task.sleep(for: .seconds(1))
            success = success && callbacks == 1
            let result = success ? "PASS: sandboxed XPC bootstrap, build identity, auth guard, second-owner rejection, 4 stop/restart cycles, cancel" : "FAIL: managed service runtime"
            print(result)
            fflush(stdout)
            exit(success ? 0 : 1)
          }
        }
        dispatchMain()
    }
}
