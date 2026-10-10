import SwiftUI

// Bookmarks under the pins, the way Arc and Dia keep them (Connor's fork).
//
// Each space shows one top-level bookmarks folder in the column, between
// the pinned tabs and the tabs that come and go: the one chosen in the
// space's menu (Bookmarks in Sidebar), or, until one is chosen, the folder
// named as the space is — "LOA" for LOA. Folders open in place and stay
// open across launches. A bookmark goes to the tab in this space that
// already shows it, and opens one when none does, so a bookmark behaves
// like a tab you keep rather than a link that piles up copies.

@MainActor
final class Shelf: ObservableObject {
    static let shared = Shelf()

    private static let key = "shelf.open"

    /// The folders opened in the column, by id.
    @Published private(set) var open: Set<UUID>

    private init() {
        open = Set((Store.settings.stringArray(forKey: Shelf.key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    func toggle(_ id: UUID) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
        Store.settings.set(open.map(\.uuidString), forKey: Shelf.key)
    }

    /// One row of the shelf: a folder or a bookmark, and how deep it sits.
    struct Line: Identifiable {
        let node: Bookmark
        let depth: Int
        var id: UUID { node.id }
    }

    /// The folder a space shows, if any.
    static func folder(for space: Space, in roots: [Bookmark]) -> Bookmark? {
        let folders = roots.filter(\.isFolder)
        switch space.shelf {
        case "none":
            return nil
        case let chosen?:
            return folders.first { $0.id.uuidString == chosen }
        case nil:
            return folders.first { $0.title.localizedCaseInsensitiveCompare(space.name) == .orderedSame }
        }
    }

    /// The rows as drawn: the folder's contents, and the contents of every
    /// folder opened inside it.
    func lines(_ folder: Bookmark?) -> [Line] {
        var out: [Line] = []
        func add(_ nodes: [Bookmark], depth: Int) {
            for node in nodes {
                out.append(Line(node: node, depth: depth))
                if node.isFolder, open.contains(node.id) { add(node.children ?? [], depth: depth + 1) }
            }
        }
        add(folder?.children ?? [], depth: 0)
        return out
    }

    /// The height the shelf takes in the column, for SideBar.rowsEnd.
    static func height(lines: Int) -> CGFloat {
        lines == 0 ? 0 : CGFloat(lines) * (SideBar.row + SideBar.gap) + below
    }

    /// The space and the line under the shelf, before the tabs.
    static let below: CGFloat = 13

    /// The same page, as far as a kept bookmark goes: the host without its
    /// www, the path without a trailing slash, and the query; never the
    /// scheme or what follows a #.
    nonisolated static func same(_ one: URL?, _ other: URL?) -> Bool {
        guard let one, let other else { return false }
        func key(_ url: URL) -> String {
            var host = url.host()?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            var path = url.path()
            while path.hasSuffix("/") { path.removeLast() }
            return host + path + (url.query().map { "?" + $0 } ?? "")
        }
        return key(one) == key(other)
    }
}

extension Browser {
    /// A bookmark from the shelf: its tab in this space, or a new one.
    func goToShelf(_ url: URL) {
        if let kept = tabs.first(where: { Shelf.same($0.pageAddress, url) }) {
            select(kept)
        } else {
            open(url, foreground: true, atEnd: true)
        }
    }
}

/// The shelf as it sits in the column. It watches the tab on screen rather
/// than the whole browser, so it isn't drawn again for every key typed in
/// the address field, yet still lights the right row when a page moves to
/// another address of its own accord.
struct ShelfView: View {
    let browser: Browser
    let space: Space
    let tab: Tab?
    let bookmarks: Bookmarks

    var body: some View {
        if let tab {
            ShelfOnScreen(browser: browser, space: space, tab: tab, bookmarks: bookmarks)
        } else {
            ShelfLines(browser: browser, space: space, here: nil, bookmarks: bookmarks)
        }
    }
}

private struct ShelfOnScreen: View {
    let browser: Browser
    let space: Space
    @ObservedObject var tab: Tab
    let bookmarks: Bookmarks

    var body: some View {
        ShelfLines(browser: browser, space: space, here: tab.pageAddress, bookmarks: bookmarks)
    }
}

private struct ShelfLines: View {
    let browser: Browser
    let space: Space
    /// The address of the page on screen.
    let here: URL?
    @ObservedObject var bookmarks: Bookmarks
    @ObservedObject private var shelf = Shelf.shared

    var body: some View {
        let lines = shelf.lines(Shelf.folder(for: space, in: bookmarks.roots))
        if !lines.isEmpty {
            VStack(spacing: SideBar.gap) {
                ForEach(lines) { line in
                    ShelfRow(browser: browser, line: line, open: shelf.open.contains(line.id),
                             live: !line.node.isFolder && Shelf.same(here, line.node.url.flatMap(URL.init(string:)))) {
                        if line.node.isFolder {
                            withAnimation(Motion.quick) { shelf.toggle(line.id) }
                        } else if let url = line.node.url.flatMap(URL.init(string:)) {
                            browser.goToShelf(url)
                        }
                    }
                }
            }
            .padding(.bottom, SideBar.gap)
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
                .padding(.horizontal, 10)
                .padding(.vertical, (Shelf.below - 1) / 2)
        }
    }
}

private struct ShelfRow: View {
    let browser: Browser
    let line: Shelf.Line
    let open: Bool
    /// The bookmark the tab on screen shows.
    let live: Bool
    let act: () -> Void

    @State private var hovering = false

    private var url: URL? { line.node.url.flatMap(URL.init(string:)) }

    var body: some View {
        HStack(spacing: 8) {
            if line.node.isFolder {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Palette.faint)
                    .frame(width: 15, height: 15)
            } else {
                Mark(icon: Favicons.shared.cached(line.node.site ?? ""),
                     letter: String((line.node.host ?? "•").prefix(1)).uppercased(), size: 15)
            }
            Text(line.node.title)
                .font(.system(size: 12.5, weight: line.node.isFolder ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(colour)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + CGFloat(line.depth) * 14)
        .padding(.trailing, 10)
        .frame(height: SideBar.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if live {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.wash)
            } else if hovering {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.hover)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture(perform: act)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.node.title)
        .accessibilityValue(line.node.isFolder ? (open ? "Open folder" : "Folder") : (line.node.host ?? ""))
        .accessibilityAddTraits(live ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, act)
        .onHover { hovering = $0 }
        .help(line.node.url ?? line.node.title)
        .contextMenu {
            if let url {
                Button("Open") { browser.goToShelf(url) }
                Button("Open in New Tab") { browser.open(url, foreground: true, atEnd: true) }
                Divider()
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            } else {
                Button(open ? "Close Folder" : "Open Folder", action: act)
            }
        }
        .animation(Motion.quick, value: hovering)
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}
