// AppFiles.swift
// The only code that writes Find's OWN files: logs, themes, journals, temporary work files.
// Every write and every removal is checked to be inside one of Find's own folders,
// after resolving symlinks, so it can never touch user files.

#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

final class AppFiles {
    static var shared: AppFiles!

    /// ~/Library/Application Support/PhotoLab
    let supportDir: String
    /// ~/Library/Caches/PhotoLab
    let cachesDir: String
    /// ~/Library/Logs/PhotoLab
    let logsDir: String

    private var realRoots: [String] = []

    init(supportDir: String, cachesDir: String, logsDir: String) {
        self.supportDir = supportDir
        self.cachesDir = cachesDir
        self.logsDir = logsDir
        for d in [supportDir, cachesDir, logsDir] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: nil)
        }
        realRoots = [supportDir, cachesDir, logsDir].map { Sys.realPath($0) ?? $0 }
    }

    var themesDir: String { return Paths.join(supportDir, "Themes") }
    var journalsDir: String { return Paths.join(supportDir, "Journals") }
    var tempDir: String { return Paths.join(cachesDir, "tmp") }

    /// True only if `path` (resolving symlinks in its parent folders) is inside one of Find's folders.
    func isOwned(_ path: String) -> Bool {
        let parent = Paths.parent(path)
        guard let realParent = Sys.realPath(parent) else { return false }
        let full = Paths.join(realParent, Paths.lastComponent(path))
        for root in realRoots where Paths.isInside(full, root: root) && full != root {
            return true
        }
        return false
    }

    func makeDir(_ path: String) -> Bool {
        let parent = Paths.parent(path)
        if !Sys.exists(parent) { _ = makeDir(parent) }
        guard isOwned(path) || realRoots.contains(Sys.realPath(path) ?? "") else { return false }
        if Sys.exists(path) { return true }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: nil)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func writeText(_ text: String, to path: String) -> Bool {
        // The folder first (makeDir refuses anything outside Find's folders), then the ownership check,
        // which needs the folder to exist (0.17: saving into a new subfolder was refused - SESS-03).
        _ = makeDir(Paths.parent(path))
        guard isOwned(path) else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        return FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
    }

    /// Write binary data atomically (temporary file, then replaced in one step). Find's own folders only.
    @discardableResult
    func writeData(_ data: Data, to path: String) -> Bool {
        _ = makeDir(Paths.parent(path))
        guard isOwned(path) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func appendText(_ text: String, to path: String) -> Bool {
        _ = makeDir(Paths.parent(path))
        guard isOwned(path) else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        if !Sys.exists(path) {
            _ = makeDir(Paths.parent(path))
            return FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return false }
        h.seekToEndOfFile()
        h.write(data)
        h.closeFile()
        return true
    }

    /// Remove one of Find's own files or folders. Refuses anything outside Find's folders.
    @discardableResult
    func removeOwned(_ path: String) -> Bool {
        guard isOwned(path) else {
            Log.shared?.warn("E-GUARD-1 refused to remove a path outside PhotoLab's folders: \(path)")
            return false
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    /// Test support: set a file's modification/creation dates. Only inside Find's own folders.
    @discardableResult
    func setDates(_ path: String, modified: Date) -> Bool {
        guard isOwned(path) else { return false }
        let secs = Int(modified.timeIntervalSince1970)
        var times = [timeval(tv_sec: secs, tv_usec: 0), timeval(tv_sec: secs, tv_usec: 0)]
        return utimes(path, &times) == 0
    }

    /// Test support: set POSIX permissions. Only inside Find's own folders.
    @discardableResult
    func setPermissions(_ path: String, _ mode: Int) -> Bool {
        guard isOwned(path) else { return false }
        return chmod(path, mode_t(mode)) == 0
    }

    /// Test support: rename inside Find's own folders.
    @discardableResult
    func moveOwned(_ from: String, _ to: String) -> Bool {
        guard isOwned(from), isOwned(to) else { return false }
        return (try? FileManager.default.moveItem(atPath: from, toPath: to)) != nil
    }

    /// Test support: create a symbolic link inside Find's own folders.
    @discardableResult
    func makeSymlink(_ path: String, to target: String) -> Bool {
        guard isOwned(path) else { return false }
        return (try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)) != nil
    }

    func list(_ dir: String) -> [String] {
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    }

    /// Delete everything in the temporary folder (called at launch and quit).
    func clearTemp() {
        for n in list(tempDir) { removeOwned(Paths.join(tempDir, n)) }
    }
}
