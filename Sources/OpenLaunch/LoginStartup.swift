import Foundation

/// Controls next-login startup without stopping or duplicating the current app.
final class LoginStartup {
    static let label = "local.openlaunch.login"
    private let agentURL: URL
    private let executableURL: URL
    private let run: ([String]) throws -> String
    private let domain = "gui/\(getuid())"

    init(agentURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.openlaunch.login.plist"),
         executableURL: URL = Bundle.main.executableURL!,
         run: @escaping ([String]) throws -> String = LoginStartup.launchctl) {
        self.agentURL = agentURL; self.executableURL = executableURL; self.run = run
    }

    func isEnabled() throws -> Bool {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return false }
        let data = try Data(contentsOf: agentURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == Self.label else {
            throw failure("登录启动项格式不正确，请重新设置。")
        }
        guard plist["RunAtLoad"] as? Bool == true else { return false }
        let disabled = try run(["print-disabled", domain])
        return !disabled.split(separator: "\n").contains { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("\"\(Self.label)\" =>") && (value.hasSuffix("true") || value.hasSuffix("disabled"))
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        let oldData = try? Data(contentsOf: agentURL)
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executableURL.path, "--background"],
            "RunAtLoad": enabled,
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": ["local.openlaunch"],
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentURL, options: .atomic)
        do {
            // enable/disable persist across logins and leave an already running app alone.
            _ = try run([enabled ? "enable" : "disable", "\(domain)/\(Self.label)"])
        } catch {
            if let oldData { try oldData.write(to: agentURL, options: .atomic) }
            else { try FileManager.default.removeItem(at: agentURL) }
            throw error
        }
    }

    static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments; process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw failure("无法更新登录启动项：\(text.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return text
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "OpenLaunch.LoginStartup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func failure(_ message: String) -> NSError { Self.failure(message) }
}
