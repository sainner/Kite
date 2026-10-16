import PDFKit
import SwiftUI
#if os(macOS)
import QuickLookUI
#else
import QuickLook
#endif

/// PDF 交给系统的 PDF 组件，缩放到窗口宽度。查找也用它的：标出所有匹配，跳到当前那个，找到几个报给 found。
struct PDFPreview {
    let url: URL
    /// 查找的关键字和当前第几个；没在找是 nil。
    var search: SearchHighlight?
    var found: (Int) -> Void = { _ in }

    final class Coordinator {
        var query: String?
        var results: [PDFSelection] = []
        var current: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func make() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    private func update(_ view: PDFView, _ state: Coordinator) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            state.query = nil
        }
        if state.query != search?.query {
            state.query = search?.query
            state.results = state.query.flatMap { view.document?.findString($0, withOptions: .caseInsensitive) } ?? []
            state.current = nil
            view.highlightedSelections = state.results.isEmpty ? nil : state.results
            if state.results.isEmpty { view.clearSelection() }
            let count = state.results.count
            // 不在视图更新当中改外面的状态
            Task { @MainActor in found(count) }
        }
        if let index = search?.current, state.results.indices.contains(index), state.current != index {
            state.current = index
            view.setCurrentSelection(state.results[index], animate: true)
            view.go(to: state.results[index])
        }
    }
}

#if os(macOS)
extension PDFPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { make() }
    func updateNSView(_ view: PDFView, context: Context) { update(view, context.coordinator) }
}

/// 图片、音视频、幻灯片与文档交给系统的通用预览。
struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
#else
extension PDFPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { make() }
    func updateUIView(_ view: PDFView, context: Context) { update(view, context.coordinator) }
}

/// 图片、音视频、幻灯片与文档交给系统的通用预览。
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Source { Source(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Source: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
#endif

/// 系统认不出的格式只列信息；用默认 App 打开、下载和共享在窗口的控制区。
struct FileInfoView: View {
    let browser: FileBrowser

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: browser.format.symbol).font(Theme.display).fontWeight(.light).foregroundStyle(.secondary)
            if let path = browser.selection.path {
                Text((path as NSString).lastPathComponent).font(Theme.body).multilineTextAlignment(.center)
            }
            if let info = browser.info {
                Grid(horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("类型").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(info.type.isEmpty ? "未知" : info.type).gridColumnAlignment(.leading)
                    }
                    GridRow { Text("大小").foregroundStyle(.secondary); Text(info.size.formatted(.byteCount(style: .file))) }
                    if let modified = info.modified {
                        GridRow { Text("修改时间").foregroundStyle(.secondary); Text(modified.formatted(date: .abbreviated, time: .shortened)) }
                    }
                }.font(Theme.secondary)
            }
            if let note = browser.infoNote {
                Text(note).font(Theme.secondary).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
