import Foundation

/// 每份预览独立持有场景进度。按接口和资源轮换，读取现场状态不会改变下一次集成的结果。
/// 未提供的接口明确拒绝，不回退到真实网络。
final class SampleGitTransport {
    private var positions: [String: Int] = [:]
    private var projectAppearances: [String: ProjectAppearance] = [:]

    var account: HTTPTransport { HTTPTransport(send: accountResponse) }
    var worker: HTTPTransport { HTTPTransport(send: workerResponse) }

    private func accountResponse(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        switch (method, path) {
        case ("GET", "/api/git/accounts"):
            return try response(request, [
                ["host": "github.com", "account": "sainner", "createdAt": 0],
                ["host": "gitlab.com", "account": "oauth2", "createdAt": 0],
            ])
        case ("POST", "/api/git/accounts/github.com/device"):
            return try response(request, ["flow": "sample", "userCode": "WDJB-MJHT",
                                          "verificationURI": "https://github.com/login/device", "interval": 5])
        case ("POST", "/api/git/accounts/github.com/device/sample"):
            return try response(request, ["status": "pending"])
        case ("GET", "/api/git/accounts/github.com/repos"):
            return try response(request, [
                ["fullName": "sainner/thesis", "url": "https://github.com/sainner/thesis.git", "private": true],
                ["fullName": "sainner/kite-notes", "url": "https://github.com/sainner/kite-notes.git", "private": false],
            ])
        case ("GET", "/api/projects"):
            return try response(request, [
                ["id": "sample-hosted", "name": "论文草稿", "remote": "hs.sainner.top/git/sample-hosted",
                 "url": "https://hs.sainner.top/git/sample-hosted.git", "hosted": true, "createdAt": 0],
                ["id": "sample", "name": "harness", "remote": "github.com/sample/harness",
                 "url": "https://github.com/sample/harness.git", "hosted": false, "createdAt": 0],
            ])
        default:
            let parts = path.split(separator: "/")
            if method == "PUT", parts.count == 4, parts.prefix(2) == ["api", "projects"], parts.last == "appearance",
               let data = request.httpBody, let body = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                let id = String(parts[2])
                var appearance = projectAppearances[id] ?? ProjectAppearance()
                if let icon = body["icon"] { appearance.icon = icon }
                if let color = body["color"] { appearance.color = color }
                projectAppearances[id] = appearance
                return try response(request, ["id": .string(id), "icon": .string(appearance.icon), "color": .string(appearance.color)])
            }
            if ["PUT", "DELETE"].contains(method), parts.count == 4, parts.prefix(3) == ["api", "git", "accounts"] {
                return try response(request, ["error": "预览数据不能修改绑定"], status: 409)
            }
            if method == "POST", parts.count == 4, parts.prefix(2) == ["api", "projects"], parts.last == "migrate" {
                return try response(request, ["error": "预览数据不能迁移"], status: 409)
            }
            return try unsupported(request)
        }
    }

    private func workerResponse(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let parts = request.url!.path.split(separator: "/")
        let method = request.httpMethod ?? "GET"
        guard parts.count == 3 else { return try unsupported(request) }
        switch (method, parts[0], parts[2]) {
        case ("POST", "workspaces", "adopt"):
            return try response(request, next([
                ["status": "adopted", "commit": "8dc7ad4", "push": ["status": "pushed"]],
                ["status": "adopted", "commit": "8dc7ad4", "push": ["status": "failed", "message": "推送失败：连不上 github.com"]],
                ["status": "conflict", "files": ["src/main.ts", "README.md"]],
            ], for: request))
        case ("GET", "checkouts", "sync"):
            return try response(request, next([
                ["branch": "main", "dirty": true, "ahead": 0, "behind": 0],
                ["branch": "main", "dirty": false, "ahead": 2, "behind": 0],
                ["branch": "main", "dirty": true, "ahead": 1, "behind": 3],
                ["branch": "main", "dirty": false, "ahead": .null, "behind": .null],
            ], for: request))
        case ("POST", "checkouts", "push"):
            return try response(request, ["error": "远程有新的提交，和现场的改动分叉了。请新建工作区，在工作区里集成"], status: 409)
        case ("POST", "workspaces", "archive"):
            return try response(request, ["error": "预览数据不能归档"], status: 409)
        default:
            return try unsupported(request)
        }
    }

    private func next(_ values: [JSON], for request: URLRequest) -> JSON {
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        let index = positions[key, default: 0]
        positions[key] = (index + 1) % values.count
        return values[index]
    }

    private func unsupported(_ request: URLRequest) throws -> (Data, URLResponse) {
        try response(request, ["error": "预览尚未提供这个操作的样本"], status: 501)
    }

    private func response(_ request: URLRequest, _ body: JSON, status: Int = 200) throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (try JSONEncoder().encode(body), response)
    }
}
