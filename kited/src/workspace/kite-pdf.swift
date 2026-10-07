// read 的 PDF 转换：PDFKit 渲染页面，Vision 识别版面，按位置从上到下拼成 Markdown。
// 有文本层的页按 Vision 给出的区域取原文，避免 OCR 错字；没有文本层的页用识别结果并输出页面图片。
// 用法：kite-pdf <pdf> <起始页> <结束页>。第一行输出 {"pages": 总页数}，之后每页一行 JSON。
// 程序名保持 kite-pdf：Vision 按程序名缓存编译好的模型，改名会重新冷启动。
import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

struct Failure: Error { let message: String }

/// 沙箱规则按真实路径匹配；URL.resolvingSymlinksInPath 会把 /private/tmp 写回 /tmp，不能用。
func real(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else { return path }
  defer { free(resolved) }
  return String(cString: resolved)
}

@_silgen_name("sandbox_init")
func sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

/// 解析不可信的 PDF 前先限制自己：不能联网，只能写 Vision 的缓存，用户目录里只能读这份 PDF 和本程序目录。
/// Kite 统一沙箱不放行 Vision 需要的 GPU 与窗口服务，这里改用进程自限。
func confine(pdf: String) throws {
  let quote = { (path: String) in "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
  let directory = { (name: Int32) -> String? in
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    return confstr(name, &buffer, buffer.count) > 0 ? String(cString: buffer) : nil
  }
  guard let entry = getpwuid(getuid()) else { throw Failure(message: "无法确定当前用户目录") }
  let home = real(String(cString: entry.pointee.pw_dir))
  let cache = home + "/Library/Caches/kite-pdf"
  // Vision 会读取本程序所在目录。
  let program = real(Bundle.main.executableURL?.deletingLastPathComponent().path ?? "/nonexistent")
  let writable = [cache, directory(_CS_DARWIN_USER_CACHE_DIR), directory(_CS_DARWIN_USER_TEMP_DIR)].compactMap { $0 }
    .map { "(subpath \(quote(real($0))))" }
  let profile = """
    (version 1)
    (allow default)
    (deny network*)
    (deny file-write*)
    (allow file-write* \(writable.joined(separator: " ")) (literal "/dev/null") (literal "/dev/dtracehelper"))
    (deny file-read-data (subpath "/Users") (subpath "/Volumes") (subpath "/private/tmp") (subpath \(quote(home))))
    (allow file-read-data (literal \(quote(pdf))) (subpath \(quote(cache))) (subpath \(quote(program))))
    """
  var error: UnsafeMutablePointer<CChar>?
  guard sandbox_init(profile, 0, &error) == 0 else {
    throw Failure(message: "无法限制转换进程：\(error.map { String(cString: $0) } ?? "未知错误")")
  }
}

/// 长边不超过 2048 像素，与附给模型的图片上限一致，也足够 Vision 识别。
func render(_ page: PDFPage) -> CGImage? {
  let box = page.bounds(for: .mediaBox)
  guard box.width > 0, box.height > 0 else { return nil }
  let scale = min(2, 2048 / max(box.width, box.height))
  let width = Int(box.width * scale), height = Int(box.height * scale)
  guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
  context.setFillColor(.white)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.scaleBy(x: scale, y: scale)
  context.translateBy(x: -box.minX, y: -box.minY)
  page.draw(with: .mediaBox, to: context)
  return context.makeImage()
}

func jpeg(_ image: CGImage) -> Data? {
  let data = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
  CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
  return CGImageDestinationFinalize(destination) ? data as Data : nil
}

typealias Container = DocumentObservation.Container

struct Page {
  let page: PDFPage
  let layered: Bool

  func rect(_ region: NormalizedRegion) -> CGRect {
    let box = page.bounds(for: .mediaBox), r = region.normalizedPath.boundingBox
    return CGRect(x: box.minX + r.minX * box.width, y: box.minY + r.minY * box.height,
      width: r.width * box.width, height: r.height * box.height).insetBy(dx: -1, dy: -1)
  }

  /// 文本层取到的是原文；康熙部首等兼容字形规范成常用字，全角标点保持原样，中文行之间不补空格。
  func text(_ block: Container.Text) -> String {
    guard layered, let raw = page.selection(for: rect(block.boundingRegion))?.string else { return block.transcript }
    let normalized = raw.unicodeScalars.map { (0x2E80...0x2FDF).contains($0.value)
      ? String($0).precomposedStringWithCompatibilityMapping : String($0) }.joined()
    let wide = { (c: Character?) -> Bool in (c?.unicodeScalars.first?.value ?? 0) >= 0x2E80 }
    let joined = normalized.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
      .reduce("") { result, line in result.isEmpty ? line : result + (wide(result.last) && wide(line.first) ? "" : " ") + line }
    return joined.isEmpty ? block.transcript : joined
  }

  /// 判断标题用的相对尺寸：文本层取字号中位数；扫描页取每行宽度除以字数，汉字记一个字宽、其余半个，行框高度噪声太大不用。
  func size(_ block: Container.Text) -> CGFloat {
    if layered, let attributed = page.selection(for: rect(block.boundingRegion))?.attributedString, attributed.length > 0 {
      var sizes: [CGFloat] = []
      attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
        if let font = value as? NSFont { sizes += Array(repeating: font.pointSize, count: range.length) }
      }
      if !sizes.isEmpty { return sizes.sorted()[sizes.count / 2] }
    }
    let widths = block.lines.compactMap { line -> CGFloat? in
      let units = line.transcript.filter { !$0.isWhitespace }.reduce(CGFloat(0)) { total, character in
        total + ((character.unicodeScalars.first?.value ?? 0) >= 0x2E80 ? 1 : 0.5) }
      return units >= 2 ? line.boundingBox.width / units : nil
    }
    return widths.isEmpty ? 0 : widths.sorted()[widths.count / 2]
  }

  func markdown(_ document: Container) -> String {
    var blocks: [(top: CGFloat, text: String)] = []
    var covered: [CGRect] = []
    let cell = { (block: Container.Text) in text(block).replacingOccurrences(of: "|", with: "\\|") }
    for table in document.tables {
      let rows = table.rows.map { "| " + $0.map { cell($0.content.text) }.joined(separator: " | ") + " |" }
      guard let header = rows.first else { continue }
      let divider = "|" + String(repeating: " --- |", count: table.rows.first?.count ?? 1)
      let bounds = table.boundingRegion.normalizedPath.boundingBox
      covered.append(bounds)
      blocks.append((bounds.maxY, ([header, divider] + rows.dropFirst()).joined(separator: "\n")))
    }
    for list in document.lists {
      let items = list.items.map { item in
        let content = text(item.content.text), marker = item.markerString.trimmingCharacters(in: .whitespaces)
        return marker.isEmpty || content.hasPrefix(marker) ? content : "\(marker) \(content)"
      }
      let bounds = list.boundingRegion.normalizedPath.boundingBox
      covered.append(bounds)
      blocks.append((bounds.maxY, items.joined(separator: "\n")))
    }
    // Vision 的段落也包含表格和列表里的文字，这些不参与正文尺寸，也不重复输出。
    let paragraphs = document.paragraphs.filter { paragraph in
      let bounds = paragraph.boundingRegion.normalizedPath.boundingBox
      return !covered.contains(where: { $0.insetBy(dx: -0.005, dy: -0.005).contains(CGPoint(x: bounds.midX, y: bounds.midY)) })
    }
    let measured = paragraphs.map { (paragraph: $0, size: size($0)) }
    // 正文尺寸按字数加权取中位数。Vision 的 title 和 isTitle 不可靠，只按相对尺寸判断标题层级；扫描页估计误差大，门槛更高、只分两级。
    let weighted = measured.flatMap { item -> [CGFloat] in
      item.size > 0 ? Array(repeating: item.size, count: max(1, item.paragraph.transcript.count)) : []
    }.sorted()
    let body = weighted.isEmpty ? 0 : weighted[weighted.count / 2]
    let levels: [(ratio: CGFloat, prefix: String)] = layered ? [(1.6, "# "), (1.3, "## "), (1.15, "### ")] : [(1.8, "# "), (1.3, "## ")]
    for (paragraph, size) in measured {
      let bounds = paragraph.boundingRegion.normalizedPath.boundingBox
      let ratio = body > 0 ? size / body : 1
      let heading = paragraph.lines.count <= 2 ? levels.first { ratio >= $0.ratio }?.prefix ?? "" : ""
      blocks.append((bounds.maxY, heading + text(paragraph).replacingOccurrences(of: "\n", with: " ")))
    }
    return blocks.sorted { $0.top > $1.top }.map(\.text).joined(separator: "\n\n")
  }
}

func emit(_ value: [String: Any]) throws {
  let data = try JSONSerialization.data(withJSONObject: value)
  FileHandle.standardOutput.write(data + Data([0x0A]))
}

func main() async throws {
  let arguments = CommandLine.arguments
  guard arguments.count == 4, let first = Int(arguments[2]), let last = Int(arguments[3]), first >= 1, last >= first else {
    throw Failure(message: "用法：kite-pdf <pdf> <起始页> <结束页>")
  }
  let path = real(arguments[1])
  try confine(pdf: path)
  guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { throw Failure(message: "无法打开 PDF") }
  if document.isLocked { throw Failure(message: "PDF 已加密，无法读取") }
  try emit(["pages": document.pageCount])
  var request = RecognizeDocumentsRequest()
  request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
  request.textRecognitionOptions.useLanguageCorrection = true
  guard first <= document.pageCount else { return }
  for number in first...min(last, document.pageCount) {
    guard let pdfPage = document.page(at: number - 1), let image = render(pdfPage) else {
      throw Failure(message: "第 \(number) 页无法渲染")
    }
    let page = Page(page: pdfPage, layered: !(pdfPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    let markdown = try await request.perform(on: image).map { page.markdown($0.document) }.joined(separator: "\n\n")
    var line: [String: Any] = ["page": number, "markdown": markdown, "textLayer": page.layered]
    if !page.layered { line["image"] = jpeg(image)?.base64EncodedString() ?? NSNull() }
    try emit(line)
  }
}

do { try await main() } catch {
  FileHandle.standardError.write(((error as? Failure)?.message ?? "PDF 转换失败：\(error)").data(using: .utf8)!)
  exit(1)
}
