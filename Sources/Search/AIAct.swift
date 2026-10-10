import Foundation
import WebKit

// The AI doing things on the page for you (Connor's fork): "search for
// running shoes", "add the blue one to the cart", "open my orders".
//
// The model sees what it can act on as a numbered list inside the page's
// text (AIPage.read: headings, links, buttons, fields — never a password or
// card field, never what is typed in one) and ends an answer with action
// lines — up to five in a row, so "type it, then press Return" is one
// answer, not two. Search does them in order, each checked as it comes, and
// stops the row early if the page goes to another page or anything in it
// changed since it was read. Then it reads the page again and asks for the
// next steps, until the model writes no action, the person presses Stop, or
// fifteen steps have gone by. Each step is outlined on the page as it
// happens and listed under the answer.
//
// The page's text can steer a model, so what can't be taken back waits for
// the person: anything that leaves for another site they didn't name, any
// press whose words or address say buy, send, delete, sign out and the
// like, anything that sends a form other than a search of this same site,
// and any yes in a dialog. On a page with words written for an AI, every
// action but a scroll waits. And whatever the markup says, a step that
// takes the page to another site is stopped as it goes (holds) and waits.

enum AIAct {
    enum Verb: String, CaseIterable {
        case go = "GO", click = "CLICK", type = "TYPE", enter = "ENTER", pick = "PICK"
        case scroll = "SCROLL", visit = "VISIT", back = "BACK"
    }

    struct Action: Equatable {
        let verb: Verb
        /// The place it acts on, from 0.
        var index: Int?
        /// TYPE's words, PICK's option, SCROLL's way ("down" or "up").
        var text = ""
        /// VISIT's address.
        var url: URL?
    }

    /// An action held for the person's go-ahead.
    struct Pending: Equatable {
        let action: Action
        let place: AIPage.Place?
        /// "Click “Place order”"
        let what: String
        /// Why it waits.
        let why: String
        /// The person named the place: nothing follows it.
        var named = false
        /// What the row it came in did before it, for the model.
        var did: [String] = []
        /// The last of a row written with DONE: once it's done, so is the request.
        var last = false
    }

    /// The most a single request does before it stops and says so.
    static let mostSteps = 15

    /// The most action lines one answer may end with, done in a row
    /// without asking the model in between.
    static let mostInARow = 5

    // MARK: - the action line

    /// The last line of a row whose end the model needn't see: what was
    /// asked is done once the row is, so it isn't asked again.
    static let finished = "DONE"

    /// The actions an answer ends with, and whether the request ends with them.
    struct Row: Equatable {
        var actions: [Action] = []
        var done = false
    }

    /// The actions the model ended its answer with, in order: the action
    /// lines at its end, up to the first that isn't written as asked, and
    /// DONE after them if it wrote that.
    nonisolated static func parseAll(_ answer: String, count: Int) -> Row {
        var lines = answer.split(whereSeparator: \.isNewline).map(String.init).filter { !clean($0).isEmpty }
        var row = Row()
        if let last = lines.last, clean(last) == finished {
            row.done = true
            lines.removeLast()
        }
        var start = lines.count
        while start > 0, isAction(lines[start - 1]) { start -= 1 }
        for line in lines[start...] {
            guard let action = parse(line, count: count) else { break }
            row.actions.append(action)
        }
        // DONE holds only for a row that is done whole: none of it left out
        // as unreadable or past the most.
        if row.actions.count != lines.count - start || row.actions.count > mostInARow { row.done = false }
        row.actions = Array(row.actions.prefix(mostInARow))
        return row
    }

    /// Whether the next action of a row still has the page it was written
    /// for: the same title and headings — not another product or step shown
    /// in place — and, read again, the same thing at its number, with the
    /// same words, link, sort and form. Otherwise the row stops there.
    nonisolated static func unchanged(_ action: Action, was: AIPage.Read, now: AIPage.Read) -> Bool {
        guard was.title == now.title,
              was.places.filter({ $0.kind == .section }) == now.places.filter({ $0.kind == .section })
        else { return false }
        guard let index = action.index else { return true }
        return was.places.indices.contains(index) && now.places.indices.contains(index) && was.places[index] == now.places[index]
    }

    /// The action the model ended its answer with: the last line that isn't
    /// empty, and only when it is an action written as asked. Nil otherwise.
    nonisolated static func parse(_ answer: String, count: Int) -> Action? {
        let lines = answer.split(whereSeparator: \.isNewline).map { clean(String($0)) }
        guard let last = lines.last(where: { !$0.isEmpty }),
              let match = last.wholeMatch(of: #/(GO|CLICK|TYPE|ENTER|PICK|SCROLL|VISIT|BACK)\b:?\s*(.*)/#),
              let verb = Verb(rawValue: String(match.1))
        else { return nil }
        let rest = String(match.2).trimmingCharacters(in: .whitespaces)
        func place(_ text: String) -> Int? {
            guard let number = Int(text), number >= 1, number <= count else { return nil }
            return number - 1
        }
        switch verb {
        // The number as models write it: 7, [7], #7, "7 (Add to cart)".
        case .go, .click, .enter:
            guard let number = rest.firstMatch(of: #/^[\[#(]?\s*(\d{1,4})\b/#), let index = place(String(number.1)) else { return nil }
            return Action(verb: verb, index: index)
        case .type, .pick:
            guard let parts = rest.wholeMatch(of: #/[\[#(]?\s*(\d{1,4})\s*[\])]?\s*[:,\-–]?\s*(.+)/#), let index = place(String(parts.1)) else { return nil }
            var words = String(parts.2).trimmingCharacters(in: .whitespaces)
            for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] where words.count >= 2 && words.hasPrefix(open) && words.hasSuffix(close) {
                words = String(words.dropFirst().dropLast())
            }
            guard !words.isEmpty else { return nil }
            return Action(verb: verb, index: index, text: String(words.prefix(2000)))
        case .scroll:
            return Action(verb: .scroll, text: rest.lowercased().hasPrefix("up") ? "up" : "down")
        case .visit:
            var written = rest
            if !written.lowercased().hasPrefix("http://"), !written.lowercased().hasPrefix("https://") { written = "https://" + written }
            guard let url = URL(string: written), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host(), host.contains(".")
            else { return nil }
            return Action(verb: .visit, url: url)
        case .back:
            return Action(verb: .back)
        }
    }

    /// Whether a line is an action, or the start of one still coming: kept
    /// out of the answer as the person reads it.
    nonisolated static func isAction(_ line: String) -> Bool {
        let line = clean(line)
        let word = String(line.prefix(while: { $0.isLetter }))
        guard !word.isEmpty, word == word.uppercased(), word.allSatisfy({ $0.isASCII }) else { return false }
        if Verb(rawValue: word) != nil { return true }
        if line == finished { return true }
        return line == word && (Verb.allCases.contains { $0.rawValue.hasPrefix(word) } || finished.hasPrefix(word))
    }

    /// A line without the bold, code marks and spaces a model wraps it in.
    nonisolated private static func clean(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*`"))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - what waits for the person

    /// Words on a button or link, or in its address, for what can't be taken back.
    private static let weighty = #"(?i)\b(buy|pay|payment|purchase|place (your )?order|order now|checkout|check out|send|post|publish|tweet|reply|comment|submit|confirm|delete|remove|erase|cancel|unsubscribe|sign ?out|log ?out|transfer|donate|subscribe|book|reserve|apply|accept|agree|approve|decline|share|invite|archive|upload|withdraw|deactivate|close (my )?account)\b"#
    private static let weightyAddress = #"(?i)(log-?out|sign-?out|delete|remove|unsubscribe|cancel|checkout|purchase)"#
    /// A dialog's way out, which answers nothing.
    private static let dismiss = #"(?i)^(close|dismiss|no,? thanks|not now|maybe later|×|x)$"#
    /// Presses that send a form but change nothing that matters.
    private static let light = #"(?i)^(search|go|find|filter|sort|next|continue|add to (cart|bag|basket)|sign in|log ?in|show( more)?|view( more)?|more|load more|see more)\b"#

    /// Why this action waits for the person, or nil when it doesn't. `named`:
    /// the person named the place outright and no model was asked.
    nonisolated static func caution(_ action: Action, place: AIPage.Place?, page: URL?, request: String,
                                    named: Bool, addressed: Bool) -> String? {
        func elsewhere(_ url: URL?) -> String? {
            guard let url, !AIPage.sameSite(url, page) else { return nil }
            let host = url.host()?.lowercased() ?? "another site"
            if !named, asked(for: url, in: request) { return nil }
            return "It goes to \(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host), another site."
        }
        switch action.verb {
        case .scroll, .back:
            return nil
        case .visit:
            if let leaving = elsewhere(action.url) { return leaving }
        case .go, .click:
            guard let place else { return nil }
            if let leaving = elsewhere(place.href) { return leaving }
            if named { return nil }
            if place.kind == .section { return nil }
            let words = place.text, address = place.href?.absoluteString ?? ""
            if words.range(of: weighty, options: .regularExpression) != nil
                || address.range(of: weightyAddress, options: .regularExpression) != nil {
                return "It could change something that can't be undone."
            }
            if place.form == "elsewhere" { return "It sends a form to another site." }
            if place.form == "post", words.range(of: #"(?i)^add to (cart|bag|basket)\b"#, options: .regularExpression) == nil {
                return "It sends a form."
            }
            if place.form == "form", words.range(of: light, options: .regularExpression) == nil {
                return "It sends a form."
            }
            if place.detail == "dialog", words.range(of: dismiss, options: .regularExpression) == nil {
                return "It answers a dialog on the page."
            }
        case .enter:
            guard let place else { return nil }
            if place.form == "elsewhere" { return "It sends what's in “\(place.text)” to another site." }
            if place.form == "form" || place.form == "post" || place.detail.hasPrefix("text box") {
                return "It may send what's in “\(place.text)”."
            }
        case .type, .pick:
            break
        }
        return addressed && !(action.verb == .go && place?.kind == .section)
            ? "This page has text written for an AI, so Search asks first." : nil
    }

    /// Whether the person's own request names the site, whole: "go to
    /// amazon.com" lets the model open amazon.com — never amazon.xyz, or
    /// amazon.com.example.io, and a bare "amazon" names no site at all.
    nonisolated static func asked(for url: URL, in request: String) -> Bool {
        guard var host = url.host()?.lowercased(), host.contains(".") else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let name = NSRegularExpression.escapedPattern(for: host)
        return request.lowercased().range(of: "(?<![a-z0-9.-])(www\\.)?\(name)(?![a-z0-9-]|\\.[a-z0-9])",
                                          options: .regularExpression) != nil
    }

    /// The action in words, for the list under the answer and the go-ahead.
    nonisolated static func describe(_ action: Action, _ place: AIPage.Place?) -> String {
        let name = place.map { "“\(String($0.text.prefix(60)))”" } ?? ""
        switch action.verb {
        case .go: return place?.kind == .section ? "Scroll to \(name)" : "Open \(name)"
        case .click: return place?.kind == .field ? "Tick \(name)" : "Click \(name)"
        case .type: return "Type “\(String(action.text.prefix(60)))” in \(name)"
        case .enter: return "Press Return in \(name)"
        case .pick: return "Choose “\(String(action.text.prefix(60)))” in \(name)"
        case .scroll: return "Scroll \(action.text)"
        case .visit: return "Open \(action.url?.host() ?? "the address")"
        case .back: return "Go back"
        }
    }

    /// The same, as done: "Clicked “Search”".
    nonisolated static func done(_ action: Action, _ place: AIPage.Place?) -> String {
        let said = describe(action, place)
        let swaps = [("Scroll to", "Scrolled to"), ("Scroll ", "Scrolled "), ("Open ", "Opened "), ("Tick ", "Ticked "),
                     ("Click ", "Clicked "), ("Type ", "Typed "), ("Press ", "Pressed "), ("Choose ", "Chose "), ("Go back", "Went back")]
        for (now, then) in swaps where said.hasPrefix(now) { return then + said.dropFirst(now.count) }
        return said
    }

    // MARK: - where a step may take the page

    /// A step under way on a tab: the sites it may take the page to — the
    /// ones this request has been on, and the one the person just allowed —
    /// and the first page elsewhere that was held. Every page load in the
    /// tab while it lasts — from a link, a form, a script, a redirect — is
    /// checked here as WebKit itself resolved it (Browser.decide), not as the
    /// page's markup suggests, and one to any other site is cancelled and
    /// held for the person. An allowed step is watched too: allowing "Send
    /// message" allows that form's own site, not wherever it leads.
    struct Watch {
        let sites: [URL]
        var held: URL?
    }

    @MainActor private static var watching: [ObjectIdentifier: Watch] = [:]

    @MainActor static func watch(_ tab: Tab, sites: [URL]) {
        watching[ObjectIdentifier(tab)] = Watch(sites: sites)
    }

    /// The watch over, and the page elsewhere it held, if any.
    @MainActor static func unwatch(_ tab: Tab) -> URL? {
        watching.removeValue(forKey: ObjectIdentifier(tab))?.held
    }

    /// Whether a page load in `tab`'s own frame, or a window it opens, waits.
    /// Another app's link (mail, calls, an app's own scheme) waits too.
    @MainActor static func holds(_ url: URL, in tab: Tab, window: Bool = false) -> Bool {
        guard var watch = watching[ObjectIdentifier(tab)] else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https"].contains(scheme) {
            if !window, watch.sites.contains(where: { AIPage.sameSite(url, $0) }) { return false }
            if watch.held == nil { watch.held = url }
            watching[ObjectIdentifier(tab)] = watch
            return true
        }
        return window || !["about", "blob", "data", "javascript"].contains(scheme)
    }

    // MARK: - doing it

    /// The action, done on the page. Nil when it went; why not otherwise.
    /// `checked`: allowed by the person. `same`: not the first of a row, so
    /// the page may have changed since it was read. Either way, it is done
    /// only on the link, or the words, as they were read.
    @MainActor
    static func perform(_ action: Action, place: AIPage.Place?, in tab: Tab, checked: Bool = false, same: Bool = false) async -> String? {
        switch action.verb {
        case .visit:
            guard let url = action.url else { return "no address" }
            tab.go(to: url)
            return nil
        case .back:
            guard tab.canGoBack else { return "there's no page to go back to" }
            tab.back()
            return nil
        case .go where place?.kind == .section:
            guard let index = action.index, let place else { return "nothing to go to" }
            return await AIPage.reveal(index, text: place.text, in: tab) ? nil : "it isn't on the page any more"
        case .go:
            guard let href = place?.href else { return "nothing to go to" }
            tab.go(to: href)
            return nil
        default:
            break
        }
        guard let web = tab.built else { return "the page isn't open" }
        let result = try? await web.callAsyncJavaScript(script, arguments: [
            "n": action.index ?? -1, "verb": action.verb.rawValue, "text": action.text,
            // Still the link, or still the words, the person or the model was
            // shown — a page can change an element after it was read.
            "href": checked || same ? place?.href?.absoluteString ?? "" : "",
            "words": (checked || same) && place?.kind == .button ? Self.bare(place?.text ?? "") : "",
        ], in: nil, contentWorld: Web.world)
        let said = result as? String ?? "the page didn't answer"
        if said == "changed" { return checked ? "it changed after you allowed it" : "it changed on the page" }
        return said == "ok" ? nil : said
    }

    /// Until the page is still again: a load it started to its end, or a
    /// moment for a page that redraws itself in place. `briefly`: between
    /// two of a row, after a step that only fills in or ticks. True when a
    /// page load started.
    @MainActor
    @discardableResult
    static func settle(_ tab: Tab, briefly: Bool = false) async -> Bool {
        let start = Date()
        var loaded = false
        while Date().timeIntervalSince(start) < (briefly ? 0.25 : 0.6) {
            if tab.loading { loaded = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if loaded {
            while tab.loading, Date().timeIntervalSince(start) < 15 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        try? await Task.sleep(for: .milliseconds(loaded ? 500 : briefly ? 100 : 400))
        return loaded
    }

    /// A button's words without the state AIPage.read added to them.
    nonisolated static func bare(_ text: String) -> String {
        var words = text
        for state in [" (ticked)", " (not ticked)"] where words.hasSuffix(state) { words.removeLast(state.count) }
        return words
    }

    /// Run in Search's own world: the element AIPage.read kept, outlined,
    /// then pressed, filled in or chosen from, the way a person would.
    static let script = """
    var el = (window.__searchPlaces || [])[n];
    if (verb === 'SCROLL') {
      window.scrollBy({ top: (text === 'up' ? -1 : 1) * window.innerHeight * 0.85, behavior: 'smooth' });
      return 'ok';
    }
    // On the page that was read, not moved into a frame of it since.
    if (!el || !el.isConnected || el.ownerDocument !== document) return "it isn't on the page any more";
    if (href && el.href !== href) return 'changed';
    if (words) {
      var now = [el.innerText, el.value, el.getAttribute('aria-label'), el.title, el.alt].join(' ').replace(/\\s+/g, ' ');
      if (now.indexOf(words) < 0) return 'changed';
    }
    el.scrollIntoView({ block: 'center', behavior: 'instant' });
    try {
      el.animate([{ outline: '3px solid rgba(255, 176, 0, 0.95)', outlineOffset: '3px' },
                  { outline: '3px solid rgba(255, 176, 0, 0)', outlineOffset: '3px' }],
                 { duration: 1600, easing: 'ease-in' });
    } catch (e) {}
    function press() {
      // A link that would open a window of its own opens here instead.
      if (el.tagName === 'A' && el.target && el.target !== '_self') el.target = '_self';
      var r = el.getBoundingClientRect();
      var at = { bubbles: true, cancelable: true, composed: true, view: window, button: 0,
                 clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
      try { el.dispatchEvent(new PointerEvent('pointerdown', at)); } catch (e) {}
      el.dispatchEvent(new MouseEvent('mousedown', at));
      if (el.focus) el.focus({ preventScroll: true });
      try { el.dispatchEvent(new PointerEvent('pointerup', at)); } catch (e) {}
      el.dispatchEvent(new MouseEvent('mouseup', at));
      el.click();
    }
    function setValue(value) {
      var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype
        : el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: value }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    if (verb === 'CLICK') { press(); return 'ok'; }
    if (verb === 'TYPE') {
      if (el.tagName === 'SELECT') return "it's a list: choose from it";
      if (el.focus) el.focus({ preventScroll: true });
      if (el.isContentEditable) {
        document.execCommand('selectAll', false, null);
        document.execCommand('insertText', false, text);
        return 'ok';
      }
      if (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') return "it isn't a box to type in";
      setValue(text);
      return 'ok';
    }
    if (verb === 'ENTER') {
      if (el.focus) el.focus({ preventScroll: true });
      var key = { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true, composed: true };
      var go = el.dispatchEvent(new KeyboardEvent('keydown', key));
      el.dispatchEvent(new KeyboardEvent('keypress', key));
      el.dispatchEvent(new KeyboardEvent('keyup', key));
      if (go && el.tagName === 'INPUT' && el.form) {
        if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
      }
      return 'ok';
    }
    if (verb === 'PICK') {
      if (el.tagName !== 'SELECT') { press(); return 'ok'; }
      var want = text.trim().toLowerCase(), hit = null, i;
      for (i = 0; i < el.options.length && !hit; i++) if (el.options[i].text.trim().toLowerCase() === want) hit = el.options[i];
      for (i = 0; i < el.options.length && !hit; i++) if (el.options[i].text.toLowerCase().indexOf(want) >= 0) hit = el.options[i];
      if (!hit) return 'there is no option “' + text + '”';
      setValue(hit.value);
      return 'ok';
    }
    return 'unknown action';
    """
}
