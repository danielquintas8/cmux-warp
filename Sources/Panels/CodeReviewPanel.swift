import Foundation
import Combine

/// A panel that displays git diffs for the current repository and its submodules.
@MainActor
final class CodeReviewPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .codeReview

    /// Absolute path to the git working directory.
    @Published private(set) var gitDirectory: String

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Parsed diff result from the git repository.
    @Published private(set) var diffResult: GitDiffResult?

    /// Currently selected file path in the file list.
    @Published var selectedFilePath: String?

    /// Whether a diff refresh is in progress.
    @Published private(set) var isLoading: Bool = false

    /// Title shown in the tab bar.
    @Published private(set) var displayTitle: String = "Code Review"

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "arrow.left.arrow.right" }

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    private var isClosed = false
    private var directoryUpdateTask: Task<Void, Never>?
    private static let directoryDebounceDelay: UInt64 = 800_000_000 // 800ms

    // MARK: - Init

    init(workspaceId: UUID, gitDirectory: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.gitDirectory = gitDirectory

        Task { await refresh() }
    }

    // MARK: - Panel protocol

    func focus() {}

    func unfocus() {}

    func close() {
        isClosed = true
        directoryUpdateTask?.cancel()
        directoryUpdateTask = nil
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Public

    func refresh() async {
        guard !isClosed else { return }
        isLoading = true
        let result = await GitDiffService.fetchDiff(in: gitDirectory)
        guard !isClosed else { return }
        diffResult = result
        isLoading = false
    }

    func selectFile(_ path: String) {
        selectedFilePath = path
    }

    /// Update the git directory and refresh diffs if it changed.
    /// Debounced to avoid rapid refreshes during tab completion.
    func updateDirectory(_ newDirectory: String) {
        let trimmed = newDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != gitDirectory else { return }

        directoryUpdateTask?.cancel()
        directoryUpdateTask = Task {
            try? await Task.sleep(nanoseconds: Self.directoryDebounceDelay)
            guard !Task.isCancelled, !isClosed else { return }
            gitDirectory = trimmed
            selectedFilePath = nil
            await refresh()
        }
    }

    /// Returns the DiffFile matching the current selection, searching both
    /// top-level files and submodule files.
    var selectedDiffFile: DiffFile? {
        guard let path = selectedFilePath, let result = diffResult else { return nil }
        if let file = result.files.first(where: { $0.path == path }) {
            return file
        }
        for submodule in result.submodules {
            if let file = submodule.files.first(where: { $0.path == path }) {
                return file
            }
        }
        return nil
    }
}
