import Foundation
import os

/// Manages the Python SenseVoice ASR server process.
actor SenseVoiceServerManager {
    static let shared = SenseVoiceServerManager()

    private let logger = Logger(subsystem: "com.type4me.sensevoice", category: "ServerManager")

    private var process: Process?
    private(set) var port: Int?
    private var stdoutPipe: Pipe?

    var isRunning: Bool { process?.isRunning ?? false }

    var serverWSURL: URL? {
        guard let port else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)/ws")
    }

    var healthURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/health")
    }

    /// Start the Python SenseVoice server.
    /// - The server binary is at `Contents/MacOS/sensevoice-server` in the app bundle during development,
    ///   or we use the venv Python directly for now.
    func start() async throws {
        guard !isRunning else {
            logger.info("Server already running on port \(self.port ?? 0)")
            return
        }

        // Kill orphan sensevoice-server processes from previous app sessions.
        // Without this, stale processes hold the ModelScope lock and consume
        // resources, preventing the new server from starting.
        Self.killOrphanProcesses()

        // For development: use venv Python + server.py
        // For production: use PyInstaller binary at Bundle.main.executableURL/../sensevoice-server
        let serverScript: String
        let executable: String

        // Try PyInstaller binary first, fallback to venv Python
        let bundledBinary = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("sensevoice-server")
            .path

        if let bin = bundledBinary, FileManager.default.fileExists(atPath: bin) {
            executable = bin
            serverScript = ""  // binary mode, no script needed
        } else {
            // Development mode: find sensevoice-server directory
            let devServerDir = findDevServerDir()
            guard let dir = devServerDir else {
                throw ServerError.serverNotFound
            }
            executable = (dir as NSString).appendingPathComponent(".venv/bin/python")
            serverScript = (dir as NSString).appendingPathComponent("server.py")

            guard FileManager.default.fileExists(atPath: executable) else {
                throw ServerError.venvNotFound
            }
        }

        // Model directory: prefer bundled model, then ModelScope cache, fallback to ModelScope ID
        let bundledModel = Bundle.main.resourceURL?
            .appendingPathComponent("Models")
            .appendingPathComponent("SenseVoiceSmall")
        let modelDir: String
        if let bundled = bundledModel, FileManager.default.fileExists(atPath: bundled.path) {
            modelDir = bundled.path
            logger.info("Using bundled model at \(bundled.path)")
        } else {
            // Check ModelScope cache: if model.pt exists, use the local path directly
            // to avoid ModelScope re-downloading due to stale metadata.
            let cacheDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/modelscope/hub/models/iic/SenseVoiceSmall")
            let cachedModel = cacheDir.appendingPathComponent("model.pt")
            if FileManager.default.fileExists(atPath: cachedModel.path) {
                modelDir = cacheDir.path
                logger.info("Using ModelScope cached model at \(cacheDir.path)")
            } else {
                modelDir = "iic/SenseVoiceSmall"
                logger.info("No cached model, will download from ModelScope")
            }
        }

        // Hotwords file (optional, may not exist)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let hotwordsPath = appSupport
            .appendingPathComponent("Type4Me")
            .appendingPathComponent("hotwords.txt")
        let hotwordsFile = FileManager.default.fileExists(atPath: hotwordsPath.path) ? hotwordsPath.path : ""

        let proc = Process()
        if serverScript.isEmpty {
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = [
                "--model-dir", modelDir,
                "--port", "0",
                "--hotwords-file", hotwordsFile,
                "--beam-size", "3",
                "--context-score", "6.0",
                "--device", "auto",
                "--language", "auto",
                "--textnorm",
                "--padding", "8",
                "--chunk-size", "10",
            ]
        } else {
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = [
                serverScript,
                "--model-dir", modelDir,
                "--port", "0",
                "--hotwords-file", hotwordsFile,
                "--beam-size", "3",
                "--context-score", "6.0",
                "--device", "auto",
                "--language", "auto",
                "--textnorm",
                "--padding", "8",
                "--chunk-size", "10",
            ]
        }

        let pipe = Pipe()
        proc.standardOutput = pipe
        // Log stderr to debug file instead of discarding
        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let msg = String(data: data, encoding: .utf8) else { return }
            for line in msg.split(separator: "\n") where !line.isEmpty {
                DebugFileLogger.log("sensevoice-server: \(line)")
            }
        }
        self.stdoutPipe = pipe

        logger.info("Starting SenseVoice server: \(executable)")

        do {
            try proc.run()
        } catch {
            logger.error("Failed to start server: \(error)")
            throw ServerError.launchFailed(error)
        }
        self.process = proc

        // Read PORT:xxxxx from stdout (with timeout)
        let portResult = await readPortFromStdout(pipe: pipe, timeout: 60)
        guard let discoveredPort = portResult else {
            proc.terminate()
            self.process = nil
            throw ServerError.portDiscoveryFailed
        }
        self.port = discoveredPort
        logger.info("SenseVoice server started on port \(discoveredPort)")

        // Wait for health check
        let healthy = await waitForHealth(timeout: 30)
        if !healthy {
            logger.warning("Server started but health check not responding yet")
        }
    }

    /// Stop the server process.
    func stop() {
        guard let proc = process else { return }
        if proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        process = nil
        port = nil
        stdoutPipe = nil
        logger.info("SenseVoice server stopped")
    }

    /// Kill any sensevoice-server processes not owned by this manager instance.
    /// Called at start() to clean up orphans from previous app launches.
    nonisolated static func killOrphanProcesses() {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "sensevoice-server"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }
        let pids = output.split(separator: "\n").compactMap { Int32($0) }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for pid in pids where pid != myPID {
            kill(pid, SIGTERM)
        }
        if !pids.isEmpty {
            NSLog("[SenseVoice] Killed %d orphan sensevoice-server processes", pids.count)
        }
    }

    /// Check if the server is healthy.
    nonisolated func isHealthy() async -> Bool {
        guard let url = await healthURL else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Private

    private func findDevServerDir() -> String? {
        // Walk up from the binary location to find sensevoice-server/
        // In dev: binary is at .build/release/Type4Me, project root has sensevoice-server/
        var dir = Bundle.main.bundlePath
        for _ in 0..<5 {
            dir = (dir as NSString).deletingLastPathComponent
            let candidate = (dir as NSString).appendingPathComponent("sensevoice-server")
            if FileManager.default.fileExists(atPath: (candidate as NSString).appendingPathComponent("server.py")) {
                return candidate
            }
        }
        // Also check ~/projects/type4me/sensevoice-server
        let home = NSHomeDirectory()
        let fallback = (home as NSString)
            .appendingPathComponent("projects/type4me/sensevoice-server")
        if FileManager.default.fileExists(atPath: (fallback as NSString).appendingPathComponent("server.py")) {
            return fallback
        }
        return nil
    }

    private func readPortFromStdout(pipe: Pipe, timeout: Int) async -> Int? {
        return await withCheckedContinuation { continuation in
            let handle = pipe.fileHandleForReading
            var resolved = false

            // Read in background
            DispatchQueue.global().async {
                while true {
                    let data = handle.availableData
                    guard !data.isEmpty else { break }
                    if let output = String(data: data, encoding: .utf8) {
                        for line in output.split(separator: "\n") {
                            if line.hasPrefix("PORT:"),
                               let portNum = Int(line.dropFirst(5)) {
                                if !resolved {
                                    resolved = true
                                    continuation.resume(returning: portNum)
                                }
                                return
                            }
                        }
                    }
                }
                if !resolved {
                    resolved = true
                    continuation.resume(returning: nil)
                }
            }

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                if !resolved {
                    resolved = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func waitForHealth(timeout: Int) async -> Bool {
        for _ in 0..<timeout {
            if await isHealthy() { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    // MARK: - Errors

    enum ServerError: Error, LocalizedError {
        case serverNotFound
        case venvNotFound
        case launchFailed(Error)
        case portDiscoveryFailed

        var errorDescription: String? {
            switch self {
            case .serverNotFound:
                return L("SenseVoice 服务未找到", "SenseVoice server not found")
            case .venvNotFound:
                return L("Python 环境未配置", "Python environment not configured")
            case .launchFailed(let e):
                return L("服务启动失败: \(e.localizedDescription)", "Server launch failed: \(e.localizedDescription)")
            case .portDiscoveryFailed:
                return L("服务端口发现失败", "Server port discovery failed")
            }
        }
    }
}
