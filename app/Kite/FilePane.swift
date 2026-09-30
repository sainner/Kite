import SwiftUI

/// 文件目录、原文、渲染与历史差异共用一个窗口；行号定位仅属于当前设备。
struct FilePane: View {
    let browser: FileBrowser

    var body: some View {
        @Bindable var browser = browser
        PaneWindow(header: PaneHeader(title: "文件", detail: browser.selection.path)) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if browser.showDirectory {
                        directory
                            .frame(width: browser.selection.path == nil || geometry.size.width < 600 ? nil : 210)
                    }
                    if !browser.showDirectory || (browser.selection.path != nil && geometry.size.width >= 600) {
                        if browser.showDirectory { Divider() }
                        preview
                    }
                }
            }
        } controls: { _ in
            HStack(spacing: 12) {
                Button { browser.showDirectory.toggle() } label: { Image(systemName: "folder") }
                    .help("显示或隐藏文件目录")
                if browser.selection.diffId != nil {
                    Text("历史差异").foregroundStyle(.secondary)
                    Button("当前文件") {
                        if let path = browser.selection.path { Task { try? await browser.navigate(FileReference(path: path)) } }
                    }
                } else if browser.selection.path != nil {
                    Picker("显示方式", selection: $browser.rendered) {
                        Text("原文").tag(false)
                        Text("预览").tag(true)
                    }.pickerStyle(.segmented).clickPointer().frame(maxWidth: 140)
                }
                Spacer(minLength: 0)
                if let page = browser.page, browser.selection.diffId == nil {
                    Button { Task { await browser.read(offset: max(1, page.offset - 200)) } } label: { Image(systemName: "chevron.left") }
                        .disabled(page.offset <= 1)
                    Button { if let offset = page.nextOffset { Task { await browser.read(offset: offset) } } } label: { Image(systemName: "chevron.right") }
                        .disabled(page.nextOffset == nil)
                }
                Button { Task { await browser.loadSelection() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(browser.loadingText || browser.selection.path == nil)
            }
            .buttonStyle(.pointingPlain).font(Theme.secondary)
            .padding(.horizontal, 14).frame(minHeight: Metrics.controlHeight)
        }
        .task(id: browser.connectionRevision) { await browser.list() }
        .task(id: browser.requestKey) { await browser.loadSelection() }
    }

    private var directory: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("上一级", systemImage: "arrow.up") {
                        let parent = (browser.directoryPath as NSString).deletingLastPathComponent
                        Task { await browser.list(parent.isEmpty ? "." : parent, offset: 0) }
                    }.disabled(browser.directoryPath == ".")
                    Spacer()
                    Button { Task { await browser.list() } } label: { Image(systemName: "arrow.clockwise") }
                }.buttonStyle(.pointingPlain)
                Text(browser.directoryPath).foregroundStyle(.secondary)
                if let error = browser.directoryError { Text(error).foregroundStyle(.secondary) }
                if browser.loadingDirectory { ProgressView() }
                if let directory = browser.directory {
                    if directory.entries.isEmpty { Text("此目录为空").foregroundStyle(.secondary) }
                    ForEach(directory.entries) { entry in
                        Button {
                            Task {
                                if entry.kind == "directory" { await browser.list(entry.path, offset: 0) }
                                else { try? await browser.navigate(FileReference(path: entry.path)) }
                            }
                        } label: {
                            Label(entry.name, systemImage: entry.kind == "directory" ? "folder" : "doc.text")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                        }.buttonStyle(.pointingPlain).disabled(browser.selecting || !["file", "directory"].contains(entry.kind))
                    }
                    HStack {
                        Button("上一页") { Task { await browser.list(offset: max(0, browser.directoryOffset - 200)) } }
                            .disabled(browser.directoryOffset == 0)
                        Spacer()
                        Button("下一页") { if let offset = directory.nextOffset { Task { await browser.list(offset: offset) } } }
                            .disabled(directory.nextOffset == nil)
                    }.buttonStyle(.pointingPlain)
                }
            }.font(Theme.secondary).padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var preview: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 8) {
                    if let error = browser.textError { Text(error).foregroundStyle(.secondary) }
                    if let message = browser.locationMessage { Text(message).font(Theme.secondary).foregroundStyle(.secondary) }
                    if browser.loadingText { ProgressView() }
                    if let diff = browser.diff {
                        if diff.files.count > 1 {
                            HStack {
                                ForEach(diff.files, id: \.path) { file in
                                    Button((file.path as NSString).lastPathComponent) {
                                        Task { try? await browser.navigate(FileReference(path: file.path, diffID: diff.id)) }
                                    }
                                }
                            }.buttonStyle(.pointingPlain).font(Theme.secondary)
                        }
                        if browser.diffRows.isEmpty { Text("文件内容为空").foregroundStyle(.secondary) }
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(browser.diffRows) { row in
                                diffRow(row).id(row.id)
                            }
                        }
                    } else if let page = browser.page {
                        if browser.rendered { MarkdownView(page.text).frame(minWidth: 240, idealWidth: 640, maxWidth: 760) }
                        else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(page.text.components(separatedBy: "\n").enumerated()), id: \.offset) { index, text in
                                    let line = page.offset + index
                                    HStack(alignment: .top, spacing: 12) {
                                        Text(String(line)).foregroundStyle(.tertiary).frame(width: 48, alignment: .trailing)
                                        Text(verbatim: text.isEmpty ? " " : text).fixedSize()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2)
                                    .background(highlight(line) ? Color.accentColor.opacity(0.12) : .clear)
                                    .id(line)
                                }
                            }
                        }
                    } else if browser.selection.path == nil { Text("选择文件，或点击消息中的引用").foregroundStyle(.secondary) }
                }
                .font(Theme.code).textSelection(.enabled).padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: browser.contentRevision) {
                await Task.yield()
                if browser.diff != nil, let row = browser.focusedRow { proxy.scrollTo(row, anchor: .top) }
                else if let line = browser.focus?.startLine { proxy.scrollTo(line, anchor: .top) }
            }
        }
    }

    private func highlight(_ line: Int?) -> Bool {
        guard let line, let start = browser.focus?.startLine else { return false }
        return line >= start && line <= (browser.focus?.endLine ?? start)
    }

    private func diffRow(_ row: FileDiffRow) -> some View {
        let color: Color = row.kind == .added ? .green : row.kind == .removed ? .red : .primary
        let focused = highlight(row.newLine)
        return HStack(alignment: .top, spacing: 8) {
            Text(row.oldLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
            Text(row.newLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
            Text(row.kind == .added ? "+" : row.kind == .removed ? "−" : " ")
            Text(verbatim: row.text.isEmpty ? " " : row.text).fixedSize()
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .background(focused ? Color.accentColor.opacity(0.18) : color.opacity(row.kind == .same ? 0 : 0.07))
    }
}
