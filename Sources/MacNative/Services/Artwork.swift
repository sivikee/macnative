import Foundation

enum Artwork {
    /// Finds artwork for a custom game by matching its title against the public Steam store search.
    static func searchSteam(title: String) async -> (cover: URL, hero: URL)? {
        var c = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        c.queryItems = [.init(name: "term", value: title), .init(name: "cc", value: "us"), .init(name: "l", value: "english")]
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["items"] as? [[String: Any]])?.first,
              let id = first["id"] as? Int else { return nil }
        return (SteamService.coverURL(String(id)), SteamService.heroURL(String(id)))
    }
}
