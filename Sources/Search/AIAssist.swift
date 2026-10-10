import SwiftUI

// The AI add-on as you meet it: Summarize Page and Ask About This Page…, and
// the panel the answer comes in. One page at a time, from your click; the
// questions after the first stay in the panel, and close it and they are
// gone — nothing is kept anywhere. The answer is plain text, never a link to
// follow or a picture to fetch, marked for what it is: a model's reading,
// which may be wrong, and where it ran. What the page says goes to the model
// as the page's words to read, never as orders (see AIPage), and anything
// in the answer the page didn't have is pointed out.
//
// A provider off this Mac is shown what it will be sent the first time it is
// used, before anything goes. A private tab uses only what runs on this Mac.

/// One conversation about one page.
@MainActor
final class Assistant: ObservableObject, Identifiable {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        /// Nil for the summary.
        let question: String?
        var answer = ""
        var done = false
        var failed: String?
        /// Addresses, emails and numbers in the answer the page doesn't have.
        var strays: [String] = []
        /// What the AI did on the page for this request (Connor's fork,
        /// AIAct), in order, listed under the answer.
        var steps: [String] = []
        /// Still at work on the page: a step, the page settling after it, or
        /// the person's go-ahead.
        var acting = false
        /// A step held for the person's go-ahead, shown with Allow and Stop.
        var waiting: AIAct.Pending?

        var went: String? { steps.last }
    }

    let id = UUID()
    let tab: Tab.ID
    let provider: AIProvider
    let model: String
    /// Asked for a summary, rather than opened for a question.
    let summary: Bool

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var reading = true
    @Published var draft = ""
    /// What a provider off this Mac is sent, not yet agreed to.
    @Published private(set) var notice: String?
    @Published private(set) var trouble: String?
    /// The page has words addressed to an AI (see AIPage.addressesAI).
    @Published private(set) var addressed = false

    private var read: AIPage.Read?
    private let fence = AIPage.newFence()
    private var messages: [AIMessage] = []
    private var waiting: AIPage.Ask?
    private var task: Task<Void, Never>?
    /// The tab, to take the person somewhere on it.
    private weak var page: Tab?
    /// Bumped by Stop: a step or an answer still under way is let go.
    private var generation = 0
    /// The last message with the page in it, and what it is cut down to
    /// when the next one comes: only the page as it is now goes whole.
    private var lastPage: (index: Int, short: String)?

    init(tab: Tab, provider: AIProvider, model: String, summary: Bool) {
        self.tab = tab.id
        self.page = tab
        self.provider = provider
        self.model = model
        self.summary = summary
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            self.read = await AIPage.read(tab)
            self.addressed = self.read?.addressed ?? false
            self.reading = false
            guard self.read != nil else {
                self.trouble = "There's nothing on this page to read."
                return
            }
            if summary { self.ask(.summary) }
        }
    }

    var busy: Bool { reading || turns.last.map { !$0.done || $0.acting } ?? false }

    /// An answer coming, or a step under way: what Stop stops.
    var working: Bool { turns.last.map { !$0.done || ($0.acting && $0.waiting == nil) } ?? false }

    /// Where it ran, for the foot of every answer.
    var place: String {
        provider == .thisMac ? "on this Mac · \(model)"
            : provider.isLocal ? "on this Mac · \(provider.name) · \(model)" : "sent to \(provider.name) · \(model)"
    }

    func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy, notice == nil, read != nil else { return }
        draft = ""
        let asked = String(question.prefix(2000))
        guard let page else { ask(.question(asked)); return }
        // The page read again for every request (Connor's fork): it may have
        // changed since, and what the AI acts on is numbered afresh. Taken
        // to another page, the conversation starts again from it.
        reading = true
        Task { @MainActor [weak self, weak page] in
            guard let self, let page else { return }
            if let fresh = await AIPage.read(page) {
                if !Shelf.same(fresh.url, self.read?.url) {
                    self.messages = []
                    self.lastPage = nil
                }
                self.read = fresh
                self.addressed = fresh.addressed
            }
            self.reading = false
            self.ask(.question(asked))
        }
    }

    private func ask(_ ask: AIPage.Ask) {
        // A place named outright is gone to at once, and nothing is sent.
        if case .question(let question) = ask, let read, let pick = AIPage.direct(question, places: read.places) {
            let place = read.places[pick]
            let elsewhere = place.kind == .link && !AIPage.sameSite(place.href, page?.pageAddress)
            turns.append(Turn(question: question, answer: elsewhere ? "“\(place.text)” is on another site." : "Taking you to “\(place.text)”.", done: true))
            if let id = turns.last?.id { act(AIAct.Action(verb: .go, index: pick), turn: id, named: true) }
            return
        }
        if !provider.isLocal, !Store.settings.bool(forKey: "ai.told.\(provider.rawValue)") {
            waiting = ask
            notice = AIAssist.notice(for: provider)
            return
        }
        send(ask)
    }

    /// The notice read and agreed to: what was asked goes.
    func agree() {
        Store.settings.set(true, forKey: "ai.told.\(provider.rawValue)")
        notice = nil
        if let waiting { send(waiting) }
        waiting = nil
    }

    private func send(_ ask: AIPage.Ask) {
        guard let read else { return }
        switch ask {
        case .summary:
            messages = []
            lastPage = nil
            withPage(AIPage.opening(read, .summary, fence: fence), short: "(The page as it was then is left out.) I asked for a summary.")
            turns.append(Turn(question: nil))
        case .question(let question):
            withPage(AIPage.opening(read, ask, fence: fence), short: "(The page as it was then is left out.) I asked: \(question)")
            turns.append(Turn(question: question))
        }
        run()
    }

    /// A message with the page in it; the one before is cut down to `short`.
    private func withPage(_ text: String, short: String) {
        if let last = lastPage, last.index < messages.count, messages[last.index].role == .user {
            messages[last.index] = AIMessage(role: .user, text: last.short)
        }
        lastPage = (messages.count, short)
        messages.append(AIMessage(role: .user, text: text))
    }

    /// The model asked, its answer streamed into the last turn.
    private func run() {
        // The key, read now and let go with the request.
        let key = provider.isLocal ? nil : AIKeys.key(for: provider)
        let stream = provider == .thisMac
            ? AIEngine.shared.stream(system: AIPage.system(fence: fence), messages: messages)
            : AIClient.shared.stream(provider, model: model, system: AIPage.system(fence: fence), messages: messages, key: key)
        let generation = self.generation
        task = Task { @MainActor [weak self] in
            do {
                for try await piece in stream {
                    guard let self, !self.turns.isEmpty else { return }
                    self.turns[self.turns.count - 1].answer += piece
                    // Longer than any answer about a page needs: a model
                    // talked into writing on and on is stopped.
                    if self.turns[self.turns.count - 1].answer.count > Assistant.longest { break }
                }
                self?.finish(nil, generation: generation)
            } catch {
                self?.finish(error.localizedDescription, generation: generation)
            }
        }
    }

    static let longest = 16_000

    private func finish(_ failed: String?, generation: Int) {
        guard !turns.isEmpty, let read else { return }
        // Stopped: what came is kept as it is, without an error for it.
        let stopped = generation != self.generation
        var turn = turns[turns.count - 1]
        turn.done = true
        turn.failed = stopped ? nil : failed
        turns[turns.count - 1] = turn
        // Checked away from the window's thread: a long answer is a long look.
        let id = turn.id, answer = turn.answer
        Task.detached(priority: .userInitiated) { [weak self] in
            let strays = AIPage.strays(in: answer, from: read)
            await MainActor.run {
                guard let self, let index = self.turns.firstIndex(where: { $0.id == id }) else { return }
                self.turns[index].strays = strays
            }
        }
        if failed == nil, !stopped, !turn.answer.isEmpty {
            messages.append(AIMessage(role: .assistant, text: turn.answer))
        } else if messages.last?.role == .user {
            // A question that got no answer isn't part of what follows; the
            // page goes again with the next one if it was the first.
            messages.removeLast()
        }
        if failed == nil, !stopped, turn.question != nil,
           let action = AIAct.parse(turn.answer, count: read.places.count) {
            act(action, turn: id, named: false)
        } else {
            turns[turns.count - 1].acting = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        generation += 1
        if let at = turns.indices.last, turns[at].acting || !turns[at].done {
            if turns[at].acting { turns[at].steps.append("Stopped") }
            turns[at].waiting = nil
            turns[at].acting = false
        }
    }

    /// An action the model ended its answer with, or a place the person
    /// named: done now, or held for their go-ahead (AIAct.caution).
    private func act(_ action: AIAct.Action, turn id: UUID, named: Bool) {
        guard let read, let at = turns.firstIndex(where: { $0.id == id }) else { return }
        let place = action.index.map { read.places[$0] }
        turns[at].acting = true
        if let why = AIAct.caution(action, place: place, page: page?.pageAddress, request: turns[at].question ?? "",
                                   named: named, addressed: read.addressed) {
            turns[at].waiting = AIAct.Pending(action: action, place: place, what: AIAct.describe(action, place), why: why, named: named)
            return
        }
        perform(action, place: place, turn: id, goOn: !named, approved: false)
    }

    /// The step held for the go-ahead, done because the person said so.
    func allow() {
        guard let at = turns.lastIndex(where: { $0.waiting != nil }), let pending = turns[at].waiting else { return }
        turns[at].waiting = nil
        perform(pending.action, place: pending.place, turn: turns[at].id, goOn: !pending.named, approved: true)
    }

    /// The step held for the go-ahead, not done: the request ends there.
    func deny() {
        guard let at = turns.lastIndex(where: { $0.waiting != nil }), let pending = turns[at].waiting else { return }
        turns[at].waiting = nil
        turns[at].acting = false
        turns[at].steps.append("Didn't: \(pending.what)")
    }

    /// The step done on the page; then, for the model's steps, the page read
    /// again and the model asked for the next one — up to AIAct.mostSteps.
    /// GO is all that was asked, and a place the person named is too.
    private func perform(_ action: AIAct.Action, place: AIPage.Place?, turn id: UUID, goOn: Bool, approved: Bool) {
        let generation = self.generation
        Task { @MainActor [weak self, weak page] in
            guard let page else {
                // The tab is gone: nothing to do it on.
                if let self, let at = self.turns.firstIndex(where: { $0.id == id }) { self.turns[at].acting = false }
                return
            }
            // A step the person didn't look at first is watched as it goes:
            // a page it opens on another site is stopped and waits.
            let watched = !approved && [.click, .type, .enter, .pick, .scroll].contains(action.verb)
            if watched { AIAct.watch(page, request: self?.turns.first(where: { $0.id == id })?.question ?? "") }
            let failed = await AIAct.perform(action, place: place, in: page)
            if failed == nil, action.verb != .go || place?.kind != .section { await AIAct.settle(page) }
            let held = watched ? AIAct.unwatch(page) : nil
            guard let self, self.generation == generation, let at = self.turns.firstIndex(where: { $0.id == id }) else { return }
            let did = AIAct.done(action, place)
            self.turns[at].steps.append(failed.map { "Couldn't: \(AIAct.describe(action, place)) — \($0)" } ?? did)
            if let held {
                let host = held.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "another site"
                self.turns[at].waiting = AIAct.Pending(action: AIAct.Action(verb: .visit, url: held), place: nil,
                                                       what: "Open \(host)", why: "The page tried to take it to another site.",
                                                       named: !goOn)
                return
            }
            guard goOn, action.verb != .go, let request = self.turns[at].question else {
                self.turns[at].acting = false
                return
            }
            guard self.turns[at].steps.count < AIAct.mostSteps else {
                self.turns[at].steps.append("Stopped after \(AIAct.mostSteps) steps")
                self.turns[at].acting = false
                return
            }
            let fresh = await AIPage.read(page)
            guard self.generation == generation, let at = self.turns.firstIndex(where: { $0.id == id }) else { return }
            guard let fresh else {
                self.turns[at].steps.append("The page has nothing on it to read")
                self.turns[at].acting = false
                return
            }
            self.read = fresh
            self.addressed = self.addressed || fresh.addressed
            let outcome = failed.map { "\(did) didn't work: \($0)." } ?? "Done: \(did)."
            self.withPage(AIPage.step(fresh, did: did, failed: failed, request: request, fence: self.fence),
                          short: outcome + " (That page is left out here.)")
            self.turns[at].answer = ""
            self.turns[at].done = false
            self.turns[at].failed = nil
            self.turns[at].strays = []
            self.run()
        }
    }
}

enum AIAssist {
    /// What a provider off this Mac is sent, said once, the first time it is
    /// used — and a word on what it does with it where that matters.
    static func notice(for provider: AIProvider) -> String {
        var text = "When you ask, Search sends this page's text, its address and your question to \(provider.host)"
        text += provider == .openRouter ? ", which passes them to the model's provider." : "."
        text += " Their terms and privacy policy apply. Nothing is sent until you ask, never from a private tab, and Search keeps no copy."
        switch provider {
        case .gemini:
            text += "\n\nOn Gemini's free tier, outside the EEA, Switzerland and the UK, Google may use this to improve its products, and people may read it. Don't use it on sensitive pages."
        case .openRouter:
            text += "\n\nSearch asks OpenRouter to use only providers that keep nothing (zero data retention)."
        default:
            break
        }
        return text
    }
}

extension Browser {
    func summarizePage() { startAssistant(summary: true) }
    func askAboutPage() { startAssistant(summary: false) }

    private func startAssistant(summary: Bool) {
        guard AI.shipped || Store.testing, let tab = active, !tab.isBlank else { return }
        guard prefs.ai, let provider = prefs.aiProvider else {
            settingsPage = .ai
            tuning = true
            announce(prefs.ai ? "Choose where the AI runs" : "Turn on AI in Settings › AI")
            return
        }
        // A web page, nothing else: not a file, not an extension's page.
        guard let scheme = tab.pageAddress?.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            announce("AI works on web pages")
            return
        }
        // A private tab leaves nothing behind anywhere, a provider included.
        let shy = tab.shy || tab.built.map { !$0.configuration.websiteDataStore.isPersistent } == true
        guard !shy || provider.isLocal else {
            announce("In a private tab, only an AI on this Mac")
            return
        }
        if provider == .thisMac, AIEngine.shared.state != .ready {
            settingsPage = .ai
            tuning = true
            announce("The model isn't on this Mac yet")
            return
        }
        let model = prefs.aiModel(for: provider)
        guard !model.isEmpty else {
            settingsPage = .ai
            tuning = true
            announce("Choose a model for \(provider.name)")
            return
        }
        guard provider.isLocal || AIKeys.hint(for: provider) != nil else {
            settingsPage = .ai
            tuning = true
            announce("No key for \(provider.name) yet")
            return
        }
        // Asked again on the page the panel is already about: the same
        // conversation goes on.
        if !summary, let open = assisting, open.tab == tab.id, open.provider == provider { return }
        assisting?.stop()
        assisting = Assistant(tab: tab, provider: provider, model: model, summary: summary)
    }

    func closeAssistant() {
        assisting?.stop()
        assisting = nil
    }
}

// MARK: - the panel

struct AssistantPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var assistant: Assistant
    /// Drawn off screen, for a picture (bench ai picture): what an image
    /// renderer can't draw — a scroll view, a field — stood in for.
    var drawn = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Text(assistant.summary ? "Summary" : "About this page")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Door(icon: "xmark", help: "Close   esc") { browser.closeAssistant() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if drawn {
                conversation.padding(.horizontal, 16).padding(.bottom, 12)
            } else {
                scrolling
            }

            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 8) {
                if drawn {
                    Text("Ask, or tell it what to do…").font(.system(size: 12.5)).foregroundStyle(Palette.faint)
                } else {
                    TextField("", text: $assistant.draft, prompt: Text("Ask, or tell it what to do…").foregroundStyle(Palette.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .focused($typing)
                        .onSubmit { assistant.submit() }
                        .disabled(assistant.notice != nil)
                }
                if assistant.working {
                    Pill("Stop") { assistant.stop() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Text("AI — may be wrong · \(assistant.place)")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.faint)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .frame(width: 380, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 24, y: 8)
        .onAppear { if !assistant.summary, !drawn { typing = true } }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let notice = assistant.notice {
                noticeCard(notice)
            } else if let trouble = assistant.trouble {
                Text(trouble).font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            } else if assistant.reading {
                Text("Reading the page…").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
            }
            if assistant.addressed, assistant.notice == nil {
                caution("This page has text written for an AI to follow. The answer may have been steered by it.")
            }
            ForEach(assistant.turns) { turn in
                TurnView(turn: turn, allow: assistant.allow, deny: assistant.deny).id(turn.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caution(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .medium))
            Text(verbatim: text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.muted)
        .padding(8)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var scrolling: some View {
            ScrollViewReader { scroller in
                ScrollView(showsIndicators: false) {
                    conversation
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                .onChange(of: assistant.turns.last?.answer) { _, _ in
                    if let last = assistant.turns.last { scroller.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: assistant.turns.last?.steps.count) { _, _ in
                    if let last = assistant.turns.last { scroller.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxHeight: 420)
    }

    private func noticeCard(_ notice: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Answers from \(assistant.provider.name)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text(verbatim: notice)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Pill("Continue", filled: true) { assistant.agree() }
                Pill("Cancel") { browser.closeAssistant() }
            }
        }
        .padding(12)
        .background(Palette.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private struct TurnView: View {
        let turn: Assistant.Turn
        var allow: () -> Void = {}
        var deny: () -> Void = {}

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let question = turn.question {
                    Text(verbatim: question)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }
                if turn.answer.isEmpty, !turn.done {
                    Text("…").font(.system(size: 13)).foregroundStyle(Palette.faint)
                }
                // As written, and never as markdown: no link to follow, no
                // picture to fetch.
                if !AIPage.shown(turn.answer).isEmpty {
                    Text(verbatim: AIPage.shown(turn.answer))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failed = turn.failed {
                    Text(verbatim: failed).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 9.5, weight: .medium))
                        Text(verbatim: step).font(.system(size: 11.5)).lineLimit(2)
                    }
                    .foregroundStyle(Palette.muted)
                }
                if turn.acting, turn.done, turn.waiting == nil {
                    Text("Working on the page…").font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                }
                if let waiting = turn.waiting {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: waiting.what + "?")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: waiting.why)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Pill("Allow", filled: true, action: allow)
                            Pill("Stop", action: deny)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help(waiting.place?.href?.absoluteString ?? waiting.action.url?.absoluteString ?? "")
                }
                if !turn.strays.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .medium))
                        Text(verbatim: "Not on the page: " + turn.strays.joined(separator: ", "))
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Palette.muted)
                    .padding(8)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

// MARK: - Settings › AI

struct AISettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// Drawn off screen, for a picture: menus and fields stood in for.
    var drawn = false
    @State private var pasted = ""
    @State private var hint: String?
    @State private var models: [String] = []
    @State private var looking = false
    @ObservedObject private var engine = AIEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Use AI on pages", "Summarize a page, or ask about it, from the View menu. Nothing is sent until you ask") {
                    Switch(on: $prefs.ai)
                }
            }
            if prefs.ai {
                Card {
                    Line("Where it runs", place) {
                        if drawn {
                            Stand(prefs.aiProvider.map { $0.isLocal ? "\($0.name), on this Mac" : $0.name } ?? "Choose…", menu: true)
                        } else {
                        Picker("", selection: Binding(get: { prefs.aiProvider }, set: { prefs.aiProvider = $0 })) {
                            Text("Choose…").tag(AIProvider?.none)
                            ForEach(AIProvider.allCases.filter { $0 != .thisMac || engine.available || prefs.aiProvider == .thisMac }) { provider in
                                Text(provider == .thisMac ? provider.name : provider.isLocal ? "\(provider.name), on this Mac" : provider.name)
                                    .tag(AIProvider?.some(provider))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        }
                    }
                    if let provider = prefs.aiProvider {
                        Rule()
                        if provider == .thisMac { onThisMac } else if provider.isLocal { localModel(provider) } else { key(provider); Rule(); cloudModel(provider) }
                    }
                }
                .onChange(of: prefs.aiProvider) { _, _ in
                    // A key typed for one provider is never saved for another.
                    pasted = ""
                    refresh()
                }
                .onAppear(perform: refresh)
                Card {
                    Line("Forget every key", "Deletes them from this Mac's keychain. A key made by signing in with OpenRouter still works until you delete it on openrouter.ai") {
                        Pill("Forget") {
                            AIKeys.forgetAll()
                            refresh()
                            browser.announce("Keys forgotten")
                        }
                    }
                }
            }
        }
    }

    /// The model here: downloaded when you say, checked, prepared once.
    @ViewBuilder
    private var onThisMac: some View {
        let size = ByteCountFormatter.string(fromByteCount: engine.downloadSize, countStyle: .file)
        if AIEngine.translated {
            Line("Model", "Needs the Apple Silicon version of Search — this copy runs translated") { EmptyView() }
        } else {
            switch engine.state {
            case .absent:
                Line("Model", "\(AIEngine.model.name), downloaded once (\(size)) and checked. Nothing leaves this Mac") {
                    Pill("Download", filled: true) { engine.install() }
                }
            case .downloading(let done):
                Line("Model", "Downloading… \(Int(done * 100))%") {
                    Pill("Cancel") { engine.cancelInstall() }
                }
            case .preparing:
                Line("Model", "Preparing it for this Mac — about twenty seconds, once") { EmptyView() }
            case .ready:
                Line("Model", "\(AIEngine.model.name), on this Mac. Nothing leaves it") {
                    Pill("Remove") { engine.remove() }
                }
            case .failed(let why):
                Line("Model", why) {
                    Pill("Try Again") { engine.install() }
                }
            }
        }
    }

    private var place: String {
        guard let provider = prefs.aiProvider else { return "A provider you have a key with, or an app on this Mac" }
        return provider.isLocal
            ? "Nothing leaves this Mac. Also in private tabs"
            : "Your key, kept in this Mac's keychain, sent only to \(provider.host). Never from a private tab"
    }

    @ViewBuilder
    private func key(_ provider: AIProvider) -> some View {
        if let hint {
            Line("Key", "\(hint), in this Mac's keychain") {
                Pill("Forget") {
                    AIKeys.forget(provider)
                    refresh()
                }
            }
        } else if !AIKeys.available {
            Line("Key", "This copy of Search can't keep keys safely — it isn't the signed release. An app on this Mac still works") { EmptyView() }
        } else {
            Line("Key", provider == .openRouter ? "Paste one, or sign in and OpenRouter makes one for you" : "Paste your API key") {
                HStack(spacing: 6) {
                    SecureField("", text: $pasted, prompt: Text("Key").foregroundStyle(Palette.faint))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 130)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onSubmit { save(provider) }
                    Pill("Save") { save(provider) }
                    if provider == .openRouter {
                        Pill("Sign In…") {
                            browser.tuning = false
                            AISignIn.start(in: browser)
                        }
                    }
                }
            }
        }
    }

    private func cloudModel(_ provider: AIProvider) -> some View {
        Line("Model", "Leave empty for \(provider.defaultModel)") {
            if drawn {
                Stand(prefs.aiModels[provider.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel, width: 170)
            } else {
            TextField("", text: Binding(get: { prefs.aiModels[provider.rawValue] ?? "" },
                                        set: { prefs.setAIModel($0, for: provider) }),
                      prompt: Text(provider.defaultModel).foregroundStyle(Palette.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 170)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    /// A menu or a field, as a picture shows it.
    private struct Stand: View {
        let text: String
        var menu = false
        var width: CGFloat?
        init(_ text: String, menu: Bool = false, width: CGFloat? = nil) { self.text = text; self.menu = menu; self.width = width }
        var body: some View {
            HStack(spacing: 5) {
                Text(text).font(.system(size: 12)).foregroundStyle(menu ? Palette.ink : Palette.faint)
                if menu { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted) }
            }
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(menu ? Palette.ground : Palette.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(menu ? Palette.hairline : .clear, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func localModel(_ provider: AIProvider) -> some View {
        if models.isEmpty {
            Line("Model", looking ? "Asking \(provider.name)…" : "\(provider.name) isn't running, or has no model yet") {
                Pill("Look Again") { refresh() }
            }
        } else {
            Line("Model", "From \(provider.name) on this Mac") {
                Picker("", selection: Binding(get: { prefs.aiModel(for: provider) }, set: { prefs.setAIModel($0, for: provider) })) {
                    Text("Choose…").tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private func save(_ provider: AIProvider) {
        let key = pasted
        pasted = ""
        switch AIKeys.save(key, for: provider) {
        case .kept: browser.announce("Key kept in the keychain")
        case .unavailable: browser.announce("This copy of Search can't keep keys")
        case .failed: browser.announce("The key wasn't kept")
        }
        refresh()
    }

    /// Looked at when the page is: a local app is asked for its models only
    /// now, never in the background.
    private func refresh() {
        guard let provider = prefs.aiProvider else { return }
        hint = provider.isLocal ? nil : AIKeys.hint(for: provider)
        models = []
        guard provider.isLocal else { return }
        looking = true
        Task { @MainActor in
            models = await AIClient.shared.localModels(provider)
            looking = false
        }
    }
}
