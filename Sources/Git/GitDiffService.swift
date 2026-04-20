import Foundation

// MARK: - Models

enum DiffLineType: Equatable, Sendable {
    case added
    case removed
    case context
}

struct DiffLine: Equatable, Sendable {
    let type: DiffLineType
    let content: String
    /// Line number in the old file (nil for added lines).
    let oldLineNumber: Int?
    /// Line number in the new file (nil for removed lines).
    let newLineNumber: Int?
}

struct DiffHunk: Equatable, Sendable {
    let header: String
    let lines: [DiffLine]
}

struct DiffFile: Equatable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let additions: Int
    let deletions: Int
    let hunks: [DiffHunk]
}

struct SubmoduleDiff: Equatable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let files: [DiffFile]
}

struct GitDiffResult: Equatable, Sendable {
    let files: [DiffFile]
    let submodules: [SubmoduleDiff]

    var isEmpty: Bool { files.isEmpty && submodules.isEmpty }
    var totalFiles: Int { files.count + submodules.reduce(0) { $0 + $1.files.count } }
    var totalAdditions: Int {
        files.reduce(0) { $0 + $1.additions } +
        submodules.flatMap(\.files).reduce(0) { $0 + $1.additions }
    }
    var totalDeletions: Int {
        files.reduce(0) { $0 + $1.deletions } +
        submodules.flatMap(\.files).reduce(0) { $0 + $1.deletions }
    }
}

// MARK: - Service

enum GitDiffService {

    static func fetchDiff(in directory: String) async -> GitDiffResult {
        async let mainDiff = runGitDiff(in: directory)
        async let subDiffs = fetchSubmoduleDiffs(in: directory)
        return GitDiffResult(files: await mainDiff, submodules: await subDiffs)
    }

    // MARK: - Private

    private static func runGitDiff(in directory: String) async -> [DiffFile] {
        // Try HEAD first (staged + unstaged), fall back to index-only for new repos
        var output = await runProcess("git", arguments: ["diff", "--no-color", "HEAD"], in: directory)
        if output.isEmpty {
            output = await runProcess("git", arguments: ["diff", "--no-color"], in: directory)
        }
        if output.isEmpty {
            output = await runProcess("git", arguments: ["diff", "--cached", "--no-color"], in: directory)
        }
        return parseDiff(output)
    }

    private static func fetchSubmoduleDiffs(in directory: String) async -> [SubmoduleDiff] {
        let nestedRepoPaths = await findNestedGitRepos(in: directory)
        guard !nestedRepoPaths.isEmpty else { return [] }

        return await withTaskGroup(of: SubmoduleDiff?.self) { group in
            for subPath in nestedRepoPaths {
                group.addTask {
                    let fullPath = (directory as NSString).appendingPathComponent(subPath)
                    let files = await runGitDiff(in: fullPath)
                    guard !files.isEmpty else { return nil }
                    return SubmoduleDiff(path: subPath, files: files)
                }
            }
            var results: [SubmoduleDiff] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results.sorted { $0.path < $1.path }
        }
    }

    /// Finds all nested git repositories using `find` to locate `.git` markers
    /// (directories for regular repos, files for submodules) up to 3 levels deep.
    private static func findNestedGitRepos(in directory: String) async -> [String] {
        let output = await runProcess(
            "/usr/bin/find",
            arguments: [
                ".", "-maxdepth", "4", "-name", ".git",
                "-not", "-path", "./.git",
                "-not", "-path", "*/node_modules/*",
                "-not", "-path", "*/build/*",
                "-not", "-path", "*/.build/*"
            ],
            in: directory,
            useEnv: false
        )

        return output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { gitPath -> String? in
                // "./subdir/.git" → "subdir"
                var parent = (gitPath as NSString).deletingLastPathComponent
                if parent.hasPrefix("./") {
                    parent = String(parent.dropFirst(2))
                }
                guard !parent.isEmpty, parent != "." else { return nil }
                return parent
            }
            .sorted()
    }

    // MARK: - Diff Parser

    private static func parseDiff(_ raw: String) -> [DiffFile] {
        let lines = raw.components(separatedBy: "\n")
        var files: [DiffFile] = []
        var index = 0

        while index < lines.count {
            guard lines[index].hasPrefix("diff --git") else {
                index += 1
                continue
            }

            let filePath = parseFilePath(from: lines[index])
            index += 1

            // Skip diff metadata lines (index, ---, +++)
            while index < lines.count &&
                  !lines[index].hasPrefix("@@") &&
                  !lines[index].hasPrefix("diff --git") {
                index += 1
            }

            // Parse hunks
            var hunks: [DiffHunk] = []
            while index < lines.count && !lines[index].hasPrefix("diff --git") {
                if lines[index].hasPrefix("@@") {
                    let (hunk, nextIndex) = parseHunk(lines: lines, startIndex: index)
                    hunks.append(hunk)
                    index = nextIndex
                } else {
                    index += 1
                }
            }

            let additions = hunks.flatMap(\.lines).filter { $0.type == .added }.count
            let deletions = hunks.flatMap(\.lines).filter { $0.type == .removed }.count
            files.append(DiffFile(path: filePath, additions: additions, deletions: deletions, hunks: hunks))
        }

        return files
    }

    private static func parseFilePath(from diffLine: String) -> String {
        // "diff --git a/path/to/file b/path/to/file"
        let parts = diffLine.components(separatedBy: " b/")
        if let last = parts.last {
            return last
        }
        return diffLine
    }

    private static func parseHunk(lines: [String], startIndex: Int) -> (DiffHunk, Int) {
        let header = lines[startIndex]
        var hunkLines: [DiffLine] = []
        var index = startIndex + 1

        // Parse line numbers from "@@ -oldStart,oldLen +newStart,newLen @@"
        let (startOld, startNew) = parseHunkHeader(header)
        var oldLine = startOld
        var newLine = startNew

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git") || line.hasPrefix("@@") {
                break
            }

            if line.hasPrefix("+") {
                hunkLines.append(DiffLine(type: .added, content: String(line.dropFirst()), oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                hunkLines.append(DiffLine(type: .removed, content: String(line.dropFirst()), oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
            } else if line.hasPrefix(" ") || line.isEmpty {
                let content = line.isEmpty ? "" : String(line.dropFirst())
                hunkLines.append(DiffLine(type: .context, content: content, oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1
                newLine += 1
            } else {
                hunkLines.append(DiffLine(type: .context, content: line, oldLineNumber: nil, newLineNumber: nil))
            }
            index += 1
        }

        return (DiffHunk(header: header, lines: hunkLines), index)
    }

    private static func parseHunkHeader(_ header: String) -> (oldStart: Int, newStart: Int) {
        // "@@ -46,15 +46,20 @@ def get_board_state_32(self):"
        let scanner = Scanner(string: header)
        _ = scanner.scanString("@@")
        _ = scanner.scanString("-")
        let oldStart = scanner.scanInt() ?? 1
        // Skip old length
        if scanner.scanString(",") != nil { _ = scanner.scanInt() }
        _ = scanner.scanString("+")
        let newStart = scanner.scanInt() ?? 1
        return (oldStart, newStart)
    }

    // MARK: - Process Runner

    private static let processTimeout: TimeInterval = 30

    private static func runProcess(
        _ executable: String,
        arguments: [String],
        in directory: String,
        useEnv: Bool = true
    ) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                if useEnv {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = [executable] + arguments
                } else {
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                }
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "")
                    return
                }

                // Kill the process if it exceeds the timeout.
                let timeoutWork = DispatchWorkItem { [weak process] in
                    guard let process, process.isRunning else { return }
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + processTimeout,
                    execute: timeoutWork
                )

                // Read ALL data BEFORE waitUntilExit to avoid pipe buffer deadlock.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeoutWork.cancel()

                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }
        }
    }
}
