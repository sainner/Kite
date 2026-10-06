import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private struct User: Decodable { let id: String; let email: String }
private struct Login: Decodable { let token: String; let user: User }
private struct Account: Decodable { let user: User }
private struct Reply {
    let data: Data
    let response: HTTPURLResponse
    var status: Int { response.statusCode }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}

private func request(_ session: URLSession, _ base: URL, _ phase: String, _ method: String, _ path: String,
                     body: [String: String]? = nil, token: String? = nil, origin: String? = nil) async throws -> Reply {
    var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
    request.httpMethod = method
    request.timeoutInterval = 5
    request.setValue(phase, forHTTPHeaderField: "X-Kite-Verification-Phase")
    if let body {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw Failure(description: "\(phase) 不是 HTTP 响应") }
    return Reply(data: data, response: response)
}

private func login(_ reply: Reply, _ phase: String) throws -> Login {
    try require(reply.status == 200, "\(phase) 登录失败：HTTP \(reply.status)")
    return try JSONDecoder().decode(Login.self, from: reply.data)
}

private func identity(_ session: URLSession, _ base: URL, _ phase: String, _ login: Login) async throws {
    let reply = try await request(session, base, phase, "GET", "/api/account", token: login.token)
    try require(reply.status == 200, "\(phase) 显式令牌未取得身份：HTTP \(reply.status)")
    let account = try JSONDecoder().decode(Account.self, from: reply.data)
    try require(account.user.id == login.user.id && account.user.email == login.user.email, "\(phase) 身份受残留 Cookie 污染")
}

@main
struct AccountHTTPVerify {
    static func main() async throws {
        guard CommandLine.arguments.count == 3, let base = URL(string: CommandLine.arguments[1]) else {
            throw Failure(description: "需要账号服务 URL 与临时 Foundation home")
        }
        try require(NSHomeDirectory() == CommandLine.arguments[2], "Foundation Cookie 存储未隔离到临时目录")
        let storage = HTTPCookieStorage.shared
        defer { storage.cookies(for: base)?.forEach { storage.deleteCookie($0) } }
        let password = "Kite-native-cookie-regression-2026"
        let emailA = "a-\(UUID().uuidString.lowercased())@kite.test"
        let emailB = "b-\(UUID().uuidString.lowercased())@kite.test"
        let credentials = ["email": emailA, "password": password]

        // 真实回归：默认 URLSession 接收登录 Cookie 后，无 Origin 的下一次原生登录被 Better Auth 拒绝。
        let seed = try await request(.shared, base, "legacy-seed", "POST", "/api/auth/sign-up/email",
                                     body: ["email": emailA, "password": password, "name": "旧会话"])
        let old = try login(seed, "旧会话注册")
        let saved = storage.cookies(for: base) ?? []
        try require(!saved.isEmpty, "真实登录响应没有在 Foundation shared 中留下 Cookie")
        let missing = try await request(.shared, base, "legacy-missing-origin", "POST", "/api/auth/sign-in/email", body: credentials)
        try require(missing.status == 403, "携带残留 Cookie 的无 Origin 请求未被拒绝：HTTP \(missing.status)")
        try require(String(data: missing.data, encoding: .utf8)?.contains("Missing or null Origin") == true,
                    "未复现 Missing or null Origin")
        let forged = try await request(.shared, base, "legacy-forged-origin", "POST", "/api/auth/sign-in/email",
                                       body: credentials, origin: "https://untrusted.example.invalid")
        try require(forged.status == 403, "伪造 Origin 的 Cookie 请求未被拒绝：HTTP \(forged.status)")

        let session = AccountHTTP.makeSession()
        defer { session.invalidateAndCancel() }
        let first = try login(try await request(session, base, "native-login", "POST", "/api/auth/sign-in/email",
                                                body: credentials), "隔离会话")
        try require(first.user.id == old.user.id && first.token != old.token, "首次原生登录未创建独立会话")
        try await identity(session, base, "native-identity-a", first)
        let anonymous = try await request(session, base, "native-without-token", "GET", "/api/account")
        try require(anonymous.status == 401, "登录后的请求偷偷使用了响应 Cookie")

        let second = try login(try await request(session, base, "native-signup-b", "POST", "/api/auth/sign-up/email",
                                                 body: ["email": emailB, "password": password, "name": "第二账号"]), "第二账号")
        try await identity(session, base, "native-identity-b", second)
        try await identity(session, base, "native-identity-a-after-b", first)
        let logout = try await request(session, base, "native-logout", "POST", "/api/auth/sign-out", body: [:], token: first.token)
        try require(logout.status == 200, "原生注销失败：HTTP \(logout.status)")
        let revoked = try await request(session, base, "native-revoked-token", "GET", "/api/account", token: first.token)
        try require(revoked.status == 401, "注销后旧显式令牌仍有效")
        try await identity(session, base, "native-identity-b-after-logout", second)
        let again = try login(try await request(session, base, "native-relogin", "POST", "/api/auth/sign-in/email",
                                                body: credentials), "注销后重登")
        try require(again.user.id == first.user.id && again.token != first.token, "重登未取得新会话")
        try await identity(session, base, "native-identity-relogin", again)
        let finalAnonymous = try await request(session, base, "native-final-without-token", "GET", "/api/account")
        try require(finalAnonymous.status == 401, "重登后无令牌请求仍取得了 Cookie 身份")
        try require(session.configuration.httpCookieStorage?.cookies(for: base)?.isEmpty ?? true,
                    "原生会话接收并保存了认证 Cookie")
        let fingerprint: ([HTTPCookie]) -> [String] = { $0.map { "\($0.name):\($0.value)" }.sorted() }
        try require(fingerprint(storage.cookies(for: base) ?? []) == fingerprint(saved), "原生登录或注销更改了 shared Cookie 存储")
        print("原生账号 HTTP 合同通过：残留 Cookie 复现、来源校验保留、Bearer 身份隔离及注销重登")
    }
}
