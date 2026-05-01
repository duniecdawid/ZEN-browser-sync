import Foundation
import Compression

// MARK: - Zen Session Decodable Types

struct ZenSessionData: Decodable {
    let spaces: [ZenSpace]?
    let tabs: [ZenTab]?
    let folders: [ZenFolder]?
}

struct ZenFolder: Decodable {
    let id: String
    let name: String?
    let workspaceId: String?
    let userIcon: String?
}

struct ZenSpace: Decodable {
    let uuid: String
    let name: String?
    let icon: String?
    let position: Int?
    let theme: ZenTheme?
}

struct ZenTheme: Decodable {
    let gradientColors: [ZenGradientColor]?
    let opacity: Double?
}

struct ZenGradientColor: Decodable {
    let c: FlexibleColor
    let isPrimary: Bool?
}

struct FlexibleColor: Decodable {
    let r: Int, g: Int, b: Int

    init(r: Int, g: Int, b: Int) {
        self.r = r; self.g = g; self.b = b
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let arr = try? container.decode([Int].self), arr.count >= 3 {
            r = arr[0]; g = arr[1]; b = arr[2]
        } else if let hex = try? container.decode(String.self) {
            let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst().prefix(6)) : String(hex.prefix(6))
            let val = UInt32(cleaned, radix: 16) ?? 0x808080
            r = Int((val >> 16) & 0xFF)
            g = Int((val >> 8) & 0xFF)
            b = Int(val & 0xFF)
        } else {
            r = 128; g = 128; b = 128
        }
    }

    var cssRGB: String { "rgb(\(r),\(g),\(b))" }
    func cssRGBA(_ alpha: Double) -> String { "rgba(\(r),\(g),\(b),\(alpha))" }
}

struct ZenTab: Decodable {
    let entries: [ZenTabEntry]?
    let pinned: Bool?
    let image: String?
    let zenWorkspace: String?
    let zenEssential: Bool?
    let zenSyncId: String?
    let groupId: String?

    var workspaceId: String? { zenWorkspace }
    var isEssential: Bool { zenEssential == true }

    var currentURL: String? {
        guard let entries = entries, !entries.isEmpty else { return nil }
        return entries.last?.url
    }

    var currentTitle: String? {
        guard let entries = entries, !entries.isEmpty else { return nil }
        return entries.last?.title
    }
}

struct ZenTabEntry: Decodable {
    let url: String?
    let title: String?
}

// MARK: - Display Types

struct WorkspaceLinks {
    let name: String
    let icon: String
    let primaryColor: FlexibleColor
    let secondaryColor: FlexibleColor
    let opacity: Double
    let essentials: [LinkItem]
    let pinned: [LinkItem]
    let folders: [LinkFolder]
}

struct LinkFolder {
    let name: String
    let links: [LinkItem]
}

struct LinkItem {
    let title: String
    let url: String
    let domain: String
    let faviconURL: String?
}

// MARK: - Link Exporter

final class LinkExporter {

    static let zenLinksFolder: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/ZenLinks")
    }()

    // MARK: - Public

    static func exportLinks() {
        guard let profileURL = SyncEngine.zenProfilePath() else {
            Logger.shared.log("LinkExporter: no profile found, skipping", level: .warning)
            return
        }
        guard let session = parseZenSessions(profileURL: profileURL) else {
            Logger.shared.log("LinkExporter: could not parse zen-sessions, skipping", level: .warning)
            return
        }
        let workspaces = buildWorkspaceLinks(from: session)
        let html = generateHTML(workspaces: workspaces)
        writeLinksPage(html)
        Logger.shared.log("LinkExporter: exported \(workspaces.count) workspace(s) to ZenLinks/index.html")
    }

    // MARK: - LZ4 Decompression

    private static let mozLz4Magic: [UInt8] = [0x6D, 0x6F, 0x7A, 0x4C, 0x7A, 0x34, 0x30, 0x00]

    static func decompressJsonlz4(at url: URL) -> Data? {
        guard let fileData = try? Data(contentsOf: url) else { return nil }
        guard fileData.count > 12 else { return nil }

        let magic = [UInt8](fileData.prefix(8))
        guard magic == mozLz4Magic else {
            Logger.shared.log("LinkExporter: invalid mozLz4 magic", level: .warning)
            return nil
        }

        let uncompressedSize: UInt32 = fileData.withUnsafeBytes { buf in
            buf.load(fromByteOffset: 8, as: UInt32.self)
        }

        guard uncompressedSize > 0, uncompressedSize < 100_000_000 else {
            Logger.shared.log("LinkExporter: suspicious uncompressed size: \(uncompressedSize)", level: .warning)
            return nil
        }

        let compressedPayload = fileData.dropFirst(12)
        let destSize = Int(uncompressedSize)
        let destBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destSize)
        defer { destBuffer.deallocate() }

        let decodedSize = compressedPayload.withUnsafeBytes { srcBuf -> Int in
            guard let srcPtr = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(
                destBuffer, destSize,
                srcPtr, srcBuf.count,
                nil,
                COMPRESSION_LZ4_RAW
            )
        }

        guard decodedSize > 0 else {
            Logger.shared.log("LinkExporter: LZ4 decompression failed", level: .warning)
            return nil
        }

        return Data(bytes: destBuffer, count: decodedSize)
    }

    // MARK: - Parsing

    static func parseZenSessions(profileURL: URL) -> ZenSessionData? {
        let sessionFile = profileURL.appendingPathComponent("zen-sessions.jsonlz4")
        guard FileManager.default.fileExists(atPath: sessionFile.path) else {
            Logger.shared.log("LinkExporter: zen-sessions.jsonlz4 not found", level: .warning)
            return nil
        }
        guard let jsonData = decompressJsonlz4(at: sessionFile) else { return nil }

        do {
            return try JSONDecoder().decode(ZenSessionData.self, from: jsonData)
        } catch {
            Logger.shared.log("LinkExporter: JSON decode failed: \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    // MARK: - Data Transformation

    static func buildWorkspaceLinks(from session: ZenSessionData) -> [WorkspaceLinks] {
        let spaces = session.spaces ?? []
        let tabs = session.tabs ?? []
        let sessionFolders = session.folders ?? []

        let folderMap = Dictionary(uniqueKeysWithValues: sessionFolders.compactMap { f -> (String, ZenFolder)? in
            return (f.id, f)
        })

        let relevantTabs = tabs.filter { tab in
            guard let url = tab.currentURL, !url.isEmpty else { return false }
            if url.hasPrefix("about:") || url.hasPrefix("moz-extension:") { return false }
            return tab.pinned == true || tab.isEssential
        }

        let globalEssentials = relevantTabs.filter { $0.workspaceId == nil && $0.isEssential }

        var tabsByWorkspace: [String: [ZenTab]] = [:]
        for tab in relevantTabs where tab.workspaceId != nil {
            tabsByWorkspace[tab.workspaceId!, default: []].append(tab)
        }

        let defaultColors = [
            FlexibleColor(r: 88, g: 86, b: 214),
            FlexibleColor(r: 52, g: 199, b: 89),
            FlexibleColor(r: 255, g: 159, b: 10),
            FlexibleColor(r: 255, g: 55, b: 95),
            FlexibleColor(r: 90, g: 200, b: 250),
            FlexibleColor(r: 175, g: 82, b: 222),
            FlexibleColor(r: 255, g: 204, b: 0),
        ]

        let globalItems = globalEssentials.compactMap { tab -> LinkItem? in
            guard let url = tab.currentURL else { return nil }
            let title = tab.currentTitle ?? domainFrom(url)
            let favicon = tabFavicon(tab, url: url)
            return LinkItem(title: title, url: url, domain: domainFrom(url), faviconURL: favicon)
        }

        var result: [WorkspaceLinks] = []
        let sortedSpaces = spaces.sorted { ($0.position ?? 999) < ($1.position ?? 999) }

        for (index, space) in sortedSpaces.enumerated() {
            let wsTabs = tabsByWorkspace[space.uuid] ?? []

            let gradientColors = space.theme?.gradientColors ?? []
            let primary = gradientColors.first(where: { $0.isPrimary == true })?.c
                ?? gradientColors.first?.c
                ?? defaultColors[index % defaultColors.count]
            let secondary = gradientColors.count > 1
                ? gradientColors[1].c
                : FlexibleColor(r: primary.r / 2, g: primary.g / 2, b: primary.b / 2)
            let opacity = space.theme?.opacity ?? 0.35

            var essentials: [LinkItem] = globalItems
            var pinned: [LinkItem] = []
            var folderTabs: [String: [LinkItem]] = [:]

            for tab in wsTabs {
                guard let url = tab.currentURL else { continue }
                let title = tab.currentTitle ?? domainFrom(url)
                let favicon = tabFavicon(tab, url: url)
                let item = LinkItem(title: title, url: url, domain: domainFrom(url), faviconURL: favicon)

                if let gid = tab.groupId, folderMap[gid] != nil {
                    folderTabs[gid, default: []].append(item)
                } else if tab.isEssential {
                    essentials.append(item)
                } else {
                    pinned.append(item)
                }
            }

            let folders = folderTabs.compactMap { (folderId, links) -> LinkFolder? in
                let name = folderMap[folderId]?.name ?? "Folder"
                return links.isEmpty ? nil : LinkFolder(name: name, links: links)
            }

            if essentials.isEmpty && pinned.isEmpty && folders.isEmpty { continue }

            result.append(WorkspaceLinks(
                name: space.name ?? "Workspace",
                icon: resolveIcon(space.icon),
                primaryColor: primary,
                secondaryColor: secondary,
                opacity: opacity,
                essentials: essentials,
                pinned: pinned,
                folders: folders
            ))
        }

        return result
    }

    private static func resolveIcon(_ icon: String?) -> String {
        guard let icon = icon, !icon.isEmpty else { return "📁" }
        if icon.hasPrefix("chrome://") {
            let name = URL(string: icon)?.deletingPathExtension().lastPathComponent ?? ""
            return zenIconSVG[name] ?? "📁"
        }
        return icon
    }

    private static let zenIconSVG: [String: String] = [
        "airplane": "✈️", "american-football": "🏈", "baseball": "⚾", "basket": "🧺",
        "bed": "🛏️", "bell": "🔔", "book": "📖", "bookmark": "🔖", "briefcase": "💼",
        "brush": "🖌️", "bug": "🐛", "build": "🔧", "cafe": "☕", "call": "📞",
        "card": "💳", "chat": "💬", "checkbox": "☑️", "circle": "⭕", "cloud": "☁️",
        "code": "💻", "coins": "🪙", "construct": "🏗️", "cutlery": "🍴", "egg": "🥚",
        "extension-puzzle": "🧩", "eye": "👁️", "fast-food": "🍔", "fish": "🐟",
        "flag": "🚩", "flame": "🔥", "flask": "🧪", "folder": "📁",
        "game-controller": "🎮", "globe": "🌍", "globe-1": "🌐", "grid-2x2": "⊞",
        "grid-3x3": "▦", "heart": "❤️", "ice-cream": "🍦", "image": "🖼️",
        "inbox": "📥", "key": "🔑", "layers": "📚", "leaf": "🍃", "lightning": "⚡",
        "location": "📍", "lock-closed": "🔒", "logo-github": "🐙", "logo-rss": "📡",
        "logo-usd": "💲", "mail": "✉️", "map": "🗺️", "megaphone": "📢", "moon": "🌙",
        "music": "🎵", "navigate": "🧭", "nuclear": "☢️", "page": "📄",
        "palette": "🎨", "paw": "🐾", "people": "👥", "pizza": "🍕", "planet": "🪐",
        "present": "🎁", "rocket": "🚀", "school": "🏫", "shapes": "🔶", "shirt": "👕",
        "skull": "💀", "square": "⬜", "squares": "🟦", "star": "⭐", "star-1": "🌟",
        "stats-chart": "📊", "sun": "☀️", "tada": "🎉", "terminal": "🖥️",
        "ticket": "🎫", "time": "⏰", "trash": "🗑️", "triangle": "🔺", "video": "🎬",
        "volume-high": "🔊", "wallet": "👛", "warning": "⚠️", "water": "💧", "weight": "🏋️",
    ]

    private static func tabFavicon(_ tab: ZenTab, url: String) -> String? {
        if let img = tab.image, !img.isEmpty, !img.hasPrefix("chrome://") {
            return img
        }
        return faviconURL(for: url)
    }

    // MARK: - HTML Generation

    static func generateHTML(workspaces: [WorkspaceLinks]) -> String {
        if workspaces.isEmpty {
            return emptyStateHTML()
        }

        let pagesHTML = workspaces.enumerated().map { (_, ws) in
            buildPageHTML(ws)
        }.joined(separator: "\n")

        let tabsHTML = workspaces.enumerated().map { (i, ws) in
            "<button class=\"tab\(i == 0 ? " active" : "")\" data-index=\"\(i)\"><span class=\"tab-icon\">\(escapeHTML(ws.icon))</span><span class=\"tab-label\">\(escapeHTML(ws.name))</span></button>"
        }.joined(separator: "\n      ")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover, user-scalable=no">
          <meta name="apple-mobile-web-app-capable" content="yes">
          <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
          <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🧘</text></svg>">
          <link rel="apple-touch-icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' rx='22' fill='%230a0a0f'/><text x='50' y='58' text-anchor='middle' dominant-baseline='middle' font-size='55'>🧘</text></svg>">
          <title>Zen Links</title>
          <style>\(cssStyles())</style>
        </head>
        <body>
          <div class="slider" id="slider">
        \(pagesHTML)
          </div>
          <nav class="tab-bar" id="tabBar">
              \(tabsHTML)
          </nav>
          <script>\(jsScript())</script>
        </body>
        </html>
        """
    }

    // MARK: - File Output

    static func writeLinksPage(_ html: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: zenLinksFolder, withIntermediateDirectories: true)
            let outputFile = zenLinksFolder.appendingPathComponent("index.html")
            try html.write(to: outputFile, atomically: true, encoding: .utf8)
        } catch {
            Logger.shared.log("LinkExporter: failed to write HTML: \(error.localizedDescription)", level: .warning)
        }
    }

    // MARK: - Helpers

    private static func domainFrom(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    private static func faviconURL(for urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host else { return nil }
        return "https://www.google.com/s2/favicons?domain=\(host)&sz=64"
    }

    private static func escapeHTML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func buildPageHTML(_ ws: WorkspaceLinks) -> String {
        let bg = "background: linear-gradient(145deg, \(ws.primaryColor.cssRGBA(ws.opacity)) 0%, \(ws.secondaryColor.cssRGBA(ws.opacity * 0.6)) 50%, #0a0a0f 100%);"
        let totalLinks = ws.essentials.count + ws.pinned.count + ws.folders.reduce(0) { $0 + $1.links.count }

        let hasMultipleSections = (!ws.essentials.isEmpty ? 1 : 0) + (!ws.pinned.isEmpty ? 1 : 0) + ws.folders.count > 1
        var sections = ""
        if !ws.essentials.isEmpty {
            let items = ws.essentials.map { linkItemHTML($0, isEssential: false) }.joined(separator: "\n")
            sections += "      <ul class=\"links-list\">\n\(items)\n      </ul>\n"
        }
        for folder in ws.folders {
            let items = folder.links.map { linkItemHTML($0, isEssential: false) }.joined(separator: "\n")
            sections += "      <details class=\"folder\">\n        <summary class=\"folder-header\"><span class=\"folder-chevron\"></span>📂 \(escapeHTML(folder.name)) <span class=\"folder-count\">\(folder.links.count)</span></summary>\n        <ul class=\"links-list\">\n\(items)\n        </ul>\n      </details>\n"
        }
        if !ws.pinned.isEmpty {
            let items = ws.pinned.map { linkItemHTML($0, isEssential: false) }.joined(separator: "\n")
            if hasMultipleSections { sections += "      <div class=\"section-label\">Pinned</div>\n" }
            sections += "      <ul class=\"links-list\">\n\(items)\n      </ul>\n"
        }

        return """
            <div class="page" style="\(bg)">
              <div class="workspace-header">
                <span class="workspace-icon">\(escapeHTML(ws.icon))</span>
                <div class="workspace-name">\(escapeHTML(ws.name))</div>
                <div class="workspace-count">\(totalLinks) link\(totalLinks == 1 ? "" : "s")</div>
              </div>
        \(sections)    </div>
        """
    }

    private static func linkItemHTML(_ item: LinkItem, isEssential: Bool) -> String {
        let letter = String(item.domain.first(where: { $0.isLetter })?.uppercased() ?? "?")
        let essentialBadge = isEssential ? "\n          <span class=\"link-essential\">ESS</span>" : ""

        let faviconHTML: String
        if let fav = item.faviconURL {
            faviconHTML = """
                      <img class="link-favicon" src="\(escapeHTML(fav))" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'" alt="">
                      <div class="link-favicon-fallback" style="display:none">\(letter)</div>
            """
        } else {
            faviconHTML = "          <div class=\"link-favicon-fallback\">\(letter)</div>"
        }

        return """
                <li><a href="\(escapeHTML(item.url))" class="link-item">
        \(faviconHTML)
                  <div class="link-text">
                    <div class="link-title">\(escapeHTML(item.title))</div>
                    <div class="link-domain">\(escapeHTML(item.domain))</div>
                  </div>\(essentialBadge)
                </a></li>
        """
    }

    private static func emptyStateHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
          <meta name="apple-mobile-web-app-capable" content="yes">
          <title>Zen Links</title>
          <style>
            body { margin: 0; height: 100vh; display: flex; align-items: center; justify-content: center;
                   font-family: -apple-system, system-ui, sans-serif; background: #0a0a0f; color: rgba(255,255,255,0.5); }
            .empty { text-align: center; }
            .empty-icon { font-size: 48px; margin-bottom: 16px; }
            .empty-text { font-size: 16px; }
          </style>
        </head>
        <body>
          <div class="empty">
            <div class="empty-icon">🧘</div>
            <div class="empty-text">No pinned links found in Zen Browser</div>
          </div>
        </body>
        </html>
        """
    }

    private static func cssStyles() -> String {
        return """

            *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
            html, body { height: 100%; overflow: hidden; font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', system-ui, sans-serif; -webkit-font-smoothing: antialiased; background: #0a0a0f; }
            .slider { display: flex; height: 100%; overflow-x: scroll; scroll-snap-type: x mandatory; -webkit-overflow-scrolling: touch; scrollbar-width: none; }
            .slider::-webkit-scrollbar { display: none; }
            .page { min-width: 100vw; height: 100%; overflow-y: auto; -webkit-overflow-scrolling: touch; scroll-snap-align: start; scroll-snap-stop: always; padding: env(safe-area-inset-top, 48px) 20px 80px 20px; }
            .workspace-header { text-align: center; padding: 20px 0 24px; }
            .workspace-icon { font-size: 36px; display: block; margin-bottom: 8px; }
            .workspace-name { font-size: 22px; font-weight: 700; color: rgba(255,255,255,0.95); letter-spacing: -0.3px; }
            .workspace-count { font-size: 13px; color: rgba(255,255,255,0.45); margin-top: 4px; }
            .section-label { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 1px; color: rgba(255,255,255,0.35); padding: 16px 4px 8px; }
            .links-list { list-style: none; }
            .link-item { display: flex; align-items: center; padding: 14px 16px; margin: 6px 0; background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.06); border-radius: 14px; text-decoration: none; color: white; backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); transition: background 0.2s, transform 0.15s; -webkit-tap-highlight-color: transparent; }
            .link-item:active { background: rgba(255,255,255,0.15); transform: scale(0.98); }
            .link-favicon { width: 28px; height: 28px; border-radius: 7px; margin-right: 14px; flex-shrink: 0; background: rgba(255,255,255,0.1); object-fit: cover; }
            .link-favicon-fallback { width: 28px; height: 28px; border-radius: 7px; margin-right: 14px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; font-size: 14px; font-weight: 600; color: rgba(255,255,255,0.8); background: rgba(255,255,255,0.1); }
            .link-text { flex: 1; min-width: 0; }
            .link-title { font-size: 15px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: rgba(255,255,255,0.92); }
            .link-domain { font-size: 12px; color: rgba(255,255,255,0.35); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .link-essential { font-size: 9px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; padding: 3px 6px; border-radius: 4px; background: rgba(255,255,255,0.12); color: rgba(255,255,255,0.5); margin-left: 10px; flex-shrink: 0; }
            .folder { margin: 12px 0; }
            .folder-header { display: flex; align-items: center; padding: 10px 14px; font-size: 14px; font-weight: 600; color: rgba(255,255,255,0.7); background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; cursor: pointer; list-style: none; -webkit-tap-highlight-color: transparent; }
            .folder-header::-webkit-details-marker { display: none; }
            .folder-chevron { display: inline-block; width: 0; height: 0; border-left: 5px solid rgba(255,255,255,0.5); border-top: 4px solid transparent; border-bottom: 4px solid transparent; margin-right: 10px; transition: transform 0.2s; }
            .folder[open] .folder-chevron { transform: rotate(90deg); }
            .folder-count { margin-left: auto; font-size: 12px; font-weight: 400; color: rgba(255,255,255,0.3); }
            .folder .links-list { padding-left: 8px; border-left: 2px solid rgba(255,255,255,0.08); margin-left: 6px; margin-top: 4px; }
            .tab-bar { position: fixed; bottom: 0; left: 0; right: 0; display: flex; z-index: 10; background: rgba(10,10,15,0.85); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); border-top: 1px solid rgba(255,255,255,0.08); padding-bottom: env(safe-area-inset-bottom, 0px); }
            .tab { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 2px; padding: 8px 2px 6px; border: none; background: none; color: rgba(255,255,255,0.35); cursor: pointer; -webkit-tap-highlight-color: transparent; transition: color 0.2s; min-width: 0; }
            .tab.active { color: rgba(255,255,255,0.95); }
            .tab-icon { font-size: 20px; line-height: 1; }
            .tab-label { font-size: 9px; font-weight: 500; letter-spacing: 0.2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; font-family: -apple-system, system-ui, sans-serif; }

        """
    }

    private static func jsScript() -> String {
        return """

            var slider = document.getElementById('slider');
            var tabs = document.querySelectorAll('.tab');

            function updateTabs() {
              var idx = Math.round(slider.scrollLeft / window.innerWidth);
              tabs.forEach(function(t, i) { t.classList.toggle('active', i === idx); });
            }

            slider.addEventListener('scroll', updateTabs, { passive: true });

            tabs.forEach(function(tab) {
              tab.addEventListener('click', function() {
                slider.scrollTo({ left: parseInt(tab.dataset.index) * window.innerWidth, behavior: 'smooth' });
              });
            });

            document.addEventListener('keydown', function(e) {
              var idx = Math.round(slider.scrollLeft / window.innerWidth);
              if (e.key === 'ArrowRight') slider.scrollTo({ left: (idx + 1) * window.innerWidth, behavior: 'smooth' });
              if (e.key === 'ArrowLeft') slider.scrollTo({ left: (idx - 1) * window.innerWidth, behavior: 'smooth' });
            });

        """
    }
}
