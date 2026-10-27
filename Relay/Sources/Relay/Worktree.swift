import Foundation

/// Git worktrees for parallel Claude Code cards: each card gets its own checkout and `relay/<name>` branch.
enum Worktree {
    struct Failure: Error { let message: String }

    static let root = NSHomeDirectory() + "/Library/Application Support/Relay/worktrees"

    static func create(from folder: String) -> Result<String, Failure> {
        guard let top = git(["-C", folder, "rev-parse", "--show-toplevel"]).output, !top.isEmpty else {
            return .failure(Failure(message: "\(Connector.shortPath(folder)) isn't a git repository, so it can't have a worktree."))
        }
        let repo = URL(fileURLWithPath: top).lastPathComponent
        let name = "\(repo)-" + String(UUID().uuidString.prefix(6)).lowercased()
        let path = "\(root)/\(name)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let result = git(["-C", top, "worktree", "add", "-b", "relay/\(name)", path])
        guard result.status == 0 else {
            return .failure(Failure(message: "Couldn't create a worktree: \(result.error ?? "git failed")"))
        }
        return .success(path)
    }

    /// The branch checked out in a folder, for card subtitles.
    static func branch(in folder: String) -> String? {
        guard folder.hasPrefix(root) else { return nil }
        return git(["-C", folder, "branch", "--show-current"]).output
    }

    private static func git(_ args: [String]) -> (status: Int32, output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, nil, error.localizedDescription) }
        process.waitUntilExit()
        let text = { (pipe: Pipe) in
            String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (process.terminationStatus, text(out), text(err))
    }
}
