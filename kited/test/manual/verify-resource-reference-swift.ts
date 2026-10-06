/**
 * 手动合同验证：Foundation Markdown 的链接和百分号编码经统一引用装饰后仍指向原文件、diff 和网页。
 * 运行：bun kited/test/manual/verify-resource-reference-swift.ts
 * Swift 编译不计入 small 测试耗时预算。
 */
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { command } from './command.ts';

// 直接编译真实的 diff 算法，避免在合同里维护一份模仿实现；只抽取其独立声明。
function declaration(source: string, signature: string): string {
  const start = source.indexOf(signature);
  if (start < 0 || source.indexOf(signature, start + 1) >= 0) throw new Error(`Swift 声明不唯一：${signature}`);
  const open = source.indexOf('{', start);
  let depth = 0;
  for (let index = open; index < source.length; index++) {
    if (source[index] === '{') depth++;
    if (source[index] === '}' && --depth === 0) return source.slice(start, index + 1);
  }
  throw new Error(`Swift 声明未闭合：${signature}`);
}

const root = mkdtempSync(join(tmpdir(), 'resource-reference-swift-contract-'));
try {
  const app = join(import.meta.dir, '..', '..', '..', 'app', 'Kite');
  const diffSource = readFileSync(join(app, 'Conversation', 'ToolPresentation.swift'), 'utf8');
  const clientSource = readFileSync(join(app, 'Application', 'KitedClient.swift'), 'utf8');
  const diffTypes = join(root, 'LineDiff.swift');
  writeFileSync(diffTypes, `import Foundation\n\n${[
    'func splitLines(', 'struct LineDiff',
  ].map((signature) => declaration(diffSource, signature)).join('\n\n')}\n\n${[
    'extension JSON: Codable', 'nonisolated struct RemoteState', 'nonisolated struct ContextUsage',
  ].map((signature) => declaration(clientSource, signature)).join('\n\n')}\n`);
  const fixture = join(root, 'ResourceReferenceContract.swift');
  writeFileSync(fixture, String.raw`
import Foundation

// sample 模式不应调用网络；若误走客户端，合同立即失败。
final class KitedClient: Equatable {
    static func == (lhs: KitedClient, rhs: KitedClient) -> Bool { lhs === rhs }
    func request<Value: Decodable>(_ path: String, method: String,
        body: any Encodable, as type: Value.Type) async throws -> Value {
        throw KitedError(message: "sample 导航误调用网络")
    }
}

struct KitedError: Error, LocalizedError {
    let message: String
    init(message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}

private func markdown(_ source: String) throws -> AttributedString {
    try AttributedString(markdown: source, options: .init(
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible))
}

private func links(_ source: AttributedString) -> [URL] {
    source.runs.compactMap { $0.link }
}

@main
struct ResourceReferenceContract {
    @MainActor
    static func main() async throws {
        let scope = ReferenceScope(machineID: "fixture-machine", workspaceID: "fixture-workspace")

        // Foundation 必须把中文、空格及 URL 保留字符编码在目标内，而非转成 fragment/query 或双重转义。
        let original = FileReference(path: "目录/带 空格#%?.ts", diffID: "diff_a81",
            startLine: 10, endLine: 20)
        let url = original.url(in: scope)
        require(FileReference(url: url) == original && FileReference.scope(of: url) == scope,
            "内部 URL 往返改变中文或保留字符、diff 定位或工作区归属")
        require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "side" }) == false,
            "新的 diff URL 仍携带旧侧或新侧参数")
        let explicit = ReferenceText.decorate(try markdown("[历史版本](\(url.absoluteString))"), scope: scope)
        require(links(explicit).count == 1 && FileReference(url: links(explicit)[0]) == original,
            "内部引用经过 Foundation Markdown 后重复编码或定位丢失")
        var legacyURL = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        legacyURL.queryItems = (legacyURL.queryItems ?? []) + [URLQueryItem(name: "side", value: "old")]
        let legacyTarget = legacyURL.url!
        let legacyLink = ReferenceText.decorate(try markdown("[旧格式](\(legacyTarget.absoluteString))"), scope: scope)
        require(FileReference(url: legacyTarget) == nil && links(legacyLink).allSatisfy { FileReference(url: $0) == nil },
            "带 side 的 URL 经过 Markdown 后仍被接受或静默转换为新引用")

        // Foundation 创建已有 Markdown 链接，装饰器再把相对目标升级成有工作区归属的引用。
        let prose = "查看 src/main.ts:1-20，以及 [修改记录](src/main.ts:diff_a81:10-20) "
            + "和 [源文件](目录/带%20空格%23%25.ts:12-18)，网页 [文档](https://example.com/docs?q=a%20b#part)。"
        let decorated = ReferenceText.decorate(try markdown(prose), scope: scope)
        let targets = links(decorated)
        let files = targets.compactMap(FileReference.init(url:))
        require(files.count == 3, "裸路径或已有 Markdown 文件链接被遗漏或重复识别：\(targets.map { $0.absoluteString })")
        require(files.contains(FileReference(path: "src/main.ts", startLine: 1, endLine: 20)),
            "中文标点进入裸路径或普通文件行范围丢失")
        require(files.contains(FileReference(path: "src/main.ts", diffID: "diff_a81",
            startLine: 10, endLine: 20)), "Markdown diff 链接的版本标识或修改后行范围丢失")
        require(files.contains(FileReference(path: "目录/带 空格#%.ts", startLine: 12, endLine: 18)),
            "Markdown 相对目标的百分号未正确解码或被解码两次")
        require(targets.filter { FileReference(url: $0) != nil }.allSatisfy { FileReference.scope(of: $0) == scope },
            "装饰后的文件引用未绑定消息所属工作区")
        require(targets.contains(URL(string: "https://example.com/docs?q=a%20b#part")!),
            "已有网页 Markdown 链接的查询或锚点被引用识别改写")

        let invalid = "错误定位 src/main.ts:0-20、旧格式 src/main.ts:diff_a81:old:10-20 和 src/main.ts:diff_a81:new:10-20"
        let unchanged = ReferenceText.decorate(try markdown(invalid), scope: scope)
        require(String(unchanged.characters) == invalid && links(unchanged).isEmpty,
            "非法行号或旧侧新侧后缀被重新解释成有效路径，或被截成部分引用")
        print("Foundation Markdown 与内部 URL 保留文件、diff、网页目标和工作区归属")

        // 可观察选择、异步读取、diff 算法与修改后行号定位交接，切换差异版本或回到文件须清理旧内容。
        let originalText = "# Kite\n\n个人 agent 工作台。\n\n先阅读文件。\n"
        let firstText = "# Kite\n\n个人 agent 工作台。\n\n文件与预览共用一个窗口。\n"
        let currentText = "# Kite\n\n个人 agent 工作台。\n\n文件、预览和 diff 共用一个窗口。\n历史引用可以回看每次修改。\n"
        let browser = FileBrowser(instanceID: "fixture-files", workspaceID: scope.workspaceID,
            client: nil, sample: true)
        guard let firstReference = FileReference.parse("README.md:diff_sample1:5"),
              let secondReference = FileReference.parse("README.md:diff_sample2:5"),
              let currentReference = FileReference.parse("README.md:1-6") else { fatalError("导航夹具引用无效") }
        try await browser.navigate(firstReference)
        await browser.loadSelection()
        require(browser.selection.path == "README.md" && browser.selection.diffId == "diff_sample1"
            && browser.focus == firstReference && browser.textError == nil,
            "首次 diff 导航未交接文件、版本或行定位")
        require(browser.diff?.id == "diff_sample1" && browser.page == nil
            && browser.diff?.files.first?.before == originalText
            && browser.diff?.files.first?.after == firstText,
            "首次 diff 导航未读取指定版本的前后内容")
        guard let firstRowID = browser.focusedRow,
              let firstRow = browser.diffRows.first(where: { $0.id == firstRowID }) else {
            fatalError("首次 diff 没有定位到行")
        }
        require(firstRow.newLine == 5 && firstRow.oldLine == nil
            && firstRow.text == "文件与预览共用一个窗口。", "首次 diff 定位未采用修改后的行号")

        try await browser.navigate(secondReference)
        await browser.loadSelection()
        require(browser.selection.path == "README.md" && browser.selection.diffId == "diff_sample2"
            && browser.focus == secondReference && browser.textError == nil,
            "同一文件的第二份 diff 导航复用了旧选择或行定位")
        require(browser.diff?.id == "diff_sample2" && browser.page == nil
            && browser.diff?.files.first?.before == firstText
            && browser.diff?.files.first?.after == currentText,
            "第二份 diff 未替换前后内容")
        guard let secondRowID = browser.focusedRow,
              let secondRow = browser.diffRows.first(where: { $0.id == secondRowID }) else {
            fatalError("第二份 diff 没有定位到行")
        }
        require(secondRow.newLine == 5 && secondRow.oldLine == nil
            && secondRow.text == "文件、预览和 diff 共用一个窗口。", "第二份 diff 定位复用了第一份内容或采用修改前行号")

        guard let overviewReference = FileReference.parse("README.md:diff_sample2") else { fatalError("整份 diff 引用无效") }
        try await browser.navigate(overviewReference)
        await browser.loadSelection()
        let firstChange = browser.diffRows.first(where: { $0.oldLine == 5 && $0.newLine == nil })
        require(browser.selection.diffId == "diff_sample2" && browser.focus == overviewReference
            && firstChange != nil && browser.focusedRow == firstChange?.id,
            "同一份 diff 去掉行号后没有回到首个改动")

        try await browser.navigate(currentReference)
        await browser.loadSelection()
        require(browser.selection.path == "README.md" && browser.selection.diffId == nil
            && browser.focus == currentReference && browser.diff == nil && browser.diffRows.isEmpty
            && browser.page?.offset == 1 && browser.textError == nil,
            "回到当前文件未清理历史 diff 或保留错误的读取位置")
        require(browser.page?.text.trimmingCharacters(in: .newlines) == currentText.trimmingCharacters(in: .newlines),
            "回到文件仍展示旧版本内容")
        print("文件浏览器按 diff 版本和修改后的行号导航，回到当前文件清理历史内容")
    }
}
  `.replace(/\\u([0-9A-Fa-f]{4})/g, (_, hex: string) => String.fromCharCode(Number.parseInt(hex, 16))));
  const compiler = await command(['xcrun', '--find', 'swiftc'], root);
  const sdk = await command(['xcrun', '--show-sdk-path'], root);
  const architecture = await command(['uname', '-m'], root);
  const executable = join(root, 'resource-reference-contract');
  await command([
    compiler, '-sdk', sdk, '-target', `${architecture}-apple-macosx26.0`, '-parse-as-library',
    join(app, 'Conversation', 'Transcript.swift'),
    join(app, 'Conversation', 'AgentConfiguration.swift'),
    join(app, 'Plugins', 'PluginManagementModels.swift'),
    join(app, 'Files', 'ResourceReference.swift'), join(app, 'Application', 'RemoteWorkspace.swift'),
    join(app, 'Files', 'FileBrowser.swift'), diffTypes, fixture, '-o', executable,
  ], root);
  console.log(await command([executable], root));
} finally {
  rmSync(root, { recursive: true, force: true });
}
