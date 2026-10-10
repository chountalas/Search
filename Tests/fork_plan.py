#!/usr/bin/env python3
"""Connor's fork: the AI on a plan — Claude through Claude Code, ChatGPT
through Codex (AIPlan) — in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fork_plan.py`. Same harness
as fork_shelf_ai.py: a world of its own, driven through ./bench's socket,
removed afterwards. Each program is stood in for by a script that writes
down how it was run — its arguments, environment, folder and input — and
answers the way the real one does (Claude Code's stream-json, Codex's
--json events), so the run is the same every time and nothing leaves the
Mac. Tests/fork_plan_real.py asks the real programs.
"""
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fork-plan")

FILLER = "<p>" + "Lorem ipsum dolor sit amet. " * 400 + "</p>"


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (f"<!doctype html><title>Acme Outdoor</title><h1>Acme Outdoor</h1><a href='/careers'>Careers</a>"
                f"{FILLER}<h2 id='pricing'>Pricing</h2>{FILLER}<h2 id='contact'>Contact</h2>{FILLER}")
        data = body.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def log_message(self, *a): pass


site = ThreadingHTTPServer(("127.0.0.1", 0), Site); threading.Thread(target=site.serve_forever, daemon=True).start()
SITE = f"http://127.0.0.1:{site.server_port}"

# The stand-in: one script for both programs, told apart by its name.
WORK = Path(tempfile.mkdtemp(prefix="fork-plan-"))
LOG = WORK / "runs.jsonl"
MODE = WORK / "mode"
FAKE = r'''#!PYTHON
import json, os, re, stat, sys, time
work = os.path.dirname(os.path.abspath(__file__))
codex = os.path.basename(sys.argv[0]).startswith("codex")
mode = open(os.path.join(work, "mode")).read().strip()
args = sys.argv[1:]
if args[:2] in (["auth", "status"], ["login", "status"]):
    said = mode.split("account:", 1)[-1] if mode.startswith("account:") else "plan"
    if said == "hang":
        # Its output closed, but it stays.
        os.close(1); os.close(2)
        time.sleep(30)
        sys.exit(0)
    if codex:
        print({"plan": "Logged in using ChatGPT", "out": "Not logged in", "key": "Logged in using an API key - sk-proj-***"}[said])
    else:
        print(json.dumps({"plan": {"loggedIn": True, "authMethod": "claude.ai", "subscriptionType": "max"},
                          "out": {"loggedIn": False}, "key": {"loggedIn": True, "authMethod": "apiKey"}}[said]))
    sys.exit(0)
if mode == "hold":
    # Gone at once, leaving something in a session of its own holding its
    # input unread.
    import subprocess
    stray = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True, stdin=sys.stdin)
    open(os.path.join(work, "stray"), "w").write(str(stray.pid))
    sys.exit(0)
stdin = sys.stdin.read()
instructions = None
for a in args:
    if a.startswith("model_instructions_file="):
        path = json.loads(a.split("=", 1)[1])
        instructions = {"path": path, "exists": os.path.exists(path),
                        "mode": oct(stat.S_IMODE(os.stat(path).st_mode)) if os.path.exists(path) else "",
                        "text": open(path).read() if os.path.exists(path) else ""}
with open(os.path.join(work, "runs.jsonl"), "a") as f:
    f.write(json.dumps({"codex": codex, "args": args, "env": dict(os.environ), "cwd": os.getcwd(), "stdin": stdin,
                        "pid": os.getpid(), "instructions": instructions}) + "\n")
def say(text):
    if codex:
        print(json.dumps({"type": "thread.started", "thread_id": "t"}))
        print(json.dumps({"type": "item.completed", "item": {"id": "item_0", "type": "error", "message": "Code Mode is unavailable"}}))
        print(json.dumps({"type": "turn.started"}))
        print(json.dumps({"type": "item.completed", "item": {"id": "item_1", "type": "agent_message", "text": text}}))
        print(json.dumps({"type": "turn.completed", "usage": {}}))
    else:
        print(json.dumps({"type": "system", "subtype": "init", "tools": [], "mcp_servers": []}))
        for i in range(0, len(text), 5):
            print(json.dumps({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                              "delta": {"type": "text_delta", "text": text[i:i + 5]}}}), flush=True)
            time.sleep(0.01)
        print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": text}))
if mode == "go":
    question = stdin.split("My request is:\n")[-1].strip().lower()
    places = re.findall(r"^(\d+)\. (?:link|section of this page): (.+?)(?: → \S+)?$", stdin, re.M)
    pick = next((n for n, text in places if any(w in text.lower() for w in re.findall(r"[a-z]+", question) if len(w) > 4)), None)
    say(f"Taking you there.\nGO {pick}" if pick else "This is the Acme Outdoor page.")
elif mode.startswith("say:"):
    say(mode[4:])
elif mode == "error":
    if codex:
        inner = json.dumps({"type": "error", "status": 400, "error": {"type": "invalid_request_error",
                            "message": "The 'gpt-x' model is not supported when using Codex with a ChatGPT account."}})
        print(json.dumps({"type": "turn.started"}))
        print(json.dumps({"type": "turn.failed", "error": {"message": inner}}))
        sys.exit(1)
    print(json.dumps({"type": "result", "subtype": "success", "is_error": True, "result": "Claude AI usage limit reached"}))
    sys.exit(1)
elif mode == "crash":
    sys.stderr.write("starting\nboom: it fell over\n")
    sys.exit(3)
elif mode == "sleep":
    import subprocess
    open(os.path.join(work, "grandchild"), "w").write(str(subprocess.Popen(["/bin/sleep", "60"]).pid))
    time.sleep(60)
    say("too late")
elif mode == "tool":
    # A tool it was never given, about to be used (a new version, say).
    if codex:
        print(json.dumps({"type": "item.started", "item": {"id": "i", "type": "command_execution", "command": "cat ~/.ssh/id_rsa"}}), flush=True)
    else:
        print(json.dumps({"type": "stream_event", "event": {"type": "content_block_start", "index": 0,
                          "content_block": {"type": "tool_use", "name": "Bash"}}}), flush=True)
    time.sleep(30)
    say("ran it")
elif mode == "escape":
    # Something started in a session of its own that keeps the output open.
    import subprocess
    stray = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True, stdout=sys.stdout)
    open(os.path.join(work, "stray"), "w").write(str(stray.pid))
    say("Answered, with a stray left behind.")
elif mode == "linger":
    # Answered, then slow to go, as Codex is.
    say("Quick.")
    sys.stdout.flush()
    time.sleep(30)
elif mode == "group":
    # Out, as both real programs can: a signal to its whole process group.
    import signal
    say("Said, then gone.")
    sys.stdout.flush()
    os.kill(0, signal.SIGTERM)
'''.replace("PYTHON", sys.executable)
for name in ("claude", "codex"):
    path = WORK / name
    path.write_text(FAKE)
    path.chmod(0o755)


def mode(m): MODE.write_text(m)


def runs():
    return [json.loads(line) for line in LOG.read_text().splitlines()] if LOG.exists() else []


def ai(action, **f): return sv.cmd({"do": "ai", "action": action, **f})


def ai_said(action, **f):
    """The answer, or the error the bench gave back as one."""
    try:
        return ai(action, **f)
    except RuntimeError as e:
        return {"error": str(e).rsplit("}: ", 1)[-1]}


def ask(tab, text, within=20):
    """A question in the panel, and its turn once it's done."""
    before = len(ai("state").get("turns", []))
    ai("question", id=tab, text=text)
    until = time.time() + within
    while time.time() < until:
        st = ai("state")
        if st.get("notice"):
            return {"notice": st["notice"]}
        turns = st.get("turns", [])
        if len(turns) > before and turns[-1]["done"] and (not turns[-1]["acting"] or turns[-1]["waiting"]):
            time.sleep(1.5)  # the scroll is smooth
            return ai("state")["turns"][-1]
        time.sleep(0.2)
    return {}


def top(tab, id):
    found = sv.ev(tab, f"Math.round(document.getElementById('{id}').getBoundingClientRect().top)")
    return 9999 if found is None else found


KEPT = {"HOME", "PATH", "LANG", "TERM", "NO_COLOR", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "DISABLE_AUTOUPDATER",
        "USER", "LOGNAME", "TMPDIR", "SHELL", "__CF_USER_TEXT_ENCODING"}

t = sv.T()
try:
    sv.setup()
    sv.launch()
    for provider, name in (("claudePlan", "claude"), ("chatGPTPlan", "codex")):
        got = ai("cli", provider=provider, path=str(WORK / name), leak="sk-ant-should-never-leave")
        t.ok(f"{provider}: the stand-in is the program", got["program"] == str(WORK / name), got)

    # -- Settings: whether the program is signed in with a plan
    for provider in ("claudePlan", "chatGPTPlan"):
        mode("account:plan"); a = ai("cli", provider=provider)["account"]
        t.ok(f"{provider}: signed in with a plan", a.startswith("plan(") and ("Max" in a or "ChatGPT" in a), a)
        mode("account:out"); a = ai("cli", provider=provider)["account"]
        t.ok(f"{provider}: signed out", a == "signedOut", a)
        mode("account:key"); a = ai("cli", provider=provider)["account"]
        t.ok(f"{provider}: an API key is told apart from a plan", a == "apiKey", a)
    mode("account:hang"); start = time.time(); a = ai("cli", provider="claudePlan")["account"]
    t.ok("account: a program that closes its output but stays is given up on", a == "unknown" and time.time() - start < 9,
         (a, time.time() - start))

    # -- Claude through Claude Code
    ai("use", provider="claudePlan")
    tab = sv.cmd({"do": "open", "url": f"{SITE}/"})["id"]; time.sleep(1.5)
    mode("go")
    turn = ask(tab, "where's the pricing?")
    t.ok("claude: the notice comes first, and nothing has run", "notice" in turn and not runs(), turn)
    t.ok("claude: the notice names Anthropic, Claude Code and the plan",
         all(w in turn.get("notice", "") for w in ("Anthropic", "Claude Code", "plan", "no tools")), turn)
    ai("agree")
    until = time.time() + 20
    while time.time() < until and not (ai("state").get("turns") and ai("state")["turns"][-1]["done"]
                                       and not ai("state")["turns"][-1]["acting"]):
        time.sleep(0.2)
    time.sleep(1.5)
    turn = ai("state")["turns"][-1]
    run = runs()[-1]
    t.ok("claude: it answered, streamed in pieces, once (not again from the result)",
         turn["answer"].startswith("Taking you there.") and turn["answer"].count("Taking you there.") == 1, turn)
    t.ok("claude: and took me to Pricing", -50 < top(tab, "pricing") < 200 and turn["went"], (top(tab, "pricing"), turn))
    t.ok("claude: the place says where it ran", ai("state")["place"] == "sent to Claude (your plan) · sonnet", ai("state")["place"])
    args = run["args"]
    t.ok("claude: print mode, safe mode, no tools at all",
         args[0] == "-p" and "--safe-mode" in args and args[args.index("--tools") + 1] == "", args)
    t.ok("claude: no MCP servers, no session kept, nobody asked",
         all(a in args for a in ("--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"))
         and args[args.index("--permission-prompts") + 1] == "none", args)
    t.ok("claude: the model and Search's instructions, as one argument each",
         "--model=sonnet" in args and any(a.startswith("--system-prompt=") and len(a) > 200 for a in args), args)
    t.ok("claude: the page and the question go on its input, not its arguments",
         "Places on this page:" in run["stdin"] and "where's the pricing?" in run["stdin"]
         and not any("Places on this page" in a or "where's the pricing" in a or "Lorem ipsum" in a for a in args), args)
    t.ok("claude: no key from Search's environment reaches it (it would be billed)",
         "ANTHROPIC_API_KEY" not in run["env"] and "OPENAI_API_KEY" not in run["env"]
         and not any("sk-ant-should-never-leave" in v for v in run["env"].values()), sorted(run["env"]))
    t.ok("claude: nothing else of Search's environment either", set(run["env"]) <= KEPT | {"PWD", "SHLVL", "_", "OLDPWD"},
         sorted(set(run["env"]) - KEPT))
    t.ok("claude: it runs in a folder of its own, not a project of yours",
         run["cwd"].endswith("/Search AI") and all(f.startswith("instructions-") for f in os.listdir(run["cwd"])),
         (run["cwd"], os.listdir(run["cwd"])))

    # A second question: the conversation goes with it.
    sv.ev(tab, "scrollTo(0, 0)"); time.sleep(0.5)
    mode("say:It's an outdoor gear company.")
    turn = ask(tab, "what is this company?")
    run = runs()[-1]
    t.ok("claude: a follow-up answered", turn.get("answer") == "It's an outdoor gear company.", turn)
    t.ok("claude: and the conversation so far went with it, oldest first",
         run["stdin"].startswith("Our conversation so far") and run["stdin"].index("[You]\nTaking you there.")
         < run["stdin"].rindex("what is this company?"), run["stdin"][:300])

    # Errors, said in the panel.
    mode("error")
    turn = ask(tab, "anything else?")
    t.ok("claude: its error is shown", "Claude Code: Claude AI usage limit reached" in turn.get("failed", ""), turn)
    mode("crash")
    turn = ask(tab, "and now?")
    t.ok("claude: a program that falls over says its last words", turn.get("failed") == "Claude Code: boom: it fell over", turn)

    # Stop ends the program, not just the panel's wait.
    mode("sleep")
    before = len(runs())
    ai("question", id=tab, text="take your time")
    until = time.time() + 10
    while len(runs()) == before and time.time() < until: time.sleep(0.2)
    pid = runs()[-1]["pid"]

    def alive(p):
        try:
            os.kill(p, 0)
            return True
        except ProcessLookupError:
            return False
    t.ok("claude: the program is running", alive(pid))
    grandchild = int((WORK / "grandchild").read_text())
    t.ok("claude: and something it started", alive(grandchild), grandchild)
    ai("stop"); time.sleep(1.5)
    t.ok("claude: Stop ends it", not alive(pid), pid)
    t.ok("claude: and what it started", not alive(grandchild), grandchild)

    # A program that signals its process group on the way out reaches only itself.
    app = sv.pids()
    mode("group")
    turn = ask(tab, "one more")
    t.ok("claude: a signal to its group doesn't reach Search", sv.pids() == app and app, (app, sv.pids()))
    t.ok("claude: and what it said before is kept", turn.get("answer") == "Said, then gone." and not turn.get("failed"), turn)

    # A tool turning up all the same: stopped there.
    mode("tool")
    turn = ask(tab, "do something")
    pid = runs()[-1]["pid"]
    t.ok("claude: a tool it reaches for stops the run", "went to use a tool (tool_use)" in turn.get("failed", "")
         and turn.get("answer", "") == "", turn)
    t.ok("claude: and the program is ended", not alive(pid), pid)

    # Something it left behind holding the output open doesn't hold the answer.
    mode("escape")
    start = time.time()
    turn = ask(tab, "and then?")
    stray = int((WORK / "stray").read_text())
    t.ok("claude: a stray holding the pipe doesn't hang the answer",
         turn.get("answer") == "Answered, with a stray left behind." and time.time() - start < 8, (turn, time.time() - start))
    try:
        os.kill(stray, 9)
    except ProcessLookupError:
        pass

    # Something holding its input unread doesn't hold a long question.
    mode("hold")
    start = time.time()
    got = ai_said("ask", provider="claudePlan", text="x" * 300_000)
    stray = int((WORK / "stray").read_text())
    pipes = subprocess.run(["lsof", "-p", sv.pids()[0]], capture_output=True, text=True).stdout.count("PIPE")
    t.ok("claude: input held unread by a stray doesn't hang the question", time.time() - start < 8 and "error" in got,
         (got, time.time() - start))
    time.sleep(1)
    pipes_after = subprocess.run(["lsof", "-p", sv.pids()[0]], capture_output=True, text=True).stdout.count("PIPE")
    try:
        os.kill(stray, 9)
    except ProcessLookupError:
        pass
    time.sleep(0.5)
    pipes_gone = subprocess.run(["lsof", "-p", sv.pids()[0]], capture_output=True, text=True).stdout.count("PIPE")
    t.ok("claude: and its input is let go without waiting for the stray", pipes_after == pipes_gone, (pipes, pipes_after, pipes_gone))

    # Answers let their pipes go when they're done, not minutes later.
    app = sv.pids()[0]
    def fds(): return len(subprocess.run(["lsof", "-p", app], capture_output=True, text=True).stdout.splitlines())
    mode("say:ok")
    ask(tab, "warm up")
    before_fds = fds()
    for i in range(6):
        ask(tab, f"again {i}")
    t.ok("claude: six answers later, no pipes left open", fds() <= before_fds + 4, (before_fds, fds()))

    # A model's name that the program would read as an option is refused.
    ai("stop")
    before = len(runs())
    mode("say:should not run")
    got = ai_said("ask", provider="claudePlan", model="--dangerously-skip-permissions", text="hi")
    t.ok("claude: a model named like an option is refused, and nothing runs",
         "isn't a model's name" in got.get("error", "") and len(runs()) == before, got)

    # Not in a private tab.
    ai("close")
    shy = sv.cmd({"do": "open", "url": f"{SITE}/", "private": True})["id"]; time.sleep(1.5)
    before = len(runs())
    ai("question", id=shy, text="hello"); time.sleep(2)
    t.ok("claude: not from a private tab", not ai("state").get("open") and len(runs()) == before, ai("state"))

    # -- ChatGPT through Codex
    ai("use", provider="chatGPTPlan")
    mode("go")
    tab2 = sv.cmd({"do": "open", "url": f"{SITE}/"})["id"]; time.sleep(1.5)
    turn = ask(tab2, "where's the pricing?")
    t.ok("codex: its own notice, naming OpenAI and Codex", "OpenAI" in turn.get("notice", "") and "Codex" in turn.get("notice", ""), turn)
    ai("agree")
    until = time.time() + 20
    while time.time() < until and not (ai("state").get("turns") and ai("state")["turns"][-1]["done"]
                                       and not ai("state")["turns"][-1]["acting"]):
        time.sleep(0.2)
    time.sleep(1.5)
    turn = ai("state")["turns"][-1]
    run = runs()[-1]
    t.ok("codex: answered, its warnings left out", turn["answer"] == "Taking you there.\nGO " + turn["answer"].split("GO ")[-1]
         and "Code Mode" not in turn["answer"], turn)
    t.ok("codex: and took me to Pricing", -50 < top(tab2, "pricing") < 200, top(tab2, "pricing"))
    args = run["args"]
    t.ok("codex: exec, JSON, no session kept, none of your config or rules",
         args[:2] == ["exec", "--json"] and all(a in args for a in ("--ephemeral", "--ignore-user-config", "--ignore-rules",
                                                                    "--skip-git-repo-check", "--sandbox=read-only")), args)
    off = {args[i + 1] for i, a in enumerate(args) if a == "--disable"}
    t.ok("codex: its tools that reach this Mac or the web are off",
         {"shell_tool", "unified_exec", "computer_use", "browser_use", "apps", "hooks", "code_mode_host"} <= off, off)
    sets = {args[i + 1] for i, a in enumerate(args) if a == "-c"}
    t.ok("codex: no web search, no skills list, no AGENTS.md from a project",
         {'web_search="disabled"', "skills.include_instructions=false", "project_doc_max_bytes=0"} <= sets, sets)
    t.ok("codex: the model, and the conversation on its input", "--model=gpt-6.1-sol" in args and args[-1] == "-"
         and "where's the pricing?" in run["stdin"] and not any("Lorem ipsum" in a for a in args), args)
    ins = run["instructions"] or {}
    t.ok("codex: Search's instructions in a file only you can read", ins.get("exists") and ins.get("mode") == "0o600"
         and "Places on this page" not in ins.get("text", "") and len(ins.get("text", "")) > 200, {k: ins.get(k) for k in ("path", "mode")})
    t.ok("codex: and the file is gone after the answer", ins and not os.path.exists(ins["path"]), ins.get("path"))
    t.ok("codex: no key from Search's environment", "OPENAI_API_KEY" not in run["env"] and "ANTHROPIC_API_KEY" not in run["env"],
         sorted(run["env"]))
    mode("tool")
    turn = ask(tab2, "do something")
    t.ok("codex: a tool it reaches for stops the run", "went to use a tool (command_execution)" in turn.get("failed", ""), turn)
    t.ok("codex: and the program is ended", not alive(runs()[-1]["pid"]), runs()[-1]["pid"])
    before = len(runs())
    got = ai_said("ask", provider="chatGPTPlan", model="gpt-5.5", text="hi")
    t.ok("codex: a model that comes with its own tools is refused, and nothing runs",
         "gives gpt-5.5 tools of its own" in got.get("error", "") and len(runs()) == before, got)
    mode("say:fine")
    got = ai_said("ask", provider="chatGPTPlan", model="gpt-6-luna", text="hi")
    t.ok("codex: one that runs without them is fine", got.get("text") == "fine", got)
    # The answer once it's whole, not when the program gets round to going.
    mode("linger")
    start = time.time()
    got = ai_said("ask", provider="chatGPTPlan", text="hi")
    took, pid = time.time() - start, runs()[-1]["pid"]
    t.ok("codex: the answer comes once it's whole, not when the program goes", got.get("text") == "Quick." and took < 4
         and alive(pid), (got, took))
    until = time.time() + 15
    while alive(pid) and time.time() < until: time.sleep(0.5)
    t.ok("codex: and a program that lingers is ended after a while", not alive(pid), pid)
    t.ok("codex: no plugin looked up first", {"plugins", "remote_plugin"} <= {runs()[-1]["args"][i + 1] for i, a in enumerate(runs()[-1]["args"]) if a == "--disable"})
    mode("error")
    turn = ask(tab2, "anything else?")
    t.ok("codex: the provider's error, out of its JSON", turn.get("failed")
         == "Codex: The 'gpt-x' model is not supported when using Codex with a ChatGPT account.", turn)

    # -- Not installed
    ai("stop")
    ai("cli", provider="claudePlan", path=str(WORK / "nowhere"))
    got = ai_said("ask", provider="claudePlan", text="hi")
    t.ok("missing: a program that isn't there is said plainly", got.get("error") == "Claude Code isn't on this Mac.", got)
finally:
    t.done()
    sv.finish()
    for p in WORK.iterdir(): p.unlink()
    WORK.rmdir()
