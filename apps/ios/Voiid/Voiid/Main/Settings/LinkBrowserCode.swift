import Foundation

/// Accept only Voiid's companion QR payload. Never follow an arbitrary scanned URL.
enum LinkBrowserCode {
    static func token(from raw: String) -> String? {
        guard raw.utf8.count < 256,
              let url = URLComponents(string: raw),
              url.scheme == "voiid", url.host == "link",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty, url.fragment == nil,
              let items = url.queryItems, items.count == 1,
              items[0].name == "token", let token = items[0].value, token.utf8.count == 32,
              token.range(of: "^[A-Za-z0-9_-]{32}$", options: .regularExpression) != nil
        else { return nil }
        return token
    }
}
