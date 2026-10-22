// 照 DeviceHub 的做法收真机的主屏镜像：CoreDevice 的 MediaStreamSession 建视频流，画到一个 CALayer 上。
// mirror list：列出 CoreDevice 看得到的设备。mirror <名字或 ID 片段> [秒数]：开一个窗口收画面，打印事件，定时要最后一帧存成文件。
import AppKit
import CoreDevice
import CoreDeviceMediaStreamSupport
import Foundation
import QuartzCore

let started = Date()
let output = URL(fileURLWithPath: "/tmp/kite-device-mirror")

func log(_ text: String) {
  let line = String(format: "[%7.3f] ", Date().timeIntervalSince(started)) + text + "\n"
  FileHandle.standardError.write(line.data(using: .utf8)!)
}

/// 设备是 CoreDevice 服务签到后才列出来的，刚起时可能是空的。
func devices() async -> [RemoteDevice] {
  for _ in 0..<50 {
    let all = DeviceManager.shared.allDevices()
    if !all.isEmpty { return all }
    try? await Task.sleep(for: .milliseconds(200))
  }
  return []
}

func fileExtension(_ data: Data) -> String {
  let head = [UInt8](data.prefix(12))
  if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
  if head.starts(with: [0xFF, 0xD8]) { return "jpg" }
  if head.count >= 12, String(bytes: head[4..<8], encoding: .ascii) == "ftyp" { return "heic" }
  return "bin"
}

func receive<S: VideoStream>(_ stream: S) async {
  Task {
    for index in 1...3 {
      try? await Task.sleep(for: .seconds(3))
      log("要最后一帧 #\(index)")
      await stream.requestLastDecodedFrame()
    }
  }
  do {
    let events = try await stream.activate()
    log("activate 返回")
    var saved = 0
    for try await event in events {
      let reflected = Mirror(reflecting: event)
      if let child = reflected.children.first, let data = child.value as? Data {
        saved += 1
        let file = output.appendingPathComponent("frame-\(saved).\(fileExtension(data))")
        try? data.write(to: file)
        log("事件 \(child.label ?? "?")：\(data.count) 字节，存到 \(file.path)")
      } else {
        log("事件：\(String(describing: event).prefix(300))")
      }
    }
    log("事件流结束")
  } catch {
    log("视频流出错：\(error)")
  }
}

@main
struct DeviceMirror {
  static func main() {
    let arguments = CommandLine.arguments
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    guard arguments.count >= 2, arguments[1] != "list" else {
      Task {
        for device in await devices() { print("\(device.id)  \(device.description)") }
        exit(0)
      }
      app.run()
      return
    }
    let wanted = arguments[1]
    let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 15 : 15

    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 393, height: 852), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.title = "device-mirror"
    let view = NSView(frame: window.contentView!.bounds)
    view.wantsLayer = true
    view.autoresizingMask = [.width, .height]
    window.contentView = view
    let layer = CALayer()
    layer.frame = view.bounds
    layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    layer.backgroundColor = NSColor.black.cgColor
    view.layer!.addSublayer(layer)
    window.orderFrontRegardless()

    // 看画面落在图层的哪里：contents 还是子图层
    var ticks = 0
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
      ticks += 1
      let contents = layer.contents.map { String(describing: type(of: $0)) } ?? "nil"
      let sublayers = layer.sublayers?.map { "\(type(of: $0)) \($0.bounds.size)" } ?? []
      log("图层：contents=\(contents) sublayers=\(sublayers)")
      if ticks >= 5 { timer.invalidate() }
    }

    Task {
      let all = await devices()
      for device in all { log("设备：\(device.id) \(device.description)") }
      guard let device = all.first(where: { $0.id.uuidString.hasPrefix(wanted.uppercased()) || $0.description.localizedCaseInsensitiveContains(wanted) }) else {
        log("没找到 \(wanted)")
        exit(1)
      }
      log("用 \(device.id)")
      let session = MediaStreamSession(clientSessionID: UUID())
      do {
        let configuration = VideoStreamConfiguration.receiveMirroredPrimary(layer: layer, timeout: 30)
        log("建视频流…")
        let stream = try await session.makeVideoStream(withConfiguration: configuration, fromRemoteDevice: device)
        log("拿到视频流")
        await receive(stream)
      } catch {
        log("建视频流出错：\(error)")
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
      log("到时退出")
      exit(0)
    }
    app.run()
  }
}
