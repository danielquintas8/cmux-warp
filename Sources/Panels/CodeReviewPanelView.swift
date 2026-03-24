import AppKit
import SwiftUI

/// SwiftUI view that renders a CodeReviewPanel with file list and diff viewer.
struct CodeReviewPanelView: View {
    @ObservedObject var panel: CodeReviewPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @State private var showFileList: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let diffResult = panel.diffResult {
                if diffResult.isEmpty {
                    emptyStateView
                } else {
                    diffContentView(diffResult)
                }
            } else if panel.isLoading {
                loadingView
            } else {
                emptyStateView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onRequestPanelFocus()
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Main Content

    private func diffContentView(_ result: GitDiffResult) -> some View {
        HSplitView {
            if showFileList {
                fileListView(result)
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 350)
            }

            diffDetailView
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - File List

    private func fileListView(_ result: GitDiffResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView(result)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !result.files.isEmpty {
                        ForEach(result.files) { file in
                            fileRow(file, prefix: nil)
                        }
                    }

                    ForEach(result.submodules) { submodule in
                        submoduleSection(submodule)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(fileListBackground)
    }

    private func headerView(_ result: GitDiffResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Code Review")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(result.totalFiles) file\(result.totalFiles == 1 ? "" : "s") changed")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showFileList.toggle()
                    }
                }) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 11))
                        .foregroundColor(showFileList ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(showFileList ? "Hide file navigation" : "Show file navigation")

                if panel.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Button(action: {
                        Task { await panel.refresh() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh diffs")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func fileRow(_ file: DiffFile, prefix: String?) -> some View {
        let fileId = prefix.map { "\($0)/\(file.path)" } ?? file.path
        let isSelected = panel.selectedFilePath == file.path
        return Button(action: {
            if isSelected {
                panel.selectedFilePath = nil  // Deselect → show all
            } else {
                panel.selectFile(file.path)   // Select → show only this file
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text(file.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                HStack(spacing: 3) {
                    if file.additions > 0 {
                        Text("+\(file.additions)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    if file.deletions > 0 {
                        Text("-\(file.deletions)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.red)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isSelected ? selectedRowBackground : Color.clear)
        }
        .buttonStyle(.plain)
        .id(fileId)
    }

    private func submoduleSection(_ submodule: SubmoduleDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(submodule.path)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            ForEach(submodule.files) { file in
                fileRow(file, prefix: submodule.path)
            }
        }
    }

    // MARK: - Diff Detail

    private var diffDetailView: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if !showFileList {
                    diffSummaryBar
                }

                if let result = panel.diffResult, !result.isEmpty {
                    let cardWidth = max(0, geo.size.width - 32)
                    let filesToShow = visibleFiles(from: result)
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(filesToShow.enumerated()), id: \.offset) { _, entry in
                                diffCard(entry.file, codeAreaWidth: cardWidth, submodulePath: entry.submodulePath)
                            }
                        }
                        .padding(16)
                    }
                    .id(panel.selectedFilePath ?? "__all__")
                } else {
                    emptyStateView
                }
            }
        }
    }

    private struct DiffFileEntry {
        let file: DiffFile
        let submodulePath: String?
    }

    /// When a file is selected in the sidebar, show only that file. Otherwise show all.
    private func visibleFiles(from result: GitDiffResult) -> [DiffFileEntry] {
        if let selected = panel.selectedFilePath {
            // Check top-level files
            if let file = result.files.first(where: { $0.path == selected }) {
                return [DiffFileEntry(file: file, submodulePath: nil)]
            }
            // Check submodule files
            for sub in result.submodules {
                if let file = sub.files.first(where: { $0.path == selected }) {
                    return [DiffFileEntry(file: file, submodulePath: sub.path)]
                }
            }
        }
        // No selection — show all files
        var entries: [DiffFileEntry] = result.files.map { DiffFileEntry(file: $0, submodulePath: nil) }
        for sub in result.submodules {
            entries += sub.files.map { DiffFileEntry(file: $0, submodulePath: sub.path) }
        }
        return entries
    }

    private var diffSummaryBar: some View {
        HStack(spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFileList.toggle()
                }
            }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Show file navigation")

            Text("Code Review")
                .font(.system(size: 12, weight: .semibold))

            if let result = panel.diffResult {
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.system(size: 9))
                    Text("\(result.totalFiles)")
                    Text("·")
                    Text("+\(result.totalAdditions)")
                        .foregroundColor(.green)
                    Text("-\(result.totalDeletions)")
                        .foregroundColor(.red)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            }

            Spacer()

            if panel.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            } else {
                Button(action: {
                    Task { await panel.refresh() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Refresh diffs")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(cardHeaderBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Advance width of a single character in the diff font (12pt monospaced).
    private static let monoCharWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let sample: NSString = "M"
        return sample.size(withAttributes: [.font: font]).width
    }()

    /// Width needed to display the longest line without clipping.
    private func estimatedContentWidth(for file: DiffFile) -> CGFloat {
        let maxChars = file.hunks
            .flatMap(\.lines)
            .map(\.content.count)
            .max() ?? 0
        // gutter (72) + gutter trailing padding (4) + characters + trailing buffer
        return CGFloat(maxChars) * Self.monoCharWidth + gutterWidth + 4 + 8
    }

    private func diffCard(_ file: DiffFile, codeAreaWidth: CGFloat, submodulePath: String? = nil) -> some View {
        let contentWidth = max(codeAreaWidth, estimatedContentWidth(for: file))

        return VStack(alignment: .leading, spacing: 0) {
            diffFileHeader(file, submodulePath: submodulePath)

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                        hunkView(hunk, minWidth: contentWidth)
                    }
                }
                .frame(minWidth: contentWidth, alignment: .leading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(cardBorderColor, lineWidth: 1)
        )
    }

    private func diffFileHeader(_ file: DiffFile, submodulePath: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)

            if let submodulePath {
                Text(submodulePath)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text("/")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))
            }

            Text(file.path)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
            HStack(spacing: 2) {
                Text("+\(file.additions)")
                    .foregroundColor(.green)
                Text("·")
                    .foregroundColor(.secondary)
                Text("-\(file.deletions)")
                    .foregroundColor(.red)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
            )
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(cardHeaderBackground)
    }

    private func hunkView(_ hunk: DiffHunk, minWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            hunkHeaderView(hunk.header, minWidth: minWidth)

            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                diffLineView(line, minWidth: minWidth)
            }
        }
    }

    private func hunkHeaderView(_ header: String, minWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("")
                .frame(width: gutterWidth)
                .background(gutterBackground)
            Text(header)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 8)
        }
        .padding(.vertical, 3)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(hunkHeaderBackground)
    }

    private var gutterWidth: CGFloat { 72 }

    private func diffLineView(_ line: DiffLine, minWidth: CGFloat) -> some View {
        let bgColor: Color
        let fgColor: Color

        switch line.type {
        case .added:
            bgColor = addedLineBackground
            fgColor = addedLineForeground
        case .removed:
            bgColor = removedLineBackground
            fgColor = removedLineForeground
        case .context:
            bgColor = .clear
            fgColor = colorScheme == .dark ? .white.opacity(0.8) : .primary
        }

        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                lineNumberText(line.oldLineNumber)
                    .frame(width: 34, alignment: .trailing)
                lineNumberText(line.newLineNumber)
                    .frame(width: 34, alignment: .trailing)
            }
            .frame(width: gutterWidth)
            .background(gutterBackground(for: line.type))
            .padding(.trailing, 4)

            Text(line.content)
                .foregroundColor(fgColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 0.5)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(bgColor)
    }

    private func lineNumberText(_ number: Int?) -> some View {
        Group {
            if let number {
                Text("\(number)")
                    .foregroundColor(lineNumberColor)
            } else {
                Text("")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.trailing, 4)
    }

    private var lineNumberColor: Color {
        colorScheme == .dark ? .white.opacity(0.3) : .black.opacity(0.3)
    }

    private func gutterBackground(for lineType: DiffLineType) -> Color {
        switch lineType {
        case .added:
            return colorScheme == .dark ? Color.green.opacity(0.08) : Color.green.opacity(0.05)
        case .removed:
            return colorScheme == .dark ? Color.red.opacity(0.08) : Color.red.opacity(0.05)
        case .context:
            return gutterBackground
        }
    }

    private var gutterBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.09, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.95, alpha: 1.0))
    }

    private var cardBorderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.12)
    }

    private var cardHeaderBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.14, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.94, alpha: 1.0))
    }

    // MARK: - Empty / Loading States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading diffs...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No changes")
                .font(.headline)
                .foregroundColor(.primary)
            Text("Working tree is clean")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Colors

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    private var fileListBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.10, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.96, alpha: 1.0))
    }

    private var selectedRowBackground: Color {
        colorScheme == .dark
            ? Color.accentColor.opacity(0.25)
            : Color.accentColor.opacity(0.15)
    }

    private var hunkHeaderBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.15, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.94, alpha: 1.0))
    }

    private var addedLineBackground: Color {
        colorScheme == .dark
            ? Color.green.opacity(0.12)
            : Color.green.opacity(0.08)
    }

    private var removedLineBackground: Color {
        colorScheme == .dark
            ? Color.red.opacity(0.12)
            : Color.red.opacity(0.08)
    }

    private var addedLineForeground: Color {
        colorScheme == .dark
            ? Color(red: 0.5, green: 0.95, blue: 0.5)
            : Color(red: 0.1, green: 0.55, blue: 0.1)
    }

    private var removedLineForeground: Color {
        colorScheme == .dark
            ? Color(red: 0.95, green: 0.5, blue: 0.5)
            : Color(red: 0.7, green: 0.15, blue: 0.15)
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}
