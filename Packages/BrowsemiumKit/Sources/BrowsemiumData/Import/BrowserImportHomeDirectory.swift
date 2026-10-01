import Darwin
import Foundation

/// Browser sources are outside this app's sandbox container. This resolves a
/// path hint only; it grants no access. Import still requires the user's
/// security-scoped folder grant before any source files are read.
enum BrowserImportHomeDirectory {
    static let current = resolve(accountHome: accountHome(), processHome: FileManager.default.homeDirectoryForCurrentUser)

    static func resolve(accountHome: URL?, processHome: URL) -> URL {
        accountHome ?? processHome
    }

    private static func accountHome() -> URL? {
        var size = 16 * 1024
        while size <= 64 * 1024 {
            var bytes = [CChar](repeating: 0, count: size)
            var status: Int32 = 0
            let home = bytes.withUnsafeMutableBufferPointer { buffer -> URL? in
                var account = passwd()
                var result: UnsafeMutablePointer<passwd>?
                status = getpwuid_r(getuid(), &account, buffer.baseAddress, buffer.count, &result)
                guard status == 0, result != nil, let directory = account.pw_dir else { return nil }
                let path = String(cString: directory)
                guard path.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            if status != ERANGE { return home }
            size *= 2
        }
        return nil
    }
}
