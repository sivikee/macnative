import Foundation

enum SystemCheck {
    static var isAppleSilicon: Bool {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return machine.hasPrefix("arm64")
    }

    /// Wine builds are x86_64, so Apple Silicon Macs need Rosetta 2.
    static var isRosettaInstalled: Bool {
        guard isAppleSilicon else { return true }
        return FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    /// Installs Rosetta 2 via Apple's `softwareupdate`, asking for an admin password through
    /// the standard macOS prompt. This is the only thing MacNative ever installs outside its folder.
    static func installRosetta() async throws {
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        try await Shell.run("/usr/bin/osascript", ["-e", script])
    }
}
