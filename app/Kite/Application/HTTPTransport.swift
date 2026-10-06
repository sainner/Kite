import Foundation

/// 可替换的请求入口；客户端仍负责构造请求、验证状态和解码响应。
struct HTTPTransport: Equatable {
    private let identity = UUID()
    let send: (URLRequest) async throws -> (Data, URLResponse)

    init(send: @escaping (URLRequest) async throws -> (Data, URLResponse)) { self.send = send }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }
}
