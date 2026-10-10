import Foundation

// Connor's fork: the AI answered through a plan you already pay for — Claude
// Pro or Max by way of Claude Code, ChatGPT Plus or Pro by way of Codex —
// rather than an API key. Search runs the program that is already signed in
// on this Mac, once for each answer, as a plain model:
//
// - no tools, so nothing on this Mac is read, run or changed by it;
// - none of your own setup for it (CLAUDE.md, AGENTS.md, skills, hooks, MCP
//   servers, settings), and no key from a shell, so it answers on the plan;
// - no session saved.
//
// The page and the question go in on its standard input, never in its
// arguments, and the answer comes back on its output. Slower than a key — a
// program starts for every answer — and it counts toward the plan's limits.

enum AIPlan {
    /// A test run's stand-in for a program (bench ai cli).
    nonisolated(unsafe) static var testProgram: [AIProvider: URL] = [:]

    /// Longer than any answer takes; then it is stopped.
    static let patience: TimeInterval = 180

    static func programName(_ provider: AIProvider) -> String {
        provider == .claudePlan ? "Claude Code" : "Codex"
    }

    /// The program, where it is installed: an app opened from the Finder has
    /// no shell PATH to find it on.
    static func program(for provider: AIProvider) -> URL? {
        if Store.testing, let test = testProgram[provider] {
            return FileManager.default.isExecutableFile(atPath: test.path) ? test : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let places: [String]
        switch provider {
        case .claudePlan:
            places = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .chatGPTPlan:
            places = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        default:
            return nil
        }
        return places.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - asking

    /// The answer to `messages`, from the program: Claude Code's a piece at a
    /// time, Codex's whole.
    static func stream(_ provider: AIProvider, model: String, system: String,
                       messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let run = Running()
            let task = Task.detached {
                do {
                    try await answer(provider, model: model, system: system, messages: messages, run: run) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                run.stop()
            }
        }
    }

    /// The program's run, for Stop and the time limit to end.
    final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var child: Child?
        private var stopped = false
        private var timedOut = false

        /// Ended by the time limit, not by Stop or by finishing.
        var tooLong: Bool {
            lock.lock(); defer { lock.unlock() }
            return timedOut
        }

        /// False when it was stopped before it started.
        func started(_ child: Child) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return false }
            self.child = child
            return true
        }

        func stop(tooLong: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            stopped = true
            if tooLong, child?.running == true { timedOut = true }
            child?.stop()
        }

        /// The answer is over: the program and its pipes are let go now.
        func finished() {
            lock.lock(); defer { lock.unlock() }
            child = nil
        }
    }

    /// A program started in a session of its own. Both programs signal their
    /// whole process group on the way out of some things; in Search's, that
    /// would be Search. Started on its own, only the given pipes go with it,
    /// it answers for itself to anything macOS asks, and Stop ends it and
    /// anything it started.
    final class Child: @unchecked Sendable {
        let pid: pid_t
        /// Its input, Search's end.
        let input: FileHandle
        /// What it prints, a line at a time; ended when it does, or a moment
        /// after it has gone if something it left behind holds the pipe open.
        let lines: AsyncStream<String>
        private let output: FileHandle, errors: FileHandle
        private let lock = NSLock()
        /// Gone and reaped: its pid may be someone else's now.
        private var reaped = false
        private var reading: AsyncStream<String>.Continuation?
        private var carry = Data()
        private var errorTail = Data()
        private var errorsEnded = false

        private init(pid: pid_t, input: FileHandle, output: FileHandle, errors: FileHandle) {
            self.pid = pid
            self.input = input
            self.output = output
            self.errors = errors
            var reading: AsyncStream<String>.Continuation?
            lines = AsyncStream { reading = $0 }
            self.reading = reading
            output.readabilityHandler = { [weak self] handle in self?.heard(handle.availableData) }
            errors.readabilityHandler = { [weak self] handle in self?.heardError(handle.availableData) }
        }

        /// Its error output into its output, for a short command.
        static func start(_ program: URL, _ arguments: [String], in folder: URL, together: Bool = false) throws -> Child {
            let toChild = Pipe(), fromChild = Pipe(), fromChildErrors = Pipe()
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer {
                posix_spawn_file_actions_destroy(&actions)
                posix_spawnattr_destroy(&attributes)
            }
            posix_spawn_file_actions_adddup2(&actions, toChild.fileHandleForReading.fileDescriptor, 0)
            posix_spawn_file_actions_adddup2(&actions, fromChild.fileHandleForWriting.fileDescriptor, 1)
            posix_spawn_file_actions_adddup2(&actions, (together ? fromChild : fromChildErrors).fileHandleForWriting.fileDescriptor, 2)
            posix_spawn_file_actions_addchdir_np(&actions, folder.path)
            // Every signal as a program expects it, not as Search set it:
            // Search ignores some (Stop's among them), and that would carry over.
            var every: sigset_t = ~0, none: sigset_t = 0
            posix_spawnattr_setsigdefault(&attributes, &every)
            posix_spawnattr_setsigmask(&attributes, &none)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID
                                                         | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
            if let disclaim = AIEngine.disclaim { _ = disclaim(&attributes, 1) }
            var argv: [UnsafeMutablePointer<CChar>?] = ([program.path] + arguments).map { strdup($0) } + [nil]
            var envp: [UnsafeMutablePointer<CChar>?] = environment().map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { (argv + envp).forEach { free($0) } }
            var pid: pid_t = 0
            let status = posix_spawn(&pid, program.path, &actions, &attributes, &argv, &envp)
            toChild.fileHandleForReading.closeFile()
            fromChild.fileHandleForWriting.closeFile()
            fromChildErrors.fileHandleForWriting.closeFile()
            guard status == 0 else { throw AIError.unreachable("It couldn't be started.") }
            // A write to a program that has gone fails, rather than taking
            // Search down with it.
            _ = fcntl(toChild.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            return Child(pid: pid, input: toChild.fileHandleForWriting, output: fromChild.fileHandleForReading,
                         errors: fromChildErrors.fileHandleForReading)
        }

        var running: Bool {
            lock.lock(); defer { lock.unlock() }
            return !reaped
        }

        /// The end of what it said on its error output.
        var lastErrorLine: String {
            lock.lock(); defer { lock.unlock() }
            let text = String(decoding: errorTail, as: UTF8.self)
            let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            return String(line.trimmingCharacters(in: .whitespaces).prefix(300))
        }

        private func heard(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            guard let reading else { return }
            guard !data.isEmpty else { return endReading() }
            carry.append(data)
            while let end = carry.firstIndex(of: 0x0A) {
                reading.yield(String(decoding: carry[carry.startIndex..<end], as: UTF8.self))
                carry = Data(carry[carry.index(after: end)...])
            }
        }

        private func heardError(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            // At the end it would be called again and again with nothing.
            guard !data.isEmpty else {
                errors.readabilityHandler = nil
                errorsEnded = true
                return
            }
            errorTail.append(data)
            if errorTail.count > 4096 { errorTail = errorTail.suffix(4096) }
        }

        /// No more of its output: the last line, then the end of the lines.
        private func endReading() {
            output.readabilityHandler = nil
            if !carry.isEmpty { reading?.yield(String(decoding: carry, as: UTF8.self)) }
            carry = Data()
            reading?.finish()
            reading = nil
        }

        /// Its exit status, once it has gone: asked once. Seen gone first and
        /// reaped after, so its process group can't be anyone else's while
        /// whatever it left in it is ended.
        func exited() async -> Int32 {
            await withCheckedContinuation { done in
                DispatchQueue.global().async {
                    var info = siginfo_t()
                    while waitid(P_PID, id_t(self.pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
                    self.lock.lock()
                    kill(-self.pid, SIGKILL)
                    var status: Int32 = 0
                    while waitpid(self.pid, &status, 0) == -1, errno == EINTR {}
                    self.reaped = true
                    self.lock.unlock()
                    // The last of both outputs, read in their own time; but
                    // something it started outside its group may hold a pipe
                    // open, so no more than a moment for it.
                    let until = ProcessInfo.processInfo.systemUptime + 2
                    while ProcessInfo.processInfo.systemUptime < until {
                        self.lock.lock()
                        let read = self.reading == nil && self.errorsEnded
                        self.lock.unlock()
                        if read { break }
                        usleep(20_000)
                    }
                    self.lock.lock()
                    self.endReading()
                    self.errors.readabilityHandler = nil
                    self.errorsEnded = true
                    self.lock.unlock()
                    // A signal, as a shell would say it; otherwise the code it gave.
                    let signal = status & 0x7f
                    done.resume(returning: signal == 0 ? (status >> 8) & 0xff : 128 + signal)
                }
            }
        }

        /// `data` on its input, then the input closed. Never blocked for good:
        /// once the program has gone, whatever it left holding its input
        /// unread isn't waited on.
        func give(_ data: Data) {
            let fd = input.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                var sent = 0
                while sent < bytes.count {
                    let wrote = write(fd, base + sent, bytes.count - sent)
                    if wrote > 0 { sent += wrote; continue }
                    guard wrote == -1, errno == EAGAIN || errno == EINTR, running else { return }
                    var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&ready, 1, 100)
                }
            }
            try? input.close()
        }

        /// Asked to stop, then made to: it, and anything it started.
        func stop() {
            lock.lock(); defer { lock.unlock() }
            guard !reaped else { return }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                lock.lock(); defer { lock.unlock() }
                if !reaped { kill(-pid, SIGKILL) }
            }
        }
    }

    private static func answer(_ provider: AIProvider, model: String, system: String, messages: [AIMessage],
                               run: Running, yield: @escaping (String) -> Void) async throws {
        let name = programName(provider)
        guard let program = program(for: provider) else { throw AIError.unreachable("\(name) isn't on this Mac.") }
        // A model's name, never something the program would take as an option.
        guard !model.isEmpty, !model.hasPrefix("-") else { throw AIError.unreachable("That isn't a model's name.") }
        guard provider != .chatGPTPlan || toolless(model) else {
            throw AIError.unreachable("Codex gives \(model) tools of its own. Use a model that runs without, like \(AIProvider.chatGPTPlan.defaultModel).")
        }
        let folder = try workFolder()
        var instructions: URL?
        defer { if let instructions { try? FileManager.default.removeItem(at: instructions) } }

        let arguments: [String]
        switch provider {
        case .claudePlan:
            arguments = claudeArguments(model: model, system: system)
        default:
            // Codex takes its instructions from a file: this answer's own,
            // readable only by you, gone with the answer.
            let file = folder.appendingPathComponent("instructions-\(UUID().uuidString).md")
            guard FileManager.default.createFile(atPath: file.path, contents: Data(system.utf8),
                                                 attributes: [.posixPermissions: 0o600])
            else { throw AIError.unreachable("\(name) couldn't be given its instructions.") }
            instructions = file
            arguments = codexArguments(model: model, instructions: file)
        }
        let child: Child
        do {
            child = try Child.start(program, arguments, in: folder)
        } catch {
            throw AIError.unreachable("\(name) couldn't be started.")
        }
        let exited = Task { await child.exited() }
        defer { run.finished() }
        guard run.started(child) else {
            child.stop()
            _ = await exited.value
            return
        }
        let watchdog = DispatchWorkItem { run.stop(tooLong: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + patience, execute: watchdog)
        defer { watchdog.cancel() }

        // The conversation on its input, written while the output is read, so
        // neither waits on the other.
        let prompt = Data(Self.prompt(messages).utf8)
        Thread.detachNewThread { child.give(prompt) }

        var said = false
        var failure: String?
        for await line in child.lines {
            switch heard(line, provider) {
            case .piece(let piece):
                // Codex's messages come whole; a second one is a paragraph of its own.
                yield(said && provider == .chatGPTPlan ? "\n\n" + piece : piece)
                said = true
            case .whole(let text):
                if !said, !text.isEmpty { yield(text); said = true }
            case .failed(let why):
                failure = why
            case .tool(let kind):
                // It was given none. If one turns up all the same — a new
                // version, another model — it is stopped there.
                failure = "it went to use a tool (\(kind)), so Search stopped it."
                run.stop()
            case .nothing:
                break
            }
        }
        let status = await exited.value
        if Task.isCancelled { return }
        if run.tooLong { throw AIError.unreachable("\(name) took too long to answer.") }
        if let failure { throw AIError.unreachable("\(name): \(AIClient.scrub(failure, hiding: nil))") }
        // Gone afterwards, the way some programs go: what it said stands.
        if status != 0, !said {
            let last = child.lastErrorLine
            throw AIError.unreachable(last.isEmpty ? "\(name) stopped without answering." : "\(name): \(AIClient.scrub(last, hiding: nil))")
        }
        if !said { throw AIError.unreachable("\(name) didn't answer.") }
    }

    /// Codex's models that come with no tool of their own: everything goes
    /// through its code mode, which fails closed with the code-mode host off.
    /// Another model would bring its file-patching tool along. Codex's own
    /// list says which, where it has one; otherwise these.
    static let knownToolless: Set<String> = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
                                             "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]

    static func toolless(_ model: String) -> Bool {
        let list = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        if let data = try? Data(contentsOf: list),
           let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]],
           let entry = models.first(where: { $0["slug"] as? String == model }) {
            return entry["tool_mode"] as? String == "code_mode_only"
        }
        return knownToolless.contains(model)
    }

    /// Claude Code as a plain model: safe mode (none of your CLAUDE.md,
    /// skills, plugins, hooks or MCP servers), no tools at all, nothing
    /// asked of anyone, no session kept.
    static func claudeArguments(model: String, system: String) -> [String] {
        ["-p", "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--no-chrome",
         "--permission-prompts", "none", "--disable-slash-commands",
         "--model=\(model)", "--system-prompt=\(system)",
         "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
    }

    /// Codex as a plain model: none of your config, rules, skills or hooks,
    /// every tool that reaches this Mac or the web off (what's left of its
    /// own fails closed), a read-only sandbox besides, no session kept.
    static func codexArguments(model: String, instructions: URL) -> [String] {
        var arguments = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                         "--sandbox=read-only", "--model=\(model)"]
        let settings = [
            "model_reasoning_effort=\"low\"",
            "model_instructions_file=\(toml(instructions.path))",
            "web_search=\"disabled\"",
            "project_doc_max_bytes=0",
            "skills.include_instructions=false",
            "include_permissions_instructions=false",
            "include_environment_context=false",
            "include_collaboration_mode_instructions=false",
            "include_apps_instructions=false",
            "check_for_update_on_startup=false",
        ]
        for setting in settings { arguments += ["-c", setting] }
        let off = ["shell_tool", "unified_exec", "view_image", "apps", "browser_use", "browser_use_external", "computer_use",
                   "image_generation", "sleep_tool", "tool_suggest", "goals", "code_mode_host", "hooks", "multi_agent",
                   "memories", "daemon_auto_start",
                   // Its snapshot of your shell runs your shell's startup files.
                   "shell_snapshot", "shell_snapshot_v2"]
        for feature in off { arguments += ["--disable", feature] }
        return arguments + ["-"]
    }

    private static func toml(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Only what the program needs to find itself and its sign-in: no key a
    /// shell might have set (it would be billed instead of the plan), nothing
    /// of Search's own.
    static func environment() -> [String: String] {
        let mine = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var kept = ["HOME": home,
                    "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                    "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1",
                    // Claude Code: no update check, error report or telemetry on the way.
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1"]
        for name in ["USER", "LOGNAME", "TMPDIR", "SHELL", "__CF_USER_TEXT_ENCODING"] {
            if let value = mine[name] { kept[name] = value }
        }
        return kept
    }

    /// The one folder it runs in, empty but for an answer's instructions:
    /// no project of yours for it to find.
    private static func workFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Search AI", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw AIError.unreachable("There's no folder to run it in.")
        }
        return folder
    }

    /// One message, as the programs take: the conversation so far, oldest
    /// first, when there is more than the question.
    static func prompt(_ messages: [AIMessage]) -> String {
        guard messages.count > 1 else { return messages.first?.text ?? "" }
        var text = "Our conversation so far, oldest first. Answer my last message."
        for message in messages {
            text += "\n\n[\(message.role == .user ? "Me" : "You")]\n\(message.text)"
        }
        return text
    }

    // MARK: - reading

    enum Heard: Equatable {
        case piece(String)
        /// The whole answer again, at the end: shown only if no piece was.
        case whole(String)
        case failed(String)
        /// A tool it was never given, about to be used.
        case tool(String)
        case nothing
    }

    static func heard(_ line: String, _ provider: AIProvider) -> Heard {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return .nothing }
        let type = json["type"] as? String
        if provider == .claudePlan {
            switch type {
            case "stream_event":
                if let event = json["event"] as? [String: Any], event["type"] as? String == "content_block_start",
                   let kind = (event["content_block"] as? [String: Any])?["type"] as? String, kind.hasSuffix("tool_use") {
                    return .tool(kind)
                }
                guard let event = json["event"] as? [String: Any], let piece = AIClient.piece(.anthropic, event),
                      !piece.isEmpty
                else { return .nothing }
                return .piece(piece)
            case "result":
                let text = json["result"] as? String ?? ""
                if json["is_error"] as? Bool == true || json["subtype"] as? String != "success" {
                    let why = text.isEmpty ? (json["errors"] as? [String])?.first ?? "" : text
                    return .failed(why.isEmpty ? "It couldn't answer." : String(why.prefix(300)))
                }
                return .whole(text)
            default:
                return .nothing
            }
        }
        if type == "item.started" || type == "item.updated" || type == "item.completed",
           let kind = (json["item"] as? [String: Any])?["type"] as? String,
           !["agent_message", "reasoning", "error", "todo_list"].contains(kind) {
            return .tool(kind)
        }
        switch type {
        case "item.completed":
            guard let item = json["item"] as? [String: Any], item["type"] as? String == "agent_message",
                  let text = item["text"] as? String, !text.isEmpty
            else { return .nothing }
            return .piece(text)
        case "turn.failed", "error":
            let said = ((json["error"] as? [String: Any])?["message"] as? String) ?? (json["message"] as? String) ?? ""
            // Often the provider's own error, as JSON in a string.
            let inner = (try? JSONSerialization.jsonObject(with: Data(said.utf8)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            let why = inner ?? said
            return .failed(why.isEmpty ? "It couldn't answer." : String(why.prefix(300)))
        default:
            return .nothing
        }
    }

    // MARK: - the account

    enum Account: Equatable {
        case missing
        case signedOut
        /// Signed in with a plan: its name where the program says.
        case plan(String)
        /// Signed in with an API key: billed by use, not the plan.
        case apiKey
        case unknown
    }

    /// Whether the program is there and signed in with a plan. Asked only
    /// when Settings shows it.
    static func account(_ provider: AIProvider) async -> Account {
        guard let program = program(for: provider) else { return .missing }
        let arguments = provider == .claudePlan ? ["auth", "status"] : ["login", "status"]
        guard let said = await output(program, arguments) else { return .unknown }
        if provider == .claudePlan {
            guard let json = try? JSONSerialization.jsonObject(with: Data(said.utf8)) as? [String: Any] else { return .unknown }
            guard json["loggedIn"] as? Bool == true else { return .signedOut }
            guard json["authMethod"] as? String == "claude.ai" else { return .apiKey }
            let kind = (json["subscriptionType"] as? String).map { "Claude " + $0.capitalized } ?? "Claude"
            return .plan(kind)
        }
        if said.contains("ChatGPT") { return .plan("ChatGPT") }
        if said.localizedCaseInsensitiveContains("API key") { return .apiKey }
        if said.localizedCaseInsensitiveContains("not logged in") { return .signedOut }
        return .unknown
    }

    /// What a short command prints, or nil if it takes longer than a few seconds.
    private static func output(_ program: URL, _ arguments: [String]) async -> String? {
        guard let folder = try? workFolder(), let child = try? Child.start(program, arguments, in: folder, together: true)
        else { return nil }
        child.give(Data())
        let exited = Task { await child.exited() }
        let timer = DispatchWorkItem { child.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timer)
        defer { timer.cancel() }
        var said = ""
        for await line in child.lines where said.utf8.count < 8192 { said += line + "\n" }
        return await exited.value < 128 ? said : nil
    }
}
