import Foundation

/// 原生账号使用显式 Bearer；不能继承网页登录 Cookie，否则重新登录会触发来源校验。
nonisolated enum AccountHTTP {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }
}
