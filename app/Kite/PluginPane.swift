import SwiftUI
import WebKit

/// 插件只提供窗口内容；标题、控制区及停靠继续由原生容器管理。
struct PluginPane: View {
    let target: WindowTarget
    let title: String
    let client: KitedClient
    let state: JSON?
    let connection: UUID
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var model
    @State private var loadState = LoadState.loading
    @State private var generation = UUID()

    private enum LoadState {
        case loading, ready, failed(String)

        var error: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    var body: some View {
        PaneWindow(header: PaneHeader(title: title)) {
            PluginWebView(target: target, client: client, theme: colorScheme == .dark ? "dark" : "light",
                          state: state, connection: connection, report: { [loadState = $loadState] message in
                              loadState.wrappedValue = message.map(LoadState.failed) ?? .ready
                          })
                .id(generation)
                .overlay {
                    if case .loading = loadState { ProgressView("正在打开插件") }
                }
        } controls: { _ in
            HStack(spacing: Metrics.paneButtonGap) {
                Text(loadState.error ?? (model.connected ? "" : "连接已断开，正在重连"))
                    .font(Theme.secondary).foregroundStyle(loadState.error == nil ? Color.secondary : .red)
                    .lineLimit(2)
                Spacer(minLength: Metrics.paneButtonGap)
                Button {
                    loadState = .loading
                    generation = UUID()
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(PaneButtonStyle())
                    .padding(Metrics.paneToolbarInset)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("重新加载插件界面")
                    .help("重新加载插件界面")
            }
            .frame(minHeight: Metrics.paneToolbarHeight)
        }
    }
}

#if os(macOS)
private typealias PluginRepresentable = NSViewRepresentable
#else
private typealias PluginRepresentable = UIViewRepresentable
#endif

private struct PluginWebView: PluginRepresentable {
    let target: WindowTarget
    let client: KitedClient
    let theme: String
    let state: JSON?
    let connection: UUID
    let report: (String?) -> Void

    func makeCoordinator() -> PluginWebBridge {
        let html = Bundle.main.url(forResource: "PluginHost", withExtension: "html")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return PluginWebBridge(hostHTML: html, load: { [client, target] in
            struct Resource: Decodable { let html: String; let resourceUri: String }
            let value = try await client.request("/instances/\(target.instanceId)/plugin/views/\(target.viewId)", as: Resource.self)
            return ["html": value.html, "resourceUri": value.resourceUri]
        }, call: { [client, target] request in
            guard let name = request["name"] as? String, let operationID = request["operationId"] as? String,
                  let arguments = request["arguments"] as? [String: Any] else { throw KitedError(message: "插件工具请求无效") }
            let encoded = try JSONDecoder().decode(JSON.self, from: JSONSerialization.data(withJSONObject: arguments))
            struct Call: Encodable { let operationId: String; let arguments: JSON }
            let component = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
            let result = try await client.request("/instances/\(target.instanceId)/plugin/tools/\(component)", method: "POST",
                body: Call(operationId: operationID, arguments: encoded), as: JSON.self)
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
        }, report: report)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { context.coordinator.start(); return context.coordinator.webView }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(theme: theme, state: state, connection: connection) }
    static func dismantleNSView(_ view: WKWebView, coordinator: PluginWebBridge) { Task { await coordinator.close() } }
    #else
    func makeUIView(context: Context) -> WKWebView { context.coordinator.start(); return context.coordinator.webView }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update(theme: theme, state: state, connection: connection) }
    static func dismantleUIView(_ view: WKWebView, coordinator: PluginWebBridge) { Task { await coordinator.close() } }
    #endif
}
